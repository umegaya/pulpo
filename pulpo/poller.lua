-- actor main loop
local ffi = require 'ffiex'
local thread = require 'pulpo.thread'
local memory = require 'pulpo.memory'
local util = require 'pulpo.util'
local fs = require 'pulpo.fs'
local signal = require 'pulpo.signal'
-- ffi.__DEBUG_CDEF__ = true
local log = require 'pulpo.logger'
log.initialize()

local _M = {}
local iolist = ffi.NULL
local handlers = {}
local handler_id_seed = 0
local read_handlers, write_handlers, gc_handlers, error_handlers = {}, {}, {}, {}
local HANDLER_TYPE_POLLER
local io_index, poller_index = {}, {}

ffi.cdef[[
	typedef struct pulpo_poller_config {
		int maxfd, maxconn, rmax, wmax;
	} pulpo_poller_config_t;
]]

---------------------------------------------------
-- system independent poller object's API
---------------------------------------------------
function io_index.read(t, ptr, len)
	return read_handlers[t:type()](t, ptr, len)
end
function io_index.write(t, ptr, len)
	return write_handlers[t:type()](t, ptr, len)
end
function io_index.nfd(t)
	return tonumber(t:fd())
end
function io_index.by(t, poller, cb)
	return poller:add(t, cb)
end
function io_index.close(t)
	logger.info("fd=%d closed by user", t:nfd())
	coroutine.yield()
end

function poller_index.add(t, io, co)
	co = ((type(co) == "function") and coroutine.wrap(co) or co)
	handlers[tonumber(io:fd())] = co
	local ok, rev = pcall(co, io)
	if ok then
		if rev then
			if rev:add_to(t) then
				return true
			end
		end
	else
		logger.warning('abort by error:', rev)
	end
	io:fin()
	return true
end
function poller_index.remove(t, io)
	if not io:remove_from(t) then return false end
	handlers[tonumber(io:fd())] = nil
	return true
end
function poller_index.loop(t)
	while t.alive do
		t:wait()
	end
end
function poller_index.stop(t)
	t.alive = false
end
function poller_index.io(t)
	return _M.newio(t:fd(), HANDLER_TYPE_POLLER, t)
end

---------------------------------------------------
-- module body
---------------------------------------------------
local function nop() end
function _M.add_handler(reader, writer, gc, err)
	handler_id_seed = handler_id_seed + 1
	read_handlers[handler_id_seed] = reader or nop
	write_handlers[handler_id_seed] = writer or nop
	gc_handlers[handler_id_seed] = gc or nop
	error_handlers[handler_id_seed] = err or nop
	return handler_id_seed
end

local function common_initialize(opts)
	--> change system limits
	_M.config = thread.share_memory('__poller__', function ()
		local data = memory.alloc_typed('pulpo_poller_config_t')
		data.maxfd = util.maxfd(opts.maxfd or 1024)
		data.maxconn = util.maxconn(opts.maxconn or 512)
		if opts.rmax or opts.wmax then
			data.rmax, data.wmax = util.setsockbuf(opts.rmax, opts.wmax)
		end
		return 'pulpo_poller_config_t', data
	end)

	-- system dependent initialization (it should define pulpo_poller_t, pulpo_io_t)
	local poller = opts.poller or (
		ffi.os == "OSX" and 
			"kqueue" or 
		(ffi.os == "Linux" and 
			"epoll" or 
			assert(false, "unsupported arch:"..ffi.os))
	)
	iolist = require ("pulpo.poller."..poller).initialize({
		opts = opts,
		handlers = handlers, gc_handlers = gc_handlers, 
		poller = _M.config, 
		poller_index = poller_index, 
		io_index = io_index,
	})
	return true
end

function _M.initialize(opts)
	common_initialize(opts)
	--> tweak signal handler
	signal.ignore("SIGPIPE")
end

function _M.init_worker()
	common_initialize({})
end

function _M.finalize()
	if iolist ~= ffi.NULL then
		memory.free(iolist)
	end
	for _,p in ipairs(_M.pollerlist) do
		p:fin()
		memory.free(p)
	end
end

_M.pollerlist = {}
function _M.new()
	local p = memory.alloc_typed('pulpo_poller_t')
	p:init(_M.config.maxfd)
	table.insert(_M.pollerlist, p)
	return p
end

function _M.newio(fd, type, ctx)
	local io = iolist[fd]
	io:init(fd, type, ctx)
	return io
end

--> handler for poller itself
local function poller_read(io, ptr, len)
	local p = io:ctx('pulpo_poller_t*')
::retry::
	if p:wait() == 0 then
		io:wait_read()
		goto retry
	end
end
local function poller_gc(io)
	local p = io:ctx('pulpo_poller_t*')
	p:fin()
	memory.free(p)
end

HANDLER_TYPE_POLLER = _M.add_handler(poller_read, nil, poller_gc)

return _M

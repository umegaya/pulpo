-- actor main loop
local ffi = require 'ffiex.init'
local thread = require 'pulpo.thread'
local memory = require 'pulpo.memory'
local util = require 'pulpo.util'
local event = require 'pulpo.event'
local signal = require 'pulpo.signal'
local exception = require 'pulpo.exception'
local raise = exception.raise

-- ffi.__DEBUG_CDEF__ = true
local log = (require 'pulpo.logger').initialize()
if not _G.pulpo_assert then
	_G.pulpo_assert = assert
end

local _M = {}
local iolist = ffi.NULL
local handlers = {}
local handler_id_seed = 0
local handler_names = {}
local read_handlers, write_handlers, gc_handlers, addrinfo_handler, error_handlers = {}, {}, {}, {}, {}
local writev_handlers, writef_handlers = {}, {}
local HANDLER_TYPE_POLLER
local io_index, poller_index = {}, {}

ffi.cdef[[
	typedef struct pulpo_poller_config {
		int maxfd, maxconn, rmax, wmax;
	} pulpo_poller_config_t;
]]

exception.define('poller')

---------------------------------------------------
-- system independent poller object's API
---------------------------------------------------
function io_index.read(t, ptr, len)
	return read_handlers[t:type()](t, ptr, len)
end
function io_index.write(t, ptr, len)
	return write_handlers[t:type()](t, ptr, len)
end
function io_index.writev(t, vec, len)
	return writev_handlers[t:type()](t, ptr, len)
end
function io_index.writef(t, in_fd, offset_p, count)
	return writef_handlers[t:type()](t, in_fd, offset_p, count)
end
function io_index.nfd(t)
	return tonumber(t:fd())
end
function io_index.__emid(t)
	return tonumber(t:fd())
end	
function io_index.by(t, poller, cb)
	return poller:add(t, cb)
end
function io_index.addrinfo(t)
	return addrinfo_handler[t:type()](t)
end
function io_index.close(t, reason)
	-- logger.info("fd=", t:fd(), " closed by user")
	t:fin(reason)
end
function io_index.__cancel(t, co)
	event.unregister_thread(event.ev_read(t), co)
	event.unregister_thread(event.ev_write(t), co)
end
io_index.emit = event.emit
io_index.event = event.get


function poller_index.newio(t, fd, type, ctx)
	return _M.newio(t, fd, type, ctx)
end
function poller_index.loop(t)
	while t.alive do
		t:wait()
	end
end
function poller_index.stop(t)
	t.alive = false
end

---------------------------------------------------
-- module body
---------------------------------------------------
local function nop() end
function _M.add_handler(name, reader, writer, gc, ai, err, writev, writef)
	handler_id_seed = handler_id_seed + 1
	read_handlers[handler_id_seed] = reader or nop
	write_handlers[handler_id_seed] = writer or nop
	writev_handlers[handler_id_seed] = writev or nop
	writef_handlers[handler_id_seed] = writef or nop
	gc_handlers[handler_id_seed] = gc or nop
	addrinfo_handler[handler_id_seed] = ai or nop
	error_handlers[handler_id_seed] = err or nop
	handler_names[handler_id_seed] = name
	logger.info('add_handler:', name, '=>', handler_id_seed)
	return handler_id_seed
end

local poller_module
local function common_initialize(opts)
	opts = opts or {}
	--> change system limits
	_M.config = thread.shared_memory('__poller_config__', function ()
		local data = memory.alloc_typed('pulpo_poller_config_t')
		data.maxfd = util.maxfd(opts.maxfd or 1024, true)
		data.maxconn = util.maxconn(opts.maxconn or 1024)
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
		pulpo_assert(false, "unsupported arch:"..ffi.os))
	)
	poller_module = require ("pulpo.poller."..poller)
	iolist = poller_module.initialize({
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
	common_initialize()
end

function _M.finalize()
	for _,p in ipairs(_M.pollerlist) do
		p:fin()
		memory.free(p)
	end
	if iolist ~= ffi.NULL then
		for i=0,_M.config.maxfd - 1,1 do
			-- print('fin:', iolist[i]:fd())
			iolist[i]:fin()
		end
		-- iolist itself allocated from poller module.
		-- so memory management is done in each modules
		if poller_module then
			poller_module.finalize()
		end
	end
end
thread.register_exit_handler("poller.lua", _M.finalize)

_M.pollerlist = {}
function _M.new()
	local p = memory.alloc_typed('pulpo_poller_t')
	p:init(_M.config.maxfd)
	table.insert(_M.pollerlist, p)
	return p
end

function _M.newio(poller, fd, type, ctx)
	local io = iolist[fd]
	io:init(poller, fd, type, ctx)
	return io
end

return _M

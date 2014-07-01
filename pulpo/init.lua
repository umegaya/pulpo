local ffi = require 'ffiex'
local C = ffi.C
local PT = ffi.load("pthread")

local _M = {}
local log = require 'pulpo.logger'
local term = require 'pulpo.terminal'
local function init_logger()
	log.initialize()
	log.redirect("default", function (setting, ...)
		term[setting.color]()
		io.write(_M.logpfx)
		print(...)
		term.resetcolor()
		io.stdout:flush()
	end)
	_G.pulpo_assert = function (cond, msgobj)
		if not cond then
			logger.fatal(msgobj)
			_G.error(msgobj, 0)
		end
		return cond
	end
end
init_logger()

local thread = require 'pulpo.thread'
local poller = require 'pulpo.poller'
local memory = require 'pulpo.memory'
local gen = require 'pulpo.generics'
local util = require 'pulpo.util'
local tentacle = require 'pulpo.tentacle'
local event = require 'pulpo.event'

_M.thread = thread
_M.logpfx = "[????] "
_M.poller = poller
_M.tentacle = tentacle
_M.event = event
_M.share_memory = thread.share_memory

-- only main thread call this.
function _M.initialize(opts)
	-- child thread may call pulpo.run, 
	-- but already initialized by init_worker.
	-- prevent re-initialize by this.
	if not _M.initialized then
		thread.initialize(opts)
		poller.initialize(opts)
		_M.init_share_memory()
		_M.mainloop = poller.new()
		_M.init_cdef()
		_M.init_opaque()
		_M.initialized = true
	end
	return _M
end

function _M.finalize()
	if _M.initialized then
		thread.finalize()
		_M.initialized = nil
	end
end

function _M.init_share_memory()
	ffi.cdef[[
		typedef struct pulpo_thread_idseed {
			int cnt;
		} pulpo_thread_idseed_t;
	]]
	_M.share_memory("__thread_id_seed__", gen.rwlock_ptr("pulpo_thread_idseed_t"))
end

-- others initialized by this.
function _M.init_worker(tls)
	if not _M.initialized then
		poller.init_worker()
		_M.mainloop = poller.new()
		_M.init_cdef()
		_M.initialized = true
	end

	return _M.init_opaque()
end

local function create_opaque(fn, group)
	local r = memory.alloc_fill_typed('pulpo_opaque_t')
	-- generate unique seed
	local seed = _M.share_memory("__thread_id_seed__")
	PT.pthread_rwlock_wrlock(seed.lock)
		seed.data.cnt = seed.data.cnt + 1
		if seed.data.cnt > 65000 then seed.data.cnt = 1 end
		r.id = seed.data.cnt
	PT.pthread_rwlock_unlock(seed.lock)
	
	r.group = memory.strdup(group)
	if fn then
		local proc = util.encode_proc(fn)
		r.proc = memory.strdup(proc)
		r.plen = #proc
	end
	return r
end
local function destroy_opaque(opq)
	memory.free(opq.group)
	memory.free(opq)
end

function _M.init_opaque()
	local opaque = thread.opaque(thread.me, "pulpo_opaque_t*")
	if opaque == ffi.NULL then
		opaque = create_opaque(nil, "root")
		thread.set_opaque(thread.me, opaque)
	end
	opaque.poller = _M.mainloop	
	_M.tid = opaque.id
	_M.logpfx = util.sprintf("[%04x] ", 8, ffi.new('int', opaque.id))

	-- opaque.rfd,opaque.wfd = pipe.create(_M.mainloop, opaque)

	thread.register_exit_handler(function ()
		destroy_opaque(opaque)
	end)
	return opaque
end

function _M.init_cdef()
	ffi.cdef[[
		typedef struct pulpo_opaque {
			unsigned short id, padd;
			char *group;
			char *proc;
			size_t plen;
			pulpo_poller_t *poller;
			pulpo_io_t *rfd, *wfd;
		} pulpo_opaque_t;
	]]
	-- necessary gen cdef
	gen.rwlock_ptr("int")
end

function _M.create_thread(fn, group, arg)
	return thread.create(function (arg)
		local ffi = require 'ffiex'
		local pulpo = require 'pulpo.init'
		local util = require 'pulpo.util'
		local memory = require 'pulpo.memory'
		local opaque = pulpo.init_worker()
		local proc = util.decode_proc(ffi.string(opaque.proc, opaque.plen))
		memory.free(opaque.proc)
		proc(arg)
	end, arg or ffi.NULL, create_opaque(fn, group or "main"))
end

function _M.run(opts, executable)
	_M.initialize(opts)

	_M.n_core = opts.n_core or util.n_cpu()
	-- -1 for this thread (also run as worker)
	for i=0,_M.n_core - 2,1 do
		thread.create(
			function (arg)
				local ffi = require 'ffiex'
				local pulpo = require 'pulpo.init'
				local util = require 'pulpo.util'
				local memory = require 'pulpo.memory'
				local opaque = pulpo.init_worker()
				local proc = util.decode_proc(ffi.string(opaque.proc, opaque.plen))
				memory.free(opaque.proc)
				pulpo.tentacle(proc, arg)
				pulpo.mainloop:loop()
			end, 
			opts.arg or ffi.NULL, 
			create_opaque(executable, opts.group or "main"), true
		)
	end
	coroutine.wrap(util.create_proc(executable))(arg)
	_M.mainloop:loop()
end

function _M.filter(group_or_id_or_filter)
	return thread.fetch(function (list, size)
		local matches = {}
		if not group_or_id_or_filter then
			for i=0,size-1,1 do
				table.insert(matches, list[i])
			end
			return matches
		end
		for i=0,size-1,1 do
			local th = list[i]
			if type(group_or_id_or_filter) == "string" then -- group
				if ffi.string(opq.group) == group_or_id_or_filter then
					table.insert(matches, th)
				end
			elseif type(group_or_id_or_filter) == "number" then -- id
				if opq.id == group_or_id_or_filter then
					table.insert(matches, th)
				end
			elseif type(group_or_id_or_filter) == "function" then -- filter
				if group_or_id_or_filter(th) then
					table.insert(matches, th)
				end
			end
		end
		return matches
	end)
end

function _M.stop(group_or_id_or_filter)
	for _,th in ipairs(_M.filter(group_or_id_or_filter)) do
		local opq = thread.opaque(th, "pulpo_opaque_t*")
		opq.poller:stop()
	end
end

local channel_list = {}
function _M.writer(thread)
	local opq = ffi.cast('pulpo_opaque_t*', thread.opaque)
	local c = channel_list[opq.id]
	if c then return c end
	c = pipe.create_writer(opq.wfd:fd())
	channel_list[opq.id] = c
	return c
end
function _M.reader()
	local opq = thread.opaque(thread.me.opaque, "pulpo_opaque_t*")
	return opq.rfd
end

return _M

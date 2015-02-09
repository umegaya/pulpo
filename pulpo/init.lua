local ffi = require 'ffiex.init'
local C = ffi.C
local PT = C

--local boot = require 'pulpo.package'
--boot.DEBUG = true

local _M = {}
local log = (require 'pulpo.logger').initialize()
local term = require 'pulpo.terminal'
local logpfx = "[????] "
function _G.pulpo_assert(cond, msgobj)
	if not cond then
		log.fatal(msgobj)
		_G.error(msgobj, 0)
	end
	return cond
end
local thread = require 'pulpo.thread'
local memory = require 'pulpo.memory'
local poller = require 'pulpo.poller'
local tentacle = require 'pulpo.tentacle'
local event = require 'pulpo.event'
local util = require 'pulpo.util'
local gen = require 'pulpo.generics'
local socket = require 'pulpo.socket'
local fs = require 'pulpo.fs'
local exception = require 'pulpo.exception'

_M.poller = poller
_M.tentacle = tentacle
_M.fiber = tentacle -- alias
_M.event = event
_M.util = util
_M.shared_memory = thread.shared_memory

local function create_opaque(fn, group, opts)
	opts = opts or {}
	local r = memory.alloc_fill_typed('pulpo_opaque_t')
	-- generate unique seed
	r.id = _M.id_seed:write(function (data)
		data.cnt = data.cnt + 1
		return data.cnt
	end)
	r.noloop = (opts.noloop and 1 or 0)
	r.debug = (opts.debug and 1 or 0)
	r.group = memory.strdup(group)
	if fn then
		local proc = util.encode_proc(fn)
		r.proc = memory.strdup(proc)
		r.plen = #proc
	end
	if opts.init_proc then
		local init_proc = util.encode_proc(opts.init_proc)
		r.init_proc = memory.strdup(init_proc)
		r.init_plen = #init_proc
	end
	if opts.init_params then
		r.init_params = memory.strdup(opts.init_params)
	end
	return r
end

local function destroy_opaque(opq)
	memory.free(opq.group)
	memory.free(opq)
end

local function init_opaque(opts)
	local opaque = thread.opaque(thread.me, "pulpo_opaque_t*")
	if opaque == ffi.NULL then
		opaque = create_opaque(nil, "root", opts)
		thread.set_opaque(thread.me, opaque)
	end
	opaque.poller = _M.evloop.poller -- it is wrapped.
	_M.thread_id = opaque.id
	logpfx = util.sprintf("[%04x] ", 8, ffi.new('int', opaque.id))

	thread.register_exit_handler("pulpo.lua", function ()
		destroy_opaque(opaque)
	end)
	return opaque
end

local function init_cdef()
	ffi.cdef[[
		typedef struct pulpo_opaque {
			unsigned short id;
			unsigned char noloop, debug;
			unsigned char finished, padd[3];
			char *group;
			char *proc, *init_proc;
			char *init_params;
			size_t plen, init_plen;
			pulpo_poller_t *poller;
		} pulpo_opaque_t;
	]]
	-- necessary gen cdef
	gen.rwlock_ptr("int")
end

local function init_shared_memory()
	ffi.cdef[[
		typedef struct pulpo_thread_idseed {
			int cnt;
		} pulpo_thread_idseed_t;
	]]
	_M.id_seed = _M.shared_memory("__thread_id_seed__", gen.rwlock_ptr("pulpo_thread_idseed_t"))
	_M.logger_mutex = _M.shared_memory("__logger_mutex__", function ()
		local mutex = memory.alloc_typed('pthread_mutex_t')
		PT.pthread_mutex_init(mutex, nil)
		return 'pthread_mutex_t', mutex
	end)
end
local function config_logger(opts)
	ffi.cdef[[
		typedef struct pulpo_logger_data {
			bool verbose;
			char *logdir;
		} pulpo_logger_data_t;
	]]
	-- make default logger thread safe
	local ret = _M.shared_memory("__logger_conf__", function ()
		local o = memory.alloc_typed('pulpo_logger_data_t')
		o.verbose = opts.verbose and opts.verbose~="false" or false
		o.logdir = opts.logdir and memory.strdup(opts.logdir) or ffi.NULL
		return 'pulpo_logger_data_t', o
	end)
	_M.verbose = ret.verbose
	if ret.logdir ~= ffi.NULL then
		local logdir = ffi.string(ret.logdir).."/"..tostring(_M.thread_id)
		log.redirect("default", fs.new_file_logger(logdir, {
			prefix = logpfx,
		}))
		logger.info('logging start at', logdir)
	else
		log.redirect("default", function (setting, ...)
			PT.pthread_mutex_lock(_M.logger_mutex)
			term[setting.color]()
			io.write(("%s "):format(os.clock()))
			io.write(logpfx)
			io.write(setting.tag)
			print(...)
			term.resetcolor()
			io.stdout:flush()
			PT.pthread_mutex_unlock(_M.logger_mutex)
		end)
	end
	if _M.verbose then
		log.loglevel = 0
	end
end

local function create_thread(exec, group, arg, opts)
	return thread.create(function (arg)
		local ffi = require 'ffiex.init'
		local pulpo = require 'pulpo.init'
		local thread = require 'pulpo.thread'
		local util = require 'pulpo.util'
		local memory = require 'pulpo.memory'
		local opaque = pulpo.init_worker()
		local proc, err = util.decode_proc(ffi.string(opaque.proc, opaque.plen))
		if not proc then
			exception.raise('fatal', 'loading main proc fails', err)
		end
		if opaque.init_proc ~= ffi.NULL then
			local init_proc = util.decode_proc(ffi.string(opaque.init_proc, opaque.init_plen))
			local ok, r = pcall(init_proc, opaque.init_params ~= ffi.NULL and ffi.string(opaque.init_params))
			memory.free(opaque.init_proc)
			if opaque.init_params ~= ffi.NULL then
				memory.free(opaque.init_params)
			end
		end
		memory.free(opaque.proc)
		if opaque.noloop == 0 then
			pulpo.main(proc, arg, opaque)
			pulpo.evloop:loop()
			thread.fin_worker()
		else
			pcall(proc, arg)
		end
		return ffi.NULL -- indicate graceful stop (not equal to PTHREAD_CANCELED)
	end, arg or ffi.NULL, create_opaque(exec, group or "main", opts))
end

local function wrap_module(mod, p)
	return setmetatable({ mod = require(mod), __poller = p }, {
		__index = function (t, k)
			local v = assert(rawget(t.mod, k), "no such API:"..k.." of "..mod)
			local tmp = v
			if type(v) == 'function' then
				v = function (...)
					return tmp(t.__poller, ...)
				end
			end
			rawset(t, k, v)
			return v
		end
	})
end

local function err_handler(e)
	--logger.report('err', tostring(e))
	exception.raise('fatal', 'error on main proc', e)
end

function _M.main(proc, arg, opq)
	local pulpo = require 'pulpo.init'
	pulpo.tentacle(function (fn, a, fzr)
		local ok, r = xpcall(fn, err_handler, a)
		if not r then
			opq.finished = 1
			if _M.is_all_thread_finished() then
				_M.stop()
			end
		end
	end, proc, arg, finalizer)
end

function _M.wrap_poller(p)
	return setmetatable({
		poller = p,
		newio = function (t, ...)
			return t.poller.newio(t.poller, ...)
		end,
		loop = function (t)
			return t.poller.loop(t.poller)
		end,
		stop = function (t)
			t.poller.stop(t.poller)
		end,
		io = setmetatable({ __poller = p }, {
			__index = function (t, k)
				local v
				if k == "linda" then
					local linda = require 'pulpo.linda'
					v = {
						new = function (name, opts)
							return linda:channel(t.__poller, name, opts)
						end
					}
				elseif k == "poller" then
					local poller = require 'pulpo.io.poller'
					v = {
						new = function ()
							return _M.wrap_poller(poller.new(t.__poller))
						end
					}
				else
					v = wrap_module("pulpo.io."..k, t.__poller)
				end
				rawset(t, k, v)
				return v
			end,
		}),
	}, {
		__index = function (t, k)
			if k == "task" or k == "clock" then
				local v = wrap_module("pulpo.task", p)
				rawset(t, "task", v)
				local tmp = { new = v.newgroup }
				rawset(t, "clock", tmp)
				return k == "task" and v or tmp
			else
				error("no such method:"..k)				
			end
		end,
	})
end

-- only main thread call this.
function _M.initialize(opts)
	-- child thread may call pulpo.run, 
	-- but already initialized by init_worker.
	-- prevent re-initialize by this.
	if not _M.initialized then
		thread.initialize(opts)
		poller.initialize(opts)
		init_shared_memory()
		config_logger(opts)
		_M.evloop = _M.wrap_poller(poller.new())
		init_cdef()
		init_opaque(opts)
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

-- others initialized by this.
function _M.init_worker(tls)
	if not _M.initialized then
		poller.init_worker()
		init_shared_memory()
		config_logger()
		_M.evloop = _M.wrap_poller(poller.new())
		init_cdef()
		_M.initialized = true
	end

	return init_opaque()
end

function _M.run(opts, executable)
	opts = opts or {}
	_M.initialize(opts)

	local n_core = opts.n_core or util.n_cpu()
	_M.n_core = n_core
	if opts.exclusive then
		-- -1 for this thread (also run as worker)
		n_core = n_core - 1
	end
	for i=1,n_core,1 do
		create_thread(executable, opts.group, opts.arg, opts)
	end
	if opts.exclusive then
		local proc, err = util.create_proc(executable)
		if not proc then
			exception.raise('fatal', 'loading main proc fails', err)
		end
		if opts.noloop then
			pcall(proc, opts.arg)
		else
			local opq = thread.opaque(thread.me, "pulpo_opaque_t*")
			_M.main(proc, opts.arg, opq)
			_M.evloop:loop()
			thread.finalize()
		end
	end
end

function _M.find_thread(group_or_id_or_filter)
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
			local opq = thread.opaque(th, "pulpo_opaque_t*")
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

function _M.is_all_thread_finished()
	return thread.fetch(function (list, size)
		local finished = 0
		for i=0,size-1,1 do
			local th = list[i]
			local opq = thread.opaque(th, "pulpo_opaque_t*")
			if opq.finished ~= 0 then 
				-- logger.info('is_all_thread_finished', i+1, 'finished')
				finished = finished + 1
			else
				-- logger.info('is_all_thread_finished', i+1, 'not finished')
			end
		end
		return finished >= size
	end)
end

-- stop threads filtered with group or id or filter proc.
-- this function will not take care the case which the thread called this function, need to be stopped.
-- please check first retval and do graceful shutdown. (but if you do loop mode, it will do graceful shutdown instead of you)
function _M.stop(group_or_id_or_filter)
	local self_stopped, main_stopped
	local stoplist = _M.find_thread(group_or_id_or_filter)
	for _,th in ipairs(stoplist) do
		if th:main() then
			main_stopped = true
			local opq = thread.opaque(th, "pulpo_opaque_t*")
			-- if main thread stopped, and your main thread runs under pulpo's loop mode, all thread will die.
			opq.poller:stop()
			-- but if it does not, please check second argument and do proper shutdown.
			return self_stopped, main_stopped
		end
	end
	for _,th in ipairs(stoplist) do
		local opq = thread.opaque(th, "pulpo_opaque_t*")
		opq.poller:stop()
		local process_current_thread = thread.equal(th, thread.me)
		if process_current_thread then
			self_stopped = true
		end
		if not process_current_thread then
			local rv, canceled = thread.join(th)
			if canceled then thread.fin_worker(th) end
		end
	end
	return self_stopped, main_stopped
end

return _M

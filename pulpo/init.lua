local ffi = require 'ffiex'
local C = ffi.C
local PT = C

local _M = {}
local log = require 'pulpo.logger'
local term = require 'pulpo.terminal'
local logpfx = "[????] "
local function init_logger()
	log.initialize()
	log.redirect("default", function (setting, ...)
		term[setting.color]()
		io.write(logpfx)
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
local socket -- lazy module

_M.poller = poller
_M.tentacle = tentacle
_M.fiber = tentacle -- alias
_M.event = event
_M.util = util
_M.shared_memory = thread.shared_memory

local function create_opaque(fn, group, noloop)
	local r = memory.alloc_fill_typed('pulpo_opaque_t')
	-- generate unique seed
	r.id = _M.id_seed:write(function (data)
		data.cnt = data.cnt + 1
		if data.cnt > 65000 then data.cnt = 1 end
		return data.cnt
	end)
	r.noloop = (noloop and 1 or 0)
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

local function init_opaque()
	local opaque = thread.opaque(thread.me, "pulpo_opaque_t*")
	if opaque == ffi.NULL then
		opaque = create_opaque(nil, "root")
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
			unsigned char noloop, padd;
			char *group;
			char *proc;
			size_t plen;
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
end

local function init_lazy_module()
	_M.socket = require 'pulpo.socket'
end

local function create_thread(exec, group, arg, noloop)
	return thread.create(function (arg)
		local ffi = require 'ffiex'
		local pulpo = require 'pulpo.init'
		local util = require 'pulpo.util'
		local memory = require 'pulpo.memory'
		local opaque = pulpo.init_worker()
		local proc = util.decode_proc(ffi.string(opaque.proc, opaque.plen))
		_G.ffi = ffi
		_G.pulpo = pulpo
		memory.free(opaque.proc)
		if opaque.noloop == 0 then
			pulpo.tentacle(proc, arg)
			pulpo.evloop:loop()
		else
			proc(arg)
		end
	end, arg or ffi.NULL, create_opaque(exec, group or "main", noloop))
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
						new = function (name)
							return linda:channel(t.__poller, name)
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
		init_lazy_module()
		_M.evloop = _M.wrap_poller(poller.new())
		init_cdef()
		init_opaque()
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
		init_lazy_module()
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
	if opts.exclusive then
		-- -1 for this thread (also run as worker)
		n_core = n_core - 1
	end
	for i=1,n_core,1 do
		create_thread(executable, opts.group, opts.arg, opts.noloop)
	end
	if opts.exclusive then
		coroutine.wrap(util.create_proc(executable))(arg)
		_M.evloop:loop()
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
	for _,th in ipairs(_M.find_thread(group_or_id_or_filter)) do
		-- th.L == NULL => main thread
		if not th:main() then
			local opq = thread.opaque(th, "pulpo_opaque_t*")
			opq.poller:stop()
			thread.join(th)
		end
	end
end

return _M

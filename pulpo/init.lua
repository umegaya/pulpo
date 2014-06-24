local ffi = require 'ffiex'
local thread = require 'pulpo.thread'
local poller = require 'pulpo.poller'
local memory = require 'pulpo.memory'
local gen = require 'pulpo.generics'
local util = require 'pulpo.util'

local _M = {}

_M.thread = thread
_M.poller = poller
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
		_M.initialized = true
	end
end

function _M.init_share_memory()
	_M.share_memory("__thread_id_seed__", gen.rwlock_ptr("int"))
end

-- others initialized by this.
function _M.init_worker(tls)
	if not _M.initialized then
		poller.init_worker()
		_M.mainloop = poller.new()
		_M.init_cdef()
		_M.initialized = true
	end

	local opaque = thread.opaque(thread.me(), "pulpo_opaque_t*")
	opaque.poller = _M.mainloop	
	_M.tid = opaque.id
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
		} pulpo_opaque_t;
	]]
	-- necessary gen cdef
	gen.rwlock_ptr("int")
end

function create_opaque(fn, group)
	local r = memory.alloc_fill_typed('pulpo_opaque_t')
	r.id = _M.share_memory("__thread_id_seed__"):write(function (data) 
		data = data + 1
		if data > 65000 then data = 1 end
		return data
	end)
	r.group = memory.strdup(group)
	local proc = util.encode_proc(fn)
	r.proc = memory.strdup(proc)
	r.plen = #proc
	return r
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
				coroutine.wrap(proc)(arg)
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

return _M
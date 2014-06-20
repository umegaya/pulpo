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

ffi.cdef[[
	typedef pulpo_opaque {
		unsigned short id, padd;
		const char *group;
		pulpo_poller_t *poller;
	} pulpo_opaque_t;
]]

local idseed_t = gen.rwlock_ptr("int")

-- only main thread call this.
function _M.initialize(opts)
	if not _M.initialized then
		thread.initialize(opts)
		poller.initialize(opts)
		_M.share_memory("__thread_id_seed__", idseed_t)
		_M.mainloop = poller.new()
		_M.initialized = true
	end
end
-- others initialized by this.
function _M.init_worker(tls)
	poller.init_worker()
	_M.mainloop = poller.new()
	_M.tls = tls
	_M.tls.poller = _M.mainloop	
	thread.set_opaque(thread.me(), tls)
end

local function create_opaque(group)
	local r = memory.alloc_fill_typed('pulpo_opaque_t')
	r.id = _M.share_memory("__thread_id_seed__"):write(function (data) 
		data = data + 1
		return data
	end)
	r.group = memory.strdup(group)
	return r
end

function _M.run(opts, executable)
	_M.initialize(opts)

	local group = opts.group or "main"
	local arg = opts.arg or ffi.NULL
	local dump = _M.encode_proc(executable)
	pulpo.share_memory(util.proc_mem_name(group), function ()
		return "const char *", memory.strdup(dump)
	end)

	_M.n_core = opts.n_core or util.n_cpu()
	for i=0,_M.n_core - 1,1 do
		thread.create(function (arg)
			local pulpo = require 'pulpo'
			local opq = thread.opaque(thread.me(), "pulpo_opaque_t*")
			pulpo.init_worker(opq)

			local util = require 'pulpo.util'
			local proc_mem_name = util.proc_mem_name(ffi.string(opq.group))
			local code = ffi.string(pulpo.share_memory(proc_mem_name))
			local proc = util.decode_proc(code)
			coroutine.wrap(proc)(arg)
			pulpo.mainloop:start()
		end, arg, create_opaque(group))
	end
	coroutine.wrap(fn)(arg)
	pulpo.mainloop:start()
end

function _M.filter(group_or_id_or_filter)
	return thread.fetch(function (list, size)
		local matches = {}
		for i=0,size,1 do
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
--package.path=("../ffiex/?.lua;" .. package.path)
local ffi = require 'ffiex'
local memory = require 'pulpo.memory'
local loader = require 'pulpo.loader'
local errno = require 'pulpo.errno'
local util = require 'pulpo.util'
local gen = require 'pulpo.generics'
local fs = require 'pulpo.fs'

local _M = {}
local C = ffi.C
local PT = ffi.load('pthread')

-- cdefs
ffi.cdef [[
	typedef struct pulpo_thread_args_dummy {
		void *manager;
		void *cache;
		void *original;
	} pulpo_thread_args_dummy_t;
]]

function _M.init_cdef(cache)
	loader.initialize(cache)

	loader.load("pthread.lua", {
		--> from pthread
		"pthread_t", "pthread_mutex_t", "pthread_rwlock_t", 
		"pthread_mutex_lock", "pthread_mutex_unlock", 
		"pthread_mutex_init", "pthread_mutex_destroy",
		"pthread_rwlock_rdlock", "pthread_rwlock_wrlock", 
		"pthread_rwlock_unlock", 
		"pthread_rwlock_init", "pthread_rwlock_destroy", 
		"pthread_create", "pthread_join", "pthread_self",
		"pthread_equal", 
	}, {}, "pthread", [[
		#include <pthread.h>
	]])

	local ffi_state = loader.load("lua.lua", {
		--> from luauxlib, lualib
		"luaL_newstate", "luaL_openlibs",
		"luaL_loadstring", "lua_pcall", "lua_tolstring",
		"lua_getfield", "lua_tointeger",
		"lua_settop", "lua_close", 
	}, {
		"LUA_GLOBALSINDEX",
	}, nil, [[
		#include <lauxlib.h>
		#include <lualib.h>
	]])

	ffi.cdef [[
		typedef void *(*pulpo_thread_proc_t)(void *);
		typedef struct pulpo_thread_handle {
			pthread_t pt;
			lua_State *L;
			void *opaque;
		} pulpo_thread_handle_t;
		typedef struct pulpo_memblock {
			const char *name;
			const char *type;
			void *ptr;
		} pulpo_memblock_t;
	]]
	local shared_memory = gen.rwlock_ptr(gen.erastic_list('pulpo_memblock_t'))
	ffi.cdef (([[
		typedef struct pulpo_thread_manager {
			pulpo_thread_handle_t **list;
			int size, used;
			%s shared_memory;
			pthread_mutex_t mtx[1];
			pthread_mutex_t load_mtx[1];
		} pulpo_thread_manager_t;
		typedef struct pulpo_thread_args {
			pulpo_thread_manager_t *manager;
			pulpo_parsed_info_t *cache;
			void *original;
		} pulpo_thread_args_t;
	]]):format(shared_memory))

	_M.defs = {
		LUA_GLOBALSINDEX = ffi_state.defs.LUA_GLOBALSINDEX
	}

	--> metatype
	ffi.metatype("pulpo_thread_manager_t", {
		__index = {
			init = function (t)
				t.size, t.used = tonumber(util.n_cpu()), 0
				t.list = assert(memory.alloc_typed("pulpo_thread_handle_t*", t.size), 
					"fail to allocate thread list")
				t.shared_memory:init(function (data) data:init(16) end)
				PT.pthread_mutex_init(t.mtx, nil)
				PT.pthread_mutex_init(t.load_mtx, nil)
			end,
			fin = function (t)
				if t.list then
					for i=0,t.used-1,1 do
						local th = t.list[i]
						_M.destroy(th, true)
					end
					memory.free(t.list)
				end
				PT.pthread_mutex_destroy(t.mtx)
				PT.pthread_mutex_destroy(t.load_mtx)
				t.shared_memory:fin(function (data) data:fin() end)
			end,
			insert = function (t, thread)
				PT.pthread_mutex_lock(t.mtx)
				if t.size <= t.used then
					t:expand(t.size * 2)
					if t.size <= t.used then
						return nil
					end
				end
				t.list[t.used] = thread
				t.used = (t.used + 1)
				PT.pthread_mutex_unlock(t.mtx)
				return t.used		
			end,
			remove = function (t, thread)
				PT.pthread_mutex_lock(t.mtx)
				local found = false
				for i=0,t.used-1,1 do
					if (not found) and PT.pthread_equal(t.list[i].pt, thread.pt) ~= 0 then
						found = true
					else
						t.list[i - 1] = t.list[i]
					end
				end
				t.list[t.used - 1] = nil
				t.used = (t.used - 1)
				PT.pthread_mutex_unlock(t.mtx)			
			end,
			find = function (t, id)
				local found
				PT.pthread_mutex_lock(t.mtx)
				for i=0,t.used-1,1 do
					if PT.pthread_equal(t.list[i].pt, id) ~= 0 then
						found = t.list[i]
						break
					end
				end
				PT.pthread_mutex_unlock(t.mtx)						
				return found
			end,
			fetch = function (t, f)
				PT.pthread_mutex_lock(t.mtx)
				local r = f(t.list, t.used)
				PT.pthread_mutex_unlock(t.mtx)
				return r
			end,
			expand = function (t, newsize)
				-- only called from mutex locked bloc
				local p = memory.realloc_typed("pulpo_thread_handle_t", newsize)
				if p then
					t.list = p
					t.size = newsize
				else
					print('expand thread list fails:'..newsize)
				end
				return p
			end,
			share_memory = function (t, _name, _init)
				return t.shared_memory:write(function (data, name, init)
					data:reserve(1) -- at least 1 entry room
					local e
					for i=0,data.used-1,1 do
						e = data.list[i]
						if ffi.string(e.name) == name then
							-- print('returns', name, e.type, e.ptr)
							return ffi.cast(ffi.string(e.type), e.ptr)
						end
					end
					if not init then
						error("no attempt to initialize but not found:"..name)
					end
					e = data.list[data.used]
					e.name = memory.strdup(name)
					if type(init) == "string" then
						e.type, e.ptr = init, memory.alloc_fill_typed(init)
					elseif type(init) == "function" then
						e.type, e.ptr = init()
					else
						assert(false, "no initializer:"..type(init))
					end
					data.used = (data.used + 1)
					return ffi.cast(ffi.string(e.type), e.ptr)
				end, _name, _init)
			end,
		}
	})
end


-- variables
local threads


-- methods
-- initialize thread module. created threads are initialized with manager
function _M.initialize(opts)
	_M.apply_options(opts or {})
	_M.init_cdef()
	threads = memory.alloc_typed("pulpo_thread_manager_t")
	threads:init()
	_M.main = true
end
function _M.apply_options(opts)
	_M.opts = opts
	if opts.cdef_cache_dir then
		util.mkdir(opts.cdef_cache_dir)
		loader.set_cache_dir(opts.cdef_cache_dir)
	end
end

function _M.init_worker(manager, cache)
	assert(manager)
	_M.init_cdef(ffi.cast("pulpo_parsed_info_t*", cache))
	threads = ffi.cast("pulpo_thread_manager_t*", manager)
	-- wait for this thread appears in global thread list
	local cnt = 10
	while not threads:find(C.pthread_self()) and (cnt > 0) do
		thread.sleep(0.1)
		cnt = cnt - 1
	end
	assert(cnt > 0, "thread initialization timeout")
end

function _M.load(name, cdecls, macros, lib, from)
	PT.pthread_mutex_lock(threads.load_mtx)
	local ret = {loader.load(name, cdecls, macros, lib, from)}
	PT.pthread_mutex_unlock(threads.load_mtx)	
	return unpack(ret)
end

-- finalize. no need to call from worker
function _M.fin()
	if threads then
		threads:fin()
		memory.free(threads)
		loader.finalize()
	end
end

-- create thread. args must be cast-able as void *.
function _M.create(proc, args, opaque)
	local L = C.luaL_newstate()
	assert(L ~= nil)
	C.luaL_openlibs(L)
	local r
	r = C.luaL_loadstring(L, ([[
	local thread = require("pulpo.thread")
	local main = load(%q)
	local mainloop = function (p)
		local args = ffi.cast("pulpo_thread_args_dummy_t*", p)
		thread.init_worker(args.manager, args.cache)
		return main(args.original)
	end
	__mainloop__ = tonumber(ffi.cast("intptr_t", ffi.cast("void *(*)(void *)", mainloop)))
	]]):format(string.dump(proc)))
	if r ~= 0 then
		assert(false, "luaL_loadstring:" .. tostring(r) .. "|" .. ffi.string(C.lua_tolstring(L, -1, nil)))
	end
	r = C.lua_pcall(L, 0, 1, 0)
	if r ~= 0 then
		assert(false, "lua_pcall:" .. tostring(r) .. "|" .. ffi.string(C.lua_tolstring(L, -1, nil)))
	end

	C.lua_getfield(L, _M.defs.LUA_GLOBALSINDEX, "__mainloop__")
	local mainloop = C.lua_tointeger(L, -1)
	C.lua_settop(L, -2)

	local th = memory.alloc_typed("pulpo_thread_handle_t")
	local t = ffi.new("pthread_t[1]")
	local argp = ffi.new("pulpo_thread_args_t", {threads, loader.get_cache_ptr(), args})
	th.L = L
	th.opaque = opaque
	assert(PT.pthread_create(t, nil, ffi.cast("pulpo_thread_proc_t", mainloop), argp) == 0)
	th.pt = t[0]
	return threads:insert(th) and th or nil
end

-- destroy thread.
function _M.destroy(thread, on_finalize)
	local rv = ffi.new("void*[1]")
	PT.pthread_join(thread.pt, rv)
	C.lua_close(thread.L)
	if not on_finalize then
		threads:remove(thread)
	end
	memory.free(thread)
	return rv[0]
end
_M.join = _M.destroy

-- get current thread handle
function _M.me()
	local pt = PT.pthread_self()
	return threads:find(pt)
end

-- check 2 thread handles (pthread_t) are same 
function _M.equal(t1, t2)
	return PT.pthread_equal(t1.pt, t2.pt) ~= 0
end

-- set pointer related with specified thread
function _M.set_opaque(thread, p)
	assert(_M.equal(_M.me(), thread), "different thread should not change opaque ptr")
	thread.opaque = p
end
function _M.opaque(thread, ct)
	local p = thread.opaque
	return (ct and p ~= ffi.NULL) and ffi.cast(ct, p) or nil
end

-- global share memory
function _M.share_memory(k, v)
	return threads:share_memory(k, v)
end

-- iterate all current thread
function _M.fetch(fn)
	return threads:fetch(fn)
end

-- nanosleep
function _M.sleep(sec)
	util.sleep(sec)
end

return _M

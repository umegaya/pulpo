--package.path=("../ffiex/?.lua;" .. package.path)
local ffi = require 'ffiex'
local parser = require 'ffiex.parser'
local memory = require 'pulpo.memory'
local loader = require 'pulpo.loader'
local errno = require 'pulpo.errno'
local signal = require 'pulpo.signal'
local util = require 'pulpo.util'
local gen = require 'pulpo.generics'
local shmem = require 'pulpo.shmem'
local fs = require 'pulpo.fs'
local log = require 'pulpo.logger'
log.initialize()
if not _G.pulpo_assert then
	_G.pulpo_assert = assert
end

local _M = {}
local C = ffi.C
local PT = ffi.load('pthread')

-- cdefs
ffi.cdef [[
	typedef struct pulpo_thread_args_dummy {
		void *manager;
		void *cache;
		void *shmem;
		void *handle;
		char *initial_cdecl;
		void *original;
	} pulpo_thread_args_dummy_t;
]]

local LUA_GLOBALSINDEX

function _M.init_cdef(cache)
	ffi.path "/usr/local/include/luajit-2.0"

	loader.initialize(cache, ffi.main_ffi_state)

	loader.load("pthread.lua", {
		--> from pthread
		"pthread_t", "pthread_mutex_t", 
		"pthread_mutex_lock", "pthread_mutex_unlock", 
		"pthread_mutex_init", "pthread_mutex_destroy",
		"pthread_create", "pthread_join", "pthread_self",
		"pthread_equal", 
	}, {}, "pthread", [[
		#include <pthread.h>
	]])

	if not cache then
		shmem.initialize()
	end

	loader.load("lua.lua", {
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

	LUA_GLOBALSINDEX = loader.ffi_state.defs.LUA_GLOBALSINDEX

	ffi.cdef [[
		typedef void *(*pulpo_thread_proc_t)(void *);
		typedef void (*pulpo_exit_handler_t)(void);
		typedef struct pulpo_thread_handle {
			pthread_t pt;
			lua_State *L;
			void *opaque;
		} pulpo_thread_handle_t;
		typedef struct pulpo_thread_manager {
			pulpo_thread_handle_t **list;
			int size, used;
			pthread_mutex_t mtx[1];
			pulpo_shmem_t shared_memory[1];
			char *initial_cdecl;
		} pulpo_thread_manager_t;
		typedef struct pulpo_thread_args {
			pulpo_thread_manager_t *manager;
			pulpo_parsed_info_t *cache;
			pulpo_shmem_t *shmem;
			pulpo_thread_handle_t *handle;
			char *initial_cdecl;
			void *original;
		} pulpo_thread_args_t;
	]]

	local INITIAL_REQUIRED_CDECL = {
		"pthread_mutex_t", "pthread_mutex_lock", "pthread_mutex_unlock"
	}

	--> metatype
	ffi.metatype("pulpo_thread_handle_t", {
		__index = {
			main = function (t) return t.L == ffi.NULL end,
		}
	})
	ffi.metatype("pulpo_thread_manager_t", {
		__index = {
			init = function (t)
				t.size, t.used = tonumber(util.n_cpu()), 0
				pulpo_assert(t.size > 0)
				t.list = pulpo_assert(memory.alloc_typed("pulpo_thread_handle_t*", t.size), 
					"fail to allocate thread list")
				assert(0 == PT.pthread_mutex_init(t.mtx, nil), "mutex_init fail:"..ffi.errno())
				t.shared_memory[0]:init()
				t.initial_cdecl = memory.strdup(
					parser.inject(ffi.main_ffi_state.tree, INITIAL_REQUIRED_CDECL)
				)
			end,
			fin = function (t)
				if t.list ~= ffi.NULL then
					for i=0,t.used-1,1 do
						local th = t.list[i]
						_M.destroy(th, true)
					end
					memory.free(t.list)
				end
				if t.initial_cdecl ~= ffi.NULL then
					memory.free(t.initial_cdecl)
				end
				PT.pthread_mutex_destroy(t.mtx)
				t.shared_memory[0]:fin()
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
					if not found then 
						if PT.pthread_equal(t.list[i].pt, thread.pt) ~= 0 then
							found = true
						end
					else
						t.list[i - 1] = t.list[i]
					end
				end
				if found then
					t.list[t.used - 1] = nil
					t.used = (t.used - 1)
				end
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
				local p = memory.realloc_typed("pulpo_thread_handle_t*", t.list, newsize)
				if p then
					t.list = p
					t.size = newsize
				else
					logger.error('expand thread list fails:'..newsize)
				end
				return p
			end,
			share_memory = function (t, name, init)
				return t.shared_memory[0]:find_or_init(name, init)
			end,
		}
	})
end

-- variables
local threads

-- main thread only, apply global option to module
local function apply_options(opts)
	_M.opts = opts
	if opts.cdef_cache_dir then
		util.mkdir(opts.cdef_cache_dir)
		loader.set_cache_dir(opts.cdef_cache_dir)
	end
end

-- TODO : initialize & init_worker's initialization order is really complex (even messy)
-- mainly because loader require pthread_mutex_* symbols, but these symbols are also required loader.
-- main thread only can initialize loader's mutex after init_cdef() finished, because we can assume any other
-- thread is not exist before pulpo's initialization is done.

-- initialize thread module. created threads are initialized with manager
function _M.initialize(opts)
	apply_options(opts or {})
	_M.init_cdef()
	threads = memory.alloc_typed("pulpo_thread_manager_t")
	threads:init()
	-- initialize pseudo thread handle of main thread
	_M.me = memory.alloc_fill_typed("pulpo_thread_handle_t")
	_M.me.pt = C.pthread_self()
	threads:insert(_M.me)
	-- initialize mutex lock for cdef loader
	loader.init_mutex(ffi.cast("pulpo_shmem_t*", threads.shared_memory))
	_M.main = true
end

function _M.init_worker(args)
	pulpo_assert(args)
	-- initialize pthread_mutex_*
	ffi.cdef(ffi.string(args.initial_cdecl))
	-- initialize pulpo_shmem_t (depends on pthread_mutex_*)
	shmem.initialize() 
	-- add mutex to loader module. now loader.load thread safe.
	loader.init_mutex(ffi.cast("pulpo_shmem_t*", args.shmem))
	_M.init_cdef(ffi.cast("pulpo_parsed_info_t*", args.cache))
	threads = ffi.cast("pulpo_thread_manager_t*", args.manager)
	-- initialize current thread handle
	_M.me = ffi.cast("pulpo_thread_handle_t*", args.handle)
	-- wait for this thread appears in global thread list
	local cnt = 100
	while not threads:find(PT.pthread_self()) and (cnt > 0) do
		thread.sleep(0.01)
		cnt = cnt - 1
	end
	pulpo_assert(cnt > 0, "thread initialization timeout")
end

-- global finalize. no need to call from worker
function _M.finalize()
	if _M.main and threads then
		_M.fin_worker()
		threads:fin()
		memory.free(threads)
		loader.finalize()
	end
end
-- release thread local resources. each worker need to call this
function _M.fin_worker(thread, on_finalize)
	thread = thread or _M.me
	local self_finalize = (thread == _M.me)
	if self_finalize then
		_M.at_exit()
	else
		-- clean up lua state (including manually allocated memory)
		C.lua_getfield(thread.L, LUA_GLOBALSINDEX, "__at_exit__")
		local at_exit = ffi.cast("pulpo_exit_handler_t", C.lua_tointeger(thread.L, -1))
		at_exit()
		C.lua_close(thread.L)
	end
	-- if run time destruction, remove this thread from list
	if not on_finalize then
		-- because all thread memory is freed after that
		threads:remove(thread)
	end
	memory.free(thread)
end

-- create thread. args must be cast-able as void *.
-- TODO : more graceful error handling (now only assert)
function _M.create(proc, args, opaque, debug)
	local th = memory.alloc_typed("pulpo_thread_handle_t")
	local L = C.luaL_newstate()
	pulpo_assert(L ~= nil)
	C.luaL_openlibs(L)
	local r = C.luaL_loadstring(L, ([[
	_G.DEBUG = %s
	local ffi = require 'ffiex'
	local thread = require 'pulpo.thread'
	local memory = require 'pulpo.memory'
	local main = loadstring(%q, '%s')
	local mainloop = function (p)
		local args = ffi.cast("pulpo_thread_args_dummy_t*", p)
		local original = args.original
		thread.init_worker(args)
		memory.free(args)
		local ok, r = pcall(main, original)
		if not ok then print('thread abort by error:', r) end
		return ok and r or ffi.NULL
	end
	__mainloop__ = tonumber(ffi.cast("intptr_t", ffi.cast("void *(*)(void *)", mainloop)))
	__at_exit__ = tonumber(ffi.cast("intptr_t", ffi.cast("void (*)(void)", thread.at_exit)))
	]]):format(
		debug and "true" or "false", 
		string.dump(proc), 
		util.sprintf("%08x", 16, th)
	))
	if r ~= 0 then
		pulpo_assert(false, "luaL_loadstring:" .. tostring(r) .. "|" .. ffi.string(C.lua_tolstring(L, -1, nil)))
	end
	r = C.lua_pcall(L, 0, 1, 0)
	if r ~= 0 then
		pulpo_assert(false, "lua_pcall:" .. tostring(r) .. "|" .. ffi.string(C.lua_tolstring(L, -1, nil)))
	end

	C.lua_getfield(L, LUA_GLOBALSINDEX, "__mainloop__")
	local mainloop = C.lua_tointeger(L, -1)
	C.lua_settop(L, -2)

	local t = ffi.new("pthread_t[1]")
	local argp = memory.alloc_typed("pulpo_thread_args_t")
	argp.manager = threads
	argp.cache = loader.get_cache_ptr()
	argp.shmem = threads.shared_memory
	argp.handle = th
	argp.initial_cdecl = threads.initial_cdecl
	argp.original = args
	th.L = L
	th.opaque = opaque
	pulpo_assert(PT.pthread_create(t, nil, ffi.cast("pulpo_thread_proc_t", mainloop), argp) == 0)
	th.pt = t[0]
	return threads:insert(th) and th or nil
end

-- destroy thread.
_M.exit_handler = {}
function _M.register_exit_handler(fn)
	table.insert(_M.exit_handler, fn)
end
function _M.at_exit()
	--print('at_exit')
	--print('at_exit', #_M.exit_handler)
	for i=#_M.exit_handler,1,-1 do
		---print('at_exit', i)
		_M.exit_handler[i]()
	end
	-- print('at_exit end')
end
function _M.join(thread, on_finalize)
	local rv = ffi.new("void*[1]")
	PT.pthread_join(thread.pt, rv)
	_M.fin_worker(thread, on_finalize)
	return rv[0]
end
_M.destroy = _M.join

-- check 2 thread handles (pthread_t) are same 
function _M.equal(t1, t2)
	return PT.pthread_equal(t1.pt, t2.pt) ~= 0
end

-- get/set pointer related with specified thread
function _M.opaque(thread, ct)
	local p = thread.opaque
	return (ct and p ~= ffi.NULL) and ffi.cast(ct, p) or nil
end
function _M.set_opaque(thread, p)
	pulpo_assert(_M.equal(_M.me, thread), "different thread should not change opaque ptr")
	thread.opaque = p
end

-- global share memory
function _M.share_memory(k, v)
	return threads:share_memory(k, v)
end

-- iterate all thread in this process
function _M.fetch(fn)
	return threads:fetch(fn)
end

-- nanosleep
function _M.sleep(sec)
	util.sleep(sec)
end

return _M

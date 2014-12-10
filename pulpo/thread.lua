--package.path=("../ffiex/?.lua;" .. package.path)
local ffi = require 'ffiex.init'
local parser = require 'ffiex.parser'

local memory = require 'pulpo.memory'
local util = require 'pulpo.util'
local exception = require 'pulpo.exception'
local log = (require 'pulpo.logger').initialize()
local gen = require 'pulpo.generics'
local loader = require 'pulpo.loader'
local signal = require 'pulpo.signal'
local errno = require 'pulpo.errno'
local runlv = require 'pulpo.runlv'
local raise = exception.raise
if not _G.pulpo_assert then
	_G.pulpo_assert = assert
end

local boot = require 'pulpo.package'
local require_on_boot = boot.require
local lock = require_on_boot 'pulpo.lock'
local shmem = require_on_boot 'pulpo.shmem'

local _M = {}
local C = ffi.C
local PT = C
local ffi_state

-- exception
exception.define('pthread')
exception.define('lua', {
	message = function (t)
		return ("%s:%d:%s"):format(t.args[1], t.args[2], C.lua_tolstring(t.args[3], -1, nil))
	end,
})

local function call_pthread(ret, ...)
	if ret ~= 0 then
		raise("pthread", ...)
	end
end
local function call_lua(ret, L, func)
	if ret ~= 0 then
		raise("lua", func, ret, L)
	end
end

-- cdefs
ffi.cdef [[
	typedef struct pulpo_thread_args_dummy {
		void *shmem;
		void *handle;
		void *mutex;
		char *bootstrap_cdefs;
		void *original;
	} pulpo_thread_args_dummy_t;
]]

local LUA_GLOBALSINDEX
local PTHREAD_CANCELED

function _M.init_cdef(cache)
	ffi.path(util.luajit_include_path())

	ffi_state = loader.load("pthread.lua", {
		--> from pthread
		"pthread_t", "pthread_mutex_t", 
		"pthread_mutex_lock", "pthread_mutex_unlock", 
		"pthread_mutex_init", "pthread_mutex_destroy",
		"pthread_create", "pthread_join", "pthread_self",
		"pthread_key_create", "pthread_setspecific", "pthread_getspecific", 
		"pthread_equal", 
	}, {}, _M.PTHREAD_LIB_NAME, [[
		#include <pthread.h>
	]])

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
	-- currently, ffiex cannot parse macro definition with cast operator.
	PTHREAD_CANCELED = ffi.cast('void *', ffi.new('char*') + 1)
	-- print(PTHREAD_CANCELED)

	ffi.cdef [[
		typedef struct pulpo_tls {
			pthread_key_t key[1];
		} pulpo_tls_t;
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
			char *initial_cdecl;
		} pulpo_thread_manager_t;
		typedef struct pulpo_thread_args {
			pulpo_shmem_t *shmem;
			pulpo_thread_handle_t *handle;
			pthread_mutex_t *mutex;
			char *bootstrap_cdefs;
			void *original;
		} pulpo_thread_args_t;
	]]

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
				t.list = memory.alloc_typed("pulpo_thread_handle_t*", t.size)
				if t.list == ffi.NULL then
					raise("malloc", "pulpo_thread_handle_t*", t.size)
				end
				call_pthread(PT.pthread_mutex_init(t.mtx, nil), "mutex_init fail", ffi.errno())
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
					if found then 
						t.list[i - 1] = t.list[i]
					elseif PT.pthread_equal(t.list[i].pt, thread.pt) ~= 0 then
						found = true
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
		}
	})
	ffi.cdef(([[
		typedef struct pulpo_tls_list {
			%s list;
		} pulpo_tls_list_t;
	]]):format(gen.rwlock_ptr(gen.erastic_map('pulpo_tls_t'))))
	local cachelist = {}
	ffi.metatype('pulpo_tls_list_t', {
		__index = function (t, k)
			local ck = tostring(t)
			local cache = cachelist[ck]
			if not cache then
				cache = {}
				cachelist[ck] = cache
			end
			local v = cache[k]
			if not v then
				v = t.list:read(function (data)
					return data:get(k)
				end)
				rawset(cache, k, v)
			end
			return v and PT.pthread_getspecific(v.key[0]) or nil
		end,
		__newindex = function (t, k, v)
			return t.list:write(function (data, name, value)
				local elem = data:put(k, function (e)
					call_pthread(PT.pthread_key_create(e.data.key, nil), "key_create", ffi.errno())
				end)
				call_pthread(PT.pthread_setspecific(elem.key[0], value), "setspecific", ffi.errno())
				return elem
			end, k, v)
		end,
	})
end

-- variables
local _threads
local _shared_memory

-- TODO : initialize & init_worker's initialization order is really complex (even messy)
local function setup_shmem_args(shmemp)
	loader.cache_dir = ffi.string(shmemp:find_or_init('cache_dir', function ()
		return 'char', memory.strdup(loader.cache_dir)
	end))
	loader.cache = shmemp:find_or_init('cache', function ()
		return 'pulpo_parsed_info_t', loader.cache
	end)
	loader.load_mutex = shmemp:find_or_init('cdef_load_mutex', function ()
		local mutex = memory.alloc_typed('pthread_mutex_t')
		PT.pthread_mutex_init(mutex, nil)
		return 'pthread_mutex_t', mutex
	end)
	_M.init_cdef()
	_threads = shmemp:find_or_init('threads', function ()
		local thmgr = memory.alloc_typed("pulpo_thread_manager_t")
		thmgr:init()
		return 'pulpo_thread_manager_t', thmgr
	end)
	_M.tls = shmemp:find_or_init('tls', function ()
		-- pulpo_tls_list_t is already initialized init_cdef (above)
		local tlses = memory.alloc_typed('pulpo_tls_list_t')
		tlses.list:init(function (data) data:init() end)
		return "pulpo_tls_list_t", tlses
	end)
end
function _M.initialize(opts)
	opts = opts or { cache_dir = "/tmp/pulpo" }
	-- create common cache dir
	util.mkdir(opts.cache_dir)
	-- initialize loader and its cache directory.
	-- boot.init_modules(runlv.LOADER)
	loader.initialize(opts, ffi.main_ffi_state)
	-- load and init lock module
	boot.init_modules(runlv.GLOBAL_LOCK)
	lock.initialize()
	-- load and init shared memory module
	boot.init_modules(runlv.SHARED_MEMORY)
	_shared_memory = memory.alloc_typed('pulpo_shmem_t')
	_shared_memory[0]:init()
	-- pick (or init) all necessary shared memory object from loader and lock module
	-- after that, loader.load can be callable with thread safety
	setup_shmem_args(_shared_memory)
	-- load syscall on-boot modules
	boot.init_modules(runlv.SYSCALLS)
	-- initialize pseudo thread handle of main thread
	_M.me = memory.alloc_fill_typed("pulpo_thread_handle_t")
	_M.me.pt = C.pthread_self()
	_threads:insert(_M.me)
end
function _M.init_worker(arg)
	-- load loader (only ffi_state and flags) / lock
	-- then initialize shared memory (after that, all module can get shared pointer through it)
	boot.init_modules(runlv.GLOBAL_LOCK)
	lock.init_worker(arg.mutex, arg.bootstrap_cdefs)
	loader.init_worker(ffi.main_ffi_state)
	-- load and init shared memory module
	boot.init_modules(runlv.SHARED_MEMORY)
	_shared_memory = ffi.cast('pulpo_shmem_t*', arg.shmem)
	-- pick (or init) all necessary shared memory object from loader and lock module
	-- after that, loader.load can be callable with thread safety
	setup_shmem_args(_shared_memory)
	-- load syscall on-boot modules
	boot.init_modules(runlv.SYSCALLS)
	-- initialize current thread handles
	_M.me = ffi.cast("pulpo_thread_handle_t*", arg.handle)
	-- wait for thread appears in global list
	local cnt = 100
	while not _threads:find(PT.pthread_self()) and (cnt > 0) do
		_thread.sleep(0.01)
		cnt = cnt - 1
	end
	pulpo_assert(cnt > 0, "thread initialization timeout")
end

-- global finalize. no need to call from worker
function _M.finalize()
	if _M.main and _threads then
		_M.fin_worker()
		_threads:fin()
		memory.free(_threads)
		loader.finalize()
		lock.finalize()
		shmem.finalize()
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
		_threads:remove(thread)
	end
	memory.free(thread)
end

local function export_cmdl_args()
	local tmp = "{"
	if _G.arg then
		for _,s in ipairs(_G.arg) do
			tmp = (tmp .. ("'%q',"):format(s))
		end
	end
	return tmp.."}"
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
	local ffi = require 'ffiex.init'
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
	_G.arg = %s
	]]):format(
		debug and "true" or "false", 
		string.dump(proc), 
		util.sprintf("%08x", 16, th),
		export_cmdl_args()
	))
	if r ~= 0 then
		call_lua(r, L, "luaL_loadstring")
	end
	call_lua(C.lua_pcall(L, 0, 1, 0), L, "lua_pcall")

	C.lua_getfield(L, LUA_GLOBALSINDEX, "__mainloop__")
	local mainloop = C.lua_tointeger(L, -1)
	C.lua_settop(L, -2)

	local t = ffi.new("pthread_t[1]")
	local argp = memory.alloc_typed("pulpo_thread_args_t")
	argp.shmem = _shared_memory
	argp.handle = th
	argp.bootstrap_cdefs = lock.bootstrap_cdefs
	argp.mutex = lock.load_mutex
	argp.original = args
	th.L = L
	th.opaque = opaque
	pulpo_assert(PT.pthread_create(t, nil, ffi.cast("pulpo_thread_proc_t", mainloop), argp) == 0)
	th.pt = t[0]
	return _threads:insert(th) and th or nil
end

-- destroy thread.
_M.exit_handler = {}
function _M.register_exit_handler(name, fn)
	table.insert(_M.exit_handler, {name, fn})
end
function _M.at_exit()
	--print('at_exit')
	--print('at_exit', #_M.exit_handler)
	for i=#_M.exit_handler,1,-1 do
		-- print('at_exit', _M.exit_handler[i][1])
		_M.exit_handler[i][2]()
	end
	-- print('at_exit end')
end
function _M.join(thread)
	local rv = ffi.new("void*[1]")
	PT.pthread_join(thread.pt, rv)
	return rv[0], rv[0] == PTHREAD_CANCELED
end
function _M.destroy(thread, on_finalize)
	local rv, cancel = _M.join(thread)
	_M.fin_worker(thread, on_finalize)
	return rv
end

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
function _M.shared_memory(k, v)
	if v then
		return _shared_memory:find_or_init(k, v)
	else
		return _shared_memory:delete(k)
	end
end
function _M.lock_shared_memory(k, proc, ...)
	return _shared_memory:touch(k, function (data, fn, ...)
		return fn(data.ptr, ...)
	end, proc, ...)
end

-- iterate all thread in this process
function _M.fetch(fn)
	return _threads:fetch(fn)
end

-- nanosleep
function _M.sleep(sec)
	util.sleep(sec)
end

return _M

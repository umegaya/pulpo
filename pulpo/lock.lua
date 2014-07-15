local ffi = require 'ffiex'
local loader = require 'pulpo.loader'
local memory = require 'pulpo.memory'

local _M = {}
local C = ffi.C
local ffi_state
local PT = C

-- local DISPATCH_TIME_FOREVER -- for OSX

local function guard_clib_loader(mutex)
	if not mutex then
		mutex = memory.alloc_typed('pthread_mutex_t')
		PT.pthread_mutex_init(mutex, nil)
	end
	_M.load_mutex = mutex
	ffi.original_load = ffi.load
	ffi.load = function (name)
		PT.pthread_mutex_lock(_M.load_mutex)
		local ok, r = pcall(ffi.original_load, name)
		PT.pthread_mutex_unlock(_M.load_mutex)
		if not ok then 
			logger.error('fail to load:', name, r)
			error(r) 
		end
		return r
	end
end

--[[
local function initialize_sem_func()
	if ffi.os == "Linux" then
		function _M.sem_init()
			local sem = ffi.new('pulpo_sem_t[1]')
			assert(C.sem_init(sem, 0, 1) ~= -1, "sem_init error:"..ffi.errno())
		end
		function _M.sem_wait(sem)
			assert(0 == C.sem_wait(sem), "error sem_wait:"..ffi.errno())
		end
		function _M.sem_post(sem)
			assert(0 == C.sem_post(sem), "error sem_post:"..ffi.errno())
		end
		function _M.sem_destroy(sem)
			if 0 ~= C.sem_destroy(sem) then
				logger.error("error sem_destroy:"..ffi.errno())
			end
		end
	elseif ffi.os == "OSX" then
		function _M.sem_init()
			local sem = C.dispatch_semaphore_create(1)	
			assert(sem ~= ffi.NULL, "sem_init error:"..ffi.errno())
			return sem
		end
		function _M.sem_wait(sem)
			assert(0 == C.dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER), "error sem_wait:"..ffi.errno())
		end
		function _M.sem_post(sem)
			assert(0 == C.dispatch_semaphore_signal(sem), "error sem_post:"..ffi.errno())
		end
		function _M.sem_destroy(sem)
			C.dispatch_release(sem)
		end
	else
		assert(false, "unsupported OS:"..ffi.os)
	end		
end
]]

-- module function
function _M.initialize(opts)
	-- here loader is not guarded for multithread. but its ok
	-- because it called from first thread, where no other thread exist yet.
	--[=[
	if ffi.os == "Linux" then
		ffi_state = loader.load('semaphore.lua', {
			'sem_init', 'sem_wait', 'sem_post', 'sem_destroy',
			'pulpo_sem_t',
		}, {}, nil, [[
			#include <semaphore.h>
			typedef sem_t *pulpo_sem_t;
		]])
	elseif ffi.os == "OSX" then
		ffi_state = loader.load('semaphore.lua', {
			'dispatch_semaphore_create', 'dispatch_release', 
			'dispatch_semaphore_wait', 'dispatch_semaphore_signal',
			'dispatch_time',
			'pulpo_sem_t',
		}, {
			"DISPATCH_TIME_FOREVER", "DISPATCH_TIME_NOW", 
		}, nil, [[
			#include <dispatch/dispatch.h>
			typedef dispatch_semaphore_t pulpo_sem_t;
		]])
		DISPATCH_TIME_FOREVER = ffi.new('unsigned long long int', ffi.defs.DISPATCH_TIME_FOREVER)
		DISPATCH_TIME_NOW = ffi.new('unsigned long long int', ffi.defs.DISPATCH_TIME_NOW)
	else
		assert(false, "unsupported OS:"..ffi.os)
	end	
	initialize_sem_func()
	_M.sem = _M.sem_init()
	]=]

	loader.load('lock.lua', {
		"pthread_rwlock_t", 
		"pthread_rwlock_rdlock", "pthread_rwlock_wrlock", 
		"pthread_rwlock_unlock", 
		"pthread_rwlock_init", "pthread_rwlock_destroy", 
		"pthread_mutex_t",
		"pthread_mutex_lock", "pthread_mutex_unlock",
		"pthread_mutex_init", "pthread_mutex_destroy",
	}, {}, nil, [[
		#include <pthread.h>
	]]) 

	guard_clib_loader()

	_M.bootstrap_cdefs = memory.strdup(
		loader.find_as_string('lock.lua')
	)
end

function _M.finalize()
	if _M.load_mutex then
		_M.pthread_mutex_destroy(_M.load_mutex)
		memory.free(_M.load_mutex)
	end
end

function _M.init_worker(mutex, bootstrap_cdefs)
	_M.bootstrap_cdefs = bootstrap_cdefs
	ffi.cdef(ffi.string(bootstrap_cdefs)) -- contains pthread_**
	--[[
	if ffi.os == "Linux" then
		-- no define
	elseif ffi.os == "OSX" then
		DISPATCH_TIME_FOREVER = ffi.new('unsigned long long int', ffi.defs.DISPATCH_TIME_FOREVER)
		DISPATCH_TIME_NOW = ffi.new('unsigned long long int', ffi.defs.DISPATCH_TIME_NOW)
	else
		assert(false, "unsupported OS:"..ffi.os)
	end

	_M.sem = ffi.cast('pulpo_sem_t', sem)
	initialize_sem_func()
	]]--
	guard_clib_loader(mutex)
end

return _M

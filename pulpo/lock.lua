local ffi = require 'ffiex.init'
local memory = require 'pulpo.memory'
local require_on_boot = (require 'pulpo.package').require
local loader = require_on_boot 'pulpo.loader'
local _M = (require 'pulpo.package').module('pulpo.lock')
local C = ffi.C
local ffi_state
local PT = C

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

-- module function
function _M.initialize()
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

function _M.init_worker(mutex, bootstrap_cdefs)
	_M.bootstrap_cdefs = bootstrap_cdefs
	ffi.cdef(ffi.string(bootstrap_cdefs)) -- contains pthread_**
	guard_clib_loader(mutex)
end

function _M.finalize()
	if _M.load_mutex then
		_M.pthread_mutex_destroy(_M.load_mutex)
		memory.free(_M.load_mutex)
	end
end

return _M

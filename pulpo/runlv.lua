local GLOBAL_LOCK = 1
local SHARED_MEMORY = 2
local SYSCALLS = 3
return {
	-- export symbols
	GLOBAL_LOCK 	= GLOBAL_LOCK,
	SHARED_MEMORY 	= SHARED_MEMORY,
	SYSCALLS 		= SYSCALLS,
	-- runlevel group
	[GLOBAL_LOCK] 	= {"pulpo.lock"},
	[SHARED_MEMORY] = {"pulpo.shmem"},
	[SYSCALLS] 		= {"pulpo.defer.errno_c", "pulpo.defer.signal_c", "pulpo.defer.util_c", "pulpo.defer.socket_c", "pulpo.defer.fs_c"},
}

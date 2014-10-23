local GLOBAL_LOCK = 1
local SHARED_MEMORY = 2
local MISC = 3
return {
	-- export symbols
	GLOBAL_LOCK 	= GLOBAL_LOCK,
	SHARED_MEMORY 	= SHARED_MEMORY,
	-- runlevel group
	[GLOBAL_LOCK] 	= {"lock"},
	[SHARED_MEMORY] = {"shmem"},
	[MISC] 			= {"defer.errno_c", "defer.signal_c", "defer.util_c", "defer.socket_c"},
}

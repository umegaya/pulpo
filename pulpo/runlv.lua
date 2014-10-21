local LOADER = 1
local GLOBAL_LOCK = 2
local SHARED_MEMORY = 3
local MISC = 4
return {
	-- export symbols
	LOADER 			= LOADER,
	GLOBAL_LOCK 	= GLOBAL_LOCK,
	SHARED_MEMORY 	= SHARED_MEMORY,
	-- runlevel group
	[LOADER] 		= {"loader"},
	[GLOBAL_LOCK] 	= {"lock"},
	[SHARED_MEMORY] = {"shmem"},
	[MISC] 			= {"errno", "signal", "util_ffi", "socket"}, -- rc3.d
}

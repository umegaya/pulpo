local ffi = require 'ffiex'
local pulpo = require 'pulpo.init'
local memory = require 'pulpo.memory'

local NCLIENTS = 1000
local NITER = 100

pulpo.initialize({
	maxfd = (2 * NCLIENTS) + 100, -- client / server socket for NCLIENTS + misc
	maxconn = NCLIENTS, 
	cdef_cache_dir = './tmp/cdefs'
})

ffi.cdef [[
	typedef struct test_config {
		int n_iter;
		int n_client;
	} test_config_t;
]]

pulpo.share_memory('config', function ()
	local config = memory.alloc_typed('test_config_t')
	config.n_iter = NITER
	config.n_client = NCLIENTS
	return 'test_config_t', config
end)

pulpo.create_thread(function (args)
	local pulpo = require 'pulpo.init'
	-- run server thread group with 2 core (including *this* thread)
	pulpo.run({
		group = "server",
		n_core = 2,
	}, "./test/worker/server.lua")
end)

while true do
	print('main thread fall asleep')
	pulpo.thread.sleep(1)
end

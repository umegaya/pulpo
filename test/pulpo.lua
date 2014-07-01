local ffi = require 'ffiex'
local pulpo = require 'pulpo.init'
local memory = require 'pulpo.memory'

local NCLIENTS = 2000
local NITER = 100
local NCLIENTCORES = 2

pulpo.initialize({
	maxfd = (2 * NCLIENTS) + 100, -- client / server socket for NCLIENTS + misc
	maxconn = NCLIENTS, 
	cdef_cache_dir = './tmp/cdefs'
})

ffi.cdef [[
	typedef struct test_config {
		int n_iter;
		int n_client;
		int n_client_core;
		int n_server_core;
		bool finished;
	} test_config_t;
]]

local cf = pulpo.share_memory('config', function ()
	local socket = require 'pulpo.socket'
	local config = memory.alloc_typed('test_config_t')
	config.n_iter = NITER
	config.n_client = NCLIENTS
	config.n_client_core = NCLIENTCORES
	config.n_server_core = socket.port_reusable() and 4 or 1
	config.finished = false
	return 'test_config_t', config
end)

-- server worker
pulpo.create_thread(function (args)
	local pulpo = require 'pulpo.init'
	-- run server thread group with 2 core (including *this* thread)
	pulpo.run({
		group = "server",
		n_core = pulpo.share_memory('config').n_server_core,
	}, "./test/worker/server.lua")
end)

pulpo.thread.sleep(1.0)

-- client worker
pulpo.create_thread(function (args)
	local pulpo = require 'pulpo.init'
	-- run client thread group with 2 core (including *this* thread)
	pulpo.run({
		group = "client",
		n_core = pulpo.share_memory('config').n_client_core,
	}, "./test/worker/client.lua")
end)


while not cf.finished do
	pulpo.thread.sleep(5)
	logger.info('finished=', cf.finished)
end

pulpo.finalize()

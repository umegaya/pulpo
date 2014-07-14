local ffi = require 'ffiex'
local pulpo = require 'pulpo.init'
local memory = require 'pulpo.memory'

local NCLIENTS = 2000
local NITER = 100
local NCLIENTCORES = 2

pulpo.initialize({
	maxfd = (2 * NCLIENTS) + 100, -- client / server socket for NCLIENTS + misc
	maxconn = NCLIENTS, 
	cache_dir = '/tmp/pulpo'
})

require 'test.tools.config'

local cf = pulpo.shared_memory('config', function ()
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
	require 'test.tools.config'
	-- run server thread group with n_server_core (including *this* thread)
	pulpo.run({
		group = "server",
		n_core = pulpo.shared_memory('config').n_server_core,
	}, "./test/tools/server.lua")
end, nil, nil, true)

pulpo.thread.sleep(1.0)

-- client worker
pulpo.create_thread(function (args)
	local pulpo = require 'pulpo.init'
	require 'test.tools.config'
	-- run client thread group with n_client_core (including *this* thread)
	pulpo.run({
		group = "client",
		n_core = pulpo.shared_memory('config').n_client_core,
	}, "./test/tools/client.lua")
end, nil, nil, true)


while not cf.finished do
	pulpo.thread.sleep(5)
	logger.info('finished=', cf.finished)
end

pulpo.finalize()
return true

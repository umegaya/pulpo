local ffi = require 'ffiex.init'
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

local socket = require 'pulpo.socket'
local config = memory.alloc_typed('test_config_t')
config.n_iter = NITER
config.n_client = NCLIENTS
config.n_client_core = NCLIENTCORES
config.n_server_core = socket.port_reusable() and 4 or 1
config.port = 8008
config.finished = false

-- server worker
pulpo.run({
	group = "server",
	n_core = config.n_server_core,
	arg = config,
}, "./test/tools/server.lua")

pulpo.util.sleep(1.0)

-- client worker
pulpo.run({
	group = "client",
	n_core = config.n_client_core,
	arg = config,
}, "./test/tools/client.lua")


while not config.finished do
	pulpo.util.sleep(5)
	logger.info('finished=', config.finished)
end

pulpo.finalize()
return true

local ffi = require 'ffiex.init'
local pulpo = require 'pulpo.init'
local memory = require 'pulpo.memory'

local NCLIENTS = 2000
local NITER = 100
local NSERVERCORES = tonumber(arg[1])

pulpo.initialize({
	maxfd = (2 * NCLIENTS) + 100, -- client / server socket for NCLIENTS + misc
	maxconn = NCLIENTS, 
	cache_dir = '/tmp/pulpo'
})

require 'test.tools.config'

local config = memory.alloc_typed('test_config_t')
local socket = require 'pulpo.socket'
config.n_iter = NITER
config.n_client = NCLIENTS
config.port = tonumber(arg[2] or 8008)
config.n_server_core = socket.port_reusable() and NSERVERCORES or 1
config.finished = false

-- run server thread group with n_server_core (including *this* thread)
pulpo.run({
	group = "server",
	n_core = pulpo.shared_memory('config').n_server_core,
	args = config
	exclusive = true, -- use this thread is also run as worker
}, "./test/tools/server.lua")

return true

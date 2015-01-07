local thread = require 'pulpo.thread'
local poller = require 'pulpo.poller'
local tentacle = require 'pulpo.tentacle'

local NCLIENTS = 1000
local NITER = 100
local opts = {
	maxfd = (2 * NCLIENTS) + 100, -- client / server socket for NCLIENTS + misc
	maxconn = NCLIENTS, 
	cache_dir = '/tmp/pulpo'
}
thread.initialize(opts)
poller.initialize(opts)

local socket = require 'pulpo.socket'

local ADDR = "127.0.0.1:8888"
local a = ffi.new('pulpo_addr_t')
a:set(ADDR)
assert(tostring(a) == ADDR)

return true
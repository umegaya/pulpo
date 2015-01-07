local thread = require 'pulpo.thread'
local poller = require 'pulpo.poller'
local tentacle = require 'pulpo.tentacle'
local memory = require 'pulpo.memory'

local NCLIENTS = 1000
local NITER = 100
local opts = {
	maxfd = (2 * NCLIENTS) + 100, -- client / server socket for NCLIENTS + misc
	maxconn = NCLIENTS, 
	cache_dir = '/tmp/pulpo'
}
thread.initialize(opts)
poller.initialize(opts)

local udp = require 'pulpo.io.udp'

local p = poller.new()
local limit,finish,cfinish = NCLIENTS * NITER,0,0

tentacle(function ()
	-- because udp listener is actually a udp connection, one connection receive all packets.
	-- so increase rbuf size is necessary.
	-- considering actual payload size, 256 * NCLIENTS seems to be enough, but maybe udp header size 
	-- requires more memory.
	local s = udp.listen(p, '0.0.0.0:8008', { rblen = 512 * NCLIENTS })
	local a = memory.managed_alloc_typed('pulpo_addr_t')
	a:init()
	local received = {}
	local ptr,len = ffi.new('char[256]')
	while true do
		-- print('accept start:')
		len = s:read(ptr, 256, a)
		if len then
			s:write(ptr, len, a)
			-- print('accept:', _fd:fd())
			finish = finish + 1
			if (finish % 5000) == 0 then
				io.stdout:write("s")
				io.stdout:flush()
			end
		end
	end
end)

local start = os.clock()

local client_msg = ("hello,luact poll"):rep(16)
for cnt=1,NCLIENTS,1 do
	tentacle(function (id)
		local a = memory.managed_alloc_typed('pulpo_addr_t')
		local a2 = memory.managed_alloc_typed('pulpo_addr_t')
		a:set('127.0.0.1:8008')
		-- print('addrs', a.p[0].sa_family)
		a2:init()
		local s = udp.connect(p, '127.0.0.1:8008')
		local ptr,len = ffi.new('char[256]')
		local i = 0
		local msg = client_msg
		while i < NITER do
			s:write(msg, #msg)
			len = s:read(ptr, 256, a2)
			assert(a[0] == a2[0])
			local rmsg = ffi.string(ptr,len)
			assert(rmsg == msg, "illegal packet received:"..msg)
			i = i + 1
			cfinish = cfinish + 1
			if (cfinish % 5000) == 0 then
				io.stdout:write("c")
				io.stdout:flush()
			end
			if cfinish >= limit then
				io.stdout:write("\n")
				p:stop()
			end
		end
	end, cnt)
end

logger.info('start', p)
p:loop()

logger.info('end', os.clock() - start, 'sec')
pulpo_assert(limit <= finish and limit <= cfinish, "not all client/server finished but poller terminated")
poller.finalize()
return true
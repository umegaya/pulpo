local thread = require 'pulpo.thread'
local poller = require 'pulpo.poller'
local tentacle = require 'pulpo.tentacle'
local memory = require 'pulpo.memory'

local NITER = 10
local NLISTENER = 5
local opts = {
	cache_dir = '/tmp/pulpo'
}
thread.initialize(opts)
poller.initialize(opts)

local udp = require 'pulpo.io.udp'
local task = require 'pulpo.task'

local p = poller.new()
local g = task.newgroup(p, 0.01, 10)


local client_msg = ("hello,luact poll"):rep(16)
local finished = 0
local MCAST_GROUP = '224.1.1.1:10000'
for i =1,NLISTENER do
	tentacle(function (id)
		local s = udp.mcast_listen(p, MCAST_GROUP)
		local a = memory.managed_alloc_typed('pulpo_addr_t')
		a:init()
		local received = {}
		local ptr,len = ffi.new('char[256]')
		local cnt = 0
		while cnt < NITER do
			-- print('accept start:')
			len = s:read(ptr, 256, a)
			if len then
				assert(client_msg == ffi.string(ptr, len))
				cnt = cnt + 1
				io.stdout:write(id)
				io.stdout:flush()
			end
		end
		finished = finished + 1
	end, i)
end

tentacle(function ()
	local s = udp.create(p)
	local a = memory.managed_alloc_typed('pulpo_addr_t')
	a:set(MCAST_GROUP)
	local cnt = 0
	while true do
		-- print('write start:')
		s:write(client_msg, #client_msg, a)
		g:sleep(0.1)
		if finished >= NLISTENER then
			break
		end
		io.stdout:write('*')
		io.stdout:flush()
		cnt = cnt + 1
		if cnt > (NITER * NLISTENER) * 2 then
			p:stop()
			logger.error('takes too long time to finish')
			os.exit(-2)
		end
	end
	io.stdout:write('\n')
	p:stop()
end)

local start = os.clock()
logger.info('start', p)
p:loop()

logger.info('end', os.clock() - start, 'sec')
poller.finalize()
return true
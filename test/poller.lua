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

local tcp = require 'pulpo.io.tcp'

local p = poller.new()
local limit,finish,cfinish = NCLIENTS * NITER,0,0

tentacle.new(function ()
	local s = tcp.listen(p, '0.0.0.0:8008')
	while true do
		-- print('accept start:')
		local _fd = s:read()
		-- print('accept:', _fd:fd())
		tentacle(function (fd)
			-- print('sub tentacle:', fd:fd())
			local i = 0
			-- print('read start')
			local ptr,len = ffi.new('char[256]')
			while i < NITER do
				len = fd:read(ptr, 256)
				-- print('read end', len)
				fd:write(ptr, len)
				i = i + 1
				finish = finish + 1
				if (finish % 5000) == 0 then
					io.stdout:write("s")
				end
			end
		end, _fd)	
	end
end)()

local start = os.clock()

local client_msg = ("hello,luact poll"):rep(16)
for cnt=1,NCLIENTS,1 do
	tentacle(function ()
		local s = tcp.connect(p, '127.0.0.1:8008')
		local ptr,len = ffi.new('char[256]')
		local i = 0
		while i < NITER do
			s:write(client_msg, #client_msg)
			len = s:read(ptr, 256) --> malloc'ed char[?]
			local msg = ffi.string(ptr,len)
			pulpo_assert(msg == client_msg, "illegal packet received:"..msg)
			i = i + 1
			cfinish = cfinish + 1
			if (cfinish % 5000) == 0 then
				io.stdout:write("c")
			end
			if cfinish >= limit then
				io.stdout:write("\n")
				p:stop()
			end
		end
	end)
end

logger.info('start', p)
p:loop()

logger.info('end', os.clock() - start, 'sec')
pulpo_assert(limit <= finish and limit <= cfinish, "not all client/server finished but poller terminated")
poller.finalize()
return true
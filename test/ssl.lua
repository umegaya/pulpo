local ffi = require 'ffiex.init'
-- ffi.__DEBUG_CDEF__ = true
local loader = require 'pulpo.loader'
loader.debug = true
local thread = require 'pulpo.thread'
local poller = require 'pulpo.poller'
local tentacle = require 'pulpo.tentacle'
local event = require 'pulpo.event'
local util = require 'pulpo.util'
-- tentacle.debug = true	

local NCLIENTS = 250
local NITER = 100
local opts = {
	maxfd = (2 * NCLIENTS) + 100, -- client / server socket for NCLIENTS + misc
	maxconn = NCLIENTS, 
	datadir = '/tmp/pulpo'
}
thread.initialize(opts)
poller.initialize(opts)

local env = require 'pulpo.env'
if ffi.os == "OSX" then
-- add loader path for openssl lib/header
-- (in case installed openssl by brew )
ffi.path("/usr/local/opt/openssl/include")
env.DYLD_LIBRARY_PATH = ((env.DYLD_LIBRARY_PATH or "") .. "/usr/local/opt/openssl/lib")
elseif ffi.os == "Linux" then
end

-- then init ssl module
local ssl = require 'pulpo.io.ssl'
ssl.debug = true
ssl.initialize({
	pubkey = "./test/certs/public.key",
	privkey = "./test/certs/private.key",
})

local p = poller.new()
local limit,finish,cfinish = NCLIENTS * NITER,0,0

tentacle(function ()
	local s = ssl.listen(p, '0.0.0.0:8008')
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
end)

local start = util.clock()

local client_msg = ("hello,luact poll"):rep(16)
for cnt=1,NCLIENTS,1 do
	tentacle(function ()
		local s = ssl.connect(p, '127.0.0.1:8008')
		local ptr,len = ffi.new('char[256]')
		local i = 0
		while i < NITER do
		--print('start write:', cnt)
			s:write(client_msg, #client_msg)
		--print('end write:', cnt)
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

logger.info('end', util.clock() - start, 'sec')
pulpo_assert(limit <= finish and limit <= cfinish, "not all client/server finished but poller terminated")
poller.finalize()

return true

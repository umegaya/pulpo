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

local NCLIENTS = 100
local NITER = 50
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

local https = require 'pulpo.io.https'

--local lib = ffi.load('picohttpparser')
--local test = [[GET / HTTP/1.1\r\n\r\n]]
--assert(#test == lib.phr_parse_request(test, #test, ))

local p = poller.new()
local limit,finish,cfinish = NCLIENTS * NITER,0,0

tentacle.new(function ()
	local s = https.listen(p, '0.0.0.0:8008')
	while true do
		-- print('accept start:')
		local _fd = s:read()
		-- print('accept:', _fd:fd())
		tentacle(function (fd)
			-- print('sub tentacle:', fd:fd())
			local i = 0
			while i < NITER do
				-- print('read start', i)
				local req = fd:read()
				-- print('read end', i)
				local verb, path, hds, b, blen = req:payload()
				assert(verb == "POST" and path == "/hoge")
				--print(b, blen)
				fd:write(b, blen)
				req:fin()
				i = i + 1
				finish = finish + 1
				if (finish % 5000) == 0 then
					io.stdout:write("s")
				end
			end
		end, _fd)	
	end
end)()

local start = util.clock()

local client_msg = ("hello,luact poll"):rep(16)
for cnt=1,NCLIENTS,1 do
	tentacle(function ()
		local s = https.connect(p, '127.0.0.1:8008')
		local i = 0
		while i < NITER do
		-- print('start write:', cnt)
			s:write(client_msg, #client_msg, { "POST", "/hoge" })
		-- print('end write:', cnt)
			local resp = s:read()
			local status, hds, b, blen = resp:payload()
			assert(status == 200 and hds:getstr("Connection"):lower() == "keep-alive")
			--print('blen = ', blen)
			local msg = ffi.string(b, blen)
			assert(msg == client_msg, "illegal packet received:["..msg.."]")
			resp:fin()
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

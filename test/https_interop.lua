local pulpo = require 'pulpo.init'


pulpo.initialize({
	datadir = '/tmp/pulpo'
})

pulpo.run({
	n_core = 1,
	exclusive = true,
}, function ()
	local pulpo = require 'pulpo.init'
	local tentacle = require 'pulpo.tentacle'
	local ffi = require 'ffiex.init'
	local ssl = require 'pulpo.io.ssl'
	ssl.initialize({
		pubkey = "./test/certs/public.key",
		privkey = "./test/certs/private.key",
	})
	local https = pulpo.evloop.io.https
	local process = pulpo.evloop.io.process

	-- interop with other http client application
	tentacle(function ()
		local msg = 'hello world'
		local s = https.listen('0.0.0.0:8008')
		while true do
			local _fd = s:read()
			if _fd then
				print('accept', _fd:fd())
				tentacle(function (fd)
					local req = fd:read()
					local verb, path, hds, b, blen = req:payload()
					assert(verb == "POST" and path == "/rest/api")
					assert(ffi.string(b, blen) == "name1=value1&name2=value2")
					req:fin()
					--print(b, blen)
					fd:write(msg, #msg)
				end, _fd)
			end
		end
	end)
	tentacle(function ()
		local exitcode, out = process.execute('curl -k -d "name1=value1&name2=value2" https://127.0.0.1:8008/rest/api')
		assert(out == "hello world")
		print('graceful stop')
		pulpo.stop()
	end)
	return true
end)

return true

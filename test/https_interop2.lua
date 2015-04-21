-- interop with other http server (google)
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
	ssl.debug = true
	ssl.initialize({})
	local https = pulpo.evloop.io.https

	-- interop with other http client application
	tentacle(function ()
		local msg = 'hello world'
		local s = https.connect('www.google.com:443')
		s:write({
			"GET", "/"
		})
		local resp = s:read()
		local status, headers, b, blen = resp:payload()
		assert(status == 302)
		assert(headers:getstr("Server"):match("^GFE"))
		assert(headers:getstr("Location"):match("^https://www.google%.co%.jp/%?"))
		resp:fin()
		print('graceful stop')
		pulpo.stop()
	end)
	return true
end)

return true

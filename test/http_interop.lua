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
	local proc = require 'pulpo.io.process'
	local clock = pulpo.evloop.clock.new(0.05, 10)
	proc.initialize(function (dur)
		return clock:alarm(dur)
	end)
	local http = pulpo.evloop.io.http
	local process = pulpo.evloop.io.process

	-- interop with other http client application
	tentacle(function ()
		local msg = 'hello world'
		local s = http.listen('0.0.0.0:8008')
		while true do
			local _fd = s:read()
			print('accept', _fd:fd())
			tentacle(function (fd)
				local req = fd:read()
				local verb, path, hds, b, blen = req:payload()
				assert(verb == "POST" and path == "/rest/api")
				-- print('received', ffi.string(b, blen))
				assert(ffi.string(b, blen) == "name1=value1&name2=value2")
				req:fin()
				-- print(b, blen)
				fd:write(msg, #msg)
			end, _fd)	
		end
	end)
	tentacle(function ()
		local exitcode, out = process.execute('exec curl -d "name1=value1&name2=value2" http://127.0.0.1:8008/rest/api')
		assert(out == "hello world")
		print('graceful stop')
		pulpo.stop()
	end)
	return true
end)

return true

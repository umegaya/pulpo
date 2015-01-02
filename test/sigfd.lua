local ffi = require 'ffiex.init'
if ffi.os == "OSX" then
	return true
end
local pulpo = (require 'pulpo.init').initialize()
local signal = require 'pulpo.signal'

pulpo.tentacle(function ()
	local sigfd = pulpo.evloop.io.sigfd
	local clock = pulpo.evloop.clock.new(0.5, 10)

	pulpo.tentacle(function ()
		print('kill tentacle1')
		clock:sleep(1.0)
		print('kill tentacle2')
		os.execute("kill -USR1 "..pulpo.util.getpid())
		clock:sleep(1.0)
		print('kill tentacle3')
		os.execute("kill -USR2 "..pulpo.util.getpid())
		print('kill tentacle end')
	end)

	local ok, r = pulpo.event.wait(false, pulpo.tentacle(function ()
		local sigg = sigfd.newgroup()
		while true do
			local event, object = pulpo.event.wait(false, sigg.SIGUSR1:event('read'), sigg.SIGUSR2:event('read'))
			if event == 'read' then
				local v = object:read()
				if object == sigg.SIGUSR1 then
					assert(signal.SIGUSR1 == v)
					print('USR1 catched: ignored')
				elseif object == sigg.SIGUSR2 then
					assert(signal.SIGUSR2 == v)
					print('USR2 catched: terminate')
					break
				else
					logger.error('invalid event catched:', event, object)
					assert(false)
				end
			else
				logger.error('invalid event catched:', event, object)
				assert(false)
			end
		end
		return true
	end))
print('result:', ok, r)
	assert(ok and r, "invalid tentacle wait result")
	pulpo.evloop:stop()
end)
pulpo.evloop:loop()

return true

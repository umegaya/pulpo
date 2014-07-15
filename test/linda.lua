-- avoid pulpo symbol inside thread proc, regard as upvalue
local _pulpo = require 'pulpo.init'
_pulpo.initialize({
	cache_dir = '/tmp/pulpo',
	io_pending_threshold = 50000,
})

logger.info('launch thread1')
_pulpo.create_thread(function (args)
	local linda = require 'pulpo.linda'
	local ioproc = require 'test.tools.ioproc'
	local loop = pulpo.mainloop
	local c1 = linda:channel(loop, 'c1')
	local c2 = linda:channel(loop, 'c2')
	local c3 = linda:channel(loop, 'c3')
	pulpo.tentacle.debug = true
	pulpo.tentacle(ioproc.writer, c2, '>')
	pulpo.event.wait(pulpo.tentacle(ioproc.reader, c1, '<'))
	logger.info('in thread1: reader end')
	c3:send('end', 3)
	logger.info('in thread1: send signal to thread3')
end)

logger.info('launch thread2')
_pulpo.create_thread(function (args)
	local linda = require 'pulpo.linda'
	local ioproc = require 'test.tools.ioproc'
	local loop = pulpo.mainloop
	local c1 = linda:channel(loop, 'c1')
	local c2 = linda:channel(loop, 'c2')	
	local c4 = linda:channel(loop, 'c4')
	pulpo.tentacle.debug = true
	pulpo.tentacle(ioproc.writer, c1, '}')
	pulpo.event.wait(pulpo.tentacle(ioproc.reader, c2, '{'))
	logger.info('in thread2: reader end')
	c4:send('end', 3)
	logger.info('in thread2: send signal to thread3')
end)

logger.info('launch thread3')
_pulpo.create_thread(function (args)
	local linda = require 'pulpo.linda'
	local loop = pulpo.mainloop
	local c3 = linda:channel(loop, 'c3')
	local c4 = linda:channel(loop, 'c4')
	logger.info('in thread3: start waiter')
	pulpo.event.wait(false, c3:event('read'), c4:event('read'))
	logger.info('in thread3: end waiter')
	pulpo.stop()
end)

logger.info('enter loop')
_pulpo.thread.sleep(5.0)

return true
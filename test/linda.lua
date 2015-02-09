-- avoid pulpo symbol inside thread proc, regard as upvalue
local _pulpo = require 'pulpo.init'
_pulpo.initialize({
	datadir = '/tmp/pulpo',
})

logger.info('launch thread1')
_pulpo.run({ n_core = 1 }, function (args)
	local pulpo = require 'pulpo.init'
	local ioproc = require 'test.tools.ioproc'
	local loop = pulpo.evloop
	local linda = loop.io.linda
	local c1 = linda.new('c1')
	local c2 = linda.new('c2')
	local c3 = linda.new('c3')
	pulpo.tentacle.debug = true
	pulpo.tentacle(ioproc.writer, c2, '>')
	pulpo.event.join(pulpo.tentacle(ioproc.reader, c1, '<'))
	logger.info('in thread1: reader end')
	c3:write('end', 3)
	logger.info('in thread1: send signal to thread3')
end)

logger.info('launch thread2')
_pulpo.run({ n_core = 1 }, function (args)
	local pulpo = require 'pulpo.init'
	local ioproc = require 'test.tools.ioproc'
	local loop = pulpo.evloop
	local linda = loop.io.linda
	local c1 = linda.new('c1')
	local c2 = linda.new('c2')	
	local c4 = linda.new('c4')
	pulpo.tentacle.debug = true
	pulpo.tentacle(ioproc.writer, c1, '}')
	pulpo.event.join(pulpo.tentacle(ioproc.reader, c2, '{'))
	logger.info('in thread2: reader end')
	c4:write('end', 3)
	logger.info('in thread2: send signal to thread3')
end)

logger.info('launch thread3')
_pulpo.run({ n_core = 1 }, function (args)
	local pulpo = require 'pulpo.init'
	local loop = pulpo.evloop
	local linda = loop.io.linda
	local c3 = linda.new('c3')
	local c4 = linda.new('c4')
	logger.info('in thread3: start waiter')
	pulpo.event.join(false, c3:event('read'), c4:event('read'))
	logger.info('in thread3: end waiter')
	pulpo.stop()
end)

logger.info('enter loop')
_pulpo.util.sleep(5.0)

return true
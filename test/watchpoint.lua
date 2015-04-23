local ffi = require 'ffiex.init'
if ffi.os ~= "Linux" then
	return true
end
local thread = require 'pulpo.thread'
thread.initialize({ datadir = "/tmp/pulpo" })

local wp = require 'pulpo.debug.watchpoint'

local i = ffi.new('int[1]')

local idx = wp(i, nil, nil, function (addr)
	logger.warn('watchpoint', addr, debug.traceback())
	assert(ffi.cast('void *', i) == ffi.cast('void *', addr))
end)
-- wp.untrap(idx)

print(ffi.C.getpid(), 'watchpoint check:================================')

for c=1,10,1 do
	print('write', c, 'to', i)
	i[0] = c
end

print('finished')
thread.finalize()
print('finalized')
return true

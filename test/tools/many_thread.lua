local ffi = require 'ffiex.init'
local thread = require 'pulpo.thread'

thread.initialize({cache_dir = './tmp/cdef'})

for i=1,32,1 do
	thread.create(function (arg)
		local ffi = require 'ffiex.init'
		local ssl = ffi.load('ssl')
	end, nil)
end

thread.sleep(2.0)

-- package.path = ("../ffiex/?.lua;" .. package.path)
local ffi = require 'ffiex.init'
--ffi.__DEBUG_CDEF__ = true
local util = require 'pulpo.util'
local memory = require 'pulpo.memory'
local thread = require 'pulpo.thread'
local loader = require 'pulpo.loader'
print(loader, loader.initialize, package, package.loaded["pulpo.loader"])

thread.initialize({
	datadir = '/tmp/pulpo'
})

--local wp = require 'pulpo.debug.watchpoint'
--wp(tonumber(ffi.cast('int', _G.crush_mutex)) + 28)

logger.info('----- test1 -----')
local args = memory.alloc_typed('int', 3)
args[0] = 1
args[1] = 2
args[2] = 3
local t = thread.create(function (targs)
	local i = 0
	-- because actually different lua_State execute the code inside this function, 
	-- ffi setup required again.
	local ffi = require 'ffi'
	ffi.cdef[[
	void *malloc(size_t sz);
	void free(void *p);
	]]
	local a = ffi.cast('int*', targs)
	logger.info('hello from pulpo:', (a[0] + a[1] + a[2]))
	pulpo_assert((a[0] + a[1] + a[2]) == 6, "correctly passed values into new thread")
	ffi.C.free(targs)
	local r = ffi.cast('int*', ffi.gc(ffi.C.malloc(ffi.sizeof('int[1]')), nil))
	r[0] = 111
	return r
end, args)

local r = ffi.cast('int*', thread.destroy(t))
pulpo_assert(r[0] == 111)




logger.info('----- test2 -----')
local threads = {}
local params = {}
for i=1,util.n_cpu(),1 do
	local a = memory.alloc_typed('int', 1)
	a[0] = i
	thread.shared_memory('thread_shm'..i, function ()
		local ptr = memory.alloc_typed('int', 1)
		ptr[0] = a[0]
		return 'int', ptr
	end)
	local t = thread.create(function (targs)
		local ffi = require 'ffi'
		local thread = require 'pulpo.thread'
		local memory = require 'pulpo.memory'
		local idx = (ffi.cast('int*', targs))[0]
		logger.warn('thread:', thread.me, idx, ffi)
		local ptr = thread.shared_memory('thread_shm'..idx)
		ptr[0] = (idx + 1) * 111
		while ptr[0] > 0 do
			thread.sleep(0.1)
		end
	end, a)
	table.insert(threads, t)
	params[i] = a
end
local finished = {}
while true do 
	local success = true
	thread.fetch(function (thread_list, size)
		pulpo_assert(size == (1 + util.n_cpu()), "should be same size as created num")
		pulpo_assert(thread_list[0] == thread.me, "idx0 is this thread")
		for i=1,size-1,1 do
			if not finished[i] then
				pulpo_assert(thread.equal(threads[i], thread_list[i]), "thread handle will be same")
				local pi = thread.shared_memory('thread_shm'..i)
				if pi[0] == i then
					success = false
					break
				else
					finished[i] = true
				end
				pulpo_assert(pi[0] == ((i + 1) * 111), "can read shared memory correctly")
				pi[0] = 0 --> indicate worker thread to stop
			end
		end
	end)
	if success then
		break
	end
	thread.sleep(0.1)
end

thread.finalize()

return true

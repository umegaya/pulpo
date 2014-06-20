-- package.path = ("../ffiex/?.lua;" .. package.path)
local ffi = require 'ffiex'
local util = require 'pulpo.util'
local memory = require 'pulpo.memory'
local thread = require 'pulpo.thread'

thread.initialize({
	cdef_cache_dir = './tmp/cdefs'
})

print('----- test1 -----')
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
	print('hello from pulpo:', (a[0] + a[1] + a[2]))
	assert((a[0] + a[1] + a[2]) == 6, "correctly passed values into new thread")
	ffi.C.free(targs)
	local r = ffi.cast('int*', ffi.C.malloc(ffi.sizeof('int[1]')))
	r[0] = 111
	return r
end, args)

local r = ffi.cast('int*', thread.destroy(t))
assert(r[0] == 111)




print('----- test2 -----')
local threads = {}
local params = {}
for i=0,util.n_cpu() - 1,1 do
	local a = memory.alloc_typed('int', 1)
	a[0] = i
	thread.share_memory('thread_shm'..i, function ()
		local ptr = memory.alloc_typed('int', 1)
		ptr[0] = a[0]
		return memory.strdup('int *'), ptr
	end)
	local t = thread.create(function (targs)
		local ffi = require 'ffi'
		local thread = require 'pulpo.thread'
		local memory = require 'pulpo.memory'
		local idx = (ffi.cast('int*', targs))[0]
		print('thread:', thread.me(), idx)
		local ptr = thread.share_memory('thread_shm'..idx)
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
		assert(size == util.n_cpu(), "should be same size as created num")
		for i=0,size-1,1 do
			if not finished[i] then
				assert(thread.equal(threads[i+1], thread_list[i]), "thread handle will be same")
				local pi = thread.share_memory('thread_shm'..i)
				if pi[0] == i then
					success = false
					break
				else
					finished[i] = true
				end
				assert(pi[0] == ((i + 1) * 111), "can read shared memory correctly")
				pi[0] = 0 --> indicate worker thread to stop
			end
		end
	end)
	if success then
		break
	end
	thread.sleep(0.1)
end

thread.fin()


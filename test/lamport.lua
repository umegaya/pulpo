local pulpo = require 'pulpo.init'
pulpo.initialize({
	datadir = '/tmp/pulpo',
})

local util = require 'pulpo.util'
local fixed_msec = 100000000100
function util.clock_pair()
	return math.floor(fixed_msec / 1000), ((fixed_msec % 1000)* 1000)
end

local lamport = require 'pulpo.lamport'
local function lc(logical_clock)
	local p = ffi.new('pulpo_lamport_clock_t')
	p:debug_init(fixed_msec, logical_clock)
	return p
end

local l = lamport.new(16)

assert(l:fresh(lc(10), "hoge"), "first check should success")
assert(l:now() == lc(11), "lamport clock not update correctly")
assert(l:fresh(lc(10), "fuga"), "same clock and different payload should be allowed")
assert(not l:fresh(lc(10), "hoge"), "same clock and same payload should not be allowed")
assert(not l:fresh(lc(9), "foo"), "less than oldest clock and different payload should not be allowed")
assert(l:now() == lc(11), "calling fresh() with older clock does not affect current clock")
assert(l:fresh(lc(20), "hoge"), "bigger clock with same payload should be allowed")
assert(l:now() == lc(21), "lamport clock update correctly")
assert(l:issue_clock() == lc(21), "issue_clock() returns same value as latest now() call")
assert(l:now() == lc(22), "after issue_clock(), clock should be increased")

local l2 = lamport.new(16)
for i=1,16 do
	assert(l2:fresh(lc(i), "hoge"), "first check should success")
end
assert(l2.oldest == lc(1), "oldest should be updated correctly")
for i=1,16 do
	assert(not l2:fresh(lc(i), "hoge"), "same payload/same clock should fail")
end
for i=1,16 do
	assert(l2:fresh(lc(i), "fuga"), "with different payload should success")
end
assert(l2.oldest == lc(1), "oldest should be updated correctly")
for i=17,32 do
	assert(l2:fresh(lc(i), "hoge"), "with same payload and bigger clock should success")
end
assert(l2.oldest == lc(17), "oldest should be updated correctly")

return true

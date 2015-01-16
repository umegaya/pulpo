local lamport = require 'pulpo.lamport'

local l = lamport.new(16)

assert(l:fresh(10, "hoge"), "first check should success")
assert(l:now() == 11, "lamport clock update correctly")
assert(l:fresh(10, "fuga"), "same clock and different payload should be allowed")
assert(not l:fresh(10, "hoge"), "same clock and same payload should not be allowed")
assert(not l:fresh(9, "foo"), "less than oldest clock and different payload should not be allowed")
assert(l:now() == 11, "calling fresh() with older clock does not affect current clock")
assert(l:fresh(20, "hoge"), "bigger clock with same payload should be allowed")
assert(l:now() == 21, "lamport clock update correctly")
assert(l:issue_clock() == 21, "issue_clock() returns same value as latest now() call")
assert(l:now() == 22, "after issue_clock(), clock should be increased")

local l2 = lamport.new(16)
for i=1,16 do
	assert(l2:fresh(i, "hoge"), "first check should success")
end
assert(l2.oldest == 1, "oldest should be updated correctly")
for i=1,16 do
	assert(not l2:fresh(i, "hoge"), "same payload/same clock should fail")
end
for i=1,16 do
	assert(l2:fresh(i, "fuga"), "with different payload should success")
end
assert(l2.oldest == 1, "oldest should be updated correctly")
for i=17,32 do
	assert(l2:fresh(i, "hoge"), "with same payload and bigger clock should success")
end
assert(l2.oldest == 17, "oldest should be updated correctly")

return true
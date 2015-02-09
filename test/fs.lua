local thread = require 'pulpo.thread'
local poller = require 'pulpo.poller'
local socket = require 'pulpo.socket'
local fs = require 'pulpo.fs'

thread.initialize({
	datadir = './tmp'
})

fs.rmdir("/tmp/test_pulpo_logger")
fs.mkdir("/tmp/test_pulpo_logger")

local fl = fs.new_file_logger('/tmp/test_pulpo_logger', {
	maxsize = 100, 
	filenum = 3,
})

fl({ tag = "D:" }, "a", nil, false, true, function () return 1 end, ffi.new('int', 1))
assert(#fl.files == 0, "first log size not limit to maxsize, so only current log should exist")
fl({ tag = "D:" }, "1"..("a"):rep(15))
assert(#fl.files == 1, "first log size limit to maxsize, so current and 1 backup should exist")
local fname = fl.files[1]
fl({ tag = "D:" }, "2"..("a"):rep(15))
assert(#fl.files == 1, "log size of current will not reach to limit by this write, so backup should not increase")
fl({ tag = "D:" }, "3"..("a"):rep(15))
assert(#fl.files == 2, "log size of current will reach to limit, so backup should increase")
local fname2 = fl.files[2]
fl({ tag = "D:" }, "4"..("a"):rep(70))
assert(#fl.files == 3, "even if single log record exceed log size limit, it will write to current")
assert(#(io.open('/tmp/test_pulpo_logger/current'):read('*a')) == 101)
fl({ tag = "D:" }, "5"..("a"):rep(15))
assert(#fl.files == 3, "then next write will purge current, and it should cause purging oldest logs")
assert(fl.files[1] == fname2, "previous second oldest backup should be oldest")
for i=1,3 do
	assert(fl.files[i] ~= fname, "oldest log should not exist")
end
fs.rmdir("/tmp/test_pulpo_logger")

return true
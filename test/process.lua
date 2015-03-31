local pulpo = require 'pulpo.init'
-- ffi.__DEBUG_CDEF__ = true
local thread = require 'pulpo.thread'
local poller = require 'pulpo.poller'
local tentacle = require 'pulpo.tentacle'
local event = require 'pulpo.event'
local util = require 'pulpo.util'
local signal = require 'pulpo.signal'

pulpo.initialize({
	datadir = '/tmp/pulpo'
})

local process = pulpo.evloop.io.process

local p1 = process.open(("%s test/tools/process_success.lua"):format(util.luajit_cmdline()))
local p2 = process.open(("%s test/tools/process_error.lua"):format(util.luajit_cmdline()))

local ptr, ofs, len = ffi.new('char[256]'), 0, 256

while true do
	local ok, code, sig = p1:read(ptr + ofs, len - ofs)
	if not ok then
		assert(code == 0 and sig == 0)
		break
	else
		ofs = ofs + ok
	end
end
assert(ffi.string(ptr, ofs) == "ok\n")

while true do
	local ok, code, sig = p2:read(ptr + 256 - len, len)
	if not ok then
		assert(code == ffi.cast('uint8_t', -1) and sig == 0)
		break
	else
		assert(false, "should cause error")
	end
end

return true
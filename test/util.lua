local thread = require 'pulpo.thread'
thread.initialize()
local util = require 'pulpo.util'
local socket = require 'pulpo.socket'
local ffi = require 'ffiex.init'

local ret
if ffi.os == "OSX" then
ret = socket.getifaddr() 
elseif ffi.os == "Linux" then
ret = socket.getifaddr()
end
print(socket.inet_namebyhost(ret:address()), socket.inet_namebyhost(ret:netmask()))

return true

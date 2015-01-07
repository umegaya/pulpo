local thread = require 'pulpo.thread'
thread.initialize()
local util = require 'pulpo.util'
local socket = require 'pulpo.socket'
local ffi = require 'ffiex.init'

local addr, mask
if ffi.os == "OSX" then
addr, mask = socket.getifaddr() 
elseif ffi.os == "Linux" then
addr, mask = socket.getifaddr()
end
print(socket.inet_namebyhost(addr), socket.inet_namebyhost(mask))

return true

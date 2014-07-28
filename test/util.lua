local thread = require 'pulpo.thread'
thread.initialize()
local util = require 'pulpo.util'
local socket = require 'pulpo.socket'
local ffi = require 'ffiex'

local addr, mask
if ffi.os == "OSX" then
addr, mask = socket.getifaddr("lo0") 
elseif ffi.os == "Linux" then
addr, mask = socket.getifaddr("lo")
end
print(addr, mask)

return true

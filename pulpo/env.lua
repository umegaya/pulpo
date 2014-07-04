local ffi = require 'ffiex'
local loader = require 'pulpo.loader'
local errno = require 'pulpo.errno'

local _M = {}
local C = ffi.C

loader.load('env.lua', {
	"setenv", "unsetenv"
}, {}, nil, [[
	#include <stdlib.h>
]])

local env_mt = { 
	__index = function (t, k)
		return os.getenv(k)
	end,
	__newindex = function (t, k, v)
		if type(k) ~= "string" then
			rawset(t, k, v)
			return
		end
		local r = ((v ~= nil) and C.setenv(k, tostring(v), true) or C.unsetenv(k))
		if r ~= 0 then
			error("error change env:"..errno.errno())
		end
	end,
}

return setmetatable(_M, env_mt)

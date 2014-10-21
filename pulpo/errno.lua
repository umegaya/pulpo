local ffi = require 'ffiex.init'
local thread = require 'pulpo.thread'

local _M = {}
local ffi_state

thread.add_initializer(function (loader, shmem)
	ffi_state = loader.load("errno.lua", {}, {
		"EAGAIN", "EWOULDBLOCK", "ENOTCONN", "EINPROGRESS", "EPIPE", 
		regex = {
			"^E%w+"
		}
	}, nil, [[
		#include <errno.h>
	]])
end)

function _M.errno()
	return ffi.errno()
end

return setmetatable(_M, {
	__index = function (t, k)
		local v = ffi_state.defs[k]
		assert(v, "no error definition:"..k)
		rawset(t, k, v)
		return v
	end
})

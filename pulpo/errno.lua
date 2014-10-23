local ffi = require 'ffiex.init'
local require_on_boot = (require 'pulpo.package').require
local _M = require_on_boot 'pulpo.defer.errno_c'

function _M.errno()
	return ffi.errno()
end

return _M

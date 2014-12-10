local require_on_boot = (require 'pulpo.package').require
local _M = require_on_boot 'pulpo.defer.fs_c'

if ffi.os == "Windows" then
	_M.PATH_SEPS = "¥"
	_M.ROOT_DESC = "C:¥¥"
else
	_M.PATH_SEPS = "/"
	_M.ROOT_DESC = "/"
end
function _M.path(...)
	return table.concat({...}, _M.PATH_SEPS)
end
function _M.abspath(...)
	return _M.ROOT_DESC..table.concat({...}, _M.PATH_SEPS)
end

return _M

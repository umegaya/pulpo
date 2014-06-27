-- tentacle is not special concept of pulpo.
-- its just coroutine, but name is really suitable for me because of lib name.
-- you disappointed? XD
local _M = {}
local tentacle_mt = {}

function tentacle_mt.__call(t, body, ...)
	return coroutine.wrap(body)(...)
end
function _M.new(body)
	return coroutine.wrap(body)
end
function _M.pnew(body)
	return function (...)
		return pcall(_M.new(body), ...)
	end
end

return setmetatable(_M, tentacle_mt)

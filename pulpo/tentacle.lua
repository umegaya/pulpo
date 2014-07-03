local event = require 'pulpo.event'

local _M = {}
local metatable = {}
local tentacle_mt = {}

local function tentacle_proc(ev, body, ...)
	if _M.debug then
		local args = {pcall(body, ...)}
		logger.notice('tentacle result:', unpack(args))
		ev:emit('end', unpack(args))
	else
		ev:emit('end', pcall(body, ...))
	end
end
function metatable.__call(t, body, ...)
	local cof = coroutine.wrap(tentacle_proc)
	local ev = event.new()
	cof(ev, body, ...)
	return ev
end
function tentacle_mt.__call(t, ...)
	local cof = coroutine.wrap(tentacle_proc)
	cof(t[1], t[2], ...)
	return t[1]
end
-- late execution
function _M.new(body)
	local cof = coroutine.wrap(tentacle_proc)
	return setmetatable({
		event.new(), body		
	}, tentacle_mt)
end

-- additional primitive for event module
function event.select_event(filter, ...)
	local ev = event.new()
	_M(function (f, ...)
		ev:emit('done', event.select(f, ...))
	end, filter, ...)
	return ev
end

function event.wait_event(timeout, ...)
	local ev = event.new()
	_M(function (t_o, ...)
		ev:emit('done', event.wait(t_o, ...))
	end, timeout, ...)
	return ev
end

return setmetatable(_M, metatable)
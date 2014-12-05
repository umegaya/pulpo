local event = require 'pulpo.event'

local _M = {}
local metatable = {}
local tentacle_mt = {}

local coro = {}
local coro_mt = {
	__index = coro,
}
local cache = {}
local function main(co)
	while true do
		co[2]:emit('end', xpcall(coroutine.yield()))
		table.insert(cache, co)
	end
end
function coro.new()
	if #cache > 0 then
		local c = cache[#cache]
		cache[#cache] = nil
		return c
	else
		local co = coroutine.create(main)
		local ev = event.new()
		local c = setmetatable({co, ev}, coro_mt)
		coroutine.resume(co, c)
		return c
	end
end
function coro:run(f, ...)
	return select(2, coroutine.resume(self[1], f, ...))
end

local function err_handler(e)
	if type(e) == 'table' then
		logger.report('tentacle result:', e)
	else
		logger.report('tentacle result:', tostring(e), debug.traceback())
	end
end
function metatable.__call(t, body, ...)
	local c = coro.new()
	coro.run(c, body, err_handler, ...)
	return c[2]
end
function tentacle_mt.__call(t, ...)
	local c = coro.new()
	coro.run(c, t[1], err_handler, ...)
	return c[2]
end
-- late execution
function _M.new(body)
	return setmetatable({
		body
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

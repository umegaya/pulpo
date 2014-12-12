local event = require 'pulpo.event'

local _M = {}
local metatable = {}
local tentacle_mt = {}

local coro = {}
local coro_mt = {
	__index = coro,
}
local cache = {}
local function err_handler(e)
	if type(e) == 'table' then
		logger.report('tentacle result:', e)
	else
		logger.report('tentacle result:', tostring(e), debug.traceback())
	end
	return e
end
local function loop(co)
if false and _M.DEBUG then
	print('coro:yield enter', co[1])
	local ret = {coroutine.yield()}
	print('coro:yield result', co[1], unpack(ret))
	ret = {xpcall(unpack(ret))}
	print('coro:main', co[1], unpack(ret))
	co[2]:emit('end', unpack(ret))
	print('coro:main notice end', co[1])
else
	co[2]:emit('end', xpcall(coroutine.yield()))
end
end
local function main(co)
	while xpcall(loop, err_handler, co) do
		table.insert(cache, co)
	end
if _M.DEBUG then
	(require 'pulpo.exception').raise('fatal', "in debug env, tentacle loop never fails")
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
function event.wait_event(filter, ...)
	local ev = event.new()
	_M(function (f, ...)
		ev:emit('done', event.wait(f, ...))
	end, filter, ...)
	return ev
end

function event.join_event(timeout, ...)
	local ev = event.new()
	_M(function (t_o, ...)
		ev:emit('done', event.join(t_o, ...))
	end, timeout, ...)
	return ev
end

return setmetatable(_M, metatable)

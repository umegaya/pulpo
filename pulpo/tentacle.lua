local _M = {}
local cache = {}
local map = {}

-- local functions
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
		co:emit('end', unpack(ret))
		print('coro:main notice end', co[1])
	else
		co:emit('end', xpcall(coroutine.yield()))
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
local function new()
	if #cache > 0 then
		local c = cache[#cache]
		cache[#cache] = nil
		return c
	else
		local co = coroutine.create(main)
		local ev = _M.event.new()
		ev[1] = co
		coroutine.resume(co, ev)
		map[co] = ev
		return ev
	end
end


-- call meta methods
local metatable = {}
local tentacle_mt = {}
function metatable.__call(t, body, ...)
	local c = new()
	_M.resume(c, body, err_handler, ...)
	return c
end
function tentacle_mt.__call(t, ...)
	local c = new()
	_M.resume(c, t[1], err_handler, ...)
	return c
end


-- late execution
function _M.new(body)
	return setmetatable({
		body
	}, tentacle_mt)
end
function _M.running()
	return map[coroutine.running()]
end
_M.yield = coroutine.yield
function _M.resume(co, ...)
	local ok, r = coroutine.resume(co[1], ...)
	co[2] = ok and r
end
function _M.cancel_handler(obj, co)
	obj:__cancel(co)
end
function _M.cancel(co)
	if co[2] then 
		_M.cancel_handler(co[2], co)
		map[co[1]] = nil
	elseif coroutine.status(co) ~= 'dead' then
		logger.warn('no canceler', co[1], 'it yields under un-cancelable operation?', coroutine.status(co))
	end
end

return setmetatable(_M, metatable)

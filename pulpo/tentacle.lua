local _M = {}
local cache = {}
local map = {}
local logger = _G.logger or print

-- local functions
local function err_handler(e)
	if type(e) == 'table' then
		logger.report('tentacle result:', e)
	else
		logger.report('tentacle result:', tostring(e), debug.traceback())
	end
	if _M.TRACE then
		local co = _M.running()
		logger.report('last yield', co.ybt)
		logger.report('last resume', co.rbt)
		co.ybt = nil
		co.rbt = nil
	end
	return e
end
local function loop(co)
	co:emit('end', xpcall(coroutine.yield()))
end
local function main(co)
	while xpcall(loop, err_handler, co) do
		co[3] = true
		table.insert(cache, co)
	end
	if _M.DEBUG then
		(require 'pulpo.exception').raise('fatal', "in debug env, tentacle loop never fails")
	end
end
local function new()
	if #cache > 0 then
		local c = table.remove(cache)
		c[3] = false
		return c
	else
		local co = coroutine.create(main)
		local ev = _M.event.new()
		ev[1] = co
		map[co] = ev
		coroutine.resume(co, ev)
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
--_M.yield = coroutine.yield
function _M.yield(obj)
	if (not obj) then
		logger.report('invalid yield result', obj, debug.traceback())
	end
	if _M.TRACE then
		_M.running().ybt = debug.traceback()
	end
	return coroutine.yield(obj)
end
function _M.set_context(ctx, co)
	co = co or _M.running()
	co[4] = ctx
end
function _M.get_context(co)
	co = co or _M.running()
	return co[4]
end
function _M.trace(co)
	assert(_M.TRACE)
	logger.report('last yield', co.ybt)
	logger.report('last resume', co.rbt)
end	
function _M.resume(co, ...)
	if not co then
		logger.report('invalid coroutine:', debug.traceback())
	end
	co[2] = nil -- no more cancelable by previous object
	local ok, r = coroutine.resume(co[1], ...)
	co[2] = ok and r
	if _M.TRACE then
		co.rbt = debug.traceback()
	end
	--[[
	if ok and (not co[2]) then
		local bt = debug.traceback()
		if not bt:match('router.lua') then
			logger.report('invalid resume result', co[1], coroutine.status(co[1]), tostring(r), debug.traceback())
		end
	elseif not ok then
		logger.report('resume end in error', r)
	end
	]]
end
function _M.cancel_handler(obj, co)
	obj:__cancel(co)
end
function _M.cancel(co)
	if co[2] then 
		_M.cancel_handler(co[2], co)
		map[co[1]] = nil
	elseif coroutine.status(co[1]) ~= 'dead' then
		if co[3] then 
			logger.warn('no canceler', co[1], 'but it is cache for next use: ok')
		elseif coroutine.status(co[1]) == 'normal' then
			-- eg) _M.cancel is called from tentacle which is to be canceled. (including via resume chain)
			-- that means, the tentacle keep on running after this cancel call, which may cause a lot of difficult bug.
			error('can not cancel running tentacle:'..tostring(co[1])..'@'..tostring(co))
		else
			logger.warn('no canceler', co[1], 'it yields under un-cancelable operation?', coroutine.status(co[1]))
		end
	end
end

return setmetatable(_M, metatable)

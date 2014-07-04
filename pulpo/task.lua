local timer = require 'pulpo.socket.timer'
local event = require 'pulpo.event'
local _M = {}
------------------------------------------------------------
-- common interface for task/taskgrp
------------------------------------------------------------

-- task
function _M.new(p, start, intv, cb, ...)
	local io = timer.create(p, start, intv)
	coroutine.wrap(function (_tm, _fn, ...)
		local function proc(tm, fn, ...)
			while true do
				local n = tm:read()
				if not n then
					logger.info('timer:', io:fd(), 'closed by event:', tp)
					goto exit
				end
				for i=1,tonumber(n),1 do
					if fn(...) == false then
						logger.info('timer:', io:fd(), 'closed by user')
						goto exit
					end
				end
			end
			::exit::
		end
		local ok, r = pcall(proc, _tm, _fn, ...)
		if not ok then
			logger.error("timer proc fails:"..r)
		end
		tm:close()
	end)(io, cb, ...)
end

-- task group
local taskgrp_index = {}
local taskgrp_mt = { __index = taskgrp_index }
local function taskgrp_new(intv, max_duration)
	local size = math.floor(max_duration / intv)
	local queue = {}
	for i=1,size,1 do
		queue[i] = {}
	end
	return setmetatable({
		index = 1,
		size = size,
		queue = queue,
		intv = intv,
	}, taskgrp_mt)
end
function taskgrp_index.get_duration_index(t, sec)
	return math.floor(sec / t.intv)
end
function taskgrp_index.get_dest_index(t, span)
	return 1 + ((t.index + span)%t.size)
end
function taskgrp_index.tick(t)
	if t.stop then return false end
	if t.index > t.size then
		t.index = 1
	end
	local q = t.queue[t.index]
	for idx,fn in ipairs(q) do
		q[idx] = nil
		if fn[2](fn[3]) ~= false then
			local nxt = t:get_dest_index(fn[1])
			table.insert(t.queue[nxt], fn)
		end
	end
	t.index = t.index + 1
	return true
end
function taskgrp_index.close(t)
	t.stop = true
end
function taskgrp_index.add(t, start, intv, fn, arg)
	local sidx = t:get_duration_index(start)
	local iidx = t:get_duration_index(intv)
	local dest = t:get_dest_index(sidx)
	local q = t.queue[dest]
	table.insert(q, {iidx, fn, arg})
end
local function sleep_proc(co)
	coroutine.resume(co)
	return false
end
function taskgrp_index.sleep(t, sec)
	local co = coroutine.running()
	t:add(sec, sec, sleep_proc, co)
	coroutine.yield(co)
end
local function alarm_proc(em)
	em:emit('read')
	return false
end
local function alarm_preyield(ev, arg)
	arg[1]:add(arg[2], arg[2], alarm_proc, ev)
end
function taskgrp_index.alarm(t, sec)
	return event.new(alarm_preyield, {t, sec})
end
function _M.newgroup(p, intv, max_duration)
	local tg = taskgrp_new(intv, max_duration)
	_M.new(p, 0, intv, tg.tick, tg)
	return tg
end

return _M

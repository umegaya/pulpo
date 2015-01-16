local timer = require 'pulpo.io.timer'
local tentacle = require 'pulpo.tentacle'
local util = require 'pulpo.util'
local pulpo = require 'pulpo.init'
local event = require 'pulpo.event'
local _M = {}
------------------------------------------------------------
-- common interface for task/taskgrp
------------------------------------------------------------

-- task
local function proc(tm, fn, ...)
	while true do
		local n = tm:read()
		if not n then
			logger.info('timer:', tm:fd(), 'closed by event:', tp)
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
function _M.new(p, start, intv, cb, ...)
	local io = timer.new(p, start, intv)
	tentacle(function (_tm, _fn, ...)
		local ok, r = pcall(proc, _tm, _fn, ...)
		if not ok then
			logger.error("timer proc fails:"..r)
		end
		_tm:close()
	end, io, cb, ...)
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
		epoc = util.clock(),
	}, taskgrp_mt)
end
function taskgrp_index.get_duration_index(t, sec)
	return math.floor(sec / t.intv)
end
function taskgrp_index.get_dest_index(t, span)
	local ofs = t:get_duration_index(util.clock() - t.epoc)
	return 1 + ((ofs + span)%t.size) -- +1 for converting to lua index
end
function taskgrp_index.loop(t)
	if t.stop then return false end
	if t.index > t.size then
		t.index = 1
	end
	local q = t.queue[t.index]
	for idx,fn in ipairs(q) do
		q[idx] = nil
		local ok, r = pcall(fn[2], fn[3])
		if ok and (r ~= false) then
			local nxt = t:get_dest_index(fn[1])
			local q = t.queue[nxt]
			table.insert(q, fn)
			fn[4] = q
			fn[5] = #q
		end
	end
	t.index = t.index + 1
	return true
end
function taskgrp_index.close(t)
	t.stop = true
end
local task_element_mt = { __index = {} }
function task_element_mt.__index:__cancel(co)
	logger.info('task cancel', self[4][self[5]][3], co)
	assert(self[4][self[5]][3] == co)
	table.remove(self[4], self[5])
end
function taskgrp_index.add(t, start, intv, fn, arg)
	local sidx = t:get_duration_index(start)
	local iidx = t:get_duration_index(intv)
	local dest = t:get_dest_index(sidx)
	local q = t.queue[dest]
	local tuple = {iidx, fn, arg, q}
	local r = setmetatable(tuple, task_element_mt)
	table.insert(q, r)
	tuple[5] = #q
	return r
end
-- sleep
local function sleep_proc(co)
	tentacle.resume(co)
	return false
end
function taskgrp_index.sleep(t, sec)
	local co = tentacle.running()
	if not co then
		logger.report('invalid tentacle called sleep', debug.traceback())
	end
	local tuple = t:add(sec, sec, sleep_proc, co)
	tentacle.yield(tuple)
end
-- alarm
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
-- tick
local function ticker_proc(em)
	if em.arg.stop then return false end
	em:emit('read')
end
local function ticker_preyield(ev, arg)
	arg[1]:add(arg[2], arg[2], ticker_proc, ev)
end
function taskgrp_index.ticker(t, intv)
	return event.new(ticker_preyield, {t, intv})
end
function taskgrp_index.stop_ticker(t, ev)
	ev.arg.stop = true
end
-- new gropu
function _M.newgroup(p, intv, max_duration)
	local tg = taskgrp_new(intv, max_duration)
	_M.new(p, 0, intv, tg.loop, tg)
	return tg
end

return _M

--[[

おおむね以下のような気分で操作できることを目指す.

-- wait one of the following events
local ignore_close = false
local type,object = event.wait(ignore_close, io:ev('read'), io2:ev('read'), io2:ev('shutdown'), timer.timeout(1000))
if type == 'read' then
	if object == io then
		...
	elseif object == io2 then
		...
	end
elseif recv == 'close' then
	assert(object == io)
elseif recv == 'shutdown' then
	assert(object == io2)
elseif recv == 'timeout' then
	print('timeout')
end

-- join all of following events
local type_object_tuples = event.join(1000, io:ev('read'), io2:ev('read'), io3:ev('read'))
for _,tuple in ipairs(type_object_tuples) do
	print(tuple[1], tuple[2])
end

-- 
io:emit('read')

]]

local ffi = require 'ffi'
local _M = {}

local eventlist = {}
local readlist, writelist = {}, {}

local ev_index = {}
local ev_mt = { __index = ev_index }
function ev_index.emit(t, type, ...)
-- logger.notice('evemit:', t, type, #t.waitq, debug.traceback())
	for _,co in ipairs(t.waitq) do
		-- waitq cleared inside resumed functions
		coroutine.resume(co, type, t, ...)
	end
end
function ev_index.destroy(t, reason)
	t:emit('destroy', t, reason)
end

function _M.add_to(emitter, type, py)
	local id = emitter:__emid()
	local evlist = eventlist[id]
	if not evlist then
		evlist = {}
		eventlist[id] = evlist
	end
	local ev = evlist[type]
	if not ev then
		ev = {
			emitter = emitter,
			waitq = {},
			pre_yield = (py or function () end),
		}
		evlist[type] = ev
	else
		ev.emitter = emitter
	end
	assert(#ev.waitq == 0)
	return ev
end

-- py : callable. do something before wait this event.
function _M.new(py, arg)
	local r = setmetatable({
		waitq = {},
		pre_yield = (py or function () end),
		arg = arg,
	}, ev_mt)
	r.emitter = r
	return r
end

function _M.get(emitter, type)
	local id = emitter:__emid()
	return eventlist[id][type]
end

function _M.destroy(emitter, reason)
	local id = emitter:__emid()
	local evlist = eventlist[id]
	for type,ev in pairs(evlist) do
		_M.emit_destroy(emitter, ev, reason)
	end
end

function _M.emit_destroy(emitter, ev, reason)
	for _,co in ipairs(ev.waitq) do
		-- waitq cleared inside resumed functions
		coroutine.resume(co, 'destroy', emitter, reason)
	end
end	

function _M.emit(emitter, type, ...)
	local id = emitter:__emid()
	local ev = eventlist[id][type] -- assert(eventlist[id][type], "event not created "..type)
	for _,co in ipairs(ev.waitq) do
		coroutine.resume(co, type, ev, ...)
	end
end

local function unregister_thread(ev, co)
	for i=1,#ev.waitq do
		if ev.waitq[i] == co then
			-- print('remove coro from event', k, co)
			table.remove(ev.waitq, i)
			break
		end
	end
end

-- provide select syscall for set of events.
-- selector must be table, which table value key must be event object.
-- and its value is event handler function, which receive (selector table itself, all args returned from event emitter...)
-- other kind of key (eg string key) can be any object.
function _M.select(selector)
	local co = pulpo_assert(coroutine.running(), "main thread")
	for k, v in pairs(selector) do
		if type(k) == 'table' and type(v) == 'function' then
			table.insert(k.waitq, co)
			k.pre_yield(k.emitter, k.arg)
		end
	end
	local tmp, rev, ok, ret
	while true do
		tmp = {coroutine.yield()}
		rev = tmp[2]
		ok, ret = pcall(selector[rev], selector, unpack(tmp))
		if (not ok) or ret then break end
	end
	for k, v in pairs(selector) do
		if type(k) == 'table' and type(v) == 'function' then
			unregister_thread(k, co)
		end
	end
	return ok, ret
end

-- wait one of the events specified in ..., is emitted.
-- you can skip some unnecessary kind of event by filtering with *filter*
-- if filter returns true, then select returns, otherwise *select* wait for next event to be emitted.
function _M.wait(filter, ...)
	local co = pulpo_assert(coroutine.running(), "main thread")
	local list = {...}
	pulpo_assert(#list > 0, "no events to wait:"..#list)
	for i=1,#list,1 do
		local ev = list[i]
		table.insert(ev.waitq, co)
		ev.pre_yield(ev.emitter, ev.arg)
	end
	local tmp, rev
	while true do
		tmp = {coroutine.yield()}
		if not filter then break end
		rev = tmp[2]
		tmp[2] = rev.emitter
		if filter(tmp) then
			break
		end
	end
	-- if rev (received event) not set, then tmp is received event
	-- in case no filter.
	if not rev then
		rev = tmp[2]
		tmp[2] = rev.emitter
	end
	for i=1,#list,1 do
		local ev = list[i]
		if rev == ev then
			assert(co == ev.waitq[1])
			table.remove(ev.waitq, 1)
		else
			unregister_thread(ev, co)
		end
	end
	return unpack(tmp)
end

-- join all event specified in ... 
-- actually timeout is not necessary to timeout event
-- if timeout is not falsy, 
-- *join* also wait timeout and if it is emitted, all unemitted events are marked as 'timeout'
-- if all events except *timeout*, is emitted, *join* no more wait for emitting *timeout*.
-- if *timeout* is falsy (nil or false), *join* just wait for all other event permanently.
-- 
-- returns array which emitted result in emit order, except result for timeout event object.
-- it will be placed last of returned array.
function _M.join(timeout, ...)
	local co = pulpo_assert(coroutine.running(), "main thread")
	local list = {...}
	if timeout then
		table.insert(list, timeout)
	end
	pulpo_assert(#list > 0, "no events to wait")
	for i=1,#list,1 do
		local ev = list[i]
		table.insert(ev.waitq, co)
		-- logger.notice(ev, "waitq:", #ev.waitq, co)
		ev.pre_yield(ev.emitter, ev.arg)
	end
	local ret = {}
	-- -1 for timeout event (its not necessary to emit)
	local emit,required = 0,timeout and (#list - 1) or #list
	while true do
		local tmp = {coroutine.yield()}
		-- print('wait emit:', unpack(tmp), debug.traceback())
		local rev = tmp[2]
		tmp[2] = rev.emitter
		if timeout and rev == timeout then
			-- timed out. 
			for i=1,#list,1 do
				local ev = list[i]
				-- all unemitted events are marked as timeout
				if rev ~= ev then
					table.insert(ret, {'timeout', ev.emitter})
				end
				unregister_thread(ev, co)
			end
			table.insert(ret, tmp)
			return ret
		else
			table.insert(ret, tmp)
			for i=1,#list,1 do
				local ev = list[i]
				if rev == ev then
					table.remove(list, i)
					assert(co == ev.waitq[1])
					table.remove(ev.waitq, 1)
					break
				end
			end
			emit = emit + 1
			--print('status:', emit, required)
			if emit >= required then
				-- maybe timeout remain
				break
			end
		end
	end
	if timeout then
		table.insert(ret, {'ontime', timeout.emitter})
		unregister_thread(timeout, co)
	end
	return ret
end

-------------------------------------------------------------------------
-- for read/write, we prepared optimized version of create/ev/single wait/emit
-- because these are used so frequent
-------------------------------------------------------------------------
function _M.add_read_to(io)
	local id = io:__emid()
	local ev = readlist[id]
	if not ev then
		ev = _M.add_to(io, 'read', io.read_yield)
		readlist[id] = ev
	else
		ev.emitter = io
	end
	return ev
end

function _M.ev_read(io)
	return assert(readlist[io:__emid()], "not initialized")
end

-- if return false, pipe error caused
function _M.wait_read(io)
	local co = pulpo_assert(coroutine.running(), "main thread")
	local ev = _M.ev_read(io)
	table.insert(ev.waitq, co)
	io:read_yield()
	local t = coroutine.yield()
	assert(ev.waitq[1] == co)
	table.remove(ev.waitq, 1)
	return t ~= 'destroy'
end

function _M.wait_emit(io)
	local co = pulpo_assert(coroutine.running(), "main thread")
	local ev = _M.ev_read(io)
	table.insert(ev.waitq, co)
	local t = coroutine.yield()
	assert(ev.waitq[1] == co)
	table.remove(ev.waitq, 1)
	return t
end

function _M.emit_read(io)
	-- print('emit_read', io:fd())
	local ev = _M.ev_read(io)
	for _,co in ipairs(ev.waitq) do
		coroutine.resume(co, 'read', ev)
	end
end

function _M.add_write_to(io)
	local id = io:__emid()
	local ev = writelist[id]
	if not ev then
		ev = _M.add_to(io, 'write', io.read_yield)
		writelist[id] = ev
	else
		ev.emitter = io
	end
	return ev
end

function _M.ev_write(io)
	return assert(writelist[io:__emid()], "not initialized")
end

-- if return false, pipe error caused
function _M.wait_write(io)
	-- print('wait_write', io:fd(), debug.traceback())
	local co = pulpo_assert(coroutine.running(), "main thread")
	local ev = _M.ev_write(io)
	table.insert(ev.waitq, co)
	io:write_yield()
	local t = coroutine.yield()
	assert(ev.waitq[1] == co)
	table.remove(ev.waitq, 1)
	return t ~= 'destroy'
end

-- if return false, pipe error caused
function _M.wait_reactivate_write(io)
	-- print('wait_write', io:fd(), debug.traceback())
	local co = pulpo_assert(coroutine.running(), "main thread")
	local ev = _M.ev_write(io)
	table.insert(ev.waitq, co)
	local t = coroutine.yield()
	assert(ev.waitq[1] == co)
	table.remove(ev.waitq, 1)
	return t ~= 'destroy'
end

function _M.emit_write(io)
	-- print('emit_write:', io:fd())
	local ev = _M.ev_write(io)
	for _,co in ipairs(ev.waitq) do
		coroutine.resume(co, 'write', ev)
	end
end

function _M.add_io_events(io)
	_M.add_read_to(io)
	_M.add_write_to(io)
end

return _M

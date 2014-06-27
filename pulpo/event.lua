--[[

おおむね以下のような気分で操作できることを目指す.

-- wait one of the following events
local type,object = event.wait_one(io:ev('read'), io2:ev('read'), io2:ev('shutdown'), timer.timeout(1000))
if type == 'read' then
	if object == io then
		...
	elseif object == io2 then
		...
	end
elseif recv == 'close' then
	pulpo_assert(object == io)
elseif recv == 'shutdown' then
	pulpo_assert(object == io2)
elseif recv == 'timeout' then
	print('timeout')
end

-- wait all of following events
local type_object_tuples = event.wait_all(1000, io:ev('read'), io2:ev('read'), io3:ev('read'))
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

function _M.create(emitter, type, py)
	local id = emitter:id()
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
		assert(#ev.waitq == 0)
	end
	return ev
end

function _M.ev(emitter, type)
	local id = emitter:id()
	return eventlist[id][type]
end

function _M.destroy(emitter)
	local id = emitter:id()
	local evlist = eventlist[id]
	for type,ev in pairs(evlist) do
		_M.emit_close(emitter, ev)
	end
end

function _M.emit_close(emitter, ev)
	for _,co in ipairs(ev.waitq) do
		coroutine.resume(co, 'close', emitter)
	end
end	

function _M.emit(emitter, type, ...)
	local id = emitter:id()
	local ev = pulpo_assert(eventlist[id][type], "event not created "..type)
	for _,co in ipairs(ev.waitq) do
		coroutine.resume(co, type, emitter, ...)
	end
end

-- TODO : add timeout? (but this is wait_one, so just add timer event in args...)
function _M.wait_one(...)
	local co = pulpo_assert(coroutine.running(), "main thread")
	local list = {...}
	for i=1,#list,1 do
		local ev = list[i]
		table.insert(ev.waitq, co)
		ev.pre_yield(ev.emitter)
	end
	local tmp = {coroutine.yield()}
	for i=1,#list,1 do
		local ev = list[i]
		assert(co == ev.waitq[1])
		table.remove(ev.waitq, 1)
	end
	return unpack(tmp)
end

-- TODO : add timeout
function _M.wait_all(timeout, ...)
	local co = pulpo_assert(coroutine.running(), "main thread")
	local list = {...}
	for i=1,#list,1 do
		local ev = list[i]
		table.insert(ev.waitq, co)
		ev.pre_yield(ev.emitter)
	end
	local ret = {}
	local emit,required = 0,#list
	while emit < required do
		local tmp = {coroutine.yield()}
		local object = tmp[2]
		table.insert(ret, tmp)
		for i=1,#list,1 do
			local ev = list[i]
			if object == ev.emitter then
				assert(co == ev.waitq[1])
				table.remove(ev.waitq, 1)
			end
		end
		emit = emit + 1
	end
	return ret
end

-------------------------------------------------------------------------
-- for read/write, we prepared optimized version of create/ev/single wait/emit
-- because these are used so frequent
-------------------------------------------------------------------------
function _M.create_read(io)
	local id = io:id()
	local ev = readlist[id]
	if not ev then
		ev = _M.create(io, 'read', io.read_yield)
		readlist[id] = ev
	else
		ev.emitter = io
	end
	return ev
end

function _M.ev_read(io)
	return assert(readlist[io:id()], "not initialized")
end

function _M.wait_read(io)
	local co = pulpo_assert(coroutine.running(), "main thread")
	local ev = _M.ev_read(io)
	table.insert(ev.waitq, co)
	io:read_yield()
	coroutine.yield()
	assert(ev.waitq[1] == co)
	table.remove(ev.waitq, 1)
end

function _M.emit_read(io)
	local ev = _M.ev_read(io)
	for _,co in ipairs(ev.waitq) do
		coroutine.resume(co, 'read', io)
	end
end

function _M.create_write(io)
	local id = io:id()
	local ev = writelist[id]
	if not ev then
		ev = _M.create(io, 'write', io.read_yield)
		writelist[id] = ev
	else
		ev.emitter = io
	end
	return ev
end

function _M.ev_write(io)
	return assert(writelist[io:id()], "not initialized")
end

function _M.wait_write(io)
	-- print('wait_write', io:fd())
	local co = pulpo_assert(coroutine.running(), "main thread")
	local ev = _M.ev_write(io)
	table.insert(ev.waitq, co)
	io:write_yield()
	coroutine.yield()
	assert(ev.waitq[1] == co)
	table.remove(ev.waitq, 1)
end

function _M.emit_write(io)
	-- print('emit_write:', io:fd())
	local ev = _M.ev_write(io)
	for _,co in ipairs(ev.waitq) do
		coroutine.resume(co, 'write', io)
	end
end

return _M

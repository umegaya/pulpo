--[[

おおむね以下のような気分で操作できることを目指す.

-- wait one of the following events
local type,object = event.wait_one(io:ev('read'), io2:ev('read'), io:ev('close'), io2:ev('shutdown'), timer.timeout(1000))
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
local type_object_tuples = event.wait_all(io:ev('read'), io2:ev('read'), io3:ev('read'))
for _,tuple in ipairs(type_object_tuples) do
	print(tuple[1], tuple[2])
end

-- 
io:emit('read')

]]

local ffi = require 'ffi'
local _M = {}

local eventlist = {}

function _M.create(emitter, type)
	local id = emitter:id()
	local ev = eventlist[id]
	if not ev then
		eventlist[id] = {
			emitter = emitter,
			waitq = {},
		}
	end
	return ev
end

function _M.destroy(emitter)
	local id = emitter:id()
	_M.emit(emitter, 'die')
	eventlist[id] = nil
end

function _M.emit(emitter, type, ...)
	local id = emitter:id()
	local ev = pulpo_assert(eventlist[id], "event not created "..type)
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
	end
	local tmp = {coroutine.yield()}
	for i=1,#list,1 do
		local ev = list[i]
		-- NOTE : if waitq has co as key, following are equivalent to waitq[co] = nil
		-- trade-off to assure emit is processed with FIFO order
		for j=1,#ev.waitq,1 do
			if ev.waitq[j] == co then
				table.remove(ev.waitq, j)
			end
		end
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
	end
	local emit,required = 0,#list
	while emit < required do
		local tmp = {coroutine.yield()}
		local object = tmp[2]
		for i=1,#list,1 do
			local ev = list[i]
			if object == ev.emitter then
				-- NOTE : if waitq has co as key, following are equivalent to waitq[co] = nil
				-- trade-off to assure emit is processed with FIFO order
				for j=1,#ev.waitq,1 do
					if ev.waitq[j] == co then
						table.remove(ev.waitq, j)
					end
				end
			end
		end
		emit = emit + 1
	end
end

return _M

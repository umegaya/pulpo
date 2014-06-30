local pulpo = require 'pulpo.init'
local ffi = require 'ffiex'
-- ffi.__DEBUG_CDEF__ = true

pulpo.initialize({
	cdef_cache_dir = './tmp/cdefs'
})

local event = pulpo.event
local loop = pulpo.mainloop
local task = require 'pulpo.task'
local tcp = require 'pulpo.socket.tcp'

local tg = task.newgroup(loop, 0.05, 10)

pulpo.tentacle.debug = true

-- all routine enclosed by tentacle
pulpo.tentacle(function ()


logger.info('server tentacle')
local n_accept = 0
local ev = pulpo.tentacle(function ()
	local s = tcp.listen(loop, "0.0.0.0:8008")
	while true do
		local _fd = s:read()
		n_accept = n_accept + 1
		logger.info('accept:', _fd:fd())
		pulpo.tentacle(function (fd)
			if n_accept <= 2 then
				-- FIFO
				event.wait(tg:alarm(0.1 * n_accept))
			elseif n_accept == 3 then
				fd:close()
				return
			elseif n_accept == 6 then
				-- FILO
				tg:sleep(0.1 * (7 - n_accept))
			elseif n_accept <= 8 then
				tg:sleep(0.1 * (10 - n_accept))
			elseif n_accept == 9 then
				tg:sleep(0.5)
			elseif n_accept <= 11 then
				tg:sleep(0.1 * (13 - n_accept))
			elseif n_accept == 12 then
				tg:sleep(0.5)
			else
				event.wait(tg:alarm(0.5 * n_accept))
			end
			local ptr,len = ffi.new('char[256]')
			len = fd:read(ptr, 256)
			if len <= 0 then
				return
			end
			fd:write(ptr, len)
		end, _fd)
	end
end)

logger.info('client tentacle')
local finished 
local tp,obj,ok,ret = event.select(false, ev, pulpo.tentacle(function ()
	local s1, s2, s3 = 
		tcp.connect(loop, "127.0.0.1:8008"),
		tcp.connect(loop, "127.0.0.1:8008"),
		tcp.connect(loop, "127.0.0.1:8008")

	s1:write('s1', 2)
	s2:write('s2', 2)
	s3:write('s3', 2)

	local cnt = 0

	-- event which is not destroy, selected.
	local type,object = event.select(function (result)
		cnt = cnt + 1
		logger.info('input to filter:', result[1], cnt > 1 and "processed" or "ignored")
		return cnt > 1
	end, s1:event('read'), s2:event('read'), s3:event('read'))
	if object == s1 then
		logger.info("s1 first")
	elseif object == s2 then
		logger.info("s2 first")
		assert(false)
	elseif object == s3 then
		logger.info("s3 first")
		assert(false)
	else
		assert(false, "unknown object returned")
	end
	finished = true
	return "bar"
end))

logger.info("wait result", tp,obj,ok,ret)

assert(tp == "end" and ok == true and ret == "bar", "something wrong with event processing")
assert(finished, "event.wait should block until above tentacle done")

event.wait(pulpo.tentacle(function ()
	local s1, s2, s3 = 
		tcp.connect(loop, "127.0.0.1:8008"),	
		tcp.connect(loop, "127.0.0.1:8008"),
		tcp.connect(loop, "127.0.0.1:8008")

	s1:write('s1', 2)
	s2:write('s2', 2)
	s3:write('s3', 2)

	local results = event.wait(s1:event('read'), s2:event('read'), s3:event('read'))
	for idx,r in ipairs(results) do
		local io = r[2]
		if io == s1 then
			logger.info(idx, "s1")
			assert(idx == 3)
		elseif io == s2 then
			logger.info(idx, "s2")
			assert(idx == 2)
		elseif io == s3 then
			logger.info(idx, "s3")
			assert(idx == 1)
		else
			assert(false, "unknown object returned")
		end
	end
end))

event.wait(pulpo.tentacle(function ()
	local s1, s2, s3 = 
		tcp.connect(loop, "127.0.0.1:8008"),	
		tcp.connect(loop, "127.0.0.1:8008"),
		tcp.connect(loop, "127.0.0.1:8008")

	s1:write('s1', 2)
	s2:write('s2', 2)
	s3:write('s3', 2)

	local alarm = tg:alarm(0.4)
	local type,object = event.select(false, alarm, event.wait_event(s1:event('read'), s2:event('read'), s3:event('read')))
	print(type, object)
	assert(type=="read" and alarm == object)
end))

pulpo.tentacle(function ()
	local s1, s2, s3 = 
		tcp.connect(loop, "127.0.0.1:8008"),	
		tcp.connect(loop, "127.0.0.1:8008"),
		tcp.connect(loop, "127.0.0.1:8008")

	s1:write('s1', 2)
	s2:write('s2', 2)
	s3:write('s3', 2)

	local waitev = event.wait_event(s1:event('read'), s2:event('read'), s3:event('read'))
	local type,object,results = event.select(false, tg:alarm(0.6), waitev)
	print(type, object)
	assert(type=="done" and object == waitev)
	for idx,r in ipairs(results) do
		local io = r[2]
		if io == s1 then
			logger.info(idx, "s1")
			assert(idx == 2)
		elseif io == s2 then
			logger.info(idx, "s2")
			assert(idx == 1)
		elseif io == s3 then
			logger.info(idx, "s3")
			assert(idx == 3)
		else
			assert(false, "unknown object returned")
		end
	end

	loop:stop()
end)

--- end of main tentacle
end)


-- start asynchronous execution
loop:loop()


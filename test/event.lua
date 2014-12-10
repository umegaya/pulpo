local ffi = require 'ffiex.init'
-- ffi.__DEBUG_CDEF__ = true
local pulpo = (require 'pulpo.init').initialize({
	cache_dir = '/tmp/pulpo'
})

local event = pulpo.event
local loop = pulpo.evloop
local clock = pulpo.clock
local tcp = loop.io.tcp
local clock = loop.clock.new(0.05, 10)

pulpo.tentacle.debug = true

-- all routine enclosed by tentacle
pulpo.tentacle(function ()


logger.info('--------------------------- server tentacle')
local n_accept = 0
local ev = pulpo.tentacle(function ()
	local s = tcp.listen("0.0.0.0:8008")
	while true do
		local _fd = s:read()
		n_accept = n_accept + 1
		logger.info('accept:', _fd:fd())
		pulpo.tentacle(function (fd)
			if n_accept <= 2 then
				-- FIFO
				event.join(clock:alarm(0.1 * n_accept))
			elseif n_accept == 3 then
				fd:close()
				return
			elseif n_accept == 6 then
				-- FILO
				clock:sleep(0.1 * (7 - n_accept))
			elseif n_accept <= 8 then
				clock:sleep(0.1 * (10 - n_accept))
			elseif n_accept == 9 then
				clock:sleep(0.5)
			elseif n_accept <= 11 then
				clock:sleep(0.1 * (13 - n_accept))
			elseif n_accept == 12 then
				clock:sleep(0.5)
			elseif n_accept <= 14 then
				clock:sleep(0.1 * (16 - n_accept))
			elseif n_accept == 15 then
				clock:sleep(0.5)
			elseif n_accept <= 17 then
				clock:sleep(0.1 * (19 - n_accept))
			elseif n_accept == 18 then
				clock:sleep(0.5)
			else
				event.join(clock:alarm(0.5 * n_accept))
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

logger.info('--------------------------- select with filter test')
local finished 
local tp,obj,ok,ret = event.wait(false, pulpo.tentacle(function ()
	local s1, s2, s3 = 
		tcp.connect("127.0.0.1:8008"),
		tcp.connect("127.0.0.1:8008"),
		tcp.connect("127.0.0.1:8008")

	s1:write('s1', 2)
	s2:write('s2', 2)
	s3:write('s3', 2)

	local cnt = 0

	-- event which is not destroy, selected.
	local type,object = event.wait(function (result)
		cnt = cnt + 1
		logger.info('input to filter:', result[1], result[2]:fd(), cnt > 1 and "processed" or "ignored")
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
assert(finished, "event.join should block until above tentacle done")

logger.info('--------------------------- wait test')
event.join(pulpo.tentacle(function ()
	local s1, s2, s3 = 
		tcp.connect("127.0.0.1:8008"),	
		tcp.connect("127.0.0.1:8008"),
		tcp.connect("127.0.0.1:8008")

	s1:write('s1', 2)
	s2:write('s2', 2)
	s3:write('s3', 2)

	local results = event.join(false, s1:event('read'), s2:event('read'), s3:event('read'))
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

logger.info('--------------------------- wait_event test1')
event.join(pulpo.tentacle(function ()
	local s1, s2, s3 = 
		tcp.connect("127.0.0.1:8008"),	
		tcp.connect("127.0.0.1:8008"),
		tcp.connect("127.0.0.1:8008")

	s1:write('s1', 2)
	s2:write('s2', 2)
	s3:write('s3', 2)

	local alarm = clock:alarm(0.4)
	local type,object = event.wait(false, alarm, event.join_event(false, s1:event('read'), s2:event('read'), s3:event('read')))
	print(type, object)
	assert(type=="read" and alarm == object)
end))

logger.info('--------------------------- wait_event test2')
event.join(pulpo.tentacle(function ()
	local s1, s2, s3 = 
		tcp.connect("127.0.0.1:8008"),	
		tcp.connect("127.0.0.1:8008"),
		tcp.connect("127.0.0.1:8008")

	s1:write('s1', 2)
	s2:write('s2', 2)
	s3:write('s3', 2)

	local waitev = event.join_event(false, s1:event('read'), s2:event('read'), s3:event('read'))
	local type,object,results = event.wait(false, clock:alarm(0.6), waitev)
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
end))

logger.info('--------------------------- timed wait test1')
event.join(pulpo.tentacle(function ()
	local s1, s2, s3 = 
		tcp.connect("127.0.0.1:8008"),	
		tcp.connect("127.0.0.1:8008"),
		tcp.connect("127.0.0.1:8008")

	s1:write('s1', 2)
	s2:write('s2', 2)
	s3:write('s3', 2)

	local alarm = clock:alarm(0.4)
	local results = event.join(alarm, s1:event('read'), s2:event('read'), s3:event('read'))
	print('results:', #results)
	for idx,r in ipairs(results) do
		local io = r[2]
		if io == s1 then
			logger.info(idx, "s1", r[1])
			assert(r[1] == 'read')
			assert(idx == 2)
		elseif io == s2 then
			logger.info(idx, "s2", r[1])
			assert(r[1] == 'read')
			assert(idx == 1)
		elseif io == s3 then
			logger.info(idx, "s3", r[1])
			assert(r[1] == 'timeout')
			assert(idx == 3)
		elseif io == alarm then
			logger.info(idx, "alarm", r[1])
			assert(r[1] == 'read')
			assert(idx == 4)
		else
			assert(false, "unknown object returned")
		end
	end
end))

logger.info('--------------------------- timed wait test2')
event.join(pulpo.tentacle(function ()
	local s1, s2, s3 = 
		tcp.connect("127.0.0.1:8008"),	
		tcp.connect("127.0.0.1:8008"),
		tcp.connect("127.0.0.1:8008")

	s1:write('s1', 2)
	s2:write('s2', 2)
	s3:write('s3', 2)

	local alarm = clock:alarm(0.6)
	local results = event.join(alarm, s1:event('read'), s2:event('read'), s3:event('read'))
	print('results:', #results)
	for idx,r in ipairs(results) do
		local io = r[2]
		if io == s1 then
			logger.info(idx, "s1", r[1])
			assert(r[1] == 'read')
			assert(idx == 2)
		elseif io == s2 then
			logger.info(idx, "s2", r[1])
			assert(r[1] == 'read')
			assert(idx == 1)
		elseif io == s3 then
			logger.info(idx, "s3", r[1])
			assert(r[1] == 'read')
			assert(idx == 3)
		elseif io == alarm then
			logger.info(idx, "alarm", r[1])
			assert(r[1] == 'ontime')
			assert(idx == 4)
		else
			assert(false, "unknown object returned")
		end
	end
end))

logger.info('--------------------------- select test')
event.join(pulpo.tentacle(function ()
	local t1, t2, t3 = clock:ticker(0.2), clock:ticker(0.3), clock:ticker(0.4)
	local selector = {
		c1 = 0, c2 = 0, c3 = 0,
		check = function (t)
			return t.c1 >= 6 and t.c2 >= 4 and t.c3 >= 3
		end,
		[t1] = function (t)
			t.c1 = t.c1 + 1
			return t:check()
		end,
		[t2] = function (t)
			t.c2 = t.c2 + 1
			return t:check()
		end,
		[t3] = function (t)
			t.c3 = t.c3 + 1
			return t:check()
		end,
	}
	event.select(selector)
	print(selector.c1, selector.c2, selector.c3)
	assert(selector:check())
	clock:stop_ticker(t1)
	clock:stop_ticker(t2)
	clock:stop_ticker(t3)
end))

--- end of main tentacle
loop:stop()
end)


-- start asynchronous execution
loop:loop()

return true

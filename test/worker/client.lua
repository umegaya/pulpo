local ffi = require 'ffiex'
local pulpo = require 'pulpo.init'
local tentacle = pulpo.tentacle
local gen = require 'pulpo.generics'
local memory = require 'pulpo.memory'
local tcp = require 'pulpo.socket.tcp'

local C = ffi.C
local PT = ffi.load("pthread")

local loop = pulpo.mainloop
local config = pulpo.share_memory('config')
local concurrency = math.floor(config.n_client / config.n_client_core)
local finished = pulpo.share_memory('finished', function ()
	ffi.cdef [[
		typedef struct exec_state {
			int cnt;
			double start_time;
		} exec_state_t;
	]]
	local t = gen.rwlock_ptr('exec_state_t')
	local p = memory.alloc_typed(t)
	p:init(function (data) 
		data.cnt = 0 
		data.start_time = os.clock()
	end)
	return t, p
end)

local client_msg = ("hello,luact poll"):rep(16)
for i=0,concurrency - 1,1 do
	tentacle(function ()
		local s = tcp.connect(loop, '127.0.0.1:8008')
-- logger.info("start tentacle", s:fd())
		io.stdout:write("-"); io.stdout:flush()
		local ptr,len = ffi.new('char[256]')
		local i = 0
		while i < config.n_iter do
			-- print('write start:', s:fd())
			s:write(client_msg, #client_msg)
			-- print('write end:', s:fd())
			len = s:read(ptr, 256) --> malloc'ed char[?]
			if len <= 0 then
				logger.info('closed', s:fd())
				break
			end
			local msg = ffi.string(ptr,len)
			pulpo_assert(msg == client_msg, "illegal packet received:"..msg)
			i = i + 1
		end
		PT.pthread_rwlock_wrlock(finished.lock)
		io.stdout:write("+"); io.stdout:flush()
		finished.data.cnt = finished.data.cnt + 1
		PT.pthread_rwlock_unlock(finished.lock)
		if finished.data.cnt >= config.n_client then
			io.stdout:write("\n")
			logger.info('test takes', os.clock() - finished.data.start_time, 'sec')
			pulpo.stop()
			config.finished = true
		end
	end)
end

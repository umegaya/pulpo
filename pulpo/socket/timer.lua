--[[
 timer : generate 'tick' event for specified interval and initial_duration.

tentacle(function (timer, cb)
	while true do
		local type = event.select(timer.ev('tick'))
		if not cb(timer) then
			break
		end
	end
	timer:close()
end)

taskgrp (light weight periodic execution)
find procs which should execute specified timing with O(1)

taskgrp:add(function (taskgrp)
	...
end)
taskgrp:sleep(time)
]]
local ffi = require 'ffiex'
local poller = require 'pulpo.poller'
local util = require 'pulpo.util'
local memory = require 'pulpo.memory'
local errno = require 'pulpo.errno'
local socket = require 'pulpo.socket'
local tentacle = require 'pulpo.tentacle'

local C = ffi.C
local _M = {}

ffi.cdef [[
	typedef union pulpo_timer_payload {
		long long int data;
		char p[0];
	} pulpo_timer_payload_t;
]]
local timer_payload = ffi.new('pulpo_timer_payload_t')
local timer_payload_size = ffi.sizeof('pulpo_timer_payload_t')

--> handlers
local function timer_read(io)
	io:wait_timer()
	if ffi.os == "OSX" then
		return io.ev.data
	elseif ffi.os == "Linux" then
		assert(timer_payload_size == C.recv(io:fd(), timer_payload.p, timer_payload_size, 0))
		return timer_payload.data
	end
end

local function timer_gc(io)
	C.close(io:fd())
end

local HANDLER_TYPE_TIMER = poller.add_handler(timer_read, nil, timer_gc)

if ffi.os == "OSX" then
------------------------------------------------------------
-- OSX : using kqueue EVFILT_TIMER
------------------------------------------------------------
require 'pulpo.poller.kqueue' -- here it is assured that kqueue is available

_M.original_socket = socket.create_unix_domain()
_M.timer_event = ffi.new('pulpo_event_t[1]')
function _M.create(p, start, intv, ctx)
	local fd = socket.dup(_M.original_socket)
	if not fd then error('fail to create socket:'..errno.errno()) end
	if not p:add_timer(fd, start, intv) then 
		C.close(fd)
		error('fd:'..fd..': fail to add timer:'..errno.errno()) 
	end
	logger.info('timer:', fd, start, intv)
	return p:newio(fd, HANDLER_TYPE_TIMER, ctx)
end


elseif ffi.os == "Linux" then
------------------------------------------------------------
-- linux : using timerfd
------------------------------------------------------------
-- load cdefs
local loader = require 'pulpo.loader'
local ffi_state = loader.load('timer.lua', {
	"timerfd_create", "timerfd_settime", "timerfd_gettime",
}, {
	"CLOCK_MONOTONIC", "CLOCK_REALTIME"
}, nil, [[
	#include <sys/timerfd.h>
]])

-- define
local CLOCK_MONOTONIC = ffi_state.defs.CLOCK_MONOTONIC
local CLOCK_REALTIME = ffi_state.defs.CLOCK_REALTIME

-- vars
_M.start = ffi.new('struct timespec[1]')
_M.intv = ffi.new('struct timespec[1]')
_M.itimerspec = ffi.new('struct itimerspec[1]')

function _M.create(p, start, intv, ctx)
	local fd = C.timerfd_create(CLOCK_MONOTONIC)
	if fd < 0 then
		error('fail to timerfd_create:'..errno.errno())
	end
	if socket.setsockopt(fd) < 0 then
		error('fail to set sockopt:'..errno.errno())
	end
	util.sec2timespec(start, _M.start)
	util.sec2timespec(intv, _M.intv)
	_M.itimerspec[0].it_interval = _M.intv[0]
	_M.itimerspec[0].value = _M.start[0]
	if timerfd_settime(fd, _M.itimerspec, nil) < 0 then
		error('fail to timerfd_settime:'..errno.errno())
	end
	logger.info('timer:', fd, start, intv)
	return p:newio(fd, HANDLER_TYPE_TIMER, ctx)
end


else
	assert(false, "timer: unsupported OS:"..ffi.os)
end

return _M

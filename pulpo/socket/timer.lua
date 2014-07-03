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
local timer_read
if ffi.os == "OSX" then
timer_read = function (io)
	local tp = io:wait_timer()
	if tp == 'destroy' then
		return nil
	end
	return io.ev.data
end
elseif ffi.os == "Linux" then
timer_read = function (io)
::retry::
	local tp = io:wait_timer()
	if tp == 'destroy' then
		return nil
	end
	local n = C.read(io:fd(), timer_payload.p, timer_payload_size)
	if n < 0 then
		local eno = errno.errno()
		print('C.read', eno)
		goto retry
	end		
	assert(timer_payload_size == n)
	return timer_payload.data
end
else
error('unsupported os:'..ffi.os)
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
	"CLOCK_MONOTONIC", "CLOCK_REALTIME", "TFD_TIMER_ABSTIME",
}, nil, [[
	#include <sys/timerfd.h>
]])
local rt
ffi_state, rt = loader.load("rtclock.lua", {
	"clock_gettime",
}, {
}, "rt", [[
	#include <time.h>
]])

-- define
local CLOCK_MONOTONIC = ffi_state.defs.CLOCK_MONOTONIC
local CLOCK_REALTIME = ffi_state.defs.CLOCK_REALTIME
local TFD_TIMER_ABSTIME = 1 -- current ffiex cannot handle definition which is defined by symbol of anon enum

-- vars
_M.start = ffi.new('struct timespec[1]')
_M.current = ffi.new('struct timespec[1]')
_M.intv = ffi.new('struct timespec[1]')
_M.itimerspec = ffi.new('struct itimerspec[1]')

function _M.create(p, start, intv, ctx)
	local fd = C.timerfd_create(CLOCK_MONOTONIC, 0)
	if fd < 0 then
		error('fail to timerfd_create:'..errno.errno())
	end
	if socket.setsockopt(fd) < 0 then
		error('fail to set sockopt:'..errno.errno())
	end
	if rt.clock_gettime(CLOCK_MONOTONIC, _M.current) < 0 then
		C.close(fd)
		error('fail to get clock:'..errno.errno())
	end
	util.sec2timespec(start, _M.start)
	util.sec2timespec(intv, _M.intv)
	_M.start[0].tv_sec = (_M.start[0].tv_sec + _M.current[0].tv_sec)
	local ns = (_M.start[0].tv_nsec + _M.current[0].tv_nsec)
	if ns >= (1000 * 1000 * 1000) then
		_M.start[0].tv_nsec = (ns - (1000 * 1000 * 1000))
		_M.start[0].tv_sec = _M.start[0].tvsec + 1
	end
	_M.itimerspec[0].it_interval = _M.intv[0]
	_M.itimerspec[0].it_value = _M.start[0]
	if C.timerfd_settime(fd, TFD_TIMER_ABSTIME, _M.itimerspec, nil) < 0 then
		C.close(fd)
		error('fail to timerfd_settime:'..errno.errno())
	end
	logger.info('timer:', fd, start, intv, HANDLER_TYPE_TIMER)
	
	return p:newio(fd, HANDLER_TYPE_TIMER, ctx)
end


else
	assert(false, "timer: unsupported OS:"..ffi.os)
end

return _M

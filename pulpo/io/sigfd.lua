local ffi = require 'ffiex.init'
local poller = require 'pulpo.poller'
local util = require 'pulpo.util'
local memory = require 'pulpo.memory'
local errno = require 'pulpo.errno'
local socket = require 'pulpo.socket'
local signal = require 'pulpo.signal'
local raise = (require 'pulpo.exception').raise


local C = ffi.C
local _M = {}
_M.iolist = {}

local signal_payload
local signal_payload_size

local EAGAIN = errno.EAGAIN
local EWOULDBLOCK = errno.EWOULDBLOCK

--> handlers
local timer_read
if ffi.os == "OSX" then
assert(false, "sorry, currently OSX sigfd not supported due to the problem of ident collision problem")
signal_read = function (io)
	local tp = io:wait_emit()
	if tp == 'destroy' then
		return nil
	end
	return io.ev.data
end
elseif ffi.os == "Linux" then
signal_read = function (io)
::retry::
	local n = C.read(io:fd(), signal_payload.p, signal_payload_size)
	if n < 0 then
		local eno = errno.errno()
		if eno == EAGAIN or eno == EWOULDBLOCK then
			io:wait_emit()
			goto retry
		else
			logger.error('sigfd:errno:', eno)
			return nil
		end
	end		
	assert(signal_payload_size == n)
	return signal_payload.data.ssi_signo
end
else
error('unsupported os:'..ffi.os)
end

local function signal_gc(io)
	C.close(io:fd())
end

local HANDLER_TYPE_SIGNAL = poller.add_handler("signal", signal_read, nil, signal_gc)

if ffi.os == "OSX" then
------------------------------------------------------------
-- OSX : using kqueue EVFILT_TIMER
------------------------------------------------------------
-- cdefs
-- define
-- vars
-- module functions
_M.original_socket = socket.unix_domain()
function _M.new(p, sig)
	local fd = socket.dup(_M.original_socket)
	if not fd then 
		raise('syscall', 'dup', errno.errno()) 
	end
	local signo = type(sig) == 'number' and sig or signal[sig]
	if not p:add_signal(fd, signo) then 
		C.close(fd)
		raise('poller', 'fail to add signal', fd, errno.errno())
	end
	logger.info('signal:', fd, sig)
	-- blocking default behavior of sigfd'ed signals
	signal.maskctl('add', sig)
	return p:newio(fd, HANDLER_TYPE_SIGNAL)
end


elseif ffi.os == "Linux" then
------------------------------------------------------------
-- linux : using timerfd
------------------------------------------------------------
-- cdefs
local loader = require 'pulpo.loader'
local ffi_state = loader.load('sigfd.lua', {
	"signalfd", "pulpo_signal_payload_t"
}, {}, nil, [[
	#include <sys/signalfd.h>
	typedef union pulpo_signal_payload {
		struct signalfd_siginfo data;
		char p[0];
	} pulpo_signal_payload_t;
]])
signal_payload = ffi.new('pulpo_signal_payload_t')
signal_payload_size = ffi.sizeof('pulpo_signal_payload_t')
-- define
-- vars
-- module functions
function _M.new(p, sig)
	local sigset = signal.makesigset(nil, sig)
	local fd = C.signalfd(-1, sigset, 0)
	if fd < 0 then
		raise('syscall', 'signalfd', errno.errno())
	end
	if socket.setsockopt(fd) < 0 then
		raise('syscall', 'setsockopt', errno.errno())
	end
	logger.info('signal:', fd, sig)
	-- blocking default behavior of sigfd'ed signals
	signal.maskctl('add', sig)
	return p:newio(fd, HANDLER_TYPE_SIGNAL)
end


else
	assert(false, "timer: unsupported OS:"..ffi.os)
end

function _M.newgroup(p)
	return setmetatable({__poller = p}, {
		__index = function (t, k)
			local v = _M.new(t.__poller, k)
			rawset(t, k, v)
			return v
		end
	})
end

return _M
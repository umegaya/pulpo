local ffi = require 'ffiex.init'
local memory = require 'pulpo.memory'
local util = require 'pulpo.util'
local thread = require 'pulpo.thread'
local loader = require 'pulpo.loader'

local C = ffi.C
local _M = (require 'pulpo.package').module('pulpo.defer.signal_c')
local ffi_state, PT

loader.load("signal.lua", {
	"signal", "sigaction", "func sigaction", 
	"sigemptyset", "sigaddset", "sig_t", 
}, {
	"SIGHUP", "SIGPIPE", "SIGKILL", "SIGALRM", "SIGSEGV", 
	"SA_RESTART", "SA_SIGINFO", 
	"SIG_BLOCK", "SIG_UNBLOCK", "SIG_SETMASK",  
	regex = {
		"^SIG%w+"
	}
}, nil, [[
	#include <signal.h>
]])
ffi_state, PT = loader.load("pthread_signal.lua", {
	"pthread_sigmask"
}, {}, thread.PTHREAD_LIB_NAME, [[
	#include <signal.h>
]])

--> that is really disappointing, but macro SIG_IGN is now cannot processed correctly. 
local SIG_IGN = ffi.cast("sig_t", 1)
local SA_RESTART = ffi.defs.SA_RESTART
local SA_SIGINFO = ffi.defs.SA_SIGINFO
local SIGMASK_OP = {
	add = ffi.defs.SIG_BLOCK,
	del = ffi.defs.SIG_UNBLOCK,
	set = ffi.defs.SIG_SETMASK
}

--> determine correct sighandler signature
local sighandler_t
if ffi.os == "OSX" then
	sighandler_t = ffi.typeof('void (*)(int, struct __siginfo *, void *)')
elseif ffi.os == "Linux" then
	sighandler_t = ffi.typeof('void (*)(int, siginfo_t *, void *)')
else
	pulpo_assert(false, "unsupported OS:"..ffi.os)
end
--> and way to get fault address from siginfo.
local function faultaddr(si)
	if ffi.os == "OSX" then
		return si.si_addr
	elseif ffi.os == "Linux" then
		return si._sifields._sigfault.si_addr
	else
		pulpo_assert(false, "unsupported OS:"..ffi.os)
	end
end

--> setup signal handler exactly called from the thread which signal occurs
_M.signal_handlers = {}
thread.tls.common_signal_handler = ffi.cast(sighandler_t, function (sno, info, p)
	-- print('sig handler(called):', _M.signal_handlers)
	_M.signal_handlers[sno](sno, info, p)
end)
-- print('sig handler(init):', _M.signal_handlers, callback)

_M.common_signal_handler = ffi.cast(sighandler_t, function (sno, info, p)
	-- this may called from another 
	ffi.cast(sighandler_t, thread.tls.common_signal_handler)(sno, info, p)
end)

_M.original_signals = {}
thread.register_exit_handler("signal.lua", function ()
	for signo, sa in pairs(_M.original_signals) do
		logger.debug('rollback signal', signo)
		C.sigaction(signo, sa, nil)
		memory.free(sa)
	end
end)

function _M.makesigset(set, ...)
	local sigset = set
	if not sigset then
		sigset = ffi.new('sigset_t[1]')
		C.sigemptyset(sigset)
	end
	local sigs = {...}
	for _,sig in ipairs(sigs) do
		local signo = type(sig) == 'number' and sig or _M[sig]
		assert(signo, "invalid signal definition:"..tostring(sig))
		C.sigaddset(sigset, signo)
	end
	return sigset
end

function _M.maskctl(op, ...)
	local sigset = _M.makesigset(nil, ...)
	assert(0 == PT.pthread_sigmask(SIGMASK_OP[op], sigset, nil), op..":procmask fails:"..ffi.errno())
end

function _M.ignore(signo)
	signo = (type(signo) == 'number' and signo or _M[signo])
	local sa = memory.managed_alloc_typed('struct sigaction')
	if C.sigaction(signo, nil, sa) ~= 0 then
		return false
	end
	sa[0].sa_flags = bit.band(bit.bnot(SA_SIGINFO), sa[0].sa_flags)
	if ffi.os == "OSX" then
		sa[0].__sigaction_u.__sa_handler = SIG_IGN
	elseif ffi.os == "Linux" then
		sa[0].__sigaction_handler.sa_handler = SIG_IGN
	else
		pulpo_assert(false, "unsupported OS:"..ffi.os)
	end
	if 0 ~= C.sigaction(signo, sa, nil) then
		logger.error("sigaction fails:", ffi.errno())
		return false
	end
	return true
end

function _M.signal(signo, handler, optional_saflags)
	_M.maskctl("del", signo)
	signo = (type(signo) == 'number' and signo or _M[signo])
	local sa = memory.managed_alloc_typed('struct sigaction')
	if not _M.original_signals[tonumber(signo)] then
		local prev = memory.alloc_typed('struct sigaction')
		if C.sigaction(signo, nil, prev) ~= 0 then
			return false
		end
		_M.original_signals[tonumber(signo)] = prev
	end
	local sset = memory.managed_alloc_typed('sigset_t')
	if ffi.os == "OSX" then
		sa[0].__sigaction_u.__sa_sigaction = _M.common_signal_handler
	elseif ffi.os == "Linux" then
		sa[0].__sigaction_handler.sa_sigaction = _M.common_signal_handler
	else
		pulpo_assert(false, "unsupported OS:"..ffi.os)
	end
	_M.signal_handlers[tonumber(signo)] = handler
	sa[0].sa_flags = bit.bor(SA_SIGINFO, SA_RESTART, optional_saflags or 0)
	if C.sigemptyset(sset) ~= 0 then
		return false
	end
	sa[0].sa_mask = sset[0]
	return C.sigaction(signo, sa, ffi.NULL) ~= 0
end

-- enable resolve signal value from signal macro symbol (like SIGSEGV)
setmetatable(_M, {
	__index = function (t, k)
		local v = ffi_state.defs[k]
		pulpo_assert(v, "no signal definition:"..k)
		rawset(t, k, v)
		return v
	end
})

-- show segv stacktrace. I understand that is unsafe. 
-- but even if app is crushed by such an unsafe operation, so what?
-- sooner or later it is crushed by illegal memory access. 
-- I want to bet small chance to get useful information about reason.
_M.signal("SIGSEGV", function (sno, info, p)
	logger.fatal("SIGSEGV", faultaddr(info))
	os.exit(-2)
end)

return _M

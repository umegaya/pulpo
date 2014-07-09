local loader = require 'pulpo.loader'
local ffi = require 'ffiex'
local memory = require 'pulpo.memory'
local util = require 'pulpo.util'

local C = ffi.C
local _M = {}
local ffi_state

local SIG_IGN
local SA_RESTART, SA_SIGINFO

loader.add_lazy_initializer(function ()
	ffi_state = loader.load("signal.lua", {
		"signal", "sigaction", "func sigaction", "sigemptyset", "sig_t", 
	}, {
		"SIGHUP", "SIGPIPE", "SIGKILL", "SIGALRM", "SIGSEGV", 
		"SA_RESTART", "SA_SIGINFO", 
		regex = {
			"^SIG%w+"
		}
	}, nil, [[
		#include <signal.h>
	]])

	--> that is really disappointing, but macro SIG_IGN is now cannot processed correctly. 
	SIG_IGN = ffi.cast("sig_t", 1)
	SA_RESTART = ffi.defs.SA_RESTART
	SA_SIGINFO = ffi.defs.SA_SIGINFO

	local function faultaddr(si)
		if ffi.os == "OSX" then
			return si.si_addr
		elseif ffi.os == "Linux" then
			return si._sifields._sigfault.si_addr
		else
			pulpo_assert(false, "unsupported OS:"..ffi.os)
		end
	end

	_M.dumped = false
	_M.signal("SIGSEGV", function (sno, info, p)
		if not _M.dumped then
			logger.fatal("SIGSEGV", faultaddr(info), debug.traceback())
			_M.dumped = true
			os.exit(-2)
		end
	end)
end)

function _M.ignore(signo)
	signo = (type(signo) == 'number' and signo or _M[signo])
	C.signal(signo, SIG_IGN)
end

function _M.signal(signo, handler, optional_saflags)
	signo = (type(signo) == 'number' and signo or _M[signo])
	local sa = memory.managed_alloc_typed('struct sigaction')
	local sset = memory.managed_alloc_typed('sigset_t')
	if ffi.os == "OSX" then
		sa[0].__sigaction_u.__sa_sigaction = handler
	elseif ffi.os == "Linux" then
		sa[0].__sigaction_handler.sa_sigaction = handler
	else
		pulpo_assert(false, "unsupported OS:"..ffi.os)
	end
	sa[0].sa_flags = bit.bor(SA_SIGINFO, SA_RESTART, optional_saflags or 0)
	if C.sigemptyset(sset) ~= 0 then
		return false
	end
	sa[0].sa_mask = sset[0]
	if C.sigaction(signo, sa, ffi.NULL) ~= 0 then
		return false
	end
	return true
end

return setmetatable(_M, {
	__index = function (t, k)
		local v = ffi_state.defs[k]
		pulpo_assert(v, "no signal definition:"..k)
		rawset(t, k, v)
		return v
	end
})

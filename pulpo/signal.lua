local loader = require 'pulpo.loader'
local ffi = require 'ffiex'
local memory = require 'pulpo.memory'
local util = require 'pulpo.util'

local C = ffi.C
local _M = {}
local ffi_state
local PT = ffi.load("pthread")

local SIG_IGN
local SA_RESTART, SA_SIGINFO
local SIGMASK_OP

loader.add_lazy_initializer(function ()
	ffi_state = loader.load("signal.lua", {
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
	ffi_state = loader.load("pthread_signal.lua", {
		"pthread_sigmask"
	}, {}, "pthread", [[
		#include <signal.h>
	]])

	--> that is really disappointing, but macro SIG_IGN is now cannot processed correctly. 
	SIG_IGN = ffi.cast("sig_t", 1)
	SA_RESTART = ffi.defs.SA_RESTART
	SA_SIGINFO = ffi.defs.SA_SIGINFO
	SIGMASK_OP = {
		add = ffi.defs.SIG_BLOCK,
		del = ffi.defs.SIG_UNBLOCK,
		set = ffi.defs.SIG_SETMASK
	}
	for k,v in pairs(SIGMASK_OP) do
		print(k, v)
	end

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
	_M.original_signals = {}
	_M.signal("SIGSEGV", function (sno, info, p)
		if not _M.dumped then
			logger.fatal("SIGSEGV", faultaddr(info), debug.traceback())
			_M.dumped = true
			os.exit(-2)
		end
	end)
	_M.ignore("SIGTRAP")
	local thread = require 'pulpo.thread'
	thread.register_exit_handler(function ()
		for signo, sa in pairs(_M.original_signals) do
			logger.info('rollback signal', signo, sa[0].__sigaction_handler.sa_handler)
			C.sigaction(signo, sa, nil)
			memory.free(sa)
			if signo == _M.SIGTRAP then
				logger.info('mask:', signo)
				_M.maskctl("add", signo)
			end
		end
	end)
end)

function _M.maskctl(op, ...)
	local sigset = ffi.new('sigset_t[1]')
	local sigs = {...}
	C.sigemptyset(sigset)
	for _,sig in ipairs(sigs) do
		local signo = type(sig) == 'number' and sig or _M[sig]
		assert(signo, "invalid signal definition:"..tostring(sig))
		C.sigaddset(sigset, signo)
		print('maskctl:addsig', signo)
	end
	print('maskctl', op, SIGMASK_OP[op])
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
	local sa2 = memory.managed_alloc_typed('struct sigaction')
	C.sigaction(signo, nil, sa2) 
	print(ffi, sa2[0].__sigaction_handler.sa_handler)
	assert(sa2[0].__sigaction_handler.sa_handler == SIG_IGN, "sigaction not set")
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
	return C.sigaction(signo, sa, ffi.NULL) ~= 0
end

return setmetatable(_M, {
	__index = function (t, k)
		local v = ffi_state.defs[k]
		pulpo_assert(v, "no signal definition:"..k)
		rawset(t, k, v)
		return v
	end
})

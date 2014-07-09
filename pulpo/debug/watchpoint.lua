local ffi = require 'ffiex'
local loader = require 'pulpo.loader'
local signal = require 'pulpo.signal'
local util = require 'pulpo.util'

local _M = {}
local C = ffi.C

if ffi.os ~= "Linux" then
	return setmetatable(_M, {
		__call = function () end,
	})
end

local ffi_state = loader.load("watchpoint.lua", {
	"getpid",
	"dr7_type", "dr7_len", "dr7_t",
}, {
	"PTRACE_POKEUSER", "PTRACE_ATTACH", "PTRACE_DETACH"
}, nil, [[
	#include <unistd.h>
	#include <sys/ptrace.h>
	#include <sys/types.h>
	#include <sys/wait.h>
	#include <linux/user.h>

	enum dr7_type {
		DR7_BREAK_ON_EXEC  = 0,
		DR7_BREAK_ON_WRITE = 1,
		DR7_BREAK_ON_RW    = 3,
	};

	enum dr7_len {
		DR7_LEN_1 = 0,
		DR7_LEN_2 = 1,
		DR7_LEN_4 = 3,
	};

	typedef struct {
		char l0:1;
		char g0:1;
		char l1:1;
		char g1:1;
		char l2:1;
		char g2:1;
		char l3:1;
		char g3:1;
		char le:1;
		char ge:1;
		char pad1:3;
		char gd:1;
		char pad2:2;
		char rw0:2;
		char len0:2;
		char rw1:2;
		char len1:2;
		char rw2:2;
		char len2:2;
		char rw3:2;
		char len3:2;
	} dr7_t;
]])

local PTRACE_POKEUSER = ffi_state.defs.PTRACE_POKEUSER
local PTRACE_ATTACH = ffi_state.defs.PTRACE_ATTACH
local PTRACE_DETACH = ffi_state.defs.PTRACE_DETACH

local DR7_BREAK_ON_EXEC = ffi.cast('enum dr7_type', "DR7_BREAK_ON_EXEC")
local DR7_BREAK_ON_WRITE = ffi.cast('enum dr7_type', "DR7_BREAK_ON_WRITE")
local DR7_BREAK_ON_RW = ffi.cast('enum dr7_type', "DR7_BREAK_ON_RW")

local DR7_LEN_1 = ffi.cast('enum dr7_len', "DR7_LEN_1")
local DR7_LEN_2 = ffi.cast('enum dr7_len', "DR7_LEN_2")
local DR7_LEN_4 = ffi.cast('enum dr7_len', "DR7_LEN_4")

local function default_handler(addr)
	if not _M.dumped then
		logger.fatal("watchpoint", addr, debug.traceback())
		_M.dumped = true
	end
end

local function get_handler(handler, addr)
	if not handler then 
		handler = default_handler
	else
		local f,err = loadstring(handler)
		if not f then error(err) end
		handler = f
	end
	return function (sno, info, p)
		handler(ffi.cast('void *', addr))
	end
end

function _M.trap(target_pid, addr, handler)
	local dr7 = ffi.new('dr7_t');
	dr7.l0 = 1;
	dr7.rw0 = DR7_BREAK_ON_WRITE;
	dr7.len0 = DR7_LEN_4;

	local ok, fn = pcall(get_handler, handler)
	if not ok then 
		logger.error('trap:get_handler:'..fn)
		goto syserror
	end

	signal.signal("SIGTRAP", fn, ffi.defs.SA_NODEFER)

    if 0 == C.ptrace(PTRACE_ATTACH, target_pid, nil, nil) then 
    	logger.error('trap:ptrace1')
    	goto syserror
    end
    util.sleep(1.0)
	if 0 == C.ptrace(PTRACE_POKEUSER, target_pid, 
		ffi.offsetof('struct user', 'u_debugreg[0]'), ffi.cast('void*', addr)) then 
    	logger.error('trap:ptrace2')
    	goto syserror
    end
	if 0 == C.ptrace(PTRACE_POKEUSER, target_pid, 
		ffi.offsetof('struct user', 'u_debugreg[7]'), dr7) then
    	logger.error('trap:ptrace3')
    	goto syserror
    end
	if 0 == C.ptrace(PTRACE_DETACH, target_pid, nil, nil) then
    	logger.error('trap:ptrace4')
    	goto syserror
    end
    print('trap success:', target_pid, addr)
	os.exit(0)
::syserror::
    print('trap failure:', target_pid, addr)
	os.exit(-1)
end

return setmetatable(_M, { __call = function(t, addr, handler)
	local cmd = ('luajit -e "(require \'pulpo.debug.watchpoint\').trap(%d,%d,%s)"'):format(
		C.getpid(), tonumber(ffi.cast('int', addr)), handler and ("'%q'"):format(string.dump(handler)) or "nil"
	)
	return os.execute(cmd)
end })


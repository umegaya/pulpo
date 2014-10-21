local ffi = require 'ffiex.init'
local loader = require 'pulpo.loader'
local signal = require 'pulpo.signal'
local util = require 'pulpo.util'
local thread = require 'pulpo.thread'

local _M = {}
local C = ffi.C

if ffi.os ~= "Linux" then
	return setmetatable(_M, {
		__call = function () end,
	})
end

local MAX_DR = 4

local ffi_state = loader.load("watchpoint.lua", {
	"getpid", "ptrace", "waitpid", "fork", 
	"struct user",
	"enum __ptrace_request", "enum dr7_break_type", "enum dr7_len", "dr7_t",
}, {
}, nil, [[
	#include <unistd.h>
	#include <sys/ptrace.h>
	#include <sys/types.h>
	#include <sys/wait.h>
	#include <sys/user.h>
	#include <sys/reg.h>

	//http://x86asm.net/articles/debugging-in-amd64-64-bit-mode-in-theory/
	enum dr7_break_type {
		DR7_BREAK_ON_EXEC  = 0,
		DR7_BREAK_ON_WRITE = 1,
		DR7_BREAK_ON_RW    = 3,
	};

	enum dr7_len {
		DR7_LEN_1 = 0,
		DR7_LEN_2 = 1,
		DR7_LEN_4 = 3,
		DR7_LEN_8 = 2,
	};

	typedef union {
		struct reg_layout {
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
		} reg;
		uint32_t data;
	} dr7_t;
]])

local PTRACE_POKEUSER = ffi.cast("enum __ptrace_request", "PTRACE_POKEUSER")
local PTRACE_ATTACH = ffi.cast("enum __ptrace_request", "PTRACE_ATTACH")
local PTRACE_DETACH = ffi.cast("enum __ptrace_request", "PTRACE_DETACH")

local DR7_BREAK_ON_EXEC = ffi.cast('enum dr7_break_type', "DR7_BREAK_ON_EXEC")
local DR7_BREAK_ON_WRITE = ffi.cast('enum dr7_break_type', "DR7_BREAK_ON_WRITE")
local DR7_BREAK_ON_RW = ffi.cast('enum dr7_break_type', "DR7_BREAK_ON_RW")
local DR7_BREAK = {
	exec = DR7_BREAK_ON_EXEC,
	write = DR7_BREAK_ON_WRITE,
	rw = DR7_BREAK_ON_RW,
}
local DR7_LEN_1 = ffi.cast('enum dr7_len', "DR7_LEN_1")
local DR7_LEN_2 = ffi.cast('enum dr7_len', "DR7_LEN_2")
local DR7_LEN_4 = ffi.cast('enum dr7_len', "DR7_LEN_4")
local DR7_LEN_8 = ffi.cast('enum dr7_len', "DR7_LEN_8")
local DR7_LEN = {
	[1] = DR7_LEN_1,
	[2] = DR7_LEN_2,
	[4] = DR7_LEN_4,	
	[8] = DR7_LEN_8,
}

-- current debugging register state
_M.dr7 = ffi.new('dr7_t')

local function default_handler(addr)
	logger.fatal("watchpoint", addr, 'newvalue:'..tostring((ffi.cast('int*', addr)[0])))
end

local function get_handler(handler, addr)
	if not handler then 
		handler = default_handler
	end
	return function (sno, info, p)
		handler(ffi.cast('void *', addr))
	end
end

function _M.regctl(target_pid, regstate, addr, idx)
	local dr7 = ffi.new('dr7_t')
	dr7.data = tonumber(regstate)

	local u = ffi.new('struct user')
	local baseofs = ffi.new('int', ffi.offsetof('struct user', 'u_debugreg'))
	local regofs = ffi.new('int', baseofs + (ffi.sizeof(u.u_debugreg[0]) * 7))

	if type(target_pid) == 'number' then
		target_pid = ffi.new('int', target_pid)
	end
	if 0 ~= C.ptrace(PTRACE_ATTACH, target_pid, nil, nil) then 
		logger.error('ptrace1', ffi.errno())
		return false
	end
	util.sleep(1.0)
	if addr and idx then
		local addrofs = ffi.new('int', baseofs + (ffi.sizeof(u.u_debugreg[0]) * idx))
		if 0 ~= C.ptrace(PTRACE_POKEUSER, target_pid, addrofs, ffi.cast('void*', addr)) then 
			logger.error('ptrace2', ffi.errno())
			return false
		end
	end
	if 0 ~= C.ptrace(PTRACE_POKEUSER, target_pid, regofs, ffi.cast('void*', dr7.data)) then
		logger.error('ptrace3', ffi.errno())
		return false
	end
	if 0 ~= C.ptrace(PTRACE_DETACH, target_pid, nil, nil) then
		logger.error('ptrace4', ffi.errno())
		return false
	end
	logger.notice('trap success:', tonumber(target_pid), addr and bit.tohex(addr) or nil)
	os.exit(idx)
::syserror::
	logger.warn('trap failure:', tonumber(target_pid), addr and bit.tohex(addr) or nil)
	os.exit(-1)
end

local function run_ptrace_process(...)
	local tmp = {}
	for _,arg in pairs({...}) do
		table.insert(tmp, tostring(arg))
	end
        local cmd = (
                'luajit -e "(require \'pulpo.thread\').initialize({ cache_dir=\'%s\'});'..
                '(require \'pulpo.debug.watchpoint\').regctl(%d,%s)"'
        ):format(
                loader.cache_dir,
                C.getpid(), table.concat(tmp, ',')
        )
        logger.info('exec', cmd)
        local r = os.execute(cmd)
        if r ~= 0 then
       		error('trap fails:'..r)
        end
        return r
end

function _M.untrap(idx)
	_M.dr7.reg["l"..idx] = 0
	return run_ptrace_process(tonumber(ffi.cast('int', _M.dr7.data)))
end

local thread = require 'pulpo.thread'
thread.register_exit_handler("watchpoint.lua", function ()
	local trapped 
	for i=0,MAX_DR-1,1 do
		if _M.dr7.reg["l"..i] ~= 0 then
			trapped = true
		end
		_M.dr7.reg["l"..i] = 0
	end
	if not trapped then return end
	return run_ptrace_process(tonumber(ffi.cast('int', _M.dr7.data)))
end)

return setmetatable(_M, { __call = function(t, addr, len, kind, handler)
	local ok, fn = pcall(get_handler, handler, addr)
	assert(ok, 'trap:get_handler:'..tostring(fn))
	signal.signal("SIGTRAP", fn, ffi.defs.SA_NODEFER)

	local idx 
	for i=0,MAX_DR-1,1 do
		if _M.dr7.reg["l"..i] == 0 then
			idx = i
			break
		end
	end
	assert(idx, "no empty register")

	_M.dr7.reg["l"..idx] = 1
	_M.dr7.reg["rw"..idx] = DR7_BREAK[kind or "write"]
	_M.dr7.reg["len"..idx] = assert(DR7_LEN[len or 4], "invalid len:"..tostring(len))
	return run_ptrace_process(
		tonumber(ffi.cast('int', _M.dr7.data)), 
		type(addr) == 'number' and addr or tonumber(ffi.cast('int', addr)), 
		idx
	)
end })


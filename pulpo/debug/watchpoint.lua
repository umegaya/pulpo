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

local DR7_LEN_1 = ffi.cast('enum dr7_len', "DR7_LEN_1")
local DR7_LEN_2 = ffi.cast('enum dr7_len', "DR7_LEN_2")
local DR7_LEN_4 = ffi.cast('enum dr7_len', "DR7_LEN_4")

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

function _M.trap(target_pid, addr)
	local u = ffi.new('struct user')
	local dr7 = ffi.new('dr7_t');
	local addrofs = ffi.new('int', ffi.offsetof('struct user', 'u_debugreg'))
	local regofs = ffi.new('int', addrofs + (ffi.sizeof(u.u_debugreg[0]) * 7))
	dr7.reg.l0 = 1
	dr7.reg.rw0 = DR7_BREAK_ON_WRITE
	dr7.reg.len0 = DR7_LEN_4

	if type(target_pid) == 'number' then
		target_pid = ffi.new('int', target_pid)
	end
	if 0 ~= C.ptrace(PTRACE_ATTACH, target_pid, nil, nil) then 
		logger.error('trap:ptrace1', ffi.errno())
		goto syserror
	end
	util.sleep(1.0)
	if 0 ~= C.ptrace(PTRACE_POKEUSER, target_pid, addrofs, ffi.cast('void*', addr)) then 
		logger.error('trap:ptrace2', ffi.errno())
		goto syserror
	end
	if 0 ~= C.ptrace(PTRACE_POKEUSER, target_pid, regofs, ffi.cast('void*', dr7.data)) then
		logger.error('trap:ptrace3', ffi.errno())
		goto syserror
	end
	if 0 ~= C.ptrace(PTRACE_DETACH, target_pid, nil, nil) then
		logger.error('trap:ptrace4', ffi.errno())
		goto syserror
	end
	logger.notice('trap success:', tonumber(target_pid), bit.tohex(addr))
	os.exit(0)
::syserror::
	logger.warn('trap failure:', tonumber(target_pid), bit.tohex(addr))
	os.exit(-1)
end

function _M.untrap(idx)
end

return setmetatable(_M, { __call = function(t, addr, handler)
	local parent = C.getpid()
	local ok, fn = pcall(get_handler, handler, addr)
	if not ok then
		error('trap:get_handler:'..fn)
	end
	signal.signal("SIGTRAP", fn, ffi.defs.SA_NODEFER)

--[[
	local child = C.fork()
	if child == 0 then
		logger.info("child", parent)
		_M.trap(parent, tonumber(ffi.cast('int', addr)))
	else
		logger.info("parent", child)
		C.waitpid(child, nil, 0)
		logger.info("parent wait end")
	end
--]]
-- [[
	local cmd = ('luajit -e "(require \'pulpo.thread\').initialize({ cdef_cache_dir=\'%s\'});(require \'pulpo.debug.watchpoint\').trap(%d,%d)"'):format(
		loader.cache_dir, 
		C.getpid(), tonumber(ffi.cast('int', addr))
	)
	-- logger.info('exec', cmd)
	local r = os.execute(cmd)
	if r ~= 0 then
		error('trap fails')
	end
	return r
--]]--
end })


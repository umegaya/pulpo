local ffi = require 'ffiex.init'
local poller = require 'pulpo.poller'
local util = require 'pulpo.util'
local memory = require 'pulpo.memory'
local errno = require 'pulpo.errno'
local event = require 'pulpo.event'
local socket = require 'pulpo.socket'
local raise = (require 'pulpo.exception').raise

local C = ffi.C
local _M = {}

local HANDLER_TYPE_PROCESS
--> cdef
local EAGAIN = errno.EAGAIN
local EPIPE = errno.EPIPE
local EWOULDBLOCK = errno.EWOULDBLOCK
local ENOTCONN = errno.ENOTCONN
local ECONNREFUSED = errno.ECONNREFUSED
local ECONNRESET = errno.ECONNRESET
local EINPROGRESS = errno.EINPROGRESS
local EINVAL = errno.EINVAL

ffi.cdef [[
typedef struct pulpo_process_context {
	FILE *fp;
} pulpo_process_context_t;
]]

--> handlers
local function process_read(io, ptr, len)
::retry::
	local n = C.read(io:fd(), ptr, len)
	if n <= 0 then
		if n == 0 then 
			local ctx = io:ctx('pulpo_process_context_t*')
			local st = C.pclose(ctx.fp)
			ctx.fp = ffi.NULL
			io:close('remote')
			return nil, socket.parse_status(st)
		end
		local eno = errno.errno()
		if eno == EAGAIN or eno == EWOULDBLOCK then
			if not io:wait_read() then
				return nil
			end
			goto retry
		else
			io:close('error')
			raise('syscall', 'read', io:nfd())
		end
	end
	return n
end

local function on_write_error(io, ret)
	local eno = errno.errno()
	-- print(io:fd(), 'write fails', ret, eno, ffi.errno() )
	if eno == EAGAIN or eno == EWOULDBLOCK then
		if not io:wait_write() then
			raise('pipe')
		end
	elseif eno == EPIPE then
		io:close('pipe')
	else
		io:close('error')
		raise('syscall', 'write', io:nfd())
	end
	return true
end

local function process_write(io, ptr, len)
::retry::
	local n = C.write(io:fd(), ptr, len)
	if n < 0 then
		on_write_error(io, n)
		goto retry
	end
	return n
end

local function process_gc(io)
	local ctx = io:ctx('pulpo_process_context_t*')
	if ctx.fp ~= ffi.NULL then
		C.pclose(ctx.fp)
	end
	memory.free(ctx)
end

local function process_addr(io)
	return nil
end

HANDLER_TYPE_PROCESS = poller.add_handler("process", process_read, process_write, process_gc, process_addr)

function _M.open(p, cmd, mode, opts)
	local ctx = memory.alloc_typed('pulpo_process_context_t')
	local fp = C.popen(cmd, mode or "r")
	if fp == ffi.NULL then
		raise('syscall', 'popen') 
	end
	ctx.fp = fp
	local fd = C.fileno(fp)
	if socket.setsockopt(fd, opts) < 0 then
		C.close(fd)
		raise('syscall', 'setsockopt') 
	end
	local io = p:newio(fd, HANDLER_TYPE_PROCESS, ctx)
	event.add_to(io, 'open')
	-- tcp_connect(io)
	return io
end

function _M.execute(p, cmd)
	local io = _M.open(p, cmd)
	local str = ""
	local buf = ffi.new('char[256]')
	while true do
		local ok, r = io:read(buf, 256)
		if not ok then
			return r, str
		else
			str = str .. ffi.string(buf, ok)
		end
	end
end

return _M

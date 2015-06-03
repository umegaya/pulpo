local ffi = require 'ffiex.init'
local poller = require 'pulpo.poller'
local util = require 'pulpo.util'
local memory = require 'pulpo.memory'
local errno = require 'pulpo.errno'
local socket = require 'pulpo.socket'
local event = require 'pulpo.event'
local raise = (require 'pulpo.exception').raise

local C = ffi.C
local _M = {}

local HANDLER_TYPE_TCP, HANDLER_TYPE_TCP_LISTENER

--> cdef
local EAGAIN = errno.EAGAIN
local EPIPE = errno.EPIPE
local EWOULDBLOCK = errno.EWOULDBLOCK
local ENOTCONN = errno.ENOTCONN
local ECONNREFUSED = errno.ECONNREFUSED
local ECONNRESET = errno.ECONNRESET
local EINPROGRESS = errno.EINPROGRESS
local EINVAL = errno.EINVAL

local STATE = {
	INIT = 0, 
	CONNECTING = 1, 
	CONNECTED = 2, 
}

ffi.cdef [[
typedef struct pulpo_tcp_context {
	pulpo_addr_t addr;
	unsigned int state:8, padd:24;
} pulpo_tcp_context_t;
typedef pulpo_sockopt_t pulpo_tcp_server_context_t;
]]

--> helper function
local function tcp_connect(io)
::retry::
	local ctx = io:ctx('pulpo_tcp_context_t*')
	if ctx.state == STATE.CONNECTING then
		event.join(io:event('open'))
		return
	elseif ctx.state == STATE.CONNECTED then
		return
	end
	local n = C.connect(io:fd(), ctx.addr.p, ctx.addr.len[0])
	if n < 0 then
		local eno = errno.errno()
		-- print('tcp_connect:', io:fd(), n, eno)
		if eno == EINPROGRESS then
			ctx.state = STATE.CONNECTING
			if not io:wait_write() then
				raise('invalid', 'socket', 'already closed')
			end
			ctx.state = STATE.CONNECTED
			io:emit('open')
			return true
		elseif eno == ECONNREFUSED then
			goto retry
		else
			raise('syscall', 'connect', io:nfd())
		end
	end
	ctx.state = STATE.CONNECTED
	io:emit('open')
	return true
end

local function tcp_server_socket(p, fd, ctx, hdtype)
	return p:newio(fd, hdtype or HANDLER_TYPE_TCP, ctx)	
end


--> handlers
local function tcp_read(io, ptr, len)
::retry::
	local n = C.recv(io:fd(), ptr, len, 0)
	if n <= 0 then
		if n == 0 then 
			return nil
		end
		local eno = errno.errno()
		if eno == EAGAIN or eno == EWOULDBLOCK then
			if not io:wait_read() then
				return nil
			end
			goto retry
		elseif eno == ENOTCONN then
			tcp_connect(io)
			goto retry
		else
			raise('syscall', 'read', io:nfd())
		end
	end
	return n
end
_M.rawread = tcp_read

local function on_write_error(io, ret)
	local eno = errno.errno()
	-- print(io:fd(), 'write fails', ret, eno, ffi.errno() )
	if eno == EAGAIN or eno == EWOULDBLOCK then
		if not io:wait_write() then
			raise('pipe')
		end
	elseif eno == ENOTCONN then
		tcp_connect(io)
	elseif eno == EPIPE then
		--[[ EPIPE: 
			http://www.freebsd.org/cgi/man.cgi?query=listen&sektion=2
			> If a connection
		    > request arrives with the queue full the client may	receive	an error with
		    > an	indication of ECONNREFUSED, or,	in the case of TCP, the	connection
		    > will be *silently* dropped.
			
			so I guess if try to write to such an connection, EPIPE may occur.
			because if I increasing listen backlog size, EPIPE not happen.
		]]
		if io:ctx('pulpo_tcp_context_t*').state == STATE.INIT then
			tcp_connect(io)
		else	
			raise('pipe')
		end	
	else
		raise('syscall', 'write', io:nfd())
	end
	return true
end

local function tcp_write(io, ptr, len)
::retry::
	local n = C.send(io:fd(), ptr, len, 0)
	if n < 0 then
		on_write_error(io, n)
		goto retry
	end
	return n
end

local function tcp_writev(io, vec, vlen)
::retry::
--[[
logger.notice(debug.traceback())
for i=0,tonumber(vlen)-1 do
	local v = vec[i]
	logger.notice('vec', i, ("[%q]"):format(ffi.string(v.iov_base, v.iov_len)))
end
--]]
	local n = C.writev(io:fd(), vec, vlen)
	if n < 0 then
		on_write_error(io, n)
		goto retry
	end
	return n
end
_M.rawwritev = tcp_writev

local function tcp_writef(io, in_fd, offset_p, count)
::retry::
	local n = C.sendfile(io:fd(), in_fd, offset_p, count)
	if n < 0 then
		on_write_error(io)
		goto retry
	end
	return n
end

local ctx_work
local function tcp_accept(io, hdtype, given_ctx)
	local ctx
::retry::
	-- print('tcp_accept:', io:fd(), given_ctx)
	if given_ctx then
		ctx = ffi.cast('pulpo_tcp_context_t *', given_ctx)
	else
		if not ctx_work then
			-- because if C.accept returns any fd, there is no point to yield this funciton.
			-- so other coroutine which call tcp_accept never intercept this ctx. 
			-- we can reuse ctx pointer for next accept call. (if accept fails)
			ctx_work = memory.alloc_typed('pulpo_tcp_context_t')
			assert(ctx_work ~= ffi.NULL, "error alloc context")
		end
		ctx = ctx_work
	end
	ctx.addr:init()
	local n = C.accept(io:fd(), ctx.addr.p, ctx.addr.len)
	if n < 0 then
		local eno = errno.errno()
		if eno == EAGAIN or eno == EWOULDBLOCK then
			if not io:wait_read() then 
				raise('report', 'TCP:listener socket closed:'..tostring(io:fd()))
			end
			goto retry
		else
			raise('syscall', 'accept', io:nfd())
		end
	else
		-- apply same setting as server 
		if socket.setsockopt(n, io:ctx('pulpo_tcp_server_context_t*')) < 0 then
			C.close(n)
			goto retry
		end
	end
	local tmp = ctx
	tmp.state = STATE.CONNECTED
	if ctx == ctx_work then
		ctx_work = nil
	end
	return tcp_server_socket(io.p, n, tmp, hdtype)
end
_M.rawaccept = tcp_accept

local function tcp_gc(io)
	memory.free(io:ctx('void*'))
	C.close(io:fd())
end

local function tcp_addr(io)
	return io:ctx('pulpo_tcp_context_t*').addr
end


HANDLER_TYPE_TCP = poller.add_handler("tcp", tcp_read, tcp_write, tcp_gc, tcp_addr, tcp_writev, tcp_writef)
HANDLER_TYPE_TCP_LISTENER = poller.add_handler("tcp_listen", tcp_accept, nil, tcp_gc)

-- ctx should be mon-managed 
function _M.connect(p, addr, opts, hdtype, ctx)
	ctx = ctx and ffi.cast('pulpo_tcp_context_t*', ctx) or memory.alloc_typed('pulpo_tcp_context_t')
	ctx.state = STATE.INIT
	-- ctx.addr is reference of original memory block, so it will modify ctx.addr's value.
	local fd = socket.stream(addr, opts, ctx.addr)
	if not fd then 
		raise('syscall', 'socket', 'create stream') 
	end
	local io = p:newio(fd, hdtype or HANDLER_TYPE_TCP, ctx)
	event.add_to(io, 'open')
	if _M.DEBUG then
		logger.debug('tcp', 'connect', fd, addr)
	end
	-- tcp_connect(io)
	return io
end

-- ctx should be mon-managed 
function _M.listen(p, addr, opts, hdtype, ctx)
	local a = memory.managed_alloc_typed('pulpo_addr_t')
	local fd = socket.stream(addr, opts, a)
	if not fd then error('fail to create socket:'..errno.errno()) end
	if not socket.set_reuse_addr(fd, true) then
		C.close(fd)
		raise('syscall', 'setsockopt', fd)
	end
	if C.bind(fd, a.p, a.len[0]) < 0 then
		C.close(fd)
		raise('syscall', 'bind', fd)
	end
	if C.listen(fd, poller.config.maxconn) < 0 then
		C.close(fd)
		raise('syscall', 'listen', fd)
	end
	logger.debug('tcp', 'listen', fd, addr)
	if ctx then
		return p:newio(fd, hdtype or HANDLER_TYPE_TCP_LISTENER, ctx)		
	else
		ctx = opts and socket.table2sockopt(opts, true) or nil
		return p:newio(fd, hdtype or HANDLER_TYPE_TCP_LISTENER, ctx)
	end
end

return _M

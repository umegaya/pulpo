local ffi = require 'ffiex'
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
	pulpo_addrinfo_t addrinfo;
	unsigned int state:8, padd:24;
} pulpo_tcp_context_t;
]]

--> helper function
local function tcp_connect(io)
::retry::
	local ctx = io:ctx('pulpo_tcp_context_t*')
	if ctx.state == STATE.CONNECTING then
		event.wait(io:event('open'))
		return
	elseif ctx.state == STATE.CONNECTED then
		return
	end
	local n = C.connect(io:fd(), ctx.addrinfo.addrp, ctx.addrinfo.alen[0])
	if n < 0 then
		local eno = errno.errno()
		-- print('tcp_connect:', io:fd(), n, eno)
		if eno == EINPROGRESS then
			-- print('EINPROGRESS:to:', socket.inet_namebyhost(ctx.addrinfo.addrp))
			ctx.state = STATE.CONNECTING
			io:wait_write()
			ctx.state = STATE.CONNECTED
			io:emit('open')
			return true
		elseif eno == ECONNREFUSED then
			goto retry
		else
			io:close('error')
			raise('syscall', 'connect', eno, io:nfd())
		end
	end
	ctx.state = STATE.CONNECTED
	io:emit('open')
	return true
end

local function tcp_server_socket(p, fd, ctx)
	return p:newio(fd, HANDLER_TYPE_TCP, ctx)	
end


--> handlers
local function tcp_read(io, ptr, len)
::retry::
	local n = C.recv(io:fd(), ptr, len, 0)
	if n <= 0 then
		if n == 0 then 
			io:close('remote')
			raise('pipe')
		end
		local eno = errno.errno()
		if eno == EAGAIN or eno == EWOULDBLOCK then
			io:wait_read()
			goto retry
		elseif eno == ENOTCONN then
			tcp_connect(io)
			goto retry
		else
			io:close('error')
			raise('syscall', 'read', eno, io:nfd())
		end
	end
	return n
end

local function on_write_error(io)
	local eno = errno.errno()
	-- print(io:fd(), 'write fails', n, eno)
	if eno == EAGAIN or eno == EWOULDBLOCK then
		io:wait_write()
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
		io:close('remote')
		raise('pipe')
	else
		io:close('error')
		raise('syscall', 'write', eno, io:nfd())
	end
	return true
end

local function tcp_write(io, ptr, len)
::retry::
	local n = C.send(io:fd(), ptr, len, 0)
	if n < 0 then
		on_write_error(io)
		goto retry
	end
	return n
end

local function tcp_writev(io, vec, vlen)
::retry::
	local n = C.writev(io:fd(), vec, vlen)
	if n < 0 then
		on_write_error(io)
		goto retry
	end
	return n
end

local ctx
local function tcp_accept(io)
::retry::
	-- print('tcp_accept:', io:fd())
	if not ctx then
		ctx = memory.alloc_typed('pulpo_tcp_context_t')
		assert(ctx ~= ffi.NULL, "error alloc context")
	end
	local n = C.accept(io:fd(), ctx.addrinfo.addrp, ctx.addrinfo.alen)
	if n < 0 then
		local eno = errno.errno()
		if eno == EAGAIN or eno == EWOULDBLOCK then
			io:wait_read()
			goto retry
		else
			raise('syscall', 'accept', eno, io:nfd())
		end
	else
		-- apply same setting as server 
		if socket.setsockopt(n, io:ctx('pulpo_sockopt_t*')) < 0 then
			C.close(n)
			goto retry
		end
	end
	local tmp = ctx
	tmp.state = STATE.CONNECTED
	ctx = nil
	return tcp_server_socket(io.p, n, tmp)
end

local function tcp_gc(io)
	memory.free(io:ctx('void*'))
	C.close(io:fd())
end

HANDLER_TYPE_TCP = poller.add_handler("tcp", tcp_read, tcp_write, tcp_gc)
HANDLER_TYPE_TCP_LISTENER = poller.add_handler("tcp_listen", tcp_accept, nil, tcp_gc)

function _M.connect(p, addr, opts)
	local ctx = memory.alloc_typed('pulpo_tcp_context_t')
	ctx.state = STATE.INIT
	local fd = socket.stream(addr, opts, ctx.addrinfo)
	if not fd then 
		raise('syscall', 'socket', errno.errno()) 
	end
	local io = p:newio(fd, HANDLER_TYPE_TCP, ctx)
	event.add_to(io, 'open')
	-- tcp_connect(io)
	return io
end

function _M.listen(p, addr, opts)
	local ai = memory.managed_alloc_typed('pulpo_addrinfo_t')
	local fd = socket.stream(addr, opts, ai)
	if not fd then error('fail to create socket:'..errno.errno()) end
	if not socket.set_reuse_addr(fd, true) then
		C.close(fd)
		raise('syscall', 'setsockopt', errno.errno(), fd)
	end
	if C.bind(fd, ai.addrp, ai.alen[0]) < 0 then
		C.close(fd)
		raise('syscall', 'bind', errno.errno(), fd)
	end
	if C.listen(fd, poller.config.maxconn) < 0 then
		C.close(fd)
		raise('syscall', 'listen', errno.errno(), fd)
	end
	logger.info('listen:', fd, addr, p)
	return p:newio(fd, HANDLER_TYPE_TCP_LISTENER, opts)
end

return _M

local ffi = require 'ffiex.init'
local poller = require 'pulpo.poller'
local util = require 'pulpo.util'
local memory = require 'pulpo.memory'
local errno = require 'pulpo.errno'
local tcp = require 'pulpo.io.tcp'


local C = ffi.C
local _M = {}

local HANDLER_TYPE_HTTP, HANDLER_TYPE_HTTP_LISTENER

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
typedef struct pulpo_tcp_context {
	pulpo_addrinfo_t addrinfo;
} pulpo_tcp_context_t;
]]

--> helper function
local function tcp_connect(io)
::retry::
	local ctx = io:ctx('pulpo_tcp_context_t*')
	local n = C.connect(io:fd(), ctx.addrinfo.addrp, ctx.addrinfo.alen[0])
	if n < 0 then
		local eno = errno.errno()
		-- print('tcp_connect:', io:fd(), n, eno)
		if eno == EINPROGRESS then
			-- print('EINPROGRESS:to:', socket.inet_namebyhost(ctx.addrinfo.addrp))
			io:wait_write()
			return
		elseif eno == ECONNREFUSED then
			logger.info('TODO: server listen backlog may exceed: try reconnection', eno)
			util.sleep(0.1) -- TODO : use lightweight sleep by timer facility
			goto retry
		else
			error(('tcp connect fails(%d) on %d'):format(eno, io:nfd()))
		end
	end
end

local function tcp_server_socket(p, fd, ctx)
	return p:newio(fd, HANDLER_TYPE_TCP, ctx)	
end


--> handlers
local function tcp_read(io, ptr, len)
::retry::
	local n = C.recv(io:fd(), ptr, len, 0)
	if n <= 0 then
		if n == 0 then return nil end
		local eno = errno.errno()
		if eno == EAGAIN or eno == EWOULDBLOCK then
			io:wait_read()
			goto retry
		elseif eno == ENOTCONN then
			tcp_connect(io)
			goto retry
		else
			error(('tcp read fails(%d) on %d'):format(eno, io:nfd()))
		end
	end
	return n
end

local function tcp_write(io, ptr, len)
::retry::
	local n = C.send(io:fd(), ptr, len, 0)
	if n < 0 then
		local eno = errno.errno()
		-- print(io:fd(), 'write fails', n, eno)
		if eno == EAGAIN or eno == EWOULDBLOCK then
			io:wait_write()
			goto retry
		elseif eno == ENOTCONN then
			tcp_connect(io)
			goto retry
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
			tcp_connect(io)
			goto retry
		else
			error(('tcp write fails(%d) on %d'):format(eno, io:nfd()))
		end
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
			error(('tcp accept fails(%d) on %d'):format(eno, io:nfd()))
		end
	else
		-- apply same setting as server 
		if socket.setsockopt(n, io:ctx('pulpo_sockopt_t*')) < 0 then
			C.close(n)
			goto retry
		end
	end
	local tmp = ctx
	ctx = nil
	return tcp_server_socket(io.p, n, tmp)
end

local function tcp_gc(io)
	memory.free(io:ctx('void*'))
	C.close(io:fd())
end

HANDLER_TYPE_HTTP = poller.add_handler("http", tcp_read, tcp_write, tcp_gc)
HANDLER_TYPE_HTTP_LISTENER = poller.add_handler("http_listen", tcp_accept, nil, tcp_gc)

function _M.connect(p, addr, opts)
	return tcp.connect(p, addr, opts, HANDLER_TYPE_HTTP)
end

function _M.listen(p, addr, opts)
	return tcp.listen(p, addr, opts, HANDLER_TYPE_HTTP_LISTENER)
end

return _M
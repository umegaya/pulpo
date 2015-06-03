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
typedef struct pulpo_udp_context {
	pulpo_addr_t addr;
	unsigned int state:8, padd:24;
} pulpo_udp_context_t;
]]

--> helper function
local function udp_connect(io, close_on_error)
::retry::
	local ctx = io:ctx('pulpo_udp_context_t*')
	if ctx.state == STATE.CONNECTING then
		event.join(io:event('open'))
		return
	elseif ctx.state == STATE.CONNECTED then
		return
	end
	local n = C.connect(io:fd(), ctx.addr.p, ctx.addr.len[0])
	if n < 0 then
		local eno = errno.errno()
		-- print('udp_connect:', io:fd(), n, eno)
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
			if close_on_error then
				io:close('error')
			end
			raise('syscall', 'connect', io:nfd())
		end
	end
	ctx.state = STATE.CONNECTED
	io:emit('open')
	return true
end

--> handlers
local function udp_read(io, ptr, len, addr)
::retry::
	local n = C.recvfrom(io:fd(), ptr, len, 0, addr.p, addr.len)
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
		else
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
	elseif eno == ENOTCONN then
		udp_connect(io)
	elseif eno == EPIPE then
		raise('pipe')
	else
		raise('syscall', 'write', io:nfd())
	end
	return true
end

local function udp_write(io, ptr, len, addr)
::retry::
	local n = C.sendto(io:fd(), ptr, len, 0, addr.p, addr.len[0])
	if n < 0 then
		on_write_error(io, n)
		goto retry
	end
	return n
end

local sendmsg_work = memory.alloc_fill_typed('struct msghdr')
local function udp_writev(io, vec, vlen, addr)
::retry::
	sendmsg_work.msg_name = addr.p
	sendmsg_work.msg_namelen = addr.len[0]
	sendmsg_work.msg_iov = vec
	sendmsg_work.msg_iovlen = vlen
	local n = C.sendmsg(io:fd(), sendmsg_work, 0)
	if n < 0 then
		on_write_error(io, n)
		goto retry
	end
	return n
end

local function udp_write_connected(io, ptr, len)
::retry::
	local n = C.send(io:fd(), ptr, len, 0)
	if n < 0 then
		on_write_error(io, n)
		goto retry
	end
	return n
end

local function udp_writev_connected(io, vec, vlen)
::retry::
	local n = C.writev(io:fd(), vec, vlen)
	if n < 0 then
		on_write_error(io, n)
		goto retry
	end
	return n
end

local function udp_writef(io, in_fd, offset_p, count)
::retry::
	local n = C.sendfile(io:fd(), in_fd, offset_p, count)
	if n < 0 then
		on_write_error(io)
		goto retry
	end
	return n
end

local function udp_gc(io)
	memory.free(io:ctx('void*'))
	C.close(io:fd())
end

local function udp_addr(io)
	return io:ctx('pulpo_udp_context_t*').addr
end

-- define handler
HANDLER_TYPE_UDP = poller.add_handler("udp", udp_read, udp_write, udp_gc, udp_addr, udp_writev)
HANDLER_TYPE_UDP_CONNECTED = poller.add_handler("udpc", udp_read, udp_write_connected, udp_gc, udp_addr, udp_writev_connected, udp_writef)

-- connector
function open(p, addr, opts)
	local ctx = memory.alloc_typed('pulpo_udp_context_t')
	ctx.state = STATE.INIT
	local fd = socket.datagram(addr, opts, ctx.addr)
	if not fd then 
		memory.free(ctx)
		raise('syscall', 'socket', 'create datagram') 
	end
	return fd, ctx
end
function _M.create(p, opts)
	local fd, ctx = open(p, "0.0.0.0", opts)
	return p:newio(fd, HANDLER_TYPE_UDP, ctx)
end
function _M.connect(p, addr, opts)
	local fd, ctx = open(p, addr, opts)
	local io = p:newio(fd, HANDLER_TYPE_UDP_CONNECTED, ctx)
	event.add_to(io, 'open')
	udp_connect(io, true)
	return io
end

-- listener
local function basic_listen(addr, opts)
	local a = memory.managed_alloc_typed('pulpo_addr_t')
	local fd = socket.datagram(addr, opts, a)
	if not fd then error('fail to create socket:'..errno.errno()) end
	if not socket.set_reuse_addr(fd, true) then
		C.close(fd)
		raise('syscall', 'setsockopt', fd)
	end
	if C.bind(fd, a.p, a.len[0]) < 0 then
		C.close(fd)
		raise('syscall', 'bind', fd)
	end
	return fd, a
end
function _M.listen(p, addr, opts)
	local fd = basic_listen(addr, opts)
	logger.debug('udp', 'listen', fd, addr)
	return p:newio(fd, HANDLER_TYPE_UDP, opts and socket.table2sockopt(opts, true) or nil)
end

function _M.mcast_listen(p, addr, opts)
	-- replace multicast group setting to INADDR_ANY
	local fd, a = basic_listen(addr:gsub("^[%.0-9]+", "0.0.0.0"), opts)
	local ok, r = pcall(socket.setup_multicast, fd, addr:match("^[%.0-9]+"), opts or {}, a)
	if not ok then
		C.close(fd)
		error(r)
	end
	logger.debug('udp', 'mcast_listen', fd, addr)
	return p:newio(fd, HANDLER_TYPE_UDP, opts and socket.table2sockopt(opts, true) or nil)
end

return _M
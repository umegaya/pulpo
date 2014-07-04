local ffi = require 'ffiex'
local socket = require 'pulpo.socket'
local poller = require 'pulpo.poller'
local loader = require 'pulpo.loader'
local errno = require 'pulpo.errno'

local _M = {}
local C = ffi.C

local EAGAIN = errno.EAGAIN
local EPIPE = errno.EPIPE
local EWOULDBLOCK = errno.EWOULDBLOCK

loader.load('linda.lua', {
	"pipe",
}, {}, nil, [[
	#include <unistd.h>
]])

local function pipe_read(io, ptr, len)
::retry::
	local n = C.read(io:fd(), ptr, len)
	if n <= 0 then
		if n == 0 then return nil end
		local eno = errno.errno()
		if eno == EAGAIN or eno == EWOULDBLOCK then
			io:wait_read()
			goto retry
		else
			error(('tcp read fails(%d) on %d'):format(eno, io:nfd()))
		end
	end
	return n
end

local function pipe_write(io, ptr, len)
::retry::
	-- print('pipe_write:', io:fd())
	local n = C.write(io:fd(), ptr, len)
	-- print('pipe_write:', n, io:fd())
	if n < 0 then
		local eno = errno.errno()
		-- print(io:fd(), 'write fails', n, eno)
		if eno == EAGAIN or eno == EWOULDBLOCK then
			io:wait_write()
			goto retry
		elseif eno == EPIPE then
			error(('pipe write fails(peer closed) on %d'):format(eno, io:fd()))
		else
			error(('pipe write fails(%d) on %d'):format(eno, io:fd()))
		end
	end
	return n
end

local function pipe_gc(io)
	memory.free(io:ctx('void*'))
	C.close(io:fd())
end

local HANDLER_TYPE_RPIPE = poller.add_handler(pipe_read, nil, pipe_gc)
local HANDLER_TYPE_WPIPE = poller.add_handler(nil, pipe_write, pipe_gc)

function _M.create(p, fds, ctx, opts)
	if not fds then
		fds = ffi.new('int[2]')
		if C.pipe(fds) ~= 0 then
			error('fail to create pipe:'..ffi.errno())
		end
	end
	if socket.setsockopt(fds[0], opts) < 0 then
		error('fail to configure read pipe:'..ffi.errno())
	end
	if socket.setsockopt(fds[1], opts) < 0 then
		error('fail to configure writes pipe:'..ffi.errno())
	end
	return p:newio(fds[0], HANDLER_TYPE_RPIPE, ctx), 
			p:newio(fds[1], HANDLER_TYPE_WPIPE, ctx)
end

return _M
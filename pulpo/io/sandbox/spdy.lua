assert(false, "NYI")
local ffi = require 'ffiex.init'
local poller = require 'pulpo.poller'
local thread = require 'pulpo.thread'
local loader = require 'pulpo.loader'
local util = require 'pulpo.util'
local memory = require 'pulpo.memory'
local errno = require 'pulpo.errno'
local socket = require 'pulpo.socket'
local ssl = require 'pulpo.io.ssl'

local _M = {}
local C = ffi.C

local ffi_state, spdy = loader.load('spdy.lua', {

}, {}, "spdylay", [[
	#include <spdylay/spdylay.h>
]])

function _M.connect(p, addr, opts)
	local io = ssl.connect(p, addr, opts)
	opts = opts or default_opt
	local sslm = opts.ssl_manager or ssl_manager_client
	local ctx = memory.alloc_typed('pulpo_ssl_context_t')
	if ctx == ffi.NULL then 
		error('fail to allocate ssl context pointer') 
	end
	local fd = socket.create_stream(addr, opts.sockopts, ctx.addrinfo)
	if not fd then 
		error('fail to create socket:'..errno.errno()) 
	end
	-- print(sslm, ssl_manager, opts.ssl_manager)
	local sslp = ssl.SSL_new(sslm.ssl_ctx)
	-- print(sslp, sslp.method, sslm.ssl_ctx.method, ssl.SSLv23_client_method())
	if sslp == ffi.NULL then
		C.close(fd)
		error("fail to create SSL:"..ssl_errstr())
	end
	ssl.SSL_set_fd(sslp, fd)
	if _M.debug then
		sslp.info_callback = ssl_info_callback_cdata
	end
	ctx.ssl = sslp
	local io = p:newio(fd, HANDLER_TYPE_SSL, ctx)
	ssl_connect(io)
	return io
end

function _M.listen(p, addr, opts)
	opts = opts or default_opt
	local ai = memory.managed_alloc_typed('pulpo_addrinfo_t')
	local fd = socket.create_stream(addr, opts.sockopts, ai)
	if not fd then error('fail to create socket:'..errno.errno()) end
	if not socket.set_reuse_addr(fd, true) then
		C.close(fd)
		error('fail to listen:set_reuse_addr:'..errno.errno())
	end
	if C.bind(fd, ai.addrp, ai.alen[0]) < 0 then
		C.close(fd)
		error('fail to listen:bind:'..errno.errno())
	end
	if C.listen(fd, poller.config.maxconn) < 0 then
		C.close(fd)
		error('fail to listen:listen:'..errno.errno())
	end
	logger.info('ssl listen:', fd, addr)
	popts = memory.alloc_fill_typed('pulpo_ssl_option_t')
	popts.ssl_manager = opts.ssl_manager or ssl_manager_server
	popts.sockopts = opts.sockopts or nil
	return p:newio(fd, HANDLER_TYPE_SSL_LISTENER, popts)
end

return _M

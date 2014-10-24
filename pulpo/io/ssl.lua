local ffi = require 'ffiex.init'
local poller = require 'pulpo.poller'
local thread = require 'pulpo.thread'
local loader = require 'pulpo.loader'
local memory = require 'pulpo.memory'
local errno = require 'pulpo.errno'
local socket = require 'pulpo.socket'
local event = require 'pulpo.event'
local exception = require 'pulpo.exception'
local raise = exception.raise

local _M = {}
local C = ffi.C

local ffi_state, ssl = loader.load('ssl.lua', {
	"SSL_CTX_new", "SSL_new", "SSL_free", "SSL_get_error", "SSL_library_init", "SSL_load_error_strings", 
	"SSL_set_fd", "SSL_connect", "SSL_shutdown", "SSL_do_handshake", "SSL_accept", "SSL_read", "SSL_write", 
	"SSLv23_server_method", "TLSv1_server_method", "SSLv23_client_method", "TLSv1_client_method",
	"SSL_use_PrivateKey_file", "SSL_use_certificate_file", 
	"ERR_error_string", "ERR_get_error", "ERR_print_errors_fp", 

	"pulpo_ssl_manager_t", "pulpo_ssl_option_t", "pulpo_ssl_context_t",
}, {
	"SSL_CB_CONNECT_EXIT", "SSL_ERROR_SSL", "SSL_ERROR_WANT_READ", "SSL_ERROR_WANT_WRITE", "SSL_ERROR_SYSCALL",
	"SSL_FILETYPE_PEM", 
}, "ssl", [[
	#include <openssl/ssl.h>
	#include <openssl/err.h>
	typedef struct pulpo_ssl_context {
		SSL *ssl;
		pulpo_addrinfo_t addrinfo;
		unsigned int state:8, padd:24;
	} pulpo_ssl_context_t;
	typedef struct pulpo_ssl_manager {
		SSL_CTX		*ssl_ctx;
		char 		*pubkey, *privkey;
	} pulpo_ssl_manager_t;
	typedef struct pulpo_ssl_server_option {
		pulpo_ssl_manager_t *ssl_manager;
		pulpo_sockopt_t 	*sockopts;
	} pulpo_ssl_option_t;
]])

--> exception
exception.define('SSL', {
	message = function(t)
		local fmt = table.remove(t.args, 1)
		return fmt:format(unpack(t.args))
	end,
})


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

local SSL_CB_CONNECT_EXIT = ffi_state.defs.SSL_CB_CONNECT_EXIT
local SSL_ERROR_SSL = ffi_state.defs.SSL_ERROR_SSL
local SSL_ERROR_WANT_READ = ffi_state.defs.SSL_ERROR_WANT_READ
local SSL_ERROR_WANT_WRITE = ffi_state.defs.SSL_ERROR_WANT_WRITE
local SSL_ERROR_SYSCALL = ffi_state.defs.SSL_ERROR_SYSCALL
local SSL_FILETYPE_PEM = ffi_state.defs.SSL_FILETYPE_PEM

local HANDLER_TYPE_SSL
local HANDLER_TYPE_SSL_LISTENER

--> helper function which required to metatype
local function ssl_get_method(method)
	-- print("method name:", method)
	return ssl[method]()
end
local function ssl_errstr()
	return ffi.string(ssl.ERR_error_string(ssl.ERR_get_error(), nil))
end
--> cdef metatype decl 
ffi.metatype('pulpo_ssl_context_t', {
	__index = {
		fin = function (t)
			if t.ssl ~= ffi.NULL then
				ssl.SSL_shutdown(t.ssl)
				ssl.SSL_free(t.ssl)
			end
		end,
	}
})
ffi.metatype('pulpo_ssl_manager_t', {
	__index = {
		init = function (t, opts)
			t.ssl_ctx = ssl.SSL_CTX_new(ssl_get_method(opts.method))
			if t.ssl_ctx == ffi.NULL then
				raise("SSL", "server ssl context fail:", opts.method, ssl_errstr())
			end
			if opts.set_ctx_property then
				opts.set_ctx_property(t.ssl_ctx)
			end
			if opts.pubkey then
				t.pubkey = memory.strdup(opts.pubkey)
				if t.pubkey == ffi.NULL then
					raise("SSL", "public key path is NULL")
				end
			end
			if opts.privkey then
				t.privkey = memory.strdup(opts.privkey)
				if t.privkey == ffi.NULL then
					raise("SSL", "private key path is NULL")
				end
			elseif not opts.pubkey then
				raise("SSL", "if you specify privkey, set pubkey also")
			end
		end,
		fin = function (t)
			if t.ssl_ctx ~= ffi.NULL then
				ssl.SSL_CTX_free(t.ssl_ctx)
				t.ssl_ctx = ffi.NULL
			end
			if t.pubkey ~= ffi.NULL then
				memory.free(t.pubkey)
				t.pubkey = ffi.NULL
			end
			if t.privkey ~= ffi.NULL then
				memory.free(t.privkey)
				t.privkey = ffi.NULL
			end
		end,
	}
})

--> global var
local ssl_manager_client = memory.alloc_fill_typed('pulpo_ssl_manager_t')
local ssl_manager_server = memory.alloc_fill_typed('pulpo_ssl_manager_t')

--> helper function
local function ssl_info_callback(sslp, st, err)
	if st == SSL_CB_CONNECT_EXIT then
		if SSL_ERROR_SSL == ssl.SSL_get_error(sslp, err) then
			ssl.ERR_print_errors_fp(io.stderr)
			assert(false)
		end
	end
end
local ssl_info_callback_cdata = ffi.cast('void (*)(SSL *, int, int)', ssl_info_callback)

local function ssl_wait_io(io, err)
	local ret = ssl.SSL_get_error(io:ctx('pulpo_ssl_context_t*').ssl, err)
	if ret == SSL_ERROR_WANT_READ then 
		io:wait_read()
	elseif ret == SSL_ERROR_WANT_WRITE then
		io:wait_write()
	elseif ret == SSL_ERROR_SYSCALL then
		io:close('error')
		raise("SSL", 'ssl_wait_io fail (%d/%d):%d', err, ret, errno.errno())
	elseif ret == SSL_ERROR_ZERO_RETURN then
		io:close('remote')
		raise("pipe")
	else
		io:close('error')
		raise("SSL", 'ssl_wait_io fail (%d/%d):%d', err, ret, ssl_errstr())
	end
end

local function ssl_handshake(io, ctx)
	local n, ret
	while true do
		n = ssl.SSL_do_handshake(ctx)
		if n > 0 then
			break
		end
		ssl_wait_io(io, n)
	end
end

local function ssl_connect(io)
	local ctx = io:ctx('pulpo_ssl_context_t*')
	local sslp = ctx.ssl
::retry::
	if ctx.state == STATE.CONNECTING then
		event.wait(io:event('open'))
		return true
	elseif ctx.state == STATE.CONNECTED then
		return true
	end
	local n = C.connect(io:fd(), ctx.addrinfo.addrp, ctx.addrinfo.alen[0])
	if n < 0 then
		local eno = errno.errno()
		-- print('tcp_connect:', io:fd(), n, eno)
		if eno == EINPROGRESS then
			-- print('EINPROGRESS:to:', socket.inet_namebyhost(ctx.addrinfo.addrp))
			-- tcp layer also established below SSL_connect.
		elseif eno == ECONNREFUSED then
			goto retry -- maybe server listen backlog exceed
		end
	end
	ctx.state = STATE.CONNECTING
	-- assert(sslp.method == ssl.SSLv23_client_method(), "method invalid")
	local n = ssl.SSL_connect(sslp)
	if n < 0 then 
		ssl_wait_io(io, n)
		ssl_handshake(io, sslp)
	elseif n == 0 then
		io:close('error')
		raise("SSL", "unrecoverable error on SSL_connect:%s", ssl_errstr())
	end
	ctx.state = STATE.CONNECTED
	io:emit('open')	
	return true
end

local function ssl_server_socket(p, fd, ctx)
	return p:newio(fd, HANDLER_TYPE_SSL, ctx)	
end


--> handlers
local function ssl_read(io, ptr, len)
::retry::
	local n = ssl.SSL_read(io:ctx('pulpo_ssl_context_t*').ssl, ptr, len)
	if n < 0 then
		ssl_wait_io(io, n)
		goto retry
	end
	return n
end

local function ssl_write(io, ptr, len)
::retry::
	local n = ssl.SSL_write(io:ctx('pulpo_ssl_context_t*').ssl, ptr, len)
	if n < 0 then
		ssl_wait_io(io, n)
		goto retry
	end
	return n
end

local function ssl_accept_sub(io, fd, sslm, ctx, sslp)
	if _M.debug then
		sslp.info_callback = ssl_info_callback_cdata
	end
	if sslm.pubkey ~= ffi.NULL and ssl.SSL_use_certificate_file(sslp, sslm.pubkey, SSL_FILETYPE_PEM) < 0 then
		raise("SSL", "SSL_use_certificate_file fail")
	end
	if sslm.privkey ~= ffi.NULL and ssl.SSL_use_PrivateKey_file(sslp, sslm.privkey, SSL_FILETYPE_PEM) < 0 then
		raise("SSL", "SSL_use_PrivateKey_file fail")
	end
	ssl.SSL_set_fd(sslp, fd)
	local cio = ssl_server_socket(io.p, fd, ctx)
	local n = ssl.SSL_accept(sslp)
	if n < 0 then
		ssl_wait_io(cio, n)
		ssl_handshake(cio, sslp)
	elseif n == 0 then
		io:close('error')
		raise("SSL", "unrecoverable error on SSL_accept:%s", ssl_errstr())
	end
	return cio
end
local ctx
local function ssl_accept(io)
	if not ctx then
		ctx = memory.alloc_typed('pulpo_ssl_context_t')
		assert(ctx ~= ffi.NULL, "fail to alloc ssl_context")
	end
::retry::
	local n = C.accept(io:fd(), ctx.addrinfo.addrp, ctx.addrinfo.alen)
	if n < 0 then
		local eno = errno.errno()
		if eno == EAGAIN or eno == EWOULDBLOCK then
			io:wait_read()
			goto retry
		else
			raise("syscall", "accept", eno, io:nfd())
		end
	else
		local opts = io:ctx('pulpo_ssl_option_t*')
		if socket.setsockopt(n, opts.sockopts) < 0 then
			C.close(n)
			raise("syscall", "setsockopt", eno, n)
		end
		local sslm = opts.ssl_manager
		sslp = ssl.SSL_new(sslm.ssl_ctx)
		if sslp == ffi.NULL then
			C.close(n)
			raise("SSL", "SSL_new fail:%s", ssl_errstr())
		end
		ctx.ssl = sslp
		ctx.state = STATE.CONNECTING
		local ok, cio = pcall(ssl_accept_sub, io, n, sslm, ctx, sslp)
		ctx.state = STATE.CONNECTED
		if not ok then 
			logger.error('accept error:', cio)
			ctx:fin() 
		end
		ctx = nil
		return cio
	end
end

local function ssl_gc(io)
	local ctx = io:ctx('pulpo_ssl_context_t*')
	if ctx then
		ctx:fin()
		memory.free(ctx)
	end
	C.close(io:fd())
end

local function ssl_server_gc(io)
	C.close(io:fd())
end

HANDLER_TYPE_SSL = poller.add_handler("ssl", ssl_read, ssl_write, ssl_gc)
HANDLER_TYPE_SSL_LISTENER = poller.add_handler("ssl_listen", ssl_accept, nil, ssl_server_gc)

function _M.initialize(opts)
	ssl.SSL_library_init()
	if _M.debug then
		ssl.SSL_load_error_strings()
	end
	if not opts.use_original_ssl_ctx then
		opts.method = (opts.client_method or "SSLv23_client_method")
		ssl_manager_client = _M.new_context(opts)
		opts.method = (opts.server_method or "SSLv23_server_method")
		ssl_manager_server = _M.new_context(opts)
		thread.register_exit_handler("ssl.lua", function () 
			ssl_manager_client:fin() 
			ssl_manager_server:fin() 
		end)
	end
	return true
end

function _M.new_context(opts)
	local sslm = memory.alloc_fill_typed('pulpo_ssl_manager_t')
	sslm:init(opts)
	return sslm
end

local default_opt = {}
function _M.connect(p, addr, opts)
	opts = opts or default_opt
	local sslm = opts.ssl_manager or ssl_manager_client
	local ctx = memory.alloc_typed('pulpo_ssl_context_t')
	if ctx == ffi.NULL then 
		raise("malloc", "pulpo_ssl_context_t") 
	end
	local fd = socket.stream(addr, opts.sockopts, ctx.addrinfo)
	if not fd then 
		raise("syscall", "socket", errno.errno()) 
	end
	-- print(sslm, ssl_manager, opts.ssl_manager)
	local sslp = ssl.SSL_new(sslm.ssl_ctx)
	-- print(sslp, sslp.method, sslm.ssl_ctx.method, ssl.SSLv23_client_method())
	if sslp == ffi.NULL then
		C.close(fd)
		raise("SSL", "SSL_new fails:%s", ssl_errstr())
	end
	ssl.SSL_set_fd(sslp, fd)
	if _M.debug then
		sslp.info_callback = ssl_info_callback_cdata
	end
	ctx.ssl = sslp
	ctx.state = STATE.INIT
	local io = p:newio(fd, HANDLER_TYPE_SSL, ctx)
	event.add_to(io, 'open')
	ssl_connect(io) -- because its unclear that how to check failure of SSL_read/SSL_write caused by non-connected or not,
	-- which is required to know to achieve lazy handshake, we assure ssl connection is established before any operation on that.
	return io
end

function _M.listen(p, addr, opts)
	opts = opts or default_opt
	local ai = memory.managed_alloc_typed('pulpo_addrinfo_t')
	local fd = socket.stream(addr, opts.sockopts, ai)
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
	logger.info('ssl listen:', fd, addr)
	popts = memory.alloc_fill_typed('pulpo_ssl_option_t')
	popts.ssl_manager = opts.ssl_manager or ssl_manager_server
	popts.sockopts = opts.sockopts or nil
	return p:newio(fd, HANDLER_TYPE_SSL_LISTENER, popts)
end

return _M
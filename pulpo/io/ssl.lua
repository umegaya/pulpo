local ffi = require 'ffiex.init'
local poller = require 'pulpo.poller'
local thread = require 'pulpo.thread'
local loader = require 'pulpo.loader'
local memory = require 'pulpo.memory'
local errno = require 'pulpo.errno'
local socket = require 'pulpo.socket'
local event = require 'pulpo.event'
local fs = require 'pulpo.fs'
local exception = require 'pulpo.exception'
local raise = exception.raise

local _M = {}
local C = ffi.C

local ffi_state, ssl = loader.load('ssl.lua', {
	"SSL_CTX_new", "SSL_new", "SSL_free", "SSL_get_error", "SSL_library_init", "SSL_load_error_strings", 
	"SSL_set_fd", "SSL_connect", "SSL_shutdown", "SSL_do_handshake", "SSL_accept", "SSL_read", "SSL_write", 
	"SSLv23_server_method", "TLSv1_server_method", "SSLv23_client_method", "TLSv1_client_method",
	"SSL_CTX_use_certificate_file", "SSL_CTX_use_PrivateKey_file", 
	"ERR_error_string", "ERR_get_error", "ERR_print_errors_fp", 

	"pulpo_ssl_manager_t", "pulpo_ssl_server_context_t", "pulpo_ssl_context_t",
}, {
	"SSL_CB_CONNECT_EXIT", "SSL_ERROR_SSL", "SSL_ERROR_WANT_READ", 
	"SSL_ERROR_WANT_WRITE", "SSL_ERROR_SYSCALL", "SSL_ERROR_ZERO_RETURN",
	"SSL_FILETYPE_PEM", 
}, "ssl", [[
	#include <openssl/ssl.h>
	#include <openssl/err.h>
	typedef struct pulpo_ssl_context {
		SSL *ssl;
		pulpo_addr_t addr;
		unsigned int state:8, padd:24;
	} pulpo_ssl_context_t;
	typedef struct pulpo_ssl_manager {
		SSL_CTX		*ssl_ctx;
		char 		*pubkey, *privkey;
	} pulpo_ssl_manager_t;
	typedef struct pulpo_ssl_server_context {
		pulpo_ssl_manager_t *ssl_manager;
		pulpo_sockopt_t 	*sockopts;
	} pulpo_ssl_server_context_t;
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
local SSL_ERROR_ZERO_RETURN = ffi_state.defs.SSL_ERROR_ZERO_RETURN
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
				t.ssl = ffi.NULL
			end
		end,
		connected = function (t)
			return t.state == STATE.CONNECTED
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
				if not fs.exists(opts.pubkey) then
					raise('not_found', 'public key file', opts.pubkey)
				end
				t.pubkey = memory.strdup(opts.pubkey)
				if t.pubkey == ffi.NULL then
					raise("SSL", "public key path is NULL")
				end
				if ssl.SSL_CTX_use_certificate_file(t.ssl_ctx, t.pubkey, opts.filetype or SSL_FILETYPE_PEM) < 0 then
					raise("SSL", "SSL_CTX_use_certificate_file fail")
				end
			end
			if opts.privkey then
				if not fs.exists(opts.privkey) then
					raise('not_found', 'private key file', opts.privkey)
				end
				t.privkey = memory.strdup(opts.privkey)
				if t.privkey == ffi.NULL then
					raise("SSL", "private key path is NULL")
				end
				if ssl.SSL_CTX_use_PrivateKey_file(t.ssl_ctx, t.privkey, opts.filetype or SSL_FILETYPE_PEM) < 0 then
					raise("SSL", "SSL_CTX_use_certificate_file fail")
				end
			elseif opts.pubkey then
				raise("SSL", "if you specify pubkey, set privkey also")
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
		if not io:wait_read() then
			raise("pipe")
		end
	elseif ret == SSL_ERROR_WANT_WRITE then
		if not io:wait_write() then
			raise("pipe")
		end
	elseif ret == SSL_ERROR_SYSCALL then
		--io:close('error')
		raise("SSL", ('ssl_wait_io fail (%d/%d):%d'):format(err, ret, errno.errno()))
	elseif ret == SSL_ERROR_ZERO_RETURN then
		raise("pipe")
	else
		raise("SSL", ('ssl_wait_io fail (%d/%d):%s'):format(err, ret, ssl_errstr()))
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

local function ssl_connect_sub(io, sslp)
	local n = ssl.SSL_connect(sslp)
	if n < 0 then 
		ssl_wait_io(io, n)
		ssl_handshake(io, sslp)
	elseif n == 0 then
		raise("SSL", "unrecoverable error on SSL_connect:%s", ssl_errstr())
	end
end

local function ssl_connect(io)
	local idx = 0
	local ctx = io:ctx('pulpo_ssl_context_t*')
	local sslp = ctx.ssl
::retry::
	if ctx.state == STATE.CONNECTING then
		event.join(io:event('open'))
		return true
	elseif ctx.state == STATE.CONNECTED then
		return true
	end
	local n = C.connect(io:fd(), ctx.addr.p, ctx.addr.len[0])
	if n < 0 then
		local eno = errno.errno()
		if eno == EINPROGRESS then
			-- tcp layer also established below SSL_connect.
		elseif eno == ECONNREFUSED then
			goto retry -- maybe server listen backlog exceed
		end
	end
	ctx.state = STATE.CONNECTING
	-- assert(sslp.method == ssl.SSLv23_client_method(), "method invalid")
	local ok, r = pcall(ssl_connect_sub, io, sslp)
	if not ok then
		io:close(r:is('SSL') and 'error' or 'remote')
		error(r)
	end
	ctx.state = STATE.CONNECTED
	io:emit('open')	
	return true
end

local function ssl_server_socket(p, fd, ctx, hdtype)
	return p:newio(fd, hdtype or HANDLER_TYPE_SSL, ctx)	
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
_M.rawread = ssl_read

local function ssl_write(io, ptr, len)
::retry::
	local n = ssl.SSL_write(io:ctx('pulpo_ssl_context_t*').ssl, ptr, len)
	if n < 0 then
		ssl_wait_io(io, n)
		goto retry
	end
	return n
end

local function ssl_writev(io, vec, len)
::retry::
	local s = ""
	for i=0,len-1 do
		s = s .. ffi.string(vec[i].iov_base, vec[i].iov_len)
	end
	if #s > 0 then
		return ssl_write(io, s, #s)
	else
		return 0
	end
end
_M.rawwritev = ssl_writev


local function ssl_accept_sub(cio, sslp)
	local n = ssl.SSL_accept(sslp)
	if n < 0 then
		ssl_wait_io(cio, n)
		ssl_handshake(cio, sslp)
	elseif n == 0 then
		raise("SSL", "unrecoverable error on SSL_accept:%s", ssl_errstr())
	end
	return cio
end
local function ssl_accept(io, hdtype, _ctx)
	local idx = 0
	local cio
	local opts = io:ctx('pulpo_ssl_server_context_t*')
	local sslm = opts.ssl_manager
	local ctx = _ctx and ffi.cast('pulpo_ssl_context_t *', _ctx) or memory.alloc_typed('pulpo_ssl_context_t')
	ctx.addr:init()
	assert(ctx ~= ffi.NULL, "fail to alloc ssl_context")
::retry::
	local n = C.accept(io:fd(), ctx.addr.p, ctx.addr.len)
	if n < 0 then
		local eno = errno.errno()
		if eno == EAGAIN or eno == EWOULDBLOCK then
			if not io:wait_read() then
				raise('report', 'SSL:listener socket closed:'..tostring(io:fd()))
			end
			goto retry
		else
			if not _ctx then memory.free(ctx) end
			raise("syscall", "accept", eno, io:nfd())
		end
	else
		if socket.setsockopt(n, opts.sockopts) < 0 then
			C.close(n)
			if not _ctx then memory.free(ctx) end
			raise("syscall", "setsockopt", eno, n)
		end
		local sslp = ssl.SSL_new(sslm.ssl_ctx)
		if sslp == ffi.NULL then
			C.close(n)
			if not _ctx then memory.free(ctx) end
			raise("SSL", "SSL_new fail:%s", ssl_errstr())
		elseif _M.debug then
			sslp.info_callback = ssl_info_callback_cdata
		end
		ssl.SSL_set_fd(sslp, n)
		ctx.ssl = sslp
		cio = ssl_server_socket(io.p, n, ctx, hdtype)
		ctx.state = STATE.CONNECTING
		local ok, r = pcall(ssl_accept_sub, cio, sslp)
		if not ok then 
			ctx.state = STATE.INIT
			logger.report('accept error:', r)
			cio:close(r:is('SSL') and 'error' or 'remote')
			goto retry
		end
		ctx.state = STATE.CONNECTED
		return cio
	end
end
_M.rawaccept = ssl_accept

local function ssl_gc(io)
	local ctx = io:ctx('pulpo_ssl_context_t*')
	if ctx then
		ctx:fin()
		if ctx:connected() then
			memory.free(ctx)
		end
	end
	C.close(io:fd())
end

local function ssl_server_gc(io)
	memory.free(io:ctx('pulpo_ssl_server_context_t *'))
	C.close(io:fd())
end
local function ssl_addr(io)
	return io:ctx('pulpo_ssl_context_t*').addr
end

HANDLER_TYPE_SSL = poller.add_handler("ssl", ssl_read, ssl_write, ssl_gc, ssl_addr, ssl_writev)
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
function _M.connect(p, addr, opts, hdtype, ctx)
	opts = opts or default_opt
	local sslm = opts.ssl_manager or ssl_manager_client
	ctx = ctx and ffi.cast('pulpo_ssl_context_t*', ctx) or memory.alloc_typed('pulpo_ssl_context_t')
	if ctx == ffi.NULL then 
		raise("malloc", "pulpo_ssl_context_t") 
	end
	local fd = socket.stream(addr, opts.sockopts, ctx.addr)
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
	local io = p:newio(fd, hdtype or HANDLER_TYPE_SSL, ctx)
	event.add_to(io, 'open')
	-- because its unclear that how to check failure of SSL_read/SSL_write caused by non-connected or not,
	-- which is required to know to achieve lazy handshake, we assure ssl connection is established before any operation on that.
	ssl_connect(io)
	return io
end

function _M.listen(p, addr, opts, hdtype, ctx)
	opts = opts or default_opt
	local a = memory.managed_alloc_typed('pulpo_addr_t')
	local fd = socket.stream(addr, opts.sockopts, a)
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
	logger.debug('ssl listen:', fd, addr)
	popts = ctx and 
		ffi.cast('pulpo_ssl_server_context_t*', ctx) or 
		memory.alloc_fill_typed('pulpo_ssl_server_context_t')
	popts.ssl_manager = opts.ssl_manager or ssl_manager_server
	popts.sockopts = opts.sockopts or nil
	return p:newio(fd, hdtype or HANDLER_TYPE_SSL_LISTENER, popts)
end

return _M

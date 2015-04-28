local ffi = require 'ffiex.init'
local pulpo = require 'pulpo.init'
local poller = require 'pulpo.poller'
local util = require 'pulpo.util'
local memory = require 'pulpo.memory'
local errno = require 'pulpo.errno'
local socket = require 'pulpo.socket'
local http = require 'pulpo.io.http'
local ssl = require 'pulpo.io.ssl'
local exception = require 'pulpo.exception'

local _M = {}
local C = ffi.C


--> handler types
local HANDLER_TYPE_HTTPS, HANDLER_TYPE_HTTPS_SERVER, HANDLER_TYPE_HTTPS_LISTENER


--> cdefs
ffi.cdef [[
	typedef struct pulpo_https_context {
		//this is nasty hack to reuse ssl/tcp routines for http/https processing.
		//pointer of this struct cast to the ptr of following structs. so never move their decls from top of struct
		pulpo_ssl_context_t ssl;
		char *buffer;
		size_t len, ofs;
		struct phr_chunked_decoder decoder[1];
		union pulpo_https_payload {
			pulpo_http_request_t req;
			pulpo_http_response_t resp;
		};
	} pulpo_https_context_t;
	typedef struct pulpo_https_server_context {
		pulpo_ssl_server_context_t ssl_server;
	} pulpo_https_server_context_t;
]]
assert(ffi.offsetof('pulpo_https_context_t', 'ssl') == 0)
assert(ffi.offsetof('pulpo_https_server_context_t', 'ssl_server') == 0)



--> cdata pulpo_https_context_t
local https_context_mt = util.copy_table(http.context_mt)
https_context_mt.__index = https_context_mt
function https_context_mt:read(io, p, len)
	return ssl.rawread(io, p, len)
end
function https_context_mt:accept(io)
	return ssl.rawaccept(io, HANDLER_TYPE_HTTPS_SERVER, self)
end
function https_context_mt:writev(io, vec, len)
	return ssl.rawwritev(io, vec, len)
end
ffi.metatype('pulpo_https_context_t', https_context_mt)


--> handlers
local function https_read(io)
	local ctx = io:ctx('pulpo_https_context_t*')
	return ctx:read_response(io)
end

local function https_server_read(io)
	local ctx = io:ctx('pulpo_https_context_t*')
	return ctx:read_request(io)
end

local function https_write(io, body, len, header)
	return io:ctx('pulpo_https_context_t*'):write_request(io, body, len, header)
end

local function https_server_write(io, body, len, header)
	return io:ctx('pulpo_https_context_t*'):write_response(io, body, len, header)
end

local function https_accept(io)
	local ctx = memory.alloc_typed('pulpo_https_context_t')
	ctx:init_buffer()
	assert(ctx ~= ffi.NULL, "error alloc context")
	return ctx:accept(io)
end

local function https_gc(io)
	io:ctx('pulpo_https_context_t*'):fin()
	C.close(io:fd())
end

local function https_addr(io)
	return io:ctx('pulpo_https_context_t*').ssl.addr
end


HANDLER_TYPE_HTTPS = poller.add_handler("https", https_read, https_write, https_gc, https_addr)
HANDLER_TYPE_HTTPS_SERVER = poller.add_handler("https_server", https_server_read, https_server_write, https_gc, https_addr)
HANDLER_TYPE_HTTPS_LISTENER = poller.add_handler("https_listen", https_accept, nil, https_gc)

function _M.connect(p, addr, opts)
	local ctx = memory.alloc_typed('pulpo_https_context_t')
	ctx:init_buffer()
	return ssl.connect(p, addr, opts, HANDLER_TYPE_HTTPS, ctx)
end

function _M.listen(p, addr, opts)
	local ctx = memory.alloc_typed('pulpo_https_server_context_t')
	ctx.ssl_server.sockopts = socket.table2sockopt(opts, true)
	return ssl.listen(p, addr, opts, HANDLER_TYPE_HTTPS_LISTENER, ctx)
end

return _M

local ffi = require 'ffiex.init'
local pulpo = require 'pulpo.init'
local poller = require 'pulpo.poller'
local util = require 'pulpo.util'
local memory = require 'pulpo.memory'
local errno = require 'pulpo.errno'
local socket = require 'pulpo.socket'
local tcp = require 'pulpo.io.tcp'
local ssl = require 'pulpo.io.ssl'
local gen = require 'pulpo.generics'
local exception = require 'pulpo.exception'
local loader = require 'pulpo.loader'

local _M = {}
local C = ffi.C


--> handler types
local HANDLER_TYPE_HTTP, HANDLER_TYPE_HTTP_SERVER, HANDLER_TYPE_HTTP_LISTENER


--> exception
exception.define('http')


--> cdefs
local ffi_state, http_parser = loader.load('http.lua', {
	"phr_parse_request", "phr_parse_response", "phr_parse_headers", "phr_decode_chunked", 
	"struct phr_header", "struct phr_chunked_decoder",
}, {}, "picohttpparser", [[
	#include <picohttpparser.h>
]])
ffi.cdef [[
	typedef struct pulpo_http_request {
		char *buf; size_t len;
		char *method_p[1], *path_p[1];
		int minor_version[1];
		struct phr_header *headers_p;
		char *body_p[1];
		size_t method_len[1], path_len[1], num_headers[1], body_len[1];
	} pulpo_http_request_t;
	typedef struct pulpo_http_response {
		char *buf; size_t len;
		int minor_version[1], status_p[1];
		struct phr_header *headers_p;
		char *body_p[1];
		size_t method_len[1], path_len[1], num_headers[1], body_len[1];
	} pulpo_http_response_t;
	typedef struct pulpo_http_header {
		size_t num_headers;
		struct phr_header *headers;
	} pulpo_http_header_t;
	typedef struct pulpo_http_context {
		//this is nasty hack to reuse ssl/tcp routines for http/https processing.
		//pointer of this struct cast to the ptr of following structs. so never move their decls from top of struct
		pulpo_tcp_context_t tcp;
		char *buffer;
		size_t len, ofs;
		struct phr_chunked_decoder decoder[1];
		union pulpo_http_payload {
			pulpo_http_request_t req;
			pulpo_http_response_t resp;
		};
	} pulpo_http_context_t;
	typedef struct pulpo_http_server_context {
		pulpo_tcp_server_context_t tcp_server;
	} pulpo_http_server_context_t;
]]
assert(ffi.offsetof('pulpo_http_context_t', 'tcp') == 0)
assert(ffi.offsetof('pulpo_http_server_context_t', 'tcp_server') == 0)

local MAX_HEADERS = 100
local MAX_REQLEN = (8192 + 4096 * (MAX_HEADERS))
local MAX_TOKENS = 10240

local INITIAL_HEADER_BUFFER = 512
local CRLF = "\r\n"
local HEADER_SEP = ":"
local AGENT_SEP = "/"
local CONTENT_LENGTH = "Content-Length"
local TRANSFER_ENCODING = "Transfer-Encoding"
local CONNECTION = "Connection"
local KEEP_ALIVE = "Keep-Alive"
local USER_AGENT = "User-Agent"
local SERVER = "Server"
local LUACT_RPC_VERSION = "0.1.0"
local LUACT_AGENT = "Luact-RPC"
local LUACT_SERVER = "Luact-RPC-Server"
local X_LUACT_MSGID = "X-Luact-MsgID"


--> helpers
local vec_cache = {}
local pulpo_iovec_list = gen.erastic_list('pulpo_iovec_t')
local function new_vec()
	local vec
	if #vec_cache > 0 then
		vec = table.remove(vec_cache)
		vec:reset()
	else
		vec = memory.alloc_typed(pulpo_iovec_list)
		vec:init(16)
	end
	return vec
end
local function free_vec(vec)
	table.insert(vec_cache, vec)
end
_M.free_vec = free_vec
local function set_vector_to_str(iovector, idx, v, vlen)
	iovector:reserve(1)
	local vec = iovector:at(idx)
	vec.iov_base = ffi.cast('void *', v)
	vec.iov_len = vlen or #v
	iovector.used = iovector.used + 1
end
local function make_request(header, body, blen)
	local idx = 1
	local vec = new_vec()
	header[1] = ("%s %s HTTP/1.1"..CRLF):format(header[1], header[2])
	set_vector_to_str(vec, 0, header[1])
	if not header[USER_AGENT] then
		header[USER_AGENT] = LUACT_AGENT..AGENT_SEP..LUACT_RPC_VERSION
	end
	set_vector_to_str(vec, idx, USER_AGENT)
	set_vector_to_str(vec, idx + 1, HEADER_SEP)
	set_vector_to_str(vec, idx + 2, header[USER_AGENT])
	set_vector_to_str(vec, idx + 3, CRLF)
	idx = idx + 4
	if body and blen then
		if not header[CONTENT_LENGTH] then
			header[CONTENT_LENGTH] = tostring(tonumber(blen))..CRLF
		end
		set_vector_to_str(vec, idx, CONTENT_LENGTH)
		set_vector_to_str(vec, idx + 1, HEADER_SEP)
		set_vector_to_str(vec, idx + 2, header[CONTENT_LENGTH])
		idx = idx + 3
	end
	for k,v in pairs(header) do
		if type(k) == 'string' and (k ~= CONTENT_LENGTH) and (k ~= USER_AGENT) then
			set_vector_to_str(vec, idx, k)
			set_vector_to_str(vec, idx + 1, HEADER_SEP)
			set_vector_to_str(vec, idx + 2, v)
			set_vector_to_str(vec, idx + 3, CRLF)
			idx = idx + 4
		end
	end
	set_vector_to_str(vec, idx, CRLF)
	if body and blen then
		set_vector_to_str(vec, idx + 1, body, blen)
	end
	return vec
end
local function make_response(header, body, blen)
	local idx
	local vec = new_vec()
	header = header or {}
	if not header[CONTENT_LENGTH] then
		header[CONTENT_LENGTH] = tostring(tonumber(blen))..CRLF
	end
	if not header[CONNECTION] then
		header[CONNECTION] = KEEP_ALIVE..CRLF
	end
	header[1] = ("HTTP/1.1 %d %s"..CRLF):format(header[1] or 200, header[2] or "OK")
	header[SERVER] = LUACT_SERVER..AGENT_SEP..LUACT_RPC_VERSION..CRLF
	set_vector_to_str(vec, 0, header[1])
	set_vector_to_str(vec, 1, CONTENT_LENGTH)
	set_vector_to_str(vec, 2, HEADER_SEP)
	set_vector_to_str(vec, 3, header[CONTENT_LENGTH])
	set_vector_to_str(vec, 4, CONNECTION)
	set_vector_to_str(vec, 5, HEADER_SEP)
	set_vector_to_str(vec, 6, header[CONNECTION])
	set_vector_to_str(vec, 7, SERVER)
	set_vector_to_str(vec, 8, HEADER_SEP)
	set_vector_to_str(vec, 9, header[SERVER])
	idx = 10
	for k,v in pairs(header) do
		if type(k) == 'string' and 
			(k ~= CONTENT_LENGTH) and (k ~= CONNECTION) and (k ~= SERVER) then
			set_vector_to_str(vec, idx, k)
			set_vector_to_str(vec, idx + 1, HEADER_SEP)
			set_vector_to_str(vec, idx + 2, v)
			set_vector_to_str(vec, idx + 3, CRLF)
			idx = idx + 4
		end
	end
	set_vector_to_str(vec, idx, CRLF)
	set_vector_to_str(vec, idx + 1, body, blen)
	return vec
end
local function debuglog(...)
	if _M.DEBUG then
		logger.warn(...)
	end
end


--> pulpo_http_request cdata
_G.global_dump = false
local http_request_mt = {}
http_request_mt.__index = http_request_mt
http_request_mt.__cache = {}
function new_http_request()
	if #http_request_mt.__cache > 0 then
		return table.remove(http_request_mt.__cache)
	else
		local r = memory.alloc_typed('pulpo_http_request_t')
		r:init()
		return r
	end
end
function http_request_mt:init()
	self.buf = ffi.NULL
	self.body_p[0] = ffi.NULL
	self.headers_p = ffi.NULL
	return self
end
function http_request_mt:fin()
	if self.buf ~= ffi.NULL then
		memory.free(self.buf)
		self.buf = ffi.NULL
	end
	if self.body_p[0] ~= ffi.NULL then
		if self.body_len[0] > 0 then
			memory.free(self.body_p[0])
		end
		self.body_p[0] = ffi.NULL
	end
	if self.headers_p ~= ffi.NULL then
		memory.free(self.headers_p)
		self.headers_p = ffi.NULL
	end
	table.insert(self.__cache, self)
end
local header_work = memory.alloc_typed('pulpo_http_header_t')
function http_request_mt:cdata_headers(use_tmp)
	local p = use_tmp and header_work or ffi.new('pulpo_http_header_t')
	p.num_headers = self.num_headers[0]
	p.headers = self.headers_p
	return p
end
function http_request_mt:body()
	return ffi.string(self.body_p[0], self.body_len[0])
end
function http_request_mt:method()
	return ffi.string(self.method_p[0], self.method_len[0])
end
function http_request_mt:path()
	return ffi.string(self.path_p[0], self.path_len[0])
end
function http_request_mt:headers()
	return self:cdata_headers(true):as_table()
end
function http_request_mt:raw_payload()
	return self:method(), self:path(),
		self:cdata_headers(),
		self.body_p[0], self.body_len[0]
end
function http_request_mt:payload()
	return self:method(), self:path(),
		self:headers(),
		self.body_p[0], self.body_len[0]
end
ffi.metatype('pulpo_http_request_t', http_request_mt)


--> pulpo_http_response cdata
local http_response_mt = util.copy_table(http_request_mt)
http_response_mt.__index = http_response_mt
http_response_mt.__cache = {}
function new_http_response()
	if #http_response_mt.__cache > 0 then
		return table.remove(http_response_mt.__cache)
	else
		local r = memory.alloc_typed('pulpo_http_response_t')
		r:init()
		return r
	end
end
function http_response_mt:status()
	return self.status_p[0]
end
function http_response_mt:raw_payload()
	return self:status(), self:cdata_headers(), self.body_p[0], self.body_len[0]
end
function http_response_mt:payload()
	return self:status(), self:headers(), self.body_p[0], self.body_len[0]
end
ffi.metatype('pulpo_http_response_t', http_response_mt)


--> pulpo_http_header cdata
local http_header_mt = {}
http_header_mt.__index = http_header_mt
function http_header_mt:get(k)
	for i=0, tonumber(self.num_headers)-1 do
		local h = self.headers[i]
		if memory.cmp(k, h.name, #k) then
			return h.value, h.value_len
		end
	end
	return nil
end
function http_header_mt:getstr(k)
	local v, vl = self:get(k)
	return v and ffi.string(v, vl)
end
function http_header_mt:as_table()
	local r = {}
	for i=0, tonumber(self.num_headers)-1 do
		local h = self.headers[i]
		-- logger.info('as_table', h.name, h.name_len, h.value, h.value_len)
		r[ffi.string(h.name, h.name_len)] = ffi.string(h.value, h.value_len)
	end
	return r	
end
function http_header_mt:is_luact_agent()
	local v, vl = self:get(USER_AGENT)
	return v and memory.cmp(v, LUACT_AGENT, #LUACT_AGENT)
end
function http_header_mt:is_luact_server()
	local v, vl = self:get(SERVER)
	return v and memory.cmp(v, LUACT_SERVER, #LUACT_SERVER)
end
function http_header_mt:luact_msgid()
	local id = self:getstr(X_LUACT_MSGID)
	return id and tonumber(id) or 0
end
function http_header_mt:luact_msg_kind() 
	local id = self:getstr(USER_AGENT)
	return id and tonumber(id:match('Luact-No-RPC:([0-9])+$')) or nil
end
ffi.metatype('pulpo_http_header_t', http_header_mt)


--> http_context cdata
local http_context_mt = {}
http_context_mt.__index = http_context_mt
http_context_mt.header_work = memory.alloc_fill_typed('struct phr_header', MAX_HEADERS)
function http_context_mt:init_buffer()
	self.buffer, self.len, self.ofs = memory.alloc_typed('char', INITIAL_HEADER_BUFFER), INITIAL_HEADER_BUFFER, 0
end
function http_context_mt:reserve_buffer(sz)
	local tmp = self.len
	while (tmp - self.ofs) < sz do
		tmp = tmp * 2
	end
	if tmp ~= self.len then
		local ptr = memory.realloc_typed('char', self.buffer, tmp)
		if not ptr then
			exception.raise('malloc', 'char', tmp)
		end
		self.buffer = ptr
		self.len = tmp
	end
end
function http_context_mt:fin()
	-- TODO : reuse context_mt?
	if self.buffer ~= ffi.NULL then
		memory.free(self.buffer)
		self.buffer = ffi.NULL
	end
	memory.free(self)
end
function http_context_mt:get_content_length_and_encoding(hd, hdlen)
	local len, encode
	for i=0, tonumber(hdlen)-1 do
		local h = hd[i]
		local name = ffi.string(h.name, h.name_len)
		local val = ffi.string(h.value, h.value_len)
		debuglog('header', name, val)
		if name:lower() == TRANSFER_ENCODING:lower() then
			encode = ffi.string(h.value, h.value_len)
		end
		if name:lower() == CONTENT_LENGTH:lower() then
			len = tonumber(ffi.string(h.value, h.value_len))
		end
		if encode and len then
			break
		end
	end
	return len, encode
end
local empty_body_dummy = ""
function http_context_mt:parse_body(io, obj, headers, read_start)
	local ret
	obj.headers_p = memory.dup('struct phr_header', headers, obj.num_headers[0])
	-- copy current read buf to req object
	obj.buf, obj.len = self.buffer, self.len
	local body_buf_len, encode = self:get_content_length_and_encoding(headers, obj.num_headers[0])
	if not body_buf_len then -- does not have body
		obj.body_p[0] = ffi.cast('char *', empty_body_dummy)
		obj.body_len[0] = 0
		return obj
	end
	local body_ofs = 0
	local body, body_buf_used
	if self.ofs > read_start then
		body = memory.alloc_typed('char', math.max(body_buf_len, tonumber(self.ofs - read_start)))
		ffi.copy(body, obj.buf + read_start, self.ofs - read_start)
		body_buf_used = self.ofs - read_start
	else
		body = memory.alloc_typed('char', body_buf_len)
		body_buf_used = 0
	end
	self:init_buffer() -- this changes self.ofs, so below here we can call this.
	if encode == "chunked" then
		-- process chunked encoding
		memory.fill(self.decoder, ffi.sizeof(self.decoder[0]))
		self.decoder[0].consume_trailer = 1
::chunked_retry::
		if body_buf_used >= body_buf_len then
			local tmp = memory.realloc_typed('char', body, body_buf_len * 2)
			if not tmp then
				exception.raise('malloc', 'char', body_buf_len * 2)
			end
			body = tmp
			body_buf_len = body_buf_len * 2
		end
		ret = nil
		if body_ofs < body_buf_used then
			obj.body_len[0] = body_buf_used - body_ofs
			ret = http_parser.phr_decode_chunked(self.decoder, body + body_ofs, obj.body_len)
			if ret == -1 then
				exception.raise('http', 'malform request', ffi.string(body, body_ofs))
			end
			body_ofs = body_ofs + obj.body_len[0]
			assert(body_buf_used >= body_ofs)
		end
		-- no buff to process or not enought buffer received
		if (not ret) or (ret == -2) then
			debuglog(ret, body_buf_len, body_ofs)
			ret = self:read(io, body + body_ofs, body_buf_len - body_ofs)
			if not ret then
				obj:fin()
				return nil
			end
			debuglog('newly read:', ret, ffi.string(body + body_ofs, ret))
			body_buf_used = body_ofs + ret
			goto chunked_retry
		end
		-- return value. 
		-- ret > 0, it means there is next data in body_ofs + ret ~ body_buf_used
		-- set this value
		if ret > 0 then
			body_buf_len = body_ofs + ret
		else
			assert((body_ofs + ret) == body_buf_used)
			body_buf_len = body_buf_used
		end
	else
		-- normal read loop upto clen bytes
		while body_buf_used < body_buf_len do
			ret = self:read(io, body + body_buf_used, body_buf_len - body_buf_used)
			if not ret then
				obj:fin()
				return nil
			end
			body_buf_used = body_buf_used + ret
		end
		body_ofs = body_buf_used
	end
	if body_buf_used > body_buf_len then
		-- no chunked and already enough buffer received.
		local required = body_buf_used - body_buf_len
		-- this means current read buffer length is longer than actual response length, 
		-- should have been reading next response / request. so longer part of body_buf_len
		-- copy to self.buffer for next request / response parsing.
		self:reserve_buffer(required)
		-- logger.info('buffer', '[['..ffi.string(body + body_buf_len, required)..']]')
		-- logger.info('b4copy', self.buffer, body, body_buf_len, body_buf_used, required, self.len)
		ffi.copy(self.buffer, body + body_buf_len, required)
		self.ofs = required
		body_ofs = body_buf_len
	end
	obj.body_p[0] = body
	obj.body_len[0] = body_ofs
	return obj
end
function http_context_mt:read_request(io)
	local r, ret
	local req = new_http_request()
::retry::
	-- logger.warn(io:fd(), 'req read start', self, self.len, self.ofs)
	r = self:read(io, self.buffer + self.ofs, self.len - self.ofs)
	-- logger.warn(io:fd(), 'end req read', r, self.buffer, '['..ffi.string(self.buffer, r)..']')
	local prevbuflen = self.ofs
	if r then
		self.ofs = self.ofs + r
		if self.len <= self.ofs then
			local tmp = memory.realloc_typed('char', self.buffer, self.len * 2)
			if not tmp then
				exception.raise('malloc', 'char', self.len * 2)
			end
			self.buffer = tmp
			self.len = self.len * 2
		end
	end
	req.num_headers[0] = MAX_HEADERS
	ret = http_parser.phr_parse_request(
		self.buffer, self.ofs, 
		ffi.cast('const char **', req.method_p), req.method_len, 
		ffi.cast('const char **', req.path_p), req.path_len, 
		req.minor_version, self.header_work, req.num_headers, prevbuflen)
	if ret > 0 then
		-- TODO : find header which describe contents length or transfer encoding, and get body data and body len
		req = self:parse_body(io, req, self.header_work, ret)
		return req
	elseif ret == -1 then
		-- TODO : upgrade to http2
		exception.raise('http', 'malform request', ffi.string(self.buffer, self.ofs))
	elseif (not r) or (r == 0) then -- close connection
		req:fin()
		return nil
	else
		goto retry
	end
end
function http_context_mt:read_response(io)
	local r 
	local resp = new_http_response()
::retry::
	r = self:read(io, self.buffer + self.ofs, self.len - self.ofs)
	local prevbuflen = self.ofs
	if r then
		self.ofs = self.ofs + r
		if self.len <= self.ofs then
			local tmp = memory.realloc_typed('char', self.buffer, self.len * 2)
			if not tmp then
				exception.raise('malloc', 'char', self.len * 2)
			end
			self.buffer = tmp
			self.len = self.len * 2
		end
	end
	resp.num_headers[0] = MAX_HEADERS
	ret = http_parser.phr_parse_response(self.buffer, self.ofs, resp.minor_version, resp.status_p,
		ffi.cast('const char **', resp.body_p), resp.body_len, self.header_work,
		resp.num_headers, prevbuflen)
	if ret > 0 then
		-- TODO : find header which describe contents length or transfer encoding, and get body data and body len
		resp = self:parse_body(io, resp, self.header_work, ret)
		return resp
	elseif ret == -1 then
		exception.raise('http', 'malform response', ffi.string(self.buffer, self.ofs))
	elseif (not r) or (r == 0) then
		resp:fin()
		return nil
	else
		goto retry
	end
end
function http_context_mt:write_request(io, body, len, header)
	if type(body) == 'table' then
		header = body
		body = nil
	end
	local vec = make_request(header, body, len)
	local r = self:writev(io, vec.list, vec.used)
	free_vec(vec)
	return r
end
function http_context_mt:write_response(io, body, len, header)
	local vec = make_response(header, body, len)
	local r = self:writev(io, vec.list, vec.used)
	free_vec(vec)
	return r
end
function http_context_mt:read(io, p, len)
	return tcp.rawread(io, p, len)
end
function http_context_mt:accept(io)
	return tcp.rawaccept(io, HANDLER_TYPE_HTTP_SERVER, self.tcp)
end
function http_context_mt:writev(io, vec, len)
	return tcp.rawwritev(io, vec, len)
end
_M.context_mt = http_context_mt
ffi.metatype('pulpo_http_context_t', http_context_mt)



--> handlers
local function http_read(io)
	local ctx = io:ctx('pulpo_http_context_t*')
	return ctx:read_response(io)
end

local function http_server_read(io)
	local ctx = io:ctx('pulpo_http_context_t*')
	return ctx:read_request(io)
end

local function http_write(io, body, len, header)
	return io:ctx('pulpo_http_context_t*'):write_request(io, body, len, header)
end

local function http_server_write(io, body, len, header)
	return io:ctx('pulpo_http_context_t*'):write_response(io, body, len, header)
end

local function http_accept(io)
	local ctx = memory.alloc_typed('pulpo_http_context_t')
	assert(ctx ~= ffi.NULL, "error alloc context")
	ctx:init_buffer()
	return ctx:accept(io)
end

local function http_gc(io)
	io:ctx('pulpo_http_context_t*'):fin()
	C.close(io:fd())
end

local function http_server_gc(io)
	memory.free(io:ctx('void *'))
	C.close(io:fd())
end

local function http_addr(io)
	return io:ctx('pulpo_http_context_t*').tcp.addr
end

HANDLER_TYPE_HTTP = poller.add_handler("http", http_read, http_write, http_gc, http_addr)
HANDLER_TYPE_HTTP_SERVER = poller.add_handler("http_server", http_server_read, http_server_write, http_gc, http_addr)
HANDLER_TYPE_HTTP_LISTENER = poller.add_handler("http_listen", http_accept, nil, http_server_gc)

function _M.connect(p, addr, opts)
	local ctx = memory.alloc_typed('pulpo_http_context_t')
	ctx:init_buffer()
	return tcp.connect(p, addr, opts, HANDLER_TYPE_HTTP, ctx)
end

function _M.listen(p, addr, opts)
	local ctx = socket.table2sockopt(opts, true)
	return tcp.listen(p, addr, opts, HANDLER_TYPE_HTTP_LISTENER, ctx)
end

return _M

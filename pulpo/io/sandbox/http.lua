local ffi = require 'ffiex.init'
local poller = require 'pulpo.poller'
local util = require 'pulpo.util'
local memory = require 'pulpo.memory'
local errno = require 'pulpo.errno'
local socket = require 'pulpo.socket'
local ssl = require 'pulpo.io.ssl'

local _M = {}
local C = ffi.C


--> handler types
local HANDLER_TYPE_HTTP, HANDLER_TYPE_HTTP_LISTENER


--> exception
exception.define('http', {
	message = function(t)
		local fmt = table.remove(t.args, 1)
		return fmt:format(unpack(t.args))
	end,
})


--> const
local prefmsg = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
local prefmsg_len = #prefmsg


--> cdef
local EAGAIN = errno.EAGAIN
local EPIPE = errno.EPIPE
local EWOULDBLOCK = errno.EWOULDBLOCK
local ENOTCONN = errno.ENOTCONN
local ECONNREFUSED = errno.ECONNREFUSED
local ECONNRESET = errno.ECONNRESET
local EINPROGRESS = errno.EINPROGRESS
local EINVAL = errno.EINVAL

local SETTINGS_HEADER_TABLE_SIZE = 1
local SETTINGS_ENABLE_PUSH = 2
local SETTINGS_MAX_CONCURRENT_STREAMS = 3
local SETTINGS_INITIAL_WINDOW_SIZE = 4
local SETTINGS_MAX_FRAME_SIZE = 5
local SETTINGS_MAX_HEADER_LIST_SIZE = 6
local INITIAL_SETTINGS = {
	[SETTINGS_HEADER_TABLE_SIZE] = 4096,
	[SETTINGS_ENABLE_PUSH] = true,
	[SETTINGS_MAX_CONCURRENT_STREAMS] = nil,
	[SETTINGS_INITIAL_WINDOW_SIZE] = 65535,
	[SETTINGS_MAX_FRAME_SIZE] = 16777215,
	[SETTINGS_MAX_HEADER_LIST_SIZE] = nil,
}

local FRAME_DATA = (0x00)			--リクエストボディや、レスポンスボディを転送する
local FRAME_HEADERS = (0x01)		--圧縮済みのHTTPヘッダーを転送する
local FRAME_PRIORITY = (0x02)		--ストリームの優先度を変更する
local FRAME_RST_STREAM = (0x03) 	--ストリームの終了を通知する
local FRAME_SETTINGS = (0x04)		--接続に関する設定を変更する
local FRAME_PUSH_PROMISE = (0x05)	--サーバーからのリソースのプッシュを通知する
local FRAME_PING = (0x06)			--接続状況を確認する
local FRAME_GOAWAY = (0x07)			--接続の終了を通知する
local FRAME_WINDOW_UPDATE = (0x08)	--フロー制御ウィンドウを更新する
local FRAME_CONTINUATION = (0x09)	--HEADERSフレームやPUSH_PROMISEフレームの続きのデータを転送する

ffi.cdef [[
typedef struct pulpo_http2_frame_header {
	uint8_t length[3], type, flag;
	uint32_t reserve:1, stream_id:31;
	uint8_t p[0];
} pulpo_http2_frame_header_t;
]]

ffi.cdef (([[
typedef struct pulpo_http2_frame_setting {
	struct pulpo_http2_frame_setting_elem {
		uint16_t id;
		uint32_t value;
	} kv[%d]
} __attribute__((__packed__)) pulpo_http2_frame_setting_t;
]]):format(#INITIAL_SETTINGS))

ffi.cdef [[
typedef struct pulpo_http_context {
	pulpo_io_t *io; // transport layer (tcp/ssl)
	int ver; 		// 20 if using http2, or 11 when using http 1.1
	struct {
		char *key, *val;
	} *headers; 	// headers
	//work buf for handling frame data
	char *buffer;
	size_t len, ofs;
} pulpo_http_context_t;
]]



--> frame_header metamethod
local frame_header_mt = {}
frame_header_mt.__index = frame_header_mt
function frame_header_mt:__len()
	return ffi.sizeof('pulpo_http2_frame_header_t') + self:payload_len()
end
function frame_header_mt:payload()
	if self.type == FRAME_SETTINGS then
		return ffi.cast('pulpo_http2_frame_setting_t *', self.payload)
	else
		return nil
	end
end
function frame_header_mt:is(tp)
	return self.type == tp
end
function frame_header_mt:set_payload_len(len)
	self.length[2] = bit.band(0xFF, len)
	self.length[1] = bit.rshift(bit.band(0xFF00, len), 8)
	self.length[0] = bit.rshift(bit.band(0xFF0000, len), 16)
end
function frame_header_mt:payload_len()
	return tonumber(self.length[2]) + bit.lshift(tonumber(self.length[1]), 8) + bit.lshift(tonumber(self.length[1]), 16)
end
ffi.metatype('pulpo_http2_frame_header_t', frame_header_mt)



--> setting frame metamethod
local setting_frame_mt = {}
setting_frame_mt.__index = setting_frame_mt
function setting_frame_mt:__len()
	for i=0, (#INITIAL_SETTINGS - 1) do
		if self.kv[i].id == 0 then
			return (i * 1) * ffi.sizeof('struct pulpo_http2_frame_setting_elem')
		end
	end
	return ffi.sizeof('pulpo_http2_frame_setting_t')
end
function setting_frame_mt:apply(opts)
	local count = 0
	for k,v in pairs(opts) do
		if opts[k] and (opts[k] ~= INITIAL_SETTINGS[k]) then
			self.kv[k-1].id = k
			self.kv[k-1].value = v
			count = count + 1
		end
	end
	for i=count, (#INITIAL_SETTINGS)-1 do
		self.kv[i].id = 0
	end
end
ffi.metatype('pulpo_http2_frame_setting_t', setting_frame_mt)


--> http_context metamethod
local context_mt = {}
context_mt.__index = context_mt
function context_mt:send_preface()
	return self.io:write(prefmsg, prefmsg_len)
end
function context_mt:send_setting(opts)
	local setting = setting_frame:payload()
	setting:apply(opts)
	setting_frame:set_payload_len(#setting)
	return self.io:write(setting_frame, #setting_frame)
end
function context_mt:send_setting_ack()
	local f = self:read_frame()
	f.flag = 1
	f:set_payload_len(0)
	return self.io:write(f, #f)
end
function context_mt:read_frame()
end


--> helpers
local function make_frame_buffer(payload_len, frame_type)
	local p = ffi.cast('pulpo_http2_frame_header_t*', memory.alloc_fill_typed('char', payload_len))
	p:set_payload_len(payload_len)
	p.type = frame_type or 0
	return p
end

-- |Identifer(16bit)|Value(32bit)| = 6 byte per option
local setting_frame = make_frame_buffer(ffi.sizeof('pulpo_http2_frame_setting_t'), FRAME_SETTINGS)
local function http_connect(io, opts)
::retry::
	local ctx = io:ctx('pulpo_http_context_t*')
	-- send magic
	ctx:send_preface()
	-- send setting frame
	ctx:send_setting(opts)
	-- recv setting frame and ack
	ctx:send_setting_ack()
end

local function http_server_socket(p, fd, ctx)
	return p:newio(fd, HANDLER_TYPE_HTTP, ctx)	
end


--> handlers
local function http_read(io, ptr, len)
	local ctx = io:ctx('pulpo_http_context_t*')
::retry::
	local f = ctx:read_frame()
	if not f then
		return nil
	elseif f:is(FRAME_DATA) then
		return ctx:read_frame_payload(ptr, len)
	elseif f:is(FRAME_GOAWAY) then
		io:close('remote')
		return nil
	else
		-- TODO : other misc things(update header list, handle push, ...)
		goto retry
	end
end

local function http_write(io, ptr, len)
::retry::
	local n = C.send(io:fd(), ptr, len, 0)
	if n < 0 then
		local eno = errno.errno()
		-- print(io:fd(), 'write fails', n, eno)
		if eno == EAGAIN or eno == EWOULDBLOCK then
			io:wait_write()
			goto retry
		elseif eno == ENOTCONN then
			http_connect(io)
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
			http_connect(io)
			goto retry
		else
			error(('tcp write fails(%d) on %d'):format(eno, io:nfd()))
		end
	end
	return n
end

local ctx
local function http_accept(io)
::retry::
	-- print('http_accept:', io:fd())
	if not ctx then
		ctx = memory.alloc_typed('pulpo_http_context_t')
		assert(ctx ~= ffi.NULL, "error alloc context")
	end
	local n = C.accept(io:fd(), ctx.addr.p, ctx.addr.len)
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
	return http_server_socket(io.p, n, tmp)
end

local function http_gc(io)
	memory.free(io:ctx('void*'))
	C.close(io:fd())
end

HANDLER_TYPE_HTTP = poller.add_handler("http", http_read, http_write, http_gc)
HANDLER_TYPE_HTTP_LISTENER = poller.add_handler("http_listen", http_accept, nil, http_gc)

function _M.connect(p, addr, opts)
	return ssl.connect(p, addr, opts, HANDLER_TYPE_HTTP)
end

function _M.listen(p, addr, opts)
	return ssl.listen(p, addr, opts, HANDLER_TYPE_HTTP_LISTENER)
end

return _M
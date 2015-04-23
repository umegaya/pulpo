local thread = require 'pulpo.thread'
thread.initialize()
local util = require 'pulpo.util'
local socket = require 'pulpo.socket'
local memory = require 'pulpo.memory'
local ffi = require 'ffiex.init'

local ret
if ffi.os == "OSX" then
ret = socket.getifaddr() 
elseif ffi.os == "Linux" then
ret = socket.getifaddr()
end
print(socket.inet_namebyhost(ret:address()), socket.inet_namebyhost(ret:netmask()))

local ret = memory.alloc_fill_typed('char', 4096)
local ret2 = memory.alloc_fill_typed('char', 4096)
local function codec(src)
	-- print('------------- codec')
	local ofs, ofs2 = 0, 0
	for i=1,#src do
		-- print('encode', ('%q'):format(src[i]), #src[i])
		local _, olen = util.encode_binary(src[i], #src[i], ret + ofs, 4096 - ofs)
		ofs = ofs + olen
	end
	-- print('encode result', ('%q'):format(ffi.string(ret, ofs)))
	local rsrc = { len = {} }
	local len = ofs
	ofs = 0
	while len > ofs do
		local tmp, tlen, n_read  = util.decode_binary(ret + ofs, len - ofs, ret2 + ofs2, 4096 - ofs2)
		ofs = ofs + n_read
		ofs2 = ofs2 + tlen
		-- print('decode', ('%q'):format(ffi.string(tmp, tlen)), tlen, n_read, len, ofs)
		table.insert(rsrc, tmp)
		table.insert(rsrc.len, tlen)
	end
	for i=1,#src do
		-- print(#src[i], rsrc.len[i])
		assert(#src[i] == rsrc.len[i], "length should match")
		assert(src[i] == ffi.string(rsrc[i], rsrc.len[i]), "result should match")
	end
end

local srcs = {
	{""},
	{"", "\0"},
	{"", "abcd"},
	{"abcdefgh"},
	{"efgh", ""},
	{"bcde", "", "ijklmnop"},
	{("hoge"):rep(64)},
	{("hoge"):rep(49)},
	{(string.char(0)):rep(256)},
	{(string.char(0)):rep(77)},
	{(string.char(0x80)):rep(64)},
	{(string.char(0x80)..string.char(0x7f)):rep(256)},
	{("hoge"):rep(64), ("fuga"):rep(32), ("gufu"):rep(128)},
	{("hoge"):rep(64), (string.char(0)):rep(32), ("fuga"):rep(32), (string.char(0x80)..string.char(0x7f)):rep(128)},
}

for i=1,#srcs do
	codec(srcs[i])
end

-- check lexicographic order
ffi.cdef [[
union converter {
	uint64_t v;
	char p[0];
};
]]

local function u64tostr(u64)
	local p = memory.alloc_fill_typed('union converter')
	p.v = u64
	return ffi.string(p.p, ffi.sizeof('union converter'))
end

local srcs2 = {
	{""},
	{"", "\0"},
	{"", u64tostr(0)},
	{"", u64tostr(1)},
	{"", u64tostr(0xFFFFFFFFFFFFFFFFULL)},
	{"\0"},
	{"/a"},
	{"/aa"},
	{"/b"},
	{"a"},
	{"a\0"},
	{"a\0\0\0\0\0"},
	{"a\0\0\0\0\0\0"},
	{"abcdefgh"},
	{"abcdefgh", u64tostr(0)},
	{"abcdefgh", u64tostr(1)},
	{"abcdefgh", u64tostr(0xFFFFFFFFFFFFFFFFULL)},
	{"abcdefgh\0"}, 
	{"abcdefgh\0", u64tostr(0)}, 
	{"abcdefgh\0", u64tostr(1)}, 
	{"abcdefgh\0", u64tostr(0xFFFFFFFFFFFFFFFFULL)}, 
	{"b"},
	{"b\0"},
}

local converted = {}
for i=1,#srcs2 do
	local ofs = 0
	local p = memory.alloc_fill_typed('char', 256)
	for j=1,#(srcs2[i]) do
		local _, olen = util.encode_binary(srcs2[i][j], #srcs2[i][j], p + ofs, 256 - ofs)
		ofs = ofs + olen
	end
	table.insert(converted, {ffi.cast('unsigned char *', p), ofs})
	-- print('converted', ('%q'):format(ffi.string(p, ofs)))
end

for i=2,#converted do
	local prev, curr = converted[i - 1], converted[i]
	--[[
	print('----------------', srcs2[i][1], srcs2[i - 1][1])
	-- print('check', ('%q'):format(ffi.string(curr[1], curr[2])), ('%q'):format(ffi.string(prev[1], prev[2])))
	for i=0,curr[2]-1 do io.write((':%02x'):format(curr[1][i])) end; io.write('\n')
	print('vs')
	for i=0,prev[2]-1 do io.write((':%02x'):format(prev[1][i])) end; io.write('\n')
	--]]--
	assert(memory.rawcmp_ex(curr[1], curr[2], prev[1], prev[2]) > 0)
end


return true


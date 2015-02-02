local require_on_boot = (require 'pulpo.package').require
local _M = require_on_boot 'pulpo.defer.socket_c'

local ffi = require 'ffiex.init'
local util = require 'pulpo.util'
ffi.cdef [[
union luact_endian_checker {
	uint32_t u;
	uint8_t bytes[4];
};
]]
local c = ffi.new('union luact_endian_checker')
c.u = 0x00000001

local LITTLE_ENDIAN = (c.bytes[0] == 0x01)
logger.info('endian', LITTLE_ENDIAN, ('%02x,%02x,%02x,%02x'):format(c.bytes[0], c.bytes[1], c.bytes[2], c.bytes[3]))

-- returns true if litten endian arch, otherwise big endian. 
-- now this framework does not support pdp endian.
function _M.little_endian()
	return LITTLE_ENDIAN
end

--- Convert given short value to network byte order on little endian hosts
-- @param x	Unsigned integer value between 0x0000 and 0xFFFF
-- @return	Byte-swapped value
-- @see		htonl
-- @see		ntohs
function _M.htons(x)
	if LITTLE_ENDIAN then
		return bit.bor(
			bit.rshift( tonumber(x), 8 ),
			bit.band( bit.lshift( tonumber(x), 8 ), 0xFF00 )
		)
	else
		return x
	end
end

--- Convert given long value to network byte order on little endian hosts
-- @param x	Unsigned integer value between 0x00000000 and 0xFFFFFFFF
-- @return	Byte-swapped value
-- @see		htons
-- @see		ntohl
function _M.htonl(x)
	if LITTLE_ENDIAN then
		return _M.htons( bit.band( tonumber(x), 0xFFFF ) ) * 0x10000 + _M.htons( bit.rshift( tonumber(x), 16 ) ) 
	else
		return x
	end
end

function _M.htonll(x, check)
	if LITTLE_ENDIAN then
		local r = ffi.new('uint64_t', (_M.htonl( x % 0x100000000 ) * 0x100000000)) + _M.htonl( x / 0x100000000 )
		if not check then
			if (tonumber(_M.ntohll(r, true)) ~= tonumber(x)) then
				logger.error('htonll error')
				print(ffi.typeof(x), ffi.typeof(r), util.sprintf('%llx', 32, _M.ntohll(r, true)), util.sprintf('%llx', 32, x), _M.ntohll(r, true) - x)
			end
		end
		return r
	else
		return x
	end
end

function _M.htonll_signed(x)
	if LITTLE_ENDIAN then
		return ffi.new('int64_t', (_M.htonl( x % 0x100000000 ) * 0x100000000)) + _M.htonl( x / 0x100000000 )
	else
		return x
	end
end


--> htons/htonl/ntohs/ntohl 
--- borrow from http://svn.fonosfera.org/fon-ng/trunk/luci/libs/core/luasrc/ip.lua

--- Convert given short value to host byte order on little endian hosts
-- @class	function
-- @name	ntohs
-- @param x	Unsigned integer value between 0x0000 and 0xFFFF
-- @return	Byte-swapped value
-- @see		htonl
-- @see		ntohs
_M.ntohs = _M.htons

--- Convert given short value to host byte order on little endian hosts
-- @class	function
-- @name	ntohl
-- @param x	Unsigned integer value between 0x00000000 and 0xFFFFFFFF
-- @return	Byte-swapped value
-- @see		htons
-- @see		ntohl
_M.ntohl = _M.htonl

_M.ntohll = _M.htonll

-- load/store 2/4/8 byte number/ctype from/to bytes array
function _M.get16(bytes)
	return bit.band( bytes[0], 
		bit.lshift(bytes[1], 8) 
	)
end
function _M.sget16(str)
	return bit.band( str:byte(1), 
		bit.lshift(str:byte(2), 8) 
	)
end
function _M.set16(bytes, v)
	bytes[0] = bit.band(v, 0xFF)
	bytes[1] = bit.rshift(bit.band(v, 0xFF00), 8)
end

function _M.get32(bytes)
	return bit.bor( bytes[0], 
		bit.lshift(bytes[1], 8),  
		bit.lshift(bytes[2], 16), 
		bit.lshift(bytes[3], 24)
	)
end
function _M.sget32(str)
	return bit.bor( str:byte(1), 
		bit.lshift(str:byte(2), 8),  
		bit.lshift(str:byte(3), 16), 
		bit.lshift(str:byte(4), 24)
	)
end
function _M.set32(bytes, v)
	bytes[0] = bit.band(v, 0xFF)
	bytes[1] = bit.rshift(bit.band(v, 0xFF00), 8)
	bytes[2] = bit.rshift(bit.band(v, 0xFF0000), 16)
	bytes[3] = bit.rshift(bit.band(v, 0xFF000000), 24)
end

function _M.get64(bytes)
	return bit.band( bytes[0], 
		bit.lshift(bytes[1], 8), 
		bit.lshift(bytes[2], 16), 
		bit.lshift(bytes[3], 24), 
		bit.lshift(bytes[4], 32), 
		bit.lshift(bytes[5], 40), 
		bit.lshift(bytes[6], 48), 
		bit.lshift(bytes[7], 56) 
	)
end
function _M.sget64(str)
	return bit.band( str:byte(1), 
		bit.lshift(str:byte(2), 8), 
		bit.lshift(str:byte(3), 16), 
		bit.lshift(str:byte(4), 24), 
		bit.lshift(str:byte(5), 32), 
		bit.lshift(str:byte(6), 40), 
		bit.lshift(str:byte(7), 48), 
		bit.lshift(str:byte(8), 56) 
	)
end
function _M.set64(bytes, v)
	bytes[0] = bit.band(v, 0xFF)
	bytes[1] = bit.rshift(bit.band(v, 0xFF00), 8)
	bytes[2] = bit.rshift(bit.band(v, 0xFF0000), 16)
	bytes[3] = bit.rshift(bit.band(v, 0xFF000000), 24)
	bytes[4] = bit.rshift(bit.band(v, 0xFF00000000), 32)
	bytes[5] = bit.rshift(bit.band(v, 0xFF0000000000), 40)
	bytes[6] = bit.rshift(bit.band(v, 0xFF000000000000), 48)
	bytes[7] = bit.rshift(bit.band(v, 0xFF00000000000000), 56)
end

return _M

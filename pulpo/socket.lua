local require_on_boot = (require 'pulpo.package').require
local _M = require_on_boot 'pulpo.defer.socket_c'

-- load/store 2/4/8 byte from/to bytes array
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
	return bit.band( bytes[0], 
		bit.lshift(bytes[1], 8),  
		bit.lshift(bytes[2], 16), 
		bit.lshift(bytes[3], 24)
	)
end
function _M.sget32(str)
	return bit.band( str:byte(1), 
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

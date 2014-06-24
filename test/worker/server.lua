local i = 0
print('server.lua', i); i = i + 1
local ffi = require 'ffiex'
print(ffi, 'server.lua', i); i = i + 1
local pulpo = require 'pulpo.init'
print(ffi, 'server.lua', i); i = i + 1
local tcp = require 'pulpo.socket.tcp'
print(ffi, 'server.lua', i); i = i + 1

local loop = pulpo.mainloop
print(ffi, 'server.lua', i); i = i + 1
local config = pulpo.share_memory('config')
print(ffi, 'server.lua', i); i = i + 1

tcp.listen('0.0.0.0:8888'):by(loop, function (s)
	while true do
		local fd = s:read()
		-- print('accept:', fd:fd())
		fd:by(loop, function (s)
			-- print('read start')
			local ptr,len = ffi.new('char[256]')
			while true do
				len = s:read(ptr, 256)
				if len <= 0 then
					print('remote peer closed', s:fd())
					break
				end
				-- print('read end', len)
				s:write(ptr, len)
			end

			pulpo.stop("server")
		end)
	end
end)
print(ffi, 'server.lua', i); i = i + 1


--[[
local l = tcp.listen(...):by(loop)
while true do
	local s = l:read()
	if not s then
		break
	end
	-- with pulpo, you need to use callback function to describe concurrent processing.
	-- you may disappoint it, but I wanna say "not all callbacks are evil".
	s:by(loop, function (s)
		s:read(buf, len)
	end)
end
]]--
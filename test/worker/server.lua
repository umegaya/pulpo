local ffi = require 'ffiex'
local pulpo = require 'pulpo.init'
local tcp = require 'pulpo.socket.tcp'

local loop = pulpo.mainloop
local config = pulpo.share_memory('config')
local n_accept = 0

tcp.listen('0.0.0.0:8008'):by(loop, function (s)
	while loop.alive do
		local fd = s:read()
		n_accept = n_accept + 1
		-- print('accept:', fd:fd())
		fd:by(loop, function (s)
			-- print('read start')
			local ptr,len = ffi.new('char[256]')
			local cnt = 0
			while true do
				len = s:read(ptr, 256)
				if len <= 0 then
					-- print('remote peer closed', s:fd(), cnt)
					break
				end
				cnt = cnt + 1
				-- print('read end', len)
				s:write(ptr, len)
			end
		end)
		if (n_accept % 100) == 0 then
			logger.warn('server:accept:', n_accept)
		end
	end
end)


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

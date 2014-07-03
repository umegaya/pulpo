local ffi = require 'ffiex'
local pulpo = require 'pulpo.init'
local tentacle = pulpo.tentacle
local tcp = require 'pulpo.socket.tcp'

require 'test.worker.config'

local loop = pulpo.mainloop
local config = pulpo.share_memory('config')
local n_accept = 0

-- if executed by pulpo.run, main file is also run under tentacle.
local s = tcp.listen(loop, '0.0.0.0:8008')
while loop.alive do
	local _fd = s:read()
	n_accept = n_accept + 1
	-- print('accept:', _fd:fd())
	tentacle(function (fd)
		-- print('read start')
		local ptr,len = ffi.new('char[256]')
		local cnt = 0
		while true do
			len = fd:read(ptr, 256)
			if len <= 0 then
				-- print('remote peer closed', s:fd(), cnt)
				break
			end
			cnt = cnt + 1
			-- print('read end', len)
			fd:write(ptr, len)
		end
	end, _fd)
	if (n_accept % 100) == 0 then
		logger.warn('server:accept:', n_accept)
	end
end

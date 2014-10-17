local ffi = require 'ffiex.init'
local pulpo = require 'pulpo.init'
local tentacle = pulpo.tentacle
local tcp = require 'pulpo.io.tcp'

require 'test.tools.config'

local loop = pulpo.evloop
local tcp = loop.io.tcp
local config = pulpo.util.getarg('test_config_t*', ...) --pulpo.shared_memory('config')
local n_accept = 0

-- if executed by pulpo.run, main file is also run under tentacle.
local s = tcp.listen('0.0.0.0:'..tostring(config.port))
while loop.poller.alive do
	local _fd = s:read()
	n_accept = n_accept + 1
	-- print('accept:', _fd:fd())
	tentacle(function (fd)
		-- print('read start')
		local ptr,len = ffi.new('char[256]')
		while true do
			len = fd:read(ptr, 256)
			if not len then
				-- print('remote peer closed', s:fd(), cnt)
				break
			end
			-- print('read end', len)
			fd:write(ptr, len)
		end
		fd:close()
	end, _fd)
	--if (n_accept % 100) == 0 then
	--	logger.warn('server:accept:', n_accept)
	--end
end

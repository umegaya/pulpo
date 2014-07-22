local poller = require 'pulpo.poller'
local memory = require 'pulpo.memory'

--> handler for poller itself
local function poller_read(io, ptr, len)
	local p = io:ctx('pulpo_poller_t*')
::retry::
	if p:wait() == 0 then
		io:wait_read()
		goto retry
	end
end
local function poller_gc(io)
	local p = io:ctx('pulpo_poller_t*')
	p:fin()
	memory.free(p)
end

local HANDLER_TYPE_POLLER = _M.add_handler("poller", poller_read, nil, poller_gc)

function _M.new(p)
	local newp = poller.new()
	return poller.newio(p, newp:fd(), HANDLER_TYPE_POLLER, newp), newp
end

return _M

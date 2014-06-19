local thread = require 'pulpo.thread'
local poller = require 'pulpo.poller'

local _M = {}

function _M.initialize(opts)
	thread.initialize(opts)
	poller.initialize(opts)
end


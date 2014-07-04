local ffi = require 'ffiex'
local thread = require 'pulpo.thread'
local memory = require 'pulpo.memory'
local gen = require 'pulpo.generics'

local pipe = require 'pulpo.socket.pipe'

local _M = {}
local C = ffi.C

ffi.cdef [[
	typedef struct pulpo_pipe {
		int fds[2];
	} pulpo_pipe_t;
]]
ffi.cdef (([[
	typedef struct pulpo_linda_t {
		%s channels;
	} pulpo_linda_t;
]]):format(gen.mutex_ptr(gen.erastic_map('pulpo_pipe_t'))))

local channel_mt = {}
function channel_mt.recv(t, ptr, len)
	return t[1]:read(ptr, len)
end
function channel_mt.send(t, ptr, len)
	return t[2]:write(ptr, len)
end
function channel_mt.event(t, event)
	if event == 'write' then
		return t[2]:event(event)
	elseif event == 'read' then
		return t[1]:event(event)
	else
		error('unsupported event:'..event)
	end
end

ffi.metatype('pulpo_linda_t', {
	__index = {
		init = function (t)
			t.channels:touch(function (data)
				data:init()
			end)
		end,
		fin = function (t)
			t.channels:touch(function (data)
				data:fin()
			end)
		end,
		channel = function (t, poller, k, opts)
			local p = t.channels:touch(function (data, key)
				return data:put(key, function (entry)
					if C.pipe(entry.data.fds) ~= 0 then
						error('cannot create pipe:'..ffi.errno())
					end	
				end)
			end, tostring(k))
			logger.info(k, 'fds:', p.fds[0], p.fds[1])
			return setmetatable({pipe.create(poller, p.fds, nil, opts)}, {
				__index = channel_mt,
			})
		end
	},
})

return thread.share_memory('linda', function ()
	local ptr = memory.alloc_typed('pulpo_linda_t')
	ptr:init()
	return 'pulpo_linda_t', ptr
end)

local ffi = require 'ffiex.init'
local thread = require 'pulpo.thread'
local memory = require 'pulpo.memory'
local gen = require 'pulpo.generics'

local pipe = require 'pulpo.io.pipe'

local _M = {}
local C = ffi.C

ffi.cdef [[
	typedef struct pulpo_pipe {
		int fds[2];
	} pulpo_pipe_t;
	typedef struct pulpo_pipe_io {
		pulpo_io_t *io[2];
	} pulpo_pipe_io_t;
]]
ffi.cdef (([[
	typedef struct pulpo_linda_t {
		%s channels;
	} pulpo_linda_t;
]]):format(gen.mutex_ptr(gen.erastic_map('pulpo_pipe_t'))))

local channel_mt = {}
function channel_mt.read(t, ptr, len)
	return t.io[0]:read(ptr, len)
end
function channel_mt.write(t, ptr, len)
	return t.io[1]:write(ptr, len)
end
function channel_mt.__emid(t)
	return t.io[0]:__emid()
end
function channel_mt.close(t)
	t.io[0]:close()
	t.io[1]:close()
end
function channel_mt.fd(t)
	return t.io[0]:fd()
end
function channel_mt.reader(t)
	return t.io[0]
end
function channel_mt.writer(t)
	return t.io[1]
end
function channel_mt.read_yield(t)
	t.io[0]:read_yield()
end
function channel_mt.write_yield(t)
	t.io[1]:write_yield()
end
function channel_mt.reactivate_write(t)
	t.io[1]:reactivate_write()
end
function channel_mt.event(t, event)
	if event == 'write' then
		return t.io[1]:event(event)
	elseif event == 'read' then
		return t.io[0]:event(event)
	else
		error('unsupported event:'..event)
	end
end
ffi.metatype('pulpo_pipe_io_t', {
	__index = channel_mt
})

local linda_cache = {}
ffi.metatype('pulpo_linda_t', {
	__index = {
		init = function (t)
			t.channels:init(function (data)	
				data:init()
			end)
		end,
		fin = function (t)
			t.channels:touch(function (data)
				data:fin()
			end)
		end,
		remove = function (t, k)
			t.channels:touch(function (data, key)
				return data:remove(key)
			end, tostring(k))
		end,
		channel = function (t, poller, k, opts)
			local pio = linda_cache[k]
			if not pio then
				local p = t.channels:touch(function (data, key)
					return data:put(key, function (entry)
						if C.pipe(entry.data.fds) ~= 0 then
							error('cannot create pipe:'..ffi.errno())
						end	
					end)
				end, tostring(k))
				logger.debug(k, 'fds:', p.fds[0], p.fds[1])
				pio = ffi.new('pulpo_pipe_io_t')
				pio.io[0],pio.io[1] = pipe.new(poller, p.fds, nil, opts)
				linda_cache[k] = pio
			end
			return pio
		end
	},
})

return thread.shared_memory('linda', function ()
	local ptr = memory.alloc_typed('pulpo_linda_t')
	ptr:init()
	return 'pulpo_linda_t', ptr
end)

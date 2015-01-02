local ffi = require 'ffiex.init'
local memory = require 'pulpo.memory'
local gen = require 'pulpo.generics'
local exception = require 'pulpo.exception'
exception.define('shmem')

local _M = (require 'pulpo.package').module('pulpo.shmem')

ffi.cdef[[ 
	typedef struct pulpo_memblock {
		char *name;
		char *type;
		void *ptr;
	} pulpo_memblock_t;
]]
ffi.cdef(([[
	typedef struct pulpo_shmem {
		%s blocks;
	} pulpo_shmem_t;
]]):format(gen.mutex_ptr(gen.erastic_list('pulpo_memblock_t'))))

ffi.metatype('pulpo_shmem_t', {
	__index = {
		init = function (t, sz)
			t.blocks:init(function (data, size) data:init(size) end, sz or 16)
		end,
		fin = function (t, sz)
			t.blocks:fin(function (data) 
				for i=0,data.used-1,1 do
					e = data.list[i]
					memory.free(e.name)
					local typename = ffi.string(e.type)
					local obj = ffi.cast(typename.."*", e.ptr)
					local ok, fn = pcall(debug.getmetatable(obj).__index, obj, "fin")
					if ok then
						-- print('fin called for', typename)
						obj:fin()
					end
					memory.free(e.type)	
					memory.free(e.ptr)
				end
				data:fin() 
			end)
		end,
		find_or_init = function (t, _name, _init)
			return t.blocks:touch(function (data, name, init)
				data:reserve(1) -- at least 1 entry room
				local e
				for i=0,data.used-1,1 do
					e = data.list[i]
					if ffi.string(e.name) == name then
						return ffi.cast(ffi.string(e.type).."*", e.ptr)
					end
				end
				if not init then
					exception.raise('shmem', 'no initializer')
				end
				e = data.list[data.used]
				e.name = memory.strdup(name)
				if type(init) == "string" then
					e.type, e.ptr = memory.strdup(init), memory.alloc_fill_typed(init)
				elseif type(init) == "function" then
					local t, ptr = init()
					e.type, e.ptr = memory.strdup(t), ptr
				else
					exception.raise('shmem', 'initializer', 'not found', name)
				end
				data.used = data.used + 1
				return ffi.cast(ffi.string(e.type).."*", e.ptr)
			end, _name, _init)
		end,
		touch = function (t, _name, proc, ...)
			return t.blocks:touch(function (data, name, fn, ...)
				local e
				for i=0,data.used-1,1 do
					e = data.list[i]
					if ffi.string(e.name) == name then
						return fn(e, ...)
					end
				end
				exception.raise('shmem', 'memblock', 'not found', name)
			end, _name, proc, ...)
		end,
		delete = function (t, _name)
			return t.blocks:touch(function (data, name)
				local e, found
				for i=0,data.used-1,1 do
					e = data.list[i]
					if found then
						data.list[i - 1] = data.list[i]
					elseif (ffi.string(e.name) == name) then
						memory.free(e.name)
						local typename = ffi.string(e.type)
						local obj = ffi.cast(typename.."*", e.ptr)
						local ok, fn = pcall(debug.getmetatable(obj).__index, obj, "fin")
						if ok then
							-- print('fin called for', typename)
							obj:fin()
						end
						memory.free(e.type)	
						memory.free(e.ptr)
						found = true
					end
				end
				if found then
					data.used = data.used - 1
				end
				return true
			end, _name)
		end,
	}
})

return _M

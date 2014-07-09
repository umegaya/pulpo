local ffi = require 'ffiex'
local gen = require 'pulpo.generics'
local memory = require 'pulpo.memory'

local _M = {}

function _M.initialize()
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
				t.blocks:touch(function (data, size) data:init(size) end, sz or 16)
			end,
			fin = function (t, sz)
				t.blocks:touch(function (data) 
					for i=0,data.used-1,1 do
						e = data.list[i]
						memory.free(e.name)
						local typename = ffi.string(e.type)
						local obj = ffi.cast(typename.."*", e.ptr)
						local ok, fn = pcall(debug.getmetatable(obj).__index, obj, "fin")
						if ok then
							print('fin called for', typename)
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
						print('init is not specified:'..name)
						error("no attempt to initialize but not found:"..name)
					end
					e = data.list[data.used]
					e.name = memory.strdup(name)
					if type(init) == "string" then
						e.type, e.ptr = memory.strdup(init), memory.alloc_fill_typed(init)
					elseif type(init) == "function" then
						local t, ptr = init()
						assert(ptr and ptr ~= ffi.NULL)
						e.type, e.ptr = memory.strdup(t), ptr
						assert(e.ptr and e.ptr ~= ffi.NULL)
					else
						pulpo_assert(false, "no initializer:"..type(init))
					end
					data.used = (data.used + 1)
					return ffi.cast(ffi.string(e.type).."*", e.ptr)
				end, _name, _init)
			end,
		}
	})
end

return _M

local ffi = require 'ffiex'
local memory = require 'pulpo.memory'
local loader = require 'pulpo.loader'

local C = ffi.C
local _M = {}

loader.add_lazy_initializer(function ()
	loader.load('generics.lua', {
		"pthread_rwlock_t", 
		"pthread_rwlock_rdlock", "pthread_rwlock_wrlock", 
		"pthread_rwlock_unlock", 
		"pthread_rwlock_init", "pthread_rwlock_destroy", 
	}, {}, nil, [[
		#include <pthread.h>
	]])
end)

local created = {}
local function cdef_generics(type, tag, tmpl)
	local typename = tag:format(type)
	if not created[typename] then
		created[typename] = true
		ffi.cdef(tmpl:format(typename, type, typename))
	end
	return typename
end

-- generic erastic list
local erastic_list_name_tag = "elastic_list_of_%s"
local erastic_list_tmpl = [[
	typedef struct _%s {
		int used, size;
		%s *list;
	} %s;
]]
function _M.erastic_list(type)
	local typename = cdef_generics(type, erastic_list_name_tag, erastic_list_tmpl)
	return typename, ffi.metatype(typename, {
		__index = {
			init = function (t, size)
				t.used = 0
				t.size = size
				t.list = assert(memory.alloc_fill_typed(type, size), 
					"fail to alloc "..type..":"..size)
			end,
			fin = function (t)
				memory.free(t.list)
			end,
			at = function (t, index)
				return t.list + index
			end,
			reserve = function (t, rsize)
				if t.used + rsize > t.size then
					local newsize = (t.used * 2)
					local p = memory.realloc_typed(type, newsize)
					if p then
						t.list = p
						t.size = newsize
					else
						print('expand '..type..'fails:'..newsize)
					end
				end
				return p
			end,
		}
	})
end

-- rwlock pointer
local rwlock_ptr_name_tag = "%s_rwlock_ptr_t"
local rwlock_ptr_tmpl = [[
	typedef struct _%s {
		pthread_rwlock_t lock[1];
		%s data;
	} %s;
]]
function _M.rwlock_ptr(type)
	local typename = cdef_generics(type, rwlock_ptr_name_tag, rwlock_ptr_tmpl)
	return typename, ffi.metatype(typename, {
		__index = {
			init = function (t, ctor)
				if ctor then t:write(ctor) end
				C.pthread_rwlock_init(t.lock, nil)
			end,
			fin = function (t, fzr)
				if fzr then t:write(fzr) end
				C.pthread_rwlock_destroy(t.lock)
			end,
			read = function (t, fn, ...)
				C.pthread_rwlock_rdlock(t.lock)
				local r = {pcall(fn, t.data, ...)}
				local ok = table.remove(r, 1)
				C.pthread_rwlock_unlock(t.lock)
				if ok then
					return unpack(r)
				else
					error("rwlock:read fails:"..table.remove(r, 1))
				end
			end,
			write = function (t, fn, ...)
				C.pthread_rwlock_wrlock(t.lock)
				local r = {pcall(fn, t.data, ...)}
				local ok = table.remove(r, 1)
				C.pthread_rwlock_unlock(t.lock)
				if ok then
					return unpack(r)
				else
					error("rwlock:write fails:"..table.remove(r, 1))
				end
			end,
		},
	})
end

return _M
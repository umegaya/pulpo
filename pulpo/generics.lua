local ffi = require 'ffiex'
local memory = require 'pulpo.memory'
local thread = require 'pulpo.thread'
local loader = require 'pulpo.loader'
local util = require 'pulpo.util'

local C = ffi.C
local PT = C
local ffi_state
local _M = {}

-- if you want to use gen independently with thread module, please call this.
function _M.initialize()
	ffi_state = loader.load('generics.lua', {
		"pthread_rwlock_t", 
		"pthread_rwlock_rdlock", "pthread_rwlock_wrlock", 
		"pthread_rwlock_unlock", 
		"pthread_rwlock_init", "pthread_rwlock_destroy", 
		"pthread_mutex_t",
		"pthread_mutex_lock", "pthread_mutex_unlock",
		"pthread_mutex_init", "pthread_mutex_destroy",
	}, {}, thread.PTHREAD_LIB_NAME, [[
		#include <pthread.h>
	]])
end

local created = {}
local function cdef_generics(type, tag, tmpl, mt, name)
	local typename = tag:format(type)
	name = name or typename
	if not created[name] then
		created[name] = true
		local decl = tmpl:gsub("%$(%w+)", {
			tagname = name, 
			basetype = type, 
			typename = name,
		})
		-- print('decl = '..decl)
		ffi.cdef(decl)
		ffi.metatype(name, mt)
	else
		ffi.typeof(name)
	end
	return name
end

-- generic erastic list
local erastic_list_name_tag = "elastic_list_of_%s"
local erastic_list_tmpl = [[
	typedef struct _$tagname {
		int used, size;
		$basetype *list;
	} $typename;
]]
function _M.erastic_list(type, name)
	return cdef_generics(type, erastic_list_name_tag, erastic_list_tmpl, {
		__index = {
			init = function (t, size)
				t.used = 0
				assert(size > 0)
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
					local newsize = (t.size * 2)
					local p = memory.realloc_typed(type, t.list, newsize)
					if p then
						t.list = p
						t.size = newsize
					else
						logger.error('expand '..type..' fails:'..newsize)
					end
				end
				return p
			end,
		}
	}, name)
end

-- erastic map
local erastic_map_name_tag = "elastic_map_of_%s"
local erastic_map_tmpl = [[
	typedef struct _$tagname {
		struct _$typename_elem {
			char *name;
			$basetype data;
		} *list;
		int size, used;
	} $typename;
]]
function _M.erastic_map(type, name)
	local elemtype = "struct _"..erastic_map_name_tag:format(type).."_elem"
	return cdef_generics(type, erastic_map_name_tag, erastic_map_tmpl, {
		__index = {
			init = function (t, size)
				t.size = size or 16
				t.used = 0
				t.list = memory.alloc_fill_typed(elemtype, t.size)
			end,
			fin = function (t)
				for i=0,t.used-1,1 do
					local e = t.list[i]
					memory.free(e.name)
					local ok, fn = pcall(debug.getmetatable(e.data).__index, e.data, "fin")
					if ok then
						e.data:fin()
					end
				end
				memory.free(t.list)
			end,
			reserve = function (t, space)
				if t.size < (t.used + space) then
					p = memory.realloc_typed(elemtype, t.list, t.size * 2)
					if p then
						t.list = p 
						t.size = t.size * 2
					else
						error('fail to reserve space:'..space)
					end
				end
			end,
			get = function (t, name)
				return t:put(name)
			end,
			put = function (t, name, init)
				t:reserve(1) -- at least 1 entry room
				local e
				for i=0,t.used-1,1 do
					e = t.list[i]
					if ffi.string(e.name) == name then
						return e.data
					end
				end
				if _G.type(init) ~= "function" then
					return nil
				end
				e = t.list[t.used]
				e.name = memory.strdup(name)
				init(e)
				t.used = (t.used + 1)
				return e.data
			end,
		}
	}, name)
end

-- rwlock pointer
local rwlock_ptr_name_tag = "%s_rwlock_ptr_t"
local rwlock_ptr_tmpl = [[
	typedef struct _$tagname {
		pthread_rwlock_t lock[1];
		$basetype data;
	} $typename;
]]
function _M.rwlock_ptr(type, name)
	return cdef_generics(type, rwlock_ptr_name_tag, rwlock_ptr_tmpl, {
		__index = {
			init = function (t, ctor, ...)
				assert(0 == PT.pthread_rwlock_init(t.lock, nil), "rwlock_init fails:"..ffi.errno())
				if ctor then t:write(ctor, ...) end
			end,
			fin = function (t, fzr)
				if fzr then t:write(fzr) end
				PT.pthread_rwlock_destroy(t.lock)
			end,
			read = function (t, fn, ...)
				PT.pthread_rwlock_rdlock(t.lock)
				local r = {pcall(fn, t.data, ...)}
				local ok = table.remove(r, 1)
				PT.pthread_rwlock_unlock(t.lock)
				if ok then
					return unpack(r)
				else
					error("rwlock:read fails:"..table.remove(r, 1))
				end
			end,
			write = function (t, fn, ...)
				PT.pthread_rwlock_wrlock(t.lock)
				local r = {pcall(fn, t.data, ...)}
				local ok = table.remove(r, 1)
				PT.pthread_rwlock_unlock(t.lock)
				if ok then
					return unpack(r)
				else
					error("rwlock:write fails:"..table.remove(r, 1))
				end
			end,
		},
	}, name)
end

-- mutex pointer
local mutex_ptr_name_tag = "%s_mutex_ptr_t"
local mutex_ptr_tmpl = [[
	typedef struct _$tagname {
		pthread_mutex_t lock[1];
		$basetype data;
	} $typename;
]]
function _M.mutex_ptr(type, name)
	return cdef_generics(type, mutex_ptr_name_tag, mutex_ptr_tmpl, {
		__index = {
			init = function (t, ctor, ...)
				assert(0 == PT.pthread_mutex_init(t.lock, nil), "mutex init error:"..ffi.errno())
				if ctor then t:touch(ctor, ...) end
			end,
			fin = function (t, fzr)
				if fzr then t:touch(fzr) end
				PT.pthread_mutex_destroy(t.lock)
			end,
			touch = function (t, fn, ...)
				PT.pthread_mutex_lock(t.lock)
				local r = {pcall(fn, t.data, ...)}
				local ok = table.remove(r, 1)
				PT.pthread_mutex_unlock(t.lock)
				if ok then
					return unpack(r)
				else
					error("mutex:touch fails:"..table.remove(r, 1))
				end
			end,
		},
	}, name)
end

return _M

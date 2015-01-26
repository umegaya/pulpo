local ffi = require 'ffiex.init'
local _M = {}
local C = ffi.C

-- malloc information list
local malloc_info_list = setmetatable({}, {
	__index = function (t, k)
		local ct = (type(k) == "string" and ffi.typeof(k.."*") or ffi.typeof("$ *", k))
		local v = { t = ct, sz = ffi.sizeof(k) }
		rawset(t, k, v)
		return v
	end
})

-- hmm, I wanna use importer(import.lua) but dependency for thread safety
-- prevents from refering pthread_*...
-- but I believe these interface never changed at 100 years future :D
-- TODO : using jemalloc
ffi.cdef [[
	void *malloc(size_t);
	void free(void *);
	void *realloc(void *, size_t);
	char *strdup(const char *);
	void *memmove(void *, const void *, size_t);
	int memcmp(const void *s1, const void *s2, size_t n);
]]

function _M.alloc_fill(sz, fill)
	local p = ffi.gc(C.malloc(sz), nil)
	if p ~= ffi.NULL then
		ffi.fill(p, sz, fill)
		return p
	end
	return nil
end

function _M.alloc_fill_typed(ct, sz, fill)
	local malloc_info = malloc_info_list[ct]
	local p = _M.alloc_fill((sz or 1) * malloc_info.sz, fill)
	if not p then return p end
	return ffi.cast(malloc_info.t, p)
end

function _M.alloc(sz)
	local p = ffi.gc(C.malloc(sz), nil)
	return p ~= ffi.NULL and p or nil
end
	
function _M.alloc_typed(ct, sz)
	local malloc_info = malloc_info_list[ct]
	local p = _M.alloc((sz or 1) * malloc_info.sz)
	if not p then return p end
	return ffi.cast(malloc_info.t, p)
end

function _M.strdup(str)
	if type(str) == "string" then
		local p = _M.alloc_typed('char', #str + 1)
		if p then
			ffi.copy(p, str)
		end
		return p
	else
		return C.strdup(str)
	end
end

function _M.realloc(p, sz)
	--logger.info('reallo from', debug.traceback())
	local p = ffi.gc(C.realloc(p, sz), nil)
	return p ~= ffi.NULL and p or nil
end

function _M.realloc_typed(ct, p, sz)
	local malloc_info = malloc_info_list[ct]
	p = _M.realloc(p, malloc_info.sz * (sz or 1))
	if not p then return p end	
	return ffi.cast(malloc_info.t, p)
end

function _M.managed_alloc(sz)
	local p = ffi.gc(C.malloc(sz), C.free)
	return p ~= ffi.NULL and p or nil
end

function _M.managed_alloc_typed(ct, sz)
	local malloc_info = malloc_info_list[ct]
	local p = C.malloc((sz or 1) * malloc_info.sz)
	if p == ffi.NULL then return nil end
	return ffi.gc(ffi.cast(malloc_info.t, p), C.free)
end

function _M.managed_realloc(p, sz)
	local p = ffi.gc(C.realloc(p, sz), C.free)
	return p ~= ffi.NULL and p or nil
end

function _M.managed_realloc_typed(ct, p, sz)
	local malloc_info = malloc_info_list[ct]
	p = C.realloc(p, malloc_info.sz * (sz or 1))
	if p == ffi.NULL then return nil end
	return ffi.gc(ffi.cast(malloc_info.t, p), C.free)
end

function _M.move(dst, src, sz)
	return C.memmove(dst, src, sz)
end

function _M.cmp(dst, src, sz)
	return C.memcmp(dst, src, sz) == 0
end

function _M.rawcmp(dst, src, sz)
	return C.memcmp(dst, src, sz)
end

function _M.free(p)
	if _M.DEBUG then
		print('free:', p, debug.traceback())
	end
	C.free(p)
end

return _M

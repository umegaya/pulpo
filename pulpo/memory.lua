local ffi = require 'ffiex.init'
local _M = {}
local C = ffi.C

local mtrace = {}
local total_alloc = 0
local total_free = 0

local function get_mtrace_info(sz)
	local i 
	local depth = 3
	while true do
		i = debug.getinfo(depth)
		if not i then
			assert(false)
		end
		if not i.source:match('pulpo/memory%.lua') then
			break
		end
		depth = depth + 1
	end
	return { sz = sz, src = i.source, line = i.currentline}
end
local function check_trace_consistency(show_ptrlist)
	local total = 0
	local keys = {}
	for k,v in pairs(mtrace) do
		if show_ptrlist then 
			table.insert(keys, k)
		end
		total = total + v.sz
	end
	if #keys > 0 then
		table.sort(keys)
		for i=1,#keys do
			local m = mtrace[keys[i]]
			logger.info(keys[i], m.sz, m.src..":"..m.line)
		end
	end
	assert((total_alloc - total_free) == total, 
		"total from list and sum does not match:"..tostring(total_alloc-total_free).."|"..tostring(total).." at "..debug.traceback())
end

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
if _M.TRACE then
	mtrace[tostring(p)] = get_mtrace_info(sz)
	total_alloc = total_alloc + sz
	check_trace_consistency()
end
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
if _M.TRACE then
	mtrace[tostring(p)] = get_mtrace_info(sz)
	total_alloc = total_alloc + sz
	check_trace_consistency()
end
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
		local p = C.strdup(str)
if _M.TRACE then
		if p ~= nil then
			local sz = C.strlen(str) + 1
			mtrace[tostring(ffi.cast('void *', p))] = get_mtrace_info(sz)
			total_alloc = total_alloc + sz
			check_trace_consistency()
		end
end
		return p
	end
end

function _M.dup(ct, src, sz)
	local p = _M.alloc_typed(ct, sz)
	if p then
		C.memmove(p, src, ffi.sizeof(ct) * sz)
	end
	return p
end

function _M.realloc(p, sz)
	--logger.info('reallo from', debug.traceback())
if not _M.TRACE then
	local p = ffi.gc(C.realloc(p, sz), nil)
	return p ~= ffi.NULL and p or nil
else
	local m = mtrace[tostring(ffi.cast('void *', p))]
	local is_null = (p == nil)
	local tmp = ffi.gc(C.realloc(p, sz), nil)
	if tmp ~= ffi.NULL then
		mtrace[tostring(ffi.cast('void *', p))] = nil
		mtrace[tostring(ffi.cast('void *', tmp))] = get_mtrace_info(sz)
		if m then
			total_free = total_free + m.sz
		else
			assert(is_null)
		end
		total_alloc = total_alloc + sz
		check_trace_consistency()
		return tmp
	else
		check_trace_consistency()	
		return nil
	end
end

end

function _M.realloc_typed(ct, p, sz)
	local malloc_info = malloc_info_list[ct]
	p = _M.realloc(p, malloc_info.sz * (sz or 1))
	if not p then return p end	
	return ffi.cast(malloc_info.t, p)
end

function _M.managed_alloc(sz)
	local p = ffi.gc(C.malloc(sz), _M.free)
if _M.TRACE then
	mtrace[tostring(p)] = get_mtrace_info(sz)
	total_alloc = total_alloc + sz
end
	return p ~= ffi.NULL and p or nil
end

function _M.managed_alloc_typed(ct, sz)
	local malloc_info = malloc_info_list[ct]
	local p = C.malloc((sz or 1) * malloc_info.sz)
	if p == ffi.NULL then return nil end
if _M.TRACE then
	local sz = malloc_info.sz * (sz or 1)
	mtrace[tostring(p)] = get_mtrace_info(sz)
	total_alloc = total_alloc + sz
end
	return ffi.gc(ffi.cast(malloc_info.t, p), _M.free)
end

function _M.move(dst, src, sz)
	return C.memmove(dst, src, sz)
end

function _M.fill(dst, sz, fill)
	ffi.fill(dst, sz, fill)
end

function _M.cmp(dst, src, sz)
	return C.memcmp(dst, src, sz) == 0
end

-- following 2 returns
-- >0 : dst is greater
-- <0 : src is greater
-- =0 : equals
function _M.rawcmp(dst, src, sz)
	return C.memcmp(dst, src, sz)
end

function _M.rawcmp_ex(dst, dsz, src, ssz)
	-- print('rawcmp_ex', dsz, ssz)
	-- if not dsz then
	-- 	print(debug.traceback())
	-- end
	if dsz <= 0 then -- dst is min key
		-- unless src is min key, dst is smaller
		return ssz <= 0 and 0 or -1
	elseif ssz <= 0 then -- src is min key
		-- unless dst is min key, src is smaller
		return dsz <= 0 and 0 or 1
	elseif dsz < ssz then
		local r = _M.rawcmp(dst, src, dsz)
		return r > 0 and 1 or -1 
	elseif dsz > ssz then
		local r = _M.rawcmp(dst, src, ssz)
		return r >= 0 and 1 or -1
	else
		return _M.rawcmp(dst, src, ssz)
	end
end

function _M.free(p)
	if _M.DEBUG then
		logger.info('free:', p, type(p), debug.traceback())
	end
if _M.TRACE then
	local m = mtrace[tostring(ffi.cast('void *', p))]
	if m then
		mtrace[tostring(ffi.cast('void *', p))] = nil
		total_free = total_free + m.sz
	else
		assert(false, "all allocated memory should traced:"..tostring(ffi.cast('void *', p)))
	end
end
	C.free(p)
end

function _M.smart(p)
	return ffi.gc(p, _M.free)
end

function _M.dump_trace(show_ptrlist)
	if _M.TRACE then
		check_trace_consistency(show_ptrlist)
		logger.info('memtrace', total_alloc, total_free, total_alloc - total_free, "gc", collectgarbage("count"))
	end
end

return _M

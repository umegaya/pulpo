local require_on_boot = (require 'pulpo.package').require
local _M = require_on_boot 'pulpo.defer.util_c'

--> hack for getting luajit include file path
local major = math.floor(jit.version_num / 10000)
local minor = math.floor((jit.version_num - major * 10000) / 100)
function _M.luajit_include_path()
	return '/usr/local/include/luajit-'..major..'.'..minor
end

--> non-ffi related util
function _M.n_cpu()
	local c = 0
	-- FIXME: I dont know about windows... just use only 1 core.
	if jit.os == 'Windows' then return 1 end
	if jit.os == 'OSX' then
		local ok, r = pcall(io.popen, 'sysctl -a machdep.cpu | grep thread_count')
		if not ok then return 1 end
		c = 1
		for l in r:lines() do 
			c = l:gsub("machdep.cpu.thread_count:%s?(%d+)", "%1")
		end
	else
		local ok, r = pcall(io.popen, 'cat /proc/cpuinfo | grep processor')
		if not ok then return 1 end
		for l in r:lines() do c = c + 1 end
		r:close()
	end
	return tonumber(c)
end

function _M.mkdir(path)
	-- TODO : windows?
	os.execute(('mkdir -p %s'):format(path))
end

function _M.rmdir(path)
	-- TODO : windows?
	os.execute(('rm -rf %s'):format(path))
end

function _M.merge_table(t1, t2, deep)
	for k,v in pairs(t2) do
		if deep and type(t1[k]) == 'table' and type(v) == 'table' then
			_M.merge_table(t1[k], v)
		else
			t1[k] = v
		end
	end
	return t1
end

function _M.copy_table(t, deep)
	local r = {}
	for k,v in pairs(t) do
		r[k] = (deep and type(v) == 'table') and _M.copy_table(v) or v
	end
	return r
end

function _M.table_equals(t1, t2)
	for k,v in pairs(t1) do
		if t2[k] == nil then
			logger.warn('teq not have', k)
			return false, k
		elseif type(t2[k]) == "table" then
			return _M.table_equals(t1[k], t2[k])		
		elseif t1[k] ~= t2[k] then
			logger.warn('teq not equal', k, t1[k], t2[k])
			return false, k
		end
	end
	for k,v in pairs(t2) do
		if not t1[k] then
			return false, k
		end
	end
	return true
end

-- TODO : faster pick up routine
function _M.random_k_from(t, k, filter)
	if #t <= k then 
		return t
	else
		local indices = {}
		local last = #t
		local safe_count = 0
		while #indices < k do
			local idx = math.random(1, #t)
			local good = true
			if filter and (not filter(t[idx])) then
				good = false
			else
				for j=1,#indices do
					if idx == indices[j] then
						good = false
						break
					end
				end
			end
			if good then
				table.insert(indices, idx)
			end
			safe_count = safe_count + 1
			if safe_count > (3 * #t) then
				break
			end
		end
		local r = {}
		for i=1,#indices do
			table.insert(r, t[indices[i]])
		end
		return r
	end
end

math.randomseed(os.clock())
function _M.random(...)
	return math.random(...)
end

--> transfer executable information through string
function _M.decode_proc(code)
	local executable
	local f, err = loadstring(code)
	if f then
		executable = f
	else
		f, err = loadfile(code)
		if f then
			executable = f
		else
			return nil, err
		end
	end
	return executable
end
function _M.encode_proc(proc)
	if type(proc) == "string" then
		return proc
	elseif type(proc) ~= "function" then
		error('invalid executable:'..type(proc))
	end
	return string.dump(proc)
end
function _M.create_proc(executable)
	return _M.decode_proc(_M.encode_proc(executable))
end
function _M.qsort(x, l, r, f, sw)
	if l < r then
		local m = math.random(l, r)	-- choose a random pivot in range l..u
		if sw then
			sw(x, l, m)
		else
			x[l], x[m] = x[m], x[l]			-- swap pivot to first position
		end
		local t = x[l]				-- pivot value
		m = l
		local i = l + 1
		while i <= r do
			-- invariant: x[l+1..m] < t <= x[m+1..i-1]
			if f(x[i],t) then
				m = m + 1
				if sw then
			 		sw(x, m, i)
				else
					x[m], x[i] = x[i], x[m]		-- swap x[i] and x[m]
				end
			end
			i = i + 1
		end
		if sw then
			sw(x, l, m)
		else
			x[l], x[m] = x[m], x[l]			-- swap pivot to first position
		end
		-- x[l+1..m-1] < x[m] <= x[m+1..u]
		_M.qsort(x, l, m-1, f, sw)
		_M.qsort(x, m+1, r, f, sw)
	end
end
--[[
local data = { [0] = 0, 6, 8, 3, 4, 9, 1, 2, 5, 7}
_M.qsort(data, 0, 9, function (a, b)
	return a < b
end)
for i=0,#data do
	assert(i == data[i])
end
]]--

return _M

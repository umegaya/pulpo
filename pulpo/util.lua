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
		if not t2[k] then
			return false, k
		elseif type(t2[k]) == "table" then
			return _M.table_equals(t1[k], t2[k])		
		elseif t1[k] ~= t2[k] then
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

function _M.random_k_from(t, k)
	if #t <= k then 
		return t
	else
		local r, tmp = {}, _M.copy_table(t)
		for i=1,k,1 do
			local e = table.remove(tmp, math.random(1, #tmp))
			table.insert(r, e)
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
			executable = function ()
				local ok, r = pcall(require, code)
				--if not ok then error(r) end
			end
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

return _M

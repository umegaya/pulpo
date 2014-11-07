local ffi = require 'ffiex.init'

local _M = {}
local exceptions = {}

local default_methods = {
	new = function (decl, bt, ...)
		return setmetatable({args={...}, bt = bt}, decl)
	end,
	message = function (t)
		return table.concat(t.args, ",")
	end,
	is = function (t, name)
		return t.name == name
	end,
	like = function (t, pattern)
		return t.name:match(pattern)
	end,
	raise = function (t)
		error(t)
	end,
}
local default_metamethods = {
	__tostring = function (t)
		return 'error:'..t.name..":"..t:message()..t.bt
	end,
	__serialize = function (t)
		return ("(require 'pulpo.exception').unserialize([[%s]],[[\n%s]],[=[%s]=])"):format(
			t.name, t.bt, _M.args_serializer and _M.args_serializer(t.args) or "{}"), true
	end,
}

-- local functions
local function def_exception(name, decl)
	decl = decl or {}
	local tmp1 = {}
	for k,v in pairs(default_methods) do
		local dv = rawget(decl, k)
		rawset(tmp1, k, dv or v)
	end
	tmp1.name = name
	local tmp2 = {}
	for k,v in pairs(default_metamethods) do
		local dv = rawget(decl, k)
		rawset(tmp2, k, dv or v)
	end
	tmp2.__index = tmp1
	return tmp2
end

local function new_exception(name, level, ...)
	local decl = exceptions[name]
	if not decl then
		_M.raise("not_found", "exception", name)
	end
	return decl.__index.new(decl, debug.traceback("", level), ...)
end

function _M.new(name, ...)
	return new_exception(name, 2, ...)
end
function _M.unserialize(name, bt, args)
	local decl = exceptions[name]
	if not decl then
		_M.raise("not_found", "exception", name)
	end
	local fn, err = loadstring(args)
	if err then
		_M.raise("runtime", err)
	end
	return decl.__index.new(decl, bt, unpack(fn()))
end

-- module functions
function _M.define(name, decl)
	exceptions[name] = def_exception(name, decl) 
	assert(exceptions[name].__index.new)
end

function _M.raise(name, ...)
	if _M.debug then
		local e = new_exception(name, 3, ...)
		logger.error(tostring(e))
		e:raise()
	else
		new_exception(name, 3, ...):raise()
	end
end

_M.define('not_found')
_M.define('invalid')
_M.define('runtime')
_M.define('malloc', {
	message = function (t)
		if t.args[2] then
			return "fail to allocate:"..t.args[1].."["..t.args[2].."]".."("..ffi.sizeof(t.args[1])*t.args[2].." bytes)"
		else
			return "fail to allocate:"..t.args[1].."("..ffi.sizeof(t.args[1]).." bytes)"
		end
	end,
})
_M.define('report', {
	__tostring = function (t)
		return t.args[1]
	end,
	raise = function (t)
		coroutine.yield(t)
	end,
})

return _M

local ffi = require 'ffiex'

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
}
local default_metamethods = {
	__tostring = function (t)
		return 'error:'..t.name..":"..t:message().." at "..t.bt
	end,
}

-- local functions
local function make_exception(name, decl)
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

function _M.new(name, bt, ...)
	local decl = exceptions[name]
	if not decl then
		_M.raise("not_found", "exception", name)
	end
	return decl.__index.new(decl, bt, ...)
end

-- module functions
function _M.define(name, decl)
	exceptions[name] = make_exception(name, decl) 
	assert(exceptions[name].__index.new)
end

function _M.raise(name, ...)
	if _M.debug then
		local e = _M.new(name, debug.traceback(), ...)
		logger.error(tostring(e))
		error(e)
	else
		error(_M.new(name, debug.traceback(), ...))
	end
end

_M.define('not_found')
_M.define('invalid')
_M.define('malloc', {
	message = function (t)
		if t.args[2] then
			return "fail to allocate:"..t.args[1].."["..t.args[2].."]".."("..ffi.sizeof(t.args[1])*t.args[2].." bytes)"
		else
			return "fail to allocate:"..t.args[1].."("..ffi.sizeof(t.args[1]).." bytes)"
		end
	end,
})

return _M

local original_require = _G.require
local runlevel_config = require 'pulpo.runlv'
local exception = require 'pulpo.exception'

local _M = {}

local function debuglog(...)
	if _M.DEBUG then print(...) end
end

local initializers = {}
function _M.init_modules(startlv, endlv)
	endlv = endlv or startlv or #initializers
	startlv = startlv or 1
	-- print('init_modules', startlv, endlv)
	for lv=startlv,endlv,1 do
		-- print(lv, initializers[lv])
		if initializers[lv] then
			for name,fn in pairs(initializers[lv]) do
				debuglog('init_module', lv, name)
				fn()
			end
			initializers[lv] = false
		end
	end
end
function _M.add_initializer(name, fn)
	local level
	for lv,module_names in ipairs(runlevel_config) do
		for _,module_name in ipairs(module_names) do
			-- print('add_initializer', lv, module_name, name)
			if name:match("pulpo%."..module_name) then
				debuglog(name, 'match with:', "pulpo%."..module_name)
				level = lv
				goto add_proc
			end
		end
	end
::add_proc::
	if level then
		local list = initializers[level]
		debuglog('add initializer at level', name, level, list)
		if not list then
			list = {}
			initializers[level] = list
		elseif list == false then
			-- init_module of this level already finished.
			-- _M.require will fallback to normal require 
			return nil
		end
		initializers[level][name] = fn
		return true
	else
		return false
	end
end
-- pseudo package tables
local pseudo_modules = {}
function _M.require(mod)
	-- print('boot.require', package, mod, package.loaded[mod], debug.traceback())
	if package.loaded[mod] then
		return package.loaded[mod]
	end
	local pseudo_M = {}
	pseudo_modules[mod] = pseudo_M
	local loaded = _M.add_initializer(mod, function ()
		original_require(mod)
		pseudo_modules[mod] = nil
	end)
	if loaded then
		return pseudo_M
	elseif loaded == nil then
		-- init_module of this level already called. 
		-- just require it. (safety)
		debuglog('immediateload', mod)
		return original_require(mod)
	else		
		exception.raise('not_found', 'runlv_entry', mod)
		return original_require(mod)
	end
end

function _M.module(mod)
	return pseudo_modules[mod] or {}
end

return _M

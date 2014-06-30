local term = require 'pulpo.terminal'

local _M = {
	loglevel = 1,
}

local settings = {} -- log name and output setting
local channels = {}

function _M.log(type, ...)
	local s = settings[type]
	if s and (not s.mute) and _M.loglevel <= s.level then
		local args = {...}
		if s.with_bt then
			table.insert(args, debug.traceback())			
		end
		s:sender(unpack(args))
	end
end

function default_out(setting, ...)
	term[setting.color]()
	print(...)
	term.resetcolor(0, 0)
	io.stdout:flush()
end

local function get_sender(channel_or_sender)
	if type(channel_or_sender) == 'function' then
		return channel_or_sender
	elseif type(channel_or_sender) == 'string' then
		return channels[channel_or_sender]
	else
		return channels.default
	end
end

local function setting(logtype, level, color, channel_or_sender)
	--print(logtype, _M[logtype], debug.traceback())
	assert(not _M[logtype], "already declared type:"..logtype)
	settings[logtype] = {
		color = color or "white", 
		level = level or 1,
		channel = channel_or_sender or "default",
		sender = get_sender(channel_or_sender), 
		mute = settings[logtype] and settings[logtype].mute,
	}
	assert(settings[logtype].sender, "invalid logtype:"..tostring(channel_or_sender))
	_M[logtype] = function (...)
		_M.log(logtype, ...)
	end
end

local function with_bt(logtype)
	if settings[logtype] then
		settings[logtype].with_bt = true
	end
end	

function _M.mute(logtype)
	if settings[logtype] then
		settings[logtype].mute = true
	end
end

function _M.redirect(channel, sender)
	channels[channel] = sender
	for k,v in pairs(settings) do
		if v.channel == channel then
			v.sender = sender
		end
	end
end

function _M.clearsetting()
	for k,v in pairs(settings) do
		_M[k] = nil
	end
	settings = {}
	outputs = {}
	_M.initialized = nil
end

function _M.initialize(sets, chs, global_name)
	if not _M.initialized then
		if outs then
			channels = chs
		else
			channels = {}
			_M.redirect("default", default_out)
		end
		if sets then
			settings = sets
		else
			_M.clearsetting()
			-- default setting
			setting("debug", 0, "cyan")
			setting("info", 1, "white")
			setting("notice", 1, "green")
			setting("warn", 2, "yellow")
			setting("error", 3, "magenta")
			with_bt("error")
			setting("fatal", 4, "red")
			with_bt("fatal")
		end
		if global_name ~= false then
			_G[global_name or "logger"] = _M
		end
		_M.initialized = true
	end
end

return _M

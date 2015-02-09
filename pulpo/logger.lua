local term = require 'pulpo.terminal'

local _M = {
	loglevel = 1,
}

local settings -- log name and output setting
local channels = {}

function default_out(setting, ...)
	term[setting.color]()
	io.write(setting.tag)
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

-- log setting object
local settings_mt = {}
settings_mt.__index = settings_mt
function settings_mt:new_log_type(logtype, tag, level, color, channel_or_sender)
	self[logtype] = {
		color = color or "white", 
		tag = tag,
		level = level or 1,
		channel = channel_or_sender or "default",
		sender = get_sender(channel_or_sender), 
		mute = false,
	}
	assert(self[logtype].sender, "invalid logtype:"..tostring(channel_or_sender))
end
function settings_mt:apply(log_module)
	for logtype, setting in pairs(self) do
		_M[logtype] = function (...)
			_M.log(logtype, ...)
		end
	end
end
function settings_mt:with_bt(logtype)
	if self[logtype] then
		self[logtype].with_bt = true
	end
end	
function settings_mt:mute(logtype)
	if self[logtype] then
		self[logtype].mute = true
	end
end
function settings_mt:set_channel(logtype, channel)
	assert(channels[channel], "no such channel:"..channel)
	if self[logtype] then
		self[logtype].channel = channel
		self[logtype].sender = channels[channel]
	end
end
function settings_mt:redirect(channel, sender)
	for k,v in pairs(self) do
		if v.channel == channel then
			v.sender = sender
		end
	end
end

-- module functions
function _M.log(type, ...)
	local s = settings[type]
	if s and (not s.mute) and _M.loglevel <= s.level then
		if s.with_bt then
			s:sender(..., debug.traceback())
		else
			s:sender(...)
		end
	end
end

function _M.new_settings()
	return setmetatable({}, settings_mt)
end

function _M.mute(logtype)
	settings:mute(logtype)
end

function _M.redirect(channel, sender)
	channels[channel] = sender
	settings:redirect(channel, sender)
end

function _M.set_channel(logtype, channel)
	settings:set_channel(logtype, channel)
end

function _M.clearsetting()
	for k,v in pairs(settings) do
		_M[k] = nil
	end
	settings = nil
	outputs = {}
	_M.initialized = nil
end

function _M.initialize(sets, chs, global_name)
	if not _M.initialized then
		if chs then
			channels = chs
		else
			channels = { default = default_out }
		end
		if sets then
			settings = sets
		else
			local s = _M.new_settings()
			-- default setting
			s:new_log_type("debug", "D:", 0, "cyan")
			s:new_log_type("info", "I:", 1, "white")
			s:new_log_type("notice", "N:", 1, "green")
			s:new_log_type("warn", "W:", 2, "yellow")
			s:new_log_type("error", "E:", 3, "magenta")
			s:with_bt("error")
			s:new_log_type("report", "R:", 3, "magenta")
			s:new_log_type("fatal", "F:", 4, "red")
			s:with_bt("fatal")
			settings = s
		end
		settings:apply(_M)
		if global_name ~= false then
			assert(not _G.logger, "global name 'logger' already used")
			_G[global_name or "logger"] = _M
		end
		_M.initialized = true
	end
	return _M
end

return _M

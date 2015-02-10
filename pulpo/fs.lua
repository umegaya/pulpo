local ffi = require 'ffiex.init'
local util = require 'pulpo.util'

local require_on_boot = (require 'pulpo.package').require
local _M = require_on_boot 'pulpo.defer.fs_c'
local C = ffi.C

if ffi.os == "Windows" then
	_M.PATH_SEPS = "¥"
	_M.ROOT_DESC = "C:¥¥"
else
	_M.PATH_SEPS = "/"
	_M.ROOT_DESC = "/"
end
function _M.path(...)
	return table.concat({...}, _M.PATH_SEPS)
end
function _M.abspath(...)
	return _M.ROOT_DESC..table.concat({...}, _M.PATH_SEPS)
end

-- file logger object
local file_logger_mt = {}
file_logger_mt.__index = file_logger_mt
function file_logger_mt:initialize(dir, opts)
	opts = opts or {}
	self.dir = dir
	self.size = opts.maxsize or 1000000
	self.num = opts.filenum or 10
	self.files = {}
	self.prefix = opts.prefix
	self.formatter = opts.formatter or self.default_formatter
	_M.mkdir(dir)
	self:open_current()
end
function file_logger_mt:finalize()
	if self.fd > 0 then
		C.close(self.fd)
	end
end
function file_logger_mt:open_current()
	if not self.fd then
		local st = _M.stat(self:current())
		self.wbytes = st and st[0].st_size or 0
	else
		if self.fd > 0 then
			C.close(self.fd)
		end
		self.wbytes = 0
	end
	local fd = _M.open(self:current(), bit.bor(_M.O_CREAT, _M.O_APPEND, _M.O_RDWR))
	if fd < 0 then
		exception.raise('fatal', 'open file fails')
	end
	self.fd = fd
end
function file_logger_mt:timestamp()
	local time, clock = util.clock_pair()
	return os.date('!%Y-%m-%dT%TZ', tonumber(time)).."."..("%06d"):format(tonumber(clock))
end
function file_logger_mt:new_filename(prefix)
	return self.dir.._M.PATH_SEPS..self:timestamp().."."..(prefix or "s")
end
function file_logger_mt:current()
	return self.dir.._M.PATH_SEPS.."current"
end
function file_logger_mt:default_formatter(setting, ...)
	local str = self:timestamp()..(self.prefix and (" "..self.prefix) or "")..setting.tag
	local args = {...}
	for i=1,select('#', ...) do
		if i > 1 then
			str = str .. "\t" .. tostring(args[i])
		else
			str = str .. tostring(args[i])
		end
	end
	str = str.."\n"
	return str
end
function file_logger_mt:rotate()
	local name = self:new_filename()
	local ok, r = pcall(_M.rename, self:current(), name)
	if not ok then
		exception.raise('fatal', r)
	end
	table.insert(self.files, name)
	if #self.files > self.num then
		_M.rm(self.files[1])
		table.remove(self.files, 1)
	end
	self:open_current()
end
function file_logger_mt:__call(setting, ...)
	local str = self:formatter(setting, ...)
	if (#str + self.wbytes) >= self.size then
		self:rotate()
	end
	self.wbytes = self.wbytes + C.write(self.fd, str, #str)
end

function _M.new_file_logger(dir, formatter, maxsize, filenum)
	local fl = setmetatable({}, file_logger_mt)
	fl:initialize(dir, formatter, maxsize, filenum)
	return fl
end

return _M

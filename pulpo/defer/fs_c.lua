local ffi = require 'ffiex.init'
local loader = require 'pulpo.loader'
local exception = require 'pulpo.exception'
exception.define('fs')


local _M = (require 'pulpo.package').module('pulpo.defer.errno_c')
local C = ffi.C

local openflags = {
	"O_RDONLY",
	"O_WRONLY",
	"O_RDWR",
	"O_ACCMODE", -- mask for open mode
	"O_NONBLOCK", -- no delay
	"O_APPEND", -- set append mode
	"O_CREAT", -- create if nonexistant 
	"O_TRUNC", -- truncate to zero length
	"O_EXCL", -- error if already exists

	"S_ISREG", -- is it a regular file?
	"S_ISDIR", -- directory?
	"S_ISCHR", -- character device?
	"S_ISBLK", -- block device?
	"S_ISFIFO", -- FIFO (named pipe)?
	"S_ISLNK", -- symbolic link? (Not in POSIX.1-1996.)
S_ISSOCK(m)
}
local ffi_state = loader.load('fs.lua', { 
	"opendir", "readdir", "closedir", "DIR", "pulpo_dir_t",
	"stat", "mkdir", "struct stat", "fileno", "unlink", 
}, openflags, nil, [[
	#include <dirent.h>
	#include <sys/stat.h>
	#include <unistd.h>
	#include <stdio.h>
	typedef struct pulpo_dir {
		DIR *dir;
	} pulpo_dir_t;
]])

local O_RDONLY = ffi_state.defs.O_RDONLY
local O_WRONLY = ffi_state.defs.O_WRONLY
local O_RDWR = ffi_state.defs.O_RDWR
local O_ACCMODE = ffi_state.defs.O_ACCMODE -- mask for open mode
local O_NONBLOCK = ffi_state.defs.O_NONBLOCK -- no delay
local O_APPEND = ffi_state.defs.O_APPEND -- set append mode
local O_CREAT = ffi_state.defs.O_CREAT -- create if nonexistant 
local O_TRUNC = ffi_state.defs.O_TRUNC -- truncate to zero length
local O_EXCL = ffi_state.defs.O_EXCL -- error if already exists
-- functional macro to check mode
local S_ISREG = ffi_state.defs.S_ISREG -- is it a regular file?
local S_ISDIR = ffi_state.defs.S_ISDIR -- directory?
local S_ISCHR = ffi_state.defs.S_ISCHR -- character device?
local S_ISBLK = ffi_state.defs.S_ISBLK -- block device?
local S_ISFIFO = ffi_state.defs.S_ISFIFO -- FIFO (named pipe)?
local S_ISLNK = ffi_state.defs.S_ISLNK -- symbolic link? (Not in POSIX.1-1996.)
-- export to openflags 
for _,flag in ipairs(openflags) do
	_M[flag] = ffi_state.defs[flag]
end

-- dir ctype
local dir_index = {}
local dir_mt = {
	__index = dir_idx,
	__gc = function (t)
		if t.dir ~= ffi.NULL then
			C.closedir(t.dir)
		end
	end
}
local function directory_iterator(dir, recursive)
	return function (d)
		local ent = C.readdir(d)
		--print('data:', ent.d_name[0], ent.d_name[1], ent.d_name[2])
		if ent ~= ffi.NULL then
			return ffi.string(ent.d_name)
		else
			return nil
		end
	end, dir
end
function dir_idx:iter()
	return directory_iterator(self.dir)
end
ffi.metatype('pulpo_dir_t', dir_mt)

-- module body
function _M.opendir(path)
	local p = ffi.new('pulpo_dir_t')
	p.dir = C.opendir(path)
	if p.dir == ffi.NULL then 
		exception.raise('syscall', "cannot open dir", ffi.string(path), ffi.errno()) 
	end
	return p
end
local st = ffi.new('struct stat[1]')
function _M.mkdir(path, readonly)
	local tmp
	for name in path:gmatch('[^/]+') do
		if tmp then
			tmp = (tmp .. "/" ..name)
		elseif path[1] == '/' then
			tmp = ('/'..name)
		else
			tmp = name
		end
		if C.stat(tmp, st) == -1 then
			local mode = readonly and '0555' or '0755'
			C.mkdir(tmp, tonumber(mode, 8))
		end
	end
	return _M.dir.open(path)
end
function _M.fileno(io)
	return C.fileno(io)
end

function _M.open(path, flags, mode)
	return C.open(path, flags, mode or O_RDWR)
end
function _M.is_dir(path)
	if C.stat(path, st) == -1 then
		exception.raise('syscall', "cannot open path", ffi.string(path), ffi.errno()) 
	end
	return S_ISDIR(st.st_mode) ~= 0
end
function _M.is_file(path)
	if C.stat(path, st) == -1 then
		exception.raise('syscall', "cannot open path", ffi.string(path), ffi.errno()) 
	end
	return S_ISREG(st.st_mode) ~= 0
end

return _M

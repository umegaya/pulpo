local ffi = require 'ffiex.init'
local loader = require 'pulpo.loader'
local exception = require 'pulpo.exception'
exception.define('fs')


local _M = (require 'pulpo.package').module('pulpo.defer.fs_c')
local C = ffi.C

local macros = {
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
	"S_ISSOCK", -- is socket ?

	"SEEK_SET", -- offset is set to offset byte
	"SEEK_CUR", -- offset is set to current offset + offset
	"SEEK_END", -- offset is set to file size + offset
}
local cdecls = { 
	"opendir", "readdir", "closedir", "DIR", "pulpo_dir_t", "open", "fsync", 
	"stat", "mkdir", "rmdir", "struct stat", "fileno", "unlink", "syscall", 
	"lseek", 
}
if ffi.os == "OSX" then
	table.insert(macros, "SYS_stat64")
	table.insert(cdecls, "getdirentries")
elseif ffi.os == "Linux" then
	table.insert(macros, "SYS_stat")
	table.insert(cdecls, "getdirentries64")
else
	assert(false, 'unsupported os:'..ffi.os)
end

local ffi_state = loader.load('fs.lua', cdecls, macros, nil, [[
	#include <dirent.h>
	#include <sys/stat.h>
	#include <unistd.h>
	#include <stdio.h>
	#include <sys/syscall.h>
	#include <sys/fcntl.h>
	typedef struct pulpo_dir {
		DIR *dir;
	} pulpo_dir_t;
]])

local syscall_stat, syscall_dents
if ffi.os == "OSX" then
	ffi.cdef [[
		/* at luajit's readdir returns this format of dirent. (not 64bit inode version.) */
		typedef struct pulpo_dirent {
			__uint32_t d_ino;                    /* file number of entry */
			__uint16_t d_reclen;            /* length of this record */
			__uint8_t  d_type;              /* file type, see below */
			__uint8_t  d_namlen;            /* length of string in d_name */
			char d_name[0];    /* name must be no longer than this */
		} pulpo_dirent_t;
	]]
	function syscall_stat(path, st)
		return C.syscall(ffi.defs.SYS_stat64, path, st)
	end
	function syscall_dents(fd, buf, n_bytes, basep)
		-- return C.syscall(ffi.defs.SYS_getdirentries64, fd, buf, n_bytes)
		return C.getdirentries(fd, buf, n_bytes, basep)
	end
elseif ffi.os == "Linux" then
	ffi.cdef [[
		typedef struct dirent pulpo_dirent_t;
	]]
	function syscall_stat(path, st)
		return C.syscall(ffi.defs.SYS_stat, path, st)
	end
	function syscall_dents(fd, buf, n_bytes, basep)
		return C.getdirentries64(fd, buf, n_bytes, basep)
	end
else
	assert(false, 'unsupported os:'..ffi.os)
end

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
for _,flag in ipairs(macros) do
	if flag:sub(1,2) == "O_" or flag:sub(1,5) == "SEEK_" then
		_M[flag] = ffi_state.defs[flag]
	end
end

-- dir ctype
local dir_index = {}
local dir_mt = {
	__index = dir_index,
	__gc = function (t)
		if t.dir ~= ffi.NULL then
			C.closedir(t.dir)
		end
	end
}
local basep = ffi.new('long[1]')
local buf = ffi.new('unsigned char[2048]')
local function raw_iterate_dir(path)
	local fd = C.open(path, O_RDONLY, 0)
	assert(fd >= 0, "fail to open dir:"..tostring(ffi.errno()))
	local size = 0
	local last = buf
	while true do
		local n_read = syscall_dents(fd, last, 2048 - size, basep)
		if n_read == 0 then
			break
		elseif n_read < 0 then
			exception.raise('syscall', 'dents', ffi.errno(), fd)
		end
		last, size = last + n_read, size + n_read
		local ofs = 0
		assert(size >= ffi.offsetof('pulpo_dirent_t', 'd_name'))
		while ofs < size do
			local ent = ffi.cast('pulpo_dirent_t*', buf + ofs)
			print(bit.rshift(ent.d_namlen, 8), ent.d_reclen, ffi.string(ent.d_name - 1), ofs)
			ofs = ofs + ent.d_reclen
		end
		if ofs < size then
			size = size - ofs
			memory.move(buf, buf + ofs, size)
			last = buf + size
		end
	end
end
local function directory_iterator(dir)
	return function (d)
		local ent = ffi.cast('pulpo_dirent_t *', C.readdir(d))
		if ent ~= ffi.NULL then
			-- print(ent.d_ino, ent.d_reclen, ent.d_namlen, ent.d_type, ent.d_name)
			return ffi.string(ent.d_name)
		else
			return nil
		end
	end, dir
end
function dir_index:iter()
	return directory_iterator(self.dir)
end
ffi.metatype('pulpo_dir_t', dir_mt)

-- module body
local stat_buf = ffi.new('struct stat[1]')
function _M.stat(path, st)
	st = st or stat_buf
	return syscall_stat(path, st) >= 0 and st or nil
end
function _M.exists(path)
	return syscall_stat(path, stat_buf) >= 0
end
function _M.opendir(path)
	local p = ffi.new('pulpo_dir_t')
	p.dir = C.opendir(path)
	return p.dir ~= ffi.NULL and p or nil
end
function _M.mkdir(path, readonly)
	local tmp
	for name in path:gmatch('[^/¥]+') do
		if tmp then
			tmp = _M.path(tmp, name)
		elseif path[1] ~= _M.PATH_SEPS then
			tmp = _M.path('', name)
		else
			tmp = name
		end
		if not _M.exists(tmp) then
			if C.mkdir(tmp, _M.mode(readonly and '0555' or '0755')) < 0 then
				exception.raise('syscall', "mkdir", tmp, ffi.errno()) 
			end
			if not _M.exists(tmp) then
				exception.raise('syscall', "mkdir", tmp, ffi.errno()) 
			end
		end
	end
end
function _M.rmdir(path, check_dir_empty)
	local dir = _M.opendir(path)
	if not dir then return end
	for file in dir:iter() do
		if check_dir_empty then
			exception.raise('fs', 'rmdir', 'not empty', file)
		end
		if not file:match('^%.+$') then
			file = _M.path(path, file)
			-- print('file:', file, _M.is_dir(file), _M.is_file(file))
			if _M.is_dir(file) then
				_M.rmdir(file)
			elseif _M.is_file(file) then
				_M.rm(file)
			end
		end
	end
	C.rmdir(path)
end
function _M.rm(path)
	return C.unlink(path) >= 0
end
function _M.fileno(io)
	return C.fileno(io)
end
function _M.mode(modestr)
	if modestr:byte() ~= ("0"):byte() then
		modestr = "0"..modestr
	end
	return ffi.new('__uint16_t', tonumber(modestr, "8"))
end
function _M.open(path, flags, mode)
	return C.open(path, flags, mode or O_RDWR)
end
function _M.is_dir(path)
	local st = _M.stat(path)
	return st and S_ISDIR(st[0].st_mode)
end
function _M.is_file(path)
	local st = _M.stat(path)
	return st and S_ISREG(st[0].st_mode)
end

return _M

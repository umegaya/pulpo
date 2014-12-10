local ffi = require 'ffiex.init'
local memory = require 'pulpo.memory'
local loader = require 'pulpo.loader'

--> ffi related utils
local _M = (require 'pulpo.package').module('pulpo.defer.util_c')

local C = ffi.C
local ffi_state = loader.load('util.lua', {
	"getrlimit", "setrlimit", "struct timespec", "struct timeval", "nanosleep",
	"gettimeofday", "snprintf", "strnlen", "strncmp", "getpid", 
}, {
	"RLIMIT_NOFILE",
	"RLIMIT_CORE",
}, nil, ffi.os == "OSX" and [[
	#include <time.h> 
	#include <sys/time.h>
	#include <sys/resource.h>
	#include <stdio.h>
	#include <unistd.h>
	#include <string.h>
]] or (ffi.os == "Linux" and [[
	#include <time.h>
	#include <sys/time.h> 
	#define __USE_GNU
	#include <sys/resource.h>
	#undef __USE_GNU
	#include <stdio.h>
	#include <unistd.h>
	#include <string.h>
]] or assert(false, "unsupported OS:"..ffi.os)))

local RLIMIT_CORE = ffi_state.defs.RLIMIT_CORE
local RLIMIT_NOFILE = ffi_state.defs.RLIMIT_NOFILE

--> add NULL symbola
ffi.NULL = ffi.new('void*')
_M.NULL = ffi.new('void*')

-- work memories
_M.req,_M.rem = ffi.new('struct timespec[1]'), ffi.new('struct timespec[1]')
_M.tval = ffi.new('struct timeval[1]')

function _M.getrlimit(type)
	local rlim = ffi.new('struct rlimit[1]')
	assert(0 == C.getrlimit(type, rlim), "rlimit fails:"..ffi.errno())
	return rlim[0].rlim_cur, rlim[0].rlim_max
end

function _M.maxfd(set_to, increase_only)
	if set_to then
		if increase_only then
			local current = _M.getrlimit(RLIMIT_NOFILE)
			if current >= set_to then
				logger.info('not need to increase because current:'..tonumber(current).." vs "..set_to)
				return current
			end
		end
		--> set max_fd to *set_to*
		C.setrlimit(RLIMIT_NOFILE, ffi.new('struct rlimit', {set_to, set_to}))
		return set_to
	else
		--> returns current max_fd
		return _M.getrlimit(RLIMIT_NOFILE)
	end
end

function _M.maxconn(set_to)
--[[ 
	if os somaxconn is less than TCP_LISTEN_BACKLOG, increase value by
	linux:	sudo /sbin/sysctl -w net.core.somaxconn=TCP_LISTEN_BACKLOG
			(and sudo /sbin/sysctl -w net.core.netdev_max_backlog=3000)
	osx:	sudo sysctl -w kern.ipc.somaxconn=TCP_LISTEN_BACKLOG
	(from http://docs.codehaus.org/display/JETTY/HighLoadServers)
]]
	if ffi.os == "Linux" then
	os.execute(('sudo /sbin/sysctl -w net.core.somaxconn=%d'):format(set_to))
	elseif ffi.os == "OSX" then
	os.execute(('sudo sysctl -w kern.ipc.somaxconn=%d'):format(set_to))
	end
	return set_to
end

function _M.setsockbuf(rb, wb)
	--[[ TODO: change rbuf/wbuf max /*
	* 	you may change your system setting for large wb, rb. 
	*	eg)
	*	macosx: sysctl -w kern.ipc.maxsockbuf=8000000 & 
	*			sysctl -w net.inet.tcp.sendspace=4000000 sysctl -w net.inet.tcp.recvspace=4000000 
	*	linux:	/proc/sys/net/core/rmem_max       - maximum receive window
    *			/proc/sys/net/core/wmem_max       - maximum send window
    *			(but for linux, below page does not recommend manual tuning because default it set to 4MB)
	*	see http://www.psc.edu/index.php/networking/641-tcp-tune for detail
	*/]]
	return rb, wb
end

function _M.sec2timespec(sec, ts)
	ts = ts or ffi.new('struct timespec[1]')
	local round = math.floor(sec)
	ts[0].tv_sec = round
	ts[0].tv_nsec = math.floor((sec - round) * (1000 * 1000 * 1000))
	return ts
end
function _M.sec2timeval(sec, ts)
	ts = ts or ffi.new('struct timeval[1]')
	local round = math.floor(sec)
	ts[0].tv_sec = round
	ts[0].tv_usec = math.floor((sec - round) * (1000 * 1000))
	return ts
end
-- nanosleep
function _M.sleep(sec)
	-- convert to nsec
	local req, rem = _M.req, _M.rem
	_M.sec2timespec(sec, _M.req)
	while C.nanosleep(req, rem) ~= 0 do
		local tmp = req
		req = rem
		rem = tmp
	end
end

-- get current time (with usec acurracy)
function _M.clock()
	C.gettimeofday(_M.tval, nil)
	return tonumber(_M.tval[0].tv_sec) + (tonumber(_M.tval[0].tv_usec) / 1000000)
end
function _M.clock_pair()
	C.gettimeofday(_M.tval, nil)
	return _M.tval[0].tv_sec, _M.tval[0].tv_usec
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

local sprintf_workmem
local sprintf_workmem_size = 0
function _M.rawsprintf(fmt, size, ...)
	if sprintf_workmem_size < (size + 1) then
		if sprintf_workmem then
			memory.free(sprintf_workmem)
		end
		sprintf_workmem = memory.alloc_typed('char', size + 1)
		sprintf_workmem_size = size + 1
	end
	local n = C.snprintf(sprintf_workmem, size + 1, fmt, ...)
	return sprintf_workmem, n
end
function _M.sprintf(fmt, size, ...)
	return ffi.string(_M.rawsprintf(fmt, size, ...))
end

function _M.strlen(p, estsize)
	return C.strnlen(p, estsize)
end
function _M.strcmp(a, b, len)
	return C.strncmp(a, b, len) == 0
end

function _M.getarg(ct, ...)
	return ffi.cast(ct, select(1, ...))
end

function _M.getpid()
	return C.getpid()
end

return _M

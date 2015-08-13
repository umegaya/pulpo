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

ffi.cdef [[
typedef uint64_t pulpo_walltime_t;
]]

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
				logger.debug('not need to increase because current:'..tonumber(current).." vs "..set_to)
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
	os.execute(('sudo /sbin/sysctl -w net.core.somaxconn=%d 2>/dev/null'):format(set_to))
	elseif ffi.os == "OSX" then
	os.execute(('sudo sysctl -w kern.ipc.somaxconn=%d 2>/dev/null'):format(set_to))
	end
	return set_to
end

function _M.getsockbuf()
	local rv, wv
	if ffi.os == "Linux" then
		rv = io.popen('sudo sysctl net.core.rmem_max 2>/dev/null')
		wv = io.popen('sudo sysctl net.core.wmem_max 2>/dev/null')
	elseif ffi.os == "OSX" then
		rv = io.popen('sudo sysctl net.inet.tcp.recvspace 2>/dev/null')
		wv = io.popen('sudo sysctl net.inet.tcp.sendspace 2>/dev/null')
	end
	local r = rv:read('*a')
	local w = wv:read('*a')
	-- print('getsockbuf:', r, r:match('([0-9]+)%c*$'), w, w:match('([0-9]+)%c*$'))
	return tonumber(r:match('[0-9]+%c*$')), tonumber(w:match('[0-9]+%c*$'))
end
function _M.setsockbuf(rb, wb)
	local crb, cwb = _M.getsockbuf()
	logger.notice('system rwbuf size:', crb, cwb)
	if not (crb and cwb) then
		return 
	end
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
	rb = rb or crb
	wb = wb or cwb
	if ffi.os == "Linux" then
		if crb < rb then
			logger.notice('set system rb to', rb)
			os.execute(('sudo sysctl -w net.core.rmem_max=%d'):format(rb))
		end
		if cwb < wb then
			logger.notice('set system wb to', wb)
			os.execute(('sudo sysctl -w net.core.wmem_max=%d'):format(wb))
		end
	elseif ffi.os == "OSX" then
		if (rb + wb) > (crb + cwb) then
			local sb = tonumber(io.popen('sudo sysctl kern.ipc.maxsockbuf'):read('*a'):match('[0-9]+%c*$'))
			if sb < (rb + wb) then
				logger.notice('set system sockbuf to', rb + wb)
				os.execute(('sudo sysctl -w kern.ipc.maxsockbuf=%d'):format(rb + wb))
			end
		end
		if crb < rb then
			logger.notice('set system rb to', rb)
			os.execute(('sudo sysctl -w net.inet.tcp.recvspace=%d'):format(rb))
		end
		if cwb < wb then
			logger.notice('set system wb to', wb)
			os.execute(('sudo sysctl -w net.inet.tcp.sendspace=%d'):format(wb))
		end
	end
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
local clock_int_work = memory.alloc_typed('pulpo_walltime_t')
function _M.walltime()
	C.gettimeofday(_M.tval, nil)
	clock_int_work[0] = _M.tval[0].tv_sec * 1000 * 1000
	return clock_int_work[0] + _M.tval[0].tv_usec
end
function _M.msec_walltime()
	local s,us = _M.clock_pair()
	return math.ceil(tonumber((s * 1000) + (us / 1000)))
end
function _M.sec2walltime(sec)
	return math.ceil(sec * 1000)
end
local fmt_buf = {}
local fmt_buf_index = 0
local fmt_buf_num = 16
local fmt_buf_size = {}
function _M.rawsprintf(fmt, size, ...)
	if not fmt_buf[fmt_buf_index] or (fmt_buf_size[fmt_buf_index] < (size + 1)) then
		fmt_buf[fmt_buf_index] = memory.realloc_typed('char', fmt_buf[fmt_buf_index] or ffi.NULL, size + 1)
		fmt_buf_size[fmt_buf_index] = size + 1
	end
	local p = fmt_buf[fmt_buf_index]
	local n = C.snprintf(p, size + 1, fmt, ...)
	fmt_buf_index = ((fmt_buf_index + 1) % fmt_buf_num)
	return p, n
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

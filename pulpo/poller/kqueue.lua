local ffi = require 'ffiex.init'
local util = require 'pulpo.util'
local memory = require 'pulpo.memory'
local loader = require 'pulpo.loader'
local event = require 'pulpo.event'

local _M = {}
local C = ffi.C
local handlers, gc_handlers, iolist

---------------------------------------------------
-- import necessary cdefs
---------------------------------------------------
local ffi_state,clib = loader.load("kqueue.lua", {
	"kqueue", "func kevent", "struct kevent", "socklen_t", "sockaddr_in", 
}, {
	"EV_ADD", "EV_ENABLE", "EV_DISABLE", "EV_DELETE", "EV_RECEIPT", "EV_ONESHOT",
	"EV_CLEAR", "EV_EOF", "EV_ERROR",
	"EVFILT_READ", 
	"EVFILT_WRITE", 
	"EVFILT_AIO", 
	"EVFILT_VNODE", 
		"NOTE_DELETE", -->		The unlink() system call was called on the file referenced by the descriptor.
		"NOTE_WRITE", -->		A write occurred on the file referenced by the descriptor.
		"NOTE_EXTEND", -->		The file referenced by the descriptor was extended.
		"NOTE_ATTRIB", -->		The file referenced by the descriptor had its attributes changed.
		"NOTE_LINK", -->		The link count on the file changed.
		"NOTE_RENAME", -->		The file referenced by the descriptor was renamed.
		"NOTE_REVOKE", -->		Access to the file was revoked via revoke(2) or the underlying fileystem was unmounted.
	"EVFILT_PROC",
		"NOTE_EXIT", -->		The process has exited.
        "NOTE_EXITSTATUS",--[[	The process has exited and its exit status is in filter specific data.
							  	Valid only on child processes and to be used along with NOTE_EXIT. ]]
		"NOTE_FORK", -->    	The process created a child process via fork(2) or similar call.
		"NOTE_EXEC", -->    	The process executed a new process via execve(2) or similar call.
		"NOTE_SIGNAL", -->  	The process was sent a signal. Status can be checked via waitpid(2) or similar call.
	"EVFILT_SIGNAL", 
	"EVFILT_MACHPORT", 
	"EVFILT_TIMER", 
		"NOTE_SECONDS", -->   	data is in seconds
		"NOTE_USECONDS", -->  	data is in microseconds
		"NOTE_NSECONDS", -->  	data is in nanoseconds
		"NOTE_ABSOLUTE", -->  	data is an absolute timeout
		"NOTE_CRITICAL", -->  	system makes a best effort to fire this timer as scheduled.
		"NOTE_BACKGROUND", -->	system has extra leeway to coalesce this timer.
		"NOTE_LEEWAY", -->    	ext[1] holds user-supplied slop in deadline for timer coalescing.
}, nil, [[
	#include <sys/event.h>
	#include <sys/time.h>
	#include <sys/socket.h>
	#include <netinet/in.h>
]])

local EVFILT_READ = ffi_state.defs.EVFILT_READ
local EVFILT_WRITE = ffi_state.defs.EVFILT_WRITE
local EVFILT_TIMER = ffi_state.defs.EVFILT_TIMER
local EVFILT_SIGNAL = ffi_state.defs.EVFILT_SIGNAL

local EV_ADD = ffi_state.defs.EV_ADD
local EV_ONESHOT = ffi_state.defs.EV_ONESHOT
local EV_CLEAR = ffi_state.defs.EV_CLEAR
local EV_DELETE = ffi_state.defs.EV_DELETE


---------------------------------------------------
-- ctype metatable definition
---------------------------------------------------
local poller_cdecl, poller_index, io_index, event_index = nil, {}, {}, {}

---------------------------------------------------
-- pulpo_io metatable definition
---------------------------------------------------
--[[
	struct kevent {
		uintptr_t ident;        /* このイベントの識別子 */
		short     filter;       /* イベントのフィルタ */
		u_short   flags;        /* kqueue のアクションフラグ */
		u_int     fflags;       /* フィルタフラグ値 */
		intptr_t  data;         /* フィルタデータ値 */
		void      *udata;       /* 不透明なユーザデータ識別子 */
	};
]]
function io_index.init(t, poller, fd, type, ctx)
	pulpo_assert(t.ev.flags == 0, 
		"already used event buffer:"..tonumber(t.ev.ident))
	t.ev.flags = bit.bor(EV_ADD, EV_CLEAR)
	t.ev.ident = fd
	t.ev.udata = ctx and ffi.cast('void *', ctx) or ffi.NULL
	t.kind = type
	t.rpoll = 0
	t.wpoll = 0
	t.p = poller
	event.add_io_events(t)
end
function io_index.initialized(t)
	return t.ev.flags ~= 0
end
function io_index.fin(t, reason)
	if t:initialized() then
	-- logger.info('io_index.fin:', t:fd(), t:type())
		t.ev.flags = 0
		event.destroy(t, reason)
		gc_handlers[t:type()](t)
	end
end
io_index.wait_read = event.wait_read
io_index.wait_write = event.wait_write
io_index.wait_emit = event.wait_emit
function io_index.read_yield(t)
	if t.rpoll == 0 then
		t.ev.filter = EVFILT_READ
		t:add_to(t.p)
		t.rpoll = 1
	end
end
function io_index.write_yield(t)
	if t.wpoll == 0 then
		t.ev.filter = EVFILT_WRITE
		t:add_to(t.p)
		t.wpoll = 1
	end
end
function io_index.deactivate_write(t)
	t.ev.filter = EVFILT_WRITE
	t:remove_from_poller(t)
	t.wpoll = 0
end
function io_index.reactivate_write(t)
	t.ev.flags = bit.bor(EV_ADD, EV_CLEAR)
	t:write_yield()
end
function io_index.emit_io(t, ev)
	if ev.filter == EVFILT_WRITE then
		event.emit_write(t)
	elseif ev.filter == EVFILT_READ then
		event.emit_read(t)
	elseif ev.filter == EVFILT_TIMER then
		t.ev.data = ev.data
		event.emit_read(t)
	end
end

function io_index.add_to(t, poller)
	pulpo_assert(bit.band(t.ev.flags, EV_ADD) ~= 0, "invalid event flag")
	local n = C.kevent(poller.kqfd, t.ev, 1, nil, 0, poller.timeout)
	-- print(poller.kqfd, n, t.ev.ident, t.ev.filter)
	if n ~= 0 then
		logger.error('kqueue event add error:'..ffi.errno().."\n"..debug.traceback())
		return false
	end
	return true
end
function io_index.remove_from_poller(t)
	t.ev.flags = EV_DELETE
	local n = C.kevent(t.p.kqfd, t.ev, 1, nil, 0, t.p.timeout)
	-- print(poller.kqfd, n, t.ident)
	if n ~= 0 then
		logger.error('kqueue event remove error:'..ffi.errno().."\n"..debug.traceback())
		return false
	end
end
function io_index.fd(t)
	return t.ev.ident
end
function io_index.type(t)
	return tonumber(t.kind)
end
function io_index.ctx(t, ct)
	return t.ev.udata ~= ffi.NULL and ffi.cast(ct, t.ev.udata) or nil
end


---------------------------------------------------
-- pulpo_poller metatable definition
---------------------------------------------------
function poller_index.init(t, maxfd)
	t.kqfd = C.kqueue()
	pulpo_assert(t.kqfd >= 0, "kqueue create fails:"..ffi.errno())
	-- print('kqfd:', tonumber(t.kqfd))
	t.maxfd = maxfd
	t.nevents = maxfd
	t.alive = true
	t:set_timeout(0.05) --> default 50ms
end
function poller_index.fin(t)
	C.close(t.kqfd)
end
local timer_event = ffi.new('struct kevent[1]')
timer_event[0].filter = EVFILT_TIMER
timer_event[0].flags = EV_ADD
function poller_index.add_timer(t, fd, start, intv)
	timer_event[0].ident = fd
	timer_event[0].data = (intv * 1000)
	local n = C.kevent(t.kqfd, timer_event, 1, nil, 0, t.timeout)
	if n ~= 0 then
		return false
	end
	return true
end
local signal_event = ffi.new('struct kevent[1]')
signal_event[0].filter = EVFILT_SIGNAL
signal_event[0].flags = EV_ADD
function poller_index.add_signal(t, fd, signo)
	timer_event[0].ident = fd
	timer_event[0].data = signo
	local n = C.kevent(t.kqfd, timer_event, 1, nil, 0, t.timeout)
	if n ~= 0 then
		return false
	end
	return true
end
function poller_index.set_timeout(t, sec)
	util.sec2timespec(sec, t.timeout)
end
function poller_index.wait(t)
	local n = C.kevent(t.kqfd, nil, 0, t.events, t.nevents, t.timeout)
	if n <= 0 then
		-- print('kqueue error:'..ffi.errno())
		return n
	end
	for i=0,n-1,1 do
		local ev = t.events + i
		local io = iolist + ev.ident
		io:emit_io(ev)
	end
end


---------------------------------------------------
-- main poller ctype definition
---------------------------------------------------
poller_cdecl = function (maxfd) 
	return ([[
		typedef int pulpo_fd_t;
		typedef struct kevent pulpo_event_t;
		typedef struct pulpo_poller {
			bool alive;
			pulpo_fd_t kqfd;
			pulpo_event_t events[%d];
			int nevents;
			struct timespec timeout[1];
			int maxfd;
		} pulpo_poller_t;
		typedef struct pulpo_io {
			pulpo_event_t ev;
			unsigned char kind, rpoll, wpoll, padd;
			pulpo_poller_t *p;
		} pulpo_io_t;
	]]):format(maxfd)
end

function _M.initialize(args)
	handlers = args.handlers
	gc_handlers = args.gc_handlers
	--> generate run time cdef
	ffi.cdef(poller_cdecl(args.poller.maxfd))
	ffi.metatype('pulpo_poller_t', { __index = util.merge_table(args.poller_index, poller_index) })
	ffi.metatype('pulpo_io_t', { __index = util.merge_table(args.io_index, io_index), __gc = io_index.fin })

	iolist = args.opts.iolist or memory.alloc_fill_typed('pulpo_io_t', args.poller.maxfd)
	return iolist
end

function _M.finalize()
	memory.free(iolist)
end

return _M


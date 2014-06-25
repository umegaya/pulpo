local loader = require 'pulpo.loader'
local ffi = require 'ffiex'
local util = require 'pulpo.util'
local memory = require 'pulpo.memory'

local _M = {}
local C = ffi.C
local udatalist, handlers, gc_handlers, iolist


---------------------------------------------------
-- import necessary cdefs
---------------------------------------------------
local ffi_state = loader.load("epoll.lua", {
	"enum EPOLL_EVENTS", "epoll_create", "epoll_wait", "epoll_ctl",
}, {
	"EPOLL_CTL_ADD", "EPOLL_CTL_MOD", "EPOLL_CTL_DEL",
	"EPOLLIN", "EPOLLOUT", "EPOLLRDHUP", "EPOLLPRI", "EPOLLERR", "EPOLLHUP",
	"EPOLLET", "EPOLLONESHOT"  
}, nil, [[
	#include <sys/epoll.h>
]])

local EPOLL_CTL_ADD = ffi_state.defs.EPOLL_CTL_ADD
local EPOLL_CTL_MOD = ffi_state.defs.EPOLL_CTL_MOD
local EPOLL_CTL_DEL = ffi_state.defs.EPOLL_CTL_DEL

local EPOLLIN = tonumber(ffi.cast('enum EPOLL_EVENTS', ffi_state.defs.EPOLLIN))
local EPOLLOUT = tonumber(ffi.cast('enum EPOLL_EVENTS', ffi_state.defs.EPOLLOUT))
local EPOLLRDHUP = tonumber(ffi.cast('enum EPOLL_EVENTS', ffi_state.defs.EPOLLRDHUP))
local EPOLLPRI = tonumber(ffi.cast('enum EPOLL_EVENTS', ffi_state.defs.EPOLLPRI))
local EPOLLERR = tonumber(ffi.cast('enum EPOLL_EVENTS', ffi_state.defs.EPOLLERR))
local EPOLLHUP = tonumber(ffi.cast('enum EPOLL_EVENTS', ffi_state.defs.EPOLLHUP))
local EPOLLONESHOT = tonumber(ffi.cast('enum EPOLL_EVENTS', ffi_state.defs.EPOLLONESHOT))



---------------------------------------------------
-- ctype metatable definition
---------------------------------------------------
local poller_cdecl, poller_index, io_index, event_index = nil, {}, {}, {}

---------------------------------------------------
-- pulpo_io metatable definition
---------------------------------------------------
--[[
typedef union epoll_data {
    void    *ptr;
    int      fd;
    uint32_t u32;
    uint64_t u64;
} epoll_data_t;
struct epoll_event {
    uint32_t     events;    /* epoll イベント */
    epoll_data_t data;      /* ユーザデータ変数 */
};
]]
function io_index.init(t, fd, type, ctx)
	assert(bit.band(t.ev.events, EPOLLERR) or t.ev.data.fd == 0, 
		"already used event buffer:"..tonumber(t.ev.data.fd))
	t.ev.events = bit.bor(EPOLLIN, EPOLLONESHOT)
	t.ev.data.fd = fd
	udatalist[tonumber(fd)] = ffi.cast('void *', ctx)
	t.kind = type
end
function io_index.fin(t)
	t.ev.events = EPOLLERR
	gc_handlers[t:type()](t)
end
function io_index.wait_read(t)
	t.ev.events = bit.bor(EPOLLIN, EPOLLONESHOT)
	-- print('wait_read', t:fd(), t.ev.events)
	local r = coroutine.yield(t)
	-- print('wait_read returns', t:fd())
	t.ev.events = r.events
end
function io_index.wait_write(t)
	t.ev.events = bit.bor(EPOLLOUT, EPOLLONESHOT)
	-- if log then print('wait_write', t:fd()) end
	local r = coroutine.yield(t)
	-- if log then print('wait_write returns', t:fd()) end
	t.ev.events = r.events
end
function io_index.add_to(t, poller)
	local n = C.epoll_ctl(poller.epfd, EPOLL_CTL_ADD, t:fd(), t.ev)
	if n ~= 0 then
		print('epoll event add error:'..ffi.errno().."\n"..debug.traceback())
		return false
	end
	return true
end
function io_index.activate(t, poller)
	local n = C.epoll_ctl(poller.epfd, EPOLL_CTL_MOD, t:fd(), t.ev)
	if n ~= 0 then
		print('epoll event mod error:'..ffi.errno().."\n"..debug.traceback())
		return false
	end
	return true
end
function io_index.remove_from(t, poller)
	local n = C.epoll_ctl(poller.epfd, EPOLL_CTL_DEL, t:fd(), t.ev)
	if n ~= 0 then
		print('epoll event remove error:'..ffi.errno().."\n"..debug.traceback())
		return false
	end
	gc_handlers[t:type()](t)
end
function io_index.fd(t)
	return t.ev.data.fd
end
function io_index.type(t)
	return tonumber(t.kind)
end
function io_index.ctx(t, ct)
	local pd = udatalist[tonumber(t.ev.data.fd)]
	return pd ~= ffi.NULL and ffi.cast(ct, pd) or nil
end


---------------------------------------------------
-- pulpo_poller metatable definition
---------------------------------------------------
function poller_index.init(t, maxfd)
	t.epfd = C.epoll_create(maxfd)
	assert(t.epfd >= 0, "epoll create fails:"..ffi.errno())
	print('epfd:', tonumber(t.epfd))
	t.maxfd = maxfd
	t.nevents = maxfd
	t.alive = true
	t:set_timeout(0.05) --> default 50ms
end
function poller_index.fin(t)
	C.close(t.epfd)
end
function poller_index.set_timeout(t, sec)
	t.timeout = sec * 1000 -- msec
end
function poller_index.wait(t)
	local n = C.epoll_wait(t.epfd, t.events, t.nevents, t.timeout)
	if n <= 0 then
		if n < 0 then print('epoll error:'..ffi.errno()) end
		return n
	end
	--if n > 0 then
	--	print('n = ', n)
	--end
	for i=0,n-1,1 do
		local ev = t.events + i
		local fd = tonumber(ev.data.fd)
		local co = assert(handlers[fd], "handler should exist for fd:"..tostring(fd))
		local ok, rev = pcall(co, ev)
		if ok then
			if rev then
				if rev:activate(t) then
					goto next
				end
			end
		else
			print('abort by error:', rev)
		end
		local io = iolist + fd
		io:fin()
		::next::
	end
end



---------------------------------------------------
-- main poller ctype definition
---------------------------------------------------
poller_cdecl = function (maxfd) 
	return ([[
		typedef int pulpo_fd_t;
		typedef struct epoll_event pulpo_event_t;
		typedef struct pulpo_io {
			pulpo_event_t ev;
			unsigned char kind, padd[3];
		} pulpo_io_t;
		typedef struct poller {
			bool alive;
			pulpo_fd_t epfd;
			pulpo_event_t events[%d];
			int nevents;
			int timeout;
			int maxfd;
		} pulpo_poller_t;
	]]):format(maxfd)
end

function _M.initialize(args)
	handlers = args.handlers
	gc_handlers = args.gc_handlers
	--> generate run time cdef
	ffi.cdef(poller_cdecl(args.poller.maxfd))
	ffi.metatype('pulpo_poller_t', { __index = util.merge_table(args.poller_index, poller_index) })
        ffi.metatype('pulpo_io_t', { __index = util.merge_table(args.io_index, io_index) })

	--> TODO : share it between threads (but thinking of cache coherence, may better seperated)
	udatalist = memory.alloc_fill_typed('void *', args.poller.maxfd)
	iolist = args.opts.iolist or memory.alloc_fill_typed('pulpo_io_t', args.poller.maxfd)
	return iolist
end

return _M

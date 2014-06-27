local loader = require 'pulpo.loader'
local ffi = require 'ffiex'
local util = require 'pulpo.util'
local memory = require 'pulpo.memory'
local errno = require 'pulpo.errno'
local event = require 'pulpo.event'

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
local EPOLLET = tonumber(ffi.cast('enum EPOLL_EVENTS', ffi_state.defs.EPOLLET))
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
	pulpo_assert(bit.band(t.ev.events, EPOLLERR) or t.ev.data.fd == 0, 
		"already used event buffer:"..tonumber(t.ev.data.fd))
	t.ev.events = bit.bor(EPOLLIN, EPOLLONESHOT)
	t.ev.data.fd = fd
	udatalist[tonumber(fd)] = ffi.cast('void *', ctx)
	t.kind = type
	t.rpoll = 0
	t.wpoll = 0
	event.create_read(t)
	event.create_write(t)
end
function io_index.fin(t)
	t.ev.events = EPOLLERR
	-- if we does not use dup(), no need to remove fd from epoll fd.
	-- so in pulpo, I don't use dup.
	-- if 3rdparty lib use dup(), please do it in gc_handler XD
	-- (just call t:remove_from_poller())
	gc_handlers[t:type()](t)
end
io_index.wait_read = event.wait_read
io_index.wait_write = event.wait_write
--[[
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
]]
function io_index.read_yield(t)
	if t.rpoll == 0 then
		t.ev.events = bit.bor(EPOLLIN, EPOLLET, t.wpoll ~= 0 and EPOLLOUT or 0)
		t:activate(t.p)
		t.rpoll = 1
	end
end
function io_index.write_yield(t)
	if t.wpoll == 0 then
		t.ev.events = bit.bor(EPOLLOUT, EPOLLET, t.rpoll ~= 0 and EPOLLIN or 0)
		t:activate(t.p)
		t.wpoll = 1
	end
end
function io_index.emit_io(t, ev)
	if bit.band(ev.events, EPOLLIN) then
		t.rpoll = 0
		event.emit_read(t)
	end
	if bit.band(ev.events, EPOLLOUT) then
		t.wpoll = 0
		event.emit_write(t)
	end
end
function io_index.add_to(t, poller)
	local n = C.epoll_ctl(poller.epfd, EPOLL_CTL_ADD, t:fd(), t.ev)
	if n ~= 0 then
		logger.error('epoll event add error:'..ffi.errno().."\n"..debug.traceback())
		return false
	end
	return true
end
function io_index.activate(t, poller)
	local n = C.epoll_ctl(poller.epfd, EPOLL_CTL_MOD, t:fd(), t.ev)
	if n ~= 0 then
		local eno = errno.errno()
		if eno ~= errno.ENOENT then
			logger.error('epoll event mod error:'..eno.."\n"..debug.traceback())
			return false
		else
			return t:add_to(poller)
		end
	end
	return true
end
function io_index.remove_from_poller(t)
	local n = C.epoll_ctl(t.poller.epfd, EPOLL_CTL_DEL, t:fd(), t.ev)
	if n ~= 0 then
		logger.error('epoll event remove error:'..ffi.errno().."\n"..debug.traceback())
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
	pulpo_assert(t.epfd >= 0, "epoll create fails:"..ffi.errno())
	logger.debug('epfd:', tonumber(t.epfd))
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
function poller_index._wait(t)
	local n = C.epoll_wait(t.epfd, t.events, t.nevents, t.timeout)
	if n <= 0 then
		-- print('epoll error:'..ffi.errno())
		return n
	end
	for i=0,n-1,1 do
		local ev = t.events + i
		local fd = tonumber(ev.data.fd)
		local co = pulpo_assert(handlers[fd], "handler should exist for fd:"..tostring(fd))
		local ok, rev = pcall(co, ev)
		if ok then
			if rev then
				if rev:activate(t) then
					goto next
				end
			end
		else
			logger.warning('abort by error:', rev)
		end
		local io = iolist + fd
		io:fin()
		::next::
	end
end
function poller_index.wait(t)
	local n = C.epoll_wait(t.epfd, t.events, t.nevents, t.timeout)
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
		typedef struct epoll_event pulpo_event_t;
		typedef struct pulpo_poller {
			bool alive;
			pulpo_fd_t epfd;
			pulpo_event_t events[%d];
			int nevents;
			int timeout;
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
	ffi.metatype('pulpo_io_t', { __index = util.merge_table(args.io_index, io_index) })

	--> TODO : share it between threads (but thinking of cache coherence, may better seperated)
	udatalist = memory.alloc_fill_typed('void *', args.poller.maxfd)
	iolist = args.opts.iolist or memory.alloc_fill_typed('pulpo_io_t', args.poller.maxfd)
	return iolist
end

return _M

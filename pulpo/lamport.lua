local ffi = require 'ffiex.init'
local util = require 'pulpo.util'
local memory = require 'pulpo.memory'
local _M = {}
local payload_map = {}
local function get_payload_map(crc)
	return payload_map[crc]
end
local function msec_timestamp()
	local s,us = util.clock_pair()
	return math.ceil(tonumber((s * 1000) + (us / 1000)))
end


ffi.cdef [[
typedef union pulpo_lamport_clock {
	struct pulpo_lamport_clock_layout {
		uint32_t walltime_lo;
		uint32_t walltime_hi:10, logical_clock:22;
	} layout;
	uint64_t value;
} pulpo_lamport_clock_t;
typedef struct pulpo_lamport_clock_generator {
	pulpo_lamport_clock_t clock;
} pulpo_lamport_clock_generator_t;
typedef struct pulpo_lamport_causal_relation_checker {
	pulpo_lamport_clock_t clock;
	pulpo_lamport_clock_t oldest;
	uint32_t bucket_size;
	pulpo_lamport_clock_t bucket_clock[0];
} pulpo_lamport_causal_relation_checker_t;
]]

-- lamport clock
local lamport_mt = {}
lamport_mt.__index = lamport_mt
function lamport_mt:init()
	self.value = 0
end
function lamport_mt:debug_init(msec_walltime, logical_clock)
	self:set_walltime(msec_walltime)
	self.layout.logical_clock = logical_clock
end
function lamport_mt:initialized()
	return self.value ~= 0
end
function lamport_mt:logical_clock()
	return self.layout.logical_clock
end
function lamport_mt:witness(lc, offset)
	local ts = msec_timestamp()
	if (lc:walltime() < ts) and (self:walltime() < ts) then
		self:set_walltime(ts)
		self.layout.logical_clock = 0
		return
	end

	if lc > self then
		if offset and (lc:walltime() - ts > offset) then
			logger.error('invalid clock', lc, lc:walltime(), ts)
			return
		end
		self:set_walltime(lc:walltime())
		self.layout.logical_clock = lc.layout.logical_clock + 1
	elseif lc < self then
		self.layout.logical_clock = self.layout.logical_clock + 1
	else
		if lc.layout.logical_clock > self.layout.logical_clock then
			self.layout.logical_clock = lc.layout.logical_clock
		end
		self.layout.logical_clock = self.layout.logical_clock + 1
	end
end
function lamport_mt:next()
	local ts = msec_timestamp()
	if self:walltime() >= ts then
		self.layout.logical_clock = self.layout.logical_clock + 1
	else
		self:set_walltime(ts)
		self.layout.logical_clock = 0
	end
end
function lamport_mt:set_walltime(wt)
	self.layout.walltime_hi = wt / 0x100000000
	self.layout.walltime_lo = bit.band(wt, 0xFFFFFFFF)
end
function lamport_mt:walltime()
	return (tonumber(self.layout.walltime_hi) * 0x100000000) + self.layout.walltime_lo
end
function lamport_mt:copy_to(to)
	to.value = self.value
end
function lamport_mt:__mod(n)
	return (self.layout.logical_clock + self.layout.walltime_lo) % n
end
function lamport_mt:__eq(lc)
	return lc.value == self.value
end
function lamport_mt:__le(lc)
	if self:walltime() < lc:walltime() then
		return true
	elseif self:walltime() > lc:walltime() then
		return false
	else
		return self.layout.logical_clock <= lc.layout.logical_clock
	end
end
function lamport_mt:__lt(lc)
	if self:walltime() < lc:walltime() then
		return true
	elseif self:walltime() > lc:walltime() then
		return false
	else
		return self.layout.logical_clock < lc.layout.logical_clock
	end
end
function lamport_mt:__tostring()
	return self:walltime()..":"..tonumber(self.layout.logical_clock)
end
ffi.metatype('pulpo_lamport_clock_t', lamport_mt)



-- lamport clock generator
local lamport_gen_mt = {}
lamport_gen_mt.__index = lamport_gen_mt
function lamport_gen_mt:init()
	self.clock:init()
end
function lamport_gen_mt:witness(lc)
	self.clock:witness(lc)
end
function lamport_gen_mt:now()
	return self.clock
end
local clock_work = ffi.new('pulpo_lamport_clock_t')
function lamport_gen_mt:issue()
	clock_work.value = self.clock.value
	self.clock:next()
	return clock_work
end
ffi.metatype('pulpo_lamport_clock_generator_t', lamport_gen_mt)



-- causal relation checker
-- which checks given payload with lamport clock is 'fresh' or not 
local causal_relation_checker_mt = util.copy_table(lamport_gen_mt)
causal_relation_checker_mt.__index = causal_relation_checker_mt
function causal_relation_checker_mt.alloc(size)
	local p = ffi.cast('pulpo_lamport_causal_relation_checker_t*', memory.alloc_fill(
		ffi.sizeof('pulpo_lamport_causal_relation_checker_t') + ffi.sizeof('pulpo_lamport_clock_t') * size
	))
	p:init(size)
	return p
end
function causal_relation_checker_mt:init(size)
	self.clock:init()
	self.oldest:init()
	self.bucket_size = size
end
local oldest_work = memory.alloc_typed('pulpo_lamport_clock_t')
function causal_relation_checker_mt:oldest_clock()
	oldest_work:init()
	for i=0,self.bucket_size-1 do
		local c = self.bucket_clock[i]
		-- print('oldest clock', c, oldest_work, i)
		if c:initialized() and ((not oldest_work:initialized()) or (c < oldest_work)) then
			c:copy_to(oldest_work)
		end
	end
	return oldest_work[0]
end
local bucket_clock_work = memory.alloc_typed('pulpo_lamport_clock_t')
function causal_relation_checker_mt:bucket_clock_at(idx)
	self.bucket_clock[idx]:copy_to(bucket_clock_work)
	return bucket_clock_work
end
causal_relation_checker_mt.issue_clock = causal_relation_checker_mt.issue
function causal_relation_checker_mt:fresh(lc, payload)
	self:witness(lc)
	if lc < self.oldest then
		return false
	else
		local idx = tonumber(lc % self.bucket_size)
		local prev_clock = self:bucket_clock_at(idx)
		local m = payload_map[self]
		-- print(idx, prev_clock, self.oldest, lc)
		if prev_clock == lc then
			if m[idx] then
				for _, p in ipairs(m[idx]) do
					if p == payload then
						return false
					end
				end
				table.insert(m[idx], payload)
			else
				m[idx] = {payload}
			end
		elseif prev_clock < lc then	
			self.bucket_clock[idx] = lc
			if prev_clock == self.oldest then
				self.oldest = self:oldest_clock()
			end
			m[idx] = {payload}
		else
			return false
		end
	end
	return true
end
ffi.metatype('pulpo_lamport_causal_relation_checker_t', causal_relation_checker_mt)



-- module functions
function _M.new(size, payload_gc)
	local crc = causal_relation_checker_mt.alloc(size)
	payload_map[crc] = { gc = payload_gc }
	return crc
end
function _M.new_clock()
	local p = memory.alloc_typed('pulpo_lamport_clock_generator_t')
	p:init()
	return p
end
function _M.destroy(crc)
	local m = payload_map[crc]
	payload_map[crc] = nil
	if m.gc then m:gc() end
	memory.free(crc)
end
function _M.debug_make_clock(clock, msec)
	local p = ffi.new('pulpo_lamport_clock_t')
	p:debug_init(msec or msec_timestamp(), clock)
	return p
end

return _M

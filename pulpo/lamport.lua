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
//hibrid logical clock which can trace physical time relationship.
//the concept is borrowed from cockroach db.
typedef union pulpo_hlc {
	struct pulpo_hlc_layout {
		uint32_t walltime_lo;
		uint32_t walltime_hi:10, logical_clock:22;
	} layout;
	uint64_t value;
	uint8_t p[0];
} pulpo_hlc_t;

typedef struct pulpo_hlc_generator {
	pulpo_hlc_t clock;
} pulpo_hlc_generator_t;

//purely logical lamport clock
typedef uint64_t pulpo_lamport_clock_t;

typedef struct pulpo_lamport_causality_checker {
	pulpo_lamport_clock_t clock;
	pulpo_lamport_clock_t oldest;
	uint32_t bucket_size;
	pulpo_lamport_clock_t bucket_clock[0];
} pulpo_lamport_causality_checker_t;
]]

_M.MAX_HLC_WALLTIME = (bit.lshift(1, 10) * 0x100000000) - 1

-- hibrid logical clock
local hlc_mt = {}
hlc_mt.__index = hlc_mt
function hlc_mt:init()
	self.value = 0
end
function hlc_mt:debug_init(msec_walltime, logical_clock)
	self:set_walltime(msec_walltime)
	self.layout.logical_clock = logical_clock
end
function hlc_mt:initialized()
	return self.value ~= 0
end
function hlc_mt:logical_clock()
	return self.layout.logical_clock
end
function hlc_mt:witness(lc, offset)
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
function hlc_mt:next()
	local ts = msec_timestamp()
	if self:walltime() >= ts then
		self.layout.logical_clock = self.layout.logical_clock + 1
	else
		self:set_walltime(ts)
		self.layout.logical_clock = 0
	end
	return self
end
function hlc_mt:set_walltime(wt)
	self.layout.walltime_hi = wt / 0x100000000
	self.layout.walltime_lo = bit.band(wt, 0xFFFFFFFF)
end
function hlc_mt:walltime()
	return (tonumber(self.layout.walltime_hi) * 0x100000000) + self.layout.walltime_lo
end
function hlc_mt:copy_to(to)
	to.value = self.value
end
function hlc_mt:add_walltime(sec)
	local wt = self:walltime()
	wt = wt + math.floor(sec * 1000)
	self:set_walltime(wt)
	return self
end
function hlc_mt:__mod(n)
	return (self.layout.logical_clock + self.layout.walltime_lo) % n
end
function hlc_mt:__eq(lc)
	return lc.value == self.value
end
function hlc_mt:__le(lc)
	if self:walltime() < lc:walltime() then
		return true
	elseif self:walltime() > lc:walltime() then
		return false
	else
		return self.layout.logical_clock <= lc.layout.logical_clock
	end
end
function hlc_mt:__lt(lc)
	if self:walltime() < lc:walltime() then
		return true
	elseif self:walltime() > lc:walltime() then
		return false
	else
		return self.layout.logical_clock < lc.layout.logical_clock
	end
end
function hlc_mt:__tostring()
	return self:walltime()..":"..tonumber(self.layout.logical_clock)
end

function hlc_mt:as_byte_string()
	return ffi.string(self.p, ffi.sizeof('pulpo_hlc_t'))
end
function hlc_mt:from_byte_string(str)
	ffi.copy(self.p, str, ffi.sizeof('pulpo_hlc_t'))
	return self
end
ffi.metatype('pulpo_hlc_t', hlc_mt)

-- hibrid logical clock generator
local hlc_gen_mt = {}
hlc_gen_mt.__index = hlc_gen_mt
function hlc_gen_mt:init()
	self.clock:init()
end
function hlc_gen_mt:witness(lc)
	self.clock:witness(lc)
end
function hlc_gen_mt:now()
	return self.clock
end
function hlc_gen_mt:issue()
	return self.clock:next()
end
ffi.metatype('pulpo_hlc_generator_t', hlc_gen_mt)



-- causal relation checker
-- which checks given payload with lamport clock is 'fresh' or not 
local causality_checker_mt = {}
causality_checker_mt.__index = causality_checker_mt
function causality_checker_mt.alloc(size)
	local p = ffi.cast('pulpo_lamport_causality_checker_t*', memory.alloc_fill(
		ffi.sizeof('pulpo_lamport_causality_checker_t') + ffi.sizeof('pulpo_lamport_clock_t') * size
	))
	p:init(size)
	return p
end
function causality_checker_mt:init(size)
	self.clock = 0
	self.oldest = 0
	self.bucket_size = size
end
function causality_checker_mt:witness(lc)
	if self.clock < lc then
		self.clock = lc + 1
	end
end
function causality_checker_mt:now()
	return self.clock
end
local clock_work = ffi.new('uint64_t')
function causality_checker_mt:issue()
	clock_work = self.clock
	self.clock = self.clock + 1
	return tonumber(clock_work) 
end
function causality_checker_mt:oldest_clock()
	local oldest = 0
	for i=0,self.bucket_size-1 do
		local c = self.bucket_clock[i]
		if (c > 0) and ((oldest == 0) or (c < oldest)) then
			oldest = c
		end
	end
	return oldest
end
causality_checker_mt.issue_clock = causality_checker_mt.issue
function causality_checker_mt:fresh(lc, payload)
	self:witness(lc)
	if lc < self.oldest then
		return false
	else
		local idx = tonumber(lc % self.bucket_size)
		local prev_clock = self.bucket_clock[idx]
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
ffi.metatype('pulpo_lamport_causality_checker_t', causality_checker_mt)



-- module functions
function _M.new(size, payload_gc)
	local cc = causality_checker_mt.alloc(size)
	payload_map[cc] = { gc = payload_gc }
	return cc
end
function _M.new_hlc()
	local p = memory.alloc_typed('pulpo_hlc_generator_t')
	p:init()
	return p
end
function _M.destroy(cc)
	local m = payload_map[cc]
	payload_map[cc] = nil
	if m.gc then m:gc() end
	memory.free(cc)
end
function _M.debug_make_hlc(clock, msec)
	local p = ffi.new('pulpo_hlc_t')
	p:debug_init(msec or msec_timestamp(), clock)
	return p
end
_M.ZERO_HLC = _M.debug_make_hlc(0, 0)

return _M

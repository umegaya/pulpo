local ffi = require 'ffiex.init'
local memory = require 'pulpo.memory'
local _M = {}
local payload_map = {}
local function get_payload_map(crc)
	return payload_map[crc]
end


ffi.cdef [[
typedef uint64_t pulpo_lamport_clock_t;
typedef struct pulpo_lamport_causal_relation_checker {
	pulpo_lamport_clock_t clock;
	pulpo_lamport_clock_t oldest;
	uint32_t bucket_size;
	pulpo_lamport_clock_t bucket_clock[0];
} pulpo_lamport_causal_relation_checker_t;
]]


-- causal relation checker
-- which checks given payload with lamport clock is 'fresh' or not 
local causal_relation_checker_mt = {}
causal_relation_checker_mt.__index = causal_relation_checker_mt
function causal_relation_checker_mt.alloc(size)
	local p = ffi.cast('pulpo_lamport_causal_relation_checker_t*', memory.alloc_fill(
		ffi.sizeof('pulpo_lamport_causal_relation_checker_t') + ffi.sizeof('pulpo_lamport_clock_t') * size
	))
	p:init(size)
	return p
end
function causal_relation_checker_mt:init(size)
	self.bucket_size = size
end
function causal_relation_checker_mt:witness(lc)
	if self.clock < lc then
		self.clock = lc + 1
	end
end
function causal_relation_checker_mt:now()
	return self.clock
end
local clock_work = ffi.new('uint64_t')
function causal_relation_checker_mt:issue_clock()
	clock_work = self.clock
	self.clock = self.clock + 1
	return tonumber(clock_work) 
end
function causal_relation_checker_mt:oldest_clock()
	local oldest = 0
	for i=0,self.bucket_size-1 do
		local c = self.bucket_clock[i]
		if (c > 0) and ((oldest == 0) or (c < oldest)) then
			oldest = c
		end
	end
	return oldest
end
function causal_relation_checker_mt:fresh(lc, payload)
	self:witness(lc)
	if lc < self.oldest then
		return false
	else
		local idx = lc % self.bucket_size
		local prev_clock = self.bucket_clock[idx] 
		local m = payload_map[self]
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
function _M.destroy(crc)
	local m = payload_map[crc]
	payload_map[crc] = nil
	if m.gc then m:gc() end
	memory.free(crc)
end

return _M

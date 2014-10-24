local pulpo = require 'pulpo.init'
local ffi = require 'ffiex.init'

local g = pulpo.evloop.clock.new(0.05, 10)

ffi.cdef [[
	typedef union num_reader {
		int n;
		char ptr[4];
	} num_reader_t;
]]

return {
	reader = function (ch, progress_ch)
		local num = ffi.new('num_reader_t')
		while true do
			local cnt = num.n
			local ptr,len = num.ptr,0
			while len < 4 do
				len = len + ch:read(ptr + len, 4 - len)
			end
			assert(num.n == (cnt + 1), "not sequencial")
			if num.n % 10000 == 0 then
				io.stdout:write(progress_ch); io.stdout:flush()
			end
			if num.n % 500000 == 0 then
				g:sleep(0.1)
			end
			if num.n >= 1000000 then
				break
			end
		end
		logger.info('reader end:', progress_ch)
	end,
	writer = function (ch, progress_ch)
		local cnt = 0
		local num = ffi.new('num_reader_t')
		while true do
			-- print('writer:', cnt, num)
			cnt = (cnt + 1)
			num.n = cnt
			local ptr,len = num.ptr,0
			while len < 4 do
				len = len + ch:write(ptr + len, 4 - len)
			end
			if num.n % 10000 == 0 then
				io.stdout:write(progress_ch); io.stdout:flush()
			end
			if num.n % 500000 == 0 then
				g:sleep(0.1)
			end
			if num.n >= 1000000 then
				break
			end
		end
		logger.info('writer end:', progress_ch)
	end
}
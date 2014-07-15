local ffi = require 'ffiex'
local waitq = {}

ffi.cdef [[
	struct hoge {
		int id;
		int cnt;
		int finish;
	};
]]
ffi.metatype('struct hoge', {
	__index = {
		init = function (t, id)
			t.id = id
			t.cnt = 0
			t.finish = 0
		end,
		yield = function (h)
			h.cnt = h.cnt + 1
			local co = coroutine.running()
			local id = tonumber(h.id)
			waitq[id] = co
			coroutine.yield()
			assert(waitq[id] == co)
			waitq[id] = nil
		end,
	}
})

local function task(h)
	while true do
		--print('task:', h.id, h.cnt)
		local n = math.random(1, 1000)
		--print(n, h.id, (1 + (h.id % 100)) == n)
		if (1 + (h.id % 1000)) == n then
			h.finish = 1
			io.stdout:write('c'); io.stdout:flush()
			break
		else
			--print(h.id, 'yield')
			h.cnt = h.cnt + 1
			h:yield()
		end
	end
end

local nhoge = 10000
local hlist = ffi.new('struct hoge['..nhoge..']')
for i=0,nhoge-1,1 do
	hlist[i]:init(i + 1)
	coroutine.wrap(task)(hlist[i])
end

local cnt = 0
while cnt < 10000 do
	--print('======================== start', #waitq)
	for i=0,nhoge-1,1 do
	--print('========================', waitq[i])
		if hlist[i].finish == 0 then
			coroutine.resume(waitq[i + 1])
		end
	end
	--print('end', cnt)
	cnt = cnt + 1
	if cnt % 1000 == 0 then
		io.stdout:write('l'); io.stdout:flush()
	end
end


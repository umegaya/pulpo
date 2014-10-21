local ffi = require 'ffiex.init'
local thread = require 'pulpo.thread'

local C = ffi.C
local _M = {}

---------------------------------------------------
-- dir submodule
---------------------------------------------------
-- module table
_M.dir = {}

-- metatype
local dir_idx = {}
function dir_idx.iter(t)
	return function (pulpo_dir_t)
		local ent = C.readdir(pulpo_dir_t)
		--print('data:', ent.d_name[0], ent.d_name[1], ent.d_name[2])
		if ent ~= ffi.NULL then
			return ffi.string(ent.d_name)
		else
			return nil
		end
	end, t.dir
end

-- module body
function _M.dir.open(path)
	local p = ffi.new('pulpo_dir_t')
	p.dir = C.opendir(path)
	assert(p.dir ~= ffi.NULL, "cannot open dir:"..ffi.string(path)) 
	return p
end

function _M.dir.create(path, readonly)
	local tmp
	local st = ffi.new('struct stat[1]')
	for name in path:gmatch('[^/]+') do
		if tmp then
			tmp = (tmp .. "/" ..name)
		elseif path[1] == '/' then
			tmp = ('/'..name)
		else
			tmp = name
		end
		if C.stat(tmp, st) == -1 then
			local mode = readonly and '0555' or '0777'
			C.mkdir(tmp, tonumber(mode, 8))
		end
	end
end

function _M.fileno(io)
	return C.fileno(io)
end

---------------------------------------------------
-- main module
---------------------------------------------------
thread.add_initializer(function (loader, shmem) 
	loader.load('fs.lua', { 
		"opendir", "readdir", "closedir", "DIR", "pulpo_dir_t",
		"stat", "mkdir", "struct stat", "fileno",
	}, {}, nil, [[
		#include <dirent.h>
		#include <sys/stat.h>
		#include <unistd.h>
		#include <stdio.h>
		typedef struct pulpo_dir {
			DIR *dir;
		} pulpo_dir_t;
	]])

	ffi.metatype('pulpo_dir_t', {
		__index = dir_idx,
		__gc = function (t)
			if t.dir ~= ffi.NULL then
				C.closedir(t.dir)
			end
		end
	})
end)

return _M
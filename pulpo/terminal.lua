local _M = {}
local output = io.write
_M.colors={ 
	black={30,40}, 
	red={31,41}, 
	green={32,42}, 
	yellow={33,43}, 
	blue={34,44}, 
	magenta={35,45}, 
	cyan={36,46}, 
	white={37,47} 
}

function _M.clear() output("\027[2J") end
function _M.cleareol() output("\027[K") end
function _M.goto(l,c) output("\027[",l,";",c,"H") end
function _M.up(n) output("\027[",n or 1,";","A") end
function _M.down(n) output("\027[",n or 1,";","B") end
function _M.right(n) output("\027[",n or 1,";","C") end
function _M.left(n) output("\027[",n or 1,";","D") end
function _M.color(f,b) output("\027[",f,";",b,"m") end
function _M.resetcolor() _M.color(0, 0) end
function _M.save() output("\027[s") end
function _M.restore() output("\027[u") end

function _M.colorRGB(r,g,b) 
	r = math.floor(r * 5 + 0.5) 
	g = math.floor(g * 5 + 0.5) 
	b = math.floor(b * 5 + 0.5) 
	local color = 16 + r * 36 + g * 6 + b 
	output("\027[48;5;",color,"m") 
end 

local fgwhite = _M.colors.white[1]
local bgblack = _M.colors.black[2]
for k,v in pairs(_M.colors) do
	-- foreground color function
	local f,b = unpack(_M.colors[k])
	_M[k] = function ()
		_M.color(f, bgblack)
	end
	_M["bg"..k] = function ()
		_M.color(fgwhite, b)
	end
end

return _M

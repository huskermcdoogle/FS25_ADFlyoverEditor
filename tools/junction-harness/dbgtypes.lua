-- What the tool reads each registry junction as, one line each, by the game's own numbers.
--   RIG_TRAILER=11 lua dbgtypes.lua <ADFlyoverEditor_junctions.xml> [numbers...]
-- Prints: n x z | type | through count, side count
-- Each junction is locked in a fresh copy of the network (the harness re-reads it), so one
-- junction's lock never leaks into the next.
local reg = arg[1]
local want = {}
for i = 2, #arg do want[tonumber(arg[i])] = true end
local f = assert(io.open(reg, "r"))
local txt = f:read("*a")
f:close()
local L = os.getenv("LUA") or "lua"
for n, x, z in txt:gmatch('n="(%d+)"%s+x="(%-?[%d.]+)"%s+z="(%-?[%d.]+)"') do
    n = tonumber(n)
    if next(want) == nil or want[n] then
        local p = io.popen(string.format('"%s" dbgtypes_one.lua %s %s 2>&1', L, x, z))
        local out = p:read("*a")
        p:close()
        local line = out:match("TYPE ([^\n]*)") or ("ERROR " .. (out:match("[^\n]*error[^\n]*") or "no result"))
        print(string.format("%d %.1f %.1f | %s", n, tonumber(x), tonumber(z), line))
        io.stdout:flush()
    end
end

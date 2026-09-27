-- Replay a capture exactly: its network, its settings, its lock point.
--   GRAPH=<converted pre.lua> lua dbgreplay_cap.lua <captureDir> <cx> <cz>
LOG_ECHO = true
local H = dofile("harness.lua")
local adopt = dofile("adoptmeta.lua")
local dir = arg[1]
local n, why = adopt(dir .. "/meta.txt")
print(string.format("-- adopted %d setting(s) from the capture%s", n, why and (" (" .. why .. ")") or ""))
local leave = false
for line in io.lines(dir .. "/meta.txt") do
    local v = line:match("^leave through paths%s+(%S+)")
    if v then leave = (v == "on") end
end
print("-- leave through paths: " .. tostring(leave))
LOG_ECHO = true
H.lock(tonumber(arg[2]), tonumber(arg[3]), { mode = "clear", radius = 12, leaveThrough = leave })
H.apply()

LOG_ECHO = true
local H = dofile("harness.lua")
local jp = H.lock(tonumber(arg[1]), tonumber(arg[2]), { mode="clear", radius=12, leaveThrough=(os.getenv("LEAVE") == "1") })
LOG_ECHO = true
H.apply()

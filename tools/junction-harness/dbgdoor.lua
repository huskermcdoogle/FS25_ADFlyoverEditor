-- THE DOOR ON A REAL JUNCTION CLEAR (multiplayer step 1): capture, clear (then build on the same spot),
-- describe what changed with GraphOps, and check the description plays forwards onto a copy of the
-- network before, and backwards onto a copy of the network after, to exactly the same networks.
--   lua dbgdoor.lua <x> <z>         (LEAVE=1 keeps through roads, as dbgstages.lua)
-- Prints one line: "door ok | <what changed>" or "door FAIL | <why>".
local H = dofile("harness.lua")
dofile("../../scripts/editor/GraphOps.lua")
local G = ADFlyoverGraphOps
local function graph()
    return { wayPoints = ADGraphManager:getWayPoints(), mapMarkers = ADGraphManager:getMapMarkers(),
             groups = ADGraphManager:getGroups() }
end
local x, z = tonumber(arg[1]), tonumber(arg[2])
local before = G.capture(graph())
local beforeCopy = G.copyGraph(graph())
H.lock(x, z, { mode = "clear", radius = 12, leaveThrough = (os.getenv("LEAVE") == "1") })
H.apply()
if os.getenv("DOOR_BUILD") == "1" then
    pcall(function()
        H.lock(x, z, { mode = "build", radius = 12 })
        H.build()
    end)
end
local a, why = G.diff(before, graph(), "junction")
if a == nil then
    print((why == "nothing changed" and "door ok | nothing changed") or ("door FAIL | " .. tostring(why)))
    return
end
local fwd = G.copyGraph(beforeCopy)
local ok, err = G.apply(fwd, a, false)
local same, d = false, err
if ok then same, d = G.same(fwd, graph()) end
if not same then print("door FAIL | forwards: " .. tostring(d) .. " | " .. G.describe(a)) return end
local back = G.copyGraph(graph())
ok, err = G.apply(back, a, true)
same, d = false, err
if ok then same, d = G.same(back, beforeCopy) end
if not same then print("door FAIL | backwards: " .. tostring(d) .. " | " .. G.describe(a)) return end
print("door ok | " .. G.describe(a))

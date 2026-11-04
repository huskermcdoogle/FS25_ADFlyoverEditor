-- SMOOTH REBUILD ON A LOOP, offline (2026-11-03, Welker Farms bug): the real editor on a made-up
-- network - a one-way loop of 16 points at the end of a two-lane road. The span is picked the way
-- traffic runs, the LONG way round from loop point 1 to loop point 11 (11 points). The short way
-- back (1, 16, 15 ... 11) is only 7 points.
--
-- Rebuild must replace only the picked span's inside points (2..10) and leave the other side of the
-- loop (12..16) exactly where it was. Before the fix it searched a fresh shortest path between the
-- ends and rebuilt 12..16 instead.
--   lua spanloop.lua           (from tools/junction-harness; no map data needed)
-- Prints PASS or FAIL lines and exits 1 on any FAIL.

local N, R = 16, 25
local graphFile = os.tmpname()
do
    local f = assert(io.open(graphFile, "w"))
    f:write("return {\n")
    for i = 1, N do
        -- A wobbly circle, so smoothing has something to move.
        local a = (i - 1) / N * 2 * math.pi
        local r = R + ((i % 2 == 0) and 1.5 or -1.5)
        f:write(string.format("  {id=%d,x=%.3f,y=0,z=%.3f,flags=0,out={%d}},\n",
            i, r * math.cos(a), r * math.sin(a), i % N + 1))
    end
    -- The road: in-lane 17 -> 18 -> 19 -> 1, out-lane 1 -> 20 -> 21.
    f:write(string.format("  {id=17,x=%.3f,y=0,z=-3,flags=0,out={18}},\n", R + 60))
    f:write(string.format("  {id=18,x=%.3f,y=0,z=-3,flags=0,out={19}},\n", R + 40))
    f:write(string.format("  {id=19,x=%.3f,y=0,z=-3,flags=0,out={1}},\n", R + 20))
    f:write(string.format("  {id=20,x=%.3f,y=0,z=3,flags=0,out={21}},\n", R + 20))
    f:write(string.format("  {id=21,x=%.3f,y=0,z=3,flags=0,out={}},\n", R + 40))
    f:write("}\n")
    f:close()
end

local realGetenv = os.getenv
os.getenv = function(k) if k == "GRAPH" then return graphFile end return realGetenv(k) end
dofile("harness.lua")
os.getenv = realGetenv
os.remove(graphFile)
local E = ADFlyoverEditor
E.smoothSpacing = 6
-- No map markers on this network (the harness has no stub for the lookup).
ADGraphManager.getMapMarkerByWayPointId = ADGraphManager.getMapMarkerByWayPointId or function() return nil end
-- Flat ground: the rebuilt points ask for a height.
getTerrainHeightAtWorldPos = function() return 0 end
-- No vehicles driving, so no removed point is held for one.
ADHeldRemovals = ADHeldRemovals or { pointsAhead = function() return {} end, hasMarker = function() return false end,
    hold = function() end }

local function key(w) return string.format("%.3f,%.3f", w.x, w.z) end
local before = {}
for i = 1, 21 do before[i] = key(ADGraphManager:getWayPointById(i)) end
local present = function()
    local s = {}
    for _, w in ipairs(ADGraphManager:getWayPoints()) do s[key(w)] = w end
    return s
end

-- The span as the pick stores it (spanIds): the route traffic runs, 1, 2, ... 11.
local span = {}
for i = 1, 11 do span[i] = i end
print(string.format("span picked: %d point(s), 1 -> 11 the long way; shortest path finder says %d point(s)",
    #span, #E:runPathBetween(1, 11)))

E:rebuildSpanInPieces(span)
for _, l in ipairs(LOG) do if l:find("rebuil") or l:find("FALLBACK") then print("  log: " .. l) end end

local now, fails = present(), 0
local function check(ok, what)
    print((ok and "PASS " or "FAIL ") .. what)
    if not ok then fails = fails + 1 end
end

local keptOther, movedPicked = 0, 0
for i = 12, 16 do if now[before[i]] then keptOther = keptOther + 1 end end
for i = 2, 10 do if not now[before[i]] then movedPicked = movedPicked + 1 end end
check(keptOther == 5, string.format("other side of the loop (12..16) untouched: %d of 5 still in place", keptOther))
check(movedPicked == 9, string.format("picked span's inside (2..10) rebuilt: %d of 9 replaced", movedPicked))
check(now[before[1]] ~= nil and now[before[11]] ~= nil, "both span ends kept")
local roadOk = true
for i = 17, 21 do if not now[before[i]] then roadOk = false end end
check(roadOk, "the road (17..21) untouched")

-- Still one closed one-way loop: follow out-links from point 1 and get back to it.
local start = now[before[1]]
local w, steps, closed, viaEnd = start, 0, false, false
repeat
    local nextId
    for _, id in ipairs(w.out or {}) do
        local o = ADGraphManager:getWayPointById(id)
        local onRoad = false
        for i = 17, 21 do if key(o) == before[i] then onRoad = true end end
        if not onRoad then nextId = id end
    end
    if nextId == nil then break end
    w = ADGraphManager:getWayPointById(nextId)
    if key(w) == before[11] then viaEnd = true end
    steps = steps + 1
    if w == start then closed = true end
until closed or steps > 200
check(closed and viaEnd, string.format("loop still closed and one-way (%d step(s) round, through point 11)", steps))

-- New points sit on the picked side: angle 0 .. 225 degrees from the loop's centre.
local onPicked, newCount = true, 0
for k, p in pairs(now) do
    local isOld = false
    for i = 1, 21 do if before[i] == k then isOld = true end end
    if not isOld then
        newCount = newCount + 1
        local a = math.deg(math.atan2(p.z, p.x)) % 360
        if a > 230 then onPicked = false end
    end
end
check(newCount > 0 and onPicked, string.format("all %d new point(s) lie on the picked side of the loop", newCount))

print(fails == 0 and "ALL PASS" or (fails .. " FAIL(S)"))
os.exit(fails == 0 and 0 or 1)

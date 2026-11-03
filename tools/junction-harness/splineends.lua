-- SPLINE ENDS JOIN THE ROAD, offline (2026-11-03): the real editor (Spline.lua included) on the
-- exported network, plus a made-up two-lane road end far from it. Each scenario draws a turn-around
-- loop with the multi-point spline the way the mouse does (cursor, hover pick, a frame, a click) and
-- right-clicks it, then checks which ends joined. Scenarios:
--   normal  - normal zoom: start 0.9 m off lane end A, end 0.9 m off lane end B (past the tight snap)
--   hover   - zoomed out (screen 160 m tall, the 2.5% pick reach is 4 m): the last click near B is
--             also within the start point's pick reach - the trap that used to swallow it
--   insert  - the same, but the last click is nearer the curve leaving the start than the start
--   alt     - the last click with Alt held: the end stays loose
--   self    - the last click 1 m from the START's lane end only: never snaps onto its own start
--   middle  - a middle click 1 m from a stray waypoint stays loose (the middle keeps the tight snap)
--   lua splineends.lua              (from tools/junction-harness)
-- START_ON_A=1 puts the first click right on A (to compare only the last end with the old code).
-- SPLINE_SRC=<file> loads that Spline.lua over the working tree's (e.g. main's, to see the old misses).
local H = dofile("harness.lua")
local E = ADFlyoverEditor
if os.getenv("SPLINE_SRC") ~= nil and os.getenv("SPLINE_SRC") ~= "" then dofile(os.getenv("SPLINE_SRC")) end
g_server = g_server or {}
local realGet = ADFlyoverSettings.get
ADFlyoverSettings.get = function(name)
    if name == "splineSpacing" then return 3 end
    if name == "splineMode" then return "multi" end
    return realGet(name)
end
E.warnPlayer = function(_, m) print("  [warning box] " .. tostring(m)) end
E.resolveHeightAt = function() return 100 end
E.getConnectionOptions = function() return false, false, AutoDrive.FLAG_NONE end
E.leftDown, E.leftAltHeld = false, false

-- a screen: nil = no project (ground fallback); else a top-down view `H` metres tall around (cx, cz)
local view = nil
local function setView(v)
    view = v
    if v == nil then
        project, g_lastMousePosX, g_lastMousePosY = nil, nil, nil
        return
    end
    project = function(x, y, z) return 0.5 + (x - v.cx) / v.H, 0.5 + (z - v.cz) / v.H, 1 end
end

local function frame(x, z)
    E.cursorX, E.cursorY, E.cursorZ = x, 100, z
    if view ~= nil then g_lastMousePosX, g_lastMousePosY = project(x, 100, z) end
    E.hoverId = E:findWayPointNearCursor()
    E:updateMultiSpline()
end
local function click(x, z, alt)
    E.leftAltHeld = alt or false
    frame(x, z)
    E:multiSplinePress()
    E:multiSplineRelease()
    E.leftAltHeld = false
end

-- a two-lane road end at (ox, 0): lane in (toward the end, -z) at x = ox - 1.85 ends at A; lane out
-- starts at B (x = ox + 1.85). A and B are 3.7 m apart, as waypoints 2648 / 2649 in the game.
local function road(ox)
    local function lane(x, inbound)
        local prev = nil
        local ids = {}
        for k = 0, 5 do
            local z = inbound and (15 - 3 * k) or (3 * k)
            local w = ADGraphManager:recordWayPoint(x, 100, z, false, false, false, 0, 0)
            if prev ~= nil then
                table.insert(prev.out, w.id)
                table.insert(w.incoming, prev.id)
            end
            prev = w
            ids[#ids + 1] = w
        end
        return ids
    end
    local inL, outL = lane(ox - 1.85, true), lane(ox + 1.85, false)
    return inL[#inL], outL[1]        -- A (end of the lane in), B (start of the lane out)
end

local results = {}

-- screen helpers for picking click spots (the old code's own tests, done here independently)
local function sd(x, z, w)
    local ax, ay = project(x, 100, z)
    local bx, by = project(w.x, 100, w.z)
    return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
end
--- a spot near B where `pred(x, z)` holds and no waypoint is in the tight snap; nil if none on the grid
local function spot(B, pred)
    for r = 0.2, 6, 0.1 do
        for a = 0, 359, 5 do
            local x, z = B.x + r * math.cos(math.rad(a)), B.z + r * math.sin(math.rad(a))
            E.cursorX, E.cursorY, E.cursorZ = x, 100, z
            g_lastMousePosX, g_lastMousePosY = project(x, 100, z)
            E.hoverId = E:findWayPointNearCursor()
            if E:splineSnapCandidate() == nil and pred(x, z) then return x, z end
        end
    end
end

-- the loop: off A (x=-1.85) away from the road (-z), round, back toward B (x=+1.85)
local loop = { { -4.5, -5 }, { -6, -12 }, { 0, -17 }, { 6, -12 }, { 4.5, -5 } }
local TIGHT, PICK, WIDE = AutoDrive.FLYOVER_SPLINE_SNAP_SCREEN_RADIUS, AutoDrive.FLYOVER_PICK_SCREEN_RADIUS,
    AutoDrive.FLYOVER_SPLINE_END_SNAP_SCREEN_RADIUS or 0.025

--- One scenario. `endAt(A, B, ox)` returns the last click (absolute x, z), or nil to skip it.
local function run(name, k, H, startRel, mid, endAt, alt, want, wantLog)
    local ox = 9000 + 200 * k
    local A, B = road(ox)
    local stray = ADGraphManager:recordWayPoint(ox + 9.0, 100, -12, false, false, false, 0, 0)
    E:cancelMultiSpline()
    setView({ H = H, cx = ox, cz = -6 })
    local mark = #LOG + 1
    -- START_ON_A=1: the first click right on A (so the old code's start joins too, and only the
    -- last end differs)
    if os.getenv("START_ON_A") == "1" then click(A.x, A.z) else click(ox + startRel[1], startRel[2]) end
    for _, p in ipairs(mid) do click(ox + p[1], p[2]) end
    local ex, ez = endAt(A, B, ox)
    local note = ""
    if ex == nil then
        note = " (no click spot found)"
    else
        note = string.format(" (last click %.2f m off B, %.2f m off A)", math.sqrt((ex - B.x) ^ 2 + (ez - B.z) ^ 2),
            math.sqrt((ex - A.x) ^ 2 + (ez - A.z) ^ 2))
        click(ex, ez, alt)
    end
    E:commitMultiSpline()
    setView(nil)
    local lines = {}
    for i = mark, #LOG do lines[#lines + 1] = LOG[i] end
    local placed = nil
    for _, l in ipairs(lines) do if l:find("placed multi%-point spline") then placed = l end end
    local joined = placed == nil and "NOT PLACED" or (placed:match("%(joined ([^)]+)%)") or "none")
    local strayLinked = #stray.out + #stray.incoming > 0
    -- the joined end must be B itself (or, joining the start only, a new point)
    local toId = placed ~= nil and tonumber(placed:match("%-> id=(%d+)")) or nil
    local endRight = (want == "both ends") == (toId == B.id)
    -- every click made a point: none swallowed by the start, none dropped
    local clicks = 1 + #mid + (ex ~= nil and 1 or 0)
    local nPts = placed ~= nil and tonumber(placed:match("from (%d+) clicked")) or nil
    local allIn = nPts == clicks
    local logged = wantLog == nil
    for _, l in ipairs(lines) do if wantLog ~= nil and l:find(wantLog) then logged = true end end
    local ok = joined == want and not strayLinked and ex ~= nil and endRight and logged and allIn
    print(string.format("%-7s H=%3d m  joined %-10s (want %-10s)%s%s  %s", name, H, joined, want,
        (strayLinked and " STRAY JOINED" or "") .. (endRight and "" or " WRONG END") .. (logged and "" or " NO LOG LINE") .. (allIn and "" or string.format(" %s OF %d CLICKS MADE POINTS", tostring(nPts), clicks)), note, ok and "ok" or "FAIL"))
    for _, l in ipairs(lines) do
        if l:find("snapped") or l:find("placed") or l:find("spline point") or l:find("went on the end") then print("        " .. l) end
    end
    print(string.format("        A=%d B=%d", A.id, B.id))
    results[#results + 1] = ok
end

-- normal zoom (screen 60 m tall: tight 0.6 m, wide 1.5 m): both clicks 0.9 m off their lane ends
local s09 = { -1.85 - 0.64, -0.64 }
run("normal", 0, 60, s09, loop, function(A, B) return B.x + 0.64, B.z - 0.64 end, false, "both ends")
-- zoomed out (160 m: tight 1.6 m, pick and wide 4 m): the start 2 m off A; the last click past the
-- tight snap of B but inside the start point's pick reach and nearer B than A - it used to grab the start
run("hover", 1, 160, { -1.85 - 1.4, -1.4 }, loop, function(A, B)
    return spot(B, function(x, z)
        local dB, dA = sd(x, z, B), sd(x, z, A)
        return dB > TIGHT * 1.05 and dB < WIDE * 0.95 and dA < PICK * 0.95 and dB < dA * 0.8
    end)
end, false, "both ends", "went on the end")
-- zoomed out, the loop starting toward B: the last click is outside the start point's pick reach but
-- inside that of the curve leaving the start (piece 1), and nearer B than the curve - it used to go
-- into the line
run("insert", 2, 160, { -1.85 - 1.4, -1.4 }, { { 2.5, -9 }, { -2, -15 }, { -8, -9 } }, function(A, B)
    return spot(B, function(x, z)
        local dB, dA = sd(x, z, B), sd(x, z, A)
        if not (dB > TIGHT * 1.05 and dB < WIDE * 0.95 and dA > PICK * 1.05) then return false end
        local seg, _, px, pz = ADSplinePath.nearestPiece(E.splineCurve, x, z)
        local dC = sd(x, z, { x = px, z = pz })
        return seg == 1 and dC < PICK * 0.95 and dB < dC * 0.8
    end)
end, false, "both ends", "went on the end")
-- Alt held on the last click (0.9 m off B, normal zoom): the end stays loose
run("alt", 3, 60, s09, loop, function(A, B) return B.x + 0.64, B.z - 0.64 end, true, "start", "not snapped %(Alt held%)")
-- zoomed in (40 m: tight 0.4 m, pick 1 m, wide 1.5 m): the last click 1.3 m off the START's lane end
-- only - outside the start point's pick reach, inside the ends' reach: never snaps onto its own start
run("self", 4, 40, s09, loop, function(A, B) return A.x - 0.92, A.z - 0.92 end, false, "start")
-- (the trap line must NOT come for a plain loop: checked on "normal" below)
-- a middle click 1 m from a stray waypoint (normal zoom) stays loose: the middle keeps the tight snap
run("middle", 5, 60, s09, { { -4.5, -5 }, { -6, -12 }, { 0, -17 }, { 8.3, -12.7 }, { 4.5, -5 } },
    function(A, B) return B.x + 0.64, B.z - 0.64 end, false, "both ends")

local bad = 0
for _, r in ipairs(results) do if not r then bad = bad + 1 end end
print(bad == 0 and "SPLINE ENDS PASS" or string.format("SPLINE ENDS FAIL (%d of %d)", bad, #results))

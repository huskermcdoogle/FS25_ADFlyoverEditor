-- Offline drive of the road runs TOOL (RoadRunsTool.lua) on the real map ground and network, with
-- stand-ins for AutoDrive's graph manager, the drawing manager and the HUD kit. Catches runtime errors
-- in the tool's paths (window reading, hover, click, double-click, card, draw, build, joins) without
-- the game.
--
--   lua tooltest.lua <x> <z> [clickX clickZ]...      (default: a built-in set of Riverbend spots)
--
-- Same data as bench.lua (TERRAIN_DIR / GRAPH / JH).
local HERE = (arg[0]:match("^(.*)[/\\]") or ".") .. "/"
local JH = os.getenv("JH") or (HERE .. "../../../junction-rework-fec884/tools/junction-harness/")
if os.getenv("TERRAIN_DIR") == nil then
    local real = os.getenv
    os.getenv = function(k) if k == "TERRAIN_DIR" then return JH .. "terrain_data/" end return real(k) end
end

g_currentMission = { terrainRootNode = 1 }
AutoDrive = { FLAG_NONE = 0, FLAG_SUBPRIO = 1, FLYOVER_DRAW_RADIUS = 200 }
CollisionFlag = {}
Logging = {
    info = function(f, ...) print("[info] " .. string.format(f, ...)) end,
    warning = function(f, ...) print("[warn] " .. string.format(f, ...)) end,
    error = function(f, ...) print("[ERROR] " .. string.format(f, ...)) end,
}
ADFlyoverSettings = { debugLog = function(f, ...) print("[log] " .. string.format(f, ...)) end }
dofile(HERE .. "terrain.lua")

-- ---------------------------------------------------------------- AutoDrive graph stand-in
local wps = dofile(os.getenv("GRAPH") or (JH .. "graph_data.lua"))
local byId = {}
for _, w in ipairs(wps) do
    byId[w.id] = w
    w.incoming = w.incoming or {}
end
for _, w in ipairs(wps) do
    for _, o in ipairs(w.out or {}) do
        local b = byId[o]
        if b ~= nil then b.incoming[#b.incoming + 1] = w.id end
    end
end
local count = #wps
local function link(a, b)
    a.out = a.out or {}
    a.out[#a.out + 1] = b.id
    b.incoming = b.incoming or {}
    b.incoming[#b.incoming + 1] = a.id
end
ADGraphManager = {
    getWayPoints = function() return byId end,
    getWayPointById = function(_, id) return byId[id] end,
    getWayPointsCount = function() return count end,
    markChanges = function() end,
    recordWayPoint = function(_, x, y, z, connectPrev, dual, reverse, prevId, flags)
        count = count + 1
        local w = { id = count, x = x, y = y, z = z, out = {}, incoming = {}, flags = flags }
        byId[count] = w
        if connectPrev and prevId ~= 0 and byId[prevId] ~= nil then
            link(byId[prevId], w)
            if dual then link(w, byId[prevId]) end
        end
        return w
    end,
    toggleConnectionBetween = function(_, a, b, reverse, dual)
        link(a, b)
        if dual then link(b, a) end
    end,
}
local snapshots = 0
ADEditorHistory = { snapshot = function() snapshots = snapshots + 1 end, depth = function() return snapshots end }
local lines, spheres = 0, 0
ADDrawingManager = {
    addLineTask = function(_, ...) lines = lines + 1 end,
    addSphereTask = function(_, ...) spheres = spheres + 1 end,
}

-- ---------------------------------------------------------------- the editor stand-in
local now = 0
ADFlyoverEditor = {
    TOOL = { NONE = 0 }, TOOL_NAMES = {}, DOUBLE_CLICK_MS = 350,
    nowMs = function() return now end,
    invalidateIdReferences = function() end,
    warnPlayer = function(_, m) print("[warning box] " .. m) end,
}
function ADFlyoverEditor:createRunFrom(points, dual, flags)
    local first, prev = nil, nil
    for _, p in ipairs(points) do
        local w = ADGraphManager:recordWayPoint(p.x, p.y or 0, p.z, prev ~= nil, dual, false, prev or 0, flags)
        prev = w.id
        first = first or prev
    end
    return first, prev
end

dofile(HERE .. "../../scripts/editor/RoadFinder.lua")
dofile(HERE .. "../../scripts/editor/RoadRunsTool.lua")
local E = ADFlyoverEditor
E.ROADRUNS_SAMPLES_PER_FRAME = 50000

local function frames(n)
    for _ = 1, n do
        now = now + 16
        E:updateRoadRuns(false)
        lines, spheres = 0, 0
        E:drawRoadRuns(2)
    end
end
local function settle(x, z)
    E.cursorX, E.cursorZ = x, z
    local guard = 0
    local b0 = (E.roadRuns ~= nil and E.roadRuns.builds) or 0
    repeat
        frames(1)
        guard = guard + 1
    until ((E.roadRuns.builds or 0) > b0) or guard > 5000
    frames(1)
    return guard
end

local function card()
    local rows = {}
    local kit = {
        tgl = function(t) rows[#rows + 1] = "tgl " .. t end,
        seg = function(c, o) local l = {} for _, x in ipairs(o) do l[#l + 1] = (x.active and "*" or "") .. x.label end rows[#rows + 1] = c .. ": " .. table.concat(l, " | ") end,
        segFlip = function(c, a, b, isB) rows[#rows + 1] = c .. ": " .. (isB and (a .. " | *" .. b) or ("*" .. a .. " | " .. b)) end,
        btn = function(t) rows[#rows + 1] = "[" .. t .. "]" end,
        add = function(k, a, b) rows[#rows + 1] = k .. " " .. tostring(a) .. (b and (" = " .. tostring(b)) or "") end,
        numberAfter = function(l)
            for _, e in ipairs(E:roadRunsNumbers(function(label, unit, dec, key) return { label = label, get = function() return E[key] end } end)) do
                if e.label == l then rows[#rows + 1] = "number " .. l .. " = " .. tostring(e.get()) end
            end
        end,
    }
    E:roadRunsCard(kit)
    return rows
end

local spots = {}
if #arg >= 2 then
    for i = 1, #arg - 1, 2 do spots[#spots + 1] = { tonumber(arg[i]), tonumber(arg[i + 1]) } end
end
local cx, cz = tonumber(arg[1] or "600"), tonumber(arg[2] or "-600")
local t0 = os.clock()
local f = settle(cx, cz)
local s = E.roadRuns
print(string.format("window ready after %d frames (%.2fs): %d stretches", f, os.clock() - t0, #s.stretches))

-- hover and click the three longest stretches near the middle; double-click the longest
table.sort(s.stretches, function(a, b) return a.len > b.len end)
local targets = {}
for _, st in ipairs(s.stretches) do
    local mid = st.pts[math.floor(#st.pts / 2) + 1]
    if math.abs(mid.x - cx) < 120 and math.abs(mid.z - cz) < 120 then targets[#targets + 1] = st end
    if #targets >= 3 then break end
end
for k, st in ipairs(targets) do
    local mid = st.pts[math.floor(#st.pts / 2) + 1]
    E.cursorX, E.cursorZ = mid.x + 1, mid.z + 1
    frames(1)
    print(string.format("hover %d: %s, %s %.0f m, %.1f m wide, %s..%s; draw %d lines %d spheres",
        k, s.hover and "found" or "NOTHING", RF and "" or (ADRoadFinder.KIND_NAMES[st.kind] or "?"), st.len, st.width or -1,
        st.startTag, st.endTag, lines, spheres))
    E:roadRunsClick()
    now = now + 1000
    frames(1)
    if k == 1 then
        -- double-click: click again within the window
        now = now - 990
        E:roadRunsClick()
        now = now + 1000
        frames(1)
    end
end
print("picks: " .. #s.picks)
for _, r in ipairs(card()) do print("  card | " .. r) end
print("next step: " .. E:roadRunsNextStep())
local before = count
E.roadMode = 1
local ok, err = pcall(function() return E:commitRoadRuns() end)
print(string.format("commit %s: %d new points, %d undo snapshot(s)%s", ok and "ok" or "FAILED", count - before, snapshots, ok and "" or (" - " .. tostring(err))))
-- the built lanes should now cover those roads
frames(2)
print(string.format("after build: %d stretches left with no path", #s.stretches))
-- every lane point joined in a chain; count joins into older points
local joins = 0
for id = before + 1, count do
    local w = byId[id]
    for _, o in ipairs(w.out) do if o <= before then joins = joins + 1 end end
    for _, i in ipairs(w.incoming) do if i <= before then joins = joins + 1 end end
end
print("links between new and old points: " .. joins)
-- a second window: move away and back
local t1 = os.clock()
settle(cx + 300, cz)
print(string.format("moved 300 m east: %d stretches (%.2fs)", #s.stretches, os.clock() - t1))
-- kinds toggle forces a re-read
E:roadRunsToggleKind(ADRoadFinder.KIND_DIRT)
settle(cx + 300, cz)
print(string.format("dirt off: %d stretches", #s.stretches))

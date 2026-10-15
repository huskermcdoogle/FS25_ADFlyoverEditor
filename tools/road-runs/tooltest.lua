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

if os.getenv("NOCO") then coroutine = nil end   -- as in FS25: no coroutine library
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

local lines, spheres, nans = 0, 0, 0
local function chk(...)
    for _, v in ipairs({ ... }) do if type(v) == "number" and v ~= v then nans = nans + 1 end end
end
-- ---------------------------------------------------------------- AutoDrive graph stand-in
-- SYNTH=bridge: an empty network on a made-up 5 m bridge (see bridgetest.lua) instead of the map
local SYNTH = os.getenv("SYNTH")
local wps = SYNTH and {} or dofile(os.getenv("GRAPH") or (JH .. "graph_data.lua"))
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
        chk(x, y, z)
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
ADDrawingManager = {
    addLineTask = function(_, ...) chk(...) lines = lines + 1 end,
    addSphereTask = function(_, ...) chk(...) spheres = spheres + 1 end,
}

-- ---------------------------------------------------------------- the editor stand-in
local now = 0
ADFlyoverEditor = {
    TOOL = { NONE = 0 }, TOOL_NAMES = {}, DOUBLE_CLICK_MS = 350,
    nowMs = function() return now end,
    invalidateIdReferences = function() end,
    warnPlayer = function(_, m) print("[warning box] " .. m) end,
}
-- the editor's insertOnSegment (FlyoverEditor.lua), for the road runs T-join
function ADFlyoverEditor:insertOnSegment(aId, bId, pos, dual, flags)
    local a, b = ADGraphManager:getWayPointById(aId), ADGraphManager:getWayPointById(bId)
    if a == nil or b == nil then return nil end
    local function unlink(p, q)
        for i = #(p.out or {}), 1, -1 do if p.out[i] == q.id then table.remove(p.out, i) end end
        for i = #(q.incoming or {}), 1, -1 do if q.incoming[i] == p.id then table.remove(q.incoming, i) end end
    end
    unlink(a, b)
    if dual then unlink(b, a) end
    local w = ADGraphManager:recordWayPoint(pos.x, 0, pos.z, false, false, false, 0, flags)
    ADGraphManager:toggleConnectionBetween(a, w, false, dual)
    ADGraphManager:toggleConnectionBetween(w, b, false, dual)
    teeJoins = (teeJoins or 0) + 1
    return w.id
end

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
dofile(HERE .. "../../scripts/editor/SplinePath.lua")
dofile(HERE .. "../../scripts/editor/RoadRunsTool.lua")
local E = ADFlyoverEditor
if DBGFILE then dofile(DBGFILE) end
-- SPLINES=<roadSplines.xml> (FlyoverRoadSplines dump): the map's road splines, as in game
if os.getenv("SPLINES") then
    local f = assert(io.open(os.getenv("SPLINES"), "rb")); local xml = f:read("*a"); f:close()
    local list = {}
    for name, len, pts in xml:gmatch('<spline name="([^"]*)" length="([^"]*)" points="([^"]*)"') do
        local P = {}
        for x, z in pts:gmatch("(-?[%d%.]+),(-?[%d%.]+)") do P[#P + 1] = { x = tonumber(x), z = tonumber(z) } end
        list[#list + 1] = { name = name, group = "", len = tonumber(len), pts = P }
    end
    E.roadRunsSplineOverride = ADRoadFinder.indexSplines(list)
    print(string.format("splines: %d read, %d centre lines", #list, #E.roadRunsSplineOverride.centre))
end
if SYNTH == "bridge" then
    local RF = ADRoadFinder
    local deckHalf = tonumber(os.getenv("DECK_HALF") or "2.5")
    RF.groundKindAt = function(x, z)
        if math.abs(z) <= 3.5 and math.abs(x) >= 30 and math.abs(x) <= 150 then return RF.KIND_PAVED end
        return RF.KIND_NONE
    end
    RF.roadMeshAt = function(x, z)
        if math.abs(z) <= deckHalf then
            if math.abs(x) <= 30 then return 6, true end
            if math.abs(x) <= 35 then return 0.2, false end
        end
        return nil
    end
    function E:roadRunsClearance(p, rx, rz)
        local function room(sx)
            for d = 0.5, 6, 0.5 do
                local z = p.z + sx * rz * d
                if math.abs(p.x) <= 30 and math.abs(z) >= deckHalf - 0.2 then return d - 0.5 end
            end
            return nil
        end
        return room(-1), room(1)
    end
end
E.ROADRUNS_SAMPLES_PER_FRAME = 50000
if os.getenv("VIEW") then E.roadView = true end   -- VIEW=1: the detection view instead of the lane preview

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
-- AT=x,z: hover and pick exactly there instead (one target)
if os.getenv("AT") then
    local ax, az = os.getenv("AT"):match("(-?[%d%.]+),(-?[%d%.]+)")
    targets = { { pts = { { x = tonumber(ax) - 1, z = tonumber(az) - 1 } }, len = 0, startTag = "-", endTag = "-" } }
end
for k, st in ipairs(targets) do
    local mid = st.pts[math.floor(#st.pts / 2) + 1]
    E.cursorX, E.cursorZ = mid.x + 1, mid.z + 1
    local h0 = os.clock()
    frames(1)
    print(string.format("hover %d: %s, %s %.0f m, %.1f m wide, %s..%s; draw %d lines %d spheres; frame %.0f ms",
        k, s.hover and "found" or "NOTHING", RF and "" or (ADRoadFinder.KIND_NAMES[st.kind] or "?"), st.len, st.width or -1,
        st.startTag, st.endTag, lines, spheres, (os.clock() - h0) * 1000))
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
-- shaping the selected run with its handles: drag one, add one on the line, ctrl-remove one
do
    local sel = s.sel
    if sel == nil and #s.picks > 0 then E:roadRunsSelect(s.picks[#s.picks]) sel = s.sel end
    if sel ~= nil then
        local H = sel.handles
        local n0, len0 = #H, sel.st.len or 0
        local k = math.max(1, math.floor((#H + 1) / 2))
        if k == 1 and #H > 2 then k = 2 end
        local h = H[k]
        -- press on it, move 3 m sideways past the drag threshold, release
        E.cursorX, E.cursorZ, E.mouseX, E.mouseY = h.x, h.z, 0, 0
        E.leftDown = true
        local took = E:roadRunsPress()
        E.mouseX = 0.1
        local P = sel.st.pts
        local i = math.max(2, math.floor(#P / 2))
        local nx, nz = -(P[i].z - P[i - 1].z), P[i].x - P[i - 1].x
        local nl = math.sqrt(nx * nx + nz * nz)
        E.cursorX, E.cursorZ = h.x + 3 * nx / nl, h.z + 3 * nz / nl
        frames(1)
        E.leftDown = false
        E:roadRunsClick()
        local moved = sel.st.edited == true
        local near = math.huge
        local LP = sel.st.pts
        for j = 1, #LP - 1 do
            local a, b = LP[j], LP[j + 1]
            local dx, dz = b.x - a.x, b.z - a.z
            local l2 = dx * dx + dz * dz
            local t = l2 > 0 and math.max(0, math.min(1, ((E.cursorX - a.x) * dx + (E.cursorZ - a.z) * dz) / l2)) or 0
            near = math.min(near, math.sqrt((E.cursorX - a.x - dx * t) ^ 2 + (E.cursorZ - a.z - dz * t) ^ 2))
        end
        -- add a handle on the line
        local mid = sel.st.pts[math.floor(#sel.st.pts / 3) + 1]
        E.cursorX, E.cursorZ = mid.x, mid.z
        frames(1)
        E:roadRunsClick()
        local n1 = #sel.handles
        -- ctrl-remove it again
        E.cursorX, E.cursorZ = mid.x, mid.z
        frames(1)
        local removed = E:roadRunsRemoveHandleAtCursor()
        print(string.format("shape: press %s, dragged handle %d of %d: line edited %s, passes %.2f m from the drop; %.0f -> %.0f m; add -> %d handles; ctrl-remove %s -> %d",
            tostring(took), k, n0, tostring(moved), near, len0, sel.st.len or 0, n1, tostring(removed), #sel.handles))
        -- the lanes that would be laid follow the shaped line (not the line before the edit)
        local lanes = E:roadRunsLanesFor(sel.st, sel.dir)
        local laneNear = math.huge
        for _, ln in ipairs(lanes) do
            for j = 1, #ln.pts - 1 do
                local a, b = ln.pts[j], ln.pts[j + 1]
                local dx, dz = b.x - a.x, b.z - a.z
                local l2 = dx * dx + dz * dz
                local t = l2 > 0 and math.max(0, math.min(1, ((h.x + 3 * nx / nl - a.x) * dx + (h.z + 3 * nz / nl - a.z) * dz) / l2)) or 0
                laneNear = math.min(laneNear, math.sqrt((h.x + 3 * nx / nl - a.x - dx * t) ^ 2 + (h.z + 3 * nz / nl - a.z - dz * t) ^ 2))
            end
        end
        print(string.format("shape: the lane laid passes %.2f m from the dragged handle", laneNear))
        local allow = 0.5
        if #lanes >= 2 then allow = E:roadGapFor(sel.st) / 2 + 0.5 end           -- two lanes sit either side
        print((took and moved and near < 0.3 and laneNear < allow and n1 == n0 + 1 and removed and #sel.handles == n0) and "SHAPE PASS" or "SHAPE FAIL")
    end
end
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
if SYNTH then
    -- can a vehicle drive the new network from the west end to the east end, and back?
    local west, east = nil, nil
    for id = before + 1, count do
        local w = byId[id]
        if west == nil or w.x < byId[west].x then west = id end
        if east == nil or w.x > byId[east].x then east = id end
    end
    local function reach(fromX, toX)
        -- start: the new points near the from-end that have outgoing links heading the right way
        local seen, queue = {}, {}
        for id = before + 1, count do
            if math.abs(byId[id].x - fromX) < 3 then queue[#queue + 1] = id seen[id] = true end
        end
        while #queue > 0 do
            local id = table.remove(queue)
            if math.abs(byId[id].x - toX) < 3 then return true end
            for _, o in ipairs(byId[id].out) do
                if not seen[o] then seen[o] = true queue[#queue + 1] = o end
            end
        end
        return false
    end
    print(string.format("drive west->east: %s; east->west: %s", tostring(reach(byId[west].x, byId[east].x)), tostring(reach(byId[east].x, byId[west].x))))
end
-- PHASE 2: reshape a built run - the chain of new points from the build, picked by a click on it,
-- a middle handle dragged 3 m, an end handle tried (it must stay), applied with a right-click
do
    -- the editor's run walk, simplified: follow points with exactly two neighbours both ways from the seed
    function ADFlyoverEditor:orderedRunThrough(seedId)
        local function nb(w)
            local r, have = {}, {}
            for _, list in ipairs({ w.out, w.incoming }) do
                for _, o in ipairs(list) do
                    if byId[o] ~= nil and not byId[o].gone and not have[o] then have[o] = true r[#r + 1] = o end
                end
            end
            return r
        end
        local ids = { seedId }
        local seen = { [seedId] = true }
        local n0 = nb(byId[seedId])
        for side = 1, math.min(2, #n0) do
            local cur, nxt = byId[seedId], n0[side]
            for _ = 1, 2000 do
                if nxt == nil or seen[nxt] then break end
                cur = byId[nxt]
                seen[cur.id] = true
                if side == 2 then table.insert(ids, 1, cur.id) else ids[#ids + 1] = cur.id end
                local n = nb(cur)
                if #n ~= 2 then break end
                nxt = seen[n[1]] and n[2] or n[1]
            end
        end
        local pts = {}
        for k, id in ipairs(ids) do local w = byId[id] pts[k] = { x = w.x, y = w.y, z = w.z, id = id } end
        return pts
    end
    function ADFlyoverEditor:spanStyle(ids)
        local a = byId[ids[1]]
        local dual = false
        for _, o in ipairs(a.incoming) do if o == ids[2] then dual = true end end
        return dual, 0
    end
    function ADFlyoverEditor:replaceChainInterior(ids, newPoints, dual, flags)
        for i = 2, #ids - 1 do byId[ids[i]].gone = true end
        local a, b = byId[ids[1]], byId[ids[#ids]]
        for _, w in ipairs({ a, b }) do
            for _, list in ipairs({ w.out, w.incoming }) do
                for i = #list, 1, -1 do if byId[list[i]].gone then table.remove(list, i) end end
            end
        end
        local prev = a.id
        for i = 2, #newPoints - 1 do prev = ADGraphManager:recordWayPoint(newPoints[i].x, 0, newPoints[i].z, true, dual, false, prev, flags).id end
        link(byId[prev], b)
        if dual then link(b, byId[prev]) end
        return true
    end
    local seed, pts = nil, {}
    for id = before + 1, count do
        local w = byId[id]
        if not w.gone then
            local p = E:orderedRunThrough(id)
            if #p > #pts then seed, pts = id, p end
        end
    end
    if #pts >= 6 then
        frames(1)
        E:roadRunsSelect(nil)
        E.hoverId = seed
        s.hover, s.hoverPick = nil, nil
        E:roadRunsClick()
        local sel = s.sel
        local ok1 = sel ~= nil and sel.built == true
        local H = sel and sel.handles or {}
        local endA, endB = { x = pts[1].x, z = pts[1].z }, { x = pts[#pts].x, z = pts[#pts].z }
        -- try the end handle: it must not move
        E.cursorX, E.cursorZ, E.mouseX, E.mouseY = H[1].x, H[1].z, 0, 0
        E.leftDown = true
        E:roadRunsPress()
        E.mouseX = 0.1
        E.cursorX = H[1].x + 3
        frames(1)
        E.leftDown = false
        E:roadRunsClick()
        local endKept = math.abs(H[1].x - endA.x) < 0.01 and math.abs(H[1].z - endA.z) < 0.01
        -- a middle handle (or one added mid-line) moved 3 m sideways
        if #H < 3 then
            local m = sel.st.pts[math.floor(#sel.st.pts / 2) + 1]
            E.cursorX, E.cursorZ = m.x, m.z
            E:roadRunsClick()
        end
        local k = math.floor((#H + 1) / 2)
        local h = H[k]
        local a, b = H[k - 1], H[k + 1]
        local nx, nz = -(b.z - a.z), b.x - a.x
        local nl = math.sqrt(nx * nx + nz * nz)
        E.cursorX, E.cursorZ, E.mouseX, E.mouseY = h.x, h.z, 0, 0
        E.leftDown = true
        E:roadRunsPress()
        E.mouseX = 0.1
        local tx, tz = h.x + 3 * nx / nl, h.z + 3 * nz / nl
        E.cursorX, E.cursorZ = tx, tz
        frames(1)
        E.leftDown = false
        E:roadRunsClick()
        local snaps0, n0 = snapshots, count
        E:roadRunsStop()
        frames(1)
        -- the rebuilt run: from the same first end, does it pass the drop and end where it did?
        local again = E:orderedRunThrough(pts[1].id)
        local near = math.huge
        for j = 1, #again - 1 do
            local a, b = again[j], again[j + 1]
            local dx, dz = b.x - a.x, b.z - a.z
            local l2 = dx * dx + dz * dz
            local t = l2 > 0 and math.max(0, math.min(1, ((tx - a.x) * dx + (tz - a.z) * dz) / l2)) or 0
            near = math.min(near, math.sqrt((tx - a.x - dx * t) ^ 2 + (tz - a.z - dz * t) ^ 2))
        end
        local last = again[#again]
        local endsOk = again[1].id == pts[1].id and math.abs(last.x - endB.x) < 0.01 and math.abs(last.z - endB.z) < 0.01
        local maxGap = 0
        local gapAt = 0
        for i = 2, #again do
            local g = math.sqrt((again[i].x - again[i - 1].x) ^ 2 + (again[i].z - again[i - 1].z) ^ 2)
            if g > maxGap then maxGap, gapAt = g, i end
        end
        print(string.format("built shape: longest step ends at point %d of %d", gapAt, #again))
        print(string.format("built shape: selected %s (%d waypoints, %d handles); end handle kept %s; rebuilt %d -> %d waypoints, passes %.2f m from the drop, longest step %.1f m, ends kept %s, %d undo snapshot(s), selection %s",
            tostring(ok1), #pts, #H, tostring(endKept), #pts, #again, near, maxGap, tostring(endsOk), snapshots - snaps0, s.sel == nil and "cleared" or "LEFT"))
        print((ok1 and endKept and near < 1.0 and endsOk and maxGap <= 7.01 and snapshots - snaps0 == 1 and s.sel == nil and count > n0)
            and "BUILT SHAPE PASS" or "BUILT SHAPE FAIL")
    else
        print("built shape: no built run to try (" .. #pts .. " points)")
    end
    E.hoverId = nil
end
-- a second window: move away and back
local t1 = os.clock()
settle(cx + 300, cz)
print(string.format("moved 300 m east: %d stretches (%.2fs)", #s.stretches, os.clock() - t1))
-- kinds toggle forces a re-read
E:roadRunsToggleKind(ADRoadFinder.KIND_DIRT)
settle(cx + 300, cz)
print(string.format("dirt off: %d stretches", #s.stretches))

print("NaN values handed to the engine: " .. nans)

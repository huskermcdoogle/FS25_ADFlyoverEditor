-- Offline harness for the junction tool's clear/rebuild gates.
--
-- Loads the REAL FlyoverEditor.lua against the REAL exported network, so what runs here is the
-- shipping code path, not a reimplementation. Everything the preview path touches that belongs to
-- the game engine is stubbed below; anything it touches that ISN'T stubbed will error loudly rather
-- than silently behaving differently from the game.

-- SHUFFLE=<seed> walks every pairs() in a random order fixed by the seed (shuffle.lua) - as the
-- game can once a clear has renumbered points. A result that changes with the seed depends on
-- loop order. Unset (or 0), nothing changes.
if (tonumber(os.getenv("SHUFFLE") or "") or 0) ~= 0 then dofile("shuffle.lua") end

-- ---------------------------------------------------------------------------- FS Lua extensions
function table.contains(t, v)
    for _, x in pairs(t or {}) do if x == v then return true end end
    return false
end
function table.removeValue(t, v)
    for i, x in ipairs(t or {}) do if x == v then table.remove(t, i); return true end end
    return false
end
function math.clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- ---------------------------------------------------------------------------------- engine stubs
LOG = {}
LOG_ECHO = false
Logging = {
    info = function(fmt, ...) local s = string.format(fmt, ...); LOG[#LOG+1] = s; if LOG_ECHO then print(s) end end,
    warning = function(fmt, ...) local s = "WARN " .. string.format(fmt, ...); LOG[#LOG+1] = s; if LOG_ECHO then print(s) end end,
    error = function(fmt, ...) local s = "ERR  " .. string.format(fmt, ...); LOG[#LOG+1] = s; if LOG_ECHO then print(s) end end,
}
AutoDrive = { FLAG_NONE = 0 }
function AutoDrive.getSetting() return 1 end
function AutoDrive:getTerrainHeightAtWorldPos() return 0 end
g_currentMission = { terrainRootNode = 1 }
g_time = 0
-- No physics offline: the surface raycast and the obstacle probe are engine calls. They are turned
-- OFF via the tool's own toggles in the scenarios below, so they are never reached; if a scenario
-- ever does reach them, these make that obvious instead of silently passing.
function getTerrainHeightAtWorldPos() error("engine call reached: getTerrainHeightAtWorldPos") end
overlapBox = nil       -- junctionObstacleHitsAlong returns 0 when this is nil
raycastClosest = nil
CollisionFlag = { STATIC_OBJECT = 1, TREE = 2, BUILDING = 4, DEFAULT = 8, DYNAMIC_OBJECT = 16 }
-- Real ground, opt-in: TERRAIN=1 replaces the flat, all-road stand-ins above with the map's paint,
-- drive cost, heights and fields (terrain.lua; data from make_terrain.py). Off by default so every
-- existing run and its saved results stay exactly as they were.
if os.getenv("TERRAIN") == "1" then dofile("terrain.lua") end
-- The user's junction numbers and split decisions, opt-in: REGDIR=<folder holding an
-- ADFlyoverEditor_junctions.xml> makes the editor read that file at its first numbering, exactly as
-- the game reads the savegame's (split_registry.lua writes one). Unset, the harness numbers the map
-- afresh as it always has. Never a real savegame: a folder with careerSavegame.xml in it is refused,
-- and since the editor only ever writes the file into a folder that has one, the harness cannot
-- write it at all.
do
    local regDir = os.getenv("REGDIR")
    if regDir ~= nil and regDir ~= "" then
        dofile("xmlstub.lua")
        regDir = regDir:gsub("[/\\]+$", "")
        if fileExists(regDir .. "/careerSavegame.xml") then
            error("REGDIR=" .. regDir .. " is a real savegame (it has careerSavegame.xml). Point it at a copy.")
        end
        if not fileExists(regDir .. "/ADFlyoverEditor_junctions.xml") then
            error("REGDIR=" .. regDir .. " has no ADFlyoverEditor_junctions.xml")
        end
        g_currentMission.missionInfo = { savegameDirectory = regDir }
    end
end

-- ------------------------------------------------------------------------------- the graph itself
local raw = dofile(os.getenv("GRAPH") or "graph_data.lua")
local byId = {}
for _, w in ipairs(raw) do
    byId[w.id] = { id = w.id, x = w.x, y = w.y, z = w.z, flags = w.flags, out = w.out,
                   incoming = w.incoming and { unpack(w.incoming) } or {} }
end
-- Only rebuild the incoming lists when the export did not carry them. Rebuilding changes their
-- ORDER, and the order is not cosmetic: the game loads what the file stored, so a harness that
-- invents its own order can answer differently from the game on the very same network. Rebuilding
-- also silently drops a point wired to itself, which is how 19 of those went unseen.
local haveIn = false
for _, w in pairs(byId) do
    if #w.incoming > 0 then haveIn = true break end
end
if not haveIn then
    for _, w in pairs(byId) do
        for _, t in ipairs(w.out) do
            if byId[t] then table.insert(byId[t].incoming, w.id) end
        end
    end
end
local ordered = {}
for i = 1, #raw do ordered[i] = byId[i] end

ADGraphManager = {}
function ADGraphManager:getWayPointById(id) return byId[id] end
function ADGraphManager:getWayPoints() return ordered end
function ADGraphManager:getWayPointsCount() return #ordered end
function ADGraphManager:markChanges() end

--- What the real undo calls to swap a whole saved graph back in. Never reached through the stub
--- undo below; dbgundo.lua loads the real one. Looked up by position, as the game does.
function ADGraphManager:setWayPoints(wps)
    ordered = wps
    byId = {}
    for i, w in ipairs(ordered) do byId[i] = w end
end
local mapMarkers, groups = {}, {}
function ADGraphManager:getMapMarkers() return mapMarkers end
function ADGraphManager:setMapMarkers(m) mapMarkers = m end
function ADGraphManager:getGroups() return groups end
function ADGraphManager:setGroups(g) groups = g end
function AutoDrive.getAllVehicles() return {} end

--- Mutating ops, so apply-time code (clearing, trimming, extending lane ends) can be exercised
--- offline. Ids are renumbered on removal exactly as AutoDrive does it, because code that holds ids
--- across a removal is a real bug class here.
function ADGraphManager:removeWayPoint(id)
    if byId[id] == nil then return end
    for _, w in pairs(byId) do
        for _, lst in ipairs({ w.out, w.incoming }) do
            for i = #lst, 1, -1 do
                if lst[i] == id then table.remove(lst, i) end
            end
        end
    end
    byId[id] = nil
    local fresh = {}
    for i = 1, #ordered do
        local w = ordered[i]
        if w ~= nil and w.id ~= id then fresh[#fresh + 1] = w end
    end
    local oldToNew = {}
    for i, w in ipairs(fresh) do oldToNew[w.id] = i end
    for _, w in ipairs(fresh) do
        for _, lst in ipairs({ w.out, w.incoming }) do
            for i = 1, #lst do lst[i] = oldToNew[lst[i]] or lst[i] end
        end
    end
    ordered = fresh
    byId = {}
    for i, w in ipairs(ordered) do
        w.id = i
        byId[i] = w
    end
end

function ADGraphManager:recordWayPoint(x, y, z, connectPrevious, dual, isReverse, previousId, flags)
    local w = { id = #ordered + 1, x = x, y = y, z = z, flags = flags or 0, out = {}, incoming = {} }
    ordered[#ordered + 1] = w
    byId[w.id] = w
    if connectPrevious and previousId ~= nil and byId[previousId] ~= nil then
        table.insert(byId[previousId].out, w.id)
        table.insert(w.incoming, previousId)
    end
    return w
end

function ADGraphManager:setWayPointFlags() end

--- Move a waypoint in place, as the game's own call does: id and links untouched.
function ADGraphManager:moveWayPoint(id, x, y, z, flags)
    local w = byId[id]
    if w == nil then return end
    w.x, w.y, w.z = x, y, z
    if flags ~= nil then w.flags = flags end
end

ADDrawingManager = { addLineTask = function() end, addSphereTask = function() end }
-- Undo does nothing here; dbgundo.lua loads the real one (scripts/editor/EditorHistory.lua) over it.
ADEditorHistory = { snapshot = function() end, capture = function() end, commit = function() end }
ADFlyoverSettings = {
    -- main routes its verbose lines through debugLog; offline we always want them
    debugLog = function(fmt, ...) Logging.info(fmt, ...) end, settings = {}, get = function() return 1 end }
ADFlyoverTheme = { lineWeight = 2 }
ADFlyoverHud = {}
ADFlyoverLocale = nil
ADFlyoverSweptPath = nil
SweptSim = nil

-- --------------------------------------------------------------------------- load the real editor
-- The smooth tool's geometry library: pure Lua, and the junction respacing calls it.
MathUtil = MathUtil or { vector2Length = function(x, z) return math.sqrt(x * x + z * z) end }
AutoDrive.FIELD_LOOP_MAX_WAYPOINT_TURN_DEG = 5
AutoDrive.FIELD_LOOP_ADAPTIVE_TOLERANCE = 0.01
AutoDrive.FIELD_LOOP_ADAPTIVE_MIN_SPACING = 1.0
dofile("../../scripts/editor/OffsetGeometry.lua")
if os.getenv("RIG_TRAILER") then ADFlyoverSweptPath = { rig = { lookAhead = 8, trailerLength = tonumber(os.getenv("RIG_TRAILER")) } } end
dofile("editor_load.lua")()
-- ADOPT=<a debug capture's meta.txt>: run on the settings the game had (replay_session.py sets it), not
-- the harness's defaults. TURNR=<m>: the card's turn radius, which the clear reads too (the game logs it
-- on every "junction site locked" line).
if os.getenv("ADOPT") and os.getenv("ADOPT") ~= "" then dofile("adoptmeta.lua")(os.getenv("ADOPT")) end

-- ----------------------------------------------------------------------------------- the scenario
local E = ADFlyoverEditor
local M = {}

--- Run the real updateJunctionPreview at (cx,cz) with the given options and return the preview plus
--- every log line it produced.
-- Test switches: REAIM=9999 disables the re-aim, NOSWEEP=1 the integrity sweep.
if os.getenv("REAIM") then AutoDrive.FLYOVER_JUNCTION_REAIM_MIN = tonumber(os.getenv("REAIM")) end
-- PART_CONNECTORS=0: a lane from one part's side road across the main road to another part's is kept as
-- a through road again (as before 2026-10-02): at j39 (the session network, the user's split decisions,
-- through roads kept) the north road's southbound lane then stays, and 39se's right turn off the main
-- road no longer drives.
if os.getenv("PART_CONNECTORS") == "0" then AutoDrive.FLYOVER_JUNCTION_PART_CONNECTORS = false end
-- SIDE_DUPES=0: the tidy carries a side lane to the box even where its whole lane in is a through
-- road's (as before 2026-10-03): clearing j39 and then 39se, both with through roads kept, then leaves
-- a dead end off the main road.
if os.getenv("SIDE_DUPES") == "0" then AutoDrive.FLYOVER_JUNCTION_SIDE_DUPES = false end
-- RUN_STRAIGHT=0: the "same lane twice" test walks a lane on past its anchor by the nearest point
-- further out again, not the way straight on at a fork, as before 2026-10-03.
if os.getenv("RUN_STRAIGHT") == "0" then AutoDrive.FLYOVER_JUNCTION_RUN_STRAIGHT = false end
-- LOOSE_ENDS=0: the check no longer says a way the clear left leading nowhere, or fed by nothing (as
-- before 2026-10-03): in the missed-turn test (regmissed.sh) j39's own turn onto the north road, kept on
-- purpose, is then said by nothing at all.
if os.getenv("LOOSE_ENDS") == "0" then AutoDrive.FLYOVER_JUNCTION_LOOSE_ENDS = false end
-- TWIN_TURNS=0: the clear of one part of a split no longer leaves another part's turn in its area
-- working (rule 1 of 2026-10-03), and the check no longer follows those turns (rule 4): at j39 with
-- through roads off, 39se's right turn then loses the point it leaves the main road at.
if os.getenv("TWIN_TURNS") == "0" then AutoDrive.FLYOVER_JUNCTION_TWIN_TURNS = false end
-- PART_ROAD=0: with through roads off, a part's clear cuts the road and sweeps its box past the
-- half-way line to the other part again (rule 2 of 2026-10-03): clearing 20n and then 20s then takes
-- the whole road between the two.
if os.getenv("PART_ROAD") == "0" then AutoDrive.FLYOVER_JUNCTION_PART_ROAD = false end

function M.lock(cx, cz, opts)
    opts = opts or {}
    LOG = {}
    E.tool = E.TOOL.JUNCTION
    E.junctionMode = opts.mode or "clear"
    -- Clear + build (doc 12) is the card's default in game; here a clear lock stays a plain clear unless
    -- asked (thenBuild = true), so every script that locks, clears and builds by hand runs as before.
    E.junctionThenBuild = opts.thenBuild == true
    E.junctionNoFit = opts.noFit or "turns"
    E.junctionLeaveThrough = (opts.leaveThrough ~= false)
    E.junctionRadius = opts.radius or 15
    E.junctionTurnRadius = opts.turnRadius or tonumber(os.getenv("TURNR") or "") or 12
    E.junctionRebuild = opts.rebuild == true
    E.junctionCheckSurface = false     -- engine raycast, off
    E.junctionCheckObstacles = false   -- engine overlapBox, off
    E.junctionSwept = false            -- needs SweptSim + a rig
    -- GAMEFLAGS=1: the road check and the swept-path check on, as in game (with TERRAIN=1 and SweptSim
    -- loaded). Set here, not before the lock: the lock sets these every time.
    if os.getenv("GAMEFLAGS") == "1" then E.junctionCheckSurface, E.junctionSwept = true, true end
    E.junctionExtendTrim = true
    E.junctionUseDubins = true
    -- Build layout (doc 07): PATTERN=exact (default, as in game) | smooth | off.
    E.junctionPattern = opts.pattern or os.getenv("PATTERN") or "exact"
    E.cursorX, E.cursorZ, E.cursorY = cx, cz, 0
    E.junctionArmed = { cx = cx, cz = cz, cy = 0 }
    E.junctionPreviewKey = nil
    E.junctionPreview = nil
    E:updateJunctionPreview()
    return E.junctionPreview, LOG
end

function M.dump(jp, log, filter)
    if jp == nil then print("  (no preview)") return end
    local leave = E.junctionLeaveThrough ~= false
    local doomed = leave and jp.turnDebris or jp.debris
    print(string.format("  approaches %d | will clear %d | through spared %d | debris %d",
        #(jp.approaches or {}), #(doomed or {}), #(jp.throughDebris or {}), #(jp.debris or {})))
    for _, line in ipairs(log) do
        if line:find("junction clear") or (filter and line:find(filter)) then
            print("    " .. line)
        end
    end
end

--- Run the real applyJunctionClear against the loaded graph. Destructive: the graph is mutated for
--- the rest of this process, so one scenario per run unless the mutation is the point.
-- AS THE RIGHT-CLICK DOES IT (Mouse.lua): only when junctionHasWork says there is something to do.
-- Calling the clear directly let j101's one-point clear pass offline while the game's right-click
-- unlocked the site, "nothing to place" (build 535). HARNESS_DIRECT=1 skips the check, and so does
-- an older editor (FE_SRC) from before junctionHasWork.
function M.apply()
    LOG = {}
    if os.getenv("HARNESS_DIRECT") ~= "1" and E.junctionHasWork ~= nil and not E:junctionHasWork(E.junctionPreview) then
        LOG[#LOG + 1] = "[FlyoverEditor]: junction site unlocked (nothing to place)."
        return LOG
    end
    E:applyJunctionClear()
    return LOG
end

--- Run the real applyJunction (the BUILD: lay the preview's new turns) against the loaded graph. Lock
--- the site with mode = "build" first; a clear-mode preview is refused here rather than silently
--- cleared, since applyJunction hands those to the clear. Destructive like M.apply.
function M.build()
    LOG = {}
    local jp = E.junctionPreview
    if jp == nil then error("M.build: no preview - lock the site with mode = \"build\" first") end
    if jp.clearMode then error("M.build: the preview is a clear - lock with mode = \"build\"") end
    if os.getenv("HARNESS_DIRECT") ~= "1" and E.junctionHasWork ~= nil and not E:junctionHasWork(jp) then
        LOG[#LOG + 1] = "[FlyoverEditor]: junction site unlocked (nothing to place)."
        return LOG
    end
    E:applyJunction()
    return LOG
end

--- Walk a lane in from its outer anchor and report the surviving end plus the last few spacings -
--- how a tidied stub is actually inspected.
function M.laneEnd(ap)
    local useOut = (ap.dir == "in")
    local node = ap.wp
    if node == nil or ADGraphManager:getWayPointById(node.id) ~= node then return nil end
    local cb = ap.chainBearing or ap.bearing or 0
    local wdx, wdz = math.sin(cb), math.cos(cb)
    if not useOut then wdx, wdz = -wdx, -wdz end
    local seq, cameFrom = { node }, nil
    for _ = 1, 400 do
        local list = useOut and (node.out or {}) or (node.incoming or {})
        local best, bd = nil, -math.huge
        for _, nid in pairs(list) do
            if nid ~= cameFrom then
                local nx = ADGraphManager:getWayPointById(nid)
                if nx ~= nil then
                    local dx, dz = nx.x - node.x, nx.z - node.z
                    local l = math.sqrt(dx * dx + dz * dz)
                    if l > 1e-6 then
                        local dot = (dx / l) * wdx + (dz / l) * wdz
                        if dot > bd then bd, best = dot, nx end
                    end
                end
            end
        end
        if best == nil or (#seq > 1 and bd < 0.3) then break end
        cameFrom = node.id
        local dx, dz = best.x - node.x, best.z - node.z
        local l = math.sqrt(dx * dx + dz * dz)
        if l > 1e-6 then wdx, wdz = dx / l, dz / l end
        node = best
        seq[#seq + 1] = node
    end
    local gaps = {}
    for i = math.max(2, #seq - 3), #seq do
        local a, b = seq[i - 1], seq[i]
        gaps[#gaps + 1] = math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
    end
    return seq[#seq], gaps, #seq
end

--- The whole lane as positions, anchor-inward: the alignment the road actually had, for checking
--- what a re-laid run-in does to it.
function M.laneSeq(ap)
    local useOut = (ap.dir == "in")
    local node = ap.wp
    if node == nil or ADGraphManager:getWayPointById(node.id) ~= node then return {} end
    local cb = ap.chainBearing or ap.bearing or 0
    local wdx, wdz = math.sin(cb), math.cos(cb)
    if not useOut then wdx, wdz = -wdx, -wdz end
    local pts, cameFrom = { { x = node.x, z = node.z } }, nil
    for _ = 1, 400 do
        local list = useOut and (node.out or {}) or (node.incoming or {})
        local best, bd = nil, -math.huge
        for _, nid in pairs(list) do
            if nid ~= cameFrom then
                local nx = ADGraphManager:getWayPointById(nid)
                if nx ~= nil then
                    local dx, dz = nx.x - node.x, nx.z - node.z
                    local l = math.sqrt(dx * dx + dz * dz)
                    if l > 1e-6 then
                        local dot = (dx / l) * wdx + (dz / l) * wdz
                        if dot > bd then bd, best = dot, nx end
                    end
                end
            end
        end
        if best == nil or (#pts > 1 and bd < 0.3) then break end
        cameFrom = node.id
        local dx, dz = best.x - node.x, best.z - node.z
        local l = math.sqrt(dx * dx + dz * dz)
        if l > 1e-6 then wdx, wdz = dx / l, dz / l end
        node = best
        pts[#pts + 1] = { x = node.x, z = node.z }
    end
    return pts
end

return M

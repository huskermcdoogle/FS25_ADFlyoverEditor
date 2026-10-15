-- Offline bench for the road finder: runs scripts/editor/RoadFinder.lua against the real map's ground
-- (paint, drive cost, fields) and an exported AutoDrive network, and writes what it found to a text
-- file that view.py turns into a pan/zoom page.
--
--   lua bench.lua <centreX> <centreZ> [size] [out.txt]
--
-- Data (both are your map, so not in git):
--   TERRAIN_DIR  terrain_data/ from the junction branch's tools/junction-harness/make_terrain.py
--   GRAPH        graph_data.lua from that harness's export_graph.py (AutoDrive network)
-- Options: KINDS=pgd (paved, gravel, dirt; default all), MODE=one|two|lanes, GAP=4, FORKGAP=15
local HERE = (arg[0]:match("^(.*)[/\\]") or ".") .. "/"
local JH = dofile(HERE .. "datadir.lua")(HERE)
if os.getenv("TERRAIN_DIR") == nil then
    -- terrain.lua reads TERRAIN_DIR through os.getenv; point it at the junction harness copy
    local real = os.getenv
    os.getenv = function(k) if k == "TERRAIN_DIR" then return JH .. "terrain_data/" end return real(k) end
end

-- the engine bits terrain.lua expects to find
g_currentMission = { terrainRootNode = 1 }
AutoDrive = {}
CollisionFlag = {}
dofile(HERE .. "terrain.lua")
dofile(HERE .. "../../scripts/editor/RoadFinder.lua")
local RF = ADRoadFinder
-- switches to compare rules: NOBUB=1 (no bubble removal), NOTHRU=1 (no through roads at forks)
if os.getenv("NOBUB") then RF.BUBBLE_MAX = 0 end
if os.getenv("NOTHRU") then RF.THROUGH_ANGLE = -1 end

local cx, cz = tonumber(arg[1] or "0"), tonumber(arg[2] or "0")
local size = tonumber(arg[3] or "384")
local outPath = arg[4] or (HERE .. "out/bench.txt")

local kindsArg = os.getenv("KINDS") or "pgd"
local kinds = {}
if kindsArg:find("p") then kinds[RF.KIND_PAVED] = true end
if kindsArg:find("g") then kinds[RF.KIND_GRAVEL] = true end
if kindsArg:find("d") then kinds[RF.KIND_DIRT] = true end

local t0 = os.clock()
local cache = RF.newCache()
local ix0, iz0 = math.floor(cx - size / 2), math.floor(cz - size / 2)
RF.cacheRequest(cache, ix0, iz0, ix0 + size - 1, iz0 + size - 1)
while not RF.cacheStep(cache, 100000) do end
local tSample = os.clock() - t0

local t1 = os.clock()
local win = RF.buildWindow(function(ix, iz) return RF.cacheKind(cache, ix, iz) end, ix0, iz0, size, size, { kinds = kinds })
local tBuild = os.clock() - t1

-- the network
local graphPath = os.getenv("GRAPH") or (JH .. "graph_data.lua")
local wps = dofile(graphPath)
local byId = {}
for _, w in ipairs(wps) do byId[w.id] = w end
local grid = RF.indexNetwork(wps, function(id) return byId[id] end, ix0, iz0, ix0 + size, iz0 + size)
local t2 = os.clock()
local stretches = RF.findStretches(win, grid)
local tCover = os.clock() - t2
local laneGap, laneGapN = RF.networkLaneGap(grid)

local modeArg = os.getenv("MODE") or "auto"
local gapFixed = tonumber(os.getenv("GAP") or "")
local forkGap = tonumber(os.getenv("FORKGAP") or "15")

local f = assert(io.open(outPath, "w"))
f:write(string.format("window %d %d %d %d\n", ix0, iz0, size, size))
f:write(string.format("timing sample=%.2f build=%.2f cover=%.2f\n", tSample, tBuild, tCover))
f:write(string.format("lanegap %s %s\n", tostring(laneGap), tostring(laneGapN)))
-- kinds grid, row by row (one char per cell: 0-3)
for r = 0, size - 1 do
    local row = {}
    for c = 0, size - 1 do row[#row + 1] = tostring(RF.cacheKind(cache, ix0 + c, iz0 + r) or 0) end
    f:write("k ", table.concat(row), "\n")
end
for _, n in ipairs(win.nodes) do
    f:write(string.format("node %.2f %.2f %s %d\n", n.x, n.z, n.tag, #n.edges))
end
for _, e in ipairs(win.edges) do
    local t = {}
    for _, p in ipairs(e.pts) do t[#t + 1] = string.format("%.2f,%.2f", p.x, p.z) end
    f:write(string.format("edge %s %d %.1f %s\n", e.class, e.kind or 0, e.width or -1, table.concat(t, " ")))
end
for _, sg in ipairs(grid.segs) do
    f:write(string.format("ad %.2f %.2f %.2f %.2f\n", sg.ax, sg.az, sg.bx, sg.bz))
end
local nLanes = 0
for si, st in ipairs(stretches) do
    local t = {}
    for _, p in ipairs(st.pts) do t[#t + 1] = string.format("%.2f,%.2f", p.x, p.z) end
    f:write(string.format("stretch %d %s %d %.1f %.1f %s %s %s\n", si, st.class, st.kind or 0, st.width or -1,
        st.len, st.startTag, st.endTag, table.concat(t, " ")))
    local mode = modeArg
    if mode == "auto" then mode = (st.class == "paved") and "lanes" or "two" end
    local gap = gapFixed or math.max(3.3, math.min(6, (st.width or 6) * 0.6))
    local lanes = RF.planLanes(st, mode, 1, gap, forkGap)
    for _, ln in ipairs(lanes or {}) do
        local q = {}
        for _, p in ipairs(ln.pts) do q[#q + 1] = string.format("%.2f,%.2f", p.x, p.z) end
        f:write(string.format("lane %d %s %s\n", si, ln.dual and "2" or "1", table.concat(q, " ")))
        nLanes = nLanes + 1
    end
end
-- WALK=1: also walk each stretch from its middle (the road walker) - "walk" = straightened, "raw" = as walked
if os.getenv("WALK") then
    local function isRoadOf(cls)
        if cls == "paved" then return function(x, z) return RF.groundKindAt(x, z) == RF.KIND_PAVED end end
        return function(x, z) local k = RF.groundKindAt(x, z) return k == RF.KIND_GRAVEL or k == RF.KIND_DIRT end
    end
    local function isStopOf(cls)
        if cls == "track" then return function(x, z) return RF.groundKindAt(x, z) == RF.KIND_PAVED end end
    end
    for si, st in ipairs(stretches) do
        local w = RF.refineStretch(st, isRoadOf, isStopOf)
        if w ~= nil then
            w = RF.keepUncovered(w, RF.indexNetwork(wps, function(id) return byId[id] end, -1100, -1100, 1100, 1100)) or w
            local b = {}
            for _, p in ipairs(w.pts) do b[#b + 1] = string.format("%.2f,%.2f", p.x, p.z) end
            f:write(string.format("walk %d %s %s %.1f %s\n", si, w.startTag, w.endTag, w.width or -1, table.concat(b, " ")))
        end
    end
end
f:close()
local live = 0
for _, n in ipairs(win.nodes) do if n.tag == "fork" then live = live + 1 end end
print(string.format("window (%d,%d) %dm: %d edges, %d forks, %d AD links, %d stretches, %d lanes; sample %.2fs build %.2fs cover %.2fs; map lane gap %s (%s pairs)",
    ix0, iz0, size, #win.edges, live, #grid.segs, #stretches, nLanes, tSample, tBuild, tCover, tostring(laneGap), tostring(laneGapN)))

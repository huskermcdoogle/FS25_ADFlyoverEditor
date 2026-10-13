-- The old narrow lane on savegame6 (AD points 9195-9270, a ~2 m asphalt lane with gravel edges) as a
-- ruler: walks from points on it must follow the old AutoDrive path (2026-10-12 game tests).
--   lua lanetest.lua   (needs the junction harness data, as bench.lua)
local HERE = (arg[0]:match("^(.*)[/\]") or ".") .. "/"
local JH = HERE .. "../../../junction-rework-fec884/tools/junction-harness/"
local real = os.getenv
os.getenv = function(k) if k == "TERRAIN_DIR" then return JH .. "terrain_data/" end return real(k) end
g_currentMission = { terrainRootNode = 1 }; AutoDrive, CollisionFlag = {}, {}
dofile(HERE .. "terrain.lua"); dofile(HERE .. "../../scripts/editor/RoadFinder.lua")
local RF = ADRoadFinder
local wps = dofile(JH .. "graph_data.lua"); local byId = {}; for _, w in ipairs(wps) do byId[w.id] = w end
-- the deleted lane path: the chain through 9230
local lane = {}
for id = 9195, 9270 do if byId[id] then lane[#lane+1] = byId[id] end end
local function distToLane(x, z)
  local bd = math.huge
  for i = 1, #lane - 1 do
    local a, b = lane[i], lane[i+1]
    local dx, dz = b.x - a.x, b.z - a.z; local l2 = dx*dx + dz*dz
    local t = l2 > 0 and math.max(0, math.min(1, ((x-a.x)*dx + (z-a.z)*dz)/l2)) or 0
    local d = math.sqrt((x - a.x - dx*t)^2 + (z - a.z - dz*t)^2)
    if d < bd then bd = d end
  end
  return bd
end
local isRoadOf = function(cls)
  if cls == "paved" then return function(x,z) return RF.groundKindAt(x,z) == 3 end end
  return function(x,z) local k = RF.groundKindAt(x,z) return k == 1 or k == 2 end
end
local isStopOf = function(cls) if cls == "track" then return function(x,z) return RF.groundKindAt(x,z) == 3 end end end
RF.WALK.maxLen = 400
local function distAny(x, z)
  local bd = math.huge
  for _, w in ipairs(wps) do for _, o in ipairs(w.out or {}) do local b = byId[o]; if b then
    local dx, dz = b.x - w.x, b.z - w.z; local l2 = dx*dx+dz*dz
    local t = l2 > 0 and math.max(0, math.min(1, ((x-w.x)*dx + (z-w.z)*dz)/l2)) or 0
    local d = math.sqrt((x - w.x - dx*t)^2 + (z - w.z - dz*t)^2); if d < bd then bd = d end end end end
  return bd
end
local tot, n, worst = 0, 0, 0
for _, seed in ipairs({ lane[10], lane[25], lane[40] }) do
    local r = RF.walkFrom(isRoadOf, seed.x + 0.7, seed.z + 0.4, { "paved", "track" }, isStopOf)
    local L, acc = RF.polylineLength(r.pts), 0
    for i, p in ipairs(r.pts) do
        if i > 1 then acc = acc + math.sqrt((p.x - r.pts[i - 1].x) ^ 2 + (p.z - r.pts[i - 1].z) ^ 2) end
        if acc > 7.5 and acc < L - 7.5 then
            local d = distAny(p.x, p.z)
            tot, n, worst = tot + d, n + 1, math.max(worst, d)
        end
    end
    print(string.format("walk %.0f m %s..%s", r.len, r.startTag, r.endTag))
end
local ok = n > 0 and tot / n <= 0.35 and worst <= 1.2
print(string.format("%s from the old path: mean %.2f m, worst %.2f m (fork gaps left out)", ok and "ok  " or "FAIL", tot / n, worst))
print(ok and "ALL PASS" or "1 FAILED")

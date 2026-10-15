-- Walk the same road from several mouse spots: lua starts.lua x1 z1 x2 z2 ...  (same ends = consistent)
local JH = "../../../junction-rework-fec884/tools/junction-harness/"
local real = os.getenv; os.getenv = function(k) if k == "TERRAIN_DIR" then return JH .. "terrain_data/" end return real(k) end
g_currentMission = { terrainRootNode = 1 }; AutoDrive, CollisionFlag = {}, {}
dofile("terrain.lua"); dofile("../../scripts/editor/RoadFinder.lua"); local RF = ADRoadFinder
-- the game's rules: a track is gravel/dirt that is not a paved road's shoulder; meeting either stops it
local shoulderAt = RF.newShoulderMap(RF.groundKindAt)
local isRoadOf = function(cls) if cls == "paved" then return function(x,z) return RF.groundKindAt(x,z) == 3 end end
  return function(x,z) local k = RF.groundKindAt(x,z) return (k == 1 or k == 2) and not shoulderAt(x, z) end end
local isStopOf = function(cls) if cls == "track" then return function(x,z) return RF.groundKindAt(x,z) == 3 or shoulderAt(x, z) end end end
-- GRAPH=<graph_data.lua>: walks end where they run onto a path in it, as in game
if os.getenv("GRAPH") then
  local wps = dofile(os.getenv("GRAPH")); local byId = {} for _, w in ipairs(wps) do byId[w.id] = w end
  local grid = RF.indexNetwork(wps, function(id) return byId[id] end, -1100, -1100, 1100, 1100)
  RF.walkCovered = function(x, z, hx, hz) return RF.coveredHere(grid, x, z, hx, hz, 2.5) end
end
RF.WALK.maxLen = 400
if os.getenv("TRACE") then RF.TRACE = true end
local spots = {}
for i = 1, #arg - 1, 2 do spots[#spots + 1] = { tonumber(arg[i]), tonumber(arg[i + 1]) } end
for _, c in ipairs(spots) do
  local r = RF.walkFrom(isRoadOf, c[1], c[2], {"paved","track"}, isStopOf)
  if r then local P = r.pts
  print(string.format("from (%6.1f,%6.1f): %3.0f m %s  %s (%.0f,%.0f) .. %s (%.0f,%.0f)", c[1], c[2], r.len, r.class, r.startTag, P[1].x, P[1].z, r.endTag, P[#P].x, P[#P].z))
  else print("from", c[1], c[2], "nothing") end
end

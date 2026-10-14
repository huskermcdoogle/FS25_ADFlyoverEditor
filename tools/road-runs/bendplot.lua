-- Dump paint + the walk (raw walker path and laid line) round a spot for bendplot.py:
--   lua bendplot.lua mouseX mouseZ x0 x1 z0 z1 > out/bend.txt
local HERE = (arg[0]:match("^(.*)[/\]") or ".") .. "/"
local JH = HERE .. "../../../junction-rework-fec884/tools/junction-harness/"
local real = os.getenv
os.getenv = function(k) if k == "TERRAIN_DIR" then return JH .. "terrain_data/" end return real(k) end
g_currentMission = { terrainRootNode = 1 }; AutoDrive, CollisionFlag = {}, {}
dofile(HERE .. "terrain.lua"); dofile(HERE .. "../../scripts/editor/RoadFinder.lua")
local RF = ADRoadFinder
local sh = RF.newShoulderMap(RF.groundKindAt)
local isRoadOf = function(cls) if cls == "paved" then return function(x,z) return RF.groundKindAt(x,z) == 3 end end
  return function(x,z) local k = RF.groundKindAt(x,z) return (k == 1 or k == 2) and not sh(x, z) end end
local isStopOf = function(cls) if cls == "track" then return function(x,z) return RF.groundKindAt(x,z) == 3 or sh(x, z) end end end
RF.WALK.maxLen = 400
local mx, mz, x0, x1, z0, z1 = tonumber(arg[1]), tonumber(arg[2]), tonumber(arg[3]), tonumber(arg[4]), tonumber(arg[5]), tonumber(arg[6])
for z = z0, z1, 0.5 do for x = x0, x1, 0.5 do
  local k = RF.groundKindAt(x, z); local c = k
  if (k == 1 or k == 2) and sh(x, z) then c = 4 elseif k == 0 and RF.isFieldAt(x, z) then c = 5 end
  print(string.format("c %.2f %.2f %d", x, z, c)) end end
local r = RF.walkFrom(isRoadOf, mx, mz, { "track" }, isStopOf)
for _, p in ipairs(r.raw or {}) do print(string.format("w %.2f %.2f", p.x, p.z)) end
for _, p in ipairs(r.pts) do print(string.format("l %.2f %.2f", p.x, p.z)) end

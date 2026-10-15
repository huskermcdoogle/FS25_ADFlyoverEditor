-- Paint of a saved case round a box, for casepic.py:  AREA=<case.xml> lua casecells.lua x0 x1 z0 z1
--   prints "c x z kind" every 0.5 m (kind 4 = shoulder, 5 = field)
local HERE = (arg[0]:match("^(.*)[/\]") or ".") .. "/"
local JH = dofile(HERE .. "datadir.lua")(HERE)
local real = os.getenv
os.getenv = function(k) if k == "TERRAIN_DIR" then return JH .. "terrain_data/" end return real(k) end
g_currentMission = { terrainRootNode = 1 }; AutoDrive, CollisionFlag = {}, {}
dofile(HERE .. "terrain.lua"); dofile(HERE .. "../../scripts/editor/RoadFinder.lua")
local RF = ADRoadFinder
local sh = RF.newShoulderMap(RF.groundKindAt)
local x0, x1, z0, z1 = tonumber(arg[1]), tonumber(arg[2]), tonumber(arg[3]), tonumber(arg[4])
for z = z0, z1, 0.5 do for x = x0, x1, 0.5 do
    local k = RF.groundKindAt(x, z)
    if (k == 1 or k == 2) and sh(x, z) then k = 4 elseif k == 0 and RF.isFieldAt(x, z) then k = 5 end
    if k ~= 0 then print(string.format("c %.2f %.2f %d", x, z, k)) end
end end

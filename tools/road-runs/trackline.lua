-- The laid line along a straight N-S track against its true middle: lua trackline.lua x z middleX
local HERE = (arg[0]:match("^(.*)[/\]") or ".") .. "/"
local JH = dofile(HERE .. "datadir.lua")(HERE)
local real = os.getenv
os.getenv = function(k) if k == "TERRAIN_DIR" then return JH .. "terrain_data/" end return real(k) end
g_currentMission = { terrainRootNode = 1 }; AutoDrive, CollisionFlag = {}, {}
dofile(HERE .. "terrain.lua"); dofile(HERE .. "../../scripts/editor/RoadFinder.lua")
local RF = ADRoadFinder
local shoulderAt = RF.newShoulderMap(RF.groundKindAt)
local isRoadOf = function(cls) if cls == "paved" then return function(x,z) return RF.groundKindAt(x,z) == 3 end end
  return function(x,z) local k = RF.groundKindAt(x,z) return (k == 1 or k == 2) and not shoulderAt(x, z) end end
local isStopOf = function(cls) if cls == "track" then return function(x,z) return RF.groundKindAt(x,z) == 3 or shoulderAt(x, z) end end end
RF.WALK.maxLen = 400
local mx = tonumber(arg[3])
local worst, sum, n = 0, 0, 0
for i = 1, #arg - 2, 3 do end
local r = RF.walkFrom(isRoadOf, tonumber(arg[1]), tonumber(arg[2]), {"track", "paved"}, isStopOf)
local rows = {}
for i, p in ipairs(r.pts) do
    local d = p.x - mx
    worst, sum, n = math.max(worst, math.abs(d)), sum + math.abs(d), n + 1
    if i % 4 == 1 then rows[#rows + 1] = string.format("%.0f:%+.1f", p.z, d) end
end
print(string.format("%.0f m %s..%s; off the middle: mean %.2f m, worst %.2f m", r.len, r.startTag, r.endTag, sum / n, worst))
print(table.concat(rows, " "))

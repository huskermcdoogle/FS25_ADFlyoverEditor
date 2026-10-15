-- Where does a walk end, and what ground is under its last points?  lua endcheck.lua x z
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
local x, z = tonumber(arg[1]), tonumber(arg[2])
local r = RF.walkFrom(isRoadOf, x, z, {"paved","track"}, isStopOf)
if r == nil then print("nothing") return end
print(string.format("%s %.0f m %s..%s", r.class, r.len, r.startTag, r.endTag))
local function across(p, q)
    local hx, hz = q.x - p.x, q.z - p.z
    local l = math.sqrt(hx * hx + hz * hz); if l < 1e-6 then return "" end
    local nx, nz = -hz / l, hx / l
    local t = {}
    for o = -6, 6, 0.5 do
        if math.abs(o) < 0.01 then t[#t + 1] = "|" end
        t[#t + 1] = ({ [0] = ".", "d", "g", "p" })[RF.groundKindAt(p.x + nx * o, p.z + nz * o)]
    end
    return table.concat(t)
end
local P = r.pts
for _, i in ipairs({ 1, 2, 3, 4, 5, 6 }) do if P[i] then print(string.format("start %3d (%.1f,%.1f) %s", i, P[i].x, P[i].z, across(P[i], P[math.min(#P, i + 1)]))) end end
for i = math.max(1, #P - 8), #P do print(string.format("end   %3d (%.1f,%.1f) %s", i, P[i].x, P[i].z, across(P[math.max(1, i - 1)], P[i]))) end

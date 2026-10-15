-- Rough time of one walk from a mouse spot, and of its main parts:  lua prof.lua x z
local HERE = (arg[0]:match("^(.*)[/\\]") or ".") .. "/"
local JH = dofile(HERE .. "datadir.lua")(HERE)
local real = os.getenv
os.getenv = function(k) if k == "TERRAIN_DIR" then return JH .. "terrain_data/" end return real(k) end
g_currentMission = { terrainRootNode = 1 }; AutoDrive, CollisionFlag = {}, {}
dofile(HERE .. "terrain.lua"); dofile(HERE .. "../../scripts/editor/RoadFinder.lua")
local RF = ADRoadFinder
local shoulderAt = RF.newShoulderMap(RF.groundKindAt)
local calls = 0
local isRoadOf = function(cls)
    if cls == "paved" then return function(x, z) calls = calls + 1 return RF.groundKindAt(x, z) == 3 end end
    return function(x, z) calls = calls + 1 local k = RF.groundKindAt(x, z) return (k == 1 or k == 2) and not shoulderAt(x, z) end
end
local isStopOf = function(cls) if cls == "track" then return function(x, z) return RF.groundKindAt(x, z) == 3 or shoulderAt(x, z) end end end
RF.WALK.maxLen = 400
local T = {}
for _, name in ipairs({ "seedRoad", "throughArm", "refineStretchInner", "straighten" }) do
    local f = RF[name]
    T[name] = { t = 0, n = 0, reads = 0 }
    RF[name] = function(...)
        local t0, c0 = os.clock(), calls
        local res = { f(...) }
        T[name].t, T[name].n, T[name].reads = T[name].t + os.clock() - t0, T[name].n + 1, T[name].reads + calls - c0
        return unpack(res, 1, 6)
    end
end
local t0 = os.clock()
local r = RF.walkFrom(isRoadOf, tonumber(arg[1]), tonumber(arg[2]), { "track", "paved" }, isStopOf)
print(string.format("total %.0f ms, %d road reads, %.0f m", (os.clock() - t0) * 1000, calls, r and r.len or 0))
for k, v in pairs(T) do print(string.format("  %-20s %4d calls %6.0f ms %7d reads", k, v.n, v.t * 1000, v.reads)) end

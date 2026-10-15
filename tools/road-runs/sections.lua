-- What the centring pass read across a walked line, section by section, between two z values:
--   lua sections.lua x z zFrom zTo [middleX]
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
local r = RF.walkFrom(isRoadOf, tonumber(arg[1]), tonumber(arg[2]), {"track", "paved"}, isStopOf)
local z0, z1 = math.min(tonumber(arg[3]), tonumber(arg[4])), math.max(tonumber(arg[3]), tonumber(arg[4]))
local mx = tonumber(arg[5] or "0")
for _, s in ipairs(r.debug.sections) do
  if s.z >= z0 and s.z <= z1 then
    local t = {} for _, b in ipairs(s.bands) do t[#t+1] = string.format("%s[%.1f..%.1f]", b.picked and "*" or "", b.lo, b.hi) end
    -- world x of the line's offset (for a N-S road: x = guide + nx * off)
    print(string.format("z %7.1f guide %+5.2f line %+5.2f %-8s %-5s exp %s %s", s.z, s.x - mx, s.x + s.nx * (s.off or 0) - mx, s.why or "used", s.edge or "", s.eL and string.format("[%.1f..%.1f]", s.eL, s.eR) or "-", table.concat(t, " ")))
  end
end

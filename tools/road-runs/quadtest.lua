-- Two two-rut tracks side by side (four ruts in a row): the rut pair read must be one track's two
-- ruts, never the middle two.   lua quadtest.lua
local HERE = (arg[0]:match("^(.*)[/\]") or ".") .. "/"
dofile(HERE .. "../../scripts/editor/RoadFinder.lua")
local RF = ADRoadFinder
-- ruts (x ranges) 1 m wide, 1 m gaps inside a track, 1.2 m between the tracks
local ruts = { { -4.7, -3.7 }, { -2.7, -1.7 }, { -0.5, 0.5 }, { 1.5, 2.5 } }
local isRoad = function(x, z) for _, r in ipairs(ruts) do if x >= r[1] and x <= r[2] then return true end end return false end
local fails = 0
for _, probe in ipairs({ -2.2, -1.0, 0.0, 1.0 }) do
    local bands = RF.bandsAt(function(x, z) return isRoad(x + probe, z) end, 0, 0, 1, 0, "track")
    local b = bands[1]
    local mid = b and (b.mid + probe) or 99
    local ok = b and b.ruts and (math.abs(mid - (-3.2)) < 0.3 or math.abs(mid - 1.0) < 0.3)
    print(string.format("%s line at %+.1f: pair middle %+.2f (tracks at -3.20 and +1.00)", ok and "ok  " or "FAIL", probe, mid))
    if not ok then fails = fails + 1 end
end
print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))

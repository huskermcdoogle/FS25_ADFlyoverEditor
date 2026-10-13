-- Ends on a curving road must keep curving (2026-10-12: straight tails ran off the middle).
-- A paved road 7 m wide bending round a 60 m radius, half a circle, with a side road at the top.
--   lua curvetest.lua
local HERE = (arg[0]:match("^(.*)[/\]") or ".") .. "/"
g_currentMission = { terrainRootNode = 1 }
function getTerrainHeightAtWorldPos() return 0 end
dofile(HERE .. "../../scripts/editor/RoadFinder.lua")
local RF = ADRoadFinder
local R0 = 60
local function kind(x, z)
    local r = math.sqrt(x * x + z * z)
    if math.abs(r - R0) <= 3.5 and z <= 5 then return RF.KIND_PAVED end
    if math.abs(x) <= 3.5 and z < -R0 and z > -R0 - 60 then return RF.KIND_PAVED end   -- side road (T)
    return RF.KIND_NONE
end
local cache = RF.newCache(kind, false)
local S = 224
RF.cacheRequest(cache, -112, -112, 111, 111)
while not RF.cacheStep(cache, 1e6) do end
local win = RF.buildWindow(function(a, b) return RF.cacheKind(cache, a, b) end, -112, -112, S, S, {})
local st = RF.findStretches(win, nil)
local isRoadOf = function(cls) return function(x, z) return kind(x, z) == RF.KIND_PAVED end end
local worst, fails = 0, 0
for _, s in ipairs(st) do
    local r = RF.refineStretch(s, isRoadOf, nil, nil)
    if r ~= nil then
        local P = r.pts
        for _, i in ipairs({ 1, 2, 3, #P - 2, #P - 1, #P }) do
            local p = P[i]
            -- off the middle of whichever road it is nearer
            local off = math.min(math.abs(math.sqrt(p.x * p.x + p.z * p.z) - R0),
                (p.z < -R0 + 4) and math.abs(p.x) or math.huge)
            worst = math.max(worst, off)
        end
        print(string.format("stretch %.0f m %s..%s: ends at (%.1f,%.1f) and (%.1f,%.1f)", r.len, r.startTag, r.endTag, P[1].x, P[1].z, P[#P].x, P[#P].z))
    end
end
local ok = worst <= 1.5   -- the test road stops dead at both ends; along it the line holds within 0.4 m
print(string.format("%s worst end off the middle %.2f m", ok and "ok  " or "FAIL", worst))
print(ok and "ALL PASS" or "1 FAILED")

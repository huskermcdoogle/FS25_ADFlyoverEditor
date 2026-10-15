-- A straight paved road with patchy paint (2026-10-12 screenshot: wavy lanes on a road with wet-look
-- patches). The laid centre line must stay straight. lua wavetest.lua
local HERE = (arg[0]:match("^(.*)[/\]") or ".") .. "/"
g_currentMission = { terrainRootNode = 1 }
function getTerrainHeightAtWorldPos() return 0 end
dofile(HERE .. "../../scripts/editor/RoadFinder.lua")
local RF = ADRoadFinder
math.randomseed(7)
-- patches: 1.5 m squares missing from the road at random, a quarter of them
local holes = {}
for i = -100, 100 do for j = -3, 3 do if math.random() < 0.25 then holes[i * 100 + j] = true end end end
local function kind(x, z)
    if math.abs(z) <= 3.5 and math.abs(x) <= 100 then
        if holes[math.floor(x / 1.5) * 100 + math.floor(z / 1.5)] then return RF.KIND_NONE end
        return RF.KIND_PAVED
    end
    return RF.KIND_NONE
end
local cache = RF.newCache(kind, false)
RF.cacheRequest(cache, -112, -112, 111, 111); while not RF.cacheStep(cache, 1e6) do end
local win = RF.buildWindow(function(a, b) return RF.cacheKind(cache, a, b) end, -112, -112, 224, 224, {})
local worst, n = 0, 0
for _, s in ipairs(RF.findStretches(win, nil)) do
    local r = RF.refineStretch(s, function() return function(x, z) return kind(x, z) == RF.KIND_PAVED end end, nil, nil)
    if r ~= nil then
        n = n + 1
        for i = 4, #r.pts - 3 do worst = math.max(worst, math.abs(r.pts[i].z)) end
        print(string.format("stretch %.0f m", r.len))
    end
end
local ok = n > 0 and worst <= 0.35
print(string.format("%s worst off the middle %.2f m", ok and "ok  " or "FAIL", worst))
print(ok and "ALL PASS" or "1 FAILED")

-- How far off the middle is the walker on the old narrow lane? Ruler: the map maker's own line
-- down that lane (spline993 and its twin 993R, averaged) and the asphalt read straight across.
--   lua centrestudy.lua <roadSplines.xml> [x z]   (walks from the mouse spot, as in game)
-- Prints, every ~10 m: the walk's offset from the map line and from the asphalt's middle,
-- + = right of the way the walk goes, - = left.
local HERE = (arg[0]:match("^(.*)[/\\]") or ".") .. "/"
local JH = HERE .. "../../../junction-rework-fec884/tools/junction-harness/"
local real = os.getenv
os.getenv = function(k) if k == "TERRAIN_DIR" then return JH .. "terrain_data/" end return real(k) end
g_currentMission = { terrainRootNode = 1 }; AutoDrive, CollisionFlag = {}, {}
dofile(HERE .. "terrain.lua"); dofile(HERE .. "../../scripts/editor/RoadFinder.lua")
local RF = ADRoadFinder
local sqrt, abs = math.sqrt, math.abs

local f = assert(io.open(arg[1], "rb")); local xml = f:read("*a"); f:close()
local byName = {}
for name, pts in xml:gmatch('<spline name="([^"]*)"[^>]-points="([^"]*)"') do
    local P = {}
    for x, z in pts:gmatch("(-?[%d%.]+),(-?[%d%.]+)") do P[#P + 1] = { x = tonumber(x), z = tonumber(z) } end
    byName[name] = P
end
local A, B = byName["spline993"], byName["spline993R"]
assert(A and B, "spline993/993R not in the dump")
local function nearestOn(P, x, z)
    local bd, bx, bz = math.huge, nil, nil
    for i = 1, #P - 1 do
        local a, b = P[i], P[i + 1]
        local dx, dz = b.x - a.x, b.z - a.z; local l2 = dx * dx + dz * dz
        local t = l2 > 0 and math.max(0, math.min(1, ((x - a.x) * dx + (z - a.z) * dz) / l2)) or 0
        local qx, qz = a.x + dx * t, a.z + dz * t
        local d = (x - qx) ^ 2 + (z - qz) ^ 2
        if d < bd then bd, bx, bz = d, qx, qz end
    end
    return bx, bz, sqrt(bd)
end
-- the map line's middle near (x,z): halfway between the two twins
local function mapMid(x, z)
    local ax, az, da = nearestOn(A, x, z)
    local bx, bz, db = nearestOn(B, x, z)
    return (ax + bx) / 2, (az + bz) / 2, math.min(da, db), sqrt((ax - bx) ^ 2 + (az - bz) ^ 2)
end
-- the asphalt straight across: middle of the paved run through the nearest paved cell, 0.1 m steps
local function asphaltMid(x, z, nx, nz)
    local function paved(o) local k = RF.groundKindAt(x + nx * o, z + nz * o) return k == RF.KIND_PAVED or (os.getenv("WITHG") and k == RF.KIND_GRAVEL) end
    local o0 = nil
    for k = 0, 40 do
        for _, s in ipairs({ 1, -1 }) do
            if o0 == nil and paved(s * k * 0.1) then o0 = s * k * 0.1 end
        end
    end
    if o0 == nil then return nil end
    local lo, hi = o0, o0
    while lo > -6 and paved(lo - 0.1) do lo = lo - 0.1 end
    while hi < 6 and paved(hi + 0.1) do hi = hi + 0.1 end
    return (lo + hi) / 2, hi - lo
end

local isRoadOf = function(cls)
    if cls == "paved" then return function(x, z) return RF.groundKindAt(x, z) == RF.KIND_PAVED end end
    return function(x, z) local k = RF.groundKindAt(x, z) return k == RF.KIND_GRAVEL or k == RF.KIND_DIRT end
end
local isStopOf = function(cls) if cls == "track" then return function(x, z) return RF.groundKindAt(x, z) == RF.KIND_PAVED end end end
local sx, sz = tonumber(arg[2] or "-824.1"), tonumber(arg[3] or "332.4")
local r = RF.walkFrom(isRoadOf, sx, sz, { "paved", "track" }, isStopOf)
print(string.format("walk from (%.1f, %.1f): %.0f m %s..%s, %d points", sx, sz, r.len or 0, tostring(r.startTag), tostring(r.endTag), #r.pts))
local P = r.pts
local sumMap, sumAbsMap, nMap, worstMap = 0, 0, 0, 0
local sumAs, sumAbsAs, nAs = 0, 0, 0
local sumMA, nMA = 0, 0
local acc, nextPrint = 0, 0
for i = 1, #P do
    if i > 1 then acc = acc + sqrt((P[i].x - P[i - 1].x) ^ 2 + (P[i].z - P[i - 1].z) ^ 2) end
    local a, b = P[math.max(1, i - 1)], P[math.min(#P, i + 1)]
    local hx, hz = b.x - a.x, b.z - a.z; local hl = sqrt(hx * hx + hz * hz)
    if hl > 0 then
        hx, hz = hx / hl, hz / hl
        -- right of travel: FS25 x east, z south; heading (hx,hz), right = (-hz, hx)
        local rx, rz = -hz, hx
        local mx, mz, md, twin = mapMid(P[i].x, P[i].z)
        local offMap = nil
        if md < 4 then
            offMap = (P[i].x - mx) * rx + (P[i].z - mz) * rz
            sumMap, sumAbsMap, nMap = sumMap + offMap, sumAbsMap + abs(offMap), nMap + 1
            worstMap = math.max(worstMap, abs(offMap))
        end
        local am, aw = asphaltMid(P[i].x, P[i].z, rx, rz)
        local offAs = am and -am or nil
        if offAs then sumAs, sumAbsAs, nAs = sumAs + offAs, sumAbsAs + abs(offAs), nAs + 1 end
        local mapVsAs = nil
        if offMap and am then
            local am2 = asphaltMid(mx, mz, rx, rz)
            if am2 then mapVsAs = -am2; sumMA, nMA = sumMA + mapVsAs, nMA + 1 end
        end
        if acc >= nextPrint then
            nextPrint = nextPrint + 10
            print(string.format("%5.0f m (%7.1f,%6.1f)  walk vs map line %s   walk vs asphalt middle %s (asphalt %s m)   map line vs asphalt %s",
                acc, P[i].x, P[i].z,
                offMap and string.format("%+5.2f", offMap) or "  -  ",
                offAs and string.format("%+5.2f", offAs) or "  -  ", aw and string.format("%.1f", aw) or "-",
                mapVsAs and string.format("%+5.2f", mapVsAs) or "  -  "))
        end
    end
end
print(string.format("walk vs map line: mean %+.2f (side bias), mean size %.2f, worst %.2f over %d points",
    sumMap / math.max(1, nMap), sumAbsMap / math.max(1, nMap), worstMap, nMap))
print(string.format("walk vs asphalt middle: mean %+.2f, mean size %.2f over %d points", sumAs / math.max(1, nAs), sumAbsAs / math.max(1, nAs), nAs))
print(string.format("map line vs asphalt middle: mean %+.2f over %d points", sumMA / math.max(1, nMA), nMA))
-- the same score as the game logs (RF.splineScore)
local list = {}
for name, len, pts in xml:gmatch('<spline name="([^"]*)" length="([^"]*)" points="([^"]*)"') do
    local Q = {}
    for x, z in pts:gmatch("(-?[%d%.]+),(-?[%d%.]+)") do Q[#Q + 1] = { x = tonumber(x), z = tonumber(z) } end
    list[#list + 1] = { name = name, group = "", len = tonumber(len), pts = Q }
end
local sc = RF.splineScore(RF.indexSplines(list), P, 4)
print(sc and string.format("game's score: %s leans %+.2f, off %.2f, worst %.2f over %d", sc.sp.name, sc.lean, sc.mean, sc.worst, sc.n) or "game's score: none")

-- Real ground for the offline harness: the map's paint, the game's AI drive-cost map, the
-- savegame's heightmap and the map's field outlines, answering the same engine calls the editor
-- makes in game. Loaded by harness.lua ONLY when TERRAIN=1, so every other run is untouched.
--
-- Without it the harness sees road everywhere, flat ground at height 0 and no fields - fine for
-- the clear's wiring, useless for anything that grades or fits to the ground. The data comes from
-- make_terrain.py (run it once; it writes terrain_data/). Every grid is 1 m, column = x + 1024,
-- row = z + 1024, the layout the game's own files use.
--
-- What is NOT here: road meshes, bridges, signs, fences, trees. The ray below hits only the
-- terrain, so the editor's road-mesh branch (ROAD collision group) never fires offline. On
-- Riverbend that branch almost never fires in game either (road meshes there are decals with no
-- collision), so the paint is the answer the game gives too.

local T = {}
local DIR = os.getenv("TERRAIN_DIR") or "terrain_data/"
if DIR:sub(-1) ~= "/" and DIR:sub(-1) ~= "\\" then DIR = DIR .. "/" end

local function slurp(name, want)
    local f = io.open(DIR .. name, "rb")
    if f == nil then
        error("TERRAIN=1 but " .. DIR .. name .. " is missing - run: python make_terrain.py", 0)
    end
    local s = f:read("*a")
    f:close()
    if want ~= nil and #s ~= want then
        error(DIR .. name .. " is " .. #s .. " bytes, expected " .. want .. " - rerun make_terrain.py", 0)
    end
    return s
end

local META = dofile(DIR .. "meta.lua")
local N = META.size                 -- 2048 paint / cost cells a side
local NH = META.heightSize          -- 2049 height posts a side (one more: they are the corners)
local HSCALE = META.heightScale / 65535
local PAINT = slurp("paint.bin", N * N)
local COST = slurp("cost.bin", N * N)
local HEIGHT = slurp("height.bin", NH * NH * 2)
local LAYERS = dofile(DIR .. "layers.lua")
local FIELDS = dofile(DIR .. "fields.lua")
local byte, floor, sqrt = string.byte, math.floor, math.sqrt

T.layers = LAYERS
T.meta = META

-- The cell under (x, z). Off the map clamps to the edge, as the engine's terrain does, rather than
-- erroring: nothing the harness loads lies off the map, and a probe that wanders there should not
-- take the run down.
local function cell(x, z)
    local i, j = floor(x + N / 2), floor(z + N / 2)
    if i < 0 then i = 0 elseif i > N - 1 then i = N - 1 end
    if j < 0 then j = 0 elseif j > N - 1 then j = N - 1 end
    return j * N + i + 1
end

--- The main paint layer index (0-based, the type cache's own numbering) at (x, z).
function T.paintAt(x, z) return byte(PAINT, cell(x, z)) end

--- The raw drive-cost byte at (x, z): 17 x (layer cost - 1) + penalty; 255 = blocked.
function T.costAt(x, z) return byte(COST, cell(x, z)) end

local function post(i, j)
    if i < 0 then i = 0 elseif i > NH - 1 then i = NH - 1 end
    if j < 0 then j = 0 elseif j > NH - 1 then j = NH - 1 end
    local k = (j * NH + i) * 2 + 1
    local hi, lo = byte(HEIGHT, k, k + 1)
    return (hi * 256 + lo) * HSCALE
end

--- Terrain height at (x, z), bilinear between the four height posts round it - the same sum the
--- Python reader (hmap.py) does, so the two agree to rounding.
function T.heightAt(x, z)
    local fx, fz = x + N / 2, z + N / 2
    local i, j = floor(fx), floor(fz)
    local tx, tz = fx - i, fz - j
    return post(i, j) * (1 - tx) * (1 - tz) + post(i + 1, j) * tx * (1 - tz)
        + post(i, j + 1) * (1 - tx) * tz + post(i + 1, j + 1) * tx * tz
end

--- Unit up-normal at (x, z) from the height's slope half a metre either side.
function T.normalAt(x, z)
    local d = 0.5
    local sx = (T.heightAt(x + d, z) - T.heightAt(x - d, z)) / (2 * d)
    local sz = (T.heightAt(x, z + d) - T.heightAt(x, z - d)) / (2 * d)
    local l = sqrt(sx * sx + 1 + sz * sz)
    return -sx / l, 1 / l, -sz / l
end

-- Field outlines, indexed by 32 m square so a lookup tests only the few outlines near it.
local FGRID = {}
for k, P in ipairs(FIELDS) do
    local x0, x1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
    for n = 1, #P, 2 do
        x0, x1 = math.min(x0, P[n]), math.max(x1, P[n])
        z0, z1 = math.min(z0, P[n + 1]), math.max(z1, P[n + 1])
    end
    for gx = floor(x0 / 32), floor(x1 / 32) do
        for gz = floor(z0 / 32), floor(z1 / 32) do
            local key = gx * 65536 + gz
            FGRID[key] = FGRID[key] or {}
            table.insert(FGRID[key], P)
        end
    end
end

local function inPoly(P, x, z)
    local c, m = false, #P
    local xj, zj = P[m - 1], P[m]
    for n = 1, m, 2 do
        local xi, zi = P[n], P[n + 1]
        if (zi > z) ~= (zj > z) and x < (xj - xi) * (z - zi) / (zj - zi) + xi then c = not c end
        xj, zj = xi, zi
    end
    return c
end

--- Is (x, z) inside one of the map's field outlines? A stand-in for the game's field layer: the
--- outline is the field as the map maker drew it, which is where the game paints field ground.
function T.fieldAt(x, z)
    for _, P in ipairs(FGRID[floor(x / 32) * 65536 + floor(z / 32)] or {}) do
        if inPoly(P, x, z) then return true end
    end
    return false
end

-- ------------------------------------------------------------------- the engine calls, as in game
local TERRAIN_NODE = g_currentMission.terrainRootNode
local NAV_MAP = 7001               -- any non-zero id: the editor only passes it back
local DETAIL_ID = 7002

function getTerrainHeightAtWorldPos(_, x, _, z) return T.heightAt(x, z) end
function getTerrainNormalAtWorldPos(_, x, _, z) return T.normalAt(x, z) end

--- r, g, b, softness, materialId of the main paint at the spot, as WheelPhysics reads it. The
--- four flags the game passes pick which of those it wants; offline all are always returned.
function getTerrainAttributesAtWorldPos(_, x, _, z)
    local L = LAYERS[T.paintAt(x, z) + 1]
    return L.r, L.g, L.b, L.softness, L.materialId
end

g_currentMission.aiSystem = g_currentMission.aiSystem or {}
g_currentMission.aiSystem.navigationMap = NAV_MAP
function g_currentMission.aiSystem:getNavigationMap() return self.navigationMap end
--- cost, isBlocking. The cost is the map file's byte as it is: the editor's threshold
--- (ROAD_DRIVE_COST_MAX) is on that same 0-255 scale.
function getVehicleNavigationMapCostAtWorldPos(map, x, _, z)
    if map ~= NAV_MAP then return nil end
    local c = T.costAt(x, z)
    return c, c == 255
end

g_currentMission.terrainDetailId = DETAIL_ID
--- Non-zero on field ground. Only the terrain-detail layer answers; anything else reads 0, as an
--- empty density map would.
function getDensityAtWorldPos(id, x, _, z)
    if id == DETAIL_ID and T.fieldAt(x, z) then return 1 end
    return 0
end

--- AutoDrive's own height read raycasts the ground; offline the ground is the terrain.
function AutoDrive:getTerrainHeightAtWorldPos(x, z) return T.heightAt(x, z) end

-- The ray: a terrain hit only. It is what lets the editor's road check get past its "no physics,
-- call it road" guard and on to the paint. Collision bits from shared/collisionMaskFlags.xml;
-- added only if the harness stub lacks them, and the existing stub values are left alone.
CollisionFlag.TERRAIN = CollisionFlag.TERRAIN or 256        -- bit 8
CollisionFlag.ROAD = CollisionFlag.ROAD or 8192             -- bit 13
CollisionFlag.VEHICLE = CollisionFlag.VEHICLE or 65536      -- bit 16

if os.getenv("TERRAIN_RAY") ~= "0" then
    --- raycastClosest(x, y, z, dx, dy, dz, maxDistance, callbackName, target, mask): calls back
    --- target[callbackName](target, hitId, hx, hy, hz, distance) with the first terrain crossing,
    --- or not at all. Marched in 0.25 m steps and then halved down to a millimetre - plenty for
    --- the straight-down rays the editor casts, and still right for a slanted one.
    function raycastClosest(x, y, z, dx, dy, dz, maxDist, cbName, target, mask)
        if mask ~= nil and floor(mask / CollisionFlag.TERRAIN) % 2 == 0 then return end
        local l = sqrt(dx * dx + dy * dy + dz * dz)
        if l < 1e-9 or maxDist == nil or maxDist <= 0 then return end
        dx, dy, dz = dx / l, dy / l, dz / l
        local function above(t) return (y + dy * t) - T.heightAt(x + dx * t, z + dz * t) end
        if above(0) < 0 then return end           -- starting underground: the engine sees no face
        local t0, step, hit = 0, 0.25, nil
        while t0 < maxDist do
            local t1 = math.min(t0 + step, maxDist)
            if above(t1) <= 0 then hit = t1 break end
            t0 = t1
        end
        if hit == nil then return end
        local a, b = t0, hit
        while b - a > 0.001 do
            local m = (a + b) / 2
            if above(m) <= 0 then b = m else a = m end
        end
        local hx, hz = x + dx * b, z + dz * b
        local cb = target ~= nil and target[cbName] or nil
        if cb ~= nil then cb(target, TERRAIN_NODE, hx, T.heightAt(hx, hz), hz, b) end
    end
end

-- AREA=<roadArea_X_Z.xml> (saved in game by the road runs detection view's "save this area"): inside
-- that square the ground is what the GAME read there (kinds every 0.25 m, fields); outside it, the
-- old harness map. The harness map is an old save at 1 m and did not match the game (2026-10-13).
-- Several files: AREA=a.xml;b.xml (the first that has a spot wins). AREAONLY=1: outside them the
-- ground is no road (no harness map), for cases that must stand on the game's own reading alone.
-- A case file (roadCases/track_N.xml) is a painted save with a <middle> the user drew.
local function loadArea(file)
    local f = assert(io.open(file, "rb"))
    local xml = f:read("*a")
    f:close()
    local A = { xml = xml }
    local tileSize = tonumber(xml:match('tile="([^"]+)"'))
    local ast = tonumber(xml:match('step="([^"]+)"')) or 0.25
    if tileSize ~= nil then
        -- painted saves (roadPaint_N.xml, track_N.xml): one <tile x0 z0 k> per square, k row by row
        local tiles, count = {}, 0
        for tx0, tz0, k in xml:gmatch('<tile x0="([^"]+)" z0="([^"]+)" k="([^"]*)"') do
            tiles[math.floor(tonumber(tx0) / tileSize + 0.5) * 100003 + math.floor(tonumber(tz0) / tileSize + 0.5)] =
                { x0 = tonumber(tx0), z0 = tonumber(tz0), k = k }
            count = count + 1
        end
        local per = math.floor(tileSize / ast + 0.5)
        A.tiles, A.tileSize, A.count = tiles, tileSize, count
        function A.char(x, z)
            local t = tiles[math.floor(x / tileSize) * 100003 + math.floor(z / tileSize)]
            if t == nil then return nil end
            local i, j = math.floor((x - t.x0) / ast), math.floor((z - t.z0) / ast)
            if i < 0 or j < 0 or i >= per or j >= per then return nil end
            return t.k:sub(j * per + i + 1, j * per + i + 1)
        end
        if not os.getenv("AREAQUIET") then
            print(string.format("area: %d painted squares of %g m at %.2f m", count, tileSize, ast))
        end
        return A
    end
    -- one square (roadArea_X_Z.xml)
    local ax0 = tonumber(xml:match('x0="([^"]+)"'))
    local az0 = tonumber(xml:match('z0="([^"]+)"'))
    local an = tonumber(xml:match(' n="([^"]+)"'))
    local rows = {}
    for k in xml:gmatch('<row k="([^"]*)"') do rows[#rows + 1] = k end
    A.x0, A.z0, A.step, A.n, A.rows = ax0, az0, ast, an, rows
    A.mouse = { x = tonumber(xml:match('<mouse x="([^"]+)"')), z = tonumber(xml:match('<mouse [^>]*z="([^"]+)"')) }
    A.line = xml:match('<line pts="([^"]*)"')
    A.walk = xml:match('<walk pts="([^"]*)"')
    function A.char(x, z)
        local i = math.floor((x - ax0) / ast)
        local j = math.floor((z - az0) / ast)
        if i < 0 or j < 0 or i >= an or j >= an then return nil end
        local row = rows[j + 1]
        return row and row:sub(i + 1, i + 1) or nil
    end
    if not os.getenv("AREAQUIET") then
        print(string.format("area: %d x %d at %.2f m from (%.0f, %.0f)", an, an, ast, ax0, az0))
    end
    return A
end

if os.getenv("AREA") then
    local areas = {}
    for file in os.getenv("AREA"):gmatch("[^;]+") do areas[#areas + 1] = loadArea(file) end
    T.area = areas[1]           -- the first file's own fields (mouse, line, walk), as before
    T.areas = areas
    local only = os.getenv("AREAONLY") ~= nil
    local function areaChar(x, z)
        for _, A in ipairs(areas) do
            local c = A.char(x, z)
            if c ~= nil then return c end
        end
        if only then return "." end
        return nil
    end
    -- DECALS="x,z,r;..." (2026-10-15 probe): ground under a concrete decal's circle read as paved;
    -- DECALMODE=all: everything there (grass too), otherwise only gravel and dirt
    local decals = {}
    for x, z, r in (os.getenv("DECALS") or ""):gmatch("([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)") do
        decals[#decals + 1] = { x = tonumber(x), z = tonumber(z), r = tonumber(r) }
    end
    if #decals > 0 then
        local plain = areaChar
        local all = os.getenv("DECALMODE") == "all"
        areaChar = function(x, z)
            local c = plain(x, z)
            for _, d in ipairs(decals) do
                if (x - d.x) ^ 2 + (z - d.z) ^ 2 <= d.r * d.r then
                    if c == "g" or c == "d" or (all and c == ".") then return "p" end
                end
            end
            return c
        end
    end
    T.areaChar = areaChar
    local MAT = { d = 1, g = 6, p = 7 }
    local baseAttr, baseDensity, baseCost = getTerrainAttributesAtWorldPos, getDensityAtWorldPos, getVehicleNavigationMapCostAtWorldPos
    function getTerrainAttributesAtWorldPos(t, x, y, z, ...)
        local c = areaChar(x, z)
        if c == nil then return baseAttr(t, x, y, z, ...) end
        return 0, 0, 0, 0, MAT[c] or 2           -- 2: a material the editor reads as no road
    end
    function getDensityAtWorldPos(id, x, y, z)
        local c = areaChar(x, z)
        if c == nil then return baseDensity(id, x, y, z) end
        return (id == DETAIL_ID and c == "F") and 1 or 0
    end
    function getVehicleNavigationMapCostAtWorldPos(map, x, y, z)
        local c = areaChar(x, z)
        if c == nil then return baseCost(map, x, y, z) end
        return 0, false                        -- the game already left rock out of 'p'
    end
end

TERRAIN = T
return T

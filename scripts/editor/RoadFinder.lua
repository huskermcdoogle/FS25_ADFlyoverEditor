--[[
Road finder: reads the map's ground paint into a 1 m grid, thins each road down to its centre line,
finds where roads fork, and splits the lines into STRETCHES that have no AutoDrive path along them.
The road runs tool (RoadRunsTool.lua) lights these up and lays lanes on the ones the user picks.

Pure Lua with no editor state, so the same code runs in game and in the offline bench
(tools/road-runs/bench.lua) against the real map's paint. The only engine reads are in
ADRoadFinder.groundKindAt; the bench answers them from the map's own files.

How a road is found (all on a square window of 1 m cells round where the user is looking):
  1. Ground kind per cell: paved (asphalt and concrete), gravel, dirt, or nothing. Two road classes
     are thinned apart - PAVED, and TRACK (gravel + dirt) - because every paved road on Riverbend has
     a brown gravel shoulder: thinned together, the shoulder would widen the road and shift its lanes.
  2. Clean-up: small holes in a road are filled, small specks of road paint are dropped.
  3. Thinning (Zhang-Suen) leaves a one-cell centre line; the distance to the road's edge at each
     centre cell gives the road's width there.
  4. The centre lines are traced into a graph: forks where three or more lines meet, ends, and lines
     that run off the window. Short spurs (edge noise) are pruned; forks closer than a road width apart
     are one fork.
  5. Track lines that only follow a paved road's shoulder are dropped; a track that ends on a paved
     road makes a fork on that road, so the paved stretch stops short there too.
  6. Each line is compared against the AutoDrive network: where a path already runs along it, it is
     covered; what is left, long enough, is a stretch.
]]

ADRoadFinder = ADRoadFinder or {}
local RF = ADRoadFinder

local floor, sqrt, abs, max, min = math.floor, math.sqrt, math.abs, math.max, math.min
local atan2, cos, sin, pi = math.atan2, math.cos, math.sin, math.pi

RF.KIND_NONE, RF.KIND_DIRT, RF.KIND_GRAVEL, RF.KIND_PAVED = 0, 1, 2, 3
RF.KIND_NAMES = { [1] = "dirt", [2] = "gravel", [3] = "paved" }

RF.TILE = 32                     -- cells a side in one cached tile of ground kinds
RF.MIN_SPECK = 40                -- road paint patches smaller than this (cells) are not roads
RF.MAX_HOLE = 30                 -- holes in road paint up to this many cells are filled
RF.MAX_ROAD_WIDTH = { paved = 16, track = 11 }   -- wider than this is a yard or a lot, not a road
RF.CLOSE_RADIUS = { paved = 1, track = 2 }     -- gaps this wide (each side) are closed: wheel ruts, seams
RF.MIN_TRACK_WIDTH = 2.0         -- narrower track lines are shoulder strips or paint seams
RF.MIN_PAVED_WIDTH = 3.0         -- narrower paved lines are kerbs, footpaths or paint seams
RF.SHOULDER_DIST = 3.5           -- a track line this close to paved road is that road's shoulder
RF.BUBBLE_MAX = 60               -- two lines between the same two forks, both shorter than this, are one road
RF.SPUR_MIN = 10                 -- dead-end spurs shorter than this (or the road's width) are noise
RF.MIN_STRETCH = 15              -- uncovered stretches shorter than this are not offered
RF.MIN_LOOSE = 40                -- a line with no fork at either end shorter than this is a paint scrap
RF.COVER_SMOOTH = 8              -- covered/uncovered runs shorter than this take their neighbours' side
RF.COVER_ANGLE = 35              -- a path within this many degrees of the road's line counts as along it
RF.TRACK_JOIN = 4                -- a track end this far past a paved road's edge makes a fork on it

-- --------------------------------------------------------------------------------- ground kinds

-- Material ids are tyre-SOUND classes (see docs/junction-tool/03-data-sources.md on the junction
-- branch): 7 = asphalt, concrete AND rock; 6 = gravel; 1 = dirt, which is also the mud under fields.
local MATERIAL_KIND = { [7] = RF.KIND_PAVED, [6] = RF.KIND_GRAVEL, [1] = RF.KIND_DIRT }
local ROCK_COST_MIN = 150        -- drive-cost map, 0-255 scale: asphalt/concrete ~51, rock >= 186

local function navigationCost(x, y, z)
    local ai = g_currentMission ~= nil and g_currentMission.aiSystem or nil
    if type(ai) ~= "table" or getVehicleNavigationMapCostAtWorldPos == nil then return nil end
    local navMap = ai.navigationMap
    if navMap == nil or navMap == 0 then return nil end
    local ok, cost, blocked = pcall(getVehicleNavigationMapCostAtWorldPos, navMap, x, y, z)
    if not ok or type(cost) ~= "number" then return nil end
    local limit = ROCK_COST_MIN
    if AISystem ~= nil and type(AISystem.COSTMAP_MAX_VALUE) == "number" and AISystem.COSTMAP_MAX_VALUE > 0 then
        limit = ROCK_COST_MIN * AISystem.COSTMAP_MAX_VALUE / 255
    end
    return cost, blocked == true, limit
end

local function fieldAt(x, z)
    local detail = g_currentMission ~= nil and g_currentMission.terrainDetailId or nil
    if detail == nil or getDensityAtWorldPos == nil then return false end
    local ok, density = pcall(getDensityAtWorldPos, detail, x, 0, z)
    return ok and type(density) == "number" and density ~= 0
end

-- THE MAP'S EDGE. The game crashed outright (no Lua error) as the read square slid past the map's
-- north-west corner (2026-10-12): terrain reads outside the terrain are not safe. Every ground read,
-- ray and probe asks onMap first.
local mapHalfFor, mapHalfVal = nil, nil
function RF.mapHalf()
    local terrain = g_currentMission ~= nil and g_currentMission.terrainRootNode or nil
    if mapHalfVal ~= nil and mapHalfFor == terrain then return mapHalfVal end
    local size = nil
    if terrain ~= nil and getTerrainSize ~= nil then
        local ok, sz = pcall(getTerrainSize, terrain)
        if ok and type(sz) == "number" and sz > 0 then size = sz end
    end
    if size == nil and g_currentMission ~= nil and type(g_currentMission.terrainSize) == "number" then
        size = g_currentMission.terrainSize
    end
    mapHalfFor, mapHalfVal = terrain, (size or 2048) / 2 - 2
    return mapHalfVal
end

--- Is (x, z) safely inside the map (2 m in from the edge)?
function RF.onMap(x, z)
    local h = RF.mapHalf()
    return x == x and z == z and x > -h and x < h and z > -h and z < h
end

RF.noRockCheck = false           -- set when the drive-cost map is missing (not the host): rock reads paved

-- FIELD OUTLINES. The field layer only marks worked ground, so the unworked strip along a fence inside
-- a field read as a dirt track (2026-10-12 game test). Inside the map's own field outline is never road:
-- the farmland under the spot, its field, that field's outline (cached per field).
-- The outlines come from g_fieldManager.fields: each field's polygonPoints are nodes on the map
-- (Field.lua:75-86). Read once, indexed in 64 m squares. (The first try went through
-- farmland:getField(), which FS25 does not have - the check silently did nothing in game.)
local fieldIndex, fieldIndexFor = nil, nil
local FIELD_CELL = 64
local function buildFieldIndex()
    local fm = g_fieldManager
    fieldIndex = {}
    if fm == nil or type(fm.fields) ~= "table" or getWorldTranslation == nil then return end
    for _, field in pairs(fm.fields) do
        local nodes = type(field) == "table" and field.polygonPoints or nil
        if type(nodes) == "table" and #nodes >= 3 then
            local poly = { x0 = math.huge, x1 = -math.huge, z0 = math.huge, z1 = -math.huge }
            for _, node in ipairs(nodes) do
                local ok, x, _, z = pcall(getWorldTranslation, node)
                if ok and type(x) == "number" and type(z) == "number" then
                    poly[#poly + 1] = x
                    poly[#poly + 1] = z
                    poly.x0, poly.x1 = min(poly.x0, x), max(poly.x1, x)
                    poly.z0, poly.z1 = min(poly.z0, z), max(poly.z1, z)
                end
            end
            if #poly >= 6 then
                for gx = floor(poly.x0 / FIELD_CELL), floor(poly.x1 / FIELD_CELL) do
                    for gz = floor(poly.z0 / FIELD_CELL), floor(poly.z1 / FIELD_CELL) do
                        local k = gx * 100003 + gz
                        fieldIndex[k] = fieldIndex[k] or {}
                        table.insert(fieldIndex[k], poly)
                    end
                end
            end
        end
    end
end
local function insideFieldOutline(x, z)
    local fm = g_fieldManager
    if fieldIndex == nil or fieldIndexFor ~= fm then
        fieldIndexFor = fm
        local ok = pcall(buildFieldIndex)
        if not ok then fieldIndex = {} end
    end
    local list = fieldIndex[floor(x / FIELD_CELL) * 100003 + floor(z / FIELD_CELL)]
    if list == nil then return false end
    for _, poly in ipairs(list) do
        if x >= poly.x0 and x <= poly.x1 and z >= poly.z0 and z <= poly.z1 then
            local inside, m = false, #poly
            local xj, zj = poly[m - 1], poly[m]
            for n = 1, m, 2 do
                local xi, zi = poly[n], poly[n + 1]
                if (zi > z) ~= (zj > z) and x < (xj - xi) * (z - zi) / (zj - zi) + xi then inside = not inside end
                xj, zj = xi, zi
            end
            if inside then return true end
        end
    end
    return false
end
RF.insideFieldOutline = insideFieldOutline

--- Field ground: worked ground in the field layer, or inside a map field outline.
function RF.isFieldAt(x, z)
    if not RF.onMap(x, z) then return false end
    return fieldAt(x, z) or insideFieldOutline(x, z)
end

--- The ground kind at (x, z): KIND_PAVED / GRAVEL / DIRT, or KIND_NONE for anything else (grass,
--- field, rock, sand, water). One paint read, plus a field read on road paint and a drive-cost read
--- on asphalt-sound paint.
function RF.groundKindAt(x, z)
    local terrain = g_currentMission ~= nil and g_currentMission.terrainRootNode or nil
    if terrain == nil or not RF.onMap(x, z) then return RF.KIND_NONE end
    local y = getTerrainHeightAtWorldPos(terrain, x, 0, z) or 0
    local ok, _, _, _, _, mat = pcall(getTerrainAttributesAtWorldPos, terrain, x, y, z, true, true, true, true, false)
    if not ok or type(mat) ~= "number" then return RF.KIND_NONE end
    local kind = MATERIAL_KIND[floor(mat + 0.5)] or RF.KIND_NONE
    if kind == RF.KIND_NONE then return kind end
    if fieldAt(x, z) or insideFieldOutline(x, z) then return RF.KIND_NONE end
    if kind == RF.KIND_PAVED then
        local cost, blocked, limit = navigationCost(x, y, z)
        if cost == nil then
            RF.noRockCheck = true
        elseif not blocked and cost >= limit then
            return RF.KIND_NONE                    -- rock: asphalt's sound, rock's drive cost
        end
    end
    return kind
end

-- --------------------------------------------------------------------------------- road meshes

-- BRIDGES AND RAMPS. Plain roads on Riverbend are paint (decals with no collision), but bridge decks,
-- ramps, flyovers and level crossings are meshes in the ROAD collision group (bit 13, see
-- docs/junction-tool/03b-data-sources-reference.md on the junction branch). Under a bridge the paint
-- is the river, so paint alone ends every road at the water. A ray cast straight down that only hits
-- the ROAD group finds the deck and its height.
--   elevated (more than DECK_MIN_HEIGHT above the terrain): a DECK cell, its own road class, so a
--     flyover never makes a false crossing with the road under it;
--   at ground level (a ramp's foot, a level crossing): counts as paved road.
RF.DECK_MIN_HEIGHT = 1.0
RF.DECK_RAY_UP = 40              -- rays start this far above the terrain (taller bridges are missed)
RF.DECK_COARSE = 4               -- a tile is first probed on this grid; a hit reads it (and its neighbours) at 1 m
RF.DECK_JOIN = 10               -- a deck end this close to a road end on the ground carries on into it (thinning pulls both ends back about half a road width)

local RoadMeshRay = { hitY = nil }
function RoadMeshRay.cb(self, hitId, x, y, z, distance)
    if y ~= nil and (self.hitY == nil or y > self.hitY) then self.hitY = y end
    return true
end

--- The top of a road mesh at (x, z): its height and whether it is raised (a deck), or nil.
function RF.roadMeshAt(x, z)
    local terrain = g_currentMission ~= nil and g_currentMission.terrainRootNode or nil
    if terrain == nil or raycastClosest == nil or CollisionFlag == nil or CollisionFlag.ROAD == nil then return nil end
    if not RF.onMap(x, z) then return nil end
    local ty = getTerrainHeightAtWorldPos(terrain, x, 0, z) or 0
    RoadMeshRay.hitY = nil
    local ok = pcall(raycastClosest, x, ty + RF.DECK_RAY_UP, z, 0, -1, 0, RF.DECK_RAY_UP + 5, "cb", RoadMeshRay, CollisionFlag.ROAD)
    if not ok or RoadMeshRay.hitY == nil then return nil end
    return RoadMeshRay.hitY, (RoadMeshRay.hitY - ty) > RF.DECK_MIN_HEIGHT
end

-- --------------------------------------------------------------------------------- tile cache

--- A cache of ground kinds in 32 m tiles, filled a budget of cells at a time so a big window never
--- stalls a frame. `classify(x, z)` defaults to groundKindAt, `meshAt(x, z)` to roadMeshAt (pass
--- false for none); the bench passes its own.
function RF.newCache(classify, meshAt)
    if meshAt == nil then meshAt = RF.roadMeshAt end
    return { tiles = {}, queue = {}, queued = {}, classify = classify or RF.groundKindAt, cursor = nil,
        meshAt = meshAt or nil, decks = {}, deckNeed = {}, deckDone = {}, deckQueued = {} }
end

local function tileKey(tx, tz) return tx * 100003 + tz end

--- Queue every tile under cells [ix0, ix1] x [iz0, iz1] that is not read yet (paint, then road
--- meshes where the coarse probe found any). Returns how many cells are still to read.
function RF.cacheRequest(cache, ix0, iz0, ix1, iz1)
    local T = RF.TILE
    local missing = 0
    for tz = floor(iz0 / T), floor(iz1 / T) do
        for tx = floor(ix0 / T), floor(ix1 / T) do
            local k = tileKey(tx, tz)
            if cache.tiles[k] == nil then
                missing = missing + T * T
                if not cache.queued[k] then
                    cache.queued[k] = true
                    cache.queue[#cache.queue + 1] = { tx = tx, tz = tz, k = k }
                end
            elseif cache.deckNeed[k] and not cache.deckDone[k] then
                missing = missing + T * T
                if not cache.deckQueued[k] then
                    cache.deckQueued[k] = true
                    cache.queue[#cache.queue + 1] = { tx = tx, tz = tz, k = k, deck = true }
                end
            end
        end
    end
    return missing
end

--- Read up to `budget` cells of queued tiles. Returns true when the queue is empty.
function RF.cacheStep(cache, budget)
    local T = RF.TILE
    local classify, meshAt = cache.classify, cache.meshAt
    local C = RF.DECK_COARSE
    while budget > 0 do
        local job = cache.cursor
        if job == nil then
            job = table.remove(cache.queue, 1)
            if job == nil then return true end
            job.n = 0
            if job.deck then job.ys = {} else job.cells = {} end
            cache.cursor = job
        end
        while job.n < T * T and budget > 0 do
            local n = job.n
            local c, r = n % T, floor(n / T)
            local x, z = job.tx * T + c + 0.5, job.tz * T + r + 0.5
            if job.deck then
                -- the 1 m read of a tile with a road mesh in or beside it
                local y, raised = meshAt(x, z)
                if y ~= nil then
                    if raised then job.ys[n + 1] = y
                    elseif cache.tiles[job.k] ~= nil and cache.tiles[job.k][n + 1] == RF.KIND_NONE then
                        cache.tiles[job.k][n + 1] = RF.KIND_PAVED      -- a ramp foot or level crossing
                    end
                end
            else
                job.cells[n + 1] = classify(x, z)
                if meshAt and c % C == floor(C / 2) and r % C == floor(C / 2) and not job.meshHit then
                    if meshAt(x, z) ~= nil then job.meshHit = true end
                end
            end
            job.n = n + 1
            budget = budget - 1
        end
        if job.n >= T * T then
            if job.deck then
                cache.decks[job.k] = job.ys
                cache.deckDone[job.k] = true
                cache.deckQueued[job.k] = nil
            else
                cache.tiles[job.k] = job.cells
                cache.queued[job.k] = nil
                if job.meshHit then
                    -- the mesh may reach into the neighbours without a coarse hit there
                    for dz = -1, 1 do
                        for dx = -1, 1 do cache.deckNeed[tileKey(job.tx + dx, job.tz + dz)] = true end
                    end
                end
            end
            cache.cursor = nil
        end
    end
    return #cache.queue == 0 and cache.cursor == nil
end

--- Kind at cell (ix, iz), or nil if its tile is not cached.
function RF.cacheKind(cache, ix, iz)
    local T = RF.TILE
    local tx, tz = floor(ix / T), floor(iz / T)
    local cells = cache.tiles[tileKey(tx, tz)]
    if cells == nil then return nil end
    return cells[(iz - tz * T) * T + (ix - tx * T) + 1]
end

--- Deck height at cell (ix, iz), or nil (no raised road mesh there, or not read).
function RF.cacheDeck(cache, ix, iz)
    local T = RF.TILE
    local tx, tz = floor(ix / T), floor(iz / T)
    local ys = cache.decks[tileKey(tx, tz)]
    if ys == nil then return nil end
    return ys[(iz - tz * T) * T + (ix - tx * T) + 1]
end

-- --------------------------------------------------------------------------------- grid helpers

-- A window grid is a flat array, index = r * W + c + 1, for c in [0, W), r in [0, H). Cell (c, r) is
-- world cell (ix0 + c, iz0 + r), centre (ix0 + c + 0.5, iz0 + r + 0.5).

local DC = { 1, 1, 0, -1, -1, -1, 0, 1 }   -- 8 neighbours, clockwise from east (z grows south)
local DR = { 0, 1, 1, 1, 0, -1, -1, -1 }

-- Yield hook: the in-game builder runs inside a coroutine and hands the frame back once it has used
-- its time slice (RF.SLICE seconds, checked every few thousand steps); the bench runs straight
-- through. The clock is the engine's getTimeSec in game, os.clock offline; with neither, a step count.
RF.SLICE = 0.004
local function clock()
    if getTimeSec ~= nil then return getTimeSec() end
    if os ~= nil and os.clock ~= nil then return os.clock() end
    return nil
end
RF.clock = clock
local workDone = 0
local function work(n)
    workDone = workDone + n
    if workDone > 2000 then
        workDone = 0
        if RF.yielding and coroutine ~= nil and coroutine.running() ~= nil then
            local now = clock()
            if now == nil or RF.sliceStart == nil or now - RF.sliceStart >= RF.SLICE then
                coroutine.yield()
                RF.sliceStart = clock()
            end
        end
    end
end

--- Connected components of value `v` (4-connected) - calls fn(cells, touchesBorder) for each.
local function components(g, W, H, v, fn)
    local seen = {}
    local stack = {}
    for i = 1, W * H do
        if g[i] == v and not seen[i] then
            local cells, border = {}, false
            seen[i] = true
            stack[1] = i
            local sp = 1
            while sp > 0 do
                local j = stack[sp]
                sp = sp - 1
                cells[#cells + 1] = j
                local c, r = (j - 1) % W, floor((j - 1) / W)
                if c == 0 or r == 0 or c == W - 1 or r == H - 1 then border = true end
                local nb1 = c > 0 and j - 1 or nil
                local nb2 = c < W - 1 and j + 1 or nil
                local nb3 = r > 0 and j - W or nil
                local nb4 = r < H - 1 and j + W or nil
                if nb1 and g[nb1] == v and not seen[nb1] then seen[nb1] = true sp = sp + 1 stack[sp] = nb1 end
                if nb2 and g[nb2] == v and not seen[nb2] then seen[nb2] = true sp = sp + 1 stack[sp] = nb2 end
                if nb3 and g[nb3] == v and not seen[nb3] then seen[nb3] = true sp = sp + 1 stack[sp] = nb3 end
                if nb4 and g[nb4] == v and not seen[nb4] then seen[nb4] = true sp = sp + 1 stack[sp] = nb4 end
            end
            work(#cells)
            fn(cells, border)
        end
    end
end

--- Square max (grow = true) or min filter of radius r over a 0/1 mask, as two 1-D passes.
local function squareFilter(m, W, H, r, grow)
    local tmp, out = {}, {}
    local want = grow and 1 or 0
    for row = 0, H - 1 do
        local base = row * W
        for c = 0, W - 1 do
            local v = 1 - want
            for k = max(0, c - r), min(W - 1, c + r) do
                if m[base + k + 1] == want then v = want break end
            end
            if not grow and (c - r < 0 or c + r > W - 1) then v = 0 end
            tmp[base + c + 1] = v
        end
        work(W * r)
    end
    for c = 0, W - 1 do
        for row = 0, H - 1 do
            local v = 1 - want
            for k = max(0, row - r), min(H - 1, row + r) do
                if tmp[k * W + c + 1] == want then v = want break end
            end
            if not grow and (row - r < 0 or row + r > H - 1) then v = 0 end
            out[row * W + c + 1] = v
        end
        work(H * r)
    end
    return out
end

--- Close a mask (grow then shrink by r): two wheel ruts painted a few metres apart become one track,
--- and paint seams across a road close up. Cells that were road stay road.
local function closeMask(m, W, H, r)
    if r <= 0 then return m end
    local c = squareFilter(squareFilter(m, W, H, r, true), W, H, r, false)
    for i = 1, W * H do if m[i] == 1 then c[i] = 1 end end
    return c
end

--- Fill small holes and drop small specks in a 0/1 mask, in place.
local function cleanMask(m, W, H)
    components(m, W, H, 0, function(cells, border)
        if not border and #cells <= RF.MAX_HOLE then
            for _, j in ipairs(cells) do m[j] = 1 end
        end
    end)
    components(m, W, H, 1, function(cells, border)
        if #cells < RF.MIN_SPECK then
            for _, j in ipairs(cells) do m[j] = 0 end
        end
    end)
end

--- Chamfer (3-4) distance, in cells, from each cell of the mask to the nearest cell outside it.
--- Cells outside the window count as outside, so a road running off the edge reads narrow there;
--- the window is drawn bigger than what is offered, so that edge band is never used.
local function distanceToEdge(m, W, H)
    local BIG = 1e9
    local d = {}
    for i = 1, W * H do d[i] = (m[i] == 1) and BIG or 0 end
    for r = 0, H - 1 do
        for c = 0, W - 1 do
            local i = r * W + c + 1
            if d[i] > 0 then
                local v = d[i]
                if c == 0 or r == 0 then v = 3 else
                    v = min(v, d[i - 1] + 3, d[i - W] + 3, d[i - W - 1] + 4)
                    if c < W - 1 then v = min(v, d[i - W + 1] + 4) else v = min(v, 3) end
                end
                d[i] = v
            end
        end
        work(W)
    end
    for r = H - 1, 0, -1 do
        for c = W - 1, 0, -1 do
            local i = r * W + c + 1
            if d[i] > 0 then
                local v = d[i]
                if c == W - 1 or r == H - 1 then v = min(v, 3) else
                    v = min(v, d[i + 1] + 3, d[i + W] + 3, d[i + W + 1] + 4)
                    if c > 0 then v = min(v, d[i + W - 1] + 4) else v = min(v, 3) end
                end
                d[i] = v
            end
        end
        work(W)
    end
    for i = 1, W * H do d[i] = d[i] / 3 end
    return d
end

--- Zhang-Suen thinning of a 0/1 mask; returns a new 0/1 grid one cell wide along each road.
local function thin(m, W, H)
    local s = {}
    local fg = {}
    for i = 1, W * H do
        s[i] = m[i]
        if m[i] == 1 then
            local c, r = (i - 1) % W, floor((i - 1) / W)
            if c > 0 and r > 0 and c < W - 1 and r < H - 1 then fg[#fg + 1] = i else s[i] = 0 end
        end
    end
    local changed = true
    while changed do
        changed = false
        for pass = 1, 2 do
            local del = {}
            local keep = {}
            for _, i in ipairs(fg) do
                if s[i] == 1 then
                    keep[#keep + 1] = i
                    local p2, p3, p4 = s[i - W], s[i - W + 1], s[i + 1]
                    local p5, p6, p7 = s[i + W + 1], s[i + W], s[i + W - 1]
                    local p8, p9 = s[i - 1], s[i - W - 1]
                    local b = p2 + p3 + p4 + p5 + p6 + p7 + p8 + p9
                    if b >= 2 and b <= 6 then
                        local a = 0
                        if p2 == 0 and p3 == 1 then a = a + 1 end
                        if p3 == 0 and p4 == 1 then a = a + 1 end
                        if p4 == 0 and p5 == 1 then a = a + 1 end
                        if p5 == 0 and p6 == 1 then a = a + 1 end
                        if p6 == 0 and p7 == 1 then a = a + 1 end
                        if p7 == 0 and p8 == 1 then a = a + 1 end
                        if p8 == 0 and p9 == 1 then a = a + 1 end
                        if p9 == 0 and p2 == 1 then a = a + 1 end
                        if a == 1 then
                            if pass == 1 then
                                if p2 * p4 * p6 == 0 and p4 * p6 * p8 == 0 then del[#del + 1] = i end
                            else
                                if p2 * p4 * p8 == 0 and p2 * p6 * p8 == 0 then del[#del + 1] = i end
                            end
                        end
                    end
                end
            end
            for _, i in ipairs(del) do s[i] = 0 end
            if #del > 0 then changed = true end
            fg = keep
            work(#keep)
        end
    end
    -- Zhang-Suen can leave 2-cell-thick staircases; drop any cell whose removal keeps its
    -- neighbours connected and that has an orthogonal neighbour pair forming an L.
    for _, i in ipairs(fg) do
        if s[i] == 1 then
            local n, e, so, w = s[i - W], s[i + 1], s[i + W], s[i - 1]
            if (n == 1 and e == 1 and s[i + W - 1] == 0 and so + w == 0)
                or (e == 1 and so == 1 and s[i - W - 1] == 0 and n + w == 0)
                or (so == 1 and w == 1 and s[i - W + 1] == 0 and n + e == 0)
                or (w == 1 and n == 1 and s[i + W + 1] == 0 and so + e == 0) then
                s[i] = 0
            end
        end
    end
    return s
end

local function nbCount(s, i, W)
    return s[i - W] + s[i - W + 1] + s[i + 1] + s[i + W + 1] + s[i + W] + s[i + W - 1] + s[i - 1] + s[i - W - 1]
end

-- ------------------------------------------------------------------------- graph from skeleton

local function newGraph() return { nodes = {}, edges = {} } end

local function addNode(G, x, z, tag)
    local n = { id = #G.nodes + 1, x = x, z = z, tag = tag, edges = {} }
    G.nodes[#G.nodes + 1] = n
    return n
end

local function polylineLength(P)
    local L = 0
    for i = 2, #P do L = L + sqrt((P[i].x - P[i - 1].x) ^ 2 + (P[i].z - P[i - 1].z) ^ 2) end
    return L
end
RF.polylineLength = polylineLength

--- Trace a skeleton into nodes and edges. Node cells: ends (one neighbour) and junction cells (three
--- or more); touching junction cells are one node. Edges carry their cells as points with the width.
local function traceSkeleton(s, d, W, H, ix0, iz0, maxWidth)
    local G = newGraph()
    local nodeAt = {}           -- cell -> node
    local isNode = {}
    local cellsList = {}
    -- cells too wide to be road (yards, lots) are cut out; their neighbours become "wide" ends
    local wideCut = {}
    for i = 1, W * H do
        if s[i] == 1 then
            if 2 * d[i] - 1 > maxWidth then s[i] = 0 wideCut[i] = true end
        end
    end
    for i = 1, W * H do
        if s[i] == 1 then
            cellsList[#cellsList + 1] = i
            local nc = nbCount(s, i, W)
            if nc ~= 2 then isNode[i] = true end
        end
    end
    work(#cellsList)
    local function cellXZ(i)
        local c, r = (i - 1) % W, floor((i - 1) / W)
        return ix0 + c + 0.5, iz0 + r + 0.5
    end
    local function nearWide(i)
        for k = 1, 8 do
            local j = i + DR[k] * W + DC[k]
            if wideCut[j] then return true end
        end
        return false
    end
    local function onBorder(i)
        local c, r = (i - 1) % W, floor((i - 1) / W)
        return c <= 1 or r <= 1 or c >= W - 2 or r >= H - 2
    end
    -- cluster touching node cells into one node
    for _, i in ipairs(cellsList) do
        if isNode[i] and nodeAt[i] == nil then
            local stack, members = { i }, {}
            nodeAt[i] = true
            while #stack > 0 do
                local j = table.remove(stack)
                members[#members + 1] = j
                for k = 1, 8 do
                    local q = j + DR[k] * W + DC[k]
                    if isNode[q] and nodeAt[q] == nil then nodeAt[q] = true stack[#stack + 1] = q end
                end
            end
            local sx, sz = 0, 0
            local tag = "fork"
            local degreeHint = 0
            for _, j in ipairs(members) do
                local x, z = cellXZ(j)
                sx, sz = sx + x, sz + z
                degreeHint = max(degreeHint, nbCount(s, j, W))
            end
            if #members == 1 and degreeHint <= 1 then
                tag = "end"
                if onBorder(members[1]) then tag = "edge" elseif nearWide(members[1]) then tag = "wide" end
            end
            local n = addNode(G, sx / #members, sz / #members, tag)
            n.cells = members
            for _, j in ipairs(members) do nodeAt[j] = n end
        end
    end
    -- walk edges out of every node
    local used = {}             -- cell -> true once on an edge (non-node cells only)
    local function walk(startNode, first)
        local pts = {}
        local x, z = startNode.x, startNode.z
        pts[1] = { x = x, z = z, w = nil }
        local prev, cur = nil, first
        while true do
            if isNode[cur] then
                local n = nodeAt[cur]
                if n == startNode and #pts <= 1 then return nil end
                pts[#pts + 1] = { x = n.x, z = n.z }
                return pts, n
            end
            if used[cur] then return nil end
            used[cur] = true
            local cx, cz = cellXZ(cur)
            pts[#pts + 1] = { x = cx, z = cz, w = 2 * d[cur] - 1 }
            -- next: a node neighbour first (so a line never skips past its fork), then an
            -- orthogonal unused cell, then a diagonal one
            local nxt = nil
            for k = 1, 8 do
                local q = cur + DR[k] * W + DC[k]
                if s[q] == 1 and q ~= prev and isNode[q] and nodeAt[q] ~= nil and (nodeAt[q] ~= startNode or #pts > 3) then nxt = q break end
            end
            if nxt == nil then
                for k = 1, 8, 2 do
                    local q = cur + DR[k] * W + DC[k]
                    if s[q] == 1 and q ~= prev and not used[q] and not isNode[q] then nxt = q break end
                end
            end
            if nxt == nil then
                for k = 2, 8, 2 do
                    local q = cur + DR[k] * W + DC[k]
                    if s[q] == 1 and q ~= prev and not used[q] and not isNode[q] then nxt = q break end
                end
            end
            if nxt == nil then
                -- dead end without a node cell (a staircase ate it): make an end here
                local tag = onBorder(cur) and "edge" or (nearWide(cur) and "wide" or "end")
                local n = addNode(G, cx, cz, tag)
                n.cells = { cur }
                pts[#pts].w = 2 * d[cur] - 1
                return pts, n
            end
            prev, cur = cur, nxt
        end
    end
    local nodesNow = #G.nodes
    for ni = 1, nodesNow do
        local n = G.nodes[ni]
        for _, j in ipairs(n.cells) do
            for k = 1, 8 do
                local q = j + DR[k] * W + DC[k]
                if s[q] == 1 and not isNode[q] and not used[q] then
                    local pts, other = walk(n, q)
                    if pts ~= nil and #pts >= 2 then
                        local e = { id = #G.edges + 1, a = n, b = other, pts = pts }
                        G.edges[#G.edges + 1] = e
                        n.edges[#n.edges + 1] = e
                        other.edges[#other.edges + 1] = e
                    end
                end
            end
        end
        work(8)
    end
    -- node-to-node edges with no cells between (two node clusters touching diagonally are one
    -- cluster already, so this is rare): ignored.
    -- closed rings with no node at all
    for _, i in ipairs(cellsList) do
        if not isNode[i] and not used[i] then
            local x, z = cellXZ(i)
            local n = addNode(G, x, z, "ring")
            n.cells = {}
            local pts = walk(n, i)
            if pts ~= nil and #pts >= 2 then
                local e = { id = #G.edges + 1, a = n, b = n, pts = pts }
                G.edges[#G.edges + 1] = e
                n.edges[#n.edges + 1] = e
                n.edges[#n.edges + 1] = e
            end
        end
    end
    return G
end

local function otherEnd(e, n) if e.a == n then return e.b end return e.a end

local function removeEdge(G, e)
    e.dead = true
    for _, n in ipairs({ e.a, e.b }) do
        for k = #n.edges, 1, -1 do if n.edges[k] == e then table.remove(n.edges, k) end end
    end
end

--- Edge points ordered from node n outwards.
local function ptsFrom(e, n)
    if e.a == n then return e.pts end
    local r = {}
    for i = #e.pts, 1, -1 do r[#r + 1] = e.pts[i] end
    return r
end

local function medianWidth(pts, skipEnds)
    local ws = {}
    local L, acc = polylineLength(pts), 0
    for i = 1, #pts do
        if i > 1 then acc = acc + sqrt((pts[i].x - pts[i - 1].x) ^ 2 + (pts[i].z - pts[i - 1].z) ^ 2) end
        if pts[i].w ~= nil and (skipEnds == nil or (acc >= skipEnds and acc <= L - skipEnds)) then ws[#ws + 1] = pts[i].w end
    end
    if #ws == 0 then
        for i = 1, #pts do if pts[i].w ~= nil then ws[#ws + 1] = pts[i].w end end
    end
    if #ws == 0 then return nil end
    table.sort(ws)
    return ws[floor((#ws + 1) / 2)]
end
RF.medianWidth = medianWidth

--- Join the two edges at a node that has exactly two, into one edge.
local function mergeThrough(G, n)
    if #n.edges ~= 2 or n.edges[1] == n.edges[2] then return false end
    local e1, e2 = n.edges[1], n.edges[2]
    local a, b = otherEnd(e1, n), otherEnd(e2, n)
    local p1 = ptsFrom(e1, a)        -- a ... n
    local p2 = ptsFrom(e2, n)        -- n ... b
    local pts = {}
    for i = 1, #p1 do pts[#pts + 1] = p1[i] end
    for i = 2, #p2 do pts[#pts + 1] = p2[i] end
    removeEdge(G, e1)
    removeEdge(G, e2)
    n.dead = true
    local e = { id = #G.edges + 1, a = a, b = b, pts = pts }
    G.edges[#G.edges + 1] = e
    a.edges[#a.edges + 1] = e
    if b ~= a then b.edges[#b.edges + 1] = e else a.edges[#a.edges + 1] = e end
    return true
end

--- Prune noise: short dead-end spurs, then forks closer than a road width apart become one fork,
--- then pass-through nodes are merged away. A few rounds, since each can expose more.
local function simplify(G)
    for _ = 1, 4 do
        local changed = false
        for _, e in ipairs(G.edges) do
            if not e.dead and e.a ~= e.b then
                local L = polylineLength(e.pts)
                for _, pair in ipairs({ { e.a, e.b }, { e.b, e.a } }) do
                    local tip, base = pair[1], pair[2]
                    if not e.dead and #tip.edges == 1 and tip.tag ~= "edge" and #base.edges >= 3 then
                        local w = medianWidth(e.pts) or 4
                        if L < max(RF.SPUR_MIN, 1.5 * w) then
                            removeEdge(G, e)
                            tip.dead = true
                            changed = true
                        end
                    end
                end
            end
        end
        -- BUBBLES: two forks joined by two short lines side by side are one road passing a patch (bare
        -- ground at a tree's foot reads as the same dirt as the track; 2026-10-12 screenshots - the run
        -- broke there and detoured round the patch). Keep the straighter line, drop the other. A short
        -- loop that leaves a fork and comes back to it is the same thing.
        for _, e in ipairs(G.edges) do
            if not e.dead and e.a == e.b and polylineLength(e.pts) < RF.BUBBLE_MAX then
                removeEdge(G, e)
                changed = true
            end
        end
        for _, e in ipairs(G.edges) do
            if not e.dead and e.a ~= e.b then
                for _, f in ipairs(e.a.edges) do
                    if f ~= e and not f.dead and f.a ~= f.b
                        and ((f.a == e.a and f.b == e.b) or (f.a == e.b and f.b == e.a)) then
                        local le, lf = polylineLength(e.pts), polylineLength(f.pts)
                        if max(le, lf) < RF.BUBBLE_MAX then
                            -- the straighter line is the one closest to the straight distance
                            local d = sqrt((e.a.x - e.b.x) ^ 2 + (e.a.z - e.b.z) ^ 2)
                            local drop = (le - d > lf - d) and e or f
                            removeEdge(G, drop)
                            changed = true
                            break
                        end
                    end
                end
            end
        end
        -- forks joined by a short edge: collapse into one (a crossing thins to two forks a few
        -- metres apart, a Y mouth sometimes too)
        for _, e in ipairs(G.edges) do
            if not e.dead and e.a ~= e.b and #e.a.edges >= 3 and #e.b.edges >= 3 then
                local L = polylineLength(e.pts)
                local w = medianWidth(e.pts) or 4
                if L < max(6, w) then
                    local keep, gone = e.a, e.b
                    removeEdge(G, e)
                    keep.x, keep.z = (keep.x + gone.x) / 2, (keep.z + gone.z) / 2
                    for _, f in ipairs(gone.edges) do
                        if f.a == gone then f.a = keep; table.insert(f.pts, 1, { x = keep.x, z = keep.z }) end
                        if f.b == gone then f.b = keep; f.pts[#f.pts + 1] = { x = keep.x, z = keep.z } end
                        keep.edges[#keep.edges + 1] = f
                    end
                    gone.edges = {}
                    gone.dead = true
                    changed = true
                end
            end
        end
        for _, n in ipairs(G.nodes) do
            if not n.dead and #n.edges == 2 and n.tag ~= "edge" then
                if mergeThrough(G, n) then changed = true end
            end
        end
        if not changed then break end
    end
    for _, n in ipairs(G.nodes) do
        if not n.dead then
            if #n.edges >= 3 then n.tag = "fork"
            elseif #n.edges == 1 and n.tag == "fork" then n.tag = "end" end
        end
    end
end

--- Moving-average smoothing of an edge's cells (they step in whole metres), ends held.
local function smoothPts(P, radius)
    local n = #P
    if n < 3 then return P end
    local out = {}
    for i = 1, n do
        local r = min(radius, i - 1, n - i)
        local sx, sz, sw, cw, sy, cy, c = 0, 0, 0, 0, 0, 0, 0
        local deck = false
        for k = i - r, i + r do
            sx, sz, c = sx + P[k].x, sz + P[k].z, c + 1
            if P[k].w ~= nil then sw, cw = sw + P[k].w, cw + 1 end
            if P[k].y ~= nil then sy, cy = sy + P[k].y, cy + 1 end
        end
        out[i] = { x = sx / c, z = sz / c, w = (cw > 0) and (sw / cw) or nil, y = (cy > 0) and (sy / cy) or nil,
            deck = P[i].deck }
    end
    return out
end

--- A point a fraction f of the way from a to b: position, width and height interpolated (a missing
--- one taken from the other end), on a deck if the nearer end is.
local function lerpPt(a, b, f)
    local wa, wb = a.w or b.w, b.w or a.w
    local ya, yb = a.y or b.y, b.y or a.y
    return { x = a.x + (b.x - a.x) * f, z = a.z + (b.z - a.z) * f, w = wa and (wa + (wb - wa) * f) or nil,
        y = ya and (ya + (yb - ya) * f) or nil, deck = (f < 0.5) and a.deck or b.deck }
end
RF.lerpPt = lerpPt

local function copyPt(p) return { x = p.x, z = p.z, w = p.w, y = p.y, deck = p.deck } end

--- Resample a polyline at a fixed step (keeps the ends; widths and heights interpolated).
local function resampleFixed(P, step)
    local out = { copyPt(P[1]) }
    local carry = 0
    for i = 2, #P do
        local a, b = P[i - 1], P[i]
        local seg = sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
        local t = step - carry
        while t <= seg do
            out[#out + 1] = lerpPt(a, b, t / seg)
            t = t + step
        end
        carry = seg - (t - step)
    end
    local last = P[#P]
    local tail = out[#out]
    if sqrt((tail.x - last.x) ^ 2 + (tail.z - last.z) ^ 2) > step * 0.3 then
        out[#out + 1] = copyPt(last)
    else
        local q = copyPt(last)
        q.w = last.w or tail.w
        out[#out] = q
    end
    return out
end
RF.resampleFixed = resampleFixed

-- ------------------------------------------------------------------------- one road class

--- Build the graph of one road class from the window's kinds. `isClass(kind, cellIndex)` picks the cells.
local function buildClass(win, isClass, maxWidth, closeRadius)
    local W, H = win.W, win.H
    local m = {}
    local any = false
    for i = 1, W * H do
        if isClass(win.kinds[i] or 0, i) then m[i] = 1 any = true else m[i] = 0 end
    end
    if not any then return newGraph(), m end
    m = closeMask(m, W, H, closeRadius or 0)
    cleanMask(m, W, H)
    local d = distanceToEdge(m, W, H)
    local s = thin(m, W, H)
    local G = traceSkeleton(s, d, W, H, win.ix0, win.iz0, maxWidth)
    simplify(G)
    for _, e in ipairs(G.edges) do
        if not e.dead then
            e.pts = resampleFixed(smoothPts(e.pts, 3), 2)
            -- ends sit on the node centres
            e.pts[1].x, e.pts[1].z = e.a.x, e.a.z
            e.pts[#e.pts].x, e.pts[#e.pts].z = e.b.x, e.b.z
            e.width = medianWidth(e.pts, 6)
            e.len = polylineLength(e.pts)
        end
    end
    return G, m, d
end

--- Nearest point on a graph's live edges to (x, z): edge, index of the segment start, distance,
--- and the projected point.
local function nearestOnGraph(G, x, z, maxDist)
    local best, bi, bd, bx, bz = nil, nil, maxDist or math.huge, nil, nil
    for _, e in ipairs(G.edges) do
        if not e.dead then
            local P = e.pts
            for i = 1, #P - 1 do
                local ax, az, cx, cz = P[i].x, P[i].z, P[i + 1].x, P[i + 1].z
                local dx, dz = cx - ax, cz - az
                local l2 = dx * dx + dz * dz
                local t = 0
                if l2 > 0 then t = max(0, min(1, ((x - ax) * dx + (z - az) * dz) / l2)) end
                local px, pz = ax + dx * t, az + dz * t
                local dd = sqrt((x - px) ^ 2 + (z - pz) ^ 2)
                if dd < bd then best, bi, bd, bx, bz = e, i, dd, px, pz end
            end
        end
    end
    return best, bi, bd, bx, bz
end
RF.nearestOnGraph = nearestOnGraph

--- Split edge e at point (px, pz) after segment start index i into two edges meeting at a new fork.
local function splitEdgeAt(G, e, i, px, pz)
    local n = addNode(G, px, pz, "fork")
    local p1, p2 = {}, {}
    for k = 1, i do p1[#p1 + 1] = e.pts[k] end
    p1[#p1 + 1] = { x = px, z = pz, w = e.pts[i].w }
    p2[1] = { x = px, z = pz, w = e.pts[i + 1].w }
    for k = i + 1, #e.pts do p2[#p2 + 1] = e.pts[k] end
    local a, b = e.a, e.b
    removeEdge(G, e)
    local e1 = { id = #G.edges + 1, a = a, b = n, pts = p1 }
    G.edges[#G.edges + 1] = e1
    local e2 = { id = #G.edges + 1, a = n, b = b, pts = p2 }
    G.edges[#G.edges + 1] = e2
    a.edges[#a.edges + 1] = e1
    n.edges[#n.edges + 1] = e1
    n.edges[#n.edges + 1] = e2
    b.edges[#b.edges + 1] = e2
    for _, f in ipairs({ e1, e2 }) do
        f.width = medianWidth(f.pts, 6) or e.width
        f.len = polylineLength(f.pts)
        f.class = e.class
    end
    return n
end

-- ------------------------------------------------------------------------- bridges and ramps

--- Carry the deck lines (bridges, flyovers, raised ramps) into the ground roads they land on. Each
--- deck end within DECK_JOIN of a ground road's end is tied to it (or, failing an end, to the nearest
--- point of a ground road, split there), and the joined lines merge into one, so a road reads
--- straight across a bridge. A deck that meets a paved road joins the paved roads, else the tracks.
local function joinDecks(D, paved, track)
    local function dist(a, b) return sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2) end
    local function findGround(n)
        local best, bd, bg = nil, RF.DECK_JOIN, nil
        for _, G in ipairs({ paved, track }) do
            for _, m in ipairs(G.nodes) do
                if not m.dead and #m.edges == 1 and m.tag ~= "edge" then
                    local d = dist(m, n)
                    if d < bd then best, bd, bg = m, d, G end
                end
            end
        end
        if best ~= nil then return best, bg end
        for _, G in ipairs({ paved, track }) do
            local e, i, dd, px, pz = nearestOnGraph(G, n.x, n.z, RF.DECK_JOIN)
            if e ~= nil then
                for _, m in ipairs({ e.a, e.b }) do
                    if sqrt((m.x - px) ^ 2 + (m.z - pz) ^ 2) < 3 then return m, G end
                end
                return splitEdgeAt(G, e, i, px, pz), G
            end
        end
        return nil
    end
    local target = {}
    for _, n in ipairs(D.nodes) do
        if not n.dead and #n.edges == 1 and n.tag ~= "edge" then
            local m, G = findGround(n)
            if m ~= nil then target[n] = { node = m, graph = G } end
        end
    end
    -- move the deck lines into the graph they join (paved first)
    local placed = {}
    for _, e in ipairs(D.edges) do
        if not e.dead then
            local ta, tb = target[e.a], target[e.b]
            local G = paved
            if ta ~= nil and tb ~= nil then
                G = (ta.graph == paved or tb.graph == paved) and paved or track
            elseif ta ~= nil then G = ta.graph elseif tb ~= nil then G = tb.graph end
            e.class = (G == paved) and "paved" or "track"
            e.deck = true
            G.edges[#G.edges + 1] = e
            for _, n in ipairs({ e.a, e.b }) do
                if placed[n] == nil then
                    placed[n] = G
                    G.nodes[#G.nodes + 1] = n
                end
            end
        end
    end
    -- tie each landing in, then merge the two lines meeting there into one
    local joined = 0
    for n, t in pairs(target) do
        local G = placed[n]
        if G ~= nil and G == t.graph then
            local m = t.node
            local c = { a = m, b = n, pts = { { x = m.x, z = m.z }, { x = n.x, z = n.z, y = n.y, deck = true } }, class = n.class }
            G.edges[#G.edges + 1] = c
            m.edges[#m.edges + 1] = c
            n.edges[#n.edges + 1] = c
            n.tag = "ramp"
            if m.tag ~= "fork" then m.tag = "ramp" end
            joined = joined + 1
        end
    end
    for _, G in ipairs({ paved, track }) do
        for _, n in ipairs(G.nodes) do
            if not n.dead and #n.edges == 2 and n.tag == "ramp" then mergeThrough(G, n) end
        end
        for _, e in ipairs(G.edges) do
            if not e.dead then
                e.class = (G == paved) and "paved" or "track"
                e.width = medianWidth(e.pts, 6)
                e.len = polylineLength(e.pts)
                for _, p in ipairs(e.pts) do if p.deck then e.deck = true break end end
            end
        end
    end
    return joined
end

-- ------------------------------------------------------------------------- through roads at forks

--- The road that carries straight on through a fork is ONE line through it (user, 2026-10-12: "through
--- tracks at T's should go through"): at each fork the two arms that line up best - within THROUGH_ANGLE
--- of straight on - are joined into one line passing the fork; the other arms still end there (and
--- stop short for the junction tool). One through pair per fork: at a crossing the straighter road
--- goes through.
RF.THROUGH_ANGLE = 35
local function armHeading(e, n)
    local P = ptsFrom(e, n)
    local far = P[#P]
    local acc = 0
    for i = 2, #P do
        acc = acc + sqrt((P[i].x - P[i - 1].x) ^ 2 + (P[i].z - P[i - 1].z) ^ 2)
        if acc >= 12 then far = P[i] break end
    end
    local hx, hz = far.x - n.x, far.z - n.z
    local l = sqrt(hx * hx + hz * hz)
    if l < 1e-6 then return nil end
    return hx / l, hz / l
end

local function throughForks(G)
    local joined = 0
    local cosMax = -cos(math.rad(RF.THROUGH_ANGLE))     -- arms pointing nearly opposite ways
    for _, n in ipairs(G.nodes) do
        if not n.dead and #n.edges >= 3 then
            local best, bi, bj = cosMax, nil, nil
            for i = 1, #n.edges do
                for j = i + 1, #n.edges do
                    local e1, e2 = n.edges[i], n.edges[j]
                    if e1 ~= e2 and not e1.dead and not e2.dead and e1.a ~= e1.b and e2.a ~= e2.b then
                        local ax, az = armHeading(e1, n)
                        local bx, bz = armHeading(e2, n)
                        if ax ~= nil and bx ~= nil then
                            local c = ax * bx + az * bz
                            if c < best then best, bi, bj = c, e1, e2 end
                        end
                    end
                end
            end
            if bi ~= nil then
                local a, b = otherEnd(bi, n), otherEnd(bj, n)
                if a ~= b then
                    local p1, p2 = ptsFrom(bi, a), ptsFrom(bj, n)
                    local pts = {}
                    for k = 1, #p1 do pts[#pts + 1] = p1[k] end
                    for k = 2, #p2 do pts[#pts + 1] = p2[k] end
                    removeEdge(G, bi)
                    removeEdge(G, bj)
                    local e = { id = #G.edges + 1, a = a, b = b, pts = pts, through = n, class = bi.class }
                    G.edges[#G.edges + 1] = e
                    a.edges[#a.edges + 1] = e
                    b.edges[#b.edges + 1] = e
                    e.width = medianWidth(pts, 6)
                    e.len = polylineLength(pts)
                    for _, p in ipairs(pts) do if p.deck then e.deck = true break end end
                    joined = joined + 1
                end
            end
        end
    end
    return joined
end

-- ------------------------------------------------------------------------- the window

--- Build everything for the window of cells [ix0, ix0 + W) x [iz0, iz0 + H). `kindAt(ix, iz)`
--- reads the cache; `opts.kinds` = { [KIND] = true } the road kinds the user wants.
--- Returns { paved = graph, track = graph, nodes, edges } with every live edge tagged by class.
function RF.buildWindow(kindAt, ix0, iz0, W, H, opts)
    opts = opts or {}
    local wanted = opts.kinds or { [1] = true, [2] = true, [3] = true }
    local win = { ix0 = ix0, iz0 = iz0, W = W, H = H, kinds = {} }
    for r = 0, H - 1 do
        for c = 0, W - 1 do
            win.kinds[r * W + c + 1] = kindAt(ix0 + c, iz0 + r) or 0
        end
        work(W)
    end
    local paved, pavedMask, pavedDist = newGraph(), nil, nil
    if wanted[RF.KIND_PAVED] then
        paved, pavedMask, pavedDist = buildClass(win, function(k) return k == RF.KIND_PAVED end, RF.MAX_ROAD_WIDTH.paved, RF.CLOSE_RADIUS.paved)
    end
    local track = newGraph()
    if wanted[RF.KIND_GRAVEL] or wanted[RF.KIND_DIRT] then
        track = buildClass(win, function(k)
            return (k == RF.KIND_GRAVEL and wanted[RF.KIND_GRAVEL]) or (k == RF.KIND_DIRT and wanted[RF.KIND_DIRT])
        end, RF.MAX_ROAD_WIDTH.track, RF.CLOSE_RADIUS.track)
    end
    for _, e in ipairs(paved.edges) do
        e.class = "paved"
        if not e.dead and (e.width or 0) < RF.MIN_PAVED_WIDTH then removeEdge(paved, e) end
    end
    for _, e in ipairs(track.edges) do e.class = "track" end

    -- distance from every cell to the nearest paved cell (for the shoulder test). Paved cells
    -- even when the user turned paved roads off: a shoulder is still a shoulder.
    local anyPaved = false
    local pm = {}
    for i = 1, W * H do
        if win.kinds[i] == RF.KIND_PAVED then pm[i] = 0 anyPaved = true else pm[i] = 1 end
    end
    local toPaved = nil
    if anyPaved then toPaved = distanceToEdge(pm, W, H) end
    local function distPaved(x, z)
        if toPaved == nil then return math.huge end
        local c, r = floor(x) - ix0, floor(z) - iz0
        if c < 0 or r < 0 or c >= W or r >= H then return math.huge end
        return toPaved[r * W + c + 1]
    end

    -- track lines: drop shoulders and paint seams
    for _, e in ipairs(track.edges) do
        if not e.dead then
            local near, total = 0, 0
            for _, p in ipairs(e.pts) do
                total = total + 1
                if distPaved(p.x, p.z) <= RF.SHOULDER_DIST then near = near + 1 end
            end
            local narrow = (e.width or 0) < RF.MIN_TRACK_WIDTH
            if (total > 0 and near / total > 0.5) or narrow then
                removeEdge(track, e)
            end
        end
    end
    -- a track ending at a paved road makes a fork on the paved road
    for _, n in ipairs(track.nodes) do
        if not n.dead and #n.edges == 1 and distPaved(n.x, n.z) <= RF.SHOULDER_DIST + 1 then
            local e, i, dd, px, pz = nearestOnGraph(paved, n.x, n.z, nil)
            if e ~= nil and dd <= (e.width or 6) / 2 + RF.TRACK_JOIN then
                -- reuse a fork already close by, else split the paved line there
                local f = nil
                for _, m in ipairs({ e.a, e.b }) do
                    if #m.edges >= 3 and sqrt((m.x - px) ^ 2 + (m.z - pz) ^ 2) < 8 then f = m end
                end
                if f == nil then
                    local ta = sqrt((e.a.x - px) ^ 2 + (e.a.z - pz) ^ 2)
                    local tb = sqrt((e.b.x - px) ^ 2 + (e.b.z - pz) ^ 2)
                    if ta > 3 and tb > 3 then f = splitEdgeAt(paved, e, i, px, pz) end
                end
                if f ~= nil then
                    n.tag = "fork"
                    n.joins = f
                    f.tag = "fork"
                    f.trackJoin = true
                end
            end
        end
    end
    -- re-simplify the track graph (dropped shoulders leave pass-through nodes)
    for _, n in ipairs(track.nodes) do
        if not n.dead and #n.edges == 2 and n.tag ~= "edge" and n.tag ~= "fork" then mergeThrough(track, n) end
        if not n.dead and #n.edges == 0 then n.dead = true end
    end
    for _, n in ipairs(track.nodes) do
        if not n.dead and #n.edges == 2 and n.tag == "fork" and n.joins == nil then mergeThrough(track, n) end
    end
    for _, e in ipairs(track.edges) do
        if not e.dead then e.width = medianWidth(e.pts, 6) e.len = polylineLength(e.pts) e.class = "track" end
    end

    -- bridges, flyovers, raised ramps: their own class (a flyover must not cross the road under it),
    -- then carried into the ground roads they land on
    win.decks = 0
    if opts.deckAt ~= nil then
        local dk = {}
        local any = false
        for r = 0, H - 1 do
            for c = 0, W - 1 do
                local y = opts.deckAt(ix0 + c, iz0 + r)
                if y ~= nil then dk[r * W + c + 1] = y any = true end
            end
            work(W)
        end
        if any then
            local function deckYAt(x, z)
                local c0, r0 = floor(x) - ix0, floor(z) - iz0
                for rad = 0, 2 do
                    local sum, n = 0, 0
                    for dr = -rad, rad do
                        for dc = -rad, rad do
                            local c, r = c0 + dc, r0 + dr
                            if c >= 0 and r >= 0 and c < W and r < H then
                                local y = dk[r * W + c + 1]
                                if y ~= nil then sum, n = sum + y, n + 1 end
                            end
                        end
                    end
                    if n > 0 then return sum / n end
                end
                return nil
            end
            local D = buildClass(win, function(_, i) return dk[i] ~= nil end, RF.MAX_ROAD_WIDTH.paved, 1)
            for _, e in ipairs(D.edges) do
                if not e.dead then
                    if (e.width or 0) < RF.MIN_TRACK_WIDTH then removeEdge(D, e) else
                        for _, p in ipairs(e.pts) do
                            p.y = deckYAt(p.x, p.z)
                            p.deck = p.y ~= nil
                        end
                    end
                end
            end
            for _, n in ipairs(D.nodes) do n.y = deckYAt(n.x, n.z) end
            win.decks = joinDecks(D, paved, track)
        end
    end

    local throughs = throughForks(paved) + throughForks(track)
    local out = { paved = paved, track = track, ix0 = ix0, iz0 = iz0, W = W, H = H, edges = {}, nodes = {}, decks = win.decks,
        throughs = throughs }
    for _, G in ipairs({ paved, track }) do
        -- a short line joined to nothing (no fork, not running off the window) is a scrap of paint
        -- along a stream or in a yard, not a road
        for _, e in ipairs(G.edges) do
            if not e.dead then
                local ta, tb = e.a.tag, e.b.tag
                local loose = ta ~= "fork" and tb ~= "fork" and ta ~= "edge" and tb ~= "edge"
                if loose and (e.len or polylineLength(e.pts)) < RF.MIN_LOOSE then removeEdge(G, e) end
            end
        end
        for _, e in ipairs(G.edges) do if not e.dead then out.edges[#out.edges + 1] = e end end
        for _, n in ipairs(G.nodes) do if not n.dead then out.nodes[#out.nodes + 1] = n end end
    end
    -- the kind each edge mostly runs on (for the card's paved / gravel / dirt filter)
    for _, e in ipairs(out.edges) do
        if e.class == "paved" then e.kind = RF.KIND_PAVED else
            local g, dct = 0, 0
            for _, p in ipairs(e.pts) do
                local k = kindAt(floor(p.x), floor(p.z))
                if k == RF.KIND_GRAVEL then g = g + 1 elseif k == RF.KIND_DIRT then dct = dct + 1 end
            end
            e.kind = (g >= dct) and RF.KIND_GRAVEL or RF.KIND_DIRT
        end
    end
    return out
end

-- ------------------------------------------------------------------------- AutoDrive coverage

--- Index a network's links near the window. `wps` is a list/array of waypoints with x, z and out
--- (ids, or waypoint tables); `byId(id)` resolves an id. Returns a grid of segments, 8 m cells.
function RF.indexNetwork(wps, byId, x0, z0, x1, z1)
    local CELL = 8
    local grid = { cell = CELL, cells = {}, segs = {} }
    for _, a in pairs(wps) do
        if type(a) == "table" and a.x ~= nil and a.out ~= nil then
            for _, o in ipairs(a.out) do
                local b = (type(o) == "table") and o or byId(o)
                if b ~= nil and b.x ~= nil then
                    local mx0, mx1 = min(a.x, b.x), max(a.x, b.x)
                    local mz0, mz1 = min(a.z, b.z), max(a.z, b.z)
                    if mx1 >= x0 and mx0 <= x1 and mz1 >= z0 and mz0 <= z1 then
                        local seg = { ax = a.x, az = a.z, bx = b.x, bz = b.z, a = a, b = b }
                        grid.segs[#grid.segs + 1] = seg
                        for gx = floor(mx0 / CELL), floor(mx1 / CELL) do
                            for gz = floor(mz0 / CELL), floor(mz1 / CELL) do
                                local k = gx * 100003 + gz
                                local list = grid.cells[k]
                                if list == nil then list = {} grid.cells[k] = list end
                                list[#list + 1] = seg
                            end
                        end
                    end
                end
            end
        end
    end
    return grid
end

--- Segments of the indexed network within `r` of (x, z): calls fn(seg, dist, px, pz).
function RF.networkNear(grid, x, z, r, fn)
    if grid == nil then return end
    local CELL = grid.cell
    local seen = {}
    for gx = floor((x - r) / CELL), floor((x + r) / CELL) do
        for gz = floor((z - r) / CELL), floor((z + r) / CELL) do
            local list = grid.cells[gx * 100003 + gz]
            if list ~= nil then
                for _, sg in ipairs(list) do
                    if not seen[sg] then
                        seen[sg] = true
                        local dx, dz = sg.bx - sg.ax, sg.bz - sg.az
                        local l2 = dx * dx + dz * dz
                        local t = 0
                        if l2 > 0 then t = max(0, min(1, ((x - sg.ax) * dx + (z - sg.az) * dz) / l2)) end
                        local px, pz = sg.ax + dx * t, sg.az + dz * t
                        local dd = sqrt((x - px) ^ 2 + (z - pz) ^ 2)
                        if dd <= r then fn(sg, dd, px, pz) end
                    end
                end
            end
        end
    end
end

local function headingDiff(ax, az, bx, bz)
    -- angle between two lines, ignoring direction, in degrees (0..90)
    local la, lb = sqrt(ax * ax + az * az), sqrt(bx * bx + bz * bz)
    if la < 1e-6 or lb < 1e-6 then return 90 end
    local c = abs((ax * bx + az * bz) / (la * lb))
    if c > 1 then c = 1 end
    return math.deg(math.acos(c))
end

--- Is the road at point i of P already driven along by the network?
local function coveredAt(grid, P, i, halfWidth)
    local a, b = P[max(1, i - 1)], P[min(#P, i + 1)]
    local hx, hz = b.x - a.x, b.z - a.z
    local r = max(3, halfWidth + 1.5)
    local hit = false
    RF.networkNear(grid, P[i].x, P[i].z, r, function(sg)
        if not hit and headingDiff(hx, hz, sg.bx - sg.ax, sg.bz - sg.az) <= RF.COVER_ANGLE then hit = true end
    end)
    return hit
end

--- Split the window's edges into stretches: the uncovered parts, long enough to offer. Each stretch:
--- { pts, kind, class, width, len, startTag, endTag, startNode, endNode, edge, i0, i1 }.
--- Tags: "fork" (a fork node), "end" (the road ends), "edge" (runs out of the window), "wide" (into a
--- yard), "path" (an AutoDrive path takes over along the road).
function RF.findStretches(win, grid)
    local stretches = {}
    for _, e in ipairs(win.edges) do
        local P = e.pts
        local half = (e.width or 6) / 2
        local cov = {}
        for i = 1, #P do cov[i] = coveredAt(grid, P, i, half) end
        -- runs shorter than COVER_SMOOTH (in points of 2 m) take their neighbours' side
        local minRun = max(1, floor(RF.COVER_SMOOTH / 2))
        local i = 1
        while i <= #P do
            local j = i
            while j < #P and cov[j + 1] == cov[i] do j = j + 1 end
            if (j - i + 1) < minRun and i > 1 and j < #P and cov[i - 1] == cov[j + 1] then
                for k = i, j do cov[k] = cov[i - 1] end
            end
            i = j + 1
        end
        e.covered = cov
        i = 1
        while i <= #P do
            if not cov[i] then
                local j = i
                while j < #P and not cov[j + 1] do j = j + 1 end
                local pts = {}
                for k = i, j do pts[#pts + 1] = P[k] end
                local L = polylineLength(pts)
                if L >= RF.MIN_STRETCH then
                    stretches[#stretches + 1] = {
                        pts = pts, kind = e.kind, class = e.class, width = e.width, len = L,
                        startTag = (i == 1) and e.a.tag or "path", endTag = (j == #P) and e.b.tag or "path",
                        startNode = (i == 1) and e.a or nil, endNode = (j == #P) and e.b or nil,
                        edge = e, i0 = i, i1 = j,
                    }
                end
                i = j + 1
            else
                i = i + 1
            end
        end
        work(#P)
    end
    return stretches
end

--- The nearest stretch to (x, z) within `maxDist` (plus its own half width).
function RF.stretchNear(stretches, x, z, maxDist)
    local best, bd = nil, math.huge
    for _, st in ipairs(stretches) do
        local P = st.pts
        local reach = (maxDist or 3) + (st.width or 6) / 2
        for i = 1, #P - 1 do
            local ax, az, cx, cz = P[i].x, P[i].z, P[i + 1].x, P[i + 1].z
            local dx, dz = cx - ax, cz - az
            local l2 = dx * dx + dz * dz
            local t = 0
            if l2 > 0 then t = max(0, min(1, ((x - ax) * dx + (z - az) * dz) / l2)) end
            local px, pz = ax + dx * t, az + dz * t
            local dd = sqrt((x - px) ^ 2 + (z - pz) ^ 2)
            if dd <= reach and dd < bd then best, bd = st, dd end
        end
    end
    return best, bd
end

--- Which side of a stretch (x, z) is on: +1 right of its point order, -1 left.
function RF.sideOf(st, x, z)
    local P = st.pts
    local bi, bd = 1, math.huge
    for i = 1, #P - 1 do
        local mx, mz = (P[i].x + P[i + 1].x) / 2, (P[i].z + P[i + 1].z) / 2
        local dd = (x - mx) ^ 2 + (z - mz) ^ 2
        if dd < bd then bi, bd = i, dd end
    end
    local hx, hz = P[bi + 1].x - P[bi].x, P[bi + 1].z - P[bi].z
    -- right of heading (hx, hz) with x east, z south is (-hz, hx)
    local rx, rz = -hz, hx
    return ((x - P[bi].x) * rx + (z - P[bi].z) * rz) >= 0 and 1 or -1
end

--- Lane centre gap measured on the network: the median distance between opposite-way lanes
--- that run side by side 2-8 m apart. nil when the window has too few to say.
function RF.networkLaneGap(grid)
    if grid == nil then return nil end
    local gaps = {}
    for _, sg in ipairs(grid.segs) do
        local dx, dz = sg.bx - sg.ax, sg.bz - sg.az
        local L = sqrt(dx * dx + dz * dz)
        if L > 1.5 then
            local mx, mz = (sg.ax + sg.bx) / 2, (sg.az + sg.bz) / 2
            local best = nil
            RF.networkNear(grid, mx, mz, 8, function(o, dd)
                if o ~= sg and dd >= 2 then
                    local ox, oz = o.bx - o.ax, o.bz - o.az
                    local ol = sqrt(ox * ox + oz * oz)
                    if ol > 1.5 then
                        local c = (dx * ox + dz * oz) / (L * ol)
                        if c < -0.97 and (best == nil or dd < best) then best = dd end
                    end
                end
            end)
            if best ~= nil then gaps[#gaps + 1] = best end
        end
    end
    if #gaps < 10 then return nil, #gaps end
    table.sort(gaps)
    return gaps[floor((#gaps + 1) / 2)], #gaps
end

-- ------------------------------------------------------------------------- walking a road

-- The window above finds every road in a square; this follows ONE road from a point on it, the way a
-- driver would: step ahead, look straight across the road, steer gently toward its middle. Asked for
-- 2026-10-12 after the first game test: one rut of a two-rut track read as the track, and paint noise
-- made bumps that are not there. So:
--   * a cross-section reads the road as BANDS of road ground; bands closer than joinGap are one road
--     (two wheel ruts 3-4 m apart with grass between are one track);
--   * the walker only steers a fraction of the way toward what it sees (gainPos), never turns more than
--     maxTurn per step, and ignores a reading that jumps too far sideways (gate) - noise is filtered;
--   * the line is straightened afterwards (RF.straighten).
RF.WALK = {
    step = 2,                       -- metres per step
    half = 9,                       -- how far either side a cross-section looks
    res = 0.25,                     -- cross-section sample spacing
    joinGap = { track = 4.0, paved = 1.0 },   -- gaps up to this inside a band are the same road (ruts)
    tightGap = 1.0,                 -- tried first: only a band narrower than rutWidth is read again with joinGap
    rutWidth = 2.5,
    rutMax = 2.0,                   -- a wheel rut is at most this wide
    rutGapMin = 0.4,                -- the grass strip between two ruts: at least ...
    rutGapMax = 3.0,                -- ... and at most this wide                 -- (a solid track must not swallow the gravel patches beside it)
    minBand = { track = 1.5, paved = 3.0 },   -- narrower bands are not a road
    gainPos = 0.3,                  -- how far toward the measured middle the line moves per step
    maxTurn = 6,                    -- degrees per step (6 deg / 2 m = no bend tighter than ~19 m)
    gate = 2.5,                     -- a middle further off than this (plus a quarter of the width) is noise
    maxMiss = 4,                    -- steps with no road ahead before the road has ended
    widen = 2.0,                    -- the band this many times its usual width: a fork's mouth
    maxLen = 1200,                  -- metres one walk may cover each way
}

--- Bands of road across the line at (x, z) with unit normal (nx, nz): list of { lo, hi } offsets,
--- merged where the gap between them is at most joinGap.
function RF.crossSection(isRoad, x, z, nx, nz, half, res, joinGap)
    local bands = {}
    local cur = nil
    local lastRoad = nil
    local o = -half
    while o <= half + 1e-6 do
        if isRoad(x + nx * o, z + nz * o) then
            if cur ~= nil and lastRoad ~= nil and o - lastRoad <= joinGap + res then
                cur.hi = o
            else
                cur = { lo = o, hi = o }
                bands[#bands + 1] = cur
            end
            lastRoad = o
        end
        o = o + res
    end
    for _, b in ipairs(bands) do
        b.lo, b.hi = b.lo - res / 2, b.hi + res / 2
        b.mid, b.w = (b.lo + b.hi) / 2, b.hi - b.lo
    end
    return bands
end

--- The bands across at (x, z): read tightly first; where the band in the middle is only a rut wide,
--- read again joining across the grass between ruts.
local function bandsAt(isRoad, x, z, nx, nz, cls)
    return RF.bandsAt(isRoad, x, z, nx, nz, cls)
end
function RF.bandsAt(isRoad, x, z, nx, nz, cls)
    local W = RF.WALK
    local bands = RF.crossSection(isRoad, x, z, nx, nz, W.half, W.res, W.tightGap)
    -- A farm track is TWO RUTS with a strip of grass between them (2026-10-12 screenshots): the middle
    -- of the track is halfway between the ruts. Find the pair of narrow dirt strips with a grass gap
    -- between them nearest the line, and read the track as that pair - stray mud beside the track (a
    -- headland, a puddle) is left out. (A field-edge rule tried before this pulled the line onto a rut:
    -- the grass between a field and a track is not track.)
    if cls == "track" then
        -- read finely for this: only single-sample holes closed, so a 1 m grass strip stays a gap
        local fine = RF.crossSection(isRoad, x, z, nx, nz, W.half, W.res, W.res)
        local best = nil
        for k = 1, #fine - 1 do
            local a, b = fine[k], fine[k + 1]
            local gap = b.lo - a.hi
            if a.w <= W.rutMax and b.w <= W.rutMax and gap >= W.rutGapMin and gap <= W.rutGapMax then
                local mid = (a.mid + b.mid) / 2
                if best == nil or abs(mid) < abs(best.mid) then
                    best = { lo = a.lo, hi = b.hi, mid = mid, w = b.hi - a.lo, ruts = true }
                end
            end
        end
        if best ~= nil then
            local out = { best }
            for _, b in ipairs(fine) do
                if b.w > W.rutWidth and (b.hi < best.lo or b.lo > best.hi) then out[#out + 1] = b end
            end
            return out
        end
    end
    local wide = W.joinGap[cls] or W.tightGap
    if wide > W.tightGap then
        local nearest = nil
        for _, b in ipairs(bands) do
            if nearest == nil or abs(b.mid) < abs(nearest.mid) then nearest = b end
        end
        if nearest == nil or nearest.w < W.rutWidth then
            bands = RF.crossSection(isRoad, x, z, nx, nz, W.half, W.res, wide)
        end
    end
    return bands
end

local function rot(hx, hz, deg)
    local a = math.rad(deg)
    local c, s = cos(a), sin(a)
    return hx * c - hz * s, hx * s + hz * c
end

--- The road under (x, z): its middle and heading, from cross-sections every 10 degrees - the one
--- across the road is the narrowest. Returns cx, cz, hx, hz, width or nil.
function RF.seedRoad(isRoad, x, z, cls)
    local W = RF.WALK
    local best = nil
    for a = 0, 170, 10 do
        local nx, nz = cos(math.rad(a)), sin(math.rad(a))
        local bands = bandsAt(isRoad, x, z, nx, nz, cls)
        for _, b in ipairs(bands) do
            if b.lo <= 1.5 and b.hi >= -1.5 and b.w >= W.minBand[cls] and (best == nil or b.w < best.w) then
                best = { w = b.w, cx = x + nx * b.mid, cz = z + nz * b.mid, nx = nx, nz = nz }
            end
        end
    end
    if best == nil then return nil end
    -- heading along the road: the normal turned a right angle (either way; the walk goes both)
    return best.cx, best.cz, best.nz, -best.nx, best.w
end

--- Walk one way from (x, z) heading (hx, hz). Returns the points (x, z, w) and how it ended:
--- "end" (no road ahead), "fork" (the road widens into a mouth), "limit" (maxLen), "loop".
function RF.walkRoad(isRoad, cls, x, z, hx, hz, w0, isStop)
    local W = RF.WALK
    local hl = sqrt(hx * hx + hz * hz)
    hx, hz = hx / hl, hz / hl
    local pts = { { x = x, z = z, w = w0 } }
    local widths = { w0 }
    local miss, len, wideRun = 0, 0, 0
    local px, pz = x, z
    local maxTurnCos = cos(math.rad(W.maxTurn))
    while len < W.maxLen do
        local qx, qz = px + hx * W.step, pz + hz * W.step
        local nx, nz = -hz, hx
        if isStop ~= nil and isStop(qx, qz) then return pts, "fork", { x = qx, z = qz } end
        local bands = bandsAt(isRoad, qx, qz, nx, nz, cls)
        -- the usual width so far (median of the recent ones)
        local recent = {}
        for i = max(1, #widths - 10), #widths do recent[#recent + 1] = widths[i] end
        table.sort(recent)
        local usual = recent[floor((#recent + 1) / 2)] or w0
        local pick = nil
        for _, b in ipairs(bands) do
            if b.w >= W.minBand[cls] and abs(b.mid) <= W.gate + 0.25 * b.w then
                if pick == nil or abs(b.mid) < abs(pick.mid) then pick = b end
            end
        end
        if pick == nil then
            miss = miss + 1
            if miss > W.maxMiss then
                -- drop the steps taken blind
                for _ = 1, miss - 1 do if #pts > 1 then table.remove(pts) end end
                return pts, "end"
            end
            px, pz = qx, qz
            pts[#pts + 1] = { x = px, z = pz, w = usual, blind = true }
        else
            miss = 0
            -- a fork's mouth: the road stays much wider than usual for a few steps running (one wide
            -- reading is a patch or a rut read the other way)
            if #pts > 4 and pick.w > W.widen * usual then
                wideRun = wideRun + 1
                if wideRun >= 3 then
                    for _ = 1, wideRun - 1 do if #pts > 1 then table.remove(pts) end end
                    local f = pts[#pts]
                    return pts, "fork", { x = f.x + hx * W.step, z = f.z + hz * W.step }
                end
            else
                wideRun = 0
            end
            -- steer a fraction of the way toward the measured middle, within the turn limit
            local tx, tz = qx + nx * pick.mid * W.gainPos, qz + nz * pick.mid * W.gainPos
            local dx, dz = tx - px, tz - pz
            local dl = sqrt(dx * dx + dz * dz)
            dx, dz = dx / dl, dz / dl
            local c = dx * hx + dz * hz
            if c < maxTurnCos then
                local side = (hx * dz - hz * dx) >= 0 and 1 or -1
                dx, dz = rot(hx, hz, side * W.maxTurn)
            end
            hx, hz = dx, dz
            px, pz = px + hx * W.step, pz + hz * W.step
            if wideRun == 0 then widths[#widths + 1] = pick.w end
            pts[#pts + 1] = { x = px, z = pz, w = (wideRun == 0) and pick.w or usual }
        end
        len = len + W.step
        -- back where it started (a ring road)
        if len > 40 and sqrt((px - x) ^ 2 + (pz - z) ^ 2) < W.step then return pts, "loop" end
        work(40)
    end
    return pts, "limit"
end

--- Douglas-Peucker: the fewest points within tol of the line.
local function simplifyLine(P, tol)
    if #P <= 2 then return P end
    local keep = { [1] = true, [#P] = true }
    local stack = { { 1, #P } }
    while #stack > 0 do
        local seg = table.remove(stack)
        local a, b = P[seg[1]], P[seg[2]]
        local dx, dz = b.x - a.x, b.z - a.z
        local l = sqrt(dx * dx + dz * dz)
        local worst, wi = -1, nil
        for i = seg[1] + 1, seg[2] - 1 do
            local d
            if l < 1e-6 then d = sqrt((P[i].x - a.x) ^ 2 + (P[i].z - a.z) ^ 2)
            else d = abs((P[i].x - a.x) * dz - (P[i].z - a.z) * dx) / l end
            if d > worst then worst, wi = d, i end
        end
        if wi ~= nil and worst > tol then
            keep[wi] = true
            stack[#stack + 1] = { seg[1], wi }
            stack[#stack + 1] = { wi, seg[2] }
        end
    end
    local out = {}
    for i = 1, #P do if keep[i] then out[#out + 1] = P[i] end end
    return out
end
RF.simplifyLine = simplifyLine

--- Heavy straightening: the fewest straight pieces within tol of the walked line, then the corners
--- between them rounded (resample, then smoothing over about ten metres).
function RF.straighten(P, tol)
    if #P < 3 then return P end
    local S = simplifyLine(P, tol or 0.75)
    local R = resampleFixed(S, 2)
    R = smoothPts(smoothPts(R, 3), 3)
    -- widths along the result from the walked line (nearest point)
    for _, p in ipairs(R) do
        if p.w == nil then
            local bd, bw = math.huge, nil
            for _, q in ipairs(P) do
                local d = (q.x - p.x) ^ 2 + (q.z - p.z) ^ 2
                if d < bd then bd, bw = d, q.w end
            end
            p.w = bw
        end
    end
    return R
end

--- Follow the road under (x, z) both ways and straighten it. `isRoadOf(cls)` returns the class's
--- isRoad(x, z). Tries paved first, then track. Returns { pts, class, width, startTag, endTag,
--- startNode, endNode } (nodes are the fork mouths, for the gap left to the junction tool) or nil.
function RF.walkFrom(isRoadOf, x, z, classes)
    for _, cls in ipairs(classes or { "paved", "track" }) do
        local isRoad = isRoadOf(cls)
        if isRoad ~= nil then
            local cx, cz, hx, hz, w = RF.seedRoad(isRoad, x, z, cls)
            if cx ~= nil then
                local fwd, endTag, endAt = RF.walkRoad(isRoad, cls, cx, cz, hx, hz, w)
                local back, startTag, startAt = RF.walkRoad(isRoad, cls, cx, cz, -hx, -hz, w)
                local P = {}
                for i = #back, 2, -1 do P[#P + 1] = back[i] end
                for i = 1, #fwd do P[#P + 1] = fwd[i] end
                if #P >= 3 then
                    local S = RF.straighten(P, 0.75)
                    return {
                        pts = S, raw = P, class = cls, width = medianWidth(S, 6), len = polylineLength(S),
                        startTag = startTag, endTag = endTag,
                        startNode = startAt and { x = startAt.x, z = startAt.z, tag = "fork" } or nil,
                        endNode = endAt and { x = endAt.x, z = endAt.z, tag = "fork" } or nil,
                    }
                end
            end
        end
    end
    return nil
end

--- A found stretch's line redrawn by WALKING it with a filter. The square's centre line is the guide
--- (it already knows the corners and the forks); every 2 m the road is read straight across the guide,
--- and the line's offset from the guide is low-pass filtered toward the middle of the band found there:
--- one-off bumps (a patch of paint, one rut read alone) are gated out, the rest is smoothed, run both
--- ways and averaged so the line does not lag behind a bend. Where the stretch ran off the read square
--- the free walker carries it on. Then straightened. Decks keep the square's line (under a bridge the
--- paint is the river). Returns a new stretch with the same tags and nodes, or nil (keep the old).
RF.FILTER = { gain = 0.25, gate = 2.0, headSpan = 3, reacquire = 4 }
RF.FORK_BEND = 10                -- metres before a fork where the found line bends toward the fork's middle
function RF.refineStretch(st, isRoadOf, isStopOf, isField)
    RF.walkIsField = isField
    local ok, out = pcall(RF.refineStretchInner, st, isRoadOf, isStopOf)
    RF.walkIsField = nil
    if not ok then error(out, 0) end
    return out
end

function RF.refineStretchInner(st, isRoadOf, isStopOf)
    for _, p in ipairs(st.pts) do if p.deck then return nil end end
    local cls = st.class
    local isRoad = isRoadOf(cls)
    if isRoad == nil then return nil end
    local W, F = RF.WALK, RF.FILTER
    local G = resampleFixed(st.pts, W.step)
    -- Near a fork the square's centre line bends toward the fork's middle. Leave out the guide within
    -- FORK_BEND (or 1.5 road widths) of a fork and carry the walked line on straight there instead.
    local bend = max(RF.FORK_BEND, 1.5 * (st.width or 4))
    local cutStart, cutEnd = 0, 0
    local function nearFork(tag, node) return (tag == "fork" or tag == "wide") and node ~= nil end
    if nearFork(st.startTag, st.startNode) then
        while #G > 6 and sqrt((G[1].x - st.startNode.x) ^ 2 + (G[1].z - st.startNode.z) ^ 2) < bend do
            table.remove(G, 1)
            cutStart = cutStart + W.step
        end
    end
    if nearFork(st.endTag, st.endNode) then
        while #G > 6 and sqrt((G[#G].x - st.endNode.x) ^ 2 + (G[#G].z - st.endNode.z) ^ 2) < bend do
            table.remove(G)
            cutEnd = cutEnd + W.step
        end
    end
    local n = #G
    if n < 4 then return nil end
    -- the guide's heading at each point, over a few points either side (the square's line steps)
    local nxs, nzs = {}, {}
    for i = 1, n do
        local a, b = G[max(1, i - F.headSpan)], G[min(n, i + F.headSpan)]
        local hx, hz = b.x - a.x, b.z - a.z
        local l = sqrt(hx * hx + hz * hz)
        if l < 1e-6 then hx, hz, l = 1, 0, 1 end
        nxs[i], nzs[i] = -hz / l, hx / l
    end
    -- what each cross-section reads: the band middle nearest the guide, and its width
    local meas, widths = {}, {}
    for i = 1, n do
        local bands = bandsAt(isRoad, G[i].x, G[i].z, nxs[i], nzs[i], cls)
        local pick = nil
        for _, b in ipairs(bands) do
            if b.w >= W.minBand[cls] and abs(b.mid) <= W.half and (pick == nil or abs(b.mid) < abs(pick.mid)) then pick = b end
        end
        if pick ~= nil then meas[i], widths[i] = pick.mid, pick.w end
        work(40)
    end
    -- filter forward and backward, each gating readings that jump too far from where it is. It starts
    -- from the MEDIAN of the first readings (one bad first reading - a yard at the track's end - used
    -- to lock the filter on the wrong side, rejecting every good reading after it: 2026-10-12 game
    -- test), and if several readings in a row agree with each other but not with it, it moves to them.
    local function pass(from, to, dir)
        local out = {}
        local first = {}
        for i = from, to, dir do
            if meas[i] ~= nil then first[#first + 1] = meas[i] end
            if #first >= 10 then break end
        end
        table.sort(first)
        local off = first[floor((#first + 1) / 2)] or 0
        local held = {}
        for i = from, to, dir do
            local m = meas[i]
            if m ~= nil then
                if abs(m - off) <= F.gate + 0.25 * (widths[i] or 0) then
                    off = off + F.gain * (m - off)
                    held = {}
                else
                    held[#held + 1] = m
                    if #held >= F.reacquire then
                        local lo, hi, sum = math.huge, -math.huge, 0
                        for _, v in ipairs(held) do lo, hi, sum = min(lo, v), max(hi, v), sum + v end
                        if hi - lo <= 1.0 then off = sum / #held end
                        held = {}
                    end
                end
            end
            out[i] = off
        end
        return out
    end
    local fw, bw = pass(1, n, 1), pass(n, 1, -1)
    local R = {}
    for i = 1, n do
        local off = (fw[i] + bw[i]) / 2
        R[i] = { x = G[i].x + nxs[i] * off, z = G[i].z + nzs[i] * off, w = widths[i] or G[i].w }
    end
    -- carry the line on straight over the part left out near a fork, along its own last heading
    local function extend(atEnd, length)
        if length <= 0 or #R < 4 then return end
        local p, q
        if atEnd then p, q = R[#R - 3], R[#R] else p, q = R[4], R[1] end
        local hx, hz = q.x - p.x, q.z - p.z
        local l = sqrt(hx * hx + hz * hz)
        if l < 1e-6 then return end
        hx, hz = hx / l, hz / l
        local d = W.step
        while d <= length + 1e-6 do
            local e = { x = q.x + hx * d, z = q.z + hz * d, w = q.w }
            if atEnd then R[#R + 1] = e else table.insert(R, 1, e) end
            d = d + W.step
        end
    end
    extend(false, cutStart)
    extend(true, cutEnd)
    -- Steady ends: the last metres are read with fewer points either side and drift. Carry the line's
    -- own straight course (read 8-20 m in) out over its last 8 m, unless the road bends there.
    local function steady(atEnd)
        local m = #R
        if m < 12 then return end
        local function at(k) if atEnd then return R[m + 1 - k] else return R[k] end end
        local a, b = at(5), at(11)                      -- 8 m and 20 m in (2 m steps)
        local tip = at(1)
        local ux, uz = a.x - b.x, a.z - b.z              -- outward along the course
        local ul = sqrt(ux * ux + uz * uz)
        local vx, vz = tip.x - a.x, tip.z - a.z
        local vl = sqrt(vx * vx + vz * vz)
        if ul < 1e-6 or vl < 1e-6 then return end
        ux, uz = ux / ul, uz / ul
        if (ux * vx + uz * vz) / vl < cos(math.rad(20)) then return end   -- a real bend at the end
        for k = 1, 4 do
            local p = at(k)
            local d = (5 - k) * W.step
            p.x, p.z = a.x + ux * d, a.z + uz * d
        end
    end
    steady(false)
    steady(true)
    local out = { startTag = st.startTag, endTag = st.endTag, startNode = st.startNode, endNode = st.endNode }
    -- ran off the read square: carry on with the free walker from that end
    local isStop = isStopOf ~= nil and isStopOf(cls) or nil
    local function carryOn(atEnd)
        local p, q
        if atEnd then p, q = R[max(1, n - 3)], R[n] else p, q = R[min(n, 4)], R[1] end
        local hx, hz = q.x - p.x, q.z - p.z
        local more, tag, at = RF.walkRoad(isRoad, cls, q.x, q.z, hx, hz, q.w or st.width or 4, isStop)
        return more, tag, at
    end
    if st.endTag == "edge" then
        local more, tag, at = carryOn(true)
        for i = 2, #more do R[#R + 1] = more[i] end
        out.endTag = tag
        out.endNode = at and { x = at.x, z = at.z, tag = "fork" } or nil
    end
    if st.startTag == "edge" then
        local more, tag, at = carryOn(false)
        local front = {}
        for i = #more, 2, -1 do front[#front + 1] = more[i] end
        for _, p in ipairs(R) do front[#front + 1] = p end
        R = front
        out.startTag = tag
        out.startNode = at and { x = at.x, z = at.z, tag = "fork" } or nil
    end
    -- straighten, but never so far that the line leaves the middle it read: on a narrow road a bend
    -- cut by straightening put the line half off the paving (2026-10-12 game test)
    local w = medianWidth(R, 0) or st.width or 4
    local S = RF.straighten(R, min(0.75, 0.15 * w))
    local limit = max(0.4, 0.2 * w)
    local worst = 0
    for _, q in ipairs(R) do
        local bd = math.huge
        for k = 1, #S - 1 do
            local a, b = S[k], S[k + 1]
            local dx, dz = b.x - a.x, b.z - a.z
            local l2 = dx * dx + dz * dz
            local t = 0
            if l2 > 0 then t = max(0, min(1, ((q.x - a.x) * dx + (q.z - a.z) * dz) / l2)) end
            local d = sqrt((q.x - a.x - dx * t) ^ 2 + (q.z - a.z - dz * t) ^ 2)
            if d < bd then bd = d end
        end
        if bd > worst then worst = bd end
    end
    if worst > limit then S = resampleFixed(smoothPts(R, 2), 2) end
    out.pts = S
    out.walk = { sections = n, read = 0, ruts = 0 }
    for i = 1, n do if meas[i] ~= nil then out.walk.read = out.walk.read + 1 end end
    out.class, out.kind, out.edge = st.class, st.kind, st.edge
    out.width = medianWidth(S, 6) or st.width
    out.len = polylineLength(S)
    out.refined = true
    return out
end

--- The ground straight across a line at its point i, as text for the log: one character per 0.5 m
--- from 8 m left to 8 m right ('.' nothing, 'F' field, 'd' dirt, 'g' gravel, 'p' paved, '|' the line).
function RF.crossText(kindAt, P, i, isField)
    local a, b = P[max(1, i - 2)], P[min(#P, i + 2)]
    local hx, hz = b.x - a.x, b.z - a.z
    local l = sqrt(hx * hx + hz * hz)
    if l < 1e-6 then return "" end
    local nx, nz = -hz / l, hx / l
    local chars = { [0] = ".", [1] = "d", [2] = "g", [3] = "p" }
    local t = {}
    for o = -8, 8, 0.5 do
        if abs(o) < 0.01 then t[#t + 1] = "|" end
        local x, z = P[i].x + nx * o, P[i].z + nz * o
        local k = kindAt(x, z)
        if k == 0 and isField ~= nil and isField(x, z) then t[#t + 1] = "F" else t[#t + 1] = chars[k] or "?" end
    end
    return table.concat(t)
end

--- The part of a (walked) stretch with no AutoDrive path along it: the uncovered run through its
--- middle; an end cut short by a path is tagged "path". nil if its middle is covered.
function RF.keepUncovered(st, grid)
    local P = st.pts
    local n = #P
    if n < 3 then return st end
    local half = (st.width or 6) / 2
    local cov = {}
    for i = 1, n do cov[i] = coveredAt(grid, P, i, half) end
    local m = floor(n / 2) + 1
    if cov[m] then return nil end
    local i0, i1 = m, m
    while i0 > 1 and not cov[i0 - 1] do i0 = i0 - 1 end
    while i1 < n and not cov[i1 + 1] do i1 = i1 + 1 end
    if i0 == 1 and i1 == n then return st end
    local out = {}
    for k, v in pairs(st) do out[k] = v end
    out.pts = {}
    for i = i0, i1 do out.pts[#out.pts + 1] = P[i] end
    if i0 > 1 then out.startTag, out.startNode = "path", nil end
    if i1 < n then out.endTag, out.endNode = "path", nil end
    out.len = polylineLength(out.pts)
    return out
end

-- ------------------------------------------------------------------------- laying lanes

--- Cut a polyline back from its start until it is `gap` metres (straight line) from (cx, cz).
local function trimFrom(P, cx, cz, gap)
    local i = 1
    while i < #P and sqrt((P[i].x - cx) ^ 2 + (P[i].z - cz) ^ 2) < gap do i = i + 1 end
    if i >= #P then return nil end
    local out = {}
    -- the exact crossing point between i-1 and i
    if i > 1 then
        local a, b = P[i - 1], P[i]
        local lo, hi = 0, 1
        for _ = 1, 20 do
            local m = (lo + hi) / 2
            local x, z = a.x + (b.x - a.x) * m, a.z + (b.z - a.z) * m
            if sqrt((x - cx) ^ 2 + (z - cz) ^ 2) < gap then lo = m else hi = m end
        end
        out[1] = lerpPt(a, b, hi)
    end
    for k = i, #P do out[#out + 1] = P[k] end
    return out
end

local function reversed(P)
    local r = {}
    for i = #P, 1, -1 do r[#r + 1] = P[i] end
    return r
end
RF.reversed = reversed

--- Offset a polyline sideways by d (positive = right of its point order): a number, or a list with
--- one offset per point. Heights and the deck mark carry across.
local function offsetLine(P, d)
    local out = {}
    for i = 1, #P do
        local a, b = P[max(1, i - 1)], P[min(#P, i + 1)]
        local hx, hz = b.x - a.x, b.z - a.z
        local l = sqrt(hx * hx + hz * hz)
        if l < 1e-6 then l = 1 end
        local rx, rz = -hz / l, hx / l
        local di = (type(d) == "table") and d[i] or d
        out[i] = { x = P[i].x + rx * di, z = P[i].z + rz * di, w = P[i].w, y = P[i].y, deck = P[i].deck }
    end
    -- drop points that fold back (inside of a tight bend)
    local clean = { out[1] }
    for i = 2, #out do
        local p, q = clean[#clean], out[i]
        local a, b = P[max(1, i - 1)], P[i]
        local hx, hz = b.x - a.x, b.z - a.z
        if (q.x - p.x) * hx + (q.z - p.z) * hz > 0.05 or i == #out then clean[#clean + 1] = q end
    end
    return clean
end
RF.offsetLine = offsetLine

--- Resample for AutoDrive: points up to `maxStep` apart on the straight, closer in bends so no point
--- turns more than `maxTurn` degrees, never closer than `minStep`.
function RF.resampleForDriving(P, minStep, maxStep, maxTurn)
    minStep, maxStep, maxTurn = minStep or 2, maxStep or 6, maxTurn or 8
    local fine = resampleFixed(P, 1)
    if #fine < 3 then return fine end
    local out = { fine[1] }
    local lastI = 1
    local i = 2
    while i < #fine do
        local p = out[#out]
        local dist = sqrt((fine[i].x - p.x) ^ 2 + (fine[i].z - p.z) ^ 2)
        local take = false
        if dist >= maxStep then take = true
        elseif dist >= minStep then
            -- heading from the last kept point to here vs from here a step on
            local q = fine[min(#fine, i + floor(minStep))]
            local h1 = atan2(fine[i].z - p.z, fine[i].x - p.x)
            local h2 = atan2(q.z - fine[i].z, q.x - fine[i].x)
            local dh = abs(h2 - h1)
            if dh > pi then dh = 2 * pi - dh end
            -- the bend between the previous kept segment and this one
            if #out >= 2 then
                local o = out[#out - 1]
                local h0 = atan2(p.z - o.z, p.x - o.x)
                local db = abs(h1 - h0)
                if db > pi then db = 2 * pi - db end
                if math.deg(db) + math.deg(dh) > maxTurn then take = true end
            elseif math.deg(dh) > maxTurn then take = true end
        end
        if take then out[#out + 1] = fine[i] lastI = i end
        i = i + 1
    end
    local last = fine[#fine]
    local tail = out[#out]
    if sqrt((last.x - tail.x) ^ 2 + (last.z - tail.z) ^ 2) < minStep * 0.6 and #out > 1 then
        out[#out] = last
    else
        out[#out + 1] = last
    end
    return out
end

--- The centre line of a stretch as it will be laid: ends at forks (and yards) cut back by `forkGap`
--- so the junction tool has room. Returns nil if nothing is left.
function RF.layCentre(st, forkGap)
    local P = st.pts
    local function gapFor(tag) return (tag == "fork" or tag == "wide") and forkGap or 0 end
    local g0, g1 = gapFor(st.startTag), gapFor(st.endTag)
    if g0 > 0 and st.startNode ~= nil then P = trimFrom(P, st.startNode.x, st.startNode.z, g0) end
    if P == nil then return nil end
    if g1 > 0 and st.endNode ~= nil then
        local r = trimFrom(reversed(P), st.endNode.x, st.endNode.z, g1)
        if r == nil then return nil end
        P = reversed(r)
    end
    if polylineLength(P) < 6 then return nil end
    return P
end

local function anyDeck(P)
    for _, p in ipairs(P) do if p.deck then return true end end
    return false
end

local function slice(P, i0, i1)
    local out = {}
    for i = i0, i1 do out[#out + 1] = P[i] end
    return out
end

--- The lanes to lay for a stretch. mode: "one" | "two" | "lanes". dir: +1 along the stretch's point
--- order, -1 against (one-way only). gap: lane centre spacing (lanes only).
---
--- `fit` (optional) keeps the lanes clear of the road's SIDES - railings, walls, a bank, the edge of a
--- bridge deck: { clear = function(p, rx, rz) -> roomLeft, roomRight (metres from the centre line to
--- the first thing in the way on each side, nil = nothing), everywhere = false (bridges only) or true,
--- rigClear = half a rig's width plus a margin, minGap = the least the two lanes may be apart,
--- taper = metres over which a lane eases in or out }.
---   Two lanes: each lane comes in as far as its side needs, never closer than minGap to the other;
---   where both lanes cannot fit, that part is ONE two-way line down the middle of the room, the lanes
---   joining it before and leaving it after.
---   One line (one-way or two-way): moved off the middle only as far as a side needs.
---
--- Returns a list of { pts, dual, startAt, endAt } ("start" / "end": which end of the stretch that end
--- of the lane sits at, for joining), with .links = { { from = k, to = m } } (lane k's last point to
--- lane m's first, one-way), .collapsed (metres laid as one line), .pulled (true if a lane came in),
--- .tooNarrow (true if even one rig does not fit somewhere). nil when the stretch is too short.
function RF.planLanes(st, mode, dir, gap, forkGap, fit)
    local C = RF.layCentre(st, forkGap)
    if C == nil then return nil end
    local lanes = { links = {}, collapsed = 0, pulled = false, tooNarrow = false }
    local back = mode == "one" and (dir or 1) < 0
    if back then C = reversed(C) end
    local useFit = fit ~= nil and fit.clear ~= nil and (fit.everywhere or anyDeck(C))
    if not useFit then
        if mode == "one" then
            lanes[1] = { pts = RF.resampleForDriving(C), dual = false,
                startAt = back and "end" or "start", endAt = back and "start" or "end" }
        elseif mode == "two" then
            lanes[1] = { pts = RF.resampleForDriving(C), dual = true, startAt = "start", endAt = "end" }
        else
            local h = (gap or 4) / 2
            -- keep right: the lane right of the point order drives along it, the left one back
            lanes[1] = { pts = RF.resampleForDriving(offsetLine(C, h)), dual = false, startAt = "start", endAt = "end" }
            lanes[2] = { pts = RF.resampleForDriving(reversed(offsetLine(C, -h))), dual = false, startAt = "end", endAt = "start" }
        end
        return lanes
    end

    C = resampleFixed(C, 2)
    local n = #C
    local c = fit.rigClear or 1.8
    local gmin = fit.minGap or 3.3
    local BIG = 1e6
    local L, R, applies = {}, {}, {}
    for i = 1, n do
        applies[i] = fit.everywhere or C[i].deck == true
        L[i], R[i] = BIG, BIG
    end
    -- probe every other point (4 m) where fitting applies; the ones between take the tighter neighbour
    for i = 1, n do
        if applies[i] and (i % 2 == 1 or i == n) then
            local a, b = C[max(1, i - 1)], C[min(n, i + 1)]
            local hx, hz = b.x - a.x, b.z - a.z
            local l = sqrt(hx * hx + hz * hz)
            if l > 1e-6 then
                local l1, r1 = fit.clear(C[i], -hz / l, hx / l)
                L[i], R[i] = l1 or BIG, r1 or BIG
            end
        end
    end
    for i = 2, n - 1 do
        if applies[i] and i % 2 == 0 then
            L[i] = min(L[i - 1], L[i + 1])
            R[i] = min(R[i - 1], R[i + 1])
        end
    end
    -- the allowed band for a rig's centre line [lo, hi] (left of the centre is negative), eased over
    -- the taper so a lane moves in BEFORE the narrow part rather than at it
    local tp = max(1, floor((fit.taper or 10) / 2))
    local lo, hi = {}, {}
    for i = 1, n do
        local l0, h0 = -BIG, BIG
        for j = max(1, i - tp), min(n, i + tp) do
            l0 = max(l0, -(L[j] - c))
            h0 = min(h0, R[j] - c)
        end
        lo[i], hi[i] = l0, h0
        if h0 < l0 then lanes.tooNarrow = true end
    end
    local pl, pr, mid, single = {}, {}, {}, {}
    local half = (gap or 4) / 2
    for i = 1, n do
        local l0, h0 = lo[i], hi[i]
        local m0 = 0
        if h0 < l0 then m0 = (l0 + h0) / 2 elseif m0 < l0 then m0 = l0 elseif m0 > h0 then m0 = h0 end
        mid[i] = m0
        if mode == "lanes" then
            local a, b = max(-half, l0), min(half, h0)
            if b - a < gmin then
                if h0 - l0 >= gmin then
                    -- room for both lanes only off the middle: slide the pair, keeping the minimum gap
                    local mm = (l0 + h0) / 2
                    if l0 < -BIG / 2 then mm = h0 - gmin / 2 end
                    if h0 > BIG / 2 then mm = l0 + gmin / 2 end
                    a, b = mm - gmin / 2, mm + gmin / 2
                else
                    single[i] = true
                end
            end
            pl[i], pr[i] = a, b
            if a > -half + 0.05 or b < half - 0.05 then lanes.pulled = true end
        end
    end
    -- light smoothing of the offsets (the probes step in 0.5 m)
    local function smoothed(v)
        local out = {}
        for i = 1, n do
            local sum, k = 0, 0
            for j = max(1, i - 2), min(n, i + 2) do
                if v[j] ~= nil then sum, k = sum + v[j], k + 1 end
            end
            out[i] = (k > 0) and sum / k or v[i]
        end
        return out
    end
    mid = smoothed(mid)

    if mode ~= "lanes" then
        for i = 1, n do if abs(mid[i]) > 0.05 then lanes.pulled = true end end
        lanes[1] = { pts = RF.resampleForDriving(offsetLine(C, mid)), dual = (mode == "two"),
            startAt = back and "end" or "start", endAt = back and "start" or "end" }
        return lanes
    end

    pl, pr = smoothed(pl), smoothed(pr)
    -- sections: runs of two lanes and of one line; a lane run too short to be worth it joins the line
    local sections = {}
    local i = 1
    while i <= n do
        local j = i
        while j < n and (single[j + 1] == true) == (single[i] == true) do j = j + 1 end
        sections[#sections + 1] = { single = single[i] == true, i0 = i, i1 = j }
        i = j + 1
    end
    local merged = {}
    for _, sec in ipairs(sections) do
        if not sec.single and sec.i1 - sec.i0 < 3 and #sections > 1 then sec.single = true end
        local prev = merged[#merged]
        if prev ~= nil and prev.single == sec.single then prev.i1 = sec.i1 else merged[#merged + 1] = sec end
    end
    sections = merged
    -- lay each section; neighbouring sections are joined end to end by one-way links
    local prevSec = nil
    for _, sec in ipairs(sections) do
        local i0, i1 = sec.i0, sec.i1
        if sec.single then
            local P = offsetLine(slice(C, i0, i1), slice(mid, i0, i1))
            if #P < 2 then P = { C[i0], C[min(n, i0 + 1)] } end
            lanes[#lanes + 1] = { pts = RF.resampleForDriving(P), dual = true,
                startAt = (i0 == 1) and "start" or nil, endAt = (i1 == n) and "end" or nil }
            sec.line = #lanes
            lanes.collapsed = lanes.collapsed + polylineLength(slice(C, i0, i1))
        else
            local right = offsetLine(slice(C, i0, i1), slice(pr, i0, i1))
            local left = reversed(offsetLine(slice(C, i0, i1), slice(pl, i0, i1)))
            lanes[#lanes + 1] = { pts = RF.resampleForDriving(right), dual = false,
                startAt = (i0 == 1) and "start" or nil, endAt = (i1 == n) and "end" or nil }
            sec.right = #lanes
            lanes[#lanes + 1] = { pts = RF.resampleForDriving(left), dual = false,
                startAt = (i1 == n) and "end" or nil, endAt = (i0 == 1) and "start" or nil }
            sec.left = #lanes
        end
        if prevSec ~= nil then
            if prevSec.single then
                -- line, then lanes: the line feeds the right lane; the left lane runs into the line
                lanes.links[#lanes.links + 1] = { from = prevSec.line, to = sec.right }
                lanes.links[#lanes.links + 1] = { from = sec.left, to = prevSec.line, toEnd = true }
            else
                -- lanes, then line: the right lane runs into the line; the line feeds the left lane
                lanes.links[#lanes.links + 1] = { from = prevSec.right, to = sec.line }
                lanes.links[#lanes.links + 1] = { from = sec.line, to = prevSec.left, fromStart = true }
            end
        end
        prevSec = sec
    end
    return lanes
end

return RF

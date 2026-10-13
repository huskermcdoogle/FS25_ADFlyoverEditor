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
RF.MIN_PAVED_WIDTH = 3.0         -- narrower paved lines beside a wider paved road are kerbs or seams
RF.MIN_LANE_WIDTH = 0.9          -- narrower than this is never a road (a 2 m strip reads 1 m: 2 x distance - 1)
RF.PAVED_SEED_REACH = 4         -- paving this close to the mouse is the road meant
RF.PAVED_EDGE = 2.5              -- gravel/dirt this close to paving is that paved road's edge
RF.KERB_DIST = 8                 -- a narrow paved line this close to a wider one runs beside it
RF.SHOULDER_DIST = 3.5           -- a track line this close to paved road is that road's shoulder
RF.BUBBLE_MAX = 60               -- two lines between the same two forks, both shorter than this, are one road
RF.SPUR_MIN = 10                 -- dead-end spurs shorter than this (or the road's width) are noise
RF.MIN_STRETCH = 15              -- uncovered stretches shorter than this are not offered
RF.MIN_LOOSE = 40                -- a line with no fork at either end shorter than this is a paint scrap
RF.COVER_SMOOTH = 8              -- covered/uncovered runs shorter than this take their neighbours' side
RF.COVER_ANGLE = 35              -- a path within this many degrees of the road's line counts as along it
RF.TRACK_REACH = 10              -- a track ending this close to a paved road meets it (the mouth is often all mud)
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
    -- A paved road's own edges belong to it: gravel or dirt within PAVED_EDGE of the paving is read
    -- as part of the paved road when finding it. An old narrow lane (2 m of ragged asphalt with mossy
    -- gravel edges) fell apart into scraps with false forks otherwise (2026-10-12); with its edges it
    -- reads as one road. The line itself is still placed on the paving (the walker reads paving only).
    local nearPaved = nil
    do
        local pm, any = {}, false
        for i = 1, W * H do
            if win.kinds[i] == RF.KIND_PAVED then pm[i] = 0 any = true else pm[i] = 1 end
        end
        if any then nearPaved = distanceToEdge(pm, W, H) end
    end
    local paved, pavedMask, pavedDist = newGraph(), nil, nil
    if wanted[RF.KIND_PAVED] then
        paved, pavedMask, pavedDist = buildClass(win, function(k, i)
            if k == RF.KIND_PAVED then return true end
            return (k == RF.KIND_GRAVEL or k == RF.KIND_DIRT) and nearPaved ~= nil and nearPaved[i] <= RF.PAVED_EDGE
        end, RF.MAX_ROAD_WIDTH.paved, RF.CLOSE_RADIUS.paved)
    end
    local track = newGraph()
    if wanted[RF.KIND_GRAVEL] or wanted[RF.KIND_DIRT] then
        track = buildClass(win, function(k)
            return (k == RF.KIND_GRAVEL and wanted[RF.KIND_GRAVEL]) or (k == RF.KIND_DIRT and wanted[RF.KIND_DIRT])
        end, RF.MAX_ROAD_WIDTH.track, RF.CLOSE_RADIUS.track)
    end
    -- Narrow paved lines: a kerb or a paint seam runs right alongside a wider paved road and is dropped;
    -- one on its own is a narrow lane (an old 2-3 m asphalt track with mossy gravel edges, which looks
    -- like a dirt road - 2026-10-12: it was never found) and is kept.
    for _, e in ipairs(paved.edges) do e.class = "paved" end
    for _, e in ipairs(paved.edges) do
        if not e.dead and (e.width or 0) < RF.MIN_PAVED_WIDTH then
            local beside, probes = 0, 0
            for k = 1, #e.pts, 4 do
                probes = probes + 1
                local p = e.pts[k]
                local near = false
                for _, f in ipairs(paved.edges) do
                    if f ~= e and not f.dead and (f.width or 0) >= RF.MIN_PAVED_WIDTH then
                        for q = 1, #f.pts, 2 do
                            if (f.pts[q].x - p.x) ^ 2 + (f.pts[q].z - p.z) ^ 2 < RF.KERB_DIST ^ 2 then near = true break end
                        end
                    end
                    if near then break end
                end
                if near then beside = beside + 1 end
            end
            if (e.width or 0) < RF.MIN_LANE_WIDTH or (probes > 0 and beside / probes > 0.5) then removeEdge(paved, e) end
        end
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
    -- Only a real track makes a fork where it meets a paved road: one at least MIN_LOOSE long, or
    -- joined to another road at its far end. Dirt scraps beside a road (a patch of mud, forest floor)
    -- cut a narrow lane into 10 m pieces otherwise (2026-10-12).
    local function isRealTrack(n)
        local e = n.edges[1]
        if e == nil then return false end
        local far = otherEnd(e, n)
        return (e.len or polylineLength(e.pts)) >= RF.MIN_LOOSE or (far ~= nil and #far.edges >= 2)
    end
    -- a track ending at a paved road makes a fork on the paved road
    for _, n in ipairs(track.nodes) do
        if not n.dead and #n.edges == 1 and distPaved(n.x, n.z) <= RF.TRACK_REACH and isRealTrack(n) then
            local e, i, dd, px, pz = nearestOnGraph(paved, n.x, n.z, nil)
            if e ~= nil and dd <= (e.width or 6) / 2 + RF.TRACK_REACH then
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
    pavedGap = 2.5,                 -- gaps bridged across a paved road
    tightGap = 1.0,                 -- tried first: only a band narrower than rutWidth is read again with joinGap
    rutWidth = 2.5,
    rutMax = 2.0,                   -- a wheel rut is at most this wide
    rutGapMin = 0.4,                -- the grass strip between two ruts: at least ...
    rutGapMax = 3.0,                -- ... and at most this wide                 -- (a solid track must not swallow the gravel patches beside it)
    minBand = { track = 1.5, paved = 1.5 },   -- narrower bands are not a road (old lanes are 2-3 m)
    gainPos = 0.3,                  -- how far toward the measured middle the line moves per step
    maxTurn = 12,                   -- degrees per step (12 deg / 2 m: bends down to ~10 m radius)
    lookAhead = 6,                  -- metres ahead the walker aims at the road's middle
    settle = 0.5,                   -- how far onto the middle just in front each step settles
    steerWide = 1.4,                -- readings wider than this x usual (a mouth) hold the course
    gate = 2.5,                     -- a middle further off than this (plus a quarter of the width) is noise
    maxMiss = 6,                    -- steps with no road ahead before the road has ended (12 m)
    widen = 2.0,                    -- the band this many times its usual width: a fork's mouth
    widenMin = 4.0,                 -- ... and at least this much wider (a 2 m lane's 4 m patch is no mouth)
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
    -- paved: patches of other paint across a road (wet-look, gravel, shadow) are bridged up to
    -- pavedGap, or a patch in the middle splits the road and the line jumps to one half (wavy lanes,
    -- 2026-10-12)
    local bands = RF.crossSection(isRoad, x, z, nx, nz, W.half, W.res, (cls == "paved") and W.pavedGap or W.tightGap)
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
function RF.seedRoad(isRoad, x, z, cls, reach)
    local W = RF.WALK
    reach = reach or 1.5
    local best = nil
    for a = 0, 170, 10 do
        local nx, nz = cos(math.rad(a)), sin(math.rad(a))
        local bands = bandsAt(isRoad, x, z, nx, nz, cls)
        for _, b in ipairs(bands) do
            if b.lo <= reach and b.hi >= -reach and b.w >= W.minBand[cls] and b.w <= (RF.MAX_ROAD_WIDTH[cls] or 16)
                and (best == nil or b.w < best.w) then
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
    -- Steered like a driver (pure pursuit): look `lookAhead` metres on, aim at the middle of the road
    -- there; then step and settle onto the middle just in front. An earlier walker turned a fraction of
    -- the way toward the middle each step and expected bends to carry on: it over-steered, weaved, ran
    -- alongside a 2 m lane 3.5 m off and gave up (2026-10-12 trace).
    local W = RF.WALK
    local hl = sqrt(hx * hx + hz * hz)
    hx, hz = hx / hl, hz / hl
    local pts = { { x = x, z = z, w = w0 } }
    local widths = { w0 }
    local miss, len, wideRun = 0, 0, 0
    local px, pz = x, z
    local maxTurnCos = cos(math.rad(W.maxTurn))
    local function usualWidth()
        local recent = {}
        for i = max(1, #widths - 10), #widths do recent[#recent + 1] = widths[i] end
        table.sort(recent)
        return recent[floor((#recent + 1) / 2)] or w0
    end
    -- the middle of the road across the line at distance d ahead: offset along the normal, width
    local function middleAt(d, hx2, hz2)
        local qx, qz = px + hx2 * d, pz + hz2 * d
        local nx, nz = -hz2, hx2
        local bands = bandsAt(isRoad, qx, qz, nx, nz, cls)
        local pick = nil
        local maxW = RF.MAX_ROAD_WIDTH[cls] or 16
        for _, b in ipairs(bands) do
            -- wider than a road can be is a yard or a muddy patch: not road to walk along
            if b.w >= W.minBand[cls] and b.w <= maxW and abs(b.mid) <= W.gate + 0.25 * b.w then
                if pick == nil or abs(b.mid) < abs(pick.mid) then pick = b end
            end
        end
        if RF.TRACE then
            local t = {}
            for _, b in ipairs(bands) do t[#t + 1] = string.format("%+.1f/%.1f", b.mid, b.w) end
            print(string.format("  look %d m at (%.1f,%.1f) heading %.0f: bands %s -> %s", d, qx, qz,
                math.deg(atan2(hz2, hx2)), table.concat(t, " "), pick and string.format("%+.1f", pick.mid) or "none"))
        end
        if pick == nil then return nil end
        return qx + nx * pick.mid, qz + nz * pick.mid, pick.w
    end
    -- a reading much wider than the road usually is (a side road's mouth) is not steered by: its
    -- middle is pulled toward the side road (a 3.5 m swerve at a T, 2026-10-12)
    local function steerable(w2, usual) return w2 ~= nil and w2 <= max(W.steerWide * usual, usual + 1.5) end
    while len < W.maxLen do
        local nearX, nearZ = px + hx * W.step, pz + hz * W.step
        if isStop ~= nil and isStop(nearX, nearZ) then return pts, "fork", { x = nearX, z = nearZ } end
        local usual = usualWidth()
        -- aim: the middle a look-ahead on (fall back to the middle just in front)
        local fx, fz, fw = middleAt(W.lookAhead, hx, hz)
        local cx, cz, cw = middleAt(W.step, hx, hz)
        if fx == nil and cx == nil then
            -- nothing straight on: look round. Road in ONE direction is a corner: take it. Road in
            -- more than one direction is a junction: the run ends there, as a fork.
            local hits = {}
            for a = -80, 80, 10 do
                if a ~= 0 then
                    local rx, rz = rot(hx, hz, a)
                    local tx, tz, tw = middleAt(W.lookAhead, rx, rz)
                    if tx ~= nil then hits[#hits + 1] = { a = a, x = tx, z = tz, w = tw, hx = rx, hz = rz } end
                end
            end
            local groups = {}
            for _, h in ipairs(hits) do
                local g = groups[#groups]
                -- readings up to 30 degrees apart are one road (a lane seen at -20 and +10 with a failed
                -- reading between is still one lane, not a junction)
                if g ~= nil and h.a - g.last <= 30 then g.last = h.a g.n = g.n + 1 g.sum = g.sum + h.a
                else groups[#groups + 1] = { first = h.a, last = h.a, n = 1, sum = h.a, hit = h } end
            end
            -- groups whose middles are under 45 degrees apart are one road too
            local merged = {}
            for _, g in ipairs(groups) do
                local m = merged[#merged]
                if m ~= nil and (g.sum / g.n) - (m.sum / m.n) < 45 then
                    m.last, m.n, m.sum = g.last, m.n + g.n, m.sum + g.sum
                else merged[#merged + 1] = g end
            end
            groups = merged
            if #groups == 1 then
                local g = groups[1]
                local best = nil
                for _, h in ipairs(hits) do
                    if best == nil or abs(h.a - g.sum / g.n) < abs(best.a - g.sum / g.n) then best = h end
                end
                hx, hz = best.hx, best.hz
                fx, fz, fw = best.x, best.z, best.w
            elseif #groups > 1 then
                if RF.TRACE then
                    local t = {}
                    for _, g in ipairs(groups) do t[#t + 1] = string.format("%d..%d", g.first, g.last) end
                    print("  junction: road at angles " .. table.concat(t, ", "))
                end
                return pts, "fork", { x = px + hx * W.step, z = pz + hz * W.step }
            end
        end
        if fx == nil and cx == nil then
            miss = miss + 1
            if miss > W.maxMiss then
                for _ = 1, miss - 1 do if #pts > 1 then table.remove(pts) end end
                return pts, "end"
            end
            px, pz = nearX, nearZ
            pts[#pts + 1] = { x = px, z = pz, w = usual, blind = true }
        else
            miss = 0
            local w = cw or fw
            -- a fork's mouth: the road stays much wider than usual for a few steps running
            if (#pts > 4 or w0 ~= nil) and w > max(W.widen * usual, usual + W.widenMin) then
                wideRun = wideRun + 1
                if wideRun >= 3 then
                    if RF.TRACE then print(string.format("  mouth: width %.1f vs usual %.1f", w, usual)) end
                    for _ = 1, wideRun - 1 do if #pts > 1 then table.remove(pts) end end
                    local f = pts[#pts]
                    return pts, "fork", { x = f.x + hx * W.step, z = f.z + hz * W.step }
                end
            else
                wideRun = 0
            end
            local ax, az = nil, nil
            if fx ~= nil and steerable(fw, usual) then ax, az = fx, fz
            elseif cx ~= nil and steerable(cw, usual) then ax, az = cx, cz end
            if ax == nil then ax, az = px + hx * W.lookAhead, pz + hz * W.lookAhead end   -- hold course
            local dx, dz = ax - px, az - pz
            local dl = sqrt(dx * dx + dz * dz)
            if dl > 1e-6 then
                dx, dz = dx / dl, dz / dl
                if dx * hx + dz * hz < maxTurnCos then
                    local side = (hx * dz - hz * dx) >= 0 and 1 or -1
                    dx, dz = rot(hx, hz, side * W.maxTurn)
                end
                hx, hz = dx, dz
            end
            px, pz = px + hx * W.step, pz + hz * W.step
            -- settle onto the middle just in front (re-read along the new heading)
            local sx, sz, sw = middleAt(0, hx, hz)
            if sx ~= nil and steerable(sw, usual) then
                px, pz = px + (sx - px) * W.settle, pz + (sz - pz) * W.settle
            end
            if wideRun == 0 then widths[#widths + 1] = w end
            pts[#pts + 1] = { x = px, z = pz, w = (wideRun == 0) and w or usual }
        end
        len = len + W.step
        if len > 40 and sqrt((px - x) ^ 2 + (pz - z) ^ 2) < W.step then return pts, "loop" end
        work(80)
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
--- Smoothing that takes out wiggles without pulling bends inward (Taubin: a smoothing step, then a
--- slightly larger step back). A plain moving average shrank a 60 m bend by about 0.4 m - the line
--- sat inside the curve. Ends held.
function RF.smoothKeepBends(P, passes)
    local n = #P
    if n < 3 then return P end
    local out = {}
    for i = 1, n do out[i] = copyPt(P[i]) end
    local function step(f)
        local dx, dz = {}, {}
        for i = 2, n - 1 do
            dx[i] = (out[i - 1].x + out[i + 1].x) / 2 - out[i].x
            dz[i] = (out[i - 1].z + out[i + 1].z) / 2 - out[i].z
        end
        for i = 2, n - 1 do
            out[i].x = out[i].x + f * dx[i]
            out[i].z = out[i].z + f * dz[i]
        end
    end
    for _ = 1, passes do
        step(0.5)
        step(-0.53)
    end
    return out
end

function RF.straighten(P, tol)
    -- Low-pass with bias correction ("twicing"): A = average over about +-10 m, B = A averaged again,
    -- line = 2A - B. Wiggles shorter than ~20 m (patchy paint, a rut read alone) are taken out; a long
    -- bend keeps its place (a plain average pulled a 60 m bend 0.4 m in; the Taubin step that fixed
    -- that let 10 m waves through on a patchy road, and simplifying first kept the waves' peaks -
    -- 2026-10-12). `tol` is no longer used.
    if #P < 3 then return P end
    local R = resampleFixed(P, 2)
    local r = RF.SMOOTH_SPAN
    local A = smoothPts(smoothPts(R, r), r)
    local B = smoothPts(smoothPts(A, r), r)
    local out = {}
    for i = 1, #R do
        out[i] = copyPt(A[i])
        out[i].x = 2 * A[i].x - B[i].x
        out[i].z = 2 * A[i].z - B[i].z
    end
    out[1].x, out[1].z = R[1].x, R[1].z
    out[#out].x, out[#out].z = R[#R].x, R[#R].z
    -- widths along the result from the walked line (nearest point)
    for _, p in ipairs(out) do
        if p.w == nil then
            local bd, bw = math.huge, nil
            for _, q in ipairs(P) do
                local d = (q.x - p.x) ^ 2 + (q.z - p.z) ^ 2
                if d < bd then bd, bw = d, q.w end
            end
            p.w = bw
        end
    end
    return out
end

--- Follow the road under (x, z) both ways and straighten it. `isRoadOf(cls)` returns the class's
--- isRoad(x, z). Tries paved first, then track. Returns { pts, class, width, startTag, endTag,
--- startNode, endNode } (nodes are the fork mouths, for the gap left to the junction tool) or nil.
--- Walk one way and carry on straight through junctions: where the walk stops at a junction, look
--- THROUGH_HOPS metres straight on; if the same road carries on there in line (within 35 degrees),
--- bridge the junction and walk on (user 2026-10-12: through roads go through T's; side roads stop).
--- Returns the points (with `bridged` marks across junctions), the end tag and the end fork point.
local W_STEP_BRIDGE = 2
RF.THROUGH_HOPS = { 15, 25, 35 }
RF.MAX_THROUGH = 12
RF.THROUGH_WALK_ANGLE = 20
local function walkThrough(isRoad, cls, x, z, hx, hz, w, isStop)
    local all = { { x = x, z = z, w = w } }
    local tag, at = "end", nil
    for _ = 1, RF.MAX_THROUGH + 1 do
        local pts
        pts, tag, at = RF.walkRoad(isRoad, cls, x, z, hx, hz, w, isStop)
        for i = 2, #pts do all[#all + 1] = pts[i] end
        if tag ~= "fork" or #all < 3 then break end
        local q, p = all[#all], all[max(1, #all - 10)]       -- the road's line over the last ~20 m
        local ux, uz = q.x - p.x, q.z - p.z
        local ul = sqrt(ux * ux + uz * uz)
        if ul < 1e-6 then break end
        ux, uz = ux / ul, uz / ul
        local found = nil
        for _, hop in ipairs(RF.THROUGH_HOPS) do
            local sx, sz, shx, shz, sw = RF.seedRoad(isRoad, q.x + ux * hop, q.z + uz * hop, cls, 3)
            if sx ~= nil then
                if shx * ux + shz * uz < 0 then shx, shz = -shx, -shz end
                -- in line within THROUGH_ANGLE, and the far road's middle no more than 3 m off the
                -- line carried on (a road crossing at a shallow angle is not the same road)
                local ox = (sx - q.x) * (-uz) + (sz - q.z) * ux
                if shx * ux + shz * uz >= cos(math.rad(RF.THROUGH_WALK_ANGLE)) and abs(ox) <= 3 then
                    found = { x = sx, z = sz, hx = shx, hz = shz, w = sw }
                    break
                end
            end
        end
        if found == nil then break end
        -- bridge the junction in a straight line, then walk on from the far side
        local dx, dz = found.x - q.x, found.z - q.z
        local d = sqrt(dx * dx + dz * dz)
        local k = W_STEP_BRIDGE
        while k < d do
            all[#all + 1] = { x = q.x + dx * k / d, z = q.z + dz * k / d, w = q.w, bridged = true }
            k = k + W_STEP_BRIDGE
        end
        x, z, hx, hz, w = found.x, found.z, found.hx, found.hz, found.w
        all[#all + 1] = { x = x, z = z, w = w }
    end
    return all, tag, at
end

function RF.walkFrom(isRoadOf, x, z, classes, isStopOf)
    for _, cls in ipairs(classes or { "paved", "track" }) do
        local isRoad = isRoadOf(cls)
        if isRoad ~= nil then
            -- paving within 4 m of the mouse wins: on an old lane (2 m of asphalt in a 6 m road with
            -- gravel edges) the mouse is usually on the edge, and the edge walked as a track gave odd
            -- short bits (2026-10-12)
            local cx, cz, hx, hz, w = RF.seedRoad(isRoad, x, z, cls, (cls == "paved") and RF.PAVED_SEED_REACH or 1.5)
            if cx ~= nil then
                local isStop = isStopOf ~= nil and isStopOf(cls) or nil
                local fwd, endTag, endAt = walkThrough(isRoad, cls, cx, cz, hx, hz, w, isStop)
                local back, startTag, startAt = walkThrough(isRoad, cls, cx, cz, -hx, -hz, w, isStop)
                local P = {}
                for i = #back, 2, -1 do P[#P + 1] = back[i] end
                for i = 1, #fwd do P[#P + 1] = fwd[i] end
                if #P >= 3 then
                    local st = {
                        pts = P, class = cls, width = medianWidth(P, 6), len = polylineLength(P),
                        startTag = startTag, endTag = endTag,
                        startNode = startAt and { x = startAt.x, z = startAt.z, tag = "fork" } or nil,
                        endNode = endAt and { x = endAt.x, z = endAt.z, tag = "fork" } or nil,
                    }
                    -- second pass: the walked line as the guide, the road read straight across it
                    -- every 2 m and the middle filtered both ways - the walker's steering cuts the
                    -- inside of bends by ~0.5 m (2026-10-12 log); this centres on the road read
                    local ok, r = pcall(RF.refineStretchInner, st, isRoadOf, isStopOf)
                    if ok and r ~= nil and #r.pts >= 3 then
                        r.raw = P
                        return r
                    end
                    st.pts = RF.straighten(P, 0.75)
                    st.raw = P
                    return st
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
RF.SMOOTH_SPAN = 5                -- points (2 m) either side in each averaging pass of the final line
RF.FILTER = { gain = 0.25, gate = 2.0, headSpan = 3, reacquire = 4, mouthWidth = 1.5, mouthSpread = 3 }
RF.JUNCTION_HOLD = 12            -- metres either side of a bridged junction where the line holds its course
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
    local isStop = isStopOf ~= nil and isStopOf(cls) or nil
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
    -- Through a junction the walk bridged, the readings are the junction, not the road: within
    -- JUNCTION_HOLD of a bridged point the line holds its course (2026-10-12: a 1-2 m dip toward the
    -- side road at each T the run went through).
    do
        local bridges = {}
        for _, p in ipairs(st.pts) do if p.bridged then bridges[#bridges + 1] = p end end
        if #bridges > 0 then
            local r2 = RF.JUNCTION_HOLD * RF.JUNCTION_HOLD
            for i = 1, n do
                for _, bp in ipairs(bridges) do
                    if (G[i].x - bp.x) ^ 2 + (G[i].z - bp.z) ^ 2 < r2 then meas[i] = nil break end
                end
            end
        end
    end
    -- Readings much wider than the road usually is are a junction's mouth or a patch beside the road:
    -- their middle is pulled toward the side road, so they are left out.
    do
        local ws = {}
        for i = 1, n do if widths[i] ~= nil then ws[#ws + 1] = widths[i] end end
        table.sort(ws)
        local usual = ws[floor((#ws + 1) / 2)]
        if usual ~= nil then
            -- a junction widens the road gradually: the readings a few metres either side of a wide
            -- one lean toward the side road too, so they are left out with it
            local wide = {}
            for i = 1, n do
                if widths[i] ~= nil and widths[i] > F.mouthWidth * usual then wide[i] = true end
            end
            for i = 1, n do
                if wide[i] then
                    for j = max(1, i - F.mouthSpread), min(n, i + F.mouthSpread) do meas[j] = nil end
                end
            end
        end
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
    -- Across a stretch with no usable readings (a junction held out above, a gap in the paint), the
    -- line runs straight from the last good point to the next: holding the walked line's own shape
    -- there kept the walk's dip into the junction (~1 m at three T's, 2026-10-12).
    do
        local i = 1
        while i <= n do
            if meas[i] == nil then
                local j = i
                while j < n and meas[j + 1] == nil do j = j + 1 end
                if i > 2 and j < n - 1 and j - i + 1 >= 2 then
                    -- a smooth curve (Hermite) leaving the last good point and reaching the next one
                    -- along the road's own direction at each: it follows a bend through the zone
                    local a, a0, b, b1 = R[i - 1], R[i - 2], R[j + 1], R[j + 2]
                    local L = sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
                    local function unit(px, pz) local l = sqrt(px * px + pz * pz) if l < 1e-6 then return 0, 0 end return px / l, pz / l end
                    local tax, taz = unit(a.x - a0.x, a.z - a0.z)
                    local tbx, tbz = unit(b1.x - b.x, b1.z - b.z)
                    local span = j - i + 2
                    for k = i, j do
                        local t = (k - i + 1) / span
                        local h00, h10 = 2 * t ^ 3 - 3 * t ^ 2 + 1, t ^ 3 - 2 * t ^ 2 + t
                        local h01, h11 = -2 * t ^ 3 + 3 * t ^ 2, t ^ 3 - t ^ 2
                        R[k].x = h00 * a.x + h10 * L * tax + h01 * b.x + h11 * L * tbx
                        R[k].z = h00 * a.z + h10 * L * taz + h01 * b.z + h11 * L * tbz
                    end
                end
                i = j + 1
            else
                i = i + 1
            end
        end
    end
    -- Both end fixes below carry the line on along the CURVE it is already following (its turn per
    -- metre read over the ~25 m before the anchor), not a straight line: straight tails ran off the
    -- middle of a curving road (2026-10-12 screenshot). On a straight road the curve is straight.
    local function at(atEnd, k) if atEnd then return R[#R + 1 - k] else return R[k] end end
    local function course(atEnd, k0)
        -- heading outward at anchor k0, and its turn per metre (from the two 14 m pieces behind it)
        local a, b, c = at(atEnd, k0), at(atEnd, k0 + 7), at(atEnd, k0 + 14)
        if a == nil or b == nil then return nil end
        local h1 = atan2(a.z - b.z, a.x - b.x)
        local rate = 0
        if c ~= nil then
            local h0 = atan2(b.z - c.z, b.x - c.x)
            local dh = h1 - h0
            if dh > pi then dh = dh - 2 * pi elseif dh < -pi then dh = dh + 2 * pi end
            rate = dh / (7 * W.step)
            local cap = math.rad(3)                      -- at most 3 degrees a metre (radius ~19 m)
            if rate > cap then rate = cap elseif rate < -cap then rate = -cap end
        end
        return h1, rate
    end
    local function along(x, z, h, rate, d)
        -- the point d metres on from (x, z) heading h, turning `rate` per metre
        local px, pz, hh, done = x, z, h, 0
        while done < d - 1e-6 do
            local s1 = min(0.5, d - done)
            hh = hh + rate * s1 / 2
            px, pz = px + cos(hh) * s1, pz + sin(hh) * s1
            hh = hh + rate * s1 / 2
            done = done + s1
        end
        return px, pz
    end
    -- carry the line on over the part left out near a fork
    local function extend(atEnd, length)
        if length <= 0 or #R < 4 then return end
        local h, rate = course(atEnd, 1)
        if h == nil then return end
        local q = at(atEnd, 1)
        local d = W.step
        while d <= length + 1e-6 do
            local x, z = along(q.x, q.z, h, rate, d)
            local e = { x = x, z = z, w = q.w }
            if atEnd then R[#R + 1] = e else table.insert(R, 1, e) end
            d = d + W.step
        end
    end
    extend(false, cutStart)
    extend(true, cutEnd)
    -- Steady ends: the last metres are read with fewer points either side and drift, or hook into a
    -- yard or a junction's mud. Carry the line's own course (read from 10 m in) out over its last
    -- 10 m, unless the road really turns there (the tip over 45 degrees off that course).
    local function steady(atEnd)
        if #R < 14 then return end
        local h, rate = course(atEnd, 6)
        if h == nil then return end
        local a, tip = at(atEnd, 6), at(atEnd, 1)
        local ex, ez = along(a.x, a.z, h, rate, 5 * W.step)
        local vx, vz = tip.x - a.x, tip.z - a.z
        local ux, uz = ex - a.x, ez - a.z
        local vl, ul = sqrt(vx * vx + vz * vz), sqrt(ux * ux + uz * uz)
        if vl < 1e-6 or ul < 1e-6 then return end
        if (ux * vx + uz * vz) / (ul * vl) < cos(math.rad(45)) then return end
        for k = 1, 5 do
            local p = at(atEnd, k)
            p.x, p.z = along(a.x, a.z, h, rate, (6 - k) * W.step)
        end
    end
    steady(false)
    steady(true)
    -- A track's line never runs onto a paved road (2026-10-12: one crossed both lanes of a road): cut
    -- each end back to where the paving starts, and that end has met the road - a fork, with its gap.
    local metStart, metEnd = nil, nil
    if isStop ~= nil then
        while #R > 4 and isStop(R[1].x, R[1].z) do metStart = table.remove(R, 1) end
        while #R > 4 and isStop(R[#R].x, R[#R].z) do metEnd = table.remove(R) end
    end
    local out = { startTag = st.startTag, endTag = st.endTag, startNode = st.startNode, endNode = st.endNode }
    if metStart ~= nil then out.startTag, out.startNode = "fork", { x = metStart.x, z = metStart.z, tag = "fork" } end
    if metEnd ~= nil then out.endTag, out.endNode = "fork", { x = metEnd.x, z = metEnd.z, tag = "fork" } end
    -- Ran off the read square, or the square lost the road ("end": a break in the paint - a muddy
    -- patch, another paint, a shadow - where the road plainly carries on): keep walking from that end.
    -- The walker bridges gaps up to 8 m and stops at a real fork, a change between paved and track,
    -- or the road's true end; what it adds is cut at the first AutoDrive path later. (2026-10-12: a
    -- paved road's run stopped mid-road and the end fixes only patched over the stop.)
    local function carryOn(atEnd)
        local m = #R
        local p, q
        if atEnd then p, q = R[max(1, m - 3)], R[m] else p, q = R[min(m, 4)], R[1] end
        local hx, hz = q.x - p.x, q.z - p.z
        local more, tag, at = RF.walkRoad(isRoad, cls, q.x, q.z, hx, hz, q.w or st.width or 4, isStop)
        return more, tag, at
    end
    local function carries(tag) return tag == "edge" or tag == "end" end
    if carries(out.endTag) and metEnd == nil then
        local more, tag, at = carryOn(true)
        -- (a walk that meets a junction's mouth at once still tells us the end is a fork: gap it)
        if #more > 1 or out.endTag == "edge" or tag == "fork" then
            for i = 2, #more do R[#R + 1] = more[i] end
            out.endTag = tag
            out.endNode = at and { x = at.x, z = at.z, tag = "fork" } or nil
        end
    end
    if carries(out.startTag) and metStart == nil then
        local more, tag, at = carryOn(false)
        if #more > 1 or out.startTag == "edge" or tag == "fork" then
            local front = {}
            for i = #more, 2, -1 do front[#front + 1] = more[i] end
            for _, p in ipairs(R) do front[#front + 1] = p end
            R = front
            out.startTag = tag
            out.startNode = at and { x = at.x, z = at.z, tag = "fork" } or nil
        end
    end
    -- straighten, but never so far that the line leaves the middle it read: on a narrow road a bend
    -- cut by straightening put the line half off the paving (2026-10-12 game test)
    local w = medianWidth(R, 0) or st.width or 4
    local S = RF.straighten(R, min(0.4, 0.1 * w))      -- (0.75 cut the inside of long bends by 0.5 m)
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

--- For the log: the strips of road ground straight across a line at point i, as offsets from the line
--- (left negative), to 0.25 m, and the middle the walk would read there.
function RF.crossDetail(isRoadOf, st, i)
    local P = st.pts
    local a, b = P[max(1, i - 2)], P[min(#P, i + 2)]
    local hx, hz = b.x - a.x, b.z - a.z
    local l = sqrt(hx * hx + hz * hz)
    if l < 1e-6 then return nil end
    local nx, nz = -hz / l, hx / l
    local isRoad = isRoadOf(st.class)
    if isRoad == nil then return nil end
    local W = RF.WALK
    local fine = RF.crossSection(isRoad, P[i].x, P[i].z, nx, nz, W.half, W.res, W.res)
    local t = {}
    for _, f in ipairs(fine) do t[#t + 1] = string.format("[%+.2f..%+.2f]", f.lo, f.hi) end
    local bands = RF.bandsAt(isRoad, P[i].x, P[i].z, nx, nz, st.class)
    local pick = nil
    for _, bd in ipairs(bands) do
        if bd.w >= W.minBand[st.class] and (pick == nil or abs(bd.mid) < abs(pick.mid)) then pick = bd end
    end
    return { strips = (#t > 0) and table.concat(t, " ") or "none", mid = pick and pick.mid or 0 }
end

-- ------------------------------------------------------------------------- the map's road splines

--- Sort the map's splines: a two-way farm way is a spline with a reversed twin on the same line (or a
--- group named ...TwoDirections / ...OneDirection) - a CENTRE line. Traffic lanes (one per direction,
--- a lane apart, no twin on the line) are not. Returns { all, centre, ends } with a 32 m grid of the
--- centre lines' points for lookups.
function RF.indexSplines(list)
    local function dist(a, b) return sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2) end
    local out = { all = list, centre = {}, grid = {} }
    local used = {}
    for i, a in ipairs(list) do
        if not used[a] and #a.pts >= 2 then
            local isCentre = a.group:find("TwoDirections") ~= nil or a.group:find("OneDirection") ~= nil
            for j = i + 1, #list do
                local b = list[j]
                if not used[b] and #b.pts >= 2 and abs(a.len - b.len) < 2
                    and dist(a.pts[1], b.pts[#b.pts]) < 1.5 and dist(a.pts[#a.pts], b.pts[1]) < 1.5 then
                    used[b] = true                       -- the reversed twin: the same line
                    isCentre = true
                    break
                end
            end
            if isCentre then
                used[a] = true
                out.centre[#out.centre + 1] = a
                for k, p in ipairs(a.pts) do
                    local key = floor(p.x / 32) * 100003 + floor(p.z / 32)
                    out.grid[key] = out.grid[key] or {}
                    table.insert(out.grid[key], { sp = a, i = k })
                end
            end
        end
    end
    return out
end

--- The centre spline nearest (x, z) within reach, or nil.
function RF.splineNear(S, x, z, reach)
    local best, bd = nil, reach
    for gx = floor((x - reach) / 32), floor((x + reach) / 32) do
        for gz = floor((z - reach) / 32), floor((z + reach) / 32) do
            for _, e in ipairs(S.grid[gx * 100003 + gz] or {}) do
                local P = e.sp.pts
                local i = e.i
                if i < #P then
                    local a, b = P[i], P[i + 1]
                    local dx, dz = b.x - a.x, b.z - a.z
                    local l2 = dx * dx + dz * dz
                    local t = l2 > 0 and max(0, min(1, ((x - a.x) * dx + (z - a.z) * dz) / l2)) or 0
                    local d = sqrt((x - a.x - dx * t) ^ 2 + (z - a.z - dz * t) ^ 2)
                    if d < bd then best, bd = e.sp, d end
                end
            end
        end
    end
    return best
end

RF.HAIRPIN_TURN = 100   -- a line turning back more than this within HAIRPIN_SPAN either side is two roads
RF.HAIRPIN_SPAN = 6

--- A stretch that doubles back on itself (two tracks meeting a road side by side, joined along its
--- verge: down one, back up the other - 2026-10-13) is cut at each turn-back; the piece nearest (x, z)
--- is kept, its cut ends tagged "fork". Returns the stretch itself when it has no turn-back.
function RF.cutHairpins(st, x, z)
    local P = st.pts
    local n = #P
    if n < 5 then return st end
    local acc = { 0 }
    for i = 2, n do acc[i] = acc[i - 1] + sqrt((P[i].x - P[i - 1].x) ^ 2 + (P[i].z - P[i - 1].z) ^ 2) end
    local cosMax = math.cos(math.rad(RF.HAIRPIN_TURN))
    local cuts = {}
    local i = 2
    while i < n do
        local a, b = i, i
        while a > 1 and acc[i] - acc[a] < RF.HAIRPIN_SPAN do a = a - 1 end
        while b < n and acc[b] - acc[i] < RF.HAIRPIN_SPAN do b = b + 1 end
        local ix, iz = P[i].x - P[a].x, P[i].z - P[a].z
        local ox, oz = P[b].x - P[i].x, P[b].z - P[i].z
        local il, ol = sqrt(ix * ix + iz * iz), sqrt(ox * ox + oz * oz)
        if il > 1 and ol > 1 and (ix * ox + iz * oz) / (il * ol) < cosMax then
            -- the sharpest point of this turn
            local best, bc = i, 2
            for k = a + 1, b - 1 do
                local px, pz = P[k].x - P[k - 1].x, P[k].z - P[k - 1].z
                local qx, qz = P[k + 1].x - P[k].x, P[k + 1].z - P[k].z
                local pl, ql = sqrt(px * px + pz * pz), sqrt(qx * qx + qz * qz)
                if pl > 1e-6 and ql > 1e-6 then
                    local c = (px * qx + pz * qz) / (pl * ql)
                    if c < bc then best, bc = k, c end
                end
            end
            cuts[#cuts + 1] = best
            i = b
        else
            i = i + 1
        end
    end
    if #cuts == 0 then return st end
    local m, bd = 1, math.huge
    for k = 1, n do
        local d = (P[k].x - x) ^ 2 + (P[k].z - z) ^ 2
        if d < bd then m, bd = k, d end
    end
    local i0, i1 = 1, n
    for _, c in ipairs(cuts) do
        if c <= m and c > i0 then i0 = c end
        if c > m and c < i1 then i1 = c end
    end
    -- the same piece is the same table each time (its refined line is kept on it)
    st.hairpinPieces = st.hairpinPieces or {}
    local key = i0 .. ":" .. i1
    if st.hairpinPieces[key] ~= nil then return st.hairpinPieces[key] end
    local out = {}
    for k, v in pairs(st) do if k ~= "hairpinPieces" and k ~= "refinedTo" then out[k] = v end end
    st.hairpinPieces[key] = out
    out.pts = {}
    for k = i0, i1 do out.pts[#out.pts + 1] = P[k] end
    if i0 > 1 then out.startTag, out.startNode = "fork", { x = P[i0].x, z = P[i0].z, tag = "fork" } end
    if i1 < n then out.endTag, out.endNode = "fork", { x = P[i1].x, z = P[i1].z, tag = "fork" } end
    out.len = polylineLength(out.pts)
    out.cutFrom = st
    return out
end

RF.GHOST_GAP = 8        -- metres in a row with no road band under the line: the line has left the road
RF.GHOST_KEEP = 0.6     -- a line with road under less than this share of its points is a ghost

--- Is there road under point i of P: a band of road at least a track's width (minBand), its middle
--- within reach of the line?
local function roadUnder(isRoad, cls, P, i)
    local a, b = P[max(1, i - 1)], P[min(#P, i + 1)]
    local hx, hz = b.x - a.x, b.z - a.z
    local l = sqrt(hx * hx + hz * hz)
    if l < 1e-6 then return false end
    local nx, nz = -hz / l, hx / l
    local need = RF.WALK.minBand[cls] or 1.5
    for _, bd in ipairs(RF.bandsAt(isRoad, P[i].x, P[i].z, nx, nz, cls)) do
        if bd.w >= need and abs(bd.mid) <= 0.5 * bd.w + 1 then return true end
    end
    return false
end

--- A line laid where there is no road (dirt patches in grass joined into a "track" - 2026-10-13 ghost
--- by the road at (-410,-640)): cut where the road is missing for GHOST_GAP metres or more, keep the
--- piece nearest (x, z) trimmed to road at both ends, and nil if that piece is mostly not road, or
--- the point nearest (x, z) is in a gap. Cut ends are "end" (nothing to join).
function RF.trimGhosts(st, isRoad, cls, x, z)
    local P = st.pts
    local n = #P
    if n < 3 or isRoad == nil then return st end
    local on, acc = {}, { 0 }
    for i = 1, n do
        on[i] = roadUnder(isRoad, cls, P, i)
        if i > 1 then acc[i] = acc[i - 1] + sqrt((P[i].x - P[i - 1].x) ^ 2 + (P[i].z - P[i - 1].z) ^ 2) end
    end
    -- the gaps: runs of no road at least GHOST_GAP long (shorter ones - a fork's mouth, a puddle - stay)
    local bad = {}
    local i = 1
    while i <= n do
        if not on[i] then
            local j = i
            while j < n and not on[j + 1] do j = j + 1 end
            local from = (i > 1) and acc[i - 1] or acc[1]
            local to = (j < n) and acc[j + 1] or acc[n]
            if to - from >= RF.GHOST_GAP then
                for k = i, j do bad[k] = true end
            end
            i = j + 1
        else
            i = i + 1
        end
    end
    local m, bd = 1, math.huge
    for k = 1, n do
        local d = (P[k].x - x) ^ 2 + (P[k].z - z) ^ 2
        if d < bd then m, bd = k, d end
    end
    -- the mouse in a gap: take the nearest good point instead, if one is close
    if bad[m] then
        local best, bdist = nil, math.huge
        for k = 1, n do
            if not bad[k] then
                local d = abs(acc[k] - acc[m])
                if d < bdist then best, bdist = k, d end
            end
        end
        if best == nil or bdist > 4 then return nil end
        m = best
    end
    local i0, i1 = m, m
    while i0 > 1 and not bad[i0 - 1] do i0 = i0 - 1 end
    while i1 < n and not bad[i1 + 1] do i1 = i1 + 1 end
    local good = 0
    for k = i0, i1 do if on[k] then good = good + 1 end end
    if good < RF.GHOST_KEEP * (i1 - i0 + 1) or i1 - i0 < 2 then return nil end
    if i0 == 1 and i1 == n then return st end
    local out = {}
    for k, v in pairs(st) do if k ~= "hairpinPieces" and k ~= "refinedTo" then out[k] = v end end
    out.pts = {}
    for k = i0, i1 do out.pts[#out.pts + 1] = P[k] end
    if i0 > 1 then out.startTag, out.startNode = "end", nil end
    if i1 < n then out.endTag, out.endNode = "end", nil end
    out.len = polylineLength(out.pts)
    return out
end

--- How far a walked line runs from the map's own road line, as a score for the walker: over the walk's
--- points within `reach` of the same centre spline, the mean offset (+ = right of the way the walk
--- goes: a steady lean to one side), the mean size, the worst, how many points, and the spline.
function RF.splineScore(S, pts, reach)
    local best, votes = nil, {}
    for i = 1, #pts, 3 do
        local sp = RF.splineNear(S, pts[i].x, pts[i].z, reach)
        if sp ~= nil then votes[sp] = (votes[sp] or 0) + 1; if best == nil or votes[sp] > votes[best] then best = sp end end
    end
    if best == nil then return nil end
    local P = best.pts
    local sum, sumAbs, worst, n = 0, 0, 0, 0
    for i = 1, #pts do
        local q = pts[i]
        local bd, bx, bz = reach * reach, nil, nil
        for k = 1, #P - 1 do
            local a, b = P[k], P[k + 1]
            local dx, dz = b.x - a.x, b.z - a.z
            local l2 = dx * dx + dz * dz
            local t = l2 > 0 and max(0, min(1, ((q.x - a.x) * dx + (q.z - a.z) * dz) / l2)) or 0
            local qx, qz = a.x + dx * t, a.z + dz * t
            local d = (q.x - qx) ^ 2 + (q.z - qz) ^ 2
            if d < bd then bd, bx, bz = d, qx, qz end
        end
        if bx ~= nil then
            local a, b = pts[max(1, i - 1)], pts[min(#pts, i + 1)]
            local hx, hz = b.x - a.x, b.z - a.z
            local hl = sqrt(hx * hx + hz * hz)
            if hl > 1e-6 then
                local off = ((q.x - bx) * -hz + (q.z - bz) * hx) / hl
                sum, sumAbs, worst, n = sum + off, sumAbs + abs(off), max(worst, abs(off)), n + 1
            end
        end
    end
    if n == 0 then return nil end
    return { lean = sum / n, mean = sumAbs / n, worst = worst, n = n, sp = best }
end

--- A centre spline as a stretch: its points, and at each end "fork" if another spline's end or line
--- comes within `junction` metres (the AI network's splines meet at junctions), else "end".
RF.SPLINE_THROUGH_ANGLE = 35      -- a road line carrying on within this of straight at a meeting is the same road
RF.SPLINE_MEET = 3                -- line ends this close meet

--- Heading (unit) of the first `span` metres of P from its start.
local function headingFrom(P, span)
    local a = P[1]
    for k = 2, #P do
        local b = P[k]
        local dx, dz = b.x - a.x, b.z - a.z
        local l = sqrt(dx * dx + dz * dz)
        if l >= span or k == #P then if l < 1e-6 then return nil end return dx / l, dz / l end
    end
    return nil
end

--- The centre line carrying straight on from the end `q` (arriving heading hx,hz), as points running
--- away from q, or nil. Only a line within RF.SPLINE_THROUGH_ANGLE of straight, and the straightest.
local function carryOn(S, used, q, hx, hz)
    local best, bestCos, bestPts = nil, math.cos(math.rad(RF.SPLINE_THROUGH_ANGLE)), nil
    for _, o in ipairs(S.centre) do
        if not used[o] and #o.pts >= 2 then
            local P = nil
            local a, b = o.pts[1], o.pts[#o.pts]
            if (a.x - q.x) ^ 2 + (a.z - q.z) ^ 2 < RF.SPLINE_MEET ^ 2 then P = o.pts
            elseif (b.x - q.x) ^ 2 + (b.z - q.z) ^ 2 < RF.SPLINE_MEET ^ 2 then
                P = {}
                for k = #o.pts, 1, -1 do P[#P + 1] = o.pts[k] end
            end
            if P ~= nil then
                local dx, dz = headingFrom(P, 10)
                if dx ~= nil and dx * hx + dz * hz > bestCos then best, bestCos, bestPts = o, dx * hx + dz * hz, P end
            end
        end
    end
    return best, bestPts
end

function RF.splineStretch(S, sp, junction)
    -- the line itself, then on through every meeting where another line carries straight on (the
    -- through road at a T is one road - 2026-10-13: spline993 stopped where 991 carried it on)
    local used = { [sp] = true }
    local P = {}
    for _, p in ipairs(sp.pts) do P[#P + 1] = { x = p.x, z = p.z, y = p.y } end
    for _ = 1, 2 do
        for _ = 1, 20 do
            local n = #P
            local back = {}
            for k = n, 1, -1 do back[#back + 1] = P[k] end
            local hx, hz = headingFrom(back, 10)
            if hx == nil then break end
            local o, Q = carryOn(S, used, P[n], -hx, -hz)
            if o == nil then break end
            used[o] = true
            for k = 2, #Q do P[#P + 1] = { x = Q[k].x, z = Q[k].z, y = Q[k].y } end
        end
        local R = {}
        for k = #P, 1, -1 do R[#R + 1] = P[k] end
        P = R
    end
    local function meets(q)
        for _, o in ipairs(S.all) do
            local twin = false
            for u in pairs(used) do
                if o == u or (abs(o.len - u.len) < 2 and #o.pts > 1
                    and sqrt((o.pts[1].x - u.pts[#u.pts].x) ^ 2 + (o.pts[1].z - u.pts[#u.pts].z) ^ 2) < 1.5) then twin = true end
            end
            if not twin then
                for k = 1, #o.pts do
                    local p = o.pts[k]
                    if (p.x - q.x) ^ 2 + (p.z - q.z) ^ 2 < junction * junction then return true end
                end
            end
        end
        return false
    end
    local st = { pts = P, len = polylineLength(P), width = 4 }
    st.startTag = meets(P[1]) and "fork" or "end"
    st.endTag = meets(P[#P]) and "fork" or "end"
    if st.startTag == "fork" then st.startNode = { x = P[1].x, z = P[1].z, tag = "fork" } end
    if st.endTag == "fork" then st.endNode = { x = P[#P].x, z = P[#P].z, tag = "fork" } end
    return st
end

--- Like keepUncovered, but the uncovered run that holds the point nearest (x, z).
function RF.keepUncoveredNear(st, grid, x, z)
    local P = st.pts
    local n = #P
    local m, bd = 1, math.huge
    for i = 1, n do
        local d = (P[i].x - x) ^ 2 + (P[i].z - z) ^ 2
        if d < bd then m, bd = i, d end
    end
    local half = (st.width or 6) / 2
    local cov = {}
    for i = 1, n do cov[i] = coveredAt(grid, P, i, half) end
    if cov[m] then return nil end
    local i0, i1 = m, m
    while i0 > 1 and not cov[i0 - 1] do i0 = i0 - 1 end
    while i1 < n and not cov[i1 + 1] do i1 = i1 + 1 end
    local out = {}
    for k, v in pairs(st) do out[k] = v end
    out.pts = {}
    for i = i0, i1 do out.pts[#out.pts + 1] = P[i] end
    if i0 > 1 then out.startTag, out.startNode = "path", nil end
    if i1 < n then out.endTag, out.endNode = "path", nil end
    out.len = polylineLength(out.pts)
    return out
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

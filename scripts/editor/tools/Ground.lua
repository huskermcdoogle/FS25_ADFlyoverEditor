-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua
-- loads it after FlyoverEditor.lua, in the old file's order.
-- MODSPLIT: HELPERS FROM THE FILES LOADED BEFORE THIS ONE (tools/modsplit/split.py writes this block)
for _, name in ipairs({ "heightAlongChain" }) do
    if ADFlyoverEditor.shared == nil or ADFlyoverEditor.shared[name] == nil then
        Logging.error("[FlyoverEditor]: Ground.lua needs %s, which no file loaded before it shares", name)
    end
end
local heightAlongChain = ADFlyoverEditor.shared.heightAlongChain
-- MODSPLIT: end of the helpers

-- ---------------------------------------------------------------------------------------------
-- GROUND
--
-- Waypoints drift off the ground. A spline interpolates heights between its ends, an offset carries
-- the source point's height sideways onto terrain that is not at the same level, a field loop
-- follows a boundary across a ditch - each is locally reasonable and each can leave a point hanging
-- in the air or buried under a slope. None of it is visible from above, which is the whole problem:
-- the network looks perfect in flyover and a vehicle drives into a hillside.
--
-- So the tool shows before it fixes. The preview marks every waypoint further from the ground than
-- the tolerance and draws a line from where it is to where it would land, and only then does
-- right-click move anything. A tool that silently re-seated a whole run would be the fastest way to
-- flatten a deliberately raised bridge.
-- ---------------------------------------------------------------------------------------------

-- The road probe's collision (isRoadAt below): what AutoDrive's own height lookup sees.
local GROUND_MASK = nil

-- ---------------------------------------------------------------------------------------------
-- THE SURFACE RULE - one rule for every tool that puts a point on the ground (2026-11-04).
--
-- Reported on Welker Farms: a floor a few centimetres above the terrain, and our points went under
-- it, onto the terrain. Two causes, both here:
--   1. The rays used DEFAULT + ROAD + TERRAIN, AutoDrive's own mask. In FS25 a building or static
--      object (the game's BUILDING, PLACEABLE_BUILDING and STATIC_OBJECT presets in
--      shared/collisionMaskFlags.xml) has no DEFAULT bit in its collision group, so sheds, concrete
--      pads and placeable floors were never hit at all. Only road meshes and old-style DEFAULT
--      meshes were.
--   2. Even a floor that was hit lost to the terrain under it: the terrain stayed in the list, and
--      "nearest to the expected height" picked it whenever the point started at terrain level.
--
-- The rule:
--   * Cast down with BUILDING and STATIC_OBJECT added, stepping from hit to hit (bridge deck, then
--     the road under it, then the terrain).
--   * Terrain hits and ROAD hits are surfaces anywhere (decks, roads, bridges - as before).
--   * Any other hit near the terrain (within FLOOR_REACH) counts only if it is a FLOOR: flat
--     (hit normal) and wide (a surface at about the same height a short step away on at least 3 of
--     4 sides). That keeps poles, fence rails, kerbs and sign posts out. Higher building hits are
--     roofs and wall tops and are stepped past; higher DEFAULT hits stay surfaces, as before.
--   * A surface with another surface less than BURY_GAP above it is buried and dropped: the terrain
--     under a floor, a ramp or a road mesh. No vehicle fits in a gap that small. A bridge deck is
--     well above its road, so both stay and the expected height still chooses.
-- ---------------------------------------------------------------------------------------------
local SURFACE = {
    FLOOR_REACH = 1.5,       -- m over the terrain: a building/static hit higher than this is not a floor
    FLOOR_FLAT = 0.85,       -- hit normal's up part; under this (about 32 deg) it is a wall or a roof slope
    FLOOR_WIDE_STEP = 0.4,   -- m to each side for the width check
    FLOOR_WIDE_MATCH = 0.25, -- m: a side counts if it finds a non-terrain surface this close in height
    FLOOR_WIDE_SIDES = 3,    -- of 4
    BURY_GAP = 2.0,          -- m: a surface with another this close above it is buried (no vehicle fits in less)
    STEP = 0.1,              -- m under a hit for the next cast
    MAX_CASTS = 12,
}
ADFlyoverEditor.SURFACE = SURFACE

local SURFACE_MASK = nil
local function surfaceMask()
    if SURFACE_MASK == nil then
        SURFACE_MASK = CollisionFlag.DEFAULT + CollisionFlag.ROAD + CollisionFlag.TERRAIN
            + (CollisionFlag.BUILDING or 0) + (CollisionFlag.STATIC_OBJECT or 0)
    end
    return SURFACE_MASK
end

-- One bit of a collision group, without bit32 (a group read as a signed number when bit 31 is set).
local function hasFlag(group, flag)
    if type(group) ~= "number" or type(flag) ~= "number" or flag <= 0 then return false end
    if group < 0 then group = group + 4294967296 end
    return math.floor(group / flag) % 2 == 1
end

local rayY, rayId, rayNy = nil, nil, nil
local function surfaceRayCallback(_, hitObjectId, x, y, z, distance, nx, ny, nz)
    -- Highest wins if the engine ever reports more than one: casting down, that is the closest.
    if y ~= nil and (rayY == nil or y > rayY) then
        rayY, rayId, rayNy = y, hitObjectId, ny
    end
end
local SurfaceRay = { callback = surfaceRayCallback }

--- The first thing straight below (x, fromY, z) within `length` m: its height, object id and normal's up part.
local function castDown(x, z, fromY, length)
    if raycastClosest == nil or CollisionFlag == nil then return nil end
    rayY, rayId, rayNy = nil, nil, nil
    -- raycastClosest calls back synchronously, which is what AutoDrive relies on as well.
    local ok = pcall(raycastClosest, x, fromY, z, 0, -1, 0, math.max(length, 0.5),
        "callback", SurfaceRay, surfaceMask())
    if not ok or rayY == nil then return nil end
    return rayY, rayId, rayNy
end

local function terrainNode()
    return g_currentMission ~= nil and g_currentMission.terrainRootNode or nil
end

--- "terrain", "road", "default" or "object" (building / static object), from the hit's collision group.
local function hitKind(id)
    local terrain = terrainNode()
    if id ~= nil and terrain ~= nil and id == terrain then return "terrain" end
    if id == nil or id == 0 or getCollisionFilterGroup == nil then return "default" end
    local ok, group = pcall(getCollisionFilterGroup, id)
    if not ok or type(group) ~= "number" then return "default" end
    if hasFlag(group, CollisionFlag.TERRAIN) then return "terrain" end
    if hasFlag(group, CollisionFlag.ROAD) then return "road" end
    if hasFlag(group, CollisionFlag.DEFAULT) then return "default" end
    return "object"
end

--- Is the surface hit at (x, h, z) wide, like a floor, rather than a pole, a rail or a kerb?
local function isWide(x, z, h)
    local s = SURFACE.FLOOR_WIDE_STEP
    local found = 0
    for _, d in ipairs({ { s, 0 }, { -s, 0 }, { 0, s }, { 0, -s } }) do
        local y, id = castDown(x + d[1], z + d[2], h + 0.5, 1.0)
        if y ~= nil and math.abs(y - h) <= SURFACE.FLOOR_WIDE_MATCH and hitKind(id) ~= "terrain" then
            found = found + 1
        end
    end
    return found >= SURFACE.FLOOR_WIDE_SIDES
end

local function objectName(id)
    if id == nil or id == 0 or getName == nil then return "?" end
    local ok, name = pcall(getName, id)
    local text = ok and tostring(name) or "?"
    if getParent ~= nil then
        local okP, p = pcall(getParent, id)
        if okP and p ~= nil and p ~= 0 then
            local okN, pn = pcall(getName, p)
            if okN and pn ~= nil then text = tostring(pn) .. "/" .. text end
        end
    end
    return text
end

local function groupText(id)
    if id == nil or id == 0 or getCollisionFilterGroup == nil then return "-" end
    local ok, group = pcall(getCollisionFilterGroup, id)
    if not ok or type(group) ~= "number" then return "-" end
    if group < 0 then group = group + 4294967296 end
    return string.format("0x%x", group)
end

-- Columns are asked for every frame while a preview is up (the ground tool checks its whole span
-- each frame), so a column is kept for a second.
local columnCache, columnCacheCount, columnCacheTime = {}, 0, nil
local function cachedColumn(key)
    local now = g_time
    if type(now) ~= "number" or columnCacheTime == nil or now - columnCacheTime > 1000 or columnCacheCount > 5000 then
        columnCache, columnCacheCount = {}, 0
        if type(now) == "number" then columnCacheTime = now else columnCacheTime = nil end
        return nil
    end
    return columnCache[key]
end
local function storeColumn(key, value)
    if columnCacheTime == nil then return end
    columnCache[key] = value
    columnCacheCount = columnCacheCount + 1
end

--- Every surface in the column at (x, z), top down, from `topY` to the terrain, by the rule above.
--- Returns the heights, and the full list (kept and skipped hits, with their kind and object) for the log.
local function surfaceColumn(x, z, topY, terrainY)
    local key = string.format("%.2f|%.2f|%.1f", x, z, topY)
    local cached = cachedColumn(key)
    if cached ~= nil then return cached.heights, cached.hits, cached.kinds end

    local hits, kept = {}, {}
    local from, sawTerrain = topY, false
    for _ = 1, SURFACE.MAX_CASTS do
        if from < terrainY - 0.05 then break end           -- already under the terrain
        local h, id, ny = castDown(x, z, from, (from - terrainY) + 1)
        if h == nil then break end
        local kind = hitKind(id)
        local hit = { y = h, id = id, kind = kind, ny = ny }
        if kind == "terrain" or kind == "road" then
            hit.keep = true
        elseif h > terrainY + SURFACE.FLOOR_REACH then
            hit.keep = (kind == "default")                 -- old-style meshes: surfaces, as before
            if not hit.keep then hit.why = "too high for a floor" end
        elseif ny ~= nil and ny < SURFACE.FLOOR_FLAT then
            hit.why = "too steep"
        elseif not isWide(x, z, h) then
            hit.why = "too narrow"
        else
            hit.keep = true
            if kind == "object" then hit.kind = "floor" end
        end
        hits[#hits + 1] = hit
        if hit.keep then kept[#kept + 1] = hit end
        if kind == "terrain" then
            sawTerrain = true
            break
        end
        from = h - SURFACE.STEP
    end
    if not sawTerrain then
        local t = { y = terrainY, kind = "terrain", keep = true, plain = true }
        hits[#hits + 1] = t
        kept[#kept + 1] = t
    end

    -- Buried: another kept surface less than BURY_GAP above it.
    local open = {}
    for _, s in ipairs(kept) do
        for _, above in ipairs(kept) do
            local gap = above.y - s.y
            if above ~= s and gap > 0.001 and gap < SURFACE.BURY_GAP then
                s.buried = above
                break
            end
        end
        if s.buried == nil then open[#open + 1] = s end
    end
    table.sort(open, function(a, b) return a.y > b.y end)
    local heights, kinds = {}, {}
    for i, s in ipairs(open) do
        heights[i], kinds[i] = s.y, s.kind
    end
    if #heights == 0 then heights[1], kinds[1] = terrainY, "terrain" end   -- cannot happen; never return nothing
    storeColumn(key, { heights = heights, hits = hits, kinds = kinds })
    return heights, hits, kinds
end

local function terrainHeightAt(x, z)
    local terrain = terrainNode()
    if terrain == nil or getTerrainHeightAtWorldPos == nil then return nil end
    return getTerrainHeightAtWorldPos(terrain, x, 1, z)
end

--- The surfaces at (x, z) by the shared rule, top down, the terrain height, and each surface's kind
--- ("terrain", "road", "floor", "default"). `aboveY` is the highest height that matters (the column
--- is searched from 15 m over it). Nil off the map.
function ADFlyoverEditor:surfacesAt(x, z, aboveY)
    local terrainY = terrainHeightAt(x, z)
    if terrainY == nil then return nil end
    local heights, _, kinds = surfaceColumn(x, z, math.max(aboveY or terrainY, terrainY) + 15, terrainY)
    return heights, terrainY, kinds
end

--- The surface nearest `referenceY` at (x, z) by the shared rule; `maxGap` (optional) refuses one
--- further away than that. Nil when there is none (or off the map).
function ADFlyoverEditor:surfaceNear(x, z, referenceY, maxGap)
    local heights, terrainY = self:surfacesAt(x, z, referenceY)
    if heights == nil then return nil end
    local ref = referenceY or terrainY
    local best, bestGap = nil, math.huge
    for _, h in ipairs(heights) do
        local gap = math.abs(h - ref)
        if gap < bestGap then best, bestGap = h, gap end
    end
    if maxGap ~= nil and bestGap > maxGap then return nil end
    return best
end

--- One log line naming everything the column at (x, z) holds: each hit's height, kind, object and
--- collision group, and why it was kept, skipped or buried. For in-game tests ("what did the ray see").
function ADFlyoverEditor:describeSurfaces(x, z, aboveY, label, chosenY)
    local terrainY = terrainHeightAt(x, z)
    if terrainY == nil then return end
    columnCacheTime = nil                                   -- a fresh look, not a cached one
    local topY = math.max(aboveY or terrainY, terrainY) + 15
    local _, hits = surfaceColumn(x, z, topY, terrainY)
    local parts = {}
    for _, hit in ipairs(hits) do
        local state
        if hit.buried ~= nil then
            state = string.format("buried under %.3f", hit.buried.y)
        elseif hit.keep then
            state = "kept"
        else
            state = "skipped, " .. tostring(hit.why)
        end
        if hit.plain then
            parts[#parts + 1] = string.format("%.3f terrain (no ray hit) %s", hit.y, state)
        else
            local up = ""
            if hit.ny ~= nil then up = string.format(" up %.2f", hit.ny) end
            parts[#parts + 1] = string.format("%.3f %s '%s' group %s%s %s", hit.y, hit.kind, objectName(hit.id),
                groupText(hit.id), up, state)
        end
    end
    local where, chosen = "", ""
    if label ~= nil then where = " " .. label end
    if chosenY ~= nil then chosen = string.format(" -> set to %.3f", chosenY) end
    -- Always on (not debugLog): it fires only on a drop or a ground commit, and the test card reads it.
    Logging.info("[FlyoverEditor]: surfaces at (%.2f, %.2f)%s: terrain %.3f; cast from %.2f: %s%s",
        x, z, where, terrainY, topY, table.concat(parts, "; "), chosen)
end

-- ---------------------------------------------------------------------------------------------
-- Road-surface probe, for junction clearance. "On the road" is either a road MESH under the point
-- (the ray hits something other than the terrain and it carries the ROAD collision group, bit 13 -
-- asphalt meshes, bridge decks) or terrain whose surface MATERIAL is a road one. The material comes
-- from the 5th return of getTerrainAttributesAtWorldPos - the same value the game's WheelPhysics
-- reads to pick tyre-track and surface-sound behaviour - and the base ids are fixed across the
-- Giants maps (data/maps/*/sounds/sounds.xml): 0 field, 1 dirt, 2 grass, 3 sand, 5 leaves,
-- 6 gravel, 7 asphalt, 97 railroad, 98/99 water. Names for the log come from
-- g_currentMission.surfaceSounds when a map remaps them. Everything is guarded: if a call is not
-- there, terrain counts as road - "unknown" is never a reason to refuse a turn.
-- ---------------------------------------------------------------------------------------------
local roadHitId, roadHitY = nil, nil
local function roadRayCallback(_, hitObjectId, x, y, z, distance)
    if y ~= nil then
        roadHitId, roadHitY = hitObjectId, y
    end
end
local RoadRay = { callback = roadRayCallback }
local ROAD_MATERIALS = { [1] = true, [6] = true, [7] = true }         -- dirt track, gravel, asphalt

-- ROCK AND FIELDS ARE NOT ROAD. Road meshes on Riverbend are decoration with no collision, so nearly
-- every probe falls through to the paint below - and the paint's material is a tyre-SOUND class, not a
-- surface class. Material 7 (the asphalt sound) covers asphalt, concrete AND every rock paint; material
-- 1 (dirt) is also the dark mud painted under every field. So a turn across a rock face or a field
-- passed as road. The game's own AI drive-cost map tells them apart: it is built from each paint's
-- drive cost (asphalt and concrete 4, rock 12). Measured over the whole of Riverbend, 96% of asphalt and
-- concrete cells read under 150 (most 51; the rest are blocked by something standing there) and not one
-- rock cell does. The map exists on the server only, which is where edits run; without it, material 7
-- stays road as before. Fields come from the field layer, read the way the game's steering assist reads
-- it (AIAutomaticSteering.lua). See docs/junction-tool/03-data-sources.md.
local ROAD_DRIVE_COST_MAX = 150                                        -- on the map file's 0-255 scale

local function navigationCostAt(x, y, z)
    local ai = g_currentMission ~= nil and g_currentMission.aiSystem or nil
    if type(ai) ~= "table" or getVehicleNavigationMapCostAtWorldPos == nil then return nil end
    local navMap = ai.navigationMap
    if navMap == nil or navMap == 0 then return nil end
    local ok, cost, blocked = pcall(getVehicleNavigationMapCostAtWorldPos, navMap, x, y, z)
    if not ok or type(cost) ~= "number" then return nil end
    return cost, blocked == true
end

local function roadDriveCostMax()
    -- the engine's own scale, in case it is not the 0-255 the map file stores
    local scale = AISystem ~= nil and AISystem.COSTMAP_MAX_VALUE or nil
    if type(scale) == "number" and scale > 0 then
        return ROAD_DRIVE_COST_MAX * scale / 255
    end
    return ROAD_DRIVE_COST_MAX
end

local function isFieldAt(x, z)
    local detail = g_currentMission ~= nil and g_currentMission.terrainDetailId or nil
    if detail == nil or getDensityAtWorldPos == nil then return false end
    local ok, density = pcall(getDensityAtWorldPos, detail, x, 0, z)
    return ok and type(density) == "number" and density ~= 0
end
local BASE_MATERIAL_NAMES = { [0] = "field", [1] = "dirt", [2] = "grass", [3] = "sand", [4] = "sound",
    [5] = "leaves", [6] = "gravel", [7] = "asphalt", [97] = "railroad", [98] = "mediumWater", [99] = "shallowWater" }
local roadProbeNoted = {}

local function roadNote(key, fmt, ...)
    if not roadProbeNoted[key] then
        roadProbeNoted[key] = true
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction clearance - " .. fmt, ...)
    end
end

local function materialName(id)
    local list = g_currentMission ~= nil and g_currentMission.surfaceSounds or nil
    if type(list) == "table" then
        for _, s in pairs(list) do
            if type(s) == "table" and s.materialId == id and s.type == "wheel" and s.name ~= nil then
                return s.name
            end
        end
    end
    return BASE_MATERIAL_NAMES[id] or ("material " .. tostring(id))
end

--- Is (x, z) on a drivable road surface?
local function isRoadAt(x, z)
    local terrain = g_currentMission ~= nil and g_currentMission.terrainRootNode or nil
    if terrain == nil or raycastClosest == nil then return true end
    local ty = getTerrainHeightAtWorldPos(terrain, x, 1, z) or 0
    if GROUND_MASK == nil then
        GROUND_MASK = CollisionFlag.DEFAULT + CollisionFlag.ROAD + CollisionFlag.TERRAIN
    end
    roadHitId, roadHitY = nil, nil
    pcall(raycastClosest, x, ty + 6, z, 0, -1, 0, 12, "callback", RoadRay, GROUND_MASK)
    if roadHitId ~= nil and roadHitId ~= 0 and roadHitId ~= terrain then
        local ok, group = pcall(getCollisionFilterGroup, roadHitId)
        if ok and type(group) == "number" and bit32 ~= nil then
            if bit32.band(group, CollisionFlag.ROAD) ~= 0 then
                roadNote("mesh", "road mesh under the turn (ROAD collision group)")
                return true
            end
            if CollisionFlag.VEHICLE ~= nil and bit32.band(group, CollisionFlag.VEHICLE) ~= 0 then
                return true                                -- something parked there is not the road's fault
            end
        end
        roadNote("object", "a static object (not a road mesh) sits over a probed spot; classed as not road")
        return false
    end
    local ok, _, _, _, _, mat = pcall(getTerrainAttributesAtWorldPos, terrain, x, ty, z, true, true, true, true, false)
    if ok and type(mat) == "number" then
        local id = math.floor(mat + 0.5)
        local road = ROAD_MATERIALS[id] == true
        roadNote("mat:" .. id, "terrain material %d ('%s') classed as %s", id, materialName(id), road and "ROAD" or "not road")
        if road and isFieldAt(x, z) then
            roadNote("field", "field ground under a probed spot; classed as not road")
            return false
        end
        if road and id == 7 then
            local cost, blocked = navigationCostAt(x, ty, z)
            if cost == nil then
                roadNote("nonav", "no drive-cost map (not the server?); asphalt-sound paint counts as road, rock included")
            elseif blocked then
                roadNote("blocked", "asphalt-sound paint marked blocked in the game's drive-cost map; classed as not road")
                return false
            elseif cost >= roadDriveCostMax() then
                roadNote("rock", "asphalt-sound paint with drive cost %d: rock, classed as not road", cost)
                return false
            end
        end
        return road
    end
    roadNote("nomat", "terrain material lookup unavailable; terrain is treated as road")
    return true
end

--- Is (x, z) PAVED: a road mesh, or the asphalt-sound paint (asphalt and concrete) that isRoadAt passes
--- - not rock, not a field? Gravel shoulders and dirt tracks are road to isRoadAt but not paved here.
--- Decided 2026-10-07: a junction turn's laid line stays on the paving; the trailer's inside wheels
--- may cut over the shoulder, as a real truck's do.
local function isPavedAt(x, z)
    if not isRoadAt(x, z) then return false end
    local terrain = g_currentMission ~= nil and g_currentMission.terrainRootNode or nil
    if terrain == nil or raycastClosest == nil then return true end
    -- isRoadAt passed on a hit that is not the terrain: a road mesh (or something parked on it).
    if roadHitId ~= nil and roadHitId ~= 0 and roadHitId ~= terrain then return true end
    local ty = getTerrainHeightAtWorldPos(terrain, x, 1, z) or 0
    local ok, _, _, _, _, mat = pcall(getTerrainAttributesAtWorldPos, terrain, x, ty, z, true, true, true, true, false)
    if ok and type(mat) == "number" then return math.floor(mat + 0.5) == 7 end
    return true
end

--- Where a waypoint at (x, y, z) belongs, for the ground tool specifically.
---
--- NOT resolveHeightAt, which is right for placing a new point and wrong here: in surface mode it
--- leaves anything more than half a metre up alone, assuming a bridge, so floating points were
--- never marked.
---
--- A point under a bridge and a point that belongs on it look identical by height alone. The span
--- says which: a route over a bridge has its ends up on the approaches, a road under one has them
--- down at road level. So `expectedY` - the height interpolated between the span's ends at this
--- point - picks the surface in the column nearest the span's own line. Ends on the approaches put
--- the line at deck height and the points go onto the deck; ends at road level keep them on the road.
---
--- "top surface" ignores the span and takes the highest surface, for a route drawn wholly at ground
--- level under a bridge it should be on - the one case the span line cannot tell apart.
function ADFlyoverEditor:groundTargetAt(x, y, z, expectedY, spanLineOnly, keepTolerance)
    local terrainY = nil
    if g_currentMission ~= nil and g_currentMission.terrainRootNode ~= nil then
        terrainY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 1, z)
    end
    if terrainY == nil then
        return nil
    end
    if self.snapToTerrain then
        return terrainY
    end

    local reference = expectedY or y
    -- The shared surface rule (top of this file). Searched from 15 m over the higher of the point and
    -- its line: high enough to include a deck the span passes over, not so high that it reaches for
    -- the canopy of a tree that happens to overhang the road.
    local surfaces, _, kinds = self:surfacesAt(x, z, math.max(y, reference))
    if surfaces == nil then
        surfaces, kinds = { terrainY }, { "terrain" }
    end

    -- The level toggle belongs to the ground tool. Other callers laying new track want the surface
    -- nearest the line they came from, whatever the ground tool happens to be set to.
    if not spanLineOnly and self.groundLevel == self.GROUND_LEVEL.TOP then
        return surfaces[1], kinds[1]
    end

    -- Keep the point on the surface it already sits on, so grounding never pulls a point down off a
    -- ramp or bridge deck it is correctly on; only points off EVERY surface fall through to the span
    -- line below. This is what stops a route over a placed ramp being flattened onto the terrain.
    if keepTolerance ~= nil then
        for i, h in ipairs(surfaces) do
            if math.abs(y - h) <= keepTolerance then
                return h, kinds[i]
            end
        end
    end

    local bestIndex, bestGap = #surfaces, math.huge
    for i, h in ipairs(surfaces) do
        local gap = math.abs(h - reference)
        if gap < bestGap then
            bestIndex, bestGap = i, gap
        end
    end
    return surfaces[bestIndex], kinds[bestIndex]
end

--- Every waypoint in the span that sits further off the ground than the tolerance.
function ADFlyoverEditor:updateGroundPreview()
    -- What is being checked: a picked span, or - when no span is
    -- pending and no other type is locked - whatever is selected (box, circle, freehand, Ctrl-click),
    -- connected or not. Ground only asks where each point sits against the ground, so it never needs a path.
    local span
    self.groundUsesSelection = false
    if self.groundFromId ~= nil and self.groundToId ~= nil then
        span = self:spanBetween(self.groundFromId, self.groundToId)
        if span == nil or #span < 1 then
            span = { self.groundFromId, self.groundToId }   -- defensive: an unresolved span is still just two points
        end
    elseif self.groundFromId == nil and self.selectionCount > 0
        and (self.pickFilter == nil or self.pickFilter == "set") then
        span = {}
        for id in pairs(self.selection) do span[#span + 1] = id end
        table.sort(span)
        self.groundUsesSelection = true
        self.pickKind = "set"
    else
        self.groundPreview = nil
        return
    end

    -- The span's own line: its two ends' heights, interpolated by distance along it. That is what
    -- tells a route over a bridge from a road beneath one - see groundTargetAt.
    local pts, along = {}, { 0 }
    for i, id in ipairs(span) do
        local wp = ADGraphManager:getWayPointById(id)
        pts[i] = wp
        if i > 1 and wp ~= nil and pts[i - 1] ~= nil then
            along[i] = along[i - 1] + MathUtil.vector2Length(wp.x - pts[i - 1].x, wp.z - pts[i - 1].z)
        else
            along[i] = along[i - 1] or 0
        end
    end
    local firstWp, lastWp = pts[1], pts[#pts]
    local total = along[#along] or 0
    local function expectedAt(i)
        -- A selection has no span line to interpolate along: each point is judged on its own.
        if self.groundUsesSelection or firstWp == nil or lastWp == nil or total < 0.01 then
            return nil
        end
        local t = along[i] / total
        return firstWp.y + (lastWp.y - firstWp.y) * t
    end

    local offenders, checked, probe = {}, 0, nil
    local middle = math.floor((#span + 1) / 2)
    for index, id in ipairs(span) do
        local wp = pts[index]
        if wp ~= nil then
            checked = checked + 1
            if index == middle or probe == nil then probe = { x = wp.x, y = wp.y, z = wp.z, id = id } end
            -- Its own lookup rather than resolveHeightAt's - see groundTargetAt for why. Bridges are
            -- kept by the downward cast finding the deck, not by refusing to look. keepTolerance =
            -- groundTolerance so a point already sitting on the ramp/bridge deck is left there rather
            -- than dragged down to the terrain the span line runs over.
            local targetY, kind = self:groundTargetAt(wp.x, wp.y, wp.z, expectedAt(index), false, self.groundTolerance)
            if targetY ~= nil then
                local delta = wp.y - targetY
                -- Under a floor or a road mesh is wrong at any tolerance: the point is inside it.
                -- (A floor a few cm over the terrain, Welker Farms 2026-11-03, hid under the 0.5 m default.)
                local under = kind ~= nil and kind ~= "terrain" and delta < -AutoDrive.FLYOVER_GROUND_UNDER
                if under or math.abs(delta) > math.max(self.groundTolerance, 0.005) then
                    offenders[#offenders + 1] =
                        { id = id, x = wp.x, y = wp.y, z = wp.z, targetY = targetY, delta = delta }
                end
            end
        end
    end

    self.groundChecked = checked
    self.groundProbe = probe
    self.groundPreview = #offenders > 0 and offenders or nil
    self.groundBlockedBy = nil
end

function ADFlyoverEditor:groundClick()
    if self.pickFilter == "set" then
        return   -- locked to selections: span clicks are ignored
    end
    self:spanPickClick({
        getFrom = function() return self.groundFromId end,
        getTo = function() return self.groundToId end,
        setEnds = function(a, b)
            self.groundFromId, self.groundToId = a, b
            self.groundPreview = nil
            -- Each new inspection starts from the default tolerance. The wheel adjusts it while a
            -- span is selected, and the wheel is also the zoom - so a value scrolled up by accident and
            -- carried over hid points two and three metres off the ground behind a five-metre tolerance.
            if b == nil then
                self.groundTolerance = AutoDrive.FLYOVER_GROUND_DEFAULT
            end
        end,
        onSpan = function(a, b, span)
            if self.pickKind == "run" then
                self.groundTolerance = AutoDrive.FLYOVER_GROUND_DEFAULT
            end
        end,
    })
end

function ADFlyoverEditor:commitGround()
    if self.groundPreview == nil or #self.groundPreview == 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: nothing is further than %.1fm off the ground in that span "
            .. "(%d waypoint(s) checked).", self.groundTolerance, self.groundChecked or 0)
        local probe = self.groundProbe
        if probe ~= nil then
            self:describeSurfaces(probe.x, probe.z, probe.y, string.format("(ground, nothing moved; id=%s at %.3f)",
                tostring(probe.id), probe.y), nil)
        end
        self:cancelGround()
        return
    end

    ADEditorHistory:snapshot("ground")

    local moved, raised, lowered = 0, 0, 0
    for _, p in ipairs(self.groundPreview) do
        local wp = ADGraphManager:getWayPointById(p.id)
        -- Re-read rather than trusting the preview: it was built on an earlier frame, and an id can
        -- mean a different waypoint after any edit that removed one.
        if wp ~= nil and math.abs(wp.x - p.x) < 0.01 and math.abs(wp.z - p.z) < 0.01 then
            ADGraphManager:moveWayPoint(p.id, p.x, p.targetY, p.z, wp.flags, false)
            moved = moved + 1
            if moved <= 3 then
                self:describeSurfaces(p.x, p.z, math.max(p.y, p.targetY),
                    string.format("(ground id=%s was %.3f)", tostring(p.id), p.y), p.targetY)
            end
            if p.delta > 0 then
                lowered = lowered + 1
            else
                raised = raised + 1
            end
        end
    end

    ADFlyoverSettings.debugLog("[FlyoverEditor]: re-seated %d waypoint(s) on the ground - %d lowered, %d raised "
        .. "(tolerance %.1fm).", moved, lowered, raised, self.groundTolerance)

    self.groundFromId, self.groundToId, self.groundPreview = nil, nil, nil
    self.spanIds = nil
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
end

function ADFlyoverEditor:cancelGround()
    self.spanIds = nil
    if self.groundFromId ~= nil or self.groundToId ~= nil then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: cancelled the ground span.")
    end
    self.groundFromId, self.groundToId, self.groundPreview = nil, nil, nil
end

function ADFlyoverEditor:straightenClick()
    self:spanPickClick({
        getFrom = function() return self.straightenFromId end,
        getTo = function() return self.straightenToId end,
        setEnds = function(a, b)
            self.straightenFromId, self.straightenToId = a, b
            self.straightenPreview = nil
        end,
    })
end

--- Points of the current span, or nil.
function ADFlyoverEditor:straightenSpanPoints()
    if self.straightenFromId == nil or self.straightenToId == nil then
        return nil, nil
    end
    local span = self:spanBetween(self.straightenFromId, self.straightenToId)
    if span == nil or #span < 3 then
        return nil, span
    end
    local pts = {}
    for _, id in ipairs(span) do
        local wp = ADGraphManager:getWayPointById(id)
        if wp ~= nil then
            pts[#pts + 1] = { x = wp.x, y = wp.y, z = wp.z }
        end
    end
    if #pts < 3 then
        return nil, span
    end
    return pts, span
end

--- `count` interior points spread evenly by arc length along `pts`, endpoints included.
local function respreadAlong(pts, count)
    local cumulative = { 0 }
    for i = 2, #pts do
        cumulative[i] = cumulative[i - 1]
            + MathUtil.vector2Length(pts[i].x - pts[i - 1].x, pts[i].z - pts[i - 1].z)
    end
    local total = cumulative[#pts]
    if total <= 0 then
        return nil
    end

    local function pointAt(distance)
        for i = 2, #pts do
            if cumulative[i] >= distance then
                local segLen = cumulative[i] - cumulative[i - 1]
                local f = segLen > 0 and (distance - cumulative[i - 1]) / segLen or 0
                return {
                    x = pts[i - 1].x + (pts[i].x - pts[i - 1].x) * f,
                    z = pts[i - 1].z + (pts[i].z - pts[i - 1].z) * f,
                }
            end
        end
        return { x = pts[#pts].x, z = pts[#pts].z }
    end

    local out = { { x = pts[1].x, y = pts[1].y, z = pts[1].z } }
    for i = 1, count do
        out[#out + 1] = pointAt(total * i / (count + 1))
    end
    out[#out + 1] = { x = pts[#pts].x, y = pts[#pts].y, z = pts[#pts].z }
    return out
end

function ADFlyoverEditor:updateStraightenPreview()
    local pts, span = self:straightenSpanPoints()
    if pts == nil then
        self.straightenPreview = nil
        return
    end

    local simplified = ADPolygonUtils.simplifyOpenChainRDP(pts, self.straightenTolerance)
    if simplified == nil or #simplified < 2 then
        self.straightenPreview = nil
        return
    end

    -- Same interior count as the span had, respread along the simplified shape.
    local result = respreadAlong(simplified, #pts - 2)
    if result == nil then
        self.straightenPreview = nil
        return
    end
    for i = 2, #result - 1 do
        result[i].y = self:resolveHeightAt(result[i].x, result[i].z, heightAlongChain(pts, result[i].x, result[i].z))
    end

    self.straightenPreview = result
    self.straightenKept = #simplified
end

--- Straighten a span, splitting it at any junction or marker so crossing routes survive - the same
--- split the smooth rebuild uses. Straightening the whole span through replaceChainInterior deleted
--- interior junctions and took the connections of the routes crossing there with them; each
--- junction-free piece is straightened on its own instead, and the anchors between pieces are left
--- untouched.
function ADFlyoverEditor:straightenSpanInPieces(ids)
    local anchorPositions, _, pieceFor = self:ownRoutePieces(ids)
    local piecesDone = 0
    -- Backwards, so a rebuilt piece cannot renumber the anchors of a piece not yet reached.
    for i = #anchorPositions - 1, 1, -1 do
        local piece, followedOwnRoute = pieceFor(i)
        if piece ~= nil and #piece > 2 then
            local pts = {}
            for j = 1, #piece do
                local wp = ADGraphManager:getWayPointById(piece[j])
                if wp ~= nil then
                    pts[#pts + 1] = { x = wp.x, y = wp.y, z = wp.z }
                end
            end
            local simplified = ADPolygonUtils.simplifyOpenChainRDP(pts, self.straightenTolerance)
            if simplified ~= nil and #simplified >= 2 then
                local result = respreadAlong(simplified, #pts - 2)
                if result ~= nil then
                    for k = 2, #result - 1 do
                        result[k].y = self:resolveHeightAt(result[k].x, result[k].z,
                            heightAlongChain(pts, result[k].x, result[k].z))
                    end
                    local a = ADGraphManager:getWayPointById(piece[1])
                    local b = ADGraphManager:getWayPointById(piece[2])
                    local dual = ADGraphManager:isDualRoad(a, b)
                    local flags = b.flags or AutoDrive.FLAG_NONE
                    -- A capture of exactly what is replaced, so a point that goes missing at a run's end can be
                    -- traced: the piece's end ids and how many points sat on it, and whether it was the span's
                    -- own route or the fallback path.
                    ADFlyoverSettings.debugLog("[FlyoverEditor]: straighten piece %d: ids %s -> %s (%d point(s)), %s, "
                        .. "keeps %d, replaces the %d between.", i, tostring(piece[1]), tostring(piece[#piece]),
                        #piece, followedOwnRoute and "own route" or "FALLBACK path", 2, #piece - 2)
                    if self:replaceChainInterior(piece, result, dual, flags) then
                        piecesDone = piecesDone + 1
                    end
                end
            end
        end
    end
    return piecesDone
end

function ADFlyoverEditor:commitStraighten()
    local pts, span = self:straightenSpanPoints()
    if pts == nil or span == nil or self.straightenPreview == nil then
        self:cancelStraighten()
        return
    end

    ADEditorHistory:snapshot("straighten span")
    local pieces = self:straightenSpanInPieces(span)

    ADFlyoverSettings.debugLog("[FlyoverEditor]: straightened a %d-point span in %d junction-free piece(s) at %.2fm tolerance.",
        #pts, pieces, self.straightenTolerance)

    self.straightenFromId, self.straightenToId, self.straightenPreview = nil, nil, nil
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
end

function ADFlyoverEditor:cancelStraighten()
    self.spanIds = nil
    if self.straightenFromId ~= nil or self.straightenToId ~= nil then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: cancelled the straighten span.")
    end
    self.straightenFromId, self.straightenToId, self.straightenPreview = nil, nil, nil
end

function ADFlyoverEditor:divideClick()
    self:spanPickClick({
        getFrom = function() return self.divideFromId end,
        getTo = function() return self.divideToId end,
        setEnds = function(a, b)
            self.divideFromId, self.divideToId = a, b
            self.dividePreview = nil
        end,
        onSpan = function(a, b, span)
            -- Start the wheel from what the span already has, so it adjusts from the current spacing
            -- rather than carrying a count over from the previous span (39 points wheeled up on a long
            -- span were once applied to a single segment).
            self.divideCount = math.max(0, #span - 2)
        end,
    })
end

--- How many waypoints currently sit between two ends, or 0 if they are not connected.
function ADFlyoverEditor:currentInteriorCount(fromId, toId)
    local span = self:runPathBetween(fromId, toId)
    if span == nil then
        return 0
    end
    return math.max(0, #span - 2)
end

-- MODSPLIT: SHARED WITH THE FILES LOADED AFTER THIS ONE (tools/modsplit/split.py writes this block)
ADFlyoverEditor.shared.isRoadAt = isRoadAt
ADFlyoverEditor.shared.isPavedAt = isPavedAt
ADFlyoverEditor.shared.roadNote = roadNote
ADFlyoverEditor.shared.roadProbeNoted = roadProbeNoted
-- MODSPLIT: end of the shared block

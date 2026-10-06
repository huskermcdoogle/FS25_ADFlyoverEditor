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

-- The same collision the mod's own height lookup uses, so "the ground" means to this tool what it
-- means to AutoDrive when it drives the route.
local GROUND_MASK = nil
local groundHit = nil

local function groundRayCallback(_, hitObjectId, x, y, z, distance)
    if y ~= nil then
        groundHit = y
    end
end
local GroundRay = { callback = groundRayCallback }

--- The highest surface directly beneath (x, fromY, z), searching `length` metres down. Nil if none.
local function surfaceBelow(x, z, fromY, length)
    if raycastClosest == nil then
        return nil
    end
    if GROUND_MASK == nil then
        GROUND_MASK = CollisionFlag.DEFAULT + CollisionFlag.ROAD + CollisionFlag.TERRAIN
    end
    groundHit = nil
    -- raycastClosest calls back synchronously, which is what AutoDrive relies on as well.
    local ok = pcall(raycastClosest, x, fromY, z, 0, -1, 0, math.max(length, 0.5),
        "callback", GroundRay, GROUND_MASK)
    if not ok then
        return nil
    end
    return groundHit
end

--- Every surface in the column at (x, z), top down, from `topY` to the terrain.
---
--- Stepped with the one ray call already proven here: cast down, note the hit, cast again from just
--- beneath it, until the terrain. That finds a bridge deck AND the road under it, where a single
--- cast from anywhere finds only whichever it meets first - and which that is depends entirely on
--- where the cast starts, which is exactly the decision that has to be made on purpose.
local function columnSurfaces(x, z, topY, terrainY)
    local hits = {}
    local from = topY
    for _ = 1, 8 do
        local h = surfaceBelow(x, z, from, (from - terrainY) + 1)
        if h == nil then
            break
        end
        hits[#hits + 1] = h
        if h <= terrainY + 0.05 then
            break
        end
        from = h - 0.1
    end
    if #hits == 0 or hits[#hits] > terrainY + 0.05 then
        hits[#hits + 1] = terrainY
    end
    return hits
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
    -- High enough to include a deck the span passes over, not so high that it reaches for the
    -- canopy of a tree that happens to overhang the road.
    local topY = math.max(y, reference, terrainY) + 15
    local surfaces = columnSurfaces(x, z, topY, terrainY)

    -- The level toggle belongs to the ground tool. Other callers laying new track want the surface
    -- nearest the line they came from, whatever the ground tool happens to be set to.
    if not spanLineOnly and self.groundLevel == self.GROUND_LEVEL.TOP then
        return surfaces[1]
    end

    -- Keep the point on the surface it already sits on, so grounding never pulls a point down off a
    -- ramp or bridge deck it is correctly on; only points off EVERY surface fall through to the span
    -- line below. This is what stops a route over a placed ramp being flattened onto the terrain.
    if keepTolerance ~= nil then
        for _, h in ipairs(surfaces) do
            if math.abs(y - h) <= keepTolerance then
                return h
            end
        end
    end

    local best, bestGap = surfaces[#surfaces], math.huge
    for _, h in ipairs(surfaces) do
        local gap = math.abs(h - reference)
        if gap < bestGap then
            best, bestGap = h, gap
        end
    end
    return best
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

    local offenders, checked = {}, 0
    for index, id in ipairs(span) do
        local wp = pts[index]
        if wp ~= nil then
            checked = checked + 1
            -- Its own lookup rather than resolveHeightAt's - see groundTargetAt for why. Bridges are
            -- kept by the downward cast finding the deck, not by refusing to look. keepTolerance =
            -- groundTolerance so a point already sitting on the ramp/bridge deck is left there rather
            -- than dragged down to the terrain the span line runs over.
            local targetY = self:groundTargetAt(wp.x, wp.y, wp.z, expectedAt(index), false, self.groundTolerance)
            if targetY ~= nil then
                local delta = wp.y - targetY
                if math.abs(delta) > self.groundTolerance then
                    offenders[#offenders + 1] =
                        { id = id, x = wp.x, y = wp.y, z = wp.z, targetY = targetY, delta = delta }
                end
            end
        end
    end

    self.groundChecked = checked
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
ADFlyoverEditor.shared.roadNote = roadNote
ADFlyoverEditor.shared.roadProbeNoted = roadProbeNoted
-- MODSPLIT: end of the shared block

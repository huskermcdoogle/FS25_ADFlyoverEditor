--[[
Field-boundary loop generator: builds a smoothed, drivable AutoDrive waypoint loop that runs just
outside a field's boundary (roughly half a vehicle-width clear of the edge), nudging inward around
any trees along the way. Triggered via the ADGenerateFieldLoop console command (registered in
DevFuncs.lua). Produces a standalone two-way secondary route - no map markers, no connection to
the rest of the route network; wire it in manually with AutoDrive's existing recording/editor
tools.

Relies on g_farmlandManager / Field:getDensityMapPolygon() for the field boundary - this is not
documented by Giants at the parameter level (confirmed only by reading their shipped Lua, the
same way Courseplay's authors did), so every step of that chain is pcall-guarded and fails with a
clear log message rather than a hard error if the API differs on a given game version.

COMPANION EDIT: the four AutoDrive.getSetting("fieldLoop...") reads became ADFlyoverSettings.get.
Those four settings do not exist in stock AutoDrive, and three of the reads had no fallback, so the
first invocation against stock was a hard Lua error. They cannot be injected into AutoDrive.settings
either - that table is iterated in 17 places and UpdateSettingsEvent indexes it unguarded, so one
extra key breaks a stock client's settings sync. So we own them. Everything else is verbatim.
]]

-- How much heading change a single waypoint is allowed to carry. Everything below is tuned to
-- keep the driven path under this: a bigger step reads as a jerk at the wheel, however
-- geometrically correct the underlying curve is.
AutoDrive.FIELD_LOOP_MAX_WAYPOINT_TURN_DEG = 5

-- A vertex counts as a corner needing rounding when a turningRadius arc would miss it by more
-- than this. It doubles as the fidelity budget: rounding a bend moves the path by at most this
-- much, so a small value buys smoothness almost for free. Measured on a test boundary, dropping
-- it from 0.2 to 0.02 took the sharpest waypoint from 18.6deg to 4.3deg while leaving deviation
-- from the real boundary unchanged at 1.48m - the bends it now rounds were being left completely
-- untouched, and those were exactly the jumpy ones.
AutoDrive.FIELD_LOOP_MAX_CROSS_TRACK_ERROR = 0.02
AutoDrive.FIELD_LOOP_ADAPTIVE_TOLERANCE = 0.01 -- sagitta-formula tolerance for thinToAdaptiveSpacing
AutoDrive.FIELD_LOOP_ADAPTIVE_PROTECT_ANGLE_DEG = 20 -- vertices turning more than this are never thinned
AutoDrive.FIELD_LOOP_ADAPTIVE_MIN_SPACING = 1.0 -- meters, closest points ever get even on tight curves
AutoDrive.FIELD_LOOP_ADAPTIVE_MAX_SPACING = 8.0 -- meters, sparsest points ever get on dead-straight runs
AutoDrive.FIELD_LOOP_SPLINE_ORDER = 2 -- refine-and-tuck passes; each roughly doubles point count before thinning claws it back
-- Only smooth what actually exceeds the per-waypoint target; a bend already inside it is fine as
-- it is, and smoothing it would trade boundary fidelity for nothing.
AutoDrive.FIELD_LOOP_SPLINE_MIN_ANGLE_DEG = AutoDrive.FIELD_LOOP_MAX_WAYPOINT_TURN_DEG
AutoDrive.FIELD_LOOP_TREE_DETOUR_AMPLITUDE_STEP = 0.25 -- meters; granularity of the detour depth search
AutoDrive.FIELD_LOOP_TREE_DETOUR_MAX_DEPTH = 15 -- meters; give up rather than bend the loop further than this into the field
AutoDrive.FIELD_LOOP_TREE_DENSIFY_SPACING = 1.5 -- meters; resolution added along segments passing near a tree, before detouring
AutoDrive.FIELD_LOOP_TREE_SMOOTH_ITERATIONS = 12 -- relaxation passes available to the post-detour safety net
AutoDrive.FIELD_LOOP_OTHER_LOOP_CLEARANCE = 1.0 -- meters a new loop keeps from another standalone loop (its margin is pulled in to manage it)
AutoDrive.FIELD_LOOP_MARGIN_PULL_STEP = 0.25 -- meters the margin comes in per try
AutoDrive.FIELD_LOOP_EDGE_MARGIN_FLOOR = -4.0 -- meters; how far INSIDE the field's outline an edge's loop may go to stay on the field side of a fence (negative = inside)
AutoDrive.FIELD_LOOP_CORNER_PUSH_STEP = 0.5 -- meters a blocked field corner moves inward per try, before it is re-rounded
AutoDrive.FIELD_LOOP_CORNER_PUSH_MAX = 30 -- meters; give up moving one corner further in than this
-- How close to a full 180-degree fold-back counts as a spike (see ADOffsetGeometry.removeSpikes,
-- the final cleanup pass on the ring that actually gets placed) rather than a genuine sharp field
-- corner. 90-120 degrees is a normal corner; 150+ is the path doubling back on itself.
AutoDrive.FIELD_LOOP_MAX_REVERSAL_DEG = 150
-- The other half of removeSpikes: a point does not need to be a near-reversal to be an artifact -
-- one that is BOTH turning sharply (above this) AND unusually close to a neighbour relative to the
-- ring's own average spacing (below FIELD_LOOP_OUTLIER_SPACING_RATIO) is the signature of a stray
-- point left by the pipeline, not an intentional tight corner - a real small-radius arc turns
-- gradually across several evenly-spaced points, it does not put a whole corner's worth of turn on
-- one point that is also oddly close to its neighbour.
AutoDrive.FIELD_LOOP_OUTLIER_ANGLE_DEG = 70
AutoDrive.FIELD_LOOP_OUTLIER_SPACING_RATIO = 0.5
-- A vehicle that can only turn this tightly is already unusual; whatever the player's turning
-- radius SETTING says, the corner-rounding math below never uses less than this. Reported live
-- (2026-09-22): a 3m setting left an awkward kink at a field corner sharper than a 3m arc could
-- smoothly represent. Lowered from 5 to 2 on request (small vehicles turn tighter); keep the
-- fieldLoopTurningRadius setting's range floor in Settings.lua equal to this.
AutoDrive.FIELD_LOOP_MIN_CORNER_RADIUS = 2

-- ---------------------------------------------------------------------------------------------
-- Live tilled-ground boundary tracer, no Courseplay involved. Confirmed live (2026-09-22):
-- FSDensityMapUtil.getFieldDataAtWorldPosition is a plain base-game global, reachable directly
-- with no environment-resolution dance (unlike Courseplay's own g_fieldScanner/g_customFieldManager,
-- which this mod tried and deliberately dropped - see git history). Same probe-walk TECHNIQUE
-- Courseplay's own field scanner uses - a standard boundary-following approach, not anything
-- Courseplay invented - reimplemented here from scratch against base-game primitives only:
-- createTransformGroup/link/setTranslation/setRotation/getRotation/localToWorld (already used
-- elsewhere in this codebase - see Proxy.lua) and FSDensityMapUtil.
-- ---------------------------------------------------------------------------------------------

AutoDrive.FIELD_TRACE_RESOLUTION = 0.2         -- meters; forward step while walking onto/off the field
AutoDrive.FIELD_TRACE_HIGH_RESOLUTION = 0.1    -- meters; fine backup step to land right on the edge
AutoDrive.FIELD_TRACE_LOOKAHEAD = 5.0          -- meters; how far ahead the probe checks while tracing
AutoDrive.FIELD_TRACE_SHORT_LOOKAHEAD = 0.5    -- meters; short lookahead used only when first orienting
AutoDrive.FIELD_TRACE_MAX_POINTS = 20000       -- safety cap so a pathological trace cannot run forever

local function isOnFieldGround(x, z)
    local okY, y = pcall(function() return AutoDrive:getTerrainHeightAtWorldPos(x, z) end)
    local okField, isField = pcall(function()
        return FSDensityMapUtil.getFieldDataAtWorldPosition(x, (okY and y) or 0, z)
    end)
    return okField and isField == true
end

local function isNodeOnFieldGround(node)
    local x, _, z = getWorldTranslation(node)
    return isOnFieldGround(x, z)
end

local function traceSetPosition(node, x, z)
    local okY, y = pcall(function() return AutoDrive:getTerrainHeightAtWorldPos(x, z) end)
    setTranslation(node, x, (okY and y) or 0, z)
end

local function traceMoveForward(node, d)
    local x, _, z = localToWorld(node, 0, 0, d)
    traceSetPosition(node, x, z)
end

local function traceRotateBy(node, angleStep)
    local _, yRot, _ = getRotation(node)
    setRotation(node, 0, yRot + angleStep, 0)
end

--- True when the line from the probe out to `lookahead` ahead of it is field ground all the way. Checking
--- only the far point let the probe see a field BEYOND a narrow strip as the field continuing: two fields
--- closer than the lookahead (5 m) came out as one contour (measured offline: gaps of 4 m or less merged,
--- 5 m and up did not). Walking the line stops at the gap. Gaps under about a metre are forgiven, though:
--- the density map is a grid of cells, so a field edge is a stair, and a line aimed along it clips the
--- steps - strict checking made the traced outline zigzag (39 corners on a plain rectangle where it had
--- 7). A step is under a metre wide; a strip worth separating is not.
local FIELD_RAY_STEP = 0.25
local FIELD_RAY_FORGIVE = 4 -- consecutive off-field samples forgiven (x step metres): a pixel step in the edge, not a strip
local function isFieldClearAhead(node, lookahead)
    local d = lookahead
    local offRun = 0
    while d > 0 do
        local x, _, z = localToWorld(node, 0, 0, d)
        if isOnFieldGround(x, z) then
            offRun = 0
        else
            offRun = offRun + 1
            if offRun >= FIELD_RAY_FORGIVE then
                return false
            end
        end
        d = d - FIELD_RAY_STEP
    end
    local x, _, z = localToWorld(node, 0, 0, lookahead)
    return isOnFieldGround(x, z)
end

--- Rotate the probe until a point `lookahead` ahead of it just crosses the field edge, so the
--- probe ends up aimed roughly along the boundary.
local function traceRotateToEdgeDirection(node, lookahead)
    local startOnField = isFieldClearAhead(node, lookahead)
    local target = not startOnField
    local angleStep = AutoDrive.FIELD_TRACE_HIGH_RESOLUTION / AutoDrive.FIELD_TRACE_LOOKAHEAD
    local swept, isOnField = 0, startOnField
    while swept < 2 * math.pi and isOnField ~= target do
        isOnField = isFieldClearAhead(node, lookahead)
        traceRotateBy(node, (isOnField and 1 or -1) * angleStep)
        swept = swept + angleStep
    end
    local _, yRot, _ = getRotation(node)
    return yRot
end

--- Walk forward while on the field, then back off in small steps until the probe is just off it -
--- lands right at the edge, ready to start tracing along it.
local function traceFindEdge(node)
    local i = 0
    while i < 100000 and isNodeOnFieldGround(node) do
        traceMoveForward(node, AutoDrive.FIELD_TRACE_RESOLUTION)
        i = i + 1
    end
    local guard = 0
    while not isNodeOnFieldGround(node) and guard < 100000 do
        traceMoveForward(node, -AutoDrive.FIELD_TRACE_HIGH_RESOLUTION)
        guard = guard + 1
    end
    traceRotateToEdgeDirection(node, AutoDrive.FIELD_TRACE_SHORT_LOOKAHEAD)
end

--- Walk the probe all the way around the field boundary, recording a point roughly every
--- FIELD_TRACE_LOOKAHEAD meters, stopping once it has swept back close to a full turn and ended
--- up near where it started. Returns closed(bool), points, lost(bool).
local function traceFieldEdge(node)
    local points = {}
    local startX, _, startZ = getWorldTranslation(node)
    table.insert(points, { x = startX, z = startZ })
    local distanceFromStart = math.huge
    local lookahead = AutoDrive.FIELD_TRACE_LOOKAHEAD
    local totalRot = 0
    local prevYRot = nil
    local i = 0
    while i < AutoDrive.FIELD_TRACE_MAX_POINTS
        and (i == 0 or distanceFromStart > lookahead or math.abs(totalRot) < math.pi) do
        local yRot = traceRotateToEdgeDirection(node, lookahead)
        local deltaYRot = yRot - (prevYRot or yRot)
        traceMoveForward(node, lookahead)
        local px, _, pz = getWorldTranslation(node)
        table.insert(points, { x = px, z = pz })
        distanceFromStart = MathUtil.vector2Length(px - startX, pz - startZ)
        totalRot = totalRot + deltaYRot
        prevYRot = yRot
        i = i + 1
        if math.abs(totalRot) > 3 * math.pi then
            return false, points, true
        end
    end
    -- Clockwise winding (negative total rotation) and swept most of the way around.
    return totalRot < 0 and math.abs(totalRot) > math.pi, points, false
end

--- Trace the boundary of whatever tilled ground is at (x, z). No Courseplay involved: built
--- directly on FSDensityMapUtil.getFieldDataAtWorldPosition (a base-game global).
function AutoDrive:traceFieldBoundary(x, z)
    if type(FSDensityMapUtil) ~= "table" or type(FSDensityMapUtil.getFieldDataAtWorldPosition) ~= "function" then
        return nil, "FSDensityMapUtil is not available."
    end
    if not isOnFieldGround(x, z) then
        return nil, string.format("x=%.1f z=%.1f is not on field ground.", x, z)
    end
    if g_currentMission == nil or g_currentMission.terrainRootNode == nil then
        return nil, "no terrain root node to trace against."
    end

    local okNode, node = pcall(createTransformGroup, "adFieldTraceProbe")
    if not okNode or node == nil then
        return nil, "could not create a probe node."
    end
    pcall(link, g_currentMission.terrainRootNode, node)
    traceSetPosition(node, x, z)
    -- Nudge off yRot 0: starting the probe right in a corner (common, since a player tends to
    -- click near the edge) otherwise finds the field edge very close to the corner, which then
    -- throws off corner detection later in the pipeline.
    setRotation(node, 0, math.pi / 7, 0)

    local points, ok = nil, false
    for attempt = 1, 10 do
        traceFindEdge(node)
        local closed, tracedPoints, lost = traceFieldEdge(node)
        if closed and not lost then
            points = tracedPoints
            ok = true
            break
        end
        traceSetPosition(node, x, z)
        setRotation(node, 0, attempt * math.pi / 6, 0)
    end

    pcall(function()
        unlink(node)
        delete(node)
    end)

    if not ok or points == nil or #points < 3 then
        return nil, "could not trace a closed field boundary here."
    end
    return points, nil
end

--- Returns points, label, err. Falls back to the base-game farmland lookup if the trace finds
--- nothing or the toggle is off - a report of this misbehaving on a particular map/save can be
--- isolated by switching it off without a rollback.
function AutoDrive:getFieldPolygonAtPosition(x, z)
    if ADFlyoverSettings.get("fieldLoopDetectCustomField") then
        local traced, traceErr = AutoDrive:traceFieldBoundary(x, z)
        if traced == nil then
            ADFlyoverSettings.debugLog("[FlyoverEditor]: field loop trace failed, using the map field: %s", tostring(traceErr))
        else
            ADFlyoverSettings.debugLog("[FlyoverEditor]: field loop traced a %d-point tilled-ground contour.", #traced)
            return traced, "Traced field", nil
        end
    end

    if g_farmlandManager == nil then
        return nil, nil, "g_farmlandManager is not available."
    end

    local okFarmland, farmland = pcall(function()
        return g_farmlandManager:getFarmlandAtWorldPosition(x, z)
    end)
    if not okFarmland or farmland == nil then
        return nil, nil, string.format("No farmland at x=%.1f z=%.1f.", x, z)
    end

    local okField, field = pcall(function()
        return farmland:getField()
    end)
    if not okField or field == nil then
        return nil, nil, string.format("No field at x=%.1f z=%.1f - that farmland has no field on it.", x, z)
    end

    local okPolygon, polygon = pcall(function()
        return field:getDensityMapPolygon()
    end)
    if not okPolygon or polygon == nil then
        return nil, nil, "Field has no boundary polygon."
    end

    local okVerts, verts = pcall(function()
        return polygon:getVerticesList()
    end)
    if not okVerts or verts == nil or #verts < 6 then
        return nil, nil, "Field boundary polygon is degenerate (<3 vertices)."
    end

    local points = {}
    for i = 1, #verts, 2 do
        points[#points + 1] = { x = verts[i], z = verts[i + 1] }
    end

    local fieldLabel = "FieldLoop"
    local okLabel, fieldId = pcall(function() return field.fieldId end)
    if okLabel and fieldId ~= nil then
        fieldLabel = "Field " .. tostring(fieldId)
    end

    return points, fieldLabel, nil
end

local function pointInPolygon(px, pz, poly)
    local inside = false
    local j = #poly
    for i = 1, #poly do
        local pi, pj = poly[i], poly[j]
        if (pi.z > pz) ~= (pj.z > pz)
            and px < (pj.x - pi.x) * (pz - pi.z) / (pj.z - pi.z) + pi.x then
            inside = not inside
        end
        j = i
    end
    return inside
end

-- Auto-discovery is bounded on both axes: FIELD_LOOP_MAX_REGIONS caps how many disconnected
-- patches one field loop will ever combine (a runaway match against unrelated fields elsewhere is
-- a bug report, not a feature), and PROBE_STRIDE samples only every Nth raw scan point so the
-- search cost tracks boundary length rather than findContour's (much higher) point density.
AutoDrive.FIELD_LOOP_MAX_REGIONS = 6
AutoDrive.FIELD_LOOP_PROBE_STRIDE = 6
AutoDrive.FIELD_LOOP_PROBE_STEP = 1.0 -- meters between probe samples along each outward ray

--- Auto-discover every tilled-ground region connected to the first one via a gap no wider than
--- fieldLoopMaxGap - a lane splitting one field into disconnected patches, say. Fully automatic,
--- no extra clicks: probes outward from points around each found region's boundary, on BOTH sides
--- (winding direction is not assumed), and scans a fresh contour wherever a probe lands on tilled
--- ground not already inside a found region.
---
--- Built entirely on the same Courseplay-free primitives as getFieldPolygonAtPosition
--- (isOnFieldGround/traceFieldBoundary above) - no Courseplay involved.
---
--- Distance is the ONLY signal this has for "same field, split by a lane" vs. "a genuinely
--- different field that happens to be nearby, across an actual road" - reported live
--- (2026-09-22): the default combo gap pulled in an unrelated field across a real road. Field ID
--- cannot tell them apart either: even Courseplay's own field scanner (when this mod still used
--- it) ignored field ID while scanning for exactly this reason - the STATIC id does not update
--- when two map fields get tilled together, so requiring a match would reject the exact case this
--- exists for, not just the unwanted one. fieldLoopMaxGap is genuinely a per-map, per-player
--- tuning knob: set it just above your widest field lane and it should not reach a real road,
--- since roads are typically wider than a field lane.
function AutoDrive:findConnectedFieldRegions(x, z, firstRegion)
    local regions = { firstRegion }

    local maxGap = ADFlyoverSettings.get("fieldLoopMaxGap") or 8
    local step = AutoDrive.FIELD_LOOP_PROBE_STEP

    local function alreadyCovered(px, pz)
        for _, r in ipairs(regions) do
            if pointInPolygon(px, pz, r) then
                return true
            end
        end
        return false
    end

    local expanded = true
    while expanded and #regions < AutoDrive.FIELD_LOOP_MAX_REGIONS do
        expanded = false
        for ri = 1, #regions do
            local r = regions[ri]
            local n = #r
            local i = 1
            while i <= n and not expanded do
                local a, b = r[i], r[(i % n) + 1]
                local ex, ez = b.x - a.x, b.z - a.z
                local len = MathUtil.vector2Length(ex, ez)
                if len > 1e-6 then
                    local nx, nz = -ez / len, ex / len
                    local side = 1
                    while side >= -1 and not expanded do
                        local dist = step
                        while dist <= maxGap do
                            local px, pz = a.x + nx * dist * side, a.z + nz * dist * side
                            if not alreadyCovered(px, pz) and isOnFieldGround(px, pz) then
                                local newRegion = AutoDrive:traceFieldBoundary(px, pz)
                                if newRegion ~= nil and #newRegion >= 3 and not alreadyCovered(newRegion[1].x, newRegion[1].z) then
                                    table.insert(regions, newRegion)
                                    ADFlyoverSettings.debugLog("[FlyoverEditor]: field loop auto-discovered region %d, %.1fm from an existing one.",
                                        #regions, dist)
                                    expanded = true
                                end
                            end
                            if expanded then break end
                            dist = dist + step
                        end
                        side = side - 2
                    end
                end
                i = i + AutoDrive.FIELD_LOOP_PROBE_STRIDE
            end
            if expanded then break end
        end
    end

    return regions
end

-- Synchronous overlap check at (x, z), mirroring ADCollSensor's own overlapBox usage
-- (Sensors/CollSensor.lua). Named for trees because that is the common case, but the mask below
-- also catches everything the junction tool's own obstacle check does (junctionObstacleMask) -
-- telephone poles, fences, signs and small buildings are CollisionFlag.STATIC_OBJECT, not TREE,
-- and TREE-only silently drove the loop straight through a pole line. Widened rather than renamed:
-- every caller already reads "tree" as "the thing along the boundary I have to detour around".
AutoDrive.FIELD_LOOP_OBSTACLE_MASK = (CollisionFlag.DEFAULT or 0) + CollisionFlag.TREE
    + CollisionFlag.STATIC_OBJECT + (CollisionFlag.DYNAMIC_OBJECT or 0) + CollisionFlag.BUILDING

function AutoDrive:fieldLoopTreeOverlapCallback(transformId)
    self.fieldLoopTreeHit = true
end

-- Box spans from ground level up to the vehicle height, so canopy/branches - and a pole's crossarm
-- or transformer - that flare out wider higher up are caught, but only as high as anything actually
-- drives. Checking higher than the tallest machine detours around branches (or wires) that pass
-- clear over it, and since a mature crown flares widest near its top, every extra metre of height
-- costs real width. For reference: tractors ~2.8-3.5m, combines ~3.9-4m (built to clear the 4m road
-- limit), trucks 4.0-4.1m, folded implements up to ~4.5m - hence a 4m default, adjustable to suit
-- the tallest machine.
function AutoDrive:hasTreeNear(x, z, halfExtent)
    self.fieldLoopTreeHit = false
    local y = AutoDrive:getTerrainHeightAtWorldPos(x, z)
    local halfHeight = (ADFlyoverSettings.get("fieldLoopVehicleHeight") or 4.0) / 2
    overlapBox(x, y + halfHeight, z, 0, 0, 0, halfExtent, halfHeight, halfExtent, "fieldLoopTreeOverlapCallback", AutoDrive, AutoDrive.FIELD_LOOP_OBSTACLE_MASK, true, true, true, true)
    return self.fieldLoopTreeHit == true
end

--- What the obstacle test actually hit at (x, z): one log line per object, with its name, the names
--- of its parents (a map's own collision helpers and leftover objects are named in their groups),
--- whether it is visible, its rigid body type and where it sits. The test only ever says "something
--- is there", and a spot where nothing can be seen (reported 2026-10-08) needs to say what. Never
--- called from the hot path - only when the generator has already given up on a spot.
function AutoDrive:fieldLoopTreeCollectCallback(transformId)
    local list = self.fieldLoopHitList
    if list ~= nil and #list < 8 then
        list[#list + 1] = transformId
    end
end

function AutoDrive:describeObstaclesAt(x, z, halfExtent)
    local y = AutoDrive:getTerrainHeightAtWorldPos(x, z)
    local halfHeight = (ADFlyoverSettings.get("fieldLoopVehicleHeight") or 4.0) / 2
    self.fieldLoopHitList = {}
    pcall(overlapBox, x, y + halfHeight, z, 0, 0, 0, halfExtent, halfHeight, halfExtent,
        "fieldLoopTreeCollectCallback", AutoDrive, AutoDrive.FIELD_LOOP_OBSTACLE_MASK, true, true, true, true)
    local hits = self.fieldLoopHitList
    self.fieldLoopHitList = nil
    if #hits == 0 then
        Logging.info("[AD] field loop obstacle at x=%.1f z=%.1f: the check finds nothing there now.", x, z)
        return
    end
    for _, id in ipairs(hits) do
        local chain = {}
        local node = id
        for _ = 1, 5 do
            local okName, name = pcall(getName, node)
            chain[#chain + 1] = (okName and name) or "?"
            local okParent, parent = pcall(getParent, node)
            if not okParent or parent == nil or parent == 0 then break end
            node = parent
        end
        local okV, visible = pcall(getVisibility, id)
        local okB, body = pcall(getRigidBodyType, id)
        local okT, tx, ty, tz = pcall(getWorldTranslation, id)
        Logging.info("[AD] field loop obstacle at x=%.1f z=%.1f: node %s, parents [%s], visible=%s, body=%s, at %s",
            x, z, tostring(id), table.concat(chain, " < "), okV and tostring(visible) or "?",
            okB and tostring(body) or "?", okT and string.format("%.1f %.1f %.1f", tx, ty, tz) or "?")
    end
end

-- Unit normal at each point, perpendicular to the local path direction, pointing toward the field
-- interior. Displacing along THIS rather than along "toward the field centroid" is what keeps a
-- detour from bunching points up: the centroid direction can be largely parallel to the path
-- (anywhere the loop runs roughly toward or away from the field's middle), so pushing along it
-- slides points down the path into each other instead of moving them aside.
local function inwardNormals(ring, fieldCentroid)
    local n = #ring
    local normals = {}
    for i = 1, n do
        local prev = ring[((i - 2) % n) + 1]
        local nxt = ring[(i % n) + 1]
        local tx, tz = nxt.x - prev.x, nxt.z - prev.z
        local len = MathUtil.vector2Length(tx, tz)
        if len < 1e-6 then
            normals[i] = { x = 0, z = 0 }
        else
            local nx, nz = -tz / len, tx / len
            if (fieldCentroid.x - ring[i].x) * nx + (fieldCentroid.z - ring[i].z) * nz < 0 then
                nx, nz = -nx, -nz
            end
            normals[i] = { x = nx, z = nz }
        end
    end
    return normals
end

--- Bends the loop around trees as a proper detour rather than nudging each blocked point on its
--- own. Per-point nudging stops as soon as each individual point happens to clear, which leaves a
--- ragged scallop of unequal displacements that no later smoothing can rescue (every relaxation
--- that would even it out gets rejected for re-entering the clearance radius).
---
--- Instead: find each contiguous run of blocked points, then displace a whole window around it
--- along the path normal by a raised cosine, offset(ds) = A/2 * (1 + cos(pi*ds/W)). That shape is
--- flat-tangent at both ends, so the detour blends into the untouched path with no kink at all,
--- and its curvature peaks at A*pi^2/(2W^2) - so choosing W >= pi*sqrt(A*R/2) keeps the whole
--- detour inside turning radius R by construction, rather than smoothing a kink after the fact.
--- Amplitude grows until every point in the window clears, so the shape is verified, not assumed.
local function detourAroundTrees(ring, fieldCentroid, treeClearance, turningRadius)
    local n = #ring
    local stats = { nudged = 0, stuck = 0, detours = 0 }
    if n < 3 then
        return ring, stats
    end

    local blocked, anyBlocked = {}, false
    for i = 1, n do
        blocked[i] = AutoDrive:hasTreeNear(ring[i].x, ring[i].z, treeClearance)
        if blocked[i] then anyBlocked = true end
    end
    if not anyBlocked then
        return ring, stats
    end

    local normals = inwardNormals(ring, fieldCentroid)

    local s = { [1] = 0 }
    for i = 2, n do
        s[i] = s[i - 1] + MathUtil.vector2Length(ring[i].x - ring[i - 1].x, ring[i].z - ring[i - 1].z)
    end
    local total = s[n] + MathUtil.vector2Length(ring[1].x - ring[n].x, ring[1].z - ring[n].z)

    local function arcDelta(from, to)
        local d = to - from
        while d > total / 2 do d = d - total end
        while d < -total / 2 do d = d + total end
        return d
    end

    -- Start scanning from a clear point so a run straddling the array end stays one run.
    local startIx = nil
    for i = 1, n do
        if not blocked[i] then startIx = i break end
    end
    if startIx == nil then
        stats.stuck = n
        return ring, stats
    end

    local runs = {}
    local runOf = {}
    local k = 1
    while k <= n do
        local idx = ((startIx - 1 + k - 1) % n) + 1
        if blocked[idx] then
            local run = { idx }
            local k2 = k + 1
            while k2 <= n do
                local idx2 = ((startIx - 1 + k2 - 1) % n) + 1
                if not blocked[idx2] then break end
                run[#run + 1] = idx2
                k2 = k2 + 1
            end
            runs[#runs + 1] = run
            for _, ix in ipairs(run) do runOf[ix] = #runs end
            k = k2
        else
            k = k + 1
        end
    end

    local displacement = {}
    for i = 1, n do displacement[i] = 0 end

    -- Fine steps so the detour is only as deep as it needs to be; 1m steps overshot by up to a
    -- metre on every detour.
    local step = AutoDrive.FIELD_LOOP_TREE_DETOUR_AMPLITUDE_STEP
    local maxAmplitude = math.max(AutoDrive.FIELD_LOOP_TREE_DETOUR_MAX_DEPTH, treeClearance * 6)

    for runIx, run in ipairs(runs) do
        stats.detours = stats.detours + 1
        local runSpan = arcDelta(s[run[1]], s[run[#run]])
        local centreS = s[run[1]] + runSpan / 2
        local runLen = math.abs(runSpan)

        local applied = false
        local amplitude = step
        while amplitude <= maxAmplitude do
            local w = math.max(runLen, math.pi * math.sqrt(amplitude * turningRadius / 2))

            -- Displaced position of every point the bump touches, so the check below can look at
            -- the segments between them and not just the points themselves.
            local moved, inWindow = {}, {}
            for i = 1, n do
                local ds = arcDelta(centreS, s[i])
                if math.abs(ds) <= w then
                    local off = amplitude * 0.5 * (1 + math.cos(math.pi * ds / w))
                    moved[i] = { x = ring[i].x + normals[i].x * off, z = ring[i].z + normals[i].z * off }
                    inWindow[#inWindow + 1] = i
                end
            end

            local ok = true
            for _, i in ipairs(inWindow) do
                -- Only this run's own blocked points drive the amplitude, plus a guard that the
                -- bump does not shove a previously-clear point into something. A point blocked by
                -- a DIFFERENT tree is skipped: it sits near the window edge where the raised
                -- cosine displaces it by almost nothing, so requiring it to clear inflated the
                -- amplitude without ever being able to fix it - and since the window widens as
                -- sqrt(amplitude), that pulled in yet more such points and ran away. Its own
                -- run's detour is what deals with it.
                if (runOf[i] == runIx) or (runOf[i] == nil) then
                    if AutoDrive:hasTreeNear(moved[i].x, moved[i].z, treeClearance) then
                        ok = false
                        break
                    end
                    -- The vehicle drives the segments, not the points: a chord between two
                    -- cleared points can still cut the corner of a clearance circle. Snug
                    -- amplitudes make that reachable (a coarser search used to overshoot past it
                    -- by accident), so check the span to the next displaced point too.
                    local nextIx = (i % n) + 1
                    if moved[nextIx] ~= nil then
                        local mx = (moved[i].x + moved[nextIx].x) / 2
                        local mz = (moved[i].z + moved[nextIx].z) / 2
                        if AutoDrive:hasTreeNear(mx, mz, treeClearance) then
                            ok = false
                            break
                        end
                    end
                end
            end
            if ok then
                for i = 1, n do
                    local ds = arcDelta(centreS, s[i])
                    if math.abs(ds) <= w then
                        local off = amplitude * 0.5 * (1 + math.cos(math.pi * ds / w))
                        if off > displacement[i] then displacement[i] = off end
                    end
                end
                applied = true
                break
            end
            amplitude = amplitude + step
        end

        if not applied then
            stats.stuck = stats.stuck + #run
            Logging.warning(
                "[AD] ADGenerateFieldLoop: could not route around a tree near x=%.1f z=%.1f within %.0fm - left in place, check that spot manually.",
                ring[run[1]].x, ring[run[1]].z, maxAmplitude
            )
            AutoDrive:describeObstaclesAt(ring[run[1]].x, ring[run[1]].z, treeClearance)
        end
    end

    local result = {}
    for i = 1, n do
        if displacement[i] > 1e-6 then
            stats.nudged = stats.nudged + 1
        end
        result[i] = {
            x = ring[i].x + normals[i].x * displacement[i],
            z = ring[i].z + normals[i].z * displacement[i],
            isCornerArc = ring[i].isCornerArc
        }
    end

    return result, stats
end

-- Sparse sampling can step straight over a tree: two consecutive ring points can both pass the
-- clearance check while the straight line between them runs well inside it, so the tree is never
-- seen at all. It also leaves the nudge nothing to shape a bump with - one lone displaced point
-- between two distant untouched ones is a spike, not a detour. So before nudging, any segment
-- that passes near a tree anywhere along its length gets subdivided finely.
local function densifyNearTrees(ring, treeClearance, fineSpacing)
    local n = #ring
    local result = {}
    for i = 1, n do
        local a, b = ring[i], ring[(i % n) + 1]
        result[#result + 1] = { x = a.x, z = a.z, isCornerArc = a.isCornerArc }

        local len = MathUtil.vector2Length(b.x - a.x, b.z - a.z)
        if len > fineSpacing then
            local samples = math.ceil(len / fineSpacing)
            local nearTree = false
            for s = 1, samples - 1 do
                local t = s / samples
                if AutoDrive:hasTreeNear(a.x + (b.x - a.x) * t, a.z + (b.z - a.z) * t, treeClearance) then
                    nearTree = true
                    break
                end
            end
            if nearTree then
                for s = 1, samples - 1 do
                    local t = s / samples
                    result[#result + 1] = { x = a.x + (b.x - a.x) * t, z = a.z + (b.z - a.z) * t }
                end
            end
        end
    end
    return result
end

--- Moves any polygon corner whose ROUNDED arc touches a tree further into the field, then rounds
--- again, until the arc clears. Doing this on the sharp polygon, before the corners are rounded, is
--- the point: the rounding then redraws every corner at the full turning radius. Bending the finished
--- path instead (detourAroundTrees) pushes a rounded corner inward along per-point normals, which
--- converge on the corner's centre and fold it into a hook (measured offline: 0.47m radius, points
--- 0.17m apart). Only the corner vertex moves, so the two edges just tilt slightly toward it.
---@return table polygon, table rounded
local function pushBlockedCornersIn(offset, treeClearance, turningRadius, arcSpacing)
    local poly = {}
    for i, p in ipairs(offset) do
        poly[i] = { x = p.x, z = p.z, y = p.y }
    end
    local n = #poly
    local areaSign = ADPolygonUtils.getSignedArea(poly) > 0 and 1 or -1
    local pushedBy = {}
    local step = AutoDrive.FIELD_LOOP_CORNER_PUSH_STEP
    local maxPush = AutoDrive.FIELD_LOOP_CORNER_PUSH_MAX

    local rounded
    for _ = 1, math.ceil(maxPush / step) + 1 do
        rounded = ADOffsetGeometry.roundPreservedCorners(
            poly, turningRadius, AutoDrive.FIELD_LOOP_MAX_CROSS_TRACK_ERROR, arcSpacing
        )

        local blocked, any = {}, false
        for _, q in ipairs(rounded) do
            if q.isCornerArc and AutoDrive:hasTreeNear(q.x, q.z, treeClearance) then
                -- Which corner built this arc point: the nearest tight vertex of the polygon.
                local best, bestD = nil, math.huge
                for i = 1, n do
                    if poly[i].isCorner then
                        local d = MathUtil.vector2Length(poly[i].x - q.x, poly[i].z - q.z)
                        if d < bestD then best, bestD = i, d end
                    end
                end
                if best ~= nil and (pushedBy[best] or 0) < maxPush then
                    blocked[best] = true
                    any = true
                end
            end
        end
        if not any then
            break
        end

        for i in pairs(blocked) do
            local prev, cur, nxt = poly[((i - 2) % n) + 1], poly[i], poly[(i % n) + 1]
            local ax, az = prev.x - cur.x, prev.z - cur.z
            local bx, bz = nxt.x - cur.x, nxt.z - cur.z
            local la, lb = MathUtil.vector2Length(ax, az), MathUtil.vector2Length(bx, bz)
            if la > 1e-6 and lb > 1e-6 then
                local dx, dz = ax / la + bx / lb, az / la + bz / lb
                local dl = MathUtil.vector2Length(dx, dz)
                if dl > 1e-6 then
                    -- The sum of the unit vectors to both neighbours points into the polygon at a
                    -- convex corner and out of it at a reflex one; "into the field" is wanted.
                    local cross = (cur.x - prev.x) * (nxt.z - cur.z) - (cur.z - prev.z) * (nxt.x - cur.x)
                    local sign = (cross * areaSign > 0) and 1 or -1
                    cur.x = cur.x + sign * dx / dl * step
                    cur.z = cur.z + sign * dz / dl * step
                    pushedBy[i] = (pushedBy[i] or 0) + step
                end
            end
        end
    end
    return poly, rounded
end

--- Two waypoints joined, in either direction.
local function waypointsLinked(wayPoints, a, b)
    local wa = wayPoints[a]
    if wa == nil or wayPoints[b] == nil then
        return false
    end
    for _, id in ipairs(wa.out or {}) do
        if id == b then return true end
    end
    for _, id in ipairs(wa.incoming or {}) do
        if id == b then return true end
    end
    return false
end

--- True when the ring of waypoints first..last runs AROUND the field(s) being looped now: nearly all of
--- their outline points lie inside it. That is an earlier loop of this very field (a test loop not yet
--- undone, say), not a neighbour, and treating it as one would collapse the new loop's margin to nothing
--- every time the same field is looped again - larger margins first, since they sit closest to it.
function AutoDrive.fieldLoopEnclosesRegions(wayPoints, first, last, regions)
    if regions == nil or #regions == 0 then
        return false
    end
    local ring = {}
    for id = first, last do
        local wp = wayPoints[id]
        if wp == nil then return false end
        ring[#ring + 1] = { x = wp.x, z = wp.z }
    end
    -- Sampled along the whole outline (every few metres), not at its corner points: a loop with a small
    -- margin rounds its corners inside the field's own corner points, so those can lie outside a loop
    -- that very much runs round the field.
    local total, inside = 0, 0
    for _, region in ipairs(regions) do
        local n = #region
        for i = 1, n do
            local a, b = region[i], region[(i % n) + 1]
            local len = MathUtil.vector2Length(b.x - a.x, b.z - a.z)
            local steps = math.max(1, math.ceil(len / 4))
            for k = 0, steps - 1 do
                local t = k / steps
                total = total + 1
                if pointInPolygon(a.x + (b.x - a.x) * t, a.z + (b.z - a.z) * t, ring) then inside = inside + 1 end
            end
        end
    end
    return total > 0 and inside >= total * 0.85
end

--- Every link of every FIELD LOOP in the network near a box. A loop laid by this generator is a run of
--- consecutively numbered waypoints, each linked to the next, with the last linked back to the first -
--- and that stays true when the player has since joined it to a road (extra links hanging off a loop
--- change nothing about the run), which is why this looks at the numbering and not at how many links
--- each point has. A road that is a plain chain, or a junction, never closes back on itself, so it is
--- left out and a loop that merely crosses a road is never held back by it. Returns a list of
--- {ax, az, bx, bz}. A loop the player has edited so its numbers are no longer one closed run is not
--- seen - the margin then simply stays as asked.
function AutoDrive:findFieldLoopSegments(minX, maxX, minZ, maxZ, enclosedRegions)
    local segs = {}
    local okAll, wayPoints = pcall(function() return ADGraphManager:getWayPoints() end)
    if not okAll or wayPoints == nil then
        return segs
    end
    local MAX_RUN = 20000
    local MIN_RUN = 8
    local done = {}
    for startId, wp in pairs(wayPoints) do
        if not done[startId] and wp.x >= minX and wp.x <= maxX and wp.z >= minZ and wp.z <= maxZ then
            local first = startId
            local back = 0
            while back < MAX_RUN and waypointsLinked(wayPoints, first - 1, first) do
                first = first - 1
                back = back + 1
            end
            local last = startId
            while last - first < MAX_RUN and waypointsLinked(wayPoints, last, last + 1) do
                last = last + 1
            end
            for id = first, last do done[id] = true end
            if last - first + 1 >= MIN_RUN and last - first < MAX_RUN and waypointsLinked(wayPoints, last, first)
                and not AutoDrive.fieldLoopEnclosesRegions(wayPoints, first, last, enclosedRegions) then
                for id = first, last do
                    local a = wayPoints[id]
                    local b = wayPoints[id == last and first or id + 1]
                    segs[#segs + 1] = { ax = a.x, az = a.z, bx = b.x, bz = b.z }
                end
            end
        end
    end
    return segs
end

local function pointToSegmentDistance(px, pz, ax, az, bx, bz)
    local dx, dz = bx - ax, bz - az
    local len2 = dx * dx + dz * dz
    local t = len2 > 1e-12 and math.max(0, math.min(1, ((px - ax) * dx + (pz - az) * dz) / len2)) or 0
    return MathUtil.vector2Length(px - (ax + t * dx), pz - (az + t * dz))
end

--- True when any part of the polygon runs within `clear` metres of any of the segments. Sampled every
--- metre along each edge: an edge that crosses a segment has a sample within half a metre of the
--- crossing, so with clear >= 0.5 a crossing can never slip between samples.
local function polygonNearSegments(poly, segs, clear)
    local n = #poly
    for i = 1, n do
        local a, b = poly[i], poly[(i % n) + 1]
        local len = MathUtil.vector2Length(b.x - a.x, b.z - a.z)
        local steps = math.max(1, math.ceil(len))
        for k = 0, steps do
            local t = k / steps
            local x, z = a.x + (b.x - a.x) * t, a.z + (b.z - a.z) * t
            for _, sg in ipairs(segs) do
                if x > math.min(sg.ax, sg.bx) - clear and x < math.max(sg.ax, sg.bx) + clear
                    and z > math.min(sg.az, sg.bz) - clear and z < math.max(sg.az, sg.bz) + clear
                    and pointToSegmentDistance(x, z, sg.ax, sg.az, sg.bx, sg.bz) < clear then
                    return true
                end
            end
        end
    end
    return false
end

--- Every fence section near a box, as {ax, az, bx, bz}. The game keeps each placed fence's sections on the
--- placeable (spec_fence.segments), every one a table with its two ends as x1, z1, x2, z2 and, for a
--- gate, a gateIndex - a closed gate is as much a wall as the rest. Read straight from there, so it
--- gives the fence LINE and not just the few spots an overlap test happened to touch, and it needs no
--- physics. (An older fence class names the ends startPosX / endPosX; both spellings are accepted.)
--- Returns an empty list wherever the game has none. The second result is a small count table for the log.
function AutoDrive:findFenceSegments(minX, maxX, minZ, maxZ)
    local segs = {}
    local counts = { placeables = 0, fences = 0, sections = 0, gates = 0, looked = {} }
    local okList, placeables = pcall(function() return g_currentMission.placeableSystem.placeables end)
    if not okList or placeables == nil then
        return segs, counts
    end
    for _, placeable in ipairs(placeables) do
        counts.placeables = counts.placeables + 1
        -- A fence is a spec_ table that holds a list of sections. The game's current fences (the
        -- "newFence" placeable type, which the barbed wire fence mod and the map's fences are) keep it at
        -- spec_newFence.fence.segments, each section with startPosX / startPosZ / endPosX / endPosZ (a
        -- gate has an animatedObject); the older fence type keeps spec_fence.segments with x1 / z1 / x2 / z2
        -- and a gateIndex. Looking at every spec_ table for either shape means a changed name does not
        -- blind it.
        local found = false
        for key, spec in pairs(placeable) do
            local list = nil
            if type(key) == "string" and key:sub(1, 5) == "spec_" and type(spec) == "table" then
                if type(spec.segments) == "table" then
                    list = spec.segments
                elseif type(spec.fence) == "table" and type(spec.fence.segments) == "table" then
                    list = spec.fence.segments
                end
            end
            if list ~= nil then
                local hadSection = false
                for _, sg in pairs(list) do
                    if type(sg) == "table" then
                        local ax, az = sg.x1 or sg.startPosX, sg.z1 or sg.startPosZ
                        local bx, bz = sg.x2 or sg.endPosX, sg.z2 or sg.endPosZ
                        if ax ~= nil and az ~= nil and bx ~= nil and bz ~= nil then
                            hadSection = true
                            counts.sections = counts.sections + 1
                            if sg.gateIndex ~= nil or sg.animatedObject ~= nil then counts.gates = counts.gates + 1 end
                            if math.max(ax, bx) >= minX and math.min(ax, bx) <= maxX
                                and math.max(az, bz) >= minZ and math.min(az, bz) <= maxZ then
                                segs[#segs + 1] = { ax = ax, az = az, bx = bx, bz = bz }
                            end
                        end
                    end
                end
                if hadSection then found = true end
            end
        end
        if found then
            counts.fences = counts.fences + 1
        else
            -- Not recognised as a fence: if its file name still says fence, keep what it IS so the log can
            -- show how the game labels it (at most three, for the log).
            local name = tostring(placeable.configFileName or "")
            if name:lower():find("fence", 1, true) ~= nil and #counts.looked < 3 then
                local keys = {}
                for key, value in pairs(placeable) do
                    if type(key) == "string" and key:sub(1, 5) == "spec_" then
                        keys[#keys + 1] = key .. (type(value) == "table" and "{" .. (value.segments ~= nil and "segments" or "") .. "}" or "")
                    end
                end
                table.sort(keys)
                counts.looked[#counts.looked + 1] = string.format("%s type=%s specs=[%s]", name, tostring(placeable.typeName), table.concat(keys, ", "))
            end
        end
    end
    return segs, counts
end

--- True when the edge a->b, shifted `m` metres outward, keeps at least `clear` from every segment AND stays
--- on the FIELD side of every segment that runs along it. Distance alone is not enough: a fence standing a
--- metre inside the field's outline is "far" from a loop running outside it, but then the fence is between
--- the loop and the field. "Along it" means roughly parallel (cos >= 0.7) with the sample falling within the
--- fence section; the field side is the side a point 10 m inside the field from the edge is on.
--- How far from a fence section a loop point has to stay for the game's obstacle test not to see it. That
--- test is a SQUARE box, `clear` metres either way, so a section running at an angle is reached from further
--- away than `clear` (at 45 degrees, by up to 1.41 times as much): half-extent x (|nx| + |nz|) for the
--- section's unit normal, plus a little for the thickness of the wire and the collision posts.
local FENCE_THICKNESS = 0.3
local function fenceNeed(sg, clear)
    local need = sg.need
    if need == nil or sg.needFor ~= clear then
        local sx, sz = sg.bx - sg.ax, sg.bz - sg.az
        local sl = MathUtil.vector2Length(sx, sz)
        if sl < 1e-6 then
            need = clear + FENCE_THICKNESS
        else
            need = clear * (math.abs(sz) + math.abs(sx)) / sl + FENCE_THICKNESS
        end
        sg.need, sg.needFor = need, clear
    end
    return need
end

local function edgeClearOfSegments(a, b, ox, oz, m, clear, segs)
    local dx, dz = b.x - a.x, b.z - a.z
    local len = MathUtil.vector2Length(dx, dz)
    local ux, uz = len > 1e-9 and dx / len or 1, len > 1e-9 and dz / len or 0
    -- An edge shifted INWARD is cut back at both ends by the corners it meets (by about the shift, at a
    -- right angle); the loop never runs along those ends, so they are not sampled.
    local trim = (m < 0 and len > 2 * (-m) + 1) and (-m) or 0
    local from, to = trim, len - trim
    local steps = math.max(1, math.ceil(to - from))
    for k = 0, steps do
        local t = (from + (to - from) * k / steps) / math.max(len, 1e-9)
        local bx0, bz0 = a.x + dx * t, a.z + dz * t -- on the field edge itself
        local x, z = bx0 + ox * m, bz0 + oz * m      -- where the loop would run
        local rx, rz = bx0 - ox * 10, bz0 - oz * 10  -- well inside the field
        for _, sg in ipairs(segs) do
            local need = fenceNeed(sg, clear)
            if x > math.min(sg.ax, sg.bx) - need and x < math.max(sg.ax, sg.bx) + need
                and z > math.min(sg.az, sg.bz) - need and z < math.max(sg.az, sg.bz) + need then
                if pointToSegmentDistance(x, z, sg.ax, sg.az, sg.bx, sg.bz) < need then
                    return false
                end
            end
            -- field side: only for a fence along this edge, with the sample alongside it
            local sx, sz = sg.bx - sg.ax, sg.bz - sg.az
            local sl = MathUtil.vector2Length(sx, sz)
            if sl > 1e-6 and math.abs((sx * ux + sz * uz) / sl) >= 0.7 then
                local along = ((x - sg.ax) * sx + (z - sg.az) * sz) / (sl * sl)
                if along >= 0 and along <= 1
                    and pointToSegmentDistance(bx0, bz0, sg.ax, sg.az, sg.bx, sg.bz) < 15 then
                    local sideLoop = sx * (z - sg.az) - sz * (x - sg.ax)
                    local sideField = sx * (rz - sg.az) - sz * (rx - sg.ax)
                    if sideLoop * sideField < 0 then
                        return false
                    end
                end
            end
        end
    end
    return true
end

--- Each field edge keeps the largest margin that stays `clear` from every fence - down past the field's own
--- outline if need be (a placed fence often stands a metre INSIDE the outline) - so a loop beside a fence
--- sits on the FIELD side of it instead of trying to detour round a fence that runs the whole length of
--- the edge. Returns insets (one per edge, negative = outward, the
--- convention generateOffset takes), how many edges were pulled in, and how many could not be cleared
--- even at the floor (those keep the full margin and are left to the later passes and the log).
local function limitEdgeInsetsByFences(poly, margin, clear, segs)
    local n = #poly
    local ws = ADPolygonUtils.getSignedArea(poly) > 0 and 1 or -1
    local floor = AutoDrive.FIELD_LOOP_EDGE_MARGIN_FLOOR
    local step = AutoDrive.FIELD_LOOP_MARGIN_PULL_STEP
    local insets, changed, blocked = {}, 0, 0
    for i = 1, n do
        local a, b = poly[i], poly[(i % n) + 1]
        local dx, dz = b.x - a.x, b.z - a.z
        local len = MathUtil.vector2Length(dx, dz)
        if len > 1e-6 then
            local ux, uz = dx / len, dz / len
            local ox, oz = uz * ws, -ux * ws -- outward: away from the field interior
            local chosen = nil
            local m = margin
            while true do
                if edgeClearOfSegments(a, b, ox, oz, m, clear, segs) then
                    chosen = m
                    break
                end
                if m <= floor then break end
                m = math.max(floor, m - step)
            end
            if chosen == nil then
                insets[i] = -margin
                blocked = blocked + 1
            else
                insets[i] = -chosen
                if chosen < margin - 1e-6 then changed = changed + 1 end
            end
        end
    end
    return insets, changed, blocked
end

function AutoDrive:buildFieldLoopRing(rawPoints, marginDistance, treeClearance, turningRadius, otherLoopSegments, fenceSegments)
    turningRadius = math.max(turningRadius, AutoDrive.FIELD_LOOP_MIN_CORNER_RADIUS)
    local requestedMargin = marginDistance
    local points = ADPolygonUtils.stripDuplicateClosingVertex(rawPoints)
    -- Light cleanup only - the offset/corner pipeline below classifies real corners by actual
    -- turning-radius cross-track error rather than by pre-removing detail, so this just drops
    -- exact-duplicate/degenerate points instead of the old pipeline's aggressive tolerance that
    -- was compensating for a much cruder single-shot offset.
    local simplified = ADPolygonUtils.simplifyClosedPolygonRDP(points, 0.3)

    -- Offset OUTWARD (away from the field interior) by marginDistance: generateOffset's positive
    -- direction is inward, so outward is the same call with a negated distance.
    -- A fence beside the field shortens the margin of just the edges it runs along (see
    -- limitEdgeInsetsByFences); with no fence nearby this is the plain uniform offset.
    local fenceEdgesPulled, fenceEdgesBlocked = 0, 0
    local function offsetFor(m)
        local insets = nil
        if fenceSegments ~= nil and #fenceSegments > 0 then
            local ins, changed, blocked = limitEdgeInsetsByFences(simplified, m, treeClearance, fenceSegments)
            fenceEdgesPulled, fenceEdgesBlocked = changed, blocked
            if changed > 0 then insets = ins end
        end
        return ADOffsetGeometry.generateOffset(
            simplified, -m, turningRadius, AutoDrive.FIELD_LOOP_MAX_CROSS_TRACK_ERROR, insets
        )
    end
    local offset, offsetErr = offsetFor(marginDistance)
    if offset == nil then
        return nil, nil, nil, offsetErr
    end

    -- Two fields with a strip between them narrower than twice the margin make loops that overlap
    -- and cross (issue 15), and crossing at under 80 degrees lets a driver hop from one to the other.
    -- So when this loop would run within a metre of another standalone loop, the margin is pulled in
    -- - only as far as needed, never past the field's own edge - and the log says so. Done on the
    -- plain offset polygon, before any tree work, so it costs nothing.
    if otherLoopSegments ~= nil and #otherLoopSegments > 0 and marginDistance > 0
        and polygonNearSegments(offset, otherLoopSegments, AutoDrive.FIELD_LOOP_OTHER_LOOP_CLEARANCE) then
        local m = marginDistance
        local best = nil
        while m > 0 do
            m = math.max(0, m - AutoDrive.FIELD_LOOP_MARGIN_PULL_STEP)
            local candidate = offsetFor(m)
            if candidate ~= nil then
                best = { margin = m, offset = candidate }
                if not polygonNearSegments(candidate, otherLoopSegments, AutoDrive.FIELD_LOOP_OTHER_LOOP_CLEARANCE) then
                    break
                end
            end
        end
        if best ~= nil then
            marginDistance, offset = best.margin, best.offset
        end
    end
    -- Still within a metre of another loop even at the field's own edge: the strip is narrower than the
    -- other loop's margin took up. Said in the log rather than hidden.
    local crowded = otherLoopSegments ~= nil and #otherLoopSegments > 0
        and polygonNearSegments(offset, otherLoopSegments, AutoDrive.FIELD_LOOP_OTHER_LOOP_CLEARANCE)

    -- Sample corner arcs at a constant ANGULAR resolution rather than a constant distance: what a
    -- driver feels is the heading change per waypoint, and a fixed spacing delivers wildly
    -- different angles depending on the radius (0.75m is 3.6deg at r=12 but 14deg at r=3).
    local arcSpacing = math.max(0.3, turningRadius * math.rad(AutoDrive.FIELD_LOOP_MAX_WAYPOINT_TURN_DEG))

    local rounded
    if ADFlyoverSettings.get("fieldLoopAvoidObstacles") then
        offset, rounded = pushBlockedCornersIn(offset, treeClearance, turningRadius, arcSpacing)
    else
        rounded = ADOffsetGeometry.roundPreservedCorners(
            offset, turningRadius, AutoDrive.FIELD_LOOP_MAX_CROSS_TRACK_ERROR, arcSpacing
        )
    end

    -- Round off the medium bends the corner pass deliberately leaves alone. Adds points, which
    -- thinToAdaptiveSpacing below claws back wherever they turn out not to be earning their keep.
    local splined = ADOffsetGeometry.smoothSpline(
        rounded, AutoDrive.FIELD_LOOP_SPLINE_ORDER, AutoDrive.FIELD_LOOP_SPLINE_MIN_ANGLE_DEG
    )

    -- thinToAdaptiveSpacing can only remove overly-dense points, never add to a sparse long
    -- straight run - densify first so it has something to work with.
    local densified = ADOffsetGeometry.densifyLongEdges(splined, AutoDrive.FIELD_LOOP_ADAPTIVE_MAX_SPACING)

    local ringXZ = ADOffsetGeometry.thinToAdaptiveSpacing(
        densified,
        AutoDrive.FIELD_LOOP_ADAPTIVE_MIN_SPACING,
        AutoDrive.FIELD_LOOP_ADAPTIVE_MAX_SPACING,
        AutoDrive.FIELD_LOOP_ADAPTIVE_TOLERANCE,
        AutoDrive.FIELD_LOOP_ADAPTIVE_PROTECT_ANGLE_DEG
    )
    if ringXZ == nil or #ringXZ < 3 then
        return nil, nil, nil, "Offset/rounding pipeline produced a degenerate ring."
    end

    local fieldCentroid = { x = 0, z = 0 }
    for i = 1, #simplified do
        fieldCentroid.x = fieldCentroid.x + simplified[i].x
        fieldCentroid.z = fieldCentroid.z + simplified[i].z
    end
    fieldCentroid.x = fieldCentroid.x / #simplified
    fieldCentroid.z = fieldCentroid.z / #simplified

    -- Enforces the floor requested live (2026-09-22) after two very close, sharply-angled points
    -- survived at a tight corner: thinToAdaptiveSpacing's minimum spacing deliberately exempts
    -- anything it classifies as a corner, precisely so rounding a corner is not flattened - which
    -- also means it is the wrong place to enforce an absolute floor. ensureMinimumEdgeLength makes
    -- no such exemption, corners included, which is exactly what is wanted here. This also has to
    -- run BEFORE tree avoidance regardless: dropping a point merges two segments into one longer
    -- chord, and a chord can cut a corner the detour had already verified as clear.
    local minPointSpacing = ADFlyoverSettings.get("fieldLoopMinPointSpacing") or 1.0
    local tidiedXZ = ADOffsetGeometry.ensureMinimumEdgeLength(ringXZ, minPointSpacing)

    -- Tree avoidance runs last, on the finished (offset, corner-rounded, adaptively spaced)
    -- boundary, so it only ever perturbs an otherwise-good path. Add resolution around trees
    -- first, so the detour has points to be shaped from and no tree can hide between two samples.
    --
    -- COMPANION EDIT: gated by "avoid obstacles" - off skips this whole pass (densify, detour, and
    -- the detour-aware relaxation below) and takes the offset boundary as-is, for a field where the
    -- obstacle check keeps flagging something that isn't really in the way.
    local avoidObstacles = ADFlyoverSettings.get("fieldLoopAvoidObstacles")
    local finalXZ, treeStats, smoothMoveCount
    if avoidObstacles then
        local nearTreeRing = densifyNearTrees(tidiedXZ, treeClearance, AutoDrive.FIELD_LOOP_TREE_DENSIFY_SPACING)

        local detouredXZ
        detouredXZ, treeStats = detourAroundTrees(nearTreeRing, fieldCentroid, treeClearance, turningRadius)

        if #detouredXZ < 3 then
            return nil, nil, nil, "Too many points along this loop could not clear obstacles - fewer than 3 points remained. Try a different obstacle clearance or a different margin."
        end

        -- The raised-cosine detour is already within turningRadius by construction, so this is a
        -- safety net for anything the max-of-overlapping-detours combination left too tight - and
        -- it still refuses any relaxation that would re-enter a tree's clearance radius.
        finalXZ, smoothMoveCount = ADOffsetGeometry.smoothTightVertices(
            detouredXZ,
            turningRadius,
            AutoDrive.FIELD_LOOP_MAX_CROSS_TRACK_ERROR,
            AutoDrive.FIELD_LOOP_TREE_SMOOTH_ITERATIONS,
            -- Check the spans this move creates, not just the point: relaxing a point on a detour
            -- can leave it clear while the chord to its neighbour clips the tree the detour exists
            -- to avoid.
            function(x, z, prev, nxt)
                if AutoDrive:hasTreeNear(x, z, treeClearance) then
                    return false
                end
                if prev and AutoDrive:hasTreeNear((x + prev.x) / 2, (z + prev.z) / 2, treeClearance) then
                    return false
                end
                if nxt and AutoDrive:hasTreeNear((x + nxt.x) / 2, (z + nxt.z) / 2, treeClearance) then
                    return false
                end
                return true
            end
        )
    else
        finalXZ = tidiedXZ
        treeStats = { nudged = 0, stuck = 0, detours = 0 }
        smoothMoveCount = 0
    end

    local ring = {}
    for i = 1, #finalXZ do
        local p = finalXZ[i]
        ring[i] = { x = p.x, y = AutoDrive:getTerrainHeightAtWorldPos(p.x, p.z), z = p.z }
    end

    local perimeter = 0
    for i = 1, #ring do
        local a, b = ring[i], ring[(i % #ring) + 1]
        perimeter = perimeter + MathUtil.vector2Length(b.x - a.x, b.z - a.z)
    end

    return ring, perimeter, {
        nudged = treeStats.nudged,
        stuck = treeStats.stuck,
        detours = treeStats.detours,
        smoothMoves = smoothMoveCount,
        rawVertexCount = #points,
        simplifiedVertexCount = #simplified,
        marginUsed = marginDistance,
        marginRequested = requestedMargin,
        crowded = crowded,
        fenceEdgesPulled = fenceEdgesPulled,
        fenceEdgesBlocked = fenceEdgesBlocked
    }, nil
end

--- True when the ring, as ordered, runs clockwise in world (x, z). Shoelace sign - same convention
--- OffsetGeometry uses (positive area = counter-clockwise) - so "clockwise" means the same thing
--- here as it does to the offset math, whichever way buildFieldLoopRing happened to emit the ring.
local function ringIsClockwise(ring)
    local area = 0
    local n = #ring
    for i = 1, n do
        local a, b = ring[i], ring[(i % n) + 1]
        area = area + (a.x * b.z - b.x * a.z)
    end
    return area < 0
end

--- flags: AutoDrive.FLAG_SUBPRIO (secondary, the old always-on default) or AutoDrive.FLAG_NONE
--- (primary). Defaults to SUBPRIO so a caller that does not pass one - the console command - keeps
--- behaving exactly as before this was configurable.
---
--- direction: "cw", "ccw", or "twoway" (default, also the old always-on behaviour). One-way costs
--- nothing extra to lay - it is the same ring, just walked one direction and connected with
--- dual=false instead of true - so "cw"/"ccw" only decide which way the ring is ordered before
--- that, checked geometrically rather than trusting whatever winding the generator happened to
--- produce.
function AutoDrive:createFieldLoopGraph(ring, flags, direction)
    flags = flags or AutoDrive.FLAG_SUBPRIO
    direction = direction or "twoway"
    local dual = direction ~= "cw" and direction ~= "ccw"

    if not dual and ringIsClockwise(ring) ~= (direction == "cw") then
        local reversed = {}
        for i = #ring, 1, -1 do
            reversed[#reversed + 1] = ring[i]
        end
        ring = reversed
    end

    local baseCount = ADGraphManager:getWayPointsCount()
    local ringCount = #ring

    -- Every ring segment dual/bidirectional (two-way) or one-way in the order set above, flagged
    -- SUBPRIO or not per the caller. Standalone - not connected to any other node.
    for i = 1, ringCount do
        local p = ring[i]
        local previousId = 0
        if i > 1 then
            previousId = baseCount + i - 1
        end
        ADGraphManager:recordWayPoint(p.x, p.y, p.z, i > 1, dual, false, previousId, flags, false)
    end

    local firstRingId = baseCount + 1
    local lastRingId = baseCount + ringCount

    -- Close the loop: last ring node connects back to the first, same dual-ness as the rest of it.
    ADGraphManager:toggleConnectionBetween(
        ADGraphManager:getWayPointById(lastRingId),
        ADGraphManager:getWayPointById(firstRingId),
        false, dual, false
    )

    ADGraphManager:prepareWayPoints()
    ADGraphManager:getNetworkErrors()

    local networkErrorCount = 0
    for i = firstRingId, lastRingId do
        local wp = ADGraphManager:getWayPointById(i)
        if wp ~= nil and wp.errorMapping ~= nil and next(wp.errorMapping) ~= nil then
            networkErrorCount = networkErrorCount + 1
        end
    end

    return {
        ringCount = ringCount,
        idRange = { firstRingId, lastRingId },
        networkErrorCount = networkErrorCount
    }
end

function AutoDrive:generateFieldLoop(marginArg, treeClearanceArg, turningRadiusArg)
    if g_server == nil then
        Logging.error("[AD] ADGenerateFieldLoop must be run on the server (host in singleplayer, or on a listen server).")
        return
    end

    local vehicle = AutoDrive.getControlledVehicle()
    if vehicle == nil or vehicle.ad == nil or vehicle.ad.stateModule == nil then
        Logging.error("[AD] ADGenerateFieldLoop needs to be called while entered an AD vehicle, or use the field loop tool in the flyover editor, which works from the cursor instead.")
        return
    end

    -- Console args override the GUI settings (AutoDrive - Settings - Global) for quick testing;
    -- omit them to use whatever is configured there.
    local marginDistance = tonumber(marginArg) or ADFlyoverSettings.get("fieldLoopMargin")
    local treeClearance = tonumber(treeClearanceArg) or ADFlyoverSettings.get("fieldLoopTreeClearance")
    local turningRadius = tonumber(turningRadiusArg) or ADFlyoverSettings.get("fieldLoopTurningRadius")

    local x, _, z = getWorldTranslation(vehicle.rootNode)
    AutoDrive:generateFieldLoopAt(x, z, marginDistance, treeClearance, turningRadius, "ADGenerateFieldLoop")
end

--- Closest pair of points between two FINISHED rings, by index, REJECTING any pair whose bridge
--- would cut across either ring's own interior rather than crossing the clear gap between them -
--- reported live (2026-09-22): the plain closest-pair version picked a corner of one ring that
--- was geometrically nearer to a far point of the other than to the ring actually facing it,
--- landing a waypoint in the middle of the wrong field. Concave/irregular shapes (a raw tilled-
--- ground scan is rarely a clean rectangle) make that a real case, not a corner case.
---
--- Sampled rather than exact: three points along each candidate segment (25/50/75%) checked
--- against BOTH rings with pointInPolygon. Exact segment/polygon intersection would catch a
--- graze this can miss, but at ring sizes in the hundreds, testing every candidate exactly is a
--- lot of work for a defect this sampling already prevents in the reported case; falls back to
--- the plain closest pair if literally nothing passes, so this never leaves the two rings
--- unbridged.
local function ringClosestPair(a, b)
    local bestI, bestJ, bestDistSq = nil, nil, math.huge
    local fallbackI, fallbackJ, fallbackDistSq = 1, 1, math.huge
    for i = 1, #a do
        local pa = a[i]
        for j = 1, #b do
            local pb = b[j]
            local dx, dz = pb.x - pa.x, pb.z - pa.z
            local d = dx * dx + dz * dz
            if d < fallbackDistSq then
                fallbackDistSq, fallbackI, fallbackJ = d, i, j
            end
            if d < bestDistSq then
                local clear = true
                for _, t in ipairs({ 0.25, 0.5, 0.75 }) do
                    local mx, mz = pa.x + dx * t, pa.z + dz * t
                    if pointInPolygon(mx, mz, a) or pointInPolygon(mx, mz, b) then
                        clear = false
                        break
                    end
                end
                if clear then
                    bestDistSq, bestI, bestJ = d, i, j
                end
            end
        end
    end
    if bestI == nil then
        return fallbackI, fallbackJ, math.sqrt(fallbackDistSq)
    end
    return bestI, bestJ, math.sqrt(bestDistSq)
end

--- Splice ring b into ring a at their closest pair (ai in a, bj in b), keyhole-style: walk a up to
--- and including ai, jump to b, walk the WHOLE of b starting and ending at bj, then continue a
--- from ai+1 onward. The a[ai]<->b[bj] edge this creates is what createFieldLoopGraph will later
--- connect like any other consecutive pair in the sequence - a real bridge, not a special case -
--- and being the same physical edge whichever direction it is walked, it works for a one-way loop
--- (drive into b, all the way around, out the same point) exactly as it does for two-way.
local function spliceRingAt(a, ai, b, bj)
    local out = {}
    for i = 1, ai do out[#out + 1] = a[i] end
    local n = #b
    for k = 0, n do
        out[#out + 1] = b[((bj - 1 + k) % n) + 1]
    end
    for i = ai + 1, #a do out[#out + 1] = a[i] end
    return out
end

--- Combine however many finished rings into the ONE ring that actually gets placed. Splices the
--- closest-remaining ring into the combined result one at a time (order does not affect the
--- outcome, just which bridge gets drawn where) - by the time this runs, every ring has already
--- gone through the full offset/corner-round/tree-avoid pipeline on its own, so nothing here
--- touches boundary geometry, only which order the already-finished points are walked in.
function AutoDrive:spliceFieldLoopRings(rings)
    if rings == nil or #rings == 0 then
        return nil
    end
    local combined = rings[1]
    for k = 2, #rings do
        local ai, bj = ringClosestPair(combined, rings[k])
        combined = spliceRingAt(combined, ai, rings[k], bj)
    end
    return combined
end

--- Generate a loop around the field at a world position. Shared by the console command and the
--- flyover tool so the two cannot drift apart; the caller decides where the position comes from
--- and what to log, this does the work.
---
--- flags/direction are forwarded to createFieldLoopGraph verbatim (nil for either keeps that
--- function's own defaults - secondary, two-way - so the console command, which has no editor
--- panel to read them from, is unaffected).
---
--- A field a lane splits into disconnected tilled patches auto-discovers every patch it can reach
--- (AutoDrive:findConnectedFieldRegions), finishes EACH one through the normal offset/corner-round/
--- tree-avoid pipeline on its own, then splices the finished rings into the one combined ring that
--- actually gets placed (AutoDrive:spliceFieldLoopRings) - one click, one course, no follow-up
--- clicks and no separate loops left for the player to connect by hand.
---
--- Returns true on success, false on failure. Everything interesting is already logged here.
function AutoDrive:generateFieldLoopAt(x, z, marginDistance, treeClearance, turningRadius, source, flags, direction)
    -- Clamped here, not just inside buildFieldLoopRing, so the summary log line below reports the
    -- radius actually used rather than a setting that got silently overridden.
    turningRadius = math.max(turningRadius, AutoDrive.FIELD_LOOP_MIN_CORNER_RADIUS)

    local rawPoints, fieldLabel, fieldErr = AutoDrive:getFieldPolygonAtPosition(x, z)
    if rawPoints == nil then
        Logging.error("[AD] %s: %s", source, tostring(fieldErr))
        return false
    end

    local rawRegions = AutoDrive:findConnectedFieldRegions(x, z, rawPoints)

    -- Loops already in the network near this field, so a new loop can keep clear of them (a narrow
    -- strip between two fields otherwise gets two loops that overlap and cross - issue 15).
    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    for _, region in ipairs(rawRegions) do
        for _, p in ipairs(region) do
            minX, maxX = math.min(minX, p.x), math.max(maxX, p.x)
            minZ, maxZ = math.min(minZ, p.z), math.max(maxZ, p.z)
        end
    end
    local reach = math.max(marginDistance, 0) + AutoDrive.FIELD_LOOP_OTHER_LOOP_CLEARANCE + 15
    local otherLoops = AutoDrive:findFieldLoopSegments(minX - reach, maxX + reach, minZ - reach, maxZ + reach, rawRegions)
    local fenceReach = math.max(marginDistance, 0) + treeClearance + 10
    local fences, fenceCounts = AutoDrive:findFenceSegments(minX - fenceReach, maxX + fenceReach, minZ - fenceReach, maxZ + fenceReach)
    ADFlyoverSettings.debugLog("[FlyoverEditor]: field loop sees %d fence section(s) near this field (the game has %d section(s), %d gate(s), on %d fence(s), of %d placeable(s)) and %d other loop link(s).",
        #fences, fenceCounts.sections, fenceCounts.gates, fenceCounts.fences, fenceCounts.placeables, #otherLoops)
    for _, line in ipairs(fenceCounts.looked or {}) do
        ADFlyoverSettings.debugLog("[FlyoverEditor]: field loop - a placeable named like a fence that was not read: %s", line)
    end

    local rings, perimeter, treeStats = {}, 0, { nudged = 0, stuck = 0, detours = 0, smoothMoves = 0, rawVertexCount = 0, simplifiedVertexCount = 0 }
    local lastRingErr = nil
    local smallestMargin, anyCrowded = nil, false
    local fenceEdgesPulled, fenceEdgesBlocked = 0, 0
    for _, region in ipairs(rawRegions) do
        local ring, ringPerimeter, ringTreeStats, ringErr = AutoDrive:buildFieldLoopRing(region, marginDistance, treeClearance, turningRadius, otherLoops, fences)
        if ring ~= nil and ringTreeStats ~= nil and ringTreeStats.marginUsed ~= nil
            and (smallestMargin == nil or ringTreeStats.marginUsed < smallestMargin) then
            smallestMargin = ringTreeStats.marginUsed
        end
        if ring ~= nil and ringTreeStats ~= nil and ringTreeStats.crowded then
            anyCrowded = true
        end
        if ring ~= nil and ringTreeStats ~= nil then
            fenceEdgesPulled = fenceEdgesPulled + (ringTreeStats.fenceEdgesPulled or 0)
            fenceEdgesBlocked = fenceEdgesBlocked + (ringTreeStats.fenceEdgesBlocked or 0)
        end
        if ring == nil then
            lastRingErr = ringErr
            Logging.warning("[AD] %s: dropped one of %d discovered region(s) - %s", source, #rawRegions, tostring(ringErr))
        else
            table.insert(rings, ring)
            perimeter = perimeter + ringPerimeter
            for _, key in ipairs({ "nudged", "stuck", "detours", "smoothMoves", "rawVertexCount", "simplifiedVertexCount" }) do
                treeStats[key] = treeStats[key] + (ringTreeStats[key] or 0)
            end
        end
    end

    if smallestMargin ~= nil and smallestMargin < marginDistance - 1e-6 then
        Logging.info("[AD] %s: margin pulled in from %.2fm to %.2fm to keep clear of another loop beside this field.",
            source, marginDistance, smallestMargin)
    end

    if #fences > 0 and (fenceEdgesPulled > 0 or fenceEdgesBlocked > 0) then
        Logging.info("[AD] %s: %d field edge(s) pulled in to stay on the field side of a fence (%d fence section(s) nearby)%s.",
            source, fenceEdgesPulled, #fences,
            fenceEdgesBlocked > 0 and string.format(", %d edge(s) could not be cleared even at the field edge", fenceEdgesBlocked) or "")
    end

    if anyCrowded then
        Logging.warning("[AD] %s: this loop still runs within %.0fm of another loop - the strip between the fields is narrower than the other loop's margin. Lower that loop's margin, or move one of them by hand.",
            source, AutoDrive.FIELD_LOOP_OTHER_LOOP_CLEARANCE)
    end

    if #rings == 0 then
        Logging.error("[AD] %s: %s", source, tostring(lastRingErr))
        return false
    end

    local combinedRing = AutoDrive:spliceFieldLoopRings(rings)

    -- Final cleanup on the ring that actually gets placed: a spike or a compressed-and-sharp
    -- outlier here can come from the finished-per-region pipeline just as easily as from a splice
    -- bridge, so this runs whether or not any splicing happened - reported live (2026-09-22) as a
    -- point sticking out at a corner.
    local cleanedRing, spikesRemoved = ADOffsetGeometry.removeSpikes(combinedRing,
        AutoDrive.FIELD_LOOP_MAX_REVERSAL_DEG, AutoDrive.FIELD_LOOP_OUTLIER_ANGLE_DEG, AutoDrive.FIELD_LOOP_OUTLIER_SPACING_RATIO)
    if spikesRemoved > 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: field loop removed %d spike point(s) from the finished ring.", spikesRemoved)
    end

    local summary = AutoDrive:createFieldLoopGraph(cleanedRing, flags, direction)

    local regionNote = #rings > 1 and string.format(", %d region(s) combined", #rings) or ""
    Logging.info(
        "[AD] %s: created %d waypoints (ids %d-%d) around '%s'%s, %s %s, margin=%.2fm treeClearance=%.2fm turningRadius=%.1fm perimeter=%.1fm, boundary %d->%d verts after simplify, %d tree detour(s) displacing %d point(s) (%d unresolved - see warnings above), %d relaxation move(s), %d network error(s).",
        source,
        summary.ringCount,
        summary.idRange[1],
        summary.idRange[2],
        fieldLabel,
        regionNote,
        (flags or AutoDrive.FLAG_SUBPRIO) == AutoDrive.FLAG_SUBPRIO and "secondary" or "primary",
        direction or "twoway",
        marginDistance,
        treeClearance,
        turningRadius,
        perimeter,
        treeStats.rawVertexCount,
        treeStats.simplifiedVertexCount,
        treeStats.detours,
        treeStats.nudged,
        treeStats.stuck,
        treeStats.smoothMoves,
        summary.networkErrorCount
    )
    return true
end

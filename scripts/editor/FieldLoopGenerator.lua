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

--- Find the field boundary under an arbitrary world position.
---
--- Split out from the vehicle version so the flyover editor can generate a loop around whatever
--- field the cursor is over, with no vehicle involved. The vehicle wrapper below is now just a
--- position lookup feeding this.
---
--- COMPANION FIX: tries g_fieldManager:getFieldAtWorldPosition() first. A field the player drew
--- in-game with "Define Field" - a custom field, not one shipped with the map - has no purchasable
--- farmland behind it, so the original farmland->getField() path below never finds it: it asks
--- "what farmland owns this spot", and a custom field is not tied to one. FieldManager answers the
--- geometric question instead ("what field polygon is under this spot"), which is what covers both
--- kinds. Kept as a fallback rather than a replacement in case an older/modified g_fieldManager
--- lacks the method - same pcall-guarded, log-and-continue style as the rest of this file.
function AutoDrive:getFieldPolygonAtPosition(x, z)
    local field = nil

    if g_fieldManager ~= nil then
        local okDirect, directField = pcall(function()
            return g_fieldManager:getFieldAtWorldPosition(x, z)
        end)
        if okDirect then
            field = directField
        end
    end

    if field == nil then
        if g_farmlandManager == nil then
            return nil, nil, "g_farmlandManager is not available."
        end

        local okFarmland, farmland = pcall(function()
            return g_farmlandManager:getFarmlandAtWorldPosition(x, z)
        end)
        if not okFarmland or farmland == nil then
            return nil, nil, string.format("No farmland at x=%.1f z=%.1f.", x, z)
        end

        local okField, farmlandField = pcall(function()
            return farmland:getField()
        end)
        if not okField or farmlandField == nil then
            return nil, nil, string.format("No field at x=%.1f z=%.1f - that farmland has no field on it.", x, z)
        end
        field = farmlandField
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

function AutoDrive:buildFieldLoopRing(rawPoints, marginDistance, treeClearance, turningRadius)
    local points = ADPolygonUtils.stripDuplicateClosingVertex(rawPoints)
    -- Light cleanup only - the offset/corner pipeline below classifies real corners by actual
    -- turning-radius cross-track error rather than by pre-removing detail, so this just drops
    -- exact-duplicate/degenerate points instead of the old pipeline's aggressive tolerance that
    -- was compensating for a much cruder single-shot offset.
    local simplified = ADPolygonUtils.simplifyClosedPolygonRDP(points, 0.3)

    -- Offset OUTWARD (away from the field interior) by marginDistance: generateOffset's positive
    -- direction is inward, so outward is the same call with a negated distance.
    local offset, offsetErr = ADOffsetGeometry.generateOffset(
        simplified, -marginDistance, turningRadius, AutoDrive.FIELD_LOOP_MAX_CROSS_TRACK_ERROR
    )
    if offset == nil then
        return nil, nil, nil, offsetErr
    end

    -- Sample corner arcs at a constant ANGULAR resolution rather than a constant distance: what a
    -- driver feels is the heading change per waypoint, and a fixed spacing delivers wildly
    -- different angles depending on the radius (0.75m is 3.6deg at r=12 but 14deg at r=3).
    local arcSpacing = math.max(0.3, turningRadius * math.rad(AutoDrive.FIELD_LOOP_MAX_WAYPOINT_TURN_DEG))

    local rounded = ADOffsetGeometry.roundPreservedCorners(
        offset, turningRadius, AutoDrive.FIELD_LOOP_MAX_CROSS_TRACK_ERROR, arcSpacing
    )

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

    -- Drop near-duplicates left at the junctions between the geometry stages. This has to happen
    -- BEFORE tree avoidance: dropping a point merges two segments into one longer chord, and a
    -- chord can cut a corner the detour had already verified as clear.
    local tidiedXZ = ADOffsetGeometry.ensureMinimumEdgeLength(ringXZ, math.min(0.6, arcSpacing * 0.6))

    -- Tree avoidance runs last, on the finished (offset, corner-rounded, adaptively spaced)
    -- boundary, so it only ever perturbs an otherwise-good path. Add resolution around trees
    -- first, so the detour has points to be shaped from and no tree can hide between two samples.
    local nearTreeRing = densifyNearTrees(tidiedXZ, treeClearance, AutoDrive.FIELD_LOOP_TREE_DENSIFY_SPACING)

    local detouredXZ, treeStats = detourAroundTrees(nearTreeRing, fieldCentroid, treeClearance, turningRadius)

    if #detouredXZ < 3 then
        return nil, nil, nil, "Too many points along this loop could not clear trees - fewer than 3 points remained. Try a larger tree clearance or a different margin."
    end

    -- The raised-cosine detour is already within turningRadius by construction, so this is a
    -- safety net for anything the max-of-overlapping-detours combination left too tight - and it
    -- still refuses any relaxation that would re-enter a tree's clearance radius.
    local smoothedXZ, smoothMoveCount = ADOffsetGeometry.smoothTightVertices(
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

    local ring = {}
    for i = 1, #smoothedXZ do
        local p = smoothedXZ[i]
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
        simplifiedVertexCount = #simplified
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

--- Position lookup for a vehicle, kept so the console command reads the same as it always did.
function AutoDrive:getFieldPolygonAtVehicle(vehicle)
    local x, _, z = getWorldTranslation(vehicle.rootNode)
    return AutoDrive:getFieldPolygonAtPosition(x, z)
end

--- Generate a loop around the field at a world position. Shared by the console command and the
--- flyover tool so the two cannot drift apart; the caller decides where the position comes from
--- and what to log, this does the work.
---
--- flags/direction are forwarded to createFieldLoopGraph verbatim (nil for either keeps that
--- function's own defaults - secondary, two-way - so the console command, which has no editor
--- panel to read them from, is unaffected).
---
--- Returns true on success. Everything interesting is already logged here.
function AutoDrive:generateFieldLoopAt(x, z, marginDistance, treeClearance, turningRadius, source, flags, direction)
    local rawPoints, fieldLabel, fieldErr = AutoDrive:getFieldPolygonAtPosition(x, z)
    if rawPoints == nil then
        Logging.error("[AD] %s: %s", source, tostring(fieldErr))
        return false
    end

    local ring, perimeter, treeStats, ringErr = AutoDrive:buildFieldLoopRing(rawPoints, marginDistance, treeClearance, turningRadius)
    if ring == nil then
        Logging.error("[AD] %s: %s", source, tostring(ringErr))
        return false
    end

    local summary = AutoDrive:createFieldLoopGraph(ring, flags, direction)

    Logging.info(
        "[AD] %s: created %d waypoints (ids %d-%d) around '%s', %s %s, margin=%.2fm treeClearance=%.2fm turningRadius=%.1fm perimeter=%.1fm, boundary %d->%d verts after simplify, %d tree detour(s) displacing %d point(s) (%d unresolved - see warnings above), %d relaxation move(s), %d network error(s).",
        source,
        summary.ringCount,
        summary.idRange[1],
        summary.idRange[2],
        fieldLabel,
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

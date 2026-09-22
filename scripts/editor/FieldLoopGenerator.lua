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
--- COMPANION FIX, two Courseplay-only attempts before the base-game farmland fallback, both gated
--- by the same "detect custom field" toggle, both synchronous, both confirmed against Courseplay's
--- own source (scripts/field/CustomField*.lua, FieldScanner.lua, CpFieldUtil.lua) rather than
--- guessed:
---
--- 1. A RECORDED custom field (g_customFieldManager) - cheap and exact, but only ever finds
---    something if the player explicitly recorded one in Courseplay, the rarer case.
--- 2. g_fieldScanner:findContour() - what actually answers "plow the ground between two map
---    fields to connect them": it walks a probe out from (x, z) and traces the LIVE tilled-ground
---    edge (Courseplay's own comment on this: "first ignore field ID as with it we can't handle
---    merged fields"), so a tilled gap joining two map fields is just part of the contour, no
---    saved boundary needed. It is a synchronous walk against the density map, not a vehicle
---    capability - no vehicle, no waiting.
---
--- Both need AutoDrive:resolveCourseplayEnvironment() below: measured live (see the field loop
--- custom-field debug lines from an earlier build) that Courseplay's bare globals read as nil from
--- here even though Courseplay is loaded - same cause Arming.lua documents for AutoDrive, FS25
--- gives every mod its own Lua environment, so a global assigned inside Courseplay's sourced files
--- lives in COURSEPLAY's environment, not the one our own files see by plain name.
---
--- Falls back to the base-game farmland lookup if neither attempt finds anything, Courseplay is
--- not installed, or the toggle is off - a report of this misbehaving on a particular map/save can
--- be isolated by switching it off without a rollback.

--- Resolve Courseplay's shared mod environment, the same way Arming.lua resolves AutoDrive's:
--- find a live Courseplay function by a STRUCTURAL route (so no mod name is involved and a rename
--- does not break this), then getfenv() it. Scans g_vehicleTypeManager for a vehicle type carrying
--- a `cpDetectFieldBoundary` function - present as soon as Courseplay registers its specialization,
--- with no vehicle instance needed. Cached after the first success; a failure is not cached, since
--- Courseplay can still be mid-load the first few times this is asked.
AutoDrive.courseplayEnv = nil

function AutoDrive:resolveCourseplayEnvironment()
    if AutoDrive.courseplayEnv ~= nil then
        return AutoDrive.courseplayEnv
    end
    if g_vehicleTypeManager == nil or g_vehicleTypeManager.types == nil then
        return nil
    end
    for _, typeDef in pairs(g_vehicleTypeManager.types) do
        local fn = typeDef.functions ~= nil and typeDef.functions.cpDetectFieldBoundary or nil
        if type(fn) == "function" then
            local ok, env = pcall(getfenv, fn)
            if ok and type(env) == "table" then
                ADFlyoverSettings.debugLog("[FlyoverEditor]: field loop resolved Courseplay's environment via %s.functions.cpDetectFieldBoundary.",
                    tostring(typeDef.name or typeDef.typeName or "?"))
                AutoDrive.courseplayEnv = env
                return env
            end
        end
    end
    return nil
end

--- Returns points, label, err, cpEnv - cpEnv (nil if not resolved) is handed back so
--- findConnectedFieldRegions below can reuse it without resolving twice.
function AutoDrive:getFieldPolygonAtPosition(x, z)
    if ADFlyoverSettings.get("fieldLoopDetectCustomField") then
        -- PROBE, temporary: FieldBoundaryDetector.lua's own comment calls FieldCourseField/
        -- FieldCourseSettings "the Giants field boundary detection" - base-game classes Courseplay
        -- merely wraps, not something it defines. If that holds, they should be plain globals
        -- reachable from OUR OWN environment with no Courseplay dependency at all, unlike
        -- g_customFieldManager/g_fieldScanner below (which Courseplay's own files DO define, hence
        -- needing environment resolution). One log line settles it instead of guessing again.
        ADFlyoverSettings.debugLog("[FlyoverEditor]: field loop base-game probe: FieldCourseField=%s FieldCourseSettings=%s",
            tostring(type(FieldCourseField)), tostring(type(FieldCourseSettings)))

        local cpEnv = AutoDrive:resolveCourseplayEnvironment()
        if cpEnv == nil then
            ADFlyoverSettings.debugLog("[FlyoverEditor]: field loop could not resolve Courseplay's environment (not loaded, or not resolved yet).")
        else
            local customFieldManager = cpEnv.g_customFieldManager
            if customFieldManager == nil then
                ADFlyoverSettings.debugLog("[FlyoverEditor]: field loop has no g_customFieldManager.")
            else
                local okCustom, customField = pcall(function()
                    return customFieldManager:getCustomField(x, z)
                end)
                if not okCustom then
                    ADFlyoverSettings.debugLog("[FlyoverEditor]: field loop g_customFieldManager:getCustomField errored: %s", tostring(customField))
                elseif customField == nil then
                    ADFlyoverSettings.debugLog("[FlyoverEditor]: field loop no recorded custom field here.")
                else
                    local okVerts, vertices = pcall(function() return customField:getVertices() end)
                    if okVerts and vertices ~= nil and #vertices >= 3 then
                        local points = {}
                        for i = 1, #vertices do
                            points[i] = { x = vertices[i].x, z = vertices[i].z }
                        end
                        local okName, name = pcall(function() return customField:getName() end)
                        ADFlyoverSettings.debugLog("[FlyoverEditor]: field loop found a recorded custom field ('%s').", (okName and name) or "?")
                        return points, (okName and name) or "Custom field", nil, cpEnv
                    end
                end
            end

            local fieldScanner = cpEnv.g_fieldScanner
            if fieldScanner == nil then
                ADFlyoverSettings.debugLog("[FlyoverEditor]: field loop has no g_fieldScanner.")
            else
                local okScan, found, scanned = pcall(function()
                    return fieldScanner:findContour(x, z)
                end)
                if not okScan then
                    ADFlyoverSettings.debugLog("[FlyoverEditor]: field loop g_fieldScanner:findContour errored: %s", tostring(found))
                elseif not found then
                    ADFlyoverSettings.debugLog("[FlyoverEditor]: field loop scanner could not trace a contour here (not on field, or lost).")
                elseif scanned == nil or #scanned < 3 then
                    ADFlyoverSettings.debugLog("[FlyoverEditor]: field loop scanner returned too few points (%s).", tostring(scanned and #scanned or "nil"))
                else
                    local points = {}
                    for i = 1, #scanned do
                        points[i] = { x = scanned[i].x, z = scanned[i].z }
                    end
                    ADFlyoverSettings.debugLog("[FlyoverEditor]: field loop scanned a %d-point tilled-ground contour.", #points)
                    return points, "Scanned field", nil, cpEnv
                end
            end
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

    return points, fieldLabel, nil, nil
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
--- Needs cpEnv (for g_fieldScanner and CpFieldUtil.isOnFieldArea, confirmed against Courseplay's
--- own CpFieldUtil.lua) - without it, or if isOnFieldArea isn't there, this returns just the one
--- region it was given rather than guessing.
---
--- Distance is the ONLY signal this has for "same field, split by a lane" vs. "a genuinely
--- different field that happens to be nearby, across an actual road" - reported live
--- (2026-09-22): the default max gap pulled in an unrelated field across a real road. Field ID
--- cannot tell them apart either: Courseplay's own FieldScanner.lua explains why it ignores field
--- ID while scanning - "with it we can't handle merged fields" - meaning the STATIC id does not
--- update when two map fields get tilled together, so requiring a match would reject the exact
--- case this exists for, not just the unwanted one. fieldLoopMaxGap is genuinely a per-map,
--- per-player tuning knob: set it just above your widest field lane and it should not reach a
--- real road, since roads are typically wider than a field lane.
function AutoDrive:findConnectedFieldRegions(x, z, cpEnv, firstRegion)
    local regions = { firstRegion }

    local fieldUtil = cpEnv ~= nil and cpEnv.CpFieldUtil or nil
    local fieldScanner = cpEnv ~= nil and cpEnv.g_fieldScanner or nil
    if fieldUtil == nil or type(fieldUtil.isOnFieldArea) ~= "function" or fieldScanner == nil then
        return regions
    end

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
                            if not alreadyCovered(px, pz) then
                                local okArea, isField = pcall(function() return fieldUtil.isOnFieldArea(px, pz) end)
                                if okArea and isField then
                                    local okScan, found, scanned = pcall(function() return fieldScanner:findContour(px, pz) end)
                                    if okScan and found and scanned ~= nil and #scanned >= 3 then
                                        local newRegion = {}
                                        for k = 1, #scanned do
                                            newRegion[k] = { x = scanned[k].x, z = scanned[k].z }
                                        end
                                        if not alreadyCovered(newRegion[1].x, newRegion[1].z) then
                                            table.insert(regions, newRegion)
                                            ADFlyoverSettings.debugLog("[FlyoverEditor]: field loop auto-discovered region %d, %.1fm from an existing one.",
                                                #regions, dist)
                                            expanded = true
                                        end
                                    end
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
            return nil, nil, nil, "Too many points along this loop could not clear trees - fewer than 3 points remained. Try a larger tree clearance or a different margin."
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
    local rawPoints, fieldLabel, fieldErr, cpEnv = AutoDrive:getFieldPolygonAtPosition(x, z)
    if rawPoints == nil then
        Logging.error("[AD] %s: %s", source, tostring(fieldErr))
        return false
    end

    local rawRegions = AutoDrive:findConnectedFieldRegions(x, z, cpEnv, rawPoints)

    local rings, perimeter, treeStats = {}, 0, { nudged = 0, stuck = 0, detours = 0, smoothMoves = 0, rawVertexCount = 0, simplifiedVertexCount = 0 }
    local lastRingErr = nil
    for _, region in ipairs(rawRegions) do
        local ring, ringPerimeter, ringTreeStats, ringErr = AutoDrive:buildFieldLoopRing(region, marginDistance, treeClearance, turningRadius)
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

    if #rings == 0 then
        Logging.error("[AD] %s: %s", source, tostring(lastRingErr))
        return false
    end

    local combinedRing = AutoDrive:spliceFieldLoopRings(rings)
    local summary = AutoDrive:createFieldLoopGraph(combinedRing, flags, direction)

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

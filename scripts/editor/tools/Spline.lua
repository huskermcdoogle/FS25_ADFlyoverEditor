-- Part of the flyover editor: the multi-point spline (its own curve, no AutoDrive spline code).
-- Written on the road runs branch inside FlyoverEditor.lua and moved here when it met the module split
-- (release 1.0.3.0). Prelude.lua loads it after the other tools/ files. It uses no file-local helpers.

-- ---------------------------------------------------------------------------------------------
-- Multi-point spline - the spline tool's own curve, with no AutoDrive spline code behind it.
--
-- Click any number of points (on the ground, or on a waypoint to join the road there), drag one
-- to move it, Ctrl-click one to remove it, right-click to lay it. The curve passes through every
-- point (ADSplinePath); the waypoints it lays are evenly spaced along it at the spacing setting.
-- An end clicked on a waypoint joins that waypoint and leaves along its road's heading (the start
-- / end tangent flips turn that heading round); an end on the ground gets a new waypoint. The
-- whole thing is one undo step. The old two-point AutoDrive spline stays behind the "curve by"
-- toggle (splineMode setting).
-- ---------------------------------------------------------------------------------------------

--- True when the spline tool is drawing its own multi-point curve rather than AutoDrive's.
function ADFlyoverEditor:splineIsMultiPoint()
    return ADFlyoverSettings.get("splineMode") ~= "autodrive"
end

function ADFlyoverEditor:toggleSplineMode()
    ADFlyoverSettings.cycle("splineMode", 1)
    -- Each mode keeps its own half-done state; neither means anything to the other.
    self:cancelSplinePreview()
    self:cancelMultiSpline()
    ADFlyoverSettings.debugLog("[FlyoverEditor]: spline curve by %s.", tostring(ADFlyoverSettings.get("splineMode")))
end

function ADFlyoverEditor:cancelMultiSpline()
    if self.splinePoints ~= nil and #self.splinePoints > 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: multi-point spline discarded (%d point(s)).", #self.splinePoints)
    end
    self.splinePoints = {}
    self.splineHoverIdx, self.splinePressIdx, self.splineDragIdx, self.splineGhost = nil, nil, nil, nil
    self.splineCurve, self.splineLaid, self.splineLaidKey, self.splineLength = nil, nil, nil, nil
    self.splineEdit, self.splineEditHoverSeed, self.splineEditHoverPts = nil, nil, nil
    -- a flip belongs to the spline it was set on: the next one starts on auto (2026-10-15 review: a
    -- flip left on a free end - greyed, so not seen - turned the next joined spline)
    self.splineFlipStartTangent, self.splineFlipEndTangent = false, false
end

--- Is a multi-point spline being drawn (at least one point down)?
function ADFlyoverEditor:multiSplinePending()
    return self.splinePoints ~= nil and #self.splinePoints > 0
end

--- The waypoint a snapped spline point sits on, or nil. Checked by position as well as id: an undo
--- or a delete renumbers waypoints while a spline is being drawn, and a stale id must never join
--- the curve onto some other point across the map.
function ADFlyoverEditor:splineSnapNode(p)
    if p == nil or p.wpId == nil then
        return nil
    end
    local wp = ADGraphManager:getWayPointById(p.wpId)
    if wp ~= nil and math.abs(wp.x - p.x) < 0.05 and math.abs(wp.z - p.z) < 0.05 then
        return wp
    end
    for _, w in pairs(ADGraphManager:getWayPoints()) do
        if math.abs(w.x - p.x) < 0.05 and math.abs(w.z - p.z) < 0.05 then
            p.wpId = w.id
            return w
        end
    end
    p.wpId = nil
    return nil
end

--- The road's heading at a waypoint, pointing the way the curve goes on (toward tx, tz), as a unit
--- {x, z}; nil when the waypoint has no road through it. With a road on both sides it is the line
--- through its two neighbours; at a dead end, the line along its one road.
function ADFlyoverEditor:splineRoadHeading(node, tx, tz)
    local seen, sx, sz, count = {}, 0, 0, 0
    for _, listName in ipairs({ "out", "incoming" }) do
        for _, id in pairs(node[listName] or {}) do
            local ownMiddle = self.splineEdit ~= nil and self.splineEdit.interior[id]
            if not seen[id] and not ownMiddle then
                seen[id] = true
                local n = ADGraphManager:getWayPointById(id)
                if n ~= nil then
                    local dx, dz = node.x - n.x, node.z - n.z
                    local len = math.sqrt(dx * dx + dz * dz)
                    if len > 0.01 then
                        -- Every neighbour is folded onto one side, so a road through the node adds up
                        -- instead of cancelling out.
                        dx, dz = dx / len, dz / len
                        if count > 0 and dx * sx + dz * sz < 0 then
                            dx, dz = -dx, -dz
                        end
                        sx, sz, count = sx + dx, sz + dz, count + 1
                    end
                end
            end
        end
    end
    local len = math.sqrt(sx * sx + sz * sz)
    if count == 0 or len < 1e-6 then
        return nil
    end
    sx, sz = sx / len, sz / len
    if sx * (tx - node.x) + sz * (tz - node.z) < 0 then
        sx, sz = -sx, -sz
    end
    return { x = sx, z = sz }
end

--- The two end headings for the current points: a snapped end follows its road (flipped on
--- request), a free end is left to the curve.
function ADFlyoverEditor:splineEndHeadings()
    local pts = self.splinePoints
    local n = #pts
    local startDir, endDir = nil, nil
    local a = self:splineSnapNode(pts[1])
    if a ~= nil then
        startDir = self:splineRoadHeading(a, pts[2].x, pts[2].z)
        if startDir ~= nil and self.splineFlipStartTangent then
            startDir = { x = -startDir.x, z = -startDir.z }
        end
    end
    local b = self:splineSnapNode(pts[n])
    if b ~= nil then
        -- The arrival heading points INTO the end, i.e. away from the point before it.
        local h = self:splineRoadHeading(b, 2 * b.x - pts[n - 1].x, 2 * b.z - pts[n - 1].z)
        if h ~= nil then
            endDir = self.splineFlipEndTangent and { x = -h.x, z = -h.z } or h
        end
    end
    return startDir, endDir
end

--- Which spline point is under the mouse, by screen distance like waypoint picking. nil if none.
function ADFlyoverEditor:splinePointNearCursor()
    local pts = self.splinePoints
    if pts == nil or #pts == 0 or self.cursorX == nil then
        return nil
    end
    local best, bestD = nil, nil
    if project ~= nil and g_lastMousePosX ~= nil and g_lastMousePosY ~= nil then
        bestD = AutoDrive.FLYOVER_PICK_SCREEN_RADIUS * AutoDrive.FLYOVER_PICK_SCREEN_RADIUS
        for i, p in ipairs(pts) do
            local ok, sx, sy, depth = pcall(project, p.x, (p.y or 0) + 0.5, p.z)
            if ok and sx ~= nil and depth ~= nil and depth > 0 then
                local dx, dy = sx - g_lastMousePosX, sy - g_lastMousePosY
                if dx * dx + dy * dy < bestD then
                    best, bestD = i, dx * dx + dy * dy
                end
            end
        end
        return best
    end
    bestD = AutoDrive.FLYOVER_PICK_RADIUS * AutoDrive.FLYOVER_PICK_RADIUS
    for i, p in ipairs(pts) do
        local dx, dz = p.x - self.cursorX, p.z - self.cursorZ
        if dx * dx + dz * dz < bestD then
            best, bestD = i, dx * dx + dz * dz
        end
    end
    return best
end

--- How close (screen units) the mouse must be to a waypoint for a spline end to snap onto it. Well
--- under the general pick radius: snapping is for when you mean that waypoint, and the wide pick
--- radius kept grabbing waypoints the player only wanted to place a point near.
AutoDrive.FLYOVER_SPLINE_SNAP_SCREEN_RADIUS = 0.010
AutoDrive.FLYOVER_SPLINE_SNAP_RADIUS = 1.5

--- The waypoint a spline end would snap onto right now, or nil. Alt held means no snapping.
function ADFlyoverEditor:splineSnapCandidate()
    if self.leftAltHeld or self.hoverId == nil then
        return nil
    end
    local wp = ADGraphManager:getWayPointById(self.hoverId)
    if wp == nil then
        return nil
    end
    if project ~= nil and g_lastMousePosX ~= nil and g_lastMousePosY ~= nil then
        local ok, sx, sy, depth = pcall(project, wp.x, wp.y + 0.5, wp.z)
        if ok and sx ~= nil and depth ~= nil and depth > 0 then
            local dx, dy = sx - g_lastMousePosX, sy - g_lastMousePosY
            local r = AutoDrive.FLYOVER_SPLINE_SNAP_SCREEN_RADIUS
            return (dx * dx + dy * dy <= r * r) and wp or nil
        end
        return nil
    end
    if self.cursorX == nil then
        return nil
    end
    local dx, dz = wp.x - self.cursorX, wp.z - self.cursorZ
    local r = AutoDrive.FLYOVER_SPLINE_SNAP_RADIUS
    return (dx * dx + dz * dz <= r * r) and wp or nil
end

--- Where a point goes for the cursor right now: onto a waypoint right under the mouse when
--- snapping is allowed (only the two ends join the road, so only they snap), else the ground.
function ADFlyoverEditor:splinePointAtCursor(allowSnap)
    local wp = allowSnap and self:splineSnapCandidate() or nil
    if wp ~= nil then
        return { x = wp.x, y = wp.y, z = wp.z, wpId = wp.id }
    end
    if self.cursorX == nil then
        return nil
    end
    local y = self:resolveHeightAt(self.cursorX, self.cursorZ, self.cursorY, self.cursorY)
    return { x = self.cursorX, y = y, z = self.cursorZ }
end

--- Which piece of the curve the mouse is on (close enough to put a point into it), or nil.
--- Measured on screen like waypoint picking, so it works the same zoomed in or out.
function ADFlyoverEditor:splineInsertPiece()
    local curve = self.splineCurve
    if curve == nil or self.splinePoints == nil or #self.splinePoints < 2 or self.cursorX == nil then
        return nil
    end
    local seg, dist, px, pz, py = ADSplinePath.nearestPiece(curve, self.cursorX, self.cursorZ)
    if seg == nil then
        return nil
    end
    if project ~= nil and g_lastMousePosX ~= nil and g_lastMousePosY ~= nil then
        local ok, sx, sy, depth = pcall(project, px, (py or self.cursorY or 0) + 0.6, pz)
        if ok and sx ~= nil and depth ~= nil and depth > 0 then
            local dx, dy = sx - g_lastMousePosX, sy - g_lastMousePosY
            local r = AutoDrive.FLYOVER_PICK_SCREEN_RADIUS
            return (dx * dx + dy * dy <= r * r) and seg or nil
        end
        return nil
    end
    return dist <= AutoDrive.FLYOVER_PICK_RADIUS and seg or nil
end

--- Put a point in at index `at` (default: on the end).
function ADFlyoverEditor:multiSplineAdd(p, at)
    if self.splinePoints == nil then
        self.splinePoints = {}
    end
    local pts = self.splinePoints
    at = at or (#pts + 1)
    local near = pts[at - 1]
    if near ~= nil and math.abs(near.x - p.x) < 0.1 and math.abs(near.z - p.z) < 0.1 then
        return
    end
    table.insert(pts, at, p)
    ADFlyoverSettings.debugLog("[FlyoverEditor]: spline point %d of %d at x=%.1f z=%.1f%s.", at, #pts, p.x, p.z,
        p.wpId ~= nil and string.format(" (on waypoint id=%d)", p.wpId) or "")
end

--- A plain click: add a point. On the curve it goes into the line there (never snapped - only the
--- ends join the road); anywhere else it goes on the end, snapping onto a waypoint right under the
--- mouse unless Alt is held. A click on an existing spline point adds nothing.
function ADFlyoverEditor:multiSplineClick()
    if self.splineHoverIdx ~= nil then
        return
    end
    if self.splineEditMode and self.splineEdit == nil then
        if self.hoverId ~= nil then self:splineEditSelect(self.hoverId) end
        return
    end
    local seg = self:splineInsertPiece()
    if self.splineEdit ~= nil and seg == nil then
        return                                   -- editing: points go into the line, never on the ends
    end
    local p = self:splinePointAtCursor(seg == nil)
    if p ~= nil then
        self:multiSplineAdd(p, seg ~= nil and seg + 1 or nil)
    end
end

--- Ctrl-click on a spline point removes it. Returns true when it took the click.
function ADFlyoverEditor:multiSplineRemoveAtCursor()
    local idx = self.splineHoverIdx
    if idx == nil or self.splinePoints == nil or self.splinePoints[idx] == nil then
        return false
    end
    if self.splineEdit ~= nil and (idx == 1 or idx == #self.splinePoints) then
        self:warnPlayer("The run's ends stay where they are - other roads meet there.")
        return true
    end
    table.remove(self.splinePoints, idx)
    self.splineHoverIdx = nil
    ADFlyoverSettings.debugLog("[FlyoverEditor]: spline point %d removed (%d left).", idx, #self.splinePoints)
    return true
end

--- A press on a spline point: remember it; moving past the drag threshold while held drags it.
function ADFlyoverEditor:multiSplinePress()
    self.splinePressIdx = self.splineHoverIdx
    self.splinePressMX, self.splinePressMY = self.mouseX, self.mouseY
end

--- Release: ends a drag, or (no drag) is a click.
function ADFlyoverEditor:multiSplineRelease()
    if self.splineDragIdx ~= nil then
        local p = self.splinePoints[self.splineDragIdx]
        ADFlyoverSettings.debugLog("[FlyoverEditor]: spline point %d moved to x=%.1f z=%.1f%s.", self.splineDragIdx,
            p ~= nil and p.x or 0, p ~= nil and p.z or 0,
            (p ~= nil and p.wpId ~= nil) and string.format(" (on waypoint id=%d)", p.wpId) or "")
        self.splineDragIdx, self.splinePressIdx = nil, nil
        return
    end
    self.splinePressIdx = nil
    self:multiSplineClick()
end

--- Per frame: hover, drag, and the preview of what would be laid.
function ADFlyoverEditor:updateMultiSpline()
    if self.splinePoints == nil then
        self.splinePoints = {}
    end
    local pts = self.splinePoints
    -- the waypoints changed under an edit (an undo, another tool): its ids are stale - drop it
    if self.splineEdit ~= nil and ADGraphManager:getWayPointsCount() ~= self.splineEdit.count then
        self:cancelMultiSpline()
        self:warnPlayer("The waypoints changed - pick the run to edit again.")
        return
    end
    if self.splineEdit ~= nil and self.splinePressIdx ~= nil and (self.splinePressIdx == 1 or self.splinePressIdx == #pts) then
        self.splinePressIdx = nil                -- an edited run's ends stay put
    end

    if self.splinePressIdx ~= nil and self.splineDragIdx == nil and self.leftDown
        and self.mouseX ~= nil and self.splinePressMX ~= nil then
        local dx, dy = self.mouseX - self.splinePressMX, self.mouseY - self.splinePressMY
        if math.sqrt(dx * dx + dy * dy) > self.MOVE_DRAG_THRESHOLD then
            self.splineDragIdx = self.splinePressIdx
        end
    end
    if self.splineDragIdx ~= nil then
        if not self.leftDown or pts[self.splineDragIdx] == nil then
            self.splineDragIdx, self.splinePressIdx = nil, nil
        else
            local idx = self.splineDragIdx
            local p = self:splinePointAtCursor(idx == 1 or idx == #pts)
            if p ~= nil then
                pts[idx] = p
            end
        end
    end

    -- No hover highlight on the point being dragged: it is under the cursor by definition.
    self.splineHoverIdx = (self.splineDragIdx == nil) and self:splinePointNearCursor() or nil

    -- What a click would do here, for the preview: put a point into the line, or add one on the end
    -- (snapped onto a waypoint, or free).
    self.splineGhost = nil
    if self.splineDragIdx == nil and self.splineHoverIdx == nil then
        local seg = self:splineInsertPiece()
        local g = self:splinePointAtCursor(seg == nil)
        if g ~= nil and not (self.splineEdit ~= nil and seg == nil) then   -- editing: only into the line
            g.insert = seg ~= nil
            self.splineGhost = g
        end
    end

    if #pts < 2 then
        self.splineCurve, self.splineLaid, self.splineLaidKey, self.splineLength = nil, nil, nil, nil
        return
    end

    -- The curve only changes when a point, the spacing or a flip does, so it is rebuilt then and
    -- not every frame - the heights along it are ground lookups.
    local spacing = ADFlyoverSettings.get("splineSpacing") or 4
    local parts = { string.format("%.2f", spacing), tostring(self.splineFlipStartTangent), tostring(self.splineFlipEndTangent),
        tostring(self.snapToTerrain), tostring(ADGraphManager:getWayPointsCount()) }
    for _, p in ipairs(pts) do
        parts[#parts + 1] = string.format("%.2f_%.2f_%s", p.x, p.z, tostring(p.wpId))
    end
    local key = table.concat(parts, "|")
    if key == self.splineLaidKey then
        return
    end
    self.splineLaidKey = key

    local startDir, endDir = self:splineEndHeadings()
    local curve = ADSplinePath.build(pts, startDir, endDir)
    local inner, total = ADSplinePath.resample(curve, spacing)
    local laid = { { x = pts[1].x, y = pts[1].y, z = pts[1].z } }
    local lastY = pts[1].y
    for _, q in ipairs(inner) do
        -- The height from the ground, with the clicked points' heights as the reference so a curve
        -- across a bridge stays on it. A jump of more than a metre from the last point is held
        -- level, as the AutoDrive spline did (Hud.lua) - it stops points diving into a dip.
        local y = self:resolveHeightAt(q.x, q.z, q.y or lastY)
        if lastY ~= nil and math.abs(y - lastY) > 1 then
            y = lastY
        end
        laid[#laid + 1] = { x = q.x, y = y, z = q.z }
        lastY = y
    end
    laid[#laid + 1] = { x = pts[#pts].x, y = pts[#pts].y, z = pts[#pts].z }
    self.splineCurve, self.splineLaid, self.splineLength = curve, laid, total
end

--- Right-click: lay the previewed curve as waypoints, as one undo step.
function ADFlyoverEditor:commitMultiSpline()
    if self.splineEdit ~= nil then
        return self:splineEditApply()
    end
    local pts = self.splinePoints
    if pts == nil or #pts < 2 then
        self:cancelMultiSpline()
        return
    end
    if not ADFlyoverEditor.canEditHere() then
        self:warnPlayer("Waypoints can only be placed on the server (host/singleplayer).")
        return
    end
    -- Make sure the preview is for exactly these points before laying it.
    self.splineLaidKey = nil
    self:updateMultiSpline()
    local laid = self.splineLaid
    if laid == nil or #laid < 2 then
        return
    end

    local reverse, dual, flags = self:getConnectionOptions()
    local pointFlags = ADFlyoverEditor.fieldFlags(flags, nil)

    local startNode = self:splineSnapNode(pts[1])
    local endNode = self:splineSnapNode(pts[#pts])
    if startNode ~= nil and startNode == endNode and #laid <= 2 then
        self:warnPlayer("The spline starts and ends on the same waypoint.")
        return
    end

    ADEditorHistory:snapshot("spline")
    local created = 0
    local function newPoint(p)
        local wp = ADGraphManager:recordWayPoint(p.x, p.y, p.z, false, false, false, 0, pointFlags, false)
        if wp ~= nil then
            created = created + 1
        end
        return wp
    end
    -- Set links, not toggles: an existing link between the two is left as it is rather than
    -- flipped off. Reverse is AutoDrive's reverse road (an out link with no matching incoming).
    local function link(a, b)
        if a == nil or b == nil or a.id == b.id then
            return
        end
        if not table.contains(a.out, b.id) then table.insert(a.out, b.id) end
        if reverse then
            return
        end
        if not table.contains(b.incoming, a.id) then table.insert(b.incoming, a.id) end
        if dual then
            if not table.contains(b.out, a.id) then table.insert(b.out, a.id) end
            if not table.contains(a.incoming, b.id) then table.insert(a.incoming, b.id) end
        end
    end

    local chain = { startNode or newPoint(laid[1]) }
    for i = 2, #laid - 1 do
        chain[#chain + 1] = newPoint(laid[i]) or false
    end
    chain[#chain + 1] = endNode or newPoint(laid[#laid]) or false
    for i = 1, #chain do
        if not chain[i] then
            Logging.warning("[FlyoverEditor]: spline - a waypoint could not be created; %d of %d laid. Undo to remove them.",
                created, #laid)
            self:cancelMultiSpline()
            self:invalidateIdReferences()
            ADGraphManager:markChanges()
            return
        end
    end
    for i = 1, #chain - 1 do
        link(chain[i], chain[i + 1])
    end

    local joined = ""
    if startNode ~= nil or endNode ~= nil then
        joined = string.format(" (joined %s)", (startNode ~= nil and endNode ~= nil) and "both ends"
            or (startNode ~= nil and "start" or "end"))
    end
    Logging.info("[FlyoverEditor]: placed multi-point spline id=%d -> id=%d from %d clicked point(s): %d new waypoint(s), %.1f m, %s%s%s.",
        chain[1].id, chain[#chain].id, #pts, created, self.splineLength or 0,
        dual and "two-way" or (reverse and "reverse" or "one-way"),
        flags ~= AutoDrive.FLAG_NONE and " secondary" or "", joined)

    self.splinePoints = {}
    self:cancelMultiSpline()
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
end

--- The preview: the clicked points large (orange; one joined to a waypoint yellow), the waypoints
--- that would be laid small along the curve, and a line from the last point to the cursor.
-- ---------------------------------------------------------------------------------------------
-- EDIT A PLACED SPLINE (2026-10-15 owner: "spline tool should have an edit function for placed
-- splines, similar to road runs tool"). The card's "action: edit placed" makes a click on a laid run
-- pick the run between its junctions; its shape becomes the spline's points (as few as keep it within
-- SPLINE_EDIT_TOL), so the spline's own gestures shape it. Its two end waypoints stay (other roads
-- meet there); right-click lays its middle again along the curve, keeping its direction, one-way or
-- two-way and priority (replaceChainInterior), as one undo step.
-- ---------------------------------------------------------------------------------------------
ADFlyoverEditor.SPLINE_EDIT_TOL = 0.5

function ADFlyoverEditor:toggleSplineEditMode()
    self:cancelMultiSpline()
    self.splineEditMode = not self.splineEditMode
    ADFlyoverSettings.debugLog("[FlyoverEditor]: spline action: %s.", self.splineEditMode and "edit placed" or "new")
end

--- Pick the laid run through `seedId` for editing. True when it did.
function ADFlyoverEditor:splineEditSelect(seedId)
    local run, _, _, why = self:orderedRunThrough(seedId)
    if run == nil or #run < 2 then
        self:warnPlayer("Can't edit that: " .. tostring(why or "no run there"))
        return false
    end
    local ids, interior = {}, {}
    for i, q in ipairs(run) do
        ids[i] = q.id
        if i > 1 and i < #run then interior[q.id] = true end
    end
    local dual, flags = false, AutoDrive.FLAG_NONE
    if self.spanStyle ~= nil then dual, flags = self:spanStyle(ids) end
    local S = (ADRoadFinder ~= nil and ADRoadFinder.simplifyLine ~= nil) and ADRoadFinder.simplifyLine(run, self.SPLINE_EDIT_TOL) or run
    local pts = {}
    for i, q in ipairs(S) do pts[i] = { x = q.x, y = q.y, z = q.z } end
    if #pts < 2 then pts = { { x = run[1].x, y = run[1].y, z = run[1].z }, { x = run[#run].x, y = run[#run].y, z = run[#run].z } } end
    pts[1].wpId, pts[#pts].wpId = ids[1], ids[#ids]
    self:cancelMultiSpline()
    self.splinePoints = pts
    self.splineEdit = { ids = ids, interior = interior, dual = dual, flags = flags,
        count = ADGraphManager:getWayPointsCount() }
    ADFlyoverSettings.debugLog("[FlyoverEditor]: spline - editing the run %d..%d: %d waypoints, %d handles, %s.",
        ids[1], ids[#ids], #ids, #pts, dual and "two-way" or "one-way")
    return true
end

--- Right-click while editing: the run's middle laid again along the curve. One undo step.
function ADFlyoverEditor:splineEditApply()
    local e = self.splineEdit
    self.splineLaidKey = nil
    self:updateMultiSpline()
    e = self.splineEdit                         -- (an update may have dropped a stale edit)
    local laid = self.splineLaid
    if e == nil or laid == nil or #laid < 2 then
        self:cancelMultiSpline()
        return
    end
    if not ADFlyoverEditor.canEditHere() then
        self:warnPlayer("Waypoints can only be changed on the server (host/singleplayer).")
        return
    end
    local a, b = ADGraphManager:getWayPointById(e.ids[1]), ADGraphManager:getWayPointById(e.ids[#e.ids])
    if a == nil or b == nil then
        self:cancelMultiSpline()
        return
    end
    local P = {}
    for i, q in ipairs(laid) do P[i] = { x = q.x, y = q.y, z = q.z } end
    P[1], P[#P] = { x = a.x, y = a.y, z = a.z }, { x = b.x, y = b.y, z = b.z }
    ADEditorHistory:snapshot("spline: edit placed")
    local ok = self:replaceChainInterior(e.ids, P, e.dual, e.flags)
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
    -- always logged, one line per right-click (the in-game test card ticks itself from it)
    Logging.info("[FlyoverEditor]: spline - edited the run %d..%d: %d waypoints now (was %d), %s.",
        e.ids[1], e.ids[#e.ids], #P, #e.ids, ok and "done" or "FAILED")
    self:cancelMultiSpline()
end

--- Edit mode, nothing picked: the run a click would pick, outlined.
function ADFlyoverEditor:splineEditHoverRun()
    if not self.splineEditMode or self.splineEdit ~= nil or self.hoverId == nil then
        self.splineEditHoverSeed, self.splineEditHoverPts = nil, nil
        return nil
    end
    if self.splineEditHoverSeed ~= self.hoverId then
        self.splineEditHoverSeed = self.hoverId
        self.splineEditHoverPts = self:orderedRunThrough(self.hoverId)
    end
    return self.splineEditHoverPts
end

function ADFlyoverEditor:drawMultiSpline(lw)
    local pts = self.splinePoints
    if pts == nil then
        return
    end
    if #pts == 0 and self.splineEditMode then
        local run = self:splineEditHoverRun()
        if run ~= nil then
            for i = 2, #run do
                local p, q = run[i - 1], run[i]
                ADDrawingManager:addLineTask(p.x, p.y + 0.3, p.z, q.x, q.y + 0.3, q.z, lw * 2, 0.12, 0.47, 0.73)
            end
        end
        return
    end
    if #pts == 0 then
        -- Nothing down yet: just show where the first point would go (yellow = joins a waypoint).
        local g = self.splineGhost
        if g ~= nil then
            ADDrawingManager:addSphereTask(g.x, (g.y or 0) + 0.8, g.z, 3,
                1, g.wpId ~= nil and 0.9 or 1, g.wpId ~= nil and 0.1 or 1, g.wpId ~= nil and 0.20 or 0.12)
        end
        return
    end
    local laid = self.splineLaid or {}
    for i, q in ipairs(laid) do
        if i > 1 then
            local a = laid[i - 1]
            ADDrawingManager:addLineTask(a.x, a.y + 0.6, a.z, q.x, q.y + 0.6, q.z, lw, 0.2, 0.8, 1)
            if i < #laid then
                ADDrawingManager:addSphereTask(q.x, q.y + 0.6, q.z, 2, 0.2, 0.8, 1, 0.15)
            end
        end
    end
    for i, p in ipairs(pts) do
        local y = (p.y or 0) + 0.8
        local size = ((i == self.splineHoverIdx) or (i == self.splineDragIdx)) and 5 or 4
        if p.wpId ~= nil then
            ADDrawingManager:addSphereTask(p.x, y, p.z, size, 1, 0.9, 0.1, 0.20)
        else
            ADDrawingManager:addSphereTask(p.x, y, p.z, size, 1, 0.5, 0, 0.20)
        end
    end
    -- Where a click would put the next point: green on the line (goes in between), yellow on a
    -- waypoint (snaps, joins the road), white on bare ground - with a line from the end it joins.
    local g = self.splineGhost
    if g ~= nil then
        local gy = (g.y or 0) + 0.8
        if g.insert then
            ADDrawingManager:addSphereTask(g.x, gy, g.z, 3, 0.3, 1, 0.3, 0.20)
        else
            local last = pts[#pts]
            ADDrawingManager:addLineTask(last.x, (last.y or g.y or 0) + 0.6, last.z, g.x, gy - 0.2, g.z, lw, 1, 1, 1)
            if g.wpId ~= nil then
                ADDrawingManager:addSphereTask(g.x, gy, g.z, 3, 1, 0.9, 0.1, 0.20)
            else
                ADDrawingManager:addSphereTask(g.x, gy, g.z, 3, 1, 1, 1, 0.12)
            end
        end
    end
end


-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua
-- loads it after FlyoverEditor.lua, in the old file's order.
-- MODSPLIT: HELPERS FROM THE FILES LOADED BEFORE THIS ONE (tools/modsplit/split.py writes this block)
for _, name in ipairs({ "clearSplineState", "tryCall" }) do
    if ADFlyoverEditor.shared == nil or ADFlyoverEditor.shared[name] == nil then
        Logging.error("[FlyoverEditor]: Connections.lua needs %s, which no file loaded before it shares", name)
    end
end
local clearSplineState = ADFlyoverEditor.shared.clearSplineState
local tryCall = ADFlyoverEditor.shared.tryCall
-- MODSPLIT: end of the helpers

-- ---------------------------------------------------------------------------------------------
-- Name a waypoint (map marker), reusing the text dialog the mod already has.
-- ---------------------------------------------------------------------------------------------

function ADFlyoverEditor:nameAtCursor()
    if self.hoverId == nil then
        return
    end
    if ADEnterTargetNameGui == nil or g_gui == nil then
        Logging.error("[FlyoverEditor]: the name dialog is not available.")
        return
    end

    -- The dialog normally works out which waypoint to name from the controlled vehicle, which is
    -- exactly the assumption that does not hold here. This override points it at the clicked
    -- waypoint instead; the dialog clears it again on close.
    ADEnterTargetNameGui.overrideWayPointId = self.hoverId
    ADEditorHistory:snapshot("name waypoint")
    -- showDialog returns falsy rather than throwing when the screen is not registered, so check
    -- it: an unreported failure here looks exactly like "the dialog opened and did nothing".
    local shown = g_gui:showDialog("ADEnterTargetNameGui")
    if not shown then
        Logging.error("[FlyoverEditor]: the name dialog would not open - g_gui has no screen "
            .. "registered as 'ADEnterTargetNameGui'. Is AutoDrive fully loaded?")
        return
    end
    -- Aim the open dialog at the clicked waypoint directly, not only through the class-level onOpen
    -- wrapper: without this the dialog can still open on the marker nearest the vehicle.
    if ADEnterTargetNameGui.applyFlyoverOverride ~= nil then
        local screen = g_gui.guis ~= nil and g_gui.guis["ADEnterTargetNameGui"] or nil
        local instance = screen ~= nil and (screen.target or screen) or nil
        local ok, err = pcall(ADEnterTargetNameGui.applyFlyoverOverride, instance)
        if not ok then
            Logging.warning("[FlyoverEditor]: could not aim the name dialog at the clicked waypoint: %s", tostring(err))
        end
    end
    ADFlyoverSettings.debugLog("[FlyoverEditor]: opened the name dialog for waypoint id=%s.", tostring(self.hoverId))
end


-- ---------------------------------------------------------------------------------------------
-- Persistent connection options.
--
-- These used to be modifier keys held down during every single click (Alt for two-way, LShift for
-- secondary, RShift for reverse), inherited from the mod's own recording scheme. That is fine for
-- the occasional connection and miserable for laying a route: the combination has to be held
-- correctly for every click, there is no indication of what is currently selected, and getting it
-- wrong is only visible afterwards. They are now sticky settings shown on the panel.
-- ---------------------------------------------------------------------------------------------

ADFlyoverEditor.CONNECTION = { ONEWAY = 1, TWOWAY = 2, REVERSE = 3 }
ADFlyoverEditor.CONNECTION_NAMES = { "one-way", "two-way", "reverse-way" }

function ADFlyoverEditor:cycleConnectionMode()
    self.connectionMode = (self.connectionMode % #self.CONNECTION_NAMES) + 1
    ADFlyoverSettings.debugLog("[FlyoverEditor]: new connections are now %s.", self.CONNECTION_NAMES[self.connectionMode])
end

function ADFlyoverEditor:togglePriority()
    self.subPrio = not self.subPrio
    ADFlyoverSettings.debugLog("[FlyoverEditor]: new connections are now %s.", self.subPrio and "secondary" or "primary")
end

function ADFlyoverEditor:cycleFalloff()
    local next_ = self.falloffRadius + AutoDrive.FLYOVER_FALLOFF_STEP
    self:setFalloffRadius(next_ > AutoDrive.FLYOVER_FALLOFF_MAX and 0 or next_)
end

--- The three values the graph calls for, derived from the sticky settings above.
function ADFlyoverEditor:getConnectionOptions()
    local reverse = self.connectionMode == self.CONNECTION.REVERSE
    local dual = self.connectionMode == self.CONNECTION.TWOWAY
    local flags = self.subPrio and AutoDrive.FLAG_SUBPRIO or AutoDrive.FLAG_NONE
    return reverse, dual, flags
end

--- What the current tool is waiting for, in plain words. This is the line that tells you what to
--- do next instead of leaving you to remember it, and it is why the panel exists.
--- One localized guidance message for the current tool state, returned WHOLE (not pre-split). The
--- panel wraps it to width at render (see buildRows). Collapsing the old line pairs into one string is
--- what lets German - which wraps differently from English - read as a sentence rather than two halves
--- broken at the English line break. Format placeholders are kept inside the localized template so the
--- live value lands in the right place in either language.
function ADFlyoverEditor:getNextStepLines()
    local t = self.TOOL
    local function L(s) return ADFlyoverLocale ~= nil and ADFlyoverLocale.t(s) or s end
    local function side() return L(self:sideName()) end

    -- Circle-select is tool-agnostic (selection is a shared substrate, same as Ctrl+drag box), so
    -- this overrides whatever the current tool would otherwise say - the mid-drag state is what the
    -- player actually needs telling right now, regardless of which tool is active. No "armed" state
    -- to report any more - Alt+drag starts a circle in one motion, the same as Ctrl+drag does a box.
    if self.circleActive then
        return L("Release to select everything inside the circle.")
    end
    if self.freehandActive then
        return L("Release to select everything inside the traced area.")
    end
    if self.rotBoxDragging then
        return L("Release to set the box's edge (direction and length).")
    end
    if self.rotBoxActive then
        return L("Click to set the width and finish the box.")
    end

    if self.tool == t.NONE then
        return L("No tool selected. Pick one above, or press 1-9 / 0.")
    end

    if self.tool == t.DRAW then
        if self.lastWaypointId ~= nil then
            return L("Click ground to extend, or a waypoint to link. Right-click ends.")
        end
        return L("Click to start a run, or a waypoint to draw on from it.")
    elseif self.tool == t.MOVE then
        if self.moveOffsetChainIds ~= nil then
            if self.dragId ~= nil then
                return string.format(L("Dragging sets the offset (%.1fm). Release, then wheel to fine-tune."),
                    self.moveOffsetDistance)
            end
            return string.format(L("Offset %.1fm - wheel to adjust, right-click to finish."),
                self.moveOffsetDistance)
        end
        if self.dragId ~= nil then
            local verb = (self.moveCopyOn and self.moveBreakOn and L("disconnect"))
                or (self.moveCopyOn and L("copy"))
                or (self.moveBreakOn and L("drop and disconnect"))
                or L("drop")
            if self.moveSelectMode == self.MOVE_SELECT.POINT and self.moveFalloffOn then
                return string.format(L("Wheel changes falloff (%.1fm), live. Release to %s."), self.falloffRadius, verb)
            end
            return string.format(L("Release to %s."), verb)
        end
        if self.moveSelectMode == self.MOVE_SELECT.SPAN then
            if self.moveSpanFromId == nil then
                return L("Click a waypoint to start the span.")
            end
            if self.moveSpanToId == nil then
                return L("Click the far end of the span.")
            end
            if self.hoverId ~= nil and self.moveSpanIds ~= nil and self.moveSpanIds[self.hoverId] then
                return L("Drag the highlighted span.")
            end
            return L("Click to replace whichever end is closer, or drag the span.")
        end
        if self.hoverId ~= nil then
            return L("Drag the highlighted waypoint.")
        end
        return L("Point at a waypoint, then drag it.")
    elseif self.tool == t.DELETE then
        if self.selectionCount > 0 then
            return string.format(L("Click to delete %d selected."), self.selectionCount)
        end
        if self.deleteScope == self.DELETE_SCOPE.RUN then
            return L("Click a run to delete all of it, out to the junctions at each end.")
        end
        if self.hoverId ~= nil then
            return L("Click to delete the highlighted one.")
        end
        return L("Point at a waypoint to delete it.")
    elseif self.tool == t.SMOOTH then
        if self.smoothToId ~= nil then
            if self.smoothMode == self.SMOOTH_MODE.REBUILD then
                return string.format(L("Wheel sets max spacing (%.1fm). Curves stay denser."), self.smoothSpacing)
            end
            return string.format(L("Wheel sets strength (%d). Right-click applies it."), self.smoothStrength)
        end
        if self.smoothFromId ~= nil then
            return L("Click the far end of the span.")
        end
        return L("Click one end of the span.")
    elseif self.tool == t.NAME then
        return L("Click a waypoint to name it.")
    elseif self.tool == t.SPLINE then
        if self.splineToId ~= nil then
            return L("Wheel adjusts the curve. Right-click places it.")
        end
        if self.splineFromId ~= nil then
            return L("Click the waypoint to curve to.")
        end
        return L("Click the waypoint to curve from.")
    elseif self.tool == t.FIELDLOOP then
        return L("Click inside a field to ring it. Uses the field loop settings.")
    elseif self.tool == t.SIDING then
        if self.sidingBlockedBy ~= nil then
            return L("Will not fit here. See the log for why.")
        end
        if self.sidingAnchorId ~= nil then
            return string.format(L("Wheel sets length (%.0fm, %s side). Flip the side on the panel. Right-click applies."),
                ADFlyoverSettings.get("sidingLength") or 30, side())
        end
        return L("Click where the siding should sit - the click is its centre.")
    elseif self.tool == t.PARALLEL then
        if self.offsetToId ~= nil then
            if self.offsetBlockedBy ~= nil then
                return L("Too tight to offset that far. Wheel it back, or swap sides.")
            end
            return string.format(L("Wheel sets offset (%.1fm %s). Flip the side on the panel. Right-click applies."),
                self.offsetDistance, side())
        end
        if self.offsetFromId ~= nil then
            return L("Click the far end of the span.")
        end
        return L("Click one end of a span to run a track alongside it, or double-click for the whole run.")
    elseif self.tool == t.GROUND then
        if self.groundToId ~= nil or self.groundUsesSelection then
            local n = self.groundPreview ~= nil and #self.groundPreview or 0
            if n == 0 then
                return string.format(L("Nothing over %.1fm off the ground. Wheel the tolerance down to see more."), self.groundTolerance)
            end
            return string.format(L("%d of %d waypoint(s) off the ground. Right-click re-seats them."), n, self.groundChecked or 0)
        end
        if self.groundFromId ~= nil then
            return L("Click the far end of the span.")
        end
        return L("Click a span or double-click a run, or select points (box, circle, Ctrl-click) - connected or not - to find waypoints off the ground.")
    elseif self.tool == t.STRAIGHTEN then
        if self.straightenToId ~= nil then
            return string.format(L("Wheel sets tolerance (%.2fm). Right-click straightens the span."), self.straightenTolerance)
        end
        if self.straightenFromId ~= nil then
            return L("Click the far end of the span.")
        end
        return L("Click one end of a span to straighten it, or double-click for the whole run.")
    elseif self.tool == t.DIVIDE then
        if self.divideToId ~= nil then
            return string.format(L("Wheel sets the count (%d). Right-click applies it."), self.divideCount)
        end
        if self.divideFromId ~= nil then
            return L("Click the far end of the span.")
        end
        return L("Click one end of the span to divide.")
    elseif self.tool == t.CONVERT then
        return string.format(L("Click to make it %s (%s)."),
            L(self.CONVERT_OP_NAMES[self.convertDirection]) .. ", " .. L(self.CONVERT_OP_NAMES[self.convertPriority]),
            self.convertScope == self.DELETE_SCOPE.RUN and L("whole run") or L("this waypoint"))
    elseif self.tool == t.MERGE then
        if self.mergeToId ~= nil then
            return L("Green marks what would be absorbed. Click the OTHER track to merge (right-click if it is the only one).")
        end
        if self.mergeFromId ~= nil then
            return L("Click the far end of the span, on the SAME track.")
        end
        return L("Click one end of the span to merge, or double-click for the whole run.")
    elseif self.tool == t.JUNCTION then
        local jp = self.junctionPreview
        if jp ~= nil and jp.clearMode then
            local leave = self.junctionLeaveThrough ~= false
            local nodes = (leave and jp.turnDebris or jp.debris) or {}
            local n = #nodes
            -- A junction that is one shared point of farm tracks has no wiring to count, but the clear
            -- still cuts tracks off it (junctionClearOnePoint).
            local cut = 0
            if n == 0 then cut = self:junctionOnePointCut(jp, leave) end
            if self.junctionArmed ~= nil then
                if n > 0 then
                    return string.format(L("Site locked: will clear %d point(s). Right-click clears; left-click moves the lock."), n)
                end
                if cut > 0 then
                    return string.format(L("Site locked: one shared point of farm tracks, %d track(s) to cut off it. Right-click clears; left-click moves the lock."), cut)
                end
                return L("Site locked, nothing here to clear. Right-click unlocks; left-click moves the lock.")
            end
            if n > 0 then
                return string.format(L("%d point(s) to clear here. Left-click locks the site; wheel = scope."), n)
            end
            if cut > 0 then
                return L("One shared point of farm tracks here. Left-click locks the site; wheel = scope.")
            end
            return L("Point at a junction and left-click to lock it. Wheel = scope; right-click leaves the tool.")
        end
        if self.junctionMode == "place" then
            if jp ~= nil and jp.placeMode and jp.ok and jp.plan ~= nil then
                local what = string.format("%s %s", jp.plan.shape == "exact" and "mod" or tostring(jp.plan.shape),
                    tostring(jp.plan.kind))
                if self.junctionArmed ~= nil then
                    return string.format(L("Locked: right-click places the %s. Left-click moves the lock."), what)
                end
                return string.format(L("A %s goes here. Left-click locks it."), what)
            elseif jp ~= nil and jp.placeMode then
                return L("Nothing can be placed here - the card says why.")
            end
            return L("Point where roads cross and left-click to lock.")
        end
        local placeable = jp ~= nil and ((jp.nNew or 0) + (jp.nRebuild or 0)) or 0
        if self.junctionArmed ~= nil then
            if placeable > 0 then
                if (jp.nRebuild or 0) > 0 then
                    return string.format(L("Site locked: %d new, %d rebuilt. Right-click places; left-click moves the lock."),
                        jp.nNew, jp.nRebuild)
                end
                return string.format(L("Site locked: %d new turn(s). Right-click places; left-click moves the lock."),
                    jp.nNew)
            end
            return L("Site locked, nothing new to place. Right-click unlocks; left-click moves the lock.")
        end
        if placeable > 0 then
            return string.format(L("%d turn(s) to lay here. Left-click locks the site; wheel = scope."), placeable)
        end
        return L("Point at a crossing and left-click to lock it. Wheel = scope; right-click leaves the tool.")
    end

    return ""
end

-- ---------------------------------------------------------------------------------------------
-- Spline connect - the mod's own curved connection, driven from the flyover tools.
--
-- This is not a reimplementation: it calls exactly what the standard editor calls
-- (AutoDrive:createSplineInterpolationBetween, then ADGraphManager:createSplineConnection), so a
-- spline laid here is identical to one laid from a vehicle. The only differences are that the two
-- endpoints come from flyover clicks rather than the vehicle's selected/hovered node, and that the
-- curvature is a sticky panel setting rather than a wheel gesture.
-- ---------------------------------------------------------------------------------------------

-- nil means "let the mod choose", which is what the standard editor does until you scroll.
ADFlyoverEditor.CURVATURE_VALUES = { false, 0.5, 1, 2, 5 }
ADFlyoverEditor.CURVATURE_NAMES = { "auto", "0.5", "1", "2", "5" }

--- Mirror a spline control point about its node.
---
--- AutoDrive:getSplineControlPoints returns, for each end, a handle at `node + direction`, where
--- direction points at whichever neighbour forms the straightest line to the other end. On a
--- two-way track both directions exist, so that choice is a guess: the curve arrives lying against
--- the lane one way round with no way to ask for the other. Reflecting the handle through the node
--- gives exactly the opposite tangent, so the spline merges in facing the other way along the
--- track. This is the geometry of the join, not which way traffic runs - that is the separate
--- direction setting.
local function mirrorControlPoint(node, p)
    if node == nil or p == nil then
        return p
    end
    return { x = 2 * node.x - p.x, y = node.y, z = 2 * node.z - p.z }
end

-- Restored: this was removed with the old merge-direction control, leaving the panel calling a
-- function that no longer existed.
function ADFlyoverEditor:toggleSplineEnds()
    self.splineSwapEnds = not self.splineSwapEnds
    ADFlyoverSettings.debugLog("[FlyoverEditor]: spline endpoints are %s.", self.splineSwapEnds and "swapped" or "normal")
end

function ADFlyoverEditor:toggleSplineEndTangent()
    self.splineFlipEndTangent = not self.splineFlipEndTangent
    ADFlyoverSettings.debugLog("[FlyoverEditor]: spline end tangent %s.", self.splineFlipEndTangent and "flipped" or "auto")
end

function ADFlyoverEditor:toggleSplineStartTangent()
    self.splineFlipStartTangent = not self.splineFlipStartTangent
    ADFlyoverSettings.debugLog("[FlyoverEditor]: spline start tangent %s.", self.splineFlipStartTangent and "flipped" or "auto")
end

--- Build the interpolation, applying any tangent flips.
---
--- With both on auto this defers to the mod's own createSplineInterpolationBetween, so the result
--- is identical to the standard editor. A flip has to go the long way round - fetch the control
--- points, mirror, hand them to createSplineWithControlPoints - because the mod derives them
--- internally with no way to influence the choice.
function ADFlyoverEditor:buildSplineInterpolation(startNode, endNode)
    AutoDrive.splineInterpolation = nil

    if not self.splineFlipEndTangent and not self.splineFlipStartTangent then
        AutoDrive:createSplineInterpolationBetween(startNode, endNode)
        return
    end

    if table.contains(startNode.out, endNode.id) or table.contains(endNode.incoming, startNode.id) then
        return
    end
    local curvature = AutoDrive.splineInterpolationUserCurvature
    if type(curvature) ~= "number" or curvature < 0.5 then
        return
    end

    local ok, p0, p3 = pcall(function()
        return AutoDrive:getSplineControlPoints(startNode, endNode)
    end)
    if not ok or p0 == nil or p3 == nil then
        AutoDrive:createSplineInterpolationBetween(startNode, endNode)
        return
    end

    if self.splineFlipStartTangent then
        p0 = mirrorControlPoint(startNode, p0)
    end
    if self.splineFlipEndTangent then
        p3 = mirrorControlPoint(endNode, p3)
    end

    tryCall("createSplineWithControlPoints", function()
        AutoDrive:createSplineWithControlPoints(startNode, p0, endNode, p3)
    end)
end

function ADFlyoverEditor:cycleCurvature()
    self.curvatureIndex = (self.curvatureIndex % #self.CURVATURE_VALUES) + 1
    ADFlyoverSettings.debugLog("[FlyoverEditor]: spline curvature %s.", self.CURVATURE_NAMES[self.curvatureIndex])
end

function ADFlyoverEditor:splineClick()
    if self.hoverId == nil then
        return
    end

    if self.splineFromId == nil then
        self.splineFromId = self.hoverId
        ADFlyoverSettings.debugLog("[FlyoverEditor]: spline from id=%s; click the waypoint to curve to.", tostring(self.splineFromId))
        return
    end

    if self.splineToId == nil then
        if self.hoverId == self.splineFromId then
            return
        end
        self.splineToId = self.hoverId
        -- Curvature must be a NUMBER before the preview exists: the mod adds to it unguarded
        -- while an interpolation is valid (see clearSplineState).
        if type(AutoDrive.splineInterpolationUserCurvature) ~= "number" then
            AutoDrive.splineInterpolationUserCurvature = AutoDrive.FLYOVER_DEFAULT_CURVATURE
        end
        ADFlyoverSettings.debugLog("[FlyoverEditor]: previewing a spline id=%s -> id=%s. Wheel adjusts curvature, right-click places it.",
            tostring(self.splineFromId), tostring(self.splineToId))
        return
    end

    -- Both ends already chosen: a further click re-picks the far end rather than doing nothing.
    if self.hoverId ~= self.splineFromId then
        self.splineToId = self.hoverId
    end
end

--- Rebuild the preview. Called every frame while one is pending.
---
--- Recomputing continuously is the point, not waste: AutoDrive:handleSplineCurvature only adjusts
--- the curvature - and only suppresses the camera zoom to do it - while splineInterpolation is
--- valid. Keeping a live interpolation is therefore what puts curvature on the wheel and takes
--- zoom off it, and it is what makes the endpoint and merge toggles change the shape as they are
--- cycled instead of only at the moment of placing.
function ADFlyoverEditor:updateSplinePreview()
    if self.splineFromId == nil or self.splineToId == nil then
        return
    end

    -- The spline always ends on the waypoint that was clicked. An earlier version could aim at a
    -- neighbour instead, to control which way the curve entered a two-way lane, but landing
    -- somewhere other than where you clicked is a worse surprise than the control was worth.
    local startId, endId = self.splineFromId, self.splineToId
    if self.splineSwapEnds then
        startId, endId = endId, startId
    end

    local startNode = ADGraphManager:getWayPointById(startId)
    local endNode = ADGraphManager:getWayPointById(endId)
    if startNode == nil or endNode == nil then
        self:cancelSplinePreview()
        return
    end

    self.splineResolvedStart, self.splineResolvedEnd = startId, endId

    tryCall("buildSplineInterpolation", function()
        self:buildSplineInterpolation(startNode, endNode)
    end)
end

function ADFlyoverEditor:cancelSplinePreview()
    if self.splineFromId ~= nil or self.splineToId ~= nil then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: spline preview discarded.")
    end
    self.splineFromId, self.splineToId = nil, nil
    self.splineResolvedStart, self.splineResolvedEnd = nil, nil
    clearSplineState()
end

--- Commit whatever the preview is currently showing.
function ADFlyoverEditor:commitSplinePreview()
    local startId, endId = self.splineResolvedStart, self.splineResolvedEnd
    if startId == nil or endId == nil then
        return
    end

    local startNode = ADGraphManager:getWayPointById(startId)
    local endNode = ADGraphManager:getWayPointById(endId)
    if startNode == nil or endNode == nil then
        self:cancelSplinePreview()
        return
    end

    local curvature = AutoDrive.splineInterpolationUserCurvature
    local interpolation = AutoDrive.splineInterpolation
    local reverse, dual, flags = self:getConnectionOptions()

    if interpolation == nil or not interpolation.valid
        or interpolation.waypoints == nil or #interpolation.waypoints <= 2 then
        -- Below curvature 0.5 the mod deliberately falls back to a straight line, and it also
        -- refuses a preview between two waypoints that are already connected. Both are ordinary
        -- outcomes rather than failures, so this connects them straight rather than complaining.
        ADFlyoverSettings.debugLog("[FlyoverEditor]: no curve to place (curvature %.2f); connecting id=%s to id=%s directly.",
            curvature or -1, tostring(startId), tostring(endId))
        ADEditorHistory:snapshot("connect (straight)")
        ADGraphManager:toggleConnectionBetween(startNode, endNode, reverse, dual, false)
        ADGraphManager:markChanges()
        self:cancelSplinePreview()
        return
    end

    -- Drop the first and last interpolated points - the endpoints already exist - and clamp height
    -- jumps, which stops points diving into the terrain over a bridge or a dip. Both copied from
    -- Hud.lua:541-552.
    local waypoints = {}
    local lastHeight = startNode.y
    for wpId, wp in pairs(interpolation.waypoints) do
        if wpId ~= 1 and wpId < (#interpolation.waypoints - 1) then
            if math.abs(wp.y - lastHeight) > 1 then
                wp.y = lastHeight
            end
            table.insert(waypoints, { x = wp.x, y = wp.y, z = wp.z })
            lastHeight = wp.y
        end
    end

    -- Honour the direction setting. createSplineConnection has no reverse parameter, so a reversed
    -- spline is built as the same curve laid down the other way: swap the endpoints and walk the
    -- interpolated points backwards. The shape is identical, the travel is opposite. Without this
    -- the reverse setting was silently discarded and there was no way to flip a spline at all.
    local chainStart, chainEnd = startId, endId
    if reverse then
        chainStart, chainEnd = endId, startId
        local flipped = {}
        for i = #waypoints, 1, -1 do
            flipped[#flipped + 1] = waypoints[i]
        end
        waypoints = flipped
    end

    ADEditorHistory:snapshot("spline connect")
    ADGraphManager:createSplineConnection(chainStart, waypoints, chainEnd, dual, false)

    -- createSplineConnection takes no flags, so a secondary spline is re-flagged afterwards. The
    -- new points are appended, so they are the last ones in the graph.
    if flags ~= AutoDrive.FLAG_NONE then
        local total = ADGraphManager:getWayPointsCount()
        for id = total - #waypoints + 1, total do
            ADGraphManager:setWayPointFlags(id, flags, false)
        end
    end

    ADFlyoverSettings.debugLog("[FlyoverEditor]: placed spline id=%s -> id=%s with %d point(s), curvature %.2f, %s%s%s.",
        tostring(chainStart), tostring(chainEnd), #waypoints, curvature or -1,
        dual and "two-way" or "one-way", flags ~= AutoDrive.FLAG_NONE and " secondary" or "",
        reverse and " (reversed)" or "")

    self.splineFromId, self.splineToId = nil, nil
    self.splineResolvedStart, self.splineResolvedEnd = nil, nil
    clearSplineState()
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
end

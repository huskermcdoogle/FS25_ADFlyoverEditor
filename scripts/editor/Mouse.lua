-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua
-- loads it after FlyoverEditor.lua, in the old file's order.
-- MODSPLIT: HELPERS FROM THE FILES LOADED BEFORE THIS ONE (tools/modsplit/split.py writes this block)
for _, name in ipairs({ "LINK_LISTS", "linkList", "tryCall" }) do
    if ADFlyoverEditor.shared == nil or ADFlyoverEditor.shared[name] == nil then
        Logging.error("[FlyoverEditor]: Mouse.lua needs %s, which no file loaded before it shares", name)
    end
end
local LINK_LISTS = ADFlyoverEditor.shared.LINK_LISTS
local linkList = ADFlyoverEditor.shared.linkList
local tryCall = ADFlyoverEditor.shared.tryCall
-- MODSPLIT: end of the helpers

function ADFlyoverEditor:mouseEvent(posX, posY, isDown, isUp, button)
    -- Every event, moves included: update() needs to know whether the mouse is over the panel.
    self.mouseX, self.mouseY = posX, posY

    -- Logged BEFORE the guard, and only for real button presses, so a click that is being thrown
    -- away still leaves a trace. A siding previewed on foot and then did nothing, with no log line
    -- at all - which means the code never reached the commit, and there was no way to tell whether
    -- the click arrived and was rejected or never arrived. This says which.
    if isDown and button ~= nil
        and button ~= Input.MOUSE_BUTTON_WHEEL_UP and button ~= Input.MOUSE_BUTTON_WHEEL_DOWN then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: click button=%s active=%s camera=%s cursor=%s guiBlocking=%s",
            tostring(button), tostring(self.active), tostring(self.camera ~= nil),
            tostring(self.cursor ~= nil), tostring(self:isGuiBlocking()))
    end

    if not self.active or self.camera == nil or self.cursor == nil or self:isGuiBlocking() then
        return
    end

    -- A modal (settings dialog or the browsable manual) owns every click, and nothing reaches the
    -- camera, the panel or the tools. Both populate dialogRows, so dialogClick handles either. The
    -- wheel arrives on its own action path (handleWheel); here we take clicks and swallow the rest.
    if self:isModalOpen() then
        if button == 1 and isDown then
            ADFlyoverHud:dialogClick(posX, posY)
        end
        return
    end

    -- Middle mouse is the camera's own orbit/spin, so it is left entirely to the camera - hiding the
    -- tool card is a keyboard key, a panel button, and an automatic hide while dragging instead
    -- (see toggleCard and buildRows). Trying to share MMB fought the orbit and only half-worked.

    -- The panel gets the event first. A header drag has to claim the WHOLE gesture, including the
    -- camera, or panning the camera and dragging the panel happen at the same time.
    if ADFlyoverHud:handleDrag(self, posX, posY, isDown, isUp, button) then
        return
    end

    -- The wheel, while a drag is in progress.
    --
    -- Normally the wheel reaches us as a camera ZOOM ACTION EVENT, which AutoDrive hooks and hands
    -- to handleWheel. That action does not fire while a mouse button is held down - measured: a
    -- four-second drag produced no wheel events at all, while scrolling with nothing held produced
    -- six in as many seconds. So the one path the falloff wheel depended on is precisely the one
    -- that is dead for the whole time it is wanted.
    --
    -- Mouse events still arrive during a drag - that is how dragging works - so take the wheel from
    -- here instead. Restricted to a live drag on purpose: outside one the action path works and
    -- handles it, and claiming it in both places would apply every notch twice.
    if isDown and self.dragId ~= nil then
        local wheelUp = Input.MOUSE_BUTTON_WHEEL_UP ~= nil and button == Input.MOUSE_BUTTON_WHEEL_UP
        local wheelDown = Input.MOUSE_BUTTON_WHEEL_DOWN ~= nil and button == Input.MOUSE_BUTTON_WHEEL_DOWN
        if wheelUp or wheelDown then
            self:handleWheel(wheelUp and 1 or -1)
            return
        end
    end

    tryCall("camera:mouseEvent", function() self.camera:mouseEvent(posX, posY, isDown, isUp, button) end)

    -- Track the press ourselves and act only on a genuine down->up transition. Acting on isUp
    -- alone stacked 15-26 waypoints on a single spot per click (87 placements across 9 distinct
    -- positions in testing), so isUp here is evidently not the one-shot edge it looks like.
    if button == 1 then
        if isDown then
            -- The panel takes the click before any tool sees it. Checked on the press so the
            -- matching release is swallowed too, rather than a button press turning into a
            -- waypoint placed on the terrain underneath the panel.
                -- An edit in progress is abandoned by clicking anywhere other than into it. Without
            -- this, clicking a number field and then clicking away left the edit live forever, and
            -- because handleEditKey swallows EVERY key while editing, the whole keyboard stopped
            -- responding - undo, the tool numbers, all of it - with nothing on screen to say why.
            local wasEditing = self.editing ~= nil

            if ADFlyoverHud:onClick(posX, posY) then
                self.panelClaimedClick = true
                return
            end
            self.panelClaimedClick = false

            if wasEditing and self.editing ~= nil then
                self:cancelEditNumber()
            end
            self.leftDown = true
            self:onLeftPress()
        elseif isUp then
            if self.panelClaimedClick then
                self.panelClaimedClick = false
                return
            end
            if self.leftDown then
                self:onLeftRelease()
            end
            self.leftDown = false
        end
    elseif button == 3 then
        -- Secondary action of the current tool. For place-waypoint that means "end this run", so
        -- the next click starts a new one instead of dragging a connection across the map.
        -- Deliberately not a timeout: a chain that breaks on its own would break exactly while
        -- lining up the next click, making the result depend on how fast you happen to work.
        if isDown then
            self.rightDown = true
        elseif isUp then
            if self.rightDown then
                self:onRightRelease()
            end
            self.rightDown = false
        end
    end
end

--- Show/hide the floating tool card by hand - the keyboard key (H) and the panel button both call
--- this. The card ALSO hides on its own while you drag a point (see buildRows), so this manual
--- override is for when it covers something you want to see while you are not mid-drag. Middle mouse
--- used to do this, but that button is the camera's orbit.
function ADFlyoverEditor:toggleCard()
    self.cardHidden = not self.cardHidden
    ADFlyoverSettings.debugLog("[FlyoverEditor]: tool card %s.", self.cardHidden and "hidden" or "shown")
end

--- Show/hide the contextual help panel - the "?" button on the header and the / (?) key both call
--- this. It shows the current tool's help and follows the tool as you switch, without blocking use.
function ADFlyoverEditor:toggleHelp()
    self.helpOpen = not self.helpOpen
    -- A freshly opened help panel starts at the top of the page, not wherever the last one was left.
    if self.helpOpen then
        self.helpScroll = 0
    end
end

--- Scroll the contextual help page. Mirrors manualScrollBy: dir is the reversed wheel step, so the
--- direction matches the manual (and everything else). The HUD clamps helpScroll to the page each
--- frame, since only it knows how long the current tool's help is; here we just move it and keep it
--- off the negative side.
function ADFlyoverEditor:helpScrollBy(dir)
    self.helpScroll = math.max(0, (self.helpScroll or 0) - dir * 0.06)
end

--- True while the active tool is mid-action - a span's first end picked, a run open, a drag armed.
--- Used to fire the floating card's jump-out only ONCE per action (its first click), not on every
--- click of that action (a span's second point, say) - and not again until the NEXT action starts.
function ADFlyoverEditor:toolHasPendingStart()
    local t = self.tool
    if t == self.TOOL.STRAIGHTEN then return self.straightenFromId ~= nil
    elseif t == self.TOOL.SMOOTH then return self.smoothFromId ~= nil
    elseif t == self.TOOL.DIVIDE then return self.divideFromId ~= nil
    elseif t == self.TOOL.GROUND then return self.groundFromId ~= nil
    elseif t == self.TOOL.PARALLEL then return self.offsetFromId ~= nil
    elseif t == self.TOOL.SIDING then return self.sidingAnchorId ~= nil
    elseif t == self.TOOL.SPLINE then return self.splineFromId ~= nil or self:multiSplinePending()
    elseif t == self.TOOL.MERGE then return self.mergeFromId ~= nil
    elseif t == self.TOOL.DRAW then return self.lastWaypointId ~= nil
    elseif t == self.TOOL.JUNCTION then return self.junctionArmed ~= nil
    elseif t == self.TOOL.ROADRUNS then return self.roadRuns ~= nil and #self.roadRuns.picks > 0
    end
    return false
end

function ADFlyoverEditor:onLeftPress()
    -- The floating tool card no longer jumps to the click: it stays where the player last left it
    -- (persisted), and the HUD moves it aside only while it would cover something being worked on.

    -- Rotated box, phase A: Space held claims this press to start the edge-drag - checked before
    -- everything else, same precedence as the shapes below.
    if self.spaceHeld and not self.rotBoxActive then
        self:beginRotBoxDrag()
        return
    end

    -- Rotated box, phase B: mid-sequence (edge already set, waiting for the third click) claims
    -- every press regardless of Space's state by now (see the design note above) - the press
    -- itself does nothing but stop the underlying tool's own click/drag firing underneath it; the
    -- real handling is on release (finishRotBoxSelect).
    if self.rotBoxActive then
        return
    end

    -- Reassigned 2026-09-21: Ctrl is now the ONE consistent "add to what I already have" layer,
    -- held on top of any of the shapes below (or alone, for a single point) - matching the
    -- CAD/creative-tool convention (Blender/Photoshop: Shift/modifier adds, base gesture picks
    -- the tool) rather than the file-manager one (Ctrl adds, nothing else needed) chosen for
    -- ergonomics (Ctrl+another key is easier to hold than Shift+another key). Alt/Shift/Alt+Shift
    -- now pick the SHAPE instead of Ctrl/Alt/Ctrl+Alt, freeing Ctrl for this.

    -- Alt+Shift together claims the drag for freehand selection - checked before either single
    -- modifier below, or it would never be reached. Box and Circle are the two simple shapes one
    -- modifier each picks; combining them picks the free-form one.
    if self.leftAltHeld and (self.leftShiftHeld or self.rightShiftHeld) then
        self.freehandActive = true
        self.freehandPoints = { { x = self.cursorX, z = self.cursorZ } }
        return
    end

    -- Alt alone claims the drag for box selection (view-aligned - see boxFrame). Not in the
    -- multi-point spline: there Alt means "place this point without snapping to a waypoint".
    if self.leftAltHeld and not (self.tool == self.TOOL.SPLINE and self:splineIsMultiPoint())
        and not (self.tool == self.TOOL.ROADRUNS and self.roadRuns ~= nil and self.roadRuns.sel ~= nil) then
        self.boxActive = true
        self.boxStartX, self.boxStartZ = self.cursorX, self.cursorZ
        return
    end

    -- Shift alone claims the drag for circle selection.
    if self.leftShiftHeld or self.rightShiftHeld then
        self.circleActive = true
        self.circleStartX, self.circleStartZ = self.cursorX, self.cursorZ
        return
    end

    -- Ctrl ALONE (none of the shapes above also held) no longer triggers any drag gesture of its
    -- own - it just toggles whichever single point you release on. Claimed here on press, same as
    -- the shapes above, so the underlying tool's own click/drag never fires underneath it; no
    -- drag-distance threshold needed since there is no shape being drawn to compare against.
    if self.leftCtrlHeld then
        self.ctrlToggleArmed = true
        return
    end

    -- Only the move tool cares about the press itself; every other tool acts on release, so that
    -- a click that turns out to be a camera drag does not commit an edit. Span is the exception:
    -- picking its two ends (and later replacing one) is a plain click, not a drag, so it is left
    -- for onLeftRelease/moveSpanClick - a press only ever begins a drag once the span already
    -- exists AND the hovered point is actually a member of it.
    -- Multi-point spline: a press on one of its points may become a drag of that point.
    if self.tool == self.TOOL.SPLINE and self.splineHoverIdx ~= nil and self:splineIsMultiPoint() then
        self:multiSplinePress()
        return
    end
    -- Road runs: a press on a handle of the selected run may become a drag of it.
    if self.tool == self.TOOL.ROADRUNS and self.roadRunsPress ~= nil and self:roadRunsPress() then
        return
    end

    if self.tool == self.TOOL.MOVE and self.hoverId ~= nil then
        -- An offset already awaiting its right-click commit owns this press: resume cursor-driven
        -- adjustment if the point is part of that SAME chain, otherwise ignore the press entirely
        -- rather than silently starting a different grab and abandoning the pending one without
        -- committing OR explicitly cancelling it.
        if self.moveOffsetChainIds ~= nil then
            local inChain = false
            for _, id in ipairs(self.moveOffsetChainIds) do
                if id == self.hoverId then inChain = true break end
            end
            if inChain then
                -- dragStartX/Z are not actually read by the offset path (offsetDistanceFromCursor
                -- only needs the cursor and moveOffsetBase), but updateDrag's very first line
                -- bails out whenever dragStartX is nil - set for that guard alone, same values
                -- beginDrag itself would set.
                local wp = ADGraphManager:getWayPointById(self.hoverId)
                self.dragId = self.hoverId
                self.dragStartX, self.dragStartZ = wp ~= nil and wp.x or self.cursorX,
                    wp ~= nil and wp.z or self.cursorZ
            else
                ADFlyoverSettings.debugLog("[FlyoverEditor]: an offset is still pending - right-click to finish it first.")
            end
            return
        end

        -- A pre-built selection (Ctrl-click/box/circle/freehand/rotated box) always wins over picks
        -- - see gatherDragNeighbours's own doc comment - but this gate was only ever checking
        -- Span's own two ends, so grabbing a box-selected point that happened not to be a span
        -- member did nothing at all, silently, while Span was active (reported 2026-09-21). Now
        -- also lets a drag start when the hovered point is in the selection, matching every other
        -- picks mode.
        -- The shared gesture language: a press only RECORDS the point. Moving past a small threshold
        -- while held starts the drag (update -> startMoveDrag); letting go without moving is a CLICK,
        -- which picks (point / second click = span / double-click = run - see moveGestureClick).
        self.movePressId = self.hoverId
        self.movePressMX, self.movePressMY = self.mouseX, self.mouseY
    end
end

--- Pixels (normalised screen units) the mouse must travel while held before a press becomes a drag.
ADFlyoverEditor.MOVE_DRAG_THRESHOLD = 0.006

--- The falloff reach for a span / run drag: the falloff value for Move's own picks, nil (taper to the
--- span's own ends) for a span or run handed over by a popup's "move".
function ADFlyoverEditor:moveReach()
    -- Settled 2026-09-26: a span, run or run-shaped selection always tapers to its own two ends. The
    -- adjustable reach is what a POINT pick with falloff is for (it walks along the run).
    return nil
end

--- A held press has moved far enough: start dragging, and decide WHAT moves from the current pick.
---   the point is in the selection      -> the selection (rigid)
---   the point is in the picked span/run -> that span / run
---   the type filter is locked to run    -> the run through the point
---   otherwise                           -> just that point (falloff applies); any old pick is dropped
function ADFlyoverEditor:startMoveDrag(id)
    self.movePressId = nil
    if id == nil then
        return
    end
    if self.selectionCount > 0 and self.selection[id] then
        self:beginDrag(id)
        return
    end
    if self.moveSpanIds ~= nil and self.moveSpanIds[id] then
        self.moveSelectMode = (self.pickKind == "run") and self.MOVE_SELECT.RUN or self.MOVE_SELECT.SPAN
        self:beginDrag(id)
        return
    end
    if self.pickFilter == "run" then
        self.moveSelectMode = self.MOVE_SELECT.RUN
        self.pickKind = "run"
        self:beginDrag(id)
        return
    end
    self.moveSpanFromId, self.moveSpanToId, self.moveSpanIds = nil, nil, nil
    self.movePickFromMenu = false
    self.moveSelectMode = self.MOVE_SELECT.POINT
    self.pickKind = "point"
    self:beginDrag(id)
end

--- A click (press + release without a drag) with the Move tool: the shared span-pick gesture, whose
--- result becomes what a following drag moves.
function ADFlyoverEditor:moveGestureClick(id)
    if id == nil then
        return
    end
    self.movePickFromMenu = false
    if self.pickFilter == "point" then
        self.moveSpanFromId, self.moveSpanToId, self.moveSpanIds = nil, nil, nil
        self.moveSelectMode = self.MOVE_SELECT.POINT
        self.pickKind = "point"
        return
    end
    local savedHover = self.hoverId
    self.hoverId = id
    self:spanPickClick({
        getFrom = function() return self.moveSpanFromId end,
        getTo = function() return self.moveSpanToId end,
        setEnds = function(a, b)
            self.moveSpanFromId, self.moveSpanToId = a, b
            if b == nil then
                self.moveSpanIds = nil
            end
        end,
        onSpan = function(a, b, span)
            local set = {}
            for _, sid in ipairs(span or {}) do set[sid] = true end
            self.moveSpanIds = set
        end,
    })
    self.hoverId = savedHover
    if self.moveSpanToId == nil then
        self.pickKind = (self.moveSpanFromId ~= nil) and "point" or nil
        self.moveSelectMode = self.MOVE_SELECT.POINT
    else
        self.moveSelectMode = (self.pickKind == "run") and self.MOVE_SELECT.RUN or self.MOVE_SELECT.SPAN
    end
end

--- Does what the Move tool would act on have any connection to the rest of the network? Disconnect is
--- meaningless (and greyed on the card) when it has none. The target is the selection, else the picked
--- span/run, else the point last pointed at (its run when locked to run). nil when there is nothing to judge.
function ADFlyoverEditor:moveTargetHasOutsideLinks()
    local set = {}
    if self.selectionCount > 0 then
        for id in pairs(self.selection) do set[id] = true end
    elseif self.moveSpanIds ~= nil then
        for id in pairs(self.moveSpanIds) do set[id] = true end
    elseif self.moveFocusId ~= nil then
        if self.pickFilter == "run" then
            local _, _, ids = self:resolveWholeRun(self.moveFocusId)
            for _, id in ipairs(ids or { self.moveFocusId }) do set[id] = true end
        else
            set[self.moveFocusId] = true
        end
    else
        return nil
    end
    local n = 0
    for id in pairs(set) do
        n = n + 1
        if n > 600 then return true end   -- big set: assume connected rather than walk it every frame
        local wp = ADGraphManager:getWayPointById(id)
        if wp ~= nil then
            for _, listName in ipairs(LINK_LISTS) do
                for _, other in pairs(linkList(wp, listName) or {}) do
                    if not set[other] then return true end
                end
            end
        end
    end
    return false
end

function ADFlyoverEditor:onLeftRelease()
    -- An armed popup owns interaction: a left click anywhere but on the popup (which the panel has
    -- already consumed) cancels back to Select, rather than letting the armed tool re-pick endpoints
    -- from the world. Apply is a right-click or the popup's own apply row.
    if self.ctxMenu ~= nil and self.ctxMenu.kind == "armed" then
        self:menuCancelArmed()
        ADFlyoverSettings.debugLog("[FlyoverEditor]: armed tool cancelled (clicked away).")
        return
    end

    if self.rotBoxDragging then
        self:finishRotBoxEdge()
        return
    end

    if self.rotBoxActive then
        self:finishRotBoxSelect(self.cursorX, self.cursorZ)
        self:openSetMenu()
        return
    end

    -- Ctrl builds a selection, whatever the tool. Selection is a shared substrate rather than a
    -- tool of its own: the multi-point operations all need it, so building one should not mean
    -- leaving the tool you are working with.
    if self.ctrlToggleArmed then
        self.ctrlToggleArmed = false
        -- On a multi-point spline's own point, Ctrl-click removes the point instead of selecting.
        if self.tool == self.TOOL.SPLINE and self:splineIsMultiPoint() and self:multiSplineRemoveAtCursor() then
            return
        end
        -- On a road run's handle, Ctrl-click removes the handle.
        if self.tool == self.TOOL.ROADRUNS and self.roadRunsRemoveHandleAtCursor ~= nil and self:roadRunsRemoveHandleAtCursor() then
            return
        end
        if self:chainToggleSelected(self.hoverId) then
            return
        end
        if self.hoverId ~= nil then
            -- A point clicked plainly first (its point menu is open) is the start of the selection: Ctrl-adding
            -- the next point keeps it, instead of silently dropping it.
            local m = self.ctxMenu
            if self.tool == self.TOOL.NONE and m ~= nil and m.kind == "point" and m.id ~= nil
                and m.id ~= self.hoverId and not self.selection[m.id] then
                self:toggleSelected(m.id)
            end
            self:toggleSelected(self.hoverId)
            -- In Select mode the selection popup takes over from whatever menu was open (a point menu from
            -- the first plain click), and follows the count; it closes when the last point is deselected.
            if self.tool == self.TOOL.NONE then
                if self.selectionCount >= 2 then
                    self:openSetMenu()
                elseif self.selectionCount == 1 then
                    -- One point left is a point pick, not a selection: show its point menu (a following
                    -- Ctrl-click picks it back up into a selection - see above).
                    local only = next(self.selection)
                    self:clearSelection()
                    self:openPointMenu(only, g_lastMousePosX or 0.5, g_lastMousePosY or 0.5)
                else
                    self:closeMenu()
                end
            end
            ADFlyoverSettings.debugLog("[FlyoverEditor]: %s waypoint id=%s (%d selected).",
                self.selection[self.hoverId] and "selected" or "deselected", tostring(self.hoverId), self.selectionCount)
        end
        return
    end

    if self.boxActive then
        self:finishBoxSelect()
        self:openSetMenu()
        return
    end

    if self.circleActive then
        self:finishCircleSelect()
        self:openSetMenu()
        return
    end

    if self.freehandActive then
        self:finishFreehandSelect()
        self:openSetMenu()
        return
    end

    if self.tool == self.TOOL.DRAW then
        self:drawClick()
    elseif self.tool == self.TOOL.MOVE then
        -- Released: a drag finishes; a press that never became a drag is a click, which picks.
        if self.dragId ~= nil then
            self:finishDrag()
        elseif self.movePressId ~= nil then
            self:moveGestureClick(self.movePressId)
        end
        self.movePressId = nil
    elseif self.tool == self.TOOL.DELETE then
        self:deleteAtCursor()
    elseif self.tool == self.TOOL.SMOOTH then
        self:smoothClick()
    elseif self.tool == self.TOOL.NAME then
        self:nameAtCursor()
    elseif self.tool == self.TOOL.SPLINE then
        if self:splineIsMultiPoint() then
            self:multiSplineRelease()
        else
            self:splineClick()
        end
    elseif self.tool == self.TOOL.MERGE then
        self:mergeClick()
    elseif self.tool == self.TOOL.FIELDLOOP then
        self:generateFieldLoopAtCursor()
    elseif self.tool == self.TOOL.CONVERT then
        self:convertToolClick()
    elseif self.tool == self.TOOL.SIDING then
        self:sidingClick()
    elseif self.tool == self.TOOL.PARALLEL then
        self:offsetClick()
    elseif self.tool == self.TOOL.GROUND then
        self:groundClick()
    elseif self.tool == self.TOOL.STRAIGHTEN then
        self:straightenClick()
    elseif self.tool == self.TOOL.DIVIDE then
        self:divideClick()
    elseif self.tool == self.TOOL.JUNCTION then
        self:junctionClick()
    elseif self.tool == self.TOOL.ROADRUNS then
        self:roadRunsClick()
    elseif self.tool == self.TOOL.NONE then
        self:selectClick()
    end
end

--- Right-click backs out one level at a time.
---
---   1st press - stop whatever the tool is doing: commit a preview, cancel a pending span, end a
---               run, drop a selection.
---   2nd press - leave the tool entirely, so no tool is selected and clicks do nothing.
---
--- The second press only counts after a pause. Without that, finishing a span and then
--- right-clicking again out of habit would drop the tool immediately, which is a surprising way to
--- lose your place. A deliberate "I am done here" is a separate press, not part of the same flurry.
function ADFlyoverEditor:onRightRelease()
    -- A right-click finishes an armed tool (apply), or dismisses a selection menu.
    if self.ctxMenu ~= nil then
        if self.ctxMenu.kind == "armed" then
            self:menuApplyArmed()
            ADFlyoverSettings.debugLog("[FlyoverEditor]: armed tool applied (right-click).")
        else
            self:closeMenu()
            ADFlyoverSettings.debugLog("[FlyoverEditor]: context menu closed (right-click).")
        end
        return
    end

    local now = self:nowMs()
    local sincePrevious = (self.lastRightPressAt ~= nil) and (now - self.lastRightPressAt) or nil
    self.lastRightPressAt = now

    if self:stopCurrentAction() then
        return
    end

    if self.selectionCount > 0 then
        self:clearSelection()
        ADFlyoverSettings.debugLog("[FlyoverEditor]: selection cleared.")
        return
    end

    if self.tool == self.TOOL.NONE then
        return
    end

    if sincePrevious == nil or sincePrevious < AutoDrive.FLYOVER_TOOL_EXIT_DELAY then
        -- Too soon to be deliberate. Say so, or it looks like right-click simply stopped working.
        ADFlyoverSettings.debugLog("[FlyoverEditor]: nothing in progress (%.0fms since the last right-click, need %.0fms) - press again to put the %s tool away.",
            sincePrevious or 0, AutoDrive.FLYOVER_TOOL_EXIT_DELAY, self.TOOL_NAMES[self.tool] or "current")
        return
    end

    ADFlyoverSettings.debugLog("[FlyoverEditor]: put the %s tool away; no tool selected.", self.TOOL_NAMES[self.tool] or "current")
    self:setTool(self.TOOL.NONE)
end

--- Milliseconds since the editor was opened.
---
--- Counted from the dt handed to update() rather than read from a global. The first version tried
--- g_currentMission.time, then g_time, then os.clock, and got none of them - so it returned a
--- constant 0, every interval computed as 0, and the "second press after a pause" could never
--- happen. Presses 4.8 seconds apart were still being told to wait.
---
--- dt is already delivered every frame and needs no engine field to exist, so it cannot fail the
--- same way.
function ADFlyoverEditor:nowMs()
    return self.elapsedMs or 0
end

--- Stop whatever the current tool has in progress. Returns true if there was something to stop.
function ADFlyoverEditor:stopCurrentAction()
    local tool = self.tool

    -- Delete with a selection: right-click is the apply.
    if tool == self.TOOL.DELETE and self.selectionCount > 0 then
        self:deleteSelection()
        return true
    end

    if tool == self.TOOL.DRAW then
        if self.lastWaypointId ~= nil then
            self:endRun()
            return true
        end
    elseif tool == self.TOOL.SIDING then
        if self.sidingAnchorId ~= nil then
            self:commitSiding()
            return true
        end
    elseif tool == self.TOOL.ROADRUNS then
        -- road runs (RoadRunsTool.lua): right-click builds what is picked
        if self:roadRunsStop() then
            return true
        end
    elseif tool == self.TOOL.MOVE then
        if self.moveOffsetChainIds ~= nil then
            self:commitMoveOffset()
            return true
        end
    elseif tool == self.TOOL.PARALLEL then
        if self.offsetToId ~= nil then
            self:commitOffset()
            return true
        elseif self.offsetFromId ~= nil then
            self:cancelOffset()
            return true
        end
    elseif tool == self.TOOL.GROUND then
        if self.groundToId ~= nil then
            self:commitGround()
            return true
        elseif self.groundFromId ~= nil then
            self:cancelGround()
            return true
        elseif self.groundUsesSelection and self.groundPreview ~= nil then
            self:commitGround()
            return true
        end
    elseif tool == self.TOOL.STRAIGHTEN then
        if self.straightenToId ~= nil then
            self:commitStraighten()
            return true
        elseif self.straightenFromId ~= nil then
            self:cancelStraighten()
            return true
        end
    elseif tool == self.TOOL.SMOOTH then
        if self.smoothToId ~= nil then
            self:commitSmooth()
            return true
        elseif self.smoothFromId ~= nil then
            self:cancelSmooth()
            return true
        end
    elseif tool == self.TOOL.SPLINE and self:multiSplinePending() then
        if #self.splinePoints >= 2 then
            self:commitMultiSpline()
        else
            self:cancelMultiSpline()
        end
        return true
    elseif tool == self.TOOL.SPLINE then
        if self.splineToId ~= nil then
            self:commitSplinePreview()
            return true
        elseif self.splineFromId ~= nil then
            self:cancelSplinePreview()
            return true
        end
    elseif tool == self.TOOL.DIVIDE then
        if self.divideToId ~= nil then
            self:commitDivide()
            return true
        elseif self.divideFromId ~= nil then
            self:cancelDivide()
            return true
        end
    elseif tool == self.TOOL.MERGE then
        if self:mergeWithOnlyCandidate() then
            return true
        end
        if self.mergeFromId ~= nil or self.mergeToId ~= nil then
            ADFlyoverSettings.debugLog("[FlyoverEditor]: cancelled the pending merge.")
            self.mergeFromId, self.mergeToId = nil, nil
            self.mergePreviewSpan, self.mergePreviewOther, self.mergePreviewQueryId = nil, nil, nil
            return true
        end
    elseif tool == self.TOOL.MOVE then
        if self.dragId ~= nil then
            self:finishDrag()
            return true
        end
    elseif tool == self.TOOL.JUNCTION then
        -- Armed site: right-click places what the preview shows; if it shows nothing new, the
        -- right-click just unlocks the site. Unarmed falls through, so the next right-click puts the
        -- tool away like any other - the way OUT of the tool without placing anything.
        if self.junctionArmed ~= nil then
            -- Placeable = new turns OR rebuilds of existing ones; clear mode's work is its wiring and
            -- links, or a junction that is one shared point (junctionHasWork says which).
            -- Clear + build (doc 12) clears and then builds on the same lock, under one undo.
            if self.junctionMode == "clear" and self.junctionThenBuild then
                if not self:applyJunctionClearThenBuild() then
                    ADFlyoverSettings.debugLog("[FlyoverEditor]: junction site unlocked (nothing to place).")
                end
            elseif self:junctionHasWork(self.junctionPreview) then
                self:applyJunction()
            else
                ADFlyoverSettings.debugLog("[FlyoverEditor]: junction site unlocked (nothing to place).")
            end
            self.junctionArmed = nil
            self.junctionPreview, self.junctionPreviewKey = nil, nil
            return true
        end
    end

    return false
end

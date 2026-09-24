--[[
Wrappers - the five fork edits that live inside AutoDrive's own source files, re-expressed as
runtime wrappers a guest mod can install.

Each of these replaces a function on AutoDrive's shared table. That works because the engine and
AutoDrive both reach these by a BY-NAME lookup at call time, never by a reference captured earlier:
specialization event listeners store the table and raiseEvent does spec[eventName](...), and
addModEventListener does the same for mouseEvent and draw. Measured in game: 226,211 interceptions
of onDrawUIInfo from outside AutoDrive.

MUST be installed AFTER the environment is resolved, never before. getfenv() on a function we have
already wrapped returns OUR environment rather than AutoDrive's, because the wrapper is defined
here - that was measured, and it silently breaks resolution.
]]

ADFlyoverWrappers = { installed = false }

local W = ADFlyoverWrappers

W.MOD_NAME = "ADFlyoverEditor"

-- Stage 3 has no editor to gate on, so a console command stands in for one. Once FlyoverEditor.lua
-- is present this falls through to the real thing and the fake is dead weight.
W.testActive = false

-- Whether something else is drawing the waypoint network right now. Until the proxy exists
-- (stage 4) the answer is no, and that decides whether wrapper 2 may fire at all - see below.
W.proxyOwnsNetwork = false

W.counts = {
    mouseSuppressed = 0,
    onDrawUIInfo = 0,   -- the open question: does this still raise once GuiTopDownCamera is active?
    drawHud = 0,        -- the independent fallback. If this climbs while onDrawUIInfo does not,
                        -- wrapper 2b is carrying the HUD suppression alone.
    editorShowForced = 0,
    wheelOffered = 0,
    topDownZoomOffered = 0,
    oldAutoDriveCurvature = 0,
}

W.hudWrapped = false
W.dialogWrapped = false

local function log(fmt, ...)
    Logging.info("[%s] " .. fmt, W.MOD_NAME, ...)
end

--- True while the flyover editor owns the screen. Reads the real editor when there is one, and the
--- stage-3 stand-in until then.
local function editorActive()
    if ADFlyoverEditor ~= nil then
        return ADFlyoverEditor.active == true
    end
    return W.testActive
end

W.editorActive = editorActive

function W.install(AD)
    if W.installed then
        return false
    end

    -- 1. Mouse. Without this every click is handled twice - once by a flyover tool and once by
    -- AutoDrive's own HUD and node editor, because AutoDrive's gate is satisfied by the flyover
    -- mode turning the mouse cursor on itself. It also fixes the spline tool outright: AutoDrive's
    -- handler clears splineInterpolation.valid on EVERY mouse event, including the right-click
    -- that was meant to commit the curve.
    local originalMouseEvent = AD.mouseEvent
    AD.mouseEvent = function(selfArg, ...)
        if editorActive() then
            W.counts.mouseSuppressed = W.counts.mouseSuppressed + 1
            AD.lastButtonDown = nil
            return
        end
        return originalMouseEvent(selfArg, ...)
    end

    -- 2. The vehicle-centred draw. This one is NOT the HUD wrapper, despite appearances, and
    -- getting that wrong cost a test cycle: onDrawUIInfo draws the HUD *and then* calls
    -- self:onDrawEditorMode(), which is the waypoint network. Returning early from it suppresses
    -- both. The fork skipped only the Hud:drawHud line inside the function and let the rest run;
    -- from outside a function cannot be half-suppressed, so wrapper 2b does the HUD surgically and
    -- this one exists purely to stop the network being drawn TWICE.
    --
    -- So it may only fire once something else is drawing the network - the proxy, from stage 4.
    -- Before that, suppressing here leaves nothing drawing it at all, and the editor shows an empty
    -- world. (Construction mode still worked in that state, because constructionScreenDraw calls
    -- onDrawEditorMode directly and never comes through here - which is what identified the bug.)
    --
    -- Whether this raises at all once GuiTopDownCamera is active is still unmeasured; AutoDrive
    -- works around exactly that for its construction screen. If it stops, the proxy still draws and
    -- 2b still hides the HUD, so nothing load-bearing is lost either way.
    local originalOnDrawUIInfo = AD.onDrawUIInfo
    AD.onDrawUIInfo = function(vehicle, ...)
        if editorActive() and W.proxyOwnsNetwork then
            W.counts.onDrawUIInfo = W.counts.onDrawUIInfo + 1
            return
        end
        return originalOnDrawUIInfo(vehicle, ...)
    end

    -- 2b. The same job, independently. AutoDrive.Hud is built inside AutoDrive's own loadMap, which
    -- is why arming happens from an update tick rather than ours - by then it exists.
    if AD.Hud ~= nil and type(AD.Hud.drawHud) == "function" then
        local originalDrawHud = AD.Hud.drawHud
        AD.Hud.drawHud = function(hudSelf, ...)
            if editorActive() then
                W.counts.drawHud = W.counts.drawHud + 1
                return
            end
            originalDrawHud(hudSelf, ...)
            -- The launch button rides on this call because it is the one place that runs exactly
            -- when AutoDrive's HUD is on screen, with the HUD instance in hand - so the button is
            -- positioned from this frame's layout and vanishes whenever the HUD does. Guarded, so a
            -- fault in our button can never cost the player AutoDrive's HUD.
            if ADFlyoverLaunch ~= nil then
                pcall(ADFlyoverLaunch.drawHudButton, hudSelf)
            end
        end
        W.hudWrapped = true
    else
        Logging.warning("[%s] AutoDrive.Hud was not built yet - the vehicle HUD may show through "
            .. "the flyover panel. Worth reporting with your mod load order.", W.MOD_NAME)
    end

    -- 3. Network rendering. AutoDrive gates its editor drawing on this, and reads it fresh at every
    -- call site, so replacing it here is enough. Called with no self at all -
    -- AutoDrive.isEditorShowEnabled() - hence the bare vararg.
    local originalIsEditorShow = AD.isEditorShowEnabled
    AD.isEditorShowEnabled = function(...)
        if editorActive() then
            W.counts.editorShowForced = W.counts.editorShowForced + 1
            return true
        end
        return originalIsEditorShow(...)
    end

    -- 4. The mouse wheel. This is the only hook that can take the wheel away from the camera zoom -
    -- both zoomSmoothly and onZoomTopDownCamera skip zooming when it returns true - so any flyover
    -- tool that wants the wheel has to come through here.
    --
    -- Note the editor gets first refusal, not unconditional ownership: when it declines, or when
    -- there is no editor yet as in stage 3, the wheel falls through and still zooms.
    local originalHandleSplineCurvature = AD.handleSplineCurvature
    -- Captured BEFORE the overwrite two lines down, which is unconditional and runs regardless of
    -- AutoDrive's version - so by the time wrapper 5 below would otherwise ask "does
    -- AD.handleSplineCurvature exist", the answer is always yes, because THIS assignment just put
    -- it there. That is not "does AutoDrive support this", it is "did wrapper 4 run" - always true -
    -- and it is exactly why the old-AutoDrive curvature fallback never fired even though wrapper 5
    -- was installed correctly: it was checking its own sibling wrapper's handiwork. This flag is the
    -- real answer, fixed at install time from what AD.handleSplineCurvature was BEFORE we touched it.
    local hadRealHandleSplineCurvature = (originalHandleSplineCurvature ~= nil)
    AD.handleSplineCurvature = function(selfArg, offset, ...)
        if editorActive() and ADFlyoverEditor ~= nil and ADFlyoverEditor.handleWheel ~= nil then
            W.counts.wheelOffered = W.counts.wheelOffered + 1
            if ADFlyoverEditor:handleWheel(offset) then
                return true
            end
            -- The editor declined, so this wheel is the camera's. The original ends in
            -- `return AutoDrive.mouseWheelActive` - AutoDrive's HUD flag, which is frozen at its
            -- entry value while the editor mutes AutoDrive's mouse handler (wrapper 1). A stale true
            -- there made every declined wheel "handled" and the flyover camera unzoomable. The flag
            -- is meaningless while the editor owns the mouse, so clear it before delegating; the
            -- spline-curvature path inside the original still gets its turn.
            AD.mouseWheelActive = false
        end
        return originalHandleSplineCurvature(selfArg, offset, ...)
    end

    -- 5. GuiTopDownCamera.onZoom, wrapped DIRECTLY - not just trusted to reach wrapper 4 above.
    --
    -- Wrapper 4 patches AD.handleSplineCurvature and relies entirely on AutoDrive itself calling it
    -- by name from GuiTopDownCamera.onZoom (AutoDrive.onZoomTopDownCamera). Checked across every
    -- AutoDrive release from 3.0.0.0 to 3.0.1.2: that wiring - onZoomTopDownCamera, and
    -- handleSplineCurvature itself - was only ADDED at 3.0.0.8. On 3.0.0.6 and earlier, AutoDrive
    -- never touches GuiTopDownCamera.onZoom at all (only VehicleCamera.zoomSmoothly, for the
    -- in-vehicle camera, which the flyover camera is not), so wrapper 4 patches a function nothing
    -- ever calls, ADFlyoverEditor:handleWheel is never reached through the flyover camera's own
    -- zoom, and EVERY tool's wheel behaviour - not just spline curvature - goes dead the moment our
    -- own top-down camera is the one doing the zooming. This is what a customer on an old AutoDrive
    -- reported as "the wheel isn't working on the spline tool" and a fresh install (3.0.0.8+) could
    -- not reproduce.
    --
    -- Hooking the base-game method ourselves removes that dependency: ADFlyoverEditor:handleWheel
    -- gets first refusal here regardless of what AutoDrive did or did not wire up. When AutoDrive's
    -- own handleSplineCurvature exists (3.0.0.8+, wrapped or not), a decline here just falls through
    -- to it exactly as before - wrapper 4 still does the real work, this is a no-op alongside it.
    -- Only when handleSplineCurvature does not exist at all (old AutoDrive) does this do the
    -- curvature math itself, using AutoDrive's own formula and clamp - unchanged across every
    -- release checked - so the feature works instead of silently depending on a hook that was never
    -- there.
    if GuiTopDownCamera ~= nil and type(GuiTopDownCamera.onZoom) == "function"
        and type(Utils) == "table" and type(Utils.overwrittenFunction) == "function" then
        GuiTopDownCamera.onZoom = Utils.overwrittenFunction(GuiTopDownCamera.onZoom,
            function(cameraSelf, superFunc, action, offset, ...)
                if editorActive() and ADFlyoverEditor ~= nil and ADFlyoverEditor.handleWheel ~= nil then
                    W.counts.topDownZoomOffered = W.counts.topDownZoomOffered + 1
                    -- onZoomTopDownCamera calls handleSplineCurvature(-offset); match that sign so
                    -- curvature turns the same way here as it does on a version new enough to reach
                    -- wrapper 4's copy of this same math.
                    if ADFlyoverEditor:handleWheel(-offset) then
                        return
                    end
                    if not hadRealHandleSplineCurvature then
                        if AutoDrive.splineInterpolation ~= nil and AutoDrive.splineInterpolation.valid then
                            W.counts.oldAutoDriveCurvature = W.counts.oldAutoDriveCurvature + 1
                            AutoDrive.splineInterpolationUserCurvature = math.clamp(
                                (AutoDrive.splineInterpolationUserCurvature or AutoDrive.FLYOVER_DEFAULT_CURVATURE or 1.5)
                                    - offset / 12, 0.49, 3.5)
                            return
                        end
                        AD.mouseWheelActive = false
                    end
                end
                return superFunc(cameraSelf, action, offset, ...)
            end)
        W.topDownZoomWrapped = true
    end

    -- 6. The proxy's ride. AutoDrive.draw is a mod event listener, so the engine looks it up by
    -- name on this table every frame. Queueing the cursor-centred network here means it lands in
    -- ADDrawingManager immediately before AutoDrive's own flush on the next line - so we never have
    -- to reach ADDrawingManager, which is another global inside AutoDrive's environment.
    local originalDraw = AD.draw
    AD.draw = function(selfArg, ...)
        if editorActive() and ADFlyoverProxy ~= nil then
            ADFlyoverProxy.run()
        end
        return originalDraw(selfArg, ...)
    end

    -- 6b. Marker-name labels bleeding through the editor's panels. AutoDrive draws map-marker names in
    -- the world with Utils.renderTextAtWorldPosition (Specialization.lua onDrawEditorMode). The engine
    -- composites text in a pass no overlay can cover, so a named waypoint sitting behind the tool
    -- panel, the floating card or the help card showed its name straight through them - the "waypoint
    -- label showing through" the panels. While the flyover editor is active, drop a label whose
    -- projected screen point lands on one of those surfaces; every other label draws exactly as before.
    -- Guarded end to end: if the projection or the hit test throws, the original still runs, so this can
    -- never cost AutoDrive its text. Global, but gated on editorActive(), so it is inert when closed.
    if type(Utils) == "table" and type(Utils.renderTextAtWorldPosition) == "function"
        and not W.worldTextWrapped then
        local originalRenderTextAtWorldPosition = Utils.renderTextAtWorldPosition
        Utils.renderTextAtWorldPosition = function(x, y, z, ...)
            if editorActive() and ADFlyoverHud ~= nil and type(ADFlyoverHud.coversPoint) == "function" then
                local ok, hidden = pcall(function()
                    local sx, sy, sz = project(x, y, z)
                    return sz ~= nil and sz <= 1 and ADFlyoverHud:coversPoint(sx, sy)
                end)
                if ok and hidden then
                    return
                end
            end
            return originalRenderTextAtWorldPosition(x, y, z, ...)
        end
        W.worldTextWrapped = true
    end

    -- 7. The name dialog. The fork made this work by EDITING AutoDrive's own EnterTargetNameGUI.lua
    -- so that onOpen and onClickOk honour an overrideWayPointId set from outside. Stock AutoDrive
    -- has no such code, so setting that field does nothing and the dialog silently falls back to
    -- "the waypoint nearest the controlled vehicle" - or, with the flyover camera detached from any
    -- vehicle, to nothing at all.
    --
    -- Reproduced here as wrappers on the dialog class. GUI methods are reached through the
    -- instance's metatable, so replacing them on the class intercepts, the same as everywhere else.
    local Dialog = ADEnterTargetNameGui
    if Dialog ~= nil and type(Dialog.onOpen) == "function" and type(Dialog.onClickOk) == "function" then
        -- Point an open dialog instance at the clicked waypoint: edit the marker already on it, or
        -- create a new one there. Public on the class because the editor ALSO calls it straight after
        -- showDialog: the dialog's XML binds onOpen/onClickOk when the screen loads, and whether that
        -- binding sees a later replacement on the class is the engine's business - so the state is
        -- set on the instance directly rather than trusting the wrapper to have run.
        Dialog.applyFlyoverOverride = function(dialogSelf)
            local overrideId = Dialog.overrideWayPointId
            if dialogSelf == nil or overrideId == nil then
                return
            end
            dialogSelf.editId, dialogSelf.editName, dialogSelf.edit = nil, nil, false
            for i, marker in pairs(ADGraphManager:getMapMarkers()) do
                if marker.id == overrideId then
                    dialogSelf.editId, dialogSelf.editName, dialogSelf.edit = i, marker.name, true
                    break
                end
            end
            if dialogSelf.titleElement ~= nil then
                -- The title strings live in AutoDrive's own l10n. Asked from this mod, g_i18n looks in
                -- OUR translations and shows "Missing 'gui_ad_...' in l10n_en.xml" - so name AutoDrive's
                -- mod explicitly, and fall back to plain English rather than ever showing a raw key.
                local key = dialogSelf.edit and "gui_ad_enterTargetNameTitle_edit" or "gui_ad_enterTargetNameTitle_add"
                local title
                for _, modName in ipairs({ "FS25_AutoDrive", (AutoDrive ~= nil and AutoDrive.modName) or nil }) do
                    local ok, text = pcall(g_i18n.getText, g_i18n, key, modName)
                    if ok and type(text) == "string" and text ~= "" and not text:lower():find("^missing") then
                        title = text
                        break
                    end
                end
                dialogSelf.titleElement:setText(title or (dialogSelf.edit and "Edit target name" or "Add target name"))
            end
            if dialogSelf.textInputElement ~= nil then
                dialogSelf.textInputElement:setText(dialogSelf.edit and dialogSelf.editName or "")
            end
            if dialogSelf.buttonsCreateElement ~= nil then
                dialogSelf.buttonsCreateElement:setVisible(not dialogSelf.edit)
            end
            if dialogSelf.buttonsEditElement ~= nil then
                dialogSelf.buttonsEditElement:setVisible(dialogSelf.edit)
            end
            -- New name: caret in the field so typing starts at once. Stock activates it in onOpen; only
            -- do it again if it is NOT already capturing input, and never touch the focus manager - an
            -- earlier attempt (both together) made the dialog not appear at all.
            -- Renaming a name that already exists: leave the field UNfocused. A focused text box
            -- swallows Space (and every other key), so the dialog's own Delete key could not clear the
            -- name; unfocused, Space reaches the buttons and the name can be deleted at once. Click the
            -- field to edit the text.
            local input = dialogSelf.textInputElement
            if input ~= nil then
                if dialogSelf.edit then
                    if input.isCapturingInput then
                        pcall(function() input:onFocusLeave() end)
                    end
                elseif not input.isCapturingInput then
                    pcall(function()
                        input.blockTime = 0
                        input:onFocusActivate()
                    end)
                end
                log("name dialog field: %s, capturing input = %s", dialogSelf.edit and "rename (left unfocused)" or "new name (focused)",
                    tostring(input.isCapturingInput))
            end
            log("name dialog aimed at waypoint id=%s (%s)", tostring(overrideId),
                dialogSelf.edit and "rename" or "new marker")
        end

        local originalOnOpen = Dialog.onOpen
        Dialog.onOpen = function(dialogSelf, ...)
            local result = originalOnOpen(dialogSelf, ...)
            Dialog.applyFlyoverOverride(dialogSelf)
            return result
        end

        -- Duplicate names: two markers called "Hof" sit side by side in every destination list, a
        -- rename looks like it "did not take" (the other one was edited), and a vehicle sent "to Hof"
        -- goes to whichever the list found first. Names are trimmed and compared case-insensitively.
        -- `exceptIndex` is the marker being renamed, which may keep its own name (or change its case).
        local function findDuplicate(manager, name, exceptIndex)
            local lower = name:lower()
            for index, marker in pairs(manager:getMapMarkers()) do
                if index ~= exceptIndex and marker.name ~= nil and marker.name:lower() == lower then
                    return marker
                end
            end
            return nil
        end
        local function refuseDuplicate(marker)
            Logging.warning("[%s] a destination named '%s' already exists (waypoint id=%s) - not applying. Pick another name.",
                W.MOD_NAME, marker.name, tostring(marker.id))
            -- On-screen, because the dialog closes either way and silence reads as "it did nothing".
            if g_currentMission ~= nil and g_currentMission.showBlinkingWarning ~= nil then
                pcall(g_currentMission.showBlinkingWarning, g_currentMission,
                    string.format("'%s' is already a destination name - pick another", marker.name), 4000)
            end
        end

        -- Stock's create path is createMapMarkerOnClosest(controlledVehicle, name): a marker on
        -- whatever waypoint is nearest the VEHICLE, wherever it happens to be parked. That call is a
        -- by-name lookup at call time, so redirecting it works however the OK button got bound.
        local originalCreateOnClosest = ADGraphManager.createMapMarkerOnClosest
        if type(originalCreateOnClosest) == "function" then
            ADGraphManager.createMapMarkerOnClosest = function(manager, vehicle, name, ...)
                local overrideId = Dialog.overrideWayPointId
                if overrideId == nil then
                    return originalCreateOnClosest(manager, vehicle, name, ...)
                end
                local text = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
                local duplicate = findDuplicate(manager, text, nil)
                if duplicate ~= nil then
                    return refuseDuplicate(duplicate)
                end
                if text:len() >= 1 then
                    log("new marker '%s' on clicked waypoint id=%s (not the vehicle's nearest)", text, tostring(overrideId))
                    return manager:createMapMarker(overrideId, text)
                end
            end
        end

        -- The rename path had no duplicate check at all. Only the player's own call is guarded
        -- (sendEvent nil/true); the same call arriving from the network event carries false and must
        -- always apply, or clients and server would disagree about the name.
        local originalRename = ADGraphManager.renameMapMarker
        if type(originalRename) == "function" then
            ADGraphManager.renameMapMarker = function(manager, newName, markerId, sendEvent, ...)
                if (sendEvent == nil or sendEvent == true) and type(newName) == "string" and markerId ~= nil then
                    local text = newName:gsub("^%s+", ""):gsub("%s+$", "")
                    -- A blank name (empty, or only spaces) is how you clear one: stock ignores an
                    -- empty rename, and a lone space used to slip through as an invisible destination.
                    -- Treat it as removing the marker, the same as the dialog's Delete button.
                    if text == "" then
                        log("blank rename on marker %s - removing the marker", tostring(markerId))
                        return manager:removeMapMarker(markerId)
                    end
                    local duplicate = findDuplicate(manager, text, markerId)
                    if duplicate ~= nil then
                        return refuseDuplicate(duplicate)
                    end
                    newName = text
                end
                return originalRename(manager, newName, markerId, sendEvent, ...)
            end
        end

        local originalOnClickOk = Dialog.onClickOk
        Dialog.onClickOk = function(dialogSelf, ...)
            local overrideId = Dialog.overrideWayPointId
            if overrideId ~= nil and not dialogSelf.edit then
                -- Stock would call createMapMarkerOnClosest, which needs a controlled vehicle and
                -- would put the marker somewhere other than where the user clicked.
                local text = dialogSelf.textInputElement ~= nil and dialogSelf.textInputElement.text or ""
                text = text:gsub("^%s+", ""):gsub("%s+$", "")
                local duplicate = findDuplicate(ADGraphManager, text, nil)
                if duplicate ~= nil then
                    refuseDuplicate(duplicate)
                    Dialog.overrideWayPointId = nil
                    if dialogSelf.superClass ~= nil then
                        return dialogSelf:onClickBack()
                    end
                    return
                end
                if text:len() >= 1 then
                    ADGraphManager:createMapMarker(overrideId, text)
                end
                Dialog.overrideWayPointId = nil
                if dialogSelf.superClass ~= nil then
                    return dialogSelf:onClickBack()
                end
                return
            end
            Dialog.overrideWayPointId = nil
            return originalOnClickOk(dialogSelf, ...)
        end

        -- However the dialog is dismissed, drop the override, so a later open from a vehicle is not
        -- still aimed at a waypoint clicked minutes ago.
        local originalOnClose = Dialog.onClose
        Dialog.onClose = function(dialogSelf, ...)
            Dialog.overrideWayPointId = nil
            if originalOnClose ~= nil then
                return originalOnClose(dialogSelf, ...)
            end
        end
        W.dialogWrapped = true
    else
        Logging.warning("[%s] the name dialog could not be wrapped - the NAME tool will name the "
            .. "wrong waypoint, or nothing at all.", W.MOD_NAME)
    end

    W.installed = true
    log("wrappers installed: mouseEvent, onDrawUIInfo, %sisEditorShowEnabled, handleSplineCurvature, %sdraw%s",
        W.hudWrapped and "Hud.drawHud, " or "", W.topDownZoomWrapped and "GuiTopDownCamera.onZoom, " or "",
        W.dialogWrapped and ", EnterTargetNameGui" or "")
    return true
end

function W.describe()
    return string.format(
        "installed=%s hudWrapped=%s topDownZoomWrapped=%s active=%s proxyOwnsNetwork=%s | mouse %d, onDrawUIInfo %d, drawHud %d, editorShow %d, wheel %d, topDownZoom %d, oldADCurvature %d",
        tostring(W.installed), tostring(W.hudWrapped), tostring(W.topDownZoomWrapped), tostring(editorActive()), tostring(W.proxyOwnsNetwork),
        W.counts.mouseSuppressed, W.counts.onDrawUIInfo, W.counts.drawHud,
        W.counts.editorShowForced, W.counts.wheelOffered, W.counts.topDownZoomOffered, W.counts.oldAutoDriveCurvature)
end

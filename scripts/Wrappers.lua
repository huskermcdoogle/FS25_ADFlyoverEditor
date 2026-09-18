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
    AD.handleSplineCurvature = function(selfArg, offset, ...)
        if editorActive() and ADFlyoverEditor ~= nil and ADFlyoverEditor.handleWheel ~= nil then
            W.counts.wheelOffered = W.counts.wheelOffered + 1
            if ADFlyoverEditor:handleWheel(offset) then
                return true
            end
        end
        return originalHandleSplineCurvature(selfArg, offset, ...)
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
        local originalOnOpen = Dialog.onOpen
        Dialog.onOpen = function(dialogSelf, ...)
            local result = originalOnOpen(dialogSelf, ...)
            local overrideId = Dialog.overrideWayPointId
            if overrideId ~= nil then
                -- Same two cases stock has, just sourced from the click instead of the vehicle:
                -- edit the marker already on that waypoint, or create a new one there.
                dialogSelf.editId, dialogSelf.editName, dialogSelf.edit = nil, nil, false
                for i, marker in pairs(ADGraphManager:getMapMarkers()) do
                    if marker.id == overrideId then
                        dialogSelf.editId, dialogSelf.editName, dialogSelf.edit = i, marker.name, true
                        break
                    end
                end
                -- onOpen already set the title, text and button rows from ITS answer; redo them now
                -- that ours has replaced it.
                if dialogSelf.titleElement ~= nil then
                    dialogSelf.titleElement:setText(g_i18n:getText(dialogSelf.edit
                        and "gui_ad_enterTargetNameTitle_edit" or "gui_ad_enterTargetNameTitle_add"))
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
            end
            return result
        end

        local originalOnClickOk = Dialog.onClickOk
        Dialog.onClickOk = function(dialogSelf, ...)
            local overrideId = Dialog.overrideWayPointId
            if overrideId ~= nil and not dialogSelf.edit then
                -- Stock would call createMapMarkerOnClosest, which needs a controlled vehicle and
                -- would put the marker somewhere other than where the user clicked.
                local text = dialogSelf.textInputElement ~= nil and dialogSelf.textInputElement.text or ""
                -- Duplicate-name guard. AutoDrive's createMapMarker accepts ANY name: two markers
                -- called "Hof" then sit side by side in every destination list, renaming one looks
                -- like the rename "did not take" (the other was edited), and a vehicle sent "to Hof"
                -- goes to whichever the list found first - the reported naming weirdness. Trimmed
                -- (a trailing space made look-alike duplicates) and compared case-insensitively;
                -- a duplicate is refused with the existing marker's location in the log.
                text = text:gsub("^%s+", ""):gsub("%s+$", "")
                local lower = text:lower()
                for _, marker in pairs(ADGraphManager:getMapMarkers()) do
                    if marker.name ~= nil and marker.name:lower() == lower then
                        Logging.warning("[%s] a destination named '%s' already exists (waypoint id=%s) - not creating a duplicate. Pick another name, or rename the existing one.",
                            W.MOD_NAME, marker.name, tostring(marker.id))
                        Dialog.overrideWayPointId = nil
                        if dialogSelf.superClass ~= nil then
                            return dialogSelf:onClickBack()
                        end
                        return
                    end
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
    log("wrappers installed: mouseEvent, onDrawUIInfo, %sisEditorShowEnabled, handleSplineCurvature, draw%s",
        W.hudWrapped and "Hud.drawHud, " or "", W.dialogWrapped and ", EnterTargetNameGui" or "")
    return true
end

function W.describe()
    return string.format(
        "installed=%s hudWrapped=%s active=%s proxyOwnsNetwork=%s | mouse %d, onDrawUIInfo %d, drawHud %d, editorShow %d, wheel %d",
        tostring(W.installed), tostring(W.hudWrapped), tostring(editorActive()), tostring(W.proxyOwnsNetwork),
        W.counts.mouseSuppressed, W.counts.onDrawUIInfo, W.counts.drawHud,
        W.counts.editorShowForced, W.counts.wheelOffered)
end

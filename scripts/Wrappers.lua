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
            return originalDrawHud(hudSelf, ...)
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

    W.installed = true
    log("wrappers installed: mouseEvent, onDrawUIInfo, %sisEditorShowEnabled, handleSplineCurvature",
        W.hudWrapped and "Hud.drawHud, " or "")
    return true
end

function W.describe()
    return string.format(
        "installed=%s hudWrapped=%s active=%s proxyOwnsNetwork=%s | mouse %d, onDrawUIInfo %d, drawHud %d, editorShow %d, wheel %d",
        tostring(W.installed), tostring(W.hudWrapped), tostring(editorActive()), tostring(W.proxyOwnsNetwork),
        W.counts.mouseSuppressed, W.counts.onDrawUIInfo, W.counts.drawHud,
        W.counts.editorShowForced, W.counts.wheelOffered)
end

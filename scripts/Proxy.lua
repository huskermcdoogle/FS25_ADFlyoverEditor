--[[
Proxy - drawing AutoDrive's waypoint network around the cursor instead of around the vehicle,
without copying AutoDrive's ~300 lines of drawing code.

The problem. AutoDrive:onDrawEditorMode takes its centre from locals:

    local startNode = self.components[1].node
    local x, y, z = getWorldTranslation(startNode)

Locals cannot be reached from outside, and the function is registered with registerFunction, which
copies the POINTER - so replacing it afterwards would not intercept the registered call either.

The way round. Don't fight the locals; change what `self` is. Across that whole function `self` is
touched only as `self.ad` (state, read and written), four specialization functions, and
`self.components` exactly ONCE, on the line above. So hand it a stand-in whose components[1].node
sits at the cursor and let __index send everything else to the real vehicle - state is then read and
written exactly where AutoDrive expects it. AutoDrive already calls the function this way itself, in
constructionScreenDraw, with an explicit self.

Measured in game by the earlier spike: 4,813 calls with this stand-in, zero errors, network rendered
at the cursor in AutoDrive's own colours.

Why it rides AutoDrive.draw rather than doing its own flush: ADDrawingManager is another global in
AutoDrive's environment, and queueing immediately before AutoDrive's own flush means we never need
to reach it. AutoDrive.draw is a mod event listener, so the engine looks it up by name each frame
and the wrapper intercepts.
]]

ADFlyoverProxy = {}

local X = ADFlyoverProxy

X.MOD_NAME = "ADFlyoverEditor"

X.enabled = false
X.cursorX = nil
X.cursorZ = nil
X.cursorNode = nil
X.draws = 0
X.drewThisFrame = false
X.lastError = nil
X.showMarker = true

local function log(fmt, ...)
    Logging.info("[%s] " .. fmt, X.MOD_NAME, ...)
end

local function terrainHeight(x, z)
    local AD = ADFlyoverArming.autoDrive
    if AD ~= nil and type(AD.getTerrainHeightAtWorldPos) == "function" then
        local ok, y = pcall(AD.getTerrainHeightAtWorldPos, AD, x, z)
        if ok and type(y) == "number" then
            return y
        end
    end
    if g_currentMission ~= nil and g_currentMission.terrainRootNode ~= nil then
        return getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 0, z)
    end
    return 0
end

local function ensureCursorNode()
    if X.cursorNode == nil or not entityExists(X.cursorNode) then
        X.cursorNode = createTransformGroup("adFlyoverCursor")
        link(getRootNode(), X.cursorNode)
    end
    return X.cursorNode
end

function X.setCursor(x, z)
    X.cursorX, X.cursorZ = x, z
    setWorldTranslation(ensureCursorNode(), x, terrainHeight(x, z), z)
end

function X.clear()
    X.enabled = false
    X.drewThisFrame = false
    ADFlyoverWrappers.proxyOwnsNetwork = false
end

--- Any vehicle carrying AutoDrive state will do: the stand-in borrows its .ad tables and its
--- specialization functions, never its position.
local function findHostVehicle()
    local AD = ADFlyoverArming.autoDrive
    if AD == nil then
        return nil
    end
    local controlled = AD.getControlledVehicle()
    if controlled ~= nil and controlled.ad ~= nil and controlled.ad.stateModule ~= nil then
        return controlled
    end
    for _, vehicle in pairs(AD.getAllVehicles()) do
        if vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil then
            return vehicle
        end
    end
    return nil
end

--- components[1].node is the ONLY field overridden. Everything else - self.ad and the four
--- specialization functions - falls through to the real vehicle.
local function buildStandIn(vehicle)
    return setmetatable({ components = { { node = X.cursorNode } } }, { __index = vehicle })
end

--- Called from inside the wrapper on AutoDrive's own draw(), so whatever this queues is flushed by
--- AutoDrive on the very next line.
--- The editor owns the cursor once it is open; the manual cursor is only for testing before it
--- exists. This is the job the fork did by editing onDrawEditorMode to read ADFlyoverEditor.cursorX
--- directly - a companion cannot edit that function, so it feeds the position in through the
--- stand-in instead.
local function activeCursor()
    if ADFlyoverEditor ~= nil and ADFlyoverEditor.active and ADFlyoverEditor.cursorX ~= nil then
        return ADFlyoverEditor.cursorX, ADFlyoverEditor.cursorZ
    end
    return X.cursorX, X.cursorZ
end

--- Will the proxy draw AutoDrive's network this frame?
---
--- A PREDICATE, deliberately, not a "did it happen" flag. Our mod's listener is registered before
--- AutoDrive's - measured from the load order - so our draw() runs BEFORE AutoDrive.draw, which is
--- where the proxy runs. Anything asking "has the proxy drawn yet" is therefore always told no, and
--- the editor's fallback renderer drew its own network every frame on top of AutoDrive's. Two
--- networks, ours above theirs. A predicate has no ordering to get wrong.
function X.willDraw()
    if ADFlyoverEditor ~= nil and ADFlyoverEditor.active and ADFlyoverEditor.cursorX ~= nil then
        return findHostVehicle() ~= nil
    end
    if X.enabled and X.cursorX ~= nil then
        return findHostVehicle() ~= nil
    end
    return false
end

function X.run()
    local cx, cz = activeCursor()
    local wanted = X.enabled or (ADFlyoverEditor ~= nil and ADFlyoverEditor.active)
    if not wanted or cz == nil then
        -- Hand the network back on the way out. Leaving proxyOwnsNetwork true after the editor
        -- closes is stale state that reads as a fault in the next diagnosis.
        ADFlyoverWrappers.proxyOwnsNetwork = false
        return
    end
    X.cursorX, X.cursorZ = cx, cz

    local vehicle = findHostVehicle()
    if vehicle == nil then
        -- Nothing to borrow state from. Hand the network back rather than leaving the world empty.
        ADFlyoverWrappers.proxyOwnsNetwork = false
        return
    end

    -- Only now may wrapper 2 suppress the vehicle-centred draw: something else is drawing it.
    ADFlyoverWrappers.proxyOwnsNetwork = true

    local ok, err = pcall(function()
        X.setCursor(X.cursorX, X.cursorZ)
        local standIn = buildStandIn(vehicle)
        local AD = ADFlyoverArming.autoDrive

        -- Re-point the borrowed vehicle's in-range list at the CURSOR, every frame.
        --
        -- AutoDrive:getWayPointsInRange caches its result on vehicle.ad.wayPointsInRange and only
        -- rebuilds when that field is nil. The one thing that clears it is updateWayPointsDistance,
        -- called from the vehicle's own update - so a vehicle nobody is driving never clears it.
        --
        -- That is what made waypoints laid on foot invisible: the write was fine, but the borrowed
        -- vehicle's cache was built before them and never rebuilt, so the draw walked a list the new
        -- points were not in. Established network drew; anything new did not; getting into the truck
        -- updated that vehicle and everything appeared at once.
        --
        -- Passing the cursor position does double duty - it clears the stale cache AND builds the
        -- new one around what is being looked at rather than around a vehicle that may be a
        -- kilometre away, which is the same re-centring the stand-in does for the draw itself.
        if type(vehicle.updateWayPointsDistance) == "function" then
            vehicle:updateWayPointsDistance(X.cursorX, X.cursorZ)
        else
            -- No such function on this build: at least drop the cache so it is rebuilt, even if it
            -- is rebuilt around the vehicle.
            if vehicle.ad ~= nil then
                vehicle.ad.wayPointsInRange = nil
            end
        end

        -- While a modal (the browsable manual or the settings dialog) is up, draw NEITHER. We keep
        -- proxyOwnsNetwork true above so AutoDrive's own vehicle-centred draw stays suppressed - the
        -- world just goes quiet behind the modal - but we skip our own editor draw so its waypoint
        -- labels, ids and the editor cursor are not queued as text on top of the page. Engine text
        -- composites in a pass an overlay cannot cover, so the only way to keep it off a modal is not
        -- to draw it (the editor's own network draw and panel are skipped for the same reason).
        local modalUp = ADFlyoverEditor ~= nil and type(ADFlyoverEditor.isModalOpen) == "function"
            and ADFlyoverEditor:isModalOpen()
        if not modalUp then
            AD.onDrawEditorMode(standIn)
            -- AutoDrive draws these as a PAIR - onDrawUIInfo calls onDrawEditorMode and then
            -- onDrawPreviews, under the same condition. Suppressing onDrawUIInfo takes both away, so
            -- calling only the first left the spline tool placing curves that were never drawn, and a
            -- curvature wheel with nothing on screen to show its effect. Same stand-in, same reason.
            if type(AD.onDrawPreviews) == "function" then
                AD.onDrawPreviews(standIn)
            end
        end
    end)
    X.draws = X.draws + 1
    -- The editor's own fallback renderer keys off this: it draws only when we did not.
    X.drewThisFrame = ok

    if not ok then
        X.lastError = tostring(err)
        X.clear()
        Logging.error("[%s] proxy draw failed, disabled: %s", X.MOD_NAME, X.lastError)
    end
end

--- Drawn from our own draw() rather than queued, so it needs nothing of AutoDrive's.
function X.drawMarker()
    if not X.enabled or X.cursorX == nil or not X.showMarker then
        return
    end
    local y = terrainHeight(X.cursorX, X.cursorZ)
    drawDebugLine(X.cursorX, y, X.cursorZ, 1, 0, 0, X.cursorX, y + 15, X.cursorZ, 1, 0, 0)
end

function X.describe()
    return string.format("proxy enabled=%s cursor=%s/%s draws=%d%s",
        tostring(X.enabled),
        X.cursorX and string.format("%.1f", X.cursorX) or "-",
        X.cursorZ and string.format("%.1f", X.cursorZ) or "-",
        X.draws,
        X.lastError and (" LAST ERROR: " .. X.lastError) or "")
end

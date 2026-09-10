--[[
MapMarker - an airplane on the game's HUD map showing where the flyover camera is and which way it
is looking.

The game's own marker stays with the player or vehicle while the camera flies somewhere else, so
on its own the map says nothing about where the editor actually is. The airplane fills that gap.

Drawn directly rather than as a registered map hotspot. Hotspots can be positioned and rotated, but
how a custom one renders its icon is base-game internals this mod cannot see - and every guess at
an undocumented API in this project has cost a round trip. The direct route needs only numbers the
map probe measured in game and verified against the player's position:

    u = ((x + worldCenterOffsetX) / worldSizeX) * mapExtensionScaleFactor + mapExtensionOffsetX
    v = ((z + worldCenterOffsetZ) / worldSizeZ) * mapExtensionScaleFactor + mapExtensionOffsetZ
    screen = mapOverlay origin + (u * width, (1 - v) * height), rotated about the overlay's
             rotation centre when the small map is in its rotating state

Checked: x = 478.8, z = 8.1 gives u = 0.6169, v = 0.5020 against the probe's playerU = 0.6169,
playerV = 0.4980 (which is 1 - v).
]]

ADFlyoverMapMarker = {
    overlay = nil,
    lastAngle = 0,
}

local K = ADFlyoverMapMarker

--- Image overlays load asynchronously: rendering one before it is ready draws nothing and makes the
--- engine log "renderOverlay called too soon". It asked, by name, for this check.
local function overlayReady(overlay)
    if getIsOverlayReady == nil then
        return true
    end
    local ok, ready = pcall(getIsOverlayReady, overlay)
    return not ok or ready
end

local function ensureOverlay()
    if K.overlay ~= nil then
        return K.overlay ~= false
    end
    local dir = ADFlyoverPrelude ~= nil and ADFlyoverPrelude.MOD_DIRECTORY or nil
    if dir == nil or createImageOverlay == nil then
        K.overlay = false
        return false
    end
    local ok, overlay = pcall(function()
        return createImageOverlay(Utils.getFilename("airplane.dds", dir))
    end)
    if ok and overlay ~= nil and overlay ~= 0 then
        K.overlay = overlay
        return true
    end
    K.overlay = false
    Logging.warning("[ADFlyoverEditor] could not load airplane.dds for the map marker.")
    return false
end

--- The HUD map, when it is on screen, or nil.
local function visibleMap()
    local hud = g_currentMission ~= nil and g_currentMission.hud or nil
    local map = hud ~= nil and hud.ingameMap or nil
    if map == nil or map.isVisible == false or map.state == 1 then
        return nil
    end
    if map.layout == nil or map.mapOverlay == nil or map.worldSizeX == nil then
        return nil
    end
    return map
end

--- A world position on the HUD map, in screen coordinates, plus the map's own rotation.
local function project(map, x, z)
    local ov = map.mapOverlay
    local u = ((x + map.worldCenterOffsetX) / map.worldSizeX) * (map.mapExtensionScaleFactor or 1)
        + (map.mapExtensionOffsetX or 0)
    local v = ((z + map.worldCenterOffsetZ) / map.worldSizeZ) * (map.mapExtensionScaleFactor or 1)
        + (map.mapExtensionOffsetZ or 0)

    local px = u * ov.width
    local py = (1 - v) * ov.height

    -- The rotating small map spins the whole overview about the player. Rotate the point with it,
    -- in pixel-proportional space: normalised y is not the same length as normalised x on a wide
    -- screen, and rotating raw normalised values would shear the result.
    local rotation = ov.rotation or 0
    if rotation ~= 0 then
        local aspect = g_screenAspectRatio or (16 / 9)
        local cx, cy = ov.rotationCenterX or 0, ov.rotationCenterY or 0
        local dx, dy = px - cx, (py - cy) / aspect
        local c, s = math.cos(rotation), math.sin(rotation)
        px = cx + (dx * c - dy * s)
        py = cy + (dx * s + dy * c) * aspect
    end

    return ov.x + px, ov.y + py, rotation
end

--- Which way the camera is looking, as a horizontal world vector, or nil if it cannot be read.
local function aimOf(camera)
    local node = camera.camera or camera.cameraBaseNode
    if node ~= nil and localDirectionToWorld ~= nil then
        -- Cameras look down their local -Z. Only the horizontal part matters for a heading.
        local ok, dx, _, dz = pcall(localDirectionToWorld, node, 0, 0, -1)
        if ok and dx ~= nil and (dx * dx + dz * dz) > 1e-6 then
            return dx, dz
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------------------------
-- Centring the small maps on the camera
--
-- The small maps scroll and rotate around "the player": the map computes
-- normalizedPlayerPosX/Z and playerRotation each frame and lays itself out from them (measured:
-- normalizedPlayerPosX = 0.7338 = (478.8 + 1024) / 2048 for a player at x = 478.8). While the editor
-- is open those should describe the CAMERA, so the map turns around the airplane instead of the
-- airplane crawling across a map centred somewhere else. The large map shows the whole world and does
-- not scroll, so there the airplane moves - which needs nothing from this at all.
--
-- Listing the map's methods by reflection returned nothing in this engine, so which hook exists is
-- found at runtime rather than assumed, and the log says which one was used.
-- ---------------------------------------------------------------------------------------------

K.followMode = nil       -- "shadow", "topdown" or "none", once decided
K.followCalls = 0
K.followActiveSince = nil
K.loggedFollowSilent = false

--- The camera's position and heading in the map's own terms, or nil.
local function cameraForMap(map)
    local editor = ADFlyoverEditor
    if editor == nil or not editor.active or editor.camera == nil then
        return nil
    end
    local cam = editor.camera
    if cam.cameraX == nil or cam.cameraZ == nil then
        return nil
    end
    local nx = (cam.cameraX + map.worldCenterOffsetX) / map.worldSizeX
    local nz = (cam.cameraZ + map.worldCenterOffsetZ) / map.worldSizeZ
    -- Heading as the rotating map wants it: zero facing north (world -Z), matching the marker's
    -- own angle, so that turning the map by minus this brings the camera's heading to screen-up.
    local dx, dz = aimOf(cam)
    local heading = dx ~= nil and math.atan2(-dx, -dz) or K.lastAngle
    return nx, nz, heading
end

--- Install the hook on this map instance, once. Idempotent across frames and across map reloads.
local function ensureFollow(map)
    if map.adFlyoverFollowHooked then
        return
    end
    map.adFlyoverFollowHooked = true

    -- 1. Shadow updatePlayerPosition on the INSTANCE. The game still computes the player's position
    --    first, so nothing is lost when the editor is closed; while it is open the three fields are
    --    rewritten afterwards, before the rest of the map's update lays itself out from them.
    if type(map.updatePlayerPosition) == "function" then
        local original = map.updatePlayerPosition
        map.updatePlayerPosition = function(self, ...)
            local result = original(self, ...)
            local nx, nz, heading = cameraForMap(self)
            if nx ~= nil then
                self.normalizedPlayerPosX, self.normalizedPlayerPosZ = nx, nz
                self.playerRotation = heading
                K.followCalls = K.followCalls + 1
            end
            return result
        end
        K.followMode = "shadow"
        Logging.info("[ADFlyoverEditor] small map will centre on the flyover camera "
            .. "(updatePlayerPosition shadowed on the map instance).")
        return
    end

    -- 2. The construction screen's route: hand the map a top-down camera. Only if the camera can
    --    answer the question the map will ask of it - otherwise this would throw every frame.
    if type(map.setTopDownCamera) == "function" then
        K.followMode = "topdown"
        Logging.info("[ADFlyoverEditor] small map will centre on the flyover camera "
            .. "(setTopDownCamera).")
        return
    end

    K.followMode = "none"
    Logging.warning("[ADFlyoverEditor] the HUD map offers neither updatePlayerPosition nor "
        .. "setTopDownCamera, so the small maps will stay centred on the player and the airplane "
        .. "will move across them instead.")
end

--- Called every frame from the mod's update.
function K.update()
    local hud = g_currentMission ~= nil and g_currentMission.hud or nil
    local map = hud ~= nil and hud.ingameMap or nil
    if map == nil or map.worldSizeX == nil then
        return
    end
    ensureFollow(map)

    local active = ADFlyoverEditor ~= nil and ADFlyoverEditor.active and ADFlyoverEditor.camera ~= nil

    if K.followMode == "topdown" then
        local wanted = active and ADFlyoverEditor.camera or nil
        if K.handedCamera ~= wanted then
            local cam = wanted
            local ok = cam == nil or type(cam.determineMapPosition) == "function"
            if ok then
                pcall(function() map:setTopDownCamera(cam) end)
                K.handedCamera = wanted
            elseif not K.loggedNoDetermine then
                K.loggedNoDetermine = true
                Logging.warning("[ADFlyoverEditor] setTopDownCamera exists but the flyover camera "
                    .. "has no determineMapPosition, so it was not handed over.")
            end
        end
    end

    -- A hook that is installed but never called is indistinguishable, from the screen, from one
    -- that works slowly. Say so once, after the editor has been open long enough to be sure.
    if K.followMode == "shadow" then
        if active then
            local t = (g_time ~= nil and g_time) or 0
            K.followActiveSince = K.followActiveSince or t
            if not K.loggedFollowSilent and K.followCalls == 0 and t - K.followActiveSince > 3000 then
                K.loggedFollowSilent = true
                Logging.warning("[ADFlyoverEditor] updatePlayerPosition was shadowed but the map has "
                    .. "not called it in 3s - it lays itself out some other way, so the small map "
                    .. "is still following the player.")
            end
        else
            K.followActiveSince = nil
        end
    end
end

function K.draw()
    local editor = ADFlyoverEditor
    if editor == nil or not editor.active or editor.camera == nil then
        return
    end
    local map = visibleMap()
    if map == nil or not ensureOverlay() then
        return
    end

    local camera = editor.camera
    -- Where the camera is looking: the centre of the view, which is where the editing happens.
    local wx, wz = camera.cameraX, camera.cameraZ
    if wx == nil or wz == nil then
        return
    end

    local sx, sy, mapRotation = project(map, wx, wz)

    -- Only inside the map window. Off the edge of a small map the point is somewhere on screen that
    -- has nothing to do with the map, and a marker there would just be litter.
    local l = map.layout
    if sx < l.mapPosX or sx > l.mapPosX + l.mapSizeX or sy < l.mapPosY or sy > l.mapPosY + l.mapSizeY then
        return
    end

    -- Heading. Screen up is world -Z (v grows with z and the screen takes 1 - v), so a world
    -- direction (dx, dz) points along screen (dx, -dz). The airplane is drawn nose up, so it wants
    -- the counter-clockwise angle from up to that vector - and then the map's own spin on top.
    local dx, dz = aimOf(camera)
    if dx ~= nil then
        K.lastAngle = math.atan2(-dx, -dz)
    end
    local angle = K.lastAngle + mapRotation

    local uiScale = (g_gameSettings ~= nil and g_gameSettings:getValue("uiScale")) or 1
    -- 34px: at 24 it read as a speck on the large map, and the halo needs room to show.
    local w, h = getNormalizedScreenValues(34 * uiScale, 34 * uiScale)
    if not overlayReady(K.overlay) then
        return
    end
    setOverlayRotation(K.overlay, angle, w * 0.5, h * 0.5)
    setOverlayColor(K.overlay, 1, 1, 1, 1)
    renderOverlay(K.overlay, sx - w * 0.5, sy - h * 0.5, w, h)
end

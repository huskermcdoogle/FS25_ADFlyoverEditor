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
    local w, h = getNormalizedScreenValues(24 * uiScale, 24 * uiScale)
    setOverlayRotation(K.overlay, angle, w * 0.5, h * 0.5)
    setOverlayColor(K.overlay, 1, 1, 1, 1)
    renderOverlay(K.overlay, sx - w * 0.5, sy - h * 0.5, w, h)
end

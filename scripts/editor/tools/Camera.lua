-- Part of the flyover editor. Prelude.lua loads it after FlyoverEditor.lua.

-- ---------------------------------------------------------------------------------------------
-- CAMERA THROUGH BUILDINGS (issue #30)
--
-- The game's top-down camera keeps clear of everything under it: GuiTopDownCamera:updatePosition
-- casts down from 100 m with its COLLISION_MASK and lifts the camera above the first thing it
-- meets. So it can never get under a shed roof, and a parking spot inside cannot be placed.
--
-- With the setting on, OUR camera instance gets its own updatePosition: the game's steps, but it
-- keeps clear of the terrain only, and at the closest zoom it comes lower and nearer, so it fits
-- inside a shed. Only the instance is changed, never the class, so the game's own build mode keeps
-- its camera exactly as it is. With the setting off, the instance calls the game's function as it
-- stands: exactly the old camera.
-- ---------------------------------------------------------------------------------------------

local CAM = {
    -- Below this zoom factor (0 = closest, 1 = furthest) the camera comes closer than the game's.
    -- The wheel moves the zoom about 0.02 a notch down here, so this is the last few notches.
    CLOSE_ZONE = 0.15,
    -- At full zoom: how high over the ground the camera looks, and how far it sits from that point.
    -- Never more than the game's own numbers; only ever lower and closer.
    NEAR_TARGET_HEIGHT = 1.0,
    NEAR_DISTANCE = 4.0,
    -- The least the camera keeps over the terrain with the setting on (or the game's, if more).
    -- A shed floor slab sits a little above the terrain; this keeps the camera out of it.
    FLOOR_MARGIN = 1.5,
    -- The game's terrain sampling grid, in metres.
    SAMPLE_STEP = 2,
    -- How often the editor asks whether the camera is under a roof, and how far up it looks.
    COVER_CHECK_MS = 250,
    COVER_RAY = 40,
}
ADFlyoverEditor.CAMERA_THROUGH = CAM

local NUMBERS = { "CAMERA_TERRAIN_OFFSET", "ROTATION_MIN_X_NEAR", "ROTATION_MIN_X_FAR", "ROTATION_MAX_X_NEAR",
    "ROTATION_MAX_X_FAR", "DISTANCE_MIN_Z", "DISTANCE_RANGE_Z", "GROUND_DISTANCE_MIN_Y" }

local function gameNumbersPresent()
    if GuiTopDownCamera == nil or type(GuiTopDownCamera.updatePosition) ~= "function" then
        return false
    end
    for _, name in ipairs(NUMBERS) do
        if type(GuiTopDownCamera[name]) ~= "number" then
            return false
        end
    end
    return true
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

--- Highest terrain on the game's 3 x 3 grid around x, z. Starts at 0, as the game's does.
local function terrainAround(cam, x, z)
    local step, h = CAM.SAMPLE_STEP, 0
    for dx = -step, step, step do
        for dz = -step, step, step do
            h = math.max(h, getTerrainHeightAtWorldPos(cam.terrainRootNode, x + dx, 0, z + dz))
        end
    end
    return h
end

--- How far the camera sits from the point it looks at, for a zoom factor. The game's line, except
--- inside CLOSE_ZONE, where it bends down to NEAR_DISTANCE at full zoom. It meets the game's line at
--- the edge of the zone, so zooming has no jump. Keeps the game's sign.
local function cameraDistance(zoom)
    local C = GuiTopDownCamera
    local game = C.DISTANCE_MIN_Z + zoom * C.DISTANCE_RANGE_Z
    if zoom >= CAM.CLOSE_ZONE then
        return game
    end
    local near = C.DISTANCE_MIN_Z
    if math.abs(near) > CAM.NEAR_DISTANCE then
        near = CAM.NEAR_DISTANCE * (near < 0 and -1 or 1)
    end
    local edge = C.DISTANCE_MIN_Z + CAM.CLOSE_ZONE * C.DISTANCE_RANGE_Z
    return lerp(near, edge, zoom / CAM.CLOSE_ZONE)
end

--- How high over the ground the camera looks, for a zoom factor. Same bend as the distance.
local function targetHeight(zoom)
    local offset = GuiTopDownCamera.CAMERA_TERRAIN_OFFSET
    if zoom >= CAM.CLOSE_ZONE then
        return offset
    end
    return lerp(math.min(offset, CAM.NEAR_TARGET_HEIGHT), offset, zoom / CAM.CLOSE_ZONE)
end

--- GuiTopDownCamera:updatePosition with the setting on. Line for line the game's, with two changes:
--- the close-zoom bend above, and the clearance check reads the terrain only (no raycast), so roofs,
--- trees and sheds no longer lift the camera.
local function updateThroughBuildings(cam)
    local C = GuiTopDownCamera
    local zoom = cam.zoomFactor or 0
    local targetY = terrainAround(cam, cam.cameraX, cam.cameraZ) + targetHeight(zoom)

    local rotMin = math.rad(C.ROTATION_MIN_X_NEAR + (C.ROTATION_MIN_X_FAR - C.ROTATION_MIN_X_NEAR) * zoom)
    local rotMax = math.rad(C.ROTATION_MAX_X_NEAR + (C.ROTATION_MAX_X_FAR - C.ROTATION_MAX_X_NEAR) * zoom)
    local rotationX = rotMin + (rotMax - rotMin) * cam.tiltFactor

    setTranslation(cam.camera, 0, 0, cameraDistance(zoom))
    setRotation(cam.cameraBaseNode, rotationX, cam.cameraRotY, 0)
    setTranslation(cam.cameraBaseNode, cam.cameraX, targetY, cam.cameraZ)

    local x, y, z = getWorldTranslation(cam.camera)
    local clear = terrainAround(cam, x, z) + math.max(C.GROUND_DISTANCE_MIN_Y, CAM.FLOOR_MARGIN)
    if y < clear then
        setTranslation(cam.cameraBaseNode, cam.cameraX, targetY + (clear - y), cam.cameraZ)
    end
end

--- Highest thing above (x, y, z) within COVER_RAY metres, or nil. Cast DOWN onto it from above:
--- a roof's collision may only face upwards, so a ray going up from under it could miss it.
--- Uses the game camera's own mask, so "a roof" means what used to lift the camera.
local function coverAbove(x, y, z)
    if RaycastUtil == nil or RaycastUtil.raycastClosest == nil or GuiTopDownCamera == nil
        or GuiTopDownCamera.COLLISION_MASK == nil then
        return nil
    end
    local ok, objectId, _, hitY = pcall(RaycastUtil.raycastClosest, x, y + CAM.COVER_RAY, z, 0, -1, 0,
        CAM.COVER_RAY - 0.2, GuiTopDownCamera.COLLISION_MASK)
    if ok and objectId ~= nil and objectId ~= 0 and hitY ~= nil then
        return hitY
    end
    return nil
end

--- Called in enable(), on the new camera, BEFORE activate(): activate() already positions it.
function ADFlyoverEditor:installCameraThroughBuildings(camera)
    self.cameraUnderCover = false
    self.coverCheckMs = 0
    self.loggedRoofPick = false
    if not gameNumbersPresent() then
        Logging.warning("[FlyoverEditor]: the game camera's numbers are missing, so camera through buildings cannot work. The camera stays the game's.")
        return
    end
    local failed = false
    camera.updatePosition = function(cam)
        if not failed and ADFlyoverSettings.get("cameraThroughBuildings") then
            local ok, err = pcall(updateThroughBuildings, cam)
            if ok then
                return
            end
            failed = true
            Logging.error("[FlyoverEditor]: camera through buildings failed, back to the game's camera: %s", tostring(err))
        end
        return GuiTopDownCamera.updatePosition(cam)
    end

    -- Once per open: the game's camera numbers, which its Lua copy on this PC does not show, and
    -- about how low each camera gets at full zoom (looked-at height + distance x sine of the tilt).
    local C = GuiTopDownCamera
    local function lowest(height, distance)
        local a = math.abs(distance) * math.sin(math.rad(C.ROTATION_MIN_X_NEAR))
        local b = math.abs(distance) * math.sin(math.rad(C.ROTATION_MAX_X_NEAR))
        return height + math.min(a, b), height + math.max(a, b)
    end
    local gLo, gHi = lowest(C.CAMERA_TERRAIN_OFFSET, C.DISTANCE_MIN_Z)
    local oLo, oHi = lowest(targetHeight(0), cameraDistance(0))
    Logging.info("[FlyoverEditor]: camera through buildings %s. Game camera: looks %.1f m over the ground from %.1f m (zoomed out %.1f m), tilt %.0f-%.0f deg near / %.0f-%.0f far, keeps %.1f m clear, mask %s. Full zoom: game about %.1f-%.1f m up, ours about %.1f-%.1f m.",
        ADFlyoverSettings.get("cameraThroughBuildings") and "on" or "off",
        C.CAMERA_TERRAIN_OFFSET, math.abs(C.DISTANCE_MIN_Z), math.abs(C.DISTANCE_MIN_Z + C.DISTANCE_RANGE_Z),
        C.ROTATION_MIN_X_NEAR, C.ROTATION_MAX_X_NEAR, C.ROTATION_MIN_X_FAR, C.ROTATION_MAX_X_FAR,
        C.GROUND_DISTANCE_MIN_Y, tostring(C.COLLISION_MASK), gLo, gHi, oLo, oHi)
end

--- The settings dialog's row. Live: the camera reads the setting every frame.
function ADFlyoverEditor:toggleCameraThroughBuildings()
    ADFlyoverSettings.cycle("cameraThroughBuildings", 1)
    Logging.info("[FlyoverEditor]: camera through buildings: %s.", ADFlyoverSettings.get("cameraThroughBuildings") and "on" or "off")
end

--- Every COVER_CHECK_MS: is the camera under a roof (or a tree)? Logs only the change, with how
--- high the camera is, so the log shows how low it got and the test card can tick itself.
function ADFlyoverEditor:cameraCoverCheck(dt)
    self.coverCheckMs = (self.coverCheckMs or 0) + (dt or 0)
    if self.coverCheckMs < CAM.COVER_CHECK_MS or self.camera == nil or self.camera.camera == nil then
        return
    end
    self.coverCheckMs = 0

    local under, x, y, z, roofY = false, nil, nil, nil, nil
    if ADFlyoverSettings.get("cameraThroughBuildings") then
        x, y, z = getWorldTranslation(self.camera.camera)
        roofY = coverAbove(x, y, z)
        under = roofY ~= nil
    end
    if under then
        local overGround = y - getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
        if not self.cameraUnderCover then
            Logging.info("[FlyoverEditor]: camera went under a roof: %.1f m over the ground, the roof %.1f m above it (zoom %.2f).",
                overGround, roofY - y, self.camera.zoomFactor or -1)
            self.coverLowest = overGround
        else
            self.coverLowest = math.min(self.coverLowest or overGround, overGround)
        end
    elseif self.cameraUnderCover then
        Logging.info("[FlyoverEditor]: camera came out from under the roof; lowest it got there: %.1f m over the ground.",
            self.coverLowest or -1)
    end
    self.cameraUnderCover = under
end

--- Where the cursor points in the world: GuiTopDownCursor:getPosition, with one guard while the
--- camera is under a roof. A pick ray from inside heads down to the floor; one that reports a point
--- ABOVE the camera has met the roof (a ray aimed above the horizon, or a pick that does not start
--- at the camera). The click is meant for the floor under that point, so the floor is used:
--- the first surface below the camera's height there, or the terrain.
function ADFlyoverEditor:cursorPosition()
    local x, y, z = self.cursor:getPosition()
    if x == nil or y == nil or not self.cameraUnderCover or self.camera == nil or self.camera.camera == nil then
        return x, y, z
    end
    local _, camY = getWorldTranslation(self.camera.camera)
    if y <= camY then
        return x, y, z
    end
    local terrainY = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
    local floorY = terrainY
    if RaycastUtil ~= nil and RaycastUtil.raycastClosest ~= nil and GuiTopDownCamera.COLLISION_MASK ~= nil
        and camY > terrainY then
        local ok, objectId, _, hitY = pcall(RaycastUtil.raycastClosest, x, camY, z, 0, -1, 0,
            camY - terrainY + 0.5, GuiTopDownCamera.COLLISION_MASK)
        if ok and objectId ~= nil and objectId ~= 0 and hitY ~= nil then
            floorY = hitY
        end
    end
    if not self.loggedRoofPick then
        Logging.info("[FlyoverEditor]: the cursor picked the roof (%.1f m, camera at %.1f m); using the floor below it (%.1f m).",
            y, camY, floorY)
        self.loggedRoofPick = true
    end
    return x, floorY, z
end

--- After a point is placed: if something is above it, say so. That is how the log shows a point
--- went onto a floor inside, not onto the roof (nothing is above a point on a roof).
function ADFlyoverEditor:notePlacedUnderRoof(id, x, y, z)
    if not ADFlyoverSettings.get("cameraThroughBuildings") then
        return
    end
    local roofY = coverAbove(x, y + 0.3, z)
    if roofY ~= nil then
        Logging.info("[FlyoverEditor]: placed a point under a roof: id=%s, %.2f m over the terrain, the roof %.1f m above it.",
            tostring(id), y - getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z), roofY - y)
    end
end

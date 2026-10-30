-- Part of the flyover editor. Prelude.lua loads it after FlyoverEditor.lua.

-- ---------------------------------------------------------------------------------------------
-- CAMERA THROUGH BUILDINGS AND HEIGHT SLICE (issue #30)
--
-- The game's top-down camera keeps clear of everything under it: GuiTopDownCamera:updatePosition
-- casts down from 100 m with its COLLISION_MASK and lifts the camera above the first thing it
-- meets. So it can never get under a shed roof, and a parking spot inside cannot be placed.
--
-- Two ways round it, both on OUR camera instance only, never the class, so the game's own build
-- mode keeps its camera exactly as it is:
--
-- * THROUGH BUILDINGS (on by default): the instance gets its own updatePosition - the game's steps,
--   but it keeps clear of the terrain only, and at the closest zoom it comes lower and nearer, so
--   it fits inside a shed.
-- * HEIGHT SLICE (off by default, X key): the camera looks straight down and its near clip is set
--   every frame so the picture starts at a flat cut over the ground. Everything above the cut -
--   roofs, trees - is not drawn. The cut is the ground under the screen centre plus the height of
--   the vehicle you are in with everything attached (its highest top), or a set height on foot.
--   The engine has no clip plane; a straight-down camera's near clip is one, and flat.
--
-- With both off, the instance calls the game's function as it stands: exactly the old camera.
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
    -- Slice: the camera stays at least this far over the cut (and the near clip never goes under
    -- it), how often the vehicle's height is read again, how far over a vehicle's top the cut
    -- sits, and how far over the highest ground in view (so a hill is never cut open).
    SLICE_MIN_NEAR = 1.0,
    SLICE_VEHICLE_MS = 1000,
    SLICE_OVER_VEHICLE = 0.1,
    SLICE_OVER_GROUND = 0.3,
    SLICE_GRID = 4,           -- the view is sampled on a (2 x SLICE_GRID + 1)^2 terrain grid
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

-- Which sign of a 90 degree pitch puts the camera straight ABOVE the point it looks at. Found on
-- the first slice frame by trying it (the camera always looks at its base node, so above = down).
local downPitch = nil

--- The near clip for a slice: the cut as a distance from the camera, raised over the highest ground
--- in view so a hill at the screen edge is never cut open. Returns the near clip and the cut's
--- height actually used.
local function sliceNearClip(cam, camX, camY, camZ, cutY)
    local half = math.tan((getFovY ~= nil and getFovY(cam.camera) or math.rad(60)) * 0.5)
    local aspect = (type(g_screenAspectRatio) == "number" and g_screenAspectRatio > 1) and g_screenAspectRatio or 1
    local groundC = getTerrainHeightAtWorldPos(cam.terrainRootNode, camX, 0, camZ)
    local r = math.max(0, camY - groundC) * half * aspect * 1.42  -- the square's corners, any yaw
    local highest = groundC
    for i = -CAM.SLICE_GRID, CAM.SLICE_GRID do
        for j = -CAM.SLICE_GRID, CAM.SLICE_GRID do
            local d = r / CAM.SLICE_GRID
            highest = math.max(highest, getTerrainHeightAtWorldPos(cam.terrainRootNode, camX + i * d, 0, camZ + j * d))
        end
    end
    local cut = math.max(cutY, highest + CAM.SLICE_OVER_GROUND)
    local near = math.max(CAM.SLICE_MIN_NEAR, camY - cut)
    return near, camY - near
end

--- GuiTopDownCamera:updatePosition for our camera when through-buildings or the slice is on. Line
--- for line the game's, with these changes: the close-zoom bend above; the clearance check reads
--- the terrain only (no raycast), so roofs, trees and sheds no longer lift the camera; and with the
--- slice on, a straight-down view, at least SLICE_MIN_NEAR over the cut, with the near clip set.
local function updateOurs(cam, editor, slice)
    local C = GuiTopDownCamera
    local zoom = cam.zoomFactor or 0
    local targetY = terrainAround(cam, cam.cameraX, cam.cameraZ) + targetHeight(zoom)

    local rotationX
    if slice then
        rotationX = math.rad(90) * (downPitch or 1)
    else
        local rotMin = math.rad(C.ROTATION_MIN_X_NEAR + (C.ROTATION_MIN_X_FAR - C.ROTATION_MIN_X_NEAR) * zoom)
        local rotMax = math.rad(C.ROTATION_MAX_X_NEAR + (C.ROTATION_MAX_X_FAR - C.ROTATION_MAX_X_NEAR) * zoom)
        rotationX = rotMin + (rotMax - rotMin) * cam.tiltFactor
    end

    setTranslation(cam.camera, 0, 0, cameraDistance(zoom))
    setRotation(cam.cameraBaseNode, rotationX, cam.cameraRotY, 0)
    setTranslation(cam.cameraBaseNode, cam.cameraX, targetY, cam.cameraZ)

    local x, y, z = getWorldTranslation(cam.camera)
    if slice and downPitch == nil then
        -- First slice frame: if +90 put the camera under the point, -90 is the one.
        downPitch = (y > targetY) and 1 or -1
        if downPitch < 0 then
            setRotation(cam.cameraBaseNode, -math.rad(90), cam.cameraRotY, 0)
            x, y, z = getWorldTranslation(cam.camera)
        end
        Logging.info("[FlyoverEditor]: height slice: straight down is a pitch of %d deg.", 90 * downPitch)
    end

    local clear = terrainAround(cam, x, z) + math.max(C.GROUND_DISTANCE_MIN_Y, CAM.FLOOR_MARGIN)
    local cutY = nil
    if slice then
        cutY = getTerrainHeightAtWorldPos(cam.terrainRootNode, cam.cameraX, 0, cam.cameraZ) + editor:sliceHeight()
        clear = math.max(clear, cutY + CAM.SLICE_MIN_NEAR)
    end
    if y < clear then
        setTranslation(cam.cameraBaseNode, cam.cameraX, targetY + (clear - y), cam.cameraZ)
        y = clear
    end

    if slice then
        local near, usedCut = sliceNearClip(cam, x, y, z, cutY)
        setNearClip(cam.camera, near)
        editor:sliceNote(usedCut, usedCut > cutY + 0.01,
            getTerrainHeightAtWorldPos(cam.terrainRootNode, cam.cameraX, 0, cam.cameraZ))
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

--- What a floor pick may land on: the ground, roads, buildings' floors, static objects. Built from
--- the flags this game has (CollisionFlag), each one once.
local function floorMask()
    if CollisionFlag == nil then
        return nil
    end
    local mask = 0
    for _, name in ipairs({ "DEFAULT", "STATIC_OBJECT", "TERRAIN", "BUILDING", "ROAD" }) do
        if type(CollisionFlag[name]) == "number" then
            mask = mask + CollisionFlag[name]
        end
    end
    return mask > 0 and mask or nil
end

--- Called in enable(), on the new camera, BEFORE activate(): activate() already positions it.
function ADFlyoverEditor:installCameraThroughBuildings(camera)
    self.cameraUnderCover = false
    self.coverCheckMs = 0
    self.loggedRoofPick = false
    self.sliceApplied = false
    self.sliceCutY = nil
    self.sliceVehicleMs = nil
    self.sliceSource = nil
    self.sliceClamped = false
    if not gameNumbersPresent() then
        Logging.warning("[FlyoverEditor]: the game camera's numbers are missing, so camera through buildings and the height slice cannot work. The camera stays the game's.")
        return
    end
    local okNear, near = pcall(function() return getNearClip(camera.camera) end)
    self.gameNearClip = (okNear and type(near) == "number") and near or 1
    local editor = self
    local failed = false
    camera.updatePosition = function(cam)
        local slice = not failed and ADFlyoverSettings.get("heightSlice") == true and setNearClip ~= nil
        if not failed and (slice or ADFlyoverSettings.get("cameraThroughBuildings")) then
            local ok, err = pcall(updateOurs, cam, editor, slice)
            if ok then
                if not slice then
                    editor:sliceRestore()
                end
                editor.sliceApplied = slice
                return
            end
            failed = true
            Logging.error("[FlyoverEditor]: camera through buildings / height slice failed, back to the game's camera: %s", tostring(err))
        end
        editor:sliceRestore()
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
    Logging.info("[FlyoverEditor]: camera through buildings %s, height slice %s. Game camera: looks %.1f m over the ground from %.1f m (zoomed out %.1f m), tilt %.0f-%.0f deg near / %.0f-%.0f far, keeps %.1f m clear, mask %s, near clip %.2f m. Full zoom: game about %.1f-%.1f m up, ours about %.1f-%.1f m.",
        ADFlyoverSettings.get("cameraThroughBuildings") and "on" or "off",
        ADFlyoverSettings.get("heightSlice") and "on" or "off",
        C.CAMERA_TERRAIN_OFFSET, math.abs(C.DISTANCE_MIN_Z), math.abs(C.DISTANCE_MIN_Z + C.DISTANCE_RANGE_Z),
        C.ROTATION_MIN_X_NEAR, C.ROTATION_MAX_X_NEAR, C.ROTATION_MIN_X_FAR, C.ROTATION_MAX_X_FAR,
        C.GROUND_DISTANCE_MIN_Y, tostring(C.COLLISION_MASK), self.gameNearClip, gLo, gHi, oLo, oHi)
end

--- The settings dialog's row. Live: the camera reads the setting every frame.
function ADFlyoverEditor:toggleCameraThroughBuildings()
    ADFlyoverSettings.cycle("cameraThroughBuildings", 1)
    Logging.info("[FlyoverEditor]: camera through buildings: %s.", ADFlyoverSettings.get("cameraThroughBuildings") and "on" or "off")
end

-- ---------------------------------------------------------------------------------------------
-- Height slice
-- ---------------------------------------------------------------------------------------------

--- The X key and the settings row.
function ADFlyoverEditor:toggleHeightSlice()
    ADFlyoverSettings.cycle("heightSlice", 1)
    self.sliceSource = nil      -- say where the cut comes from again, right away
    self.sliceVehicleMs = nil
    Logging.info("[FlyoverEditor]: height slice: %s.", ADFlyoverSettings.get("heightSlice") and "on" or "off")
end

--- Put the game's near clip back. Safe to call every frame: only acts once after a slice.
function ADFlyoverEditor:sliceRestore()
    if self.sliceApplied and self.camera ~= nil and self.camera.camera ~= nil and setNearClip ~= nil then
        pcall(setNearClip, self.camera.camera, self.gameNearClip or 1)
    end
    self.sliceApplied = false
    self.sliceCutY = nil
end

--- Highest top of a vehicle over the ground under it, from its size in its XML (base.size#height,
--- measured up from its root node). Nil if it has none.
local function vehicleTop(v)
    if v == nil or v.rootNode == nil or v.size == nil or type(v.size.height) ~= "number" then
        return nil
    end
    local x, y, z = localToWorld(v.rootNode, 0, (v.size.heightOffset or 0) + v.size.height, 0)
    return y - getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
end

--- The cut's height over the ground: the vehicle you are in with everything attached (highest top),
--- or the on-foot setting. Read again every SLICE_VEHICLE_MS; logged when it changes.
function ADFlyoverEditor:sliceHeight()
    local now = self.elapsedMs or 0
    if self.sliceVehicleMs ~= nil and now - self.sliceVehicleMs < CAM.SLICE_VEHICLE_MS and self.sliceHeightM ~= nil then
        return self.sliceHeightM
    end
    self.sliceVehicleMs = now

    local okV, vehicle = pcall(function() return AutoDrive.getControlledVehicle() end)
    vehicle = okV and vehicle or nil
    local height, source = nil, nil
    if vehicle ~= nil then
        local root = (vehicle.getRootVehicle ~= nil and vehicle:getRootVehicle()) or vehicle
        local all = (root.getChildVehicles ~= nil and root:getChildVehicles()) or { root }
        local highest, count = nil, 0
        for _, v in ipairs(all) do
            local top = vehicleTop(v)
            if top ~= nil then
                highest = math.max(highest or top, top)
            end
            count = count + 1
        end
        if highest ~= nil then
            height = highest + CAM.SLICE_OVER_VEHICLE
            local name = (root.getFullName ~= nil and root:getFullName()) or tostring(root.configFileName)
            source = string.format("from the vehicle %s with %d attached (highest top %.1f m)", tostring(name), math.max(0, count - 1), highest)
        end
    end
    if height == nil then
        height = ADFlyoverSettings.get("heightSliceOnFoot") or 4
        source = "on foot"
    end
    self.sliceHeightM = height

    local key = string.format("%s %.1f", source, height)
    if key ~= self.sliceSource then
        self.sliceSource = key
        Logging.info("[FlyoverEditor]: height slice: cut at %.1f m over the ground, %s.", height, source)
    end
    return height
end

--- Every slice frame: the cut actually used. Logs only when the hill clamp starts or stops biting.
function ADFlyoverEditor:sliceNote(cutY, clamped, groundY)
    self.sliceCutY = cutY
    if clamped ~= self.sliceClamped then
        self.sliceClamped = clamped
        if clamped then
            Logging.info("[FlyoverEditor]: height slice: ground in view is higher than the cut, so the cut is raised to %.1f m over the ground to keep it whole.", cutY - groundY)
        else
            Logging.info("[FlyoverEditor]: height slice: cut back at its set height.")
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Under a roof, and where clicks land
-- ---------------------------------------------------------------------------------------------

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

--- Slice on: where the pick ray, carried on from the cut, first meets the floor. Nil if it can't say.
function ADFlyoverEditor:pickBelowCut(cutY)
    local ok, ox, oy, oz, dx, dy, dz = pcall(function() return self.camera:getPickRay() end)
    if not ok or type(dy) ~= "number" or dy >= -0.01 or RaycastUtil == nil or RaycastUtil.raycastClosest == nil then
        return nil
    end
    local mask = floorMask()
    if mask == nil then
        return nil
    end
    local t = math.max(0, (oy - cutY) / -dy)
    local sx, sy, sz = ox + dx * t, oy + dy * t, oz + dz * t
    local okR, objectId, hx, hy, hz = pcall(RaycastUtil.raycastClosest, sx, sy, sz, dx, dy, dz, 500, mask)
    if okR and objectId ~= nil and objectId ~= 0 and hy ~= nil then
        return hx, hy, hz
    end
    return nil
end

--- Where the cursor points in the world: GuiTopDownCursor:getPosition, with two guards.
---
--- * Slice on: a pick above the cut has met something that is not drawn (a roof). The click is
---   meant for what you see, so the pick ray is carried on from the cut to the floor.
--- * Through buildings, camera under a roof: a pick ray from inside heads down to the floor; one
---   that reports a point ABOVE the camera has met the roof (a ray aimed above the horizon, or a
---   pick that does not start at the camera). The floor below that point is used: the first
---   surface below the camera's height there, or the terrain.
function ADFlyoverEditor:cursorPosition()
    local x, y, z = self.cursor:getPosition()
    if x == nil or y == nil or self.camera == nil or self.camera.camera == nil then
        return x, y, z
    end

    if self.sliceApplied and self.sliceCutY ~= nil then
        if y <= self.sliceCutY + 0.05 then
            return x, y, z
        end
        local fx, fy, fz = self:pickBelowCut(self.sliceCutY)
        if not self.loggedRoofPick then
            Logging.info("[FlyoverEditor]: the cursor picked something above the cut (%.1f m, cut at %.1f m); %s.",
                y, self.sliceCutY, fy ~= nil and string.format("using the floor under it (%.1f m)", fy) or "found no floor, kept it")
            self.loggedRoofPick = true
        end
        if fy ~= nil then
            return fx, fy, fz
        end
        return x, y, z
    end

    if not self.cameraUnderCover then
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
    if not ADFlyoverSettings.get("cameraThroughBuildings") and not ADFlyoverSettings.get("heightSlice") then
        return
    end
    local roofY = coverAbove(x, y + 0.3, z)
    if roofY ~= nil then
        Logging.info("[FlyoverEditor]: placed a point under a roof: id=%s, %.2f m over the terrain, the roof %.1f m above it.",
            tostring(id), y - getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z), roofY - y)
    end
end

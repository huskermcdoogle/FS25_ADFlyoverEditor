-- Held removals (decided 2026-10-18, issue #26 follow-on). Part of the flyover editor; Prelude.lua
-- sources it after EditorHistory.lua.
--
-- When the editor replaces points (smooth, divide, straighten) and a driving vehicle still has one of
-- them ahead on its route, the point is HELD instead of removed:
--   - it is unlinked both ways, so no new route can use it;
--   - it stays in the array with its id, so nothing renumbers under the vehicle;
--   - it is flagged `held`, so the editor can tell it apart from a live point.
-- A held point is removed for real, in one pass, once no driving vehicle has it at or ahead of its
-- current point any more.
--
-- A vehicle AutoDrive stops on purpose (stopVehicle) while it holds a point ahead is restarted after
-- LIMIT_MS, the way AutoDrive restarts a stuck one. Before that restart its route is cleared and the
-- held points nobody else needs are released, so the new route is planned without them.
--
-- Saving releases every held point at once, so the saved network never carries them. That is safe for
-- a vehicle still on one: it keeps its own list of points and steers by index, so it finishes its run
-- on the old road, as it would after an ordinary removal.

ADHeldRemovals = {}

ADHeldRemovals.LIMIT_MS = 60000
ADHeldRemovals.RELEASE_EVERY_MS = 500

-- vehicle -> ms it has been stopped on purpose while holding a point ahead
local stoppedMs = {}
local sinceRelease = 0

local function removeValue(list, value)
    if list == nil then
        return
    end
    for i = #list, 1, -1 do
        if list[i] == value then
            table.remove(list, i)
        end
    end
end

--- The route points a drive module still has at or ahead of its current point, as a set keyed by the
--- point table. nil when there is no route.
local function aheadOfDrive(drive)
    if drive == nil or drive.wayPoints == nil then
        return nil
    end
    local set = {}
    for i = math.max(1, drive.currentWayPoint or 1), #drive.wayPoints do
        set[drive.wayPoints[i]] = true
    end
    return set
end

local function allVehicles()
    return AutoDrive.getAllVehicles() or {}
end

local function holdsAhead(set)
    for wp in pairs(set) do
        if wp.held then
            return true
        end
    end
    return false
end

--- Every point still ahead of some vehicle with a route: point table -> true.
function ADHeldRemovals.pointsAhead()
    local ahead = {}
    for _, vehicle in pairs(allVehicles()) do
        local set = vehicle.ad ~= nil and aheadOfDrive(vehicle.ad.drivePathModule) or nil
        if set ~= nil then
            for wp in pairs(set) do
                ahead[wp] = true
            end
        end
    end
    return ahead
end

--- Markers are never held: a held point is unlinked, and a marker on it would be stranded.
function ADHeldRemovals.hasMarker(id)
    return ADGraphManager:getMapMarkerByWayPointId(id) ~= nil
end

function ADHeldRemovals.anyHeld()
    for _, wp in ipairs(ADGraphManager:getWayPoints()) do
        if wp.held then
            return true
        end
    end
    return false
end

--- Hold a point: unlink it both ways, keep it in the array with its id, and flag it.
function ADHeldRemovals.hold(wp)
    local id = wp.id
    for _, other in ipairs(ADGraphManager:getWayPoints()) do
        if other ~= wp then
            removeValue(other.out, id)
            removeValue(other.incoming, id)
        end
    end
    wp.out, wp.incoming, wp.held = {}, {}, true
    ADGraphManager:markChanges()
end

local function removeListed(ids)
    -- Highest id first: each removal renumbers everything above it, so the lower ids stay valid.
    table.sort(ids, function(a, b) return a > b end)
    for _, id in ipairs(ids) do
        ADGraphManager:removeWayPoint(id, false)
    end
    if #ids > 0 then
        ADGraphManager:markChanges()
    end
    return #ids
end

--- The ids of held points, minus any the `keep` set (point table -> true) asks us to keep.
local function heldIds(keep)
    local ids = {}
    for _, wp in ipairs(ADGraphManager:getWayPoints()) do
        if wp.held and not (keep ~= nil and keep[wp]) then
            table.insert(ids, wp.id)
        end
    end
    return ids
end

--- Remove every held point that no vehicle still has ahead. Returns how many went.
function ADHeldRemovals.release()
    local n = removeListed(heldIds(ADHeldRemovals.pointsAhead()))
    if n > 0 then
        Logging.info("[FlyoverEditor]: held removals: released %d point(s) no vehicle drives through any more.", n)
    end
    return n
end

--- Remove every held point, whether a vehicle has it ahead or not. Used at save.
function ADHeldRemovals.releaseAll()
    return removeListed(heldIds(nil))
end

--- Restart a vehicle that has been held on purpose for too long. The route is cleared first, so the
--- held points nobody else needs can go before AutoDrive plans the new route.
function ADHeldRemovals.restart(vehicle)
    vehicle.ad.drivePathModule:reset()
    ADHeldRemovals.release()
    vehicle.ad.taskModule:stopAndRestartAD()
    ADFlyoverSettings.debugLog("held removals: a vehicle stopped on purpose with a point ahead was restarted")
end

--- Called every frame from the editor's update. The checks run every RELEASE_EVERY_MS.
function ADHeldRemovals.update(dt)
    sinceRelease = sinceRelease + (dt or 0)
    if sinceRelease < ADHeldRemovals.RELEASE_EVERY_MS then
        return
    end
    local elapsed = sinceRelease
    sinceRelease = 0

    if not ADHeldRemovals.anyHeld() then
        stoppedMs = {}
        return
    end

    for _, vehicle in pairs(allVehicles()) do
        local set = vehicle.ad ~= nil and aheadOfDrive(vehicle.ad.drivePathModule) or nil
        local spec = vehicle.ad ~= nil and vehicle.ad.specialDrivingModule or nil
        if set ~= nil and spec ~= nil and holdsAhead(set) and spec:isStoppingVehicle() then
            stoppedMs[vehicle] = (stoppedMs[vehicle] or 0) + elapsed
            if stoppedMs[vehicle] >= ADHeldRemovals.LIMIT_MS then
                stoppedMs[vehicle] = nil
                ADHeldRemovals.restart(vehicle)
            end
        else
            stoppedMs[vehicle] = nil
        end
    end

    ADHeldRemovals.release()
end

--- Save: the saved network must not carry held points.
function ADHeldRemovals.releaseForSave()
    if ADHeldRemovals.anyHeld() then
        ADHeldRemovals.releaseAll()
    end
end

-- AutoDrive's own stuck restart (no progress for 8 s) plans from wherever the vehicle is, and that can
-- be a held point it is stuck at. Clear the route and release first, the same as a time-limit restart.
-- Installed once, however often the editor files are sourced.
if ADDrivePathModule ~= nil and type(ADDrivePathModule.handleBeingStuck) == "function"
    and not ADDrivePathModule.__adFlyoverHeldStuckHooked then
    ADDrivePathModule.__adFlyoverHeldStuckHooked = true
    local autoDriveStuck = ADDrivePathModule.handleBeingStuck
    ADDrivePathModule.handleBeingStuck = function(self, ...)
        local set = aheadOfDrive(self)
        if set ~= nil and holdsAhead(set) then
            self:reset()
            ADHeldRemovals.release()
        end
        return autoDriveStuck(self, ...)
    end
end

-- Into the game's save, the same way the junction registry does it (JxRegistry.lua). Never lets a
-- failure here stop the game's own save.
if ItemSystem ~= nil and type(ItemSystem.save) == "function" and not ItemSystem.__adFlyoverHeldHooked then
    ItemSystem.__adFlyoverHeldHooked = true
    local gameSave = ItemSystem.save
    ItemSystem.save = function(...)
        if ADHeldRemovals ~= nil then
            local ok, err = pcall(ADHeldRemovals.releaseForSave)
            if not ok then
                Logging.warning("[FlyoverEditor]: held removals - releasing before the game's save failed: %s", tostring(err))
            end
        end
        return gameSave(...)
    end
end

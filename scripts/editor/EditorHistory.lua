--[[
ADEditorHistory - undo for the flyover editor.

Snapshot-based, deliberately. The obvious cheaper design is a journal of inverse operations
("waypoint 412 moved from A to B, so undo moves 412 back"), but waypoint ids in this mod are
POSITIONAL, not stable: ADGraphManager:removeWayPoint renumbers every id above the deleted one
(GraphManager.lua:288, complete with the author's own ":("). Any stored id is therefore invalidated
by an unrelated later delete, and the corruption is silent - undo would move the wrong waypoint.
Snapshots sidestep the whole problem because they restore the numbering along with the data.

The cost is a deep copy of the graph per action. For a large network (~7000 waypoints) that is on
the order of a megabyte and a few milliseconds, which is fine at the rate a human clicks, and the
stack is capped so it cannot grow without bound.
]]

ADEditorHistory = {
    stack = {},
    -- Undone states, so they can be put back. Cleared by any new edit: once you change something
    -- after undoing, the branch you undid is no longer reachable and pretending otherwise would
    -- redo into a graph that no longer matches.
    redoStack = {},
    -- Deep enough to cover a run of edits that went wrong without holding the whole session's
    -- graph history in memory.
    MAX_ENTRIES = 25
}

local function copyIdList(list)
    local out = {}
    if list ~= nil then
        for i = 1, #list do
            out[i] = list[i]
        end
    end
    return out
end

--- COMPANION EDIT: copy every field, rather than an allowlist of the eight this build happens to
--- have. The allowlist matched GraphManager's waypoint shape in the build it was written against;
--- any field a newer AutoDrive adds would be stripped from every waypoint by one keypress, marked
--- dirty, and written to the player's route file. That is a bad trade for a guest mod, and copying
--- generically costs the same.
local function copyWayPoints(wayPoints)
    local copy = {}
    for i = 1, #wayPoints do
        local wp = wayPoints[i]
        local c = {}
        for k, v in pairs(wp) do
            if k == "out" or k == "incoming" then
                c[k] = copyIdList(v)
            elseif type(v) == "table" then
                local t = {}
                for tk, tv in pairs(v) do
                    t[tk] = tv
                end
                c[k] = t
            else
                c[k] = v
            end
        end
        copy[i] = c
    end
    return copy
end

local function copyMapMarkers(markers)
    local copy = {}
    for index, marker in pairs(markers) do
        local m = {}
        for k, v in pairs(marker) do
            m[k] = v
        end
        copy[index] = m
    end
    return copy
end

local function copyGroups(groups)
    local copy = {}
    for name, id in pairs(groups or {}) do
        copy[name] = id
    end
    return copy
end

--- A copy of the graph as it stands right now.
local function captureState(label)
    return {
        label = label or "edit",
        wayPoints = copyWayPoints(ADGraphManager:getWayPoints()),
        mapMarkers = copyMapMarkers(ADGraphManager:getMapMarkers()),
        groups = copyGroups(ADGraphManager:getGroups())
    }
end

--[[ PARKING SPOTS FOLLOW THEIR NAME (issue #24, 2026-10-16)

AutoDrive keeps a vehicle's parking spot as a NUMBER: its place in the list of names, not the name.
When a name is deleted, AutoDrive moves every later parking spot up one place to match. An undo that
puts the deleted name back did not move them down again, so every parking spot after it now named the
name before it - and each delete + undo stepped them one further through the list.

Before an undo or redo changes the list, note the name (and where it stands) each parking spot points
at; afterwards point each one at that name's new place. A name the undo took away clears the parking
spot (-1), the same as AutoDrive does when a name is deleted. Two places hold it: the vehicle's own
(stateModule) and each tool's (advd) - AutoDrive's removeMapMarker shifts both.
]]
local function rememberParkSpots()
    local held = {}
    local markers, wps = ADGraphManager:getMapMarkers(), ADGraphManager:getWayPoints()
    local function note(vehicle, kind, index)
        local m = type(index) == "number" and markers[index] or nil
        if m == nil or m.name == nil then return end
        local wp = wps[m.id]
        table.insert(held, { vehicle = vehicle, kind = kind, index = index, name = m.name,
            x = wp ~= nil and wp.x or nil, z = wp ~= nil and wp.z or nil })
    end
    for _, vehicle in pairs(AutoDrive.getAllVehicles()) do
        if vehicle ~= nil then
            local sm = vehicle.ad ~= nil and vehicle.ad.stateModule or nil
            if sm ~= nil and sm.getParkDestinationAtJobFinished ~= nil then
                note(vehicle, "vehicle", sm:getParkDestinationAtJobFinished())
            end
            if vehicle.advd ~= nil then
                note(vehicle, "tool", vehicle.advd.parkDestination)
            end
        end
    end
    return held
end

local function putParkSpotsBack(held)
    if held == nil or #held == 0 then return end
    local markers, wps = ADGraphManager:getMapMarkers(), ADGraphManager:getWayPoints()
    local moved, cleared = 0, 0
    for _, h in ipairs(held) do
        -- the same name; if several carry it, the one nearest where it stood
        local best, bestD = -1, math.huge
        for i = 1, #markers do
            local m = markers[i]
            if m ~= nil and m.name == h.name and m.isADDebug ~= true then
                local wp = wps[m.id]
                local d = 0
                if wp ~= nil and h.x ~= nil then d = (wp.x - h.x) ^ 2 + (wp.z - h.z) ^ 2 end
                if d < bestD then best, bestD = i, d end
            end
        end
        if best ~= h.index then
            if h.kind == "vehicle" then
                h.vehicle.ad.stateModule:setParkDestinationAtJobFinished(best)
            else
                -- the field, not setParkDestination: that one sends an event and also overwrites the
                -- root vehicle's own spot with the tool's
                h.vehicle.advd.parkDestination = best
            end
            if best == -1 then cleared = cleared + 1 else moved = moved + 1 end
        end
    end
    if moved + cleared > 0 then
        Logging.info("[FlyoverEditor]: undo - %d parking spot(s) kept on their name, %d cleared (their name is gone).",
            moved, cleared)
    end
end

-- Never lets a fault here stop the undo itself.
local function safely(f, ...)
    local ok, result = pcall(f, ...)
    if not ok then
        Logging.warning("[FlyoverEditor] ADEditorHistory: parking spots not checked: %s", tostring(result))
        return nil
    end
    return result
end

--- COMPANION EDIT: a full graph swap has to do more than swap the graph. AutoDrive's own
--- equivalent is AutoDriveRoutesUploadEvent:run, which does six things here; this did two, and the
--- comment justifying the `false` was simply wrong.
local function restoreState(entry)
    local parks = safely(rememberParkSpots)
    ADGraphManager:setWayPoints(entry.wayPoints)
    ADGraphManager:setMapMarkers(entry.mapMarkers)

    -- true, not false. The updateVehicles branch is the ONLY code that rewrites vehicle.ad.groups
    -- from the new list - the waypoint swap does not touch it. Without it, undoing a group creation
    -- leaves every vehicle holding a key for a group that no longer exists, and that map is
    -- serialised per vehicle, so the phantom survives a save and reload.
    ADGraphManager:setGroups(entry.groups, true)

    -- Vehicles hold map markers as direct TABLE references into ADGraphManager's list, and the
    -- snapshot built brand-new tables. Without this every vehicle keeps an orphan whose marker
    -- index may now name a different destination - and it is the wrong index that gets saved.
    for _, vehicle in pairs(AutoDrive.getAllVehicles()) do
        if vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil
            and vehicle.ad.stateModule.resetMarkersOnReload ~= nil then
            vehicle.ad.stateModule:resetMarkersOnReload()
        end
    end
    safely(putParkSpotsBack, parks)

    -- setMapMarkers deliberately does not notify, on the grounds that its caller will. We are the
    -- caller. The listener is what rebuilds the map hotspots, so without this the map keeps
    -- hotspots for markers the undo just deleted.
    if AutoDrive.notifyDestinationListeners ~= nil then
        AutoDrive:notifyDestinationListeners()
    end
    -- Forces the HUD destination pulldown to rebuild.
    if AutoDrive.Hud ~= nil then
        AutoDrive.Hud.lastUIScale = 0
    end

    ADGraphManager:markChanges()
end

--- Capture the current graph before an edit. Call this BEFORE mutating, once per user-visible
--- action - not once per waypoint inside a loop, or undo becomes single-step-at-a-time.
function ADEditorHistory:snapshot(label)
    return self:commit(self:capture(label))
end

--- Capture the graph now WITHOUT putting it on the stack: half of snapshot(), for an action that
--- cannot tell before it starts whether it will change anything. The junction clear cleans its site
--- first and only then knows whether there is anything to clear. Capture before the first edit, then
--- commit() once something has changed, or drop the capture if nothing did. Snapshotting and popping
--- it again would not do: a snapshot empties the redo stack, so an action that changed nothing would
--- still throw the redo away. Returns nil if the graph could not be copied.
function ADEditorHistory:capture(label)
    local ok, entry = pcall(captureState, label)
    if not ok then
        Logging.error("[FlyoverEditor] ADEditorHistory: failed to snapshot before '%s': %s", tostring(label), tostring(entry))
        return nil
    end
    return entry
end

--- Put a capture() on the stack, once the action it was taken for has changed something. False for a
--- capture that failed, as snapshot() returns.
function ADEditorHistory:commit(entry)
    if entry == nil then return false end
    table.insert(self.stack, entry)
    self.redoStack = {}

    -- Drop the oldest once past the cap. table.remove from the front is O(n) on the stack depth
    -- (25), not on the graph size, so this is cheap regardless of network size.
    while #self.stack > self.MAX_ENTRIES do
        table.remove(self.stack, 1)
    end
    return true
end

--- Fold every entry above `entry` into it, so one undo takes back a pair of actions done as one (the
--- junction tool's clear + build). An entry is the graph BEFORE its action, so keeping the lowest keeps
--- the graph from before the first. False when `entry` is no longer on the stack.
function ADEditorHistory:foldOnto(entry)
    if entry == nil then return false end
    for i = #self.stack, 1, -1 do
        if self.stack[i] == entry then
            while #self.stack > i do table.remove(self.stack) end
            return true
        end
    end
    return false
end

function ADEditorHistory:canUndo()
    return #self.stack > 0
end

function ADEditorHistory:depth()
    return #self.stack
end

--- Restore the most recent snapshot. Returns the label of what was undone, or nil.
function ADEditorHistory:undo()
    if #self.stack == 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor] ADEditorHistory: nothing to undo.")
        return nil
    end

    -- COMPANION EDIT: peek, do not pop. Popping before the restore meant a throw inside
    -- setMapMarkers lost the snapshot AND left waypoints from one state with markers from
    -- another, with no way back. Only commit once the restore has actually succeeded.
    local entry = self.stack[#self.stack]
    local ok, err = pcall(function()
        -- Keep where we are, so it can be redone.
        table.insert(self.redoStack, captureState(entry.label))
        restoreState(entry)
    end)
    if not ok then
        Logging.error("[FlyoverEditor] ADEditorHistory: failed to restore snapshot '%s': %s", tostring(entry.label), tostring(err))
        return nil
    end

    table.remove(self.stack)
    ADFlyoverSettings.debugLog("[FlyoverEditor] ADEditorHistory: undid '%s' (%d undo, %d redo available).",
        tostring(entry.label), #self.stack, #self.redoStack)
    return entry.label
end

function ADEditorHistory:canRedo()
    return #self.redoStack > 0
end

function ADEditorHistory:redoDepth()
    return #self.redoStack
end

--- Put back the most recently undone state.
function ADEditorHistory:redo()
    if #self.redoStack == 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor] ADEditorHistory: nothing to redo.")
        return nil
    end

    -- COMPANION EDIT: peek, do not pop. Popping before the restore meant a throw inside
    -- setMapMarkers lost the snapshot AND left waypoints from one state with markers from
    -- another, with no way back. Only commit once the restore has actually succeeded.
    local entry = self.redoStack[#self.redoStack]
    local ok, err = pcall(function()
        -- Symmetric with undo: keep where we are so it can be undone again.
        table.insert(self.stack, captureState(entry.label))
        restoreState(entry)
    end)
    if not ok then
        Logging.error("[FlyoverEditor] ADEditorHistory: failed to redo '%s': %s", tostring(entry.label), tostring(err))
        return nil
    end

    table.remove(self.redoStack)
    ADFlyoverSettings.debugLog("[FlyoverEditor] ADEditorHistory: redid '%s' (%d undo, %d redo available).",
        tostring(entry.label), #self.stack, #self.redoStack)
    return entry.label
end

function ADEditorHistory:clear()
    self.stack = {}
    self.redoStack = {}
end

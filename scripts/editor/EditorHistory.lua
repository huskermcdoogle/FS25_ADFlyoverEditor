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

--[[ ACTIONS, NOT COPIES (multiplayer step 1, 2026-10-16)

Undo now plays recorded actions backwards instead of swapping in a whole copy of the network. The
recording is ADFlyoverGraphOps (GraphOps.lua): it compares the network at the start of an action with
the network at the start of the next one, by tag, and keeps exactly what changed, before and after.
The id problem described at the top of this file is gone because an action names points by tag, not
by number. Proven exact forwards and backwards on a 17k network (tools/mp-probe/door_check.lua).

The stack keeps the shape the tools rely on: an entry goes on the stack when an action STARTS
(snapshot, or commit after capture), so a tool can still compare the top of the stack before and after
to see whether its action did anything. The entry is filled in at the next boundary (the next action,
an undo or redo, opening the editor) - flush() - with what changed in between.

Each entry: { label, actions = { action, ... } }. Usually one action; foldOnto() joins entries.
Changes nobody announced (AutoDrive recording a route, say) become their own entry, "changes made
outside the editor", so undo never quietly takes them back together with an editor action.

If GraphOps is missing, or ADFlyoverGraphOps.USE_FOR_UNDO is false, the old copy-based undo above
runs unchanged.
]]

local OUTSIDE_LABEL = "changes made outside the editor"

local function graphNow()
    return { wayPoints = ADGraphManager:getWayPoints(), mapMarkers = ADGraphManager:getMapMarkers(),
             groups = ADGraphManager:getGroups() }
end

local function useActions()
    return ADFlyoverGraphOps ~= nil and ADFlyoverGraphOps.USE_FOR_UNDO ~= false
end

-- The network as it stood at the last boundary, and the table it was taken from: a different table
-- means AutoDrive swapped the whole network (savegame load, route import), and nothing recorded
-- before that can be played on it.
ADEditorHistory.shadow = nil
ADEditorHistory.shadowOf = nil
ADEditorHistory.open = nil

local function retake(self)
    local g = graphNow()
    self.shadow = ADFlyoverGraphOps.capture(g)
    self.shadowOf = g.wayPoints
end

function ADEditorHistory:push(entry)
    table.insert(self.stack, entry)
    self.redoStack = {}
    while #self.stack > self.MAX_ENTRIES do
        table.remove(self.stack, 1)
    end
end

--- Record whatever changed since the last boundary into the open entry (or a new "outside" entry).
--- Returns the action recorded, or nil.
function ADEditorHistory:flush()
    if not useActions() then return nil end
    local g = graphNow()
    if self.shadow == nil or self.shadowOf ~= g.wayPoints then
        if self.shadow ~= nil and (#self.stack > 0 or #self.redoStack > 0) then
            Logging.info("[FlyoverEditor] ADEditorHistory: the whole network was replaced; the undo history no longer fits it and is cleared.")
            self.stack, self.redoStack = {}, {}
        end
        retake(self)
        self.open = nil
        return nil
    end
    local open = self.open
    self.open = nil
    local clock = getTimeSec
    local t0 = clock ~= nil and clock() or 0
    local action, afterOrWhy = ADFlyoverGraphOps.diff(self.shadow, g, open and open.label or OUTSIDE_LABEL)
    local tDiff = (clock ~= nil and clock() or 0) - t0
    if action == nil then
        if afterOrWhy ~= "nothing changed" then
            -- a change the door cannot describe: nothing recorded before it can be played any more
            Logging.warning("[FlyoverEditor] ADEditorHistory: %s - undo history cleared.", tostring(afterOrWhy))
            self.stack, self.redoStack = {}, {}
            retake(self)
        end
        return nil
    end
    self.shadow = afterOrWhy
    if open ~= nil then
        table.insert(open.actions, action)
    else
        self:push({ label = OUTSIDE_LABEL, actions = { action } })
    end
    ADFlyoverSettings.debugLog("[FlyoverEditor] ADEditorHistory: recorded %s", ADFlyoverGraphOps.describe(action))
    -- MULTIPLAYER STEP 2: pack every action the way the network will carry it, check it comes back the
    -- same, and log the size. Nothing is sent. Never lets a fault here touch the undo.
    if ADFlyoverActionCodec ~= nil then
        self.packCount = (self.packCount or 0) + 1
        local t1 = clock ~= nil and clock() or 0
        local ok, bytes, pieces, same, why = pcall(ADFlyoverActionCodec.roundTrip, action, self.packCount)
        local tPack = (clock ~= nil and clock() or 0) - t1
        if not ok then
            Logging.warning("[FlyoverEditor]: pack check - '%s' FAILED: %s", tostring(action.label), tostring(bytes))
        else
            Logging.info("[FlyoverEditor]: pack check - '%s' %s: %d byte(s) in %d piece(s); recorded in %.0f ms, packed in %.0f ms (%d points).",
                tostring(action.label), same and "ok" or ("FAILED: " .. tostring(why)), #bytes, #pieces,
                tDiff * 1000, tPack * 1000, #g.wayPoints)
        end
    end
    return action
end

-- What a whole-network swap did besides the swap (restoreState above), for actions that touched
-- markers or groups. Points keep their tables, so vehicles holding them are not disturbed.
local function afterPlayback(actions)
    local markers, groups = false, false
    for _, a in ipairs(actions) do
        if a.markers ~= nil then markers = true end
        if a.groups ~= nil then groups = true end
    end
    if groups then ADGraphManager:setGroups(ADGraphManager:getGroups(), true) end
    if markers then
        for _, vehicle in pairs(AutoDrive.getAllVehicles()) do
            if vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil
                and vehicle.ad.stateModule.resetMarkersOnReload ~= nil then
                vehicle.ad.stateModule:resetMarkersOnReload()
            end
        end
        if AutoDrive.notifyDestinationListeners ~= nil then AutoDrive:notifyDestinationListeners() end
    end
    if AutoDrive.Hud ~= nil then AutoDrive.Hud.lastUIScale = 0 end
    ADGraphManager:markChanges()
end

local function play(self, entry, backwards)
    local g = graphNow()
    local parks = safely(rememberParkSpots)
    local list = entry.actions
    local from, to, step = 1, #list, 1
    if backwards then from, to, step = #list, 1, -1 end
    for i = from, to, step do
        local ok, why = ADFlyoverGraphOps.apply(g, list[i], backwards)
        if not ok then return why end
    end
    afterPlayback(list)
    safely(putParkSpotsBack, parks)
    retake(self)
    return true
end

--- Mark the start of an action. Call this BEFORE mutating, once per user-visible action - not once
--- per waypoint inside a loop, or undo becomes single-step-at-a-time.
function ADEditorHistory:snapshot(label)
    if useActions() then
        self:flush()
        local entry = { label = label or "edit", actions = {} }
        self:push(entry)
        self.open = entry
        return true
    end
    return self:commit(self:capture(label))
end

--- Capture the graph now WITHOUT putting it on the stack: half of snapshot(), for an action that
--- cannot tell before it starts whether it will change anything. The junction clear cleans its site
--- first and only then knows whether there is anything to clear. Capture before the first edit, then
--- commit() once something has changed, or drop the capture if nothing did. Snapshotting and popping
--- it again would not do: a snapshot empties the redo stack, so an action that changed nothing would
--- still throw the redo away. Returns nil if the graph could not be copied.
function ADEditorHistory:capture(label)
    if useActions() then
        -- a boundary now; the changes from here until the next one belong to this capture once committed
        self:flush()
        return { label = label or "edit", actions = {}, captured = true }
    end
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
    if useActions() and entry.captured then
        entry.captured = nil
        self:push(entry)
        self.open = entry
        return true
    end
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
--- junction tool's clear + build). False when `entry` is no longer on the stack.
function ADEditorHistory:foldOnto(entry)
    if entry == nil then return false end
    if useActions() then self:flush() end
    for i = #self.stack, 1, -1 do
        if self.stack[i] == entry then
            while #self.stack > i do
                local above = table.remove(self.stack, i + 1)
                if useActions() and entry.actions ~= nil and above.actions ~= nil then
                    for _, a in ipairs(above.actions) do table.insert(entry.actions, a) end
                end
            end
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

--- Undo the most recent action. Returns the label of what was undone, or nil.
function ADEditorHistory:undo()
    if useActions() then self:flush() end
    if #self.stack == 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor] ADEditorHistory: nothing to undo.")
        return nil
    end
    local entry = self.stack[#self.stack]

    if useActions() and entry.actions ~= nil then
        local ok, result = pcall(play, self, entry, true)
        if not ok or result ~= true then
            Logging.error("[FlyoverEditor] ADEditorHistory: could not undo '%s' (%s) - undo history cleared.",
                tostring(entry.label), tostring(result))
            self.stack, self.redoStack = {}, {}
            retake(self)
            return nil
        end
        table.remove(self.stack)
        table.insert(self.redoStack, entry)
        -- always logged: the in-game test card ticks itself from it
        Logging.info("[FlyoverEditor]: undo (actions) - undid '%s' in %d step(s) (%d undo, %d redo available).",
            tostring(entry.label), #entry.actions, #self.stack, #self.redoStack)
        return entry.label
    end

    -- COMPANION EDIT: peek, do not pop. Popping before the restore meant a throw inside
    -- setMapMarkers lost the snapshot AND left waypoints from one state with markers from
    -- another, with no way back. Only commit once the restore has actually succeeded.
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

--- Put back the most recently undone action.
function ADEditorHistory:redo()
    -- anything changed since the undo becomes an entry of its own, and that empties the redo stack
    if useActions() then self:flush() end
    if #self.redoStack == 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor] ADEditorHistory: nothing to redo.")
        return nil
    end
    local entry = self.redoStack[#self.redoStack]

    if useActions() and entry.actions ~= nil then
        local ok, result = pcall(play, self, entry, false)
        if not ok or result ~= true then
            Logging.error("[FlyoverEditor] ADEditorHistory: could not redo '%s' (%s) - undo history cleared.",
                tostring(entry.label), tostring(result))
            self.stack, self.redoStack = {}, {}
            retake(self)
            return nil
        end
        table.remove(self.redoStack)
        table.insert(self.stack, entry)
        Logging.info("[FlyoverEditor]: undo (actions) - redid '%s' in %d step(s) (%d undo, %d redo available).",
            tostring(entry.label), #entry.actions, #self.stack, #self.redoStack)
        return entry.label
    end

    -- COMPANION EDIT: peek, do not pop. Popping before the restore meant a throw inside
    -- setMapMarkers lost the snapshot AND left waypoints from one state with markers from
    -- another, with no way back. Only commit once the restore has actually succeeded.
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
    self.open = nil
    -- the next boundary takes the network afresh; nothing before now is recorded
    self.shadow, self.shadowOf = nil, nil
end

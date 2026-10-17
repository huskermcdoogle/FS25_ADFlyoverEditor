--[[ ADFlyoverNetGame - THE MULTIPLAYER EDITOR IN THE GAME (glue between FS25 and NetCore)

NetCore.lua holds the rules and is proven offline (tools/mp-probe/sim.lua, undo_story.lua). This file
only connects them to the game:

  - who we are: the server (with or without a host player at it) or a player who joined
  - the network message (scripts/NetEvent.lua, registered early) in and out: actions cut into pieces,
    joined again on arrival
  - when an action is finished (the boundaries): EditorHistory tells us at every snapshot, undo and
    redo; and every frame, a short quiet moment after the last change while no mouse button is held
  - undo and redo go to NetCore's per-player undo instead of EditorHistory's stack
  - after someone else's change lands: AutoDrive is told (HUD, markers, parking spots), the editor
    forgets the waypoint numbers it was holding
  - the safety net for AutoDrive's OWN editing (recording a route, AutoDrive's editor, route import),
    which reaches every PC through AutoDrive's own messages, behind ours: those changes are taken in
    without being sent again, and a player whose network got points that way (no shared tags) loads the
    whole network again shortly after

Single player never starts any of this: active stays false, and every hook is a no-op.

UNTESTED IN THE GAME as of 2026-10-16: no second player has joined yet. Every rule it calls is tested
offline; this file is the part only a real session can check.
]]

ADFlyoverNetGame = ADFlyoverNetGame or {}
local NG = ADFlyoverNetGame
local G, C, N = ADFlyoverGraphOps, ADFlyoverActionCodec, ADFlyoverNet

NG.K = { ACTION = 1, UNDO = 2, HELLO = 3, APPLIED = 11, REFUSED = 12, BLOCKED = 13, WHOLE = 14 }
local K = NG.K
NG.QUIET_MS = 150          -- a boundary this long after the last change, when no button is held
NG.RELOAD_AFTER_MS = 3000  -- a player whose network AutoDrive added points to reloads this long after the last one
NG.RELOAD_AT_MOST_MS = 15000

NG.active = false
NG.graph = {}

local function log(fmt, ...) Logging.info("[FlyoverEditor]: multiplayer - " .. fmt, ...) end
local function nowMs() return (g_time or 0) end

function NG.isMultiplayer()
    local m = g_currentMission
    return m ~= nil and m.missionDynamicInfo ~= nil and m.missionDynamicInfo.isMultiplayer == true
end

function NG.myId()
    return g_currentMission ~= nil and g_currentMission.playerUserId or nil
end

function NG.nameOf(id)
    if id == nil then return "someone" end
    local ok, name = pcall(function()
        local user = g_currentMission.userManager:getUserByUserId(id)
        return user ~= nil and user:getNickname() or nil
    end)
    if ok and name ~= nil and name ~= "" then return name end
    return "player " .. tostring(id)
end
N.nameOf = NG.nameOf

-- A player's block of tags: never 0 (the server's), never so big it leaves Lua's whole numbers.
local function slotOf(id)
    id = tonumber(id) or 1
    if id < 1 or id > 500000 then id = (math.abs(math.floor(id)) % 500000) + 1 end
    return id
end

--- Point NG.graph at AutoDrive's tables. True when AutoDrive swapped its whole point list since last time.
local function refresh()
    local w = ADGraphManager:getWayPoints()
    local replaced = NG.lastWps ~= nil and w ~= NG.lastWps
    NG.graph.wayPoints, NG.graph.mapMarkers, NG.graph.groups = w, ADGraphManager:getMapMarkers(), ADGraphManager:getGroups()
    NG.lastWps = w
    return replaced
end

local function hasUntagged()
    for _, wp in ipairs(NG.graph.wayPoints or {}) do
        if wp.fxTag == nil then return true end
    end
    return false
end

local function markerSignature()
    local parts = {}
    for i, m in ipairs(ADGraphManager:getMapMarkers() or {}) do parts[i] = tostring(m.id) .. "=" .. tostring(m.name) end
    return table.concat(parts, ";")
end

local function say(text)
    if text == nil or text == "" then return end
    log("%s", text)
    if ADFlyoverEditor ~= nil and ADFlyoverEditor.showWarning ~= nil then
        pcall(ADFlyoverEditor.showWarning, ADFlyoverEditor, text)
    end
end

--- After the network changed under the editor (someone else's action, an undo coming back, a reload):
--- what AutoDrive and the editor need to hear. `run` does the change; parking spots are kept on their
--- names across it (issue #24), markers and HUD refreshed.
local function changeUnder(run)
    local sig0 = markerSignature()
    NG.applying = true
    local ok, err
    if ADEditorHistory ~= nil and ADEditorHistory.keepParkSpots ~= nil then
        ok, err = pcall(ADEditorHistory.keepParkSpots, run)
    else
        ok, err = pcall(run)
    end
    if not ok then Logging.error("[FlyoverEditor]: multiplayer - applying a change failed: %s", tostring(err)) end
    if markerSignature() ~= sig0 then
        for _, vehicle in pairs(AutoDrive.getAllVehicles()) do
            if vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil
                and vehicle.ad.stateModule.resetMarkersOnReload ~= nil then
                pcall(vehicle.ad.stateModule.resetMarkersOnReload, vehicle.ad.stateModule)
            end
        end
        if AutoDrive.notifyDestinationListeners ~= nil then pcall(AutoDrive.notifyDestinationListeners, AutoDrive) end
    end
    if AutoDrive.Hud ~= nil then AutoDrive.Hud.lastUIScale = 0 end
    ADGraphManager:markChanges()
    NG.applying = false
    if ADFlyoverEditor ~= nil and ADFlyoverEditor.invalidateIdReferences ~= nil then
        pcall(ADFlyoverEditor.invalidateIdReferences, ADFlyoverEditor)
    end
    return ok
end

-- ---------------------------------------------------------------- messages <-> events
local function piecesOf(id, bytes)
    if bytes == nil then return { { id = id, index = 1, count = 0, bytes = "" } } end
    return C.cut(id, bytes)
end

--- A NetCore message as one or more events.
local function encode(msg)
    local evs = {}
    local E = ADFlyoverNetEvent
    if msg.kind == "action" then
        for _, p in ipairs(piecesOf(msg.localId, msg.bytes)) do
            evs[#evs + 1] = E.new(K.ACTION, { msg.localId, p.index, p.count }, "", "", p.bytes)
        end
    elseif msg.kind == "undo" or msg.kind == "redo" then
        evs[1] = E.new(K.UNDO, { msg.seq, msg.kind == "redo" and 1 or 0 })
    elseif msg.kind == "hello" then
        evs[1] = E.new(K.HELLO, {})
    elseif msg.kind == "applied" then
        for _, p in ipairs(piecesOf(msg.seq, msg.bytes)) do
            evs[#evs + 1] = E.new(K.APPLIED, { msg.seq, msg.origin or -1, msg.localId or 0, p.index, p.count,
                msg.undoOf or -1, msg.redoOf or -1 }, msg.label or "", "", p.bytes)
        end
    elseif msg.kind == "refused" then
        evs[1] = E.new(K.REFUSED, { msg.localId or 0, msg.holder or -1 }, msg.label or "", msg.why or "")
    elseif msg.kind == "blocked" then
        evs[1] = E.new(K.BLOCKED, { msg.seq or 0, msg.redo and 1 or 0, msg.byPlayer or -1 }, msg.byLabel or "", msg.why or "")
    elseif msg.kind == "whole" then
        for _, p in ipairs(piecesOf(-1 - msg.seq, msg.bytes)) do
            evs[#evs + 1] = E.new(K.WHOLE, { msg.seq, 0, 0, p.index, p.count }, "", "", p.bytes)
        end
    end
    return evs
end

local function opt(v) if v == nil or v < 0 then return nil end return v end

--- An event back into a NetCore message; nil while pieces are still missing.
local function decode(ev, sender)
    local i = ev.ints
    NG.joiners = NG.joiners or {}
    local function joined(id, index, count)
        if count == 0 then return nil, true end
        local key = tostring(sender) .. "/" .. ev.kind
        NG.joiners[key] = NG.joiners[key] or C.newJoiner()
        local whole = C.join(NG.joiners[key], { id = id, index = index, count = count, bytes = ev.bytes })
        return whole, whole ~= nil
    end
    if ev.kind == K.ACTION then
        local bytes, done = joined(i[1], i[2], i[3])
        if not done then return nil end
        return { kind = "action", localId = i[1], bytes = bytes }
    elseif ev.kind == K.UNDO then
        return { kind = i[2] == 1 and "redo" or "undo", seq = i[1] }
    elseif ev.kind == K.HELLO then
        return { kind = "hello" }
    elseif ev.kind == K.APPLIED then
        local bytes, done = joined(i[1], i[4], i[5])
        if not done then return nil end
        return { kind = "applied", seq = i[1], origin = opt(i[2]), localId = i[3], bytes = bytes,
                 undoOf = opt(i[6]), redoOf = opt(i[7]), label = ev.s1 ~= "" and ev.s1 or nil }
    elseif ev.kind == K.REFUSED then
        return { kind = "refused", localId = i[1], holder = opt(i[2]), label = ev.s1, why = ev.s2 ~= "" and ev.s2 or nil }
    elseif ev.kind == K.BLOCKED then
        return { kind = "blocked", seq = i[1], redo = i[2] == 1, byPlayer = opt(i[3]),
                 byLabel = ev.s1 ~= "" and ev.s1 or nil, why = ev.s2 }
    elseif ev.kind == K.WHOLE then
        local bytes, done = joined(-1 - i[1], i[4], i[5])
        if not done then return nil end
        return { kind = "whole", seq = i[1], bytes = bytes }
    end
    return nil
end

-- ---------------------------------------------------------------- server (and the host at it)
local function serverSend(player, msg)
    local conn = NG.conns[player]
    if conn == nil then return end
    for _, ev in ipairs(encode(msg)) do
        local ok, err = pcall(conn.sendEvent, conn, ev)
        if not ok then
            log("could not send to %s (%s) - dropping them", NG.nameOf(player), tostring(err))
            N.serverRemovePlayer(NG.server, player)
            NG.conns[player] = nil
            return
        end
    end
end

--- The host's own edits since the last boundary go out (numbered by the server, checked against zones).
function NG.hostFlush(label)
    if NG.server == nil or NG.hostId == nil then return end
    if refresh() then NG.serverReplaced() return end
    local a = G.diff(NG.hostShadow, NG.graph, label or NG.label or "edit")
    if a ~= nil then
        local ok, holder = N.serverHostAction(NG.server, NG.hostId, a)
        if not ok then
            -- NetCore took it back on the server's (= the host's) network already
            changeUnder(function() end)
            say(string.format("Not applied: %s - %s is working there.", tostring(a.label), NG.nameOf(holder)))
        end
    end
    NG.hostShadow = G.capture(NG.graph)
end

--- AutoDrive swapped the whole network (route import, a reload): tag it afresh, everyone reloads.
function NG.serverReplaced()
    refresh()
    G.tagAll(NG.graph.wayPoints)
    NG.server.graph = NG.graph
    if NG.hostId ~= nil then NG.hostShadow = G.capture(NG.graph) end
    N.serverWholeToAll(NG.server)
    log("the whole network was replaced; every player loads it again")
end

local function serverReceive(ev, connection)
    local id = nil
    pcall(function() id = g_currentMission.userManager:getUserIdByConnection(connection) end)
    if id == nil then return end
    NG.conns[id] = connection
    local msg = decode(ev, id)
    if msg == nil then return end
    NG.hostFlush("edit in progress")
    if refresh() then NG.serverReplaced() end
    local seq0 = NG.server.seq
    changeUnder(function() N.serverReceive(NG.server, id, msg) end)
    if NG.server.seq ~= seq0 and NG.hostId ~= nil then NG.hostShadow = G.capture(NG.graph) end
    -- one line per message that did something, so a tester's log shows the session
    if NG.server.seq ~= seq0 then
        log("#%d %s: %s", NG.server.seq, NG.nameOf(id), msg.kind == "action" and "an edit" or msg.kind)
    elseif msg.kind == "hello" then
        log("%s joined (or reloaded): sent the whole network (%d points)", NG.nameOf(id), #NG.graph.wayPoints)
    elseif msg.kind == "action" then
        log("%s's edit was refused (another player is working there)", NG.nameOf(id))
    end
end

-- ---------------------------------------------------------------- player who joined
local function clientSend(msg)
    for _, ev in ipairs(encode(msg)) do ADFlyoverNetEvent.toServer(ev) end
end

local function tellPlayer()
    local c = NG.client
    for i = (NG.toldRefusals or 0) + 1, #c.refusals do
        local r = c.refusals[i]
        if r.lost then
            say(string.format("The network was loaded again from the server; %d edit(s) of yours not yet confirmed were not kept.", r.lost))
        else
            say(string.format("Not applied: %s - %s is working there.", tostring(r.label), NG.nameOf(r.holder)))
        end
    end
    NG.toldRefusals = #c.refusals
    for i = (NG.toldSaid or 0) + 1, #c.said do say(c.said[i]) end
    NG.toldSaid = #c.said
end

local function clientReceive(ev)
    local msg = decode(ev, "server")
    if msg == nil then return end
    if refresh() and msg.kind ~= "whole" then
        -- AutoDrive replaced our whole network (its own route upload reached us): the server sends ours too
        NG.client.waitingForWhole = true
    end
    local ok = true
    changeUnder(function() ok = N.clientReceive(NG.client, msg) end)
    if not ok then
        log("out of step with the server - loading the whole network again")
        N.clientHello(NG.client)
    end
    if msg.kind == "whole" then
        log("loaded the whole network from the server (%d points)", #NG.graph.wayPoints)
        if ADEditorHistory ~= nil then ADEditorHistory:clear() end
    end
    tellPlayer()
end

--- This player's own edits since the last boundary go to the server.
function NG.clientFlush(label)
    if NG.client == nil then return end
    if refresh() then NG.client.waitingForWhole = true; N.clientHello(NG.client) return end
    N.clientFlush(NG.client, label or NG.label or "edit")
end

-- ---------------------------------------------------------------- the game calls these
--- Start when the editor files are in and this is a multiplayer game.
function NG.start()
    if NG.active or not NG.isMultiplayer() then return end
    if ADFlyoverNetEvent == nil then
        Logging.error("[FlyoverEditor]: multiplayer - the network message is not registered; the editor stays single-player here")
        return
    end
    NG.conns, NG.joiners = {}, {}
    NG.toldRefusals, NG.toldSaid = 0, 0
    refresh()
    if g_server ~= nil then
        G.setTagSpace(0)
        G.tagAll(NG.graph.wayPoints)
        NG.server = N.newServer({ graph = NG.graph, send = serverSend, now = nowMs, log = function(s) log("%s", s) end })
        if g_client ~= nil and NG.myId() ~= nil then
            NG.hostId = NG.myId()
            NG.hostShadow = G.capture(NG.graph)
        end
        log("started as the %s", NG.hostId ~= nil and "host" or "server (no player here)")
    else
        local me = NG.myId()
        G.setTagSpace(slotOf(me))
        NG.client = N.newClient({ graph = NG.graph, player = me, send = clientSend, log = function(s) log("%s", s) end })
        N.clientHello(NG.client)
        log("started as player %s; asked the server for the network", NG.nameOf(me))
    end
    NG.active = true
    NG.installSafetyNet()
end

function NG.stop()
    NG.active = false
    NG.server, NG.client, NG.hostId, NG.hostShadow, NG.lastWps = nil, nil, nil, nil, nil
end

--- A message arrived (NetEvent.lua calls this through ADFlyoverPrelude.netReceive).
function NG.receive(ev, connection)
    if not NG.active then return end
    if NG.server ~= nil and connection ~= nil and connection.getIsServer ~= nil and not connection:getIsServer() then
        serverReceive(ev, connection)
    elseif NG.client ~= nil then
        clientReceive(ev)
    end
end

--- A boundary: EditorHistory calls this when an action starts (so what came before is finished),
--- and before an undo or redo.
function NG.boundary()
    if not NG.active or NG.applying then return end
    if NG.server ~= nil then NG.hostFlush() elseif NG.client ~= nil then NG.clientFlush() end
end

--- Every frame: a boundary once the network has been quiet a moment and no mouse button is held; a
--- reload when AutoDrive's own editing left this player with points nobody tagged for everyone.
function NG.update(dt)
    if not NG.active then return end
    local E = ADFlyoverEditor
    local busy = E ~= nil and (E.dragId ~= nil or E.leftDown == true)
    if NG.dirtyAt ~= nil and not busy and nowMs() - NG.dirtyAt >= NG.QUIET_MS then
        NG.dirtyAt = nil
        NG.boundary()
    end
    if NG.client ~= nil and NG.reloadAt ~= nil and not busy and nowMs() >= NG.reloadAt then
        NG.reloadAt, NG.reloadFirst = nil, nil
        log("AutoDrive added points here outside the editor; loading the whole network so everyone's tags agree")
        N.clientHello(NG.client)
    end
end

--- AutoDrive's markChanges, wrapped while multiplayer is on: the network changed, a boundary is due.
function NG.noteChange()
    if NG.active and not NG.applying then NG.dirtyAt = nowMs() end
end

--- Undo / redo in multiplayer: this player's (or the host's) own newest action that still fits.
function NG.undo(redo)
    if not NG.active then return nil end
    NG.boundary()
    local text
    if NG.server ~= nil then
        if NG.hostId == nil then return nil end
        changeUnder(function() text = N.serverHostUndo(NG.server, NG.hostId, redo) end)
        NG.hostShadow = G.capture(NG.graph)
    else
        text = N.clientUndo(NG.client, redo)
        NG.toldSaid = #NG.client.said   -- said here, not again when the next message arrives
    end
    say(text)
    return text
end

--- May the editor change the network here? Single player and the server: yes. A player: once the
--- whole network has arrived.
function NG.canEdit()
    if g_server ~= nil then return true end
    return NG.active and NG.client ~= nil and not NG.client.waitingForWhole
end

-- ---------------------------------------------------------------- AutoDrive's own editing
NG.AD_GRAPH_EVENTS = {
    "AutoDriveChangeMapMarkerGroupEvent", "AutoDriveCreateMapMarkerEvent", "CreatePlaceableEvent",
    "CreateSplineConnectionEvent", "AutoDriveCreateWayPointEvent", "AutoDriveDeleteMapMarkerEvent",
    "AutoDriveDeleteWayPointsEvent", "AutoDriveMoveWayPointEvent", "AutoDriveRecordWayPointEvent",
    "AutoDriveRenameMapMarkerEvent", "AutoDriveRoutesUploadEvent", "AutoDriveSectionEvent",
    "AutoDriveSetConnectionEvent", "AutoDriveToggleConnectionEvent", "AutoDriveGroupsEvent",
    "AutoDriveDebugSettingsEvent",
}

local function beforeOutside()
    if not NG.active or NG.applying then return end
    -- our own edits so far go out first, so AutoDrive's change is not taken for ours
    NG.boundary()
end

local function afterOutside(name)
    if not NG.active or NG.applying then return end
    local replaced = refresh()
    if NG.server ~= nil then
        if replaced then NG.serverReplaced() return end
        -- the players apply AutoDrive's change themselves; here it is only taken in, and new points tagged
        G.tagAll(NG.graph.wayPoints)
        if NG.hostId ~= nil then NG.hostShadow = G.capture(NG.graph) end
    elseif NG.client ~= nil then
        if replaced then NG.client.waitingForWhole = true; N.clientHello(NG.client) return end
        if hasUntagged() then
            local now = nowMs()
            NG.reloadFirst = NG.reloadFirst or now
            NG.reloadAt = math.min(now + NG.RELOAD_AFTER_MS, NG.reloadFirst + NG.RELOAD_AT_MOST_MS)
        end
        -- taken in, not sent: everyone gets it from AutoDrive
        NG.client.shadow = G.capture(NG.graph)
    end
end

function NG.installSafetyNet()
    if NG.netInstalled then return end
    NG.netInstalled = true
    local env = ADFlyoverArming ~= nil and ADFlyoverArming.env or nil
    local wrapped = 0
    for _, name in ipairs(NG.AD_GRAPH_EVENTS) do
        local cls = (env ~= nil and env[name]) or _G[name]
        if type(cls) == "table" and type(cls.run) == "function" and not cls.__fxWrapped then
            local original = cls.run
            cls.__fxWrapped = true
            cls.run = function(self, ...)
                pcall(beforeOutside)
                local results = { original(self, ...) }
                local ok, err = pcall(afterOutside, name)
                if not ok then Logging.error("[FlyoverEditor]: multiplayer - after %s: %s", name, tostring(err)) end
                return unpack(results)
            end
            wrapped = wrapped + 1
        end
    end
    -- every change to the network (ours and AutoDrive's) passes markChanges: that is the boundary clock
    if not ADGraphManager.__fxMarkWrapped then
        ADGraphManager.__fxMarkWrapped = true
        local mark = ADGraphManager.markChanges
        ADGraphManager.markChanges = function(...)
            NG.noteChange()
            return mark(...)
        end
    end
    log("watching %d of AutoDrive's own network messages", wrapped)
end

if ADFlyoverPrelude ~= nil then
    ADFlyoverPrelude.netReceive = function(ev, connection) NG.receive(ev, connection) end
end

--[[ ADFlyoverNet - WHO DOES WHAT IN MULTIPLAYER (steps 3-5), with no game in it

The rules of the multiplayer editor as plain Lua, so they run and are tested offline
(tools/mp-probe/sim.lua plays a server and several players against each other). The game side (step 3+,
events) only carries the messages this file hands it and calls back in when one arrives.

THE SERVER keeps the one true network and puts every change in one order.
  - A player's action arrives as bytes (ActionCodec). The server checks its zones, then REPLAYS the
    action by tag on its own network (GraphOps.replay - other players' actions may have got in first),
    writes down exactly what that did (GraphOps.diff), gives it the next number, and sends that exact
    action to every player, the sender included.
  - The host plays on the server's own network: its actions are already applied, so the server only
    checks zones (and takes the action back if the spot is someone else's), numbers it and sends it.

A PLAYER applies its own edits at once (it feels like single player) and sends them. Until the server's
copy comes back they are "pending". When anything arrives from the server, the player:
  1. takes its pending actions back (exactly, newest first),
  2. applies the server's action (exactly - the network is now the server's as of the action before),
  3. drops its own action from pending if this was it,
  4. puts the rest of its pending actions back on top (replay by tag) and writes down again exactly
     what each did.
Zones mean two players' actions do not touch the same places, so step 4 always fits.

ZONES (step 5, claimed when an action is made; claiming at the start of a gesture is step 7). The
server divides the map into squares the size of the zone radius (default 15 m, a server setting). An
action takes every square within one square of each point whose PLACE it changes (moved, deleted,
added). Links do not take squares: a link belongs to whoever makes it (user, 2026-10-16). A square
taken by another player, still held, refuses the action; squares are held for `linger` ms after the
holder's last action. A refused action comes back to its player, who takes it back.
]]

ADFlyoverNet = ADFlyoverNet or {}
local N = ADFlyoverNet
local G = ADFlyoverGraphOps
local C = ADFlyoverActionCodec

N.ZONE_RADIUS = 15
N.ZONE_LINGER_MS = 2000

-- ---------------------------------------------------------------- zones
local function cellKey(cx, cz) return cx .. ":" .. cz end

--- The squares an action needs: around every point whose place it changes.
function N.cellsOf(a, size)
    local cells, list = {}, {}
    local function around(x, z)
        if x == nil or z == nil then return end
        local cx, cz = math.floor(x / size), math.floor(z / size)
        for dx = -1, 1 do
            for dz = -1, 1 do
                local k = cellKey(cx + dx, cz + dz)
                if not cells[k] then cells[k] = true; list[#list + 1] = k end
            end
        end
    end
    for _, p in ipairs(a.dels) do around(p.x, p.z) end
    for _, p in ipairs(a.adds) do around(p.x, p.z) end
    for _, s in ipairs(a.sets) do around(s.before.x, s.before.z); around(s.after.x, s.after.z) end
    table.sort(list)
    return list
end

-- ---------------------------------------------------------------- server
function N.newServer(o)
    return {
        graph = o.graph,             -- { wayPoints, mapMarkers, groups }, AutoDrive's own on the server
        send = o.send,               -- function(player, msg)
        players = {},                -- player -> true
        now = o.now or function() return 0 end,
        zoneSize = o.zoneRadius or N.ZONE_RADIUS,
        linger = o.linger or N.ZONE_LINGER_MS,
        zones = {},                  -- cell -> { player, untilMs }
        seq = 0,
        stats = { applied = 0, refused = 0, skipped = 0 },
        history = {}, historyOrder = {},   -- seq -> { player, action, label, state = done|undone|dead }
        lastBy = {},                       -- tag -> { player, label }: who changed that point last
        hostRedo = {},
        log = o.log or function() end,
    }
end

function N.serverAddPlayer(s, player) s.players[player] = true end
function N.serverRemovePlayer(s, player)
    s.players[player] = nil
    for k, z in pairs(s.zones) do if z.player == player then s.zones[k] = nil end end
end

--- Who holds the squares this action needs (nil when they are free or the player's own).
local function blocker(s, player, cells)
    local now = s.now()
    for _, k in ipairs(cells) do
        local z = s.zones[k]
        if z ~= nil and z.player ~= player and z.untilMs > now then return z.player end
    end
    return nil
end

local function take(s, player, cells)
    local untilMs = s.now() + s.linger
    for _, k in ipairs(cells) do s.zones[k] = { player = player, untilMs = untilMs } end
end

local function killRedo(s, player)
    for _, seq in ipairs(s.historyOrder) do
        local e = s.history[seq]
        if e ~= nil and e.player == player and e.state == "undone" then e.state = "dead" end
    end
end

local function broadcast(s, msg)
    for p in pairs(s.players) do s.send(p, msg) end
end

--- Zones in use now, for the tints and the corner legend: { cell -> player }.
function N.serverZones(s)
    local now, out = s.now(), {}
    for k, z in pairs(s.zones) do if z.untilMs > now then out[k] = z.player end end
    return out
end

--- The whole network as one action from nothing: every point with its tag and links, markers, groups.
--- What a player gets on joining, and when it is out of step (the reload).
function N.wholeNetwork(graph)
    local empty = { order = {}, pts = {}, markers = {}, groups = {} }
    local a = G.diff(empty, graph, "whole network")
    return a
end

--- A message from a player.
function N.serverReceive(s, player, msg)
    if msg.kind == "hello" then
        -- joined, or out of step: the whole network as it is now, then every action after it (one line,
        -- in order, so nothing can fall between)
        s.players[player] = true
        s.send(player, { kind = "whole", seq = s.seq, bytes = C.pack(N.wholeNetwork(s.graph)) })
        return
    end
    if msg.kind == "undo" or msg.kind == "redo" then
        local ok, refusal = N.serverUndo(s, player, msg.seq, msg.kind == "redo")
        if not ok then s.send(player, refusal) end
        return
    end
    if msg.kind ~= "action" then return end
    local a = C.unpack(msg.bytes)
    local cells = N.cellsOf(a, s.zoneSize)
    local holder = blocker(s, player, cells)
    if holder ~= nil then
        s.stats.refused = s.stats.refused + 1
        s.log(string.format("refused %s's '%s': the spot is %s's", tostring(player), tostring(a.label), tostring(holder)))
        s.send(player, { kind = "refused", localId = msg.localId, holder = holder, label = a.label })
        return
    end
    local before = G.capture(s.graph)
    local ok, skipped = G.replay(s.graph, a, false)
    if not ok then
        s.send(player, { kind = "refused", localId = msg.localId, holder = nil, label = a.label, why = skipped[1] })
        return
    end
    s.stats.skipped = s.stats.skipped + #skipped
    take(s, player, cells)
    local exact, why2 = G.diff(before, s.graph, a.label)
    if exact == nil and why2 ~= "nothing changed" then s.stats.indescribable = (s.stats.indescribable or 0) + 1 end
    s.seq = s.seq + 1
    s.stats.applied = s.stats.applied + 1
    killRedo(s, player)
    N.remember(s, s.seq, player, exact)
    N.noteChanger(s.lastBy, exact, player, a.label)
    broadcast(s, { kind = "applied", seq = s.seq, origin = player, localId = msg.localId,
                   bytes = exact ~= nil and C.pack(exact) or nil, skipped = #skipped })
end

--- The host's own action, already applied to the server's network (the host edits it directly).
--- Returns true, or false and who holds the spot (the action has then been taken back).
function N.serverHostAction(s, host, a)
    local cells = N.cellsOf(a, s.zoneSize)
    local holder = blocker(s, host, cells)
    if holder ~= nil then
        G.apply(s.graph, a, true)
        s.stats.refused = s.stats.refused + 1
        return false, holder
    end
    take(s, host, cells)
    s.seq = s.seq + 1
    s.stats.applied = s.stats.applied + 1
    killRedo(s, host)
    s.hostRedo = {}
    N.remember(s, s.seq, host, a)
    N.noteChanger(s.lastBy, a, host, a.label)
    broadcast(s, { kind = "applied", seq = s.seq, origin = host, localId = 0, bytes = C.pack(a), skipped = 0 })
    return true
end

-- ---------------------------------------------------------------- player
function N.newClient(o)
    local c = {
        graph = o.graph, player = o.player, send = o.send,
        pending = {},      -- { localId, action (nil when it came to nothing) }, oldest first
        nextLocal = 0, seq = 0,
        stats = { sent = 0, confirmed = 0, refused = 0, outOfStep = 0 },
        refusals = {},     -- what to tell the player: { label, holder }
        history = {}, historyOrder = {}, redoOrder = {},   -- own numbered actions: seq -> { seq, label, action, state }
        lastBy = {},       -- tag -> { player, label }
        queued = {},       -- undo/redo pressed while an own action was still on its way
        said = {},         -- what the screen was told (the simulator reads it)
        log = o.log or function() end,
    }
    c.shadow = G.capture(c.graph)
    return c
end

--- Ask for the whole network (on joining, or when out of step). Messages until it arrives are dropped:
--- the whole network is sent after them on the same line, so it already holds them.
function N.clientHello(c)
    c.waitingForWhole = true
    c.send({ kind = "hello" })
end

--- A boundary on this player's side (an action finished): send whatever changed since the last one.
function N.clientFlush(c, label)
    if c.waitingForWhole then return nil end
    local a, after = G.diff(c.shadow, c.graph, label)
    if a == nil then
        if after ~= "nothing changed" then c.log("could not describe '" .. tostring(label) .. "': " .. tostring(after)) end
        return nil
    end
    c.shadow = after
    c.nextLocal = c.nextLocal + 1
    c.pending[#c.pending + 1] = { localId = c.nextLocal, action = a }
    c.stats.sent = c.stats.sent + 1
    c.send({ kind = "action", localId = c.nextLocal, bytes = C.pack(a) })
    return a
end

local function takeBackPending(c)
    for i = #c.pending, 1, -1 do
        local p = c.pending[i]
        if p.action ~= nil then
            local ok, why = G.apply(c.graph, p.action, true)
            if not ok then return false, why end
        end
    end
    return true
end

local function putBackPending(c)
    for _, p in ipairs(c.pending) do
        if p.action ~= nil then
            local before = G.capture(c.graph)
            G.replay(c.graph, p.action, false)
            p.action = G.diff(before, c.graph, p.action.label)   -- nil when it now changes nothing
        end
    end
end

local function dropPending(c, localId)
    for i, p in ipairs(c.pending) do
        if p.localId == localId then table.remove(c.pending, i) return true end
    end
    return false
end

--- A message from the server. Returns false when this player is out of step and needs the whole
--- network sent again (resync, step 3's safety net).
function N.clientReceive(c, msg)
    if msg.kind == "whole" then
        -- the server's network replaces ours, in place (AutoDrive keeps its own tables). Anything of ours
        -- not confirmed yet is gone with it; say so.
        local a = C.unpack(msg.bytes)
        local fresh = { wayPoints = {}, mapMarkers = {}, groups = {} }
        G.apply(fresh, a, false)
        local wps = c.graph.wayPoints
        for i = 1, math.max(#wps, #fresh.wayPoints) do wps[i] = fresh.wayPoints[i] end
        local mk = c.graph.mapMarkers
        for i = 1, math.max(#mk, #fresh.mapMarkers) do mk[i] = fresh.mapMarkers[i] end
        local g = c.graph.groups
        for k in pairs(g) do g[k] = nil end
        for k, v in pairs(fresh.groups) do g[k] = v end
        if #c.pending > 0 then
            c.stats.lostOnReload = (c.stats.lostOnReload or 0) + #c.pending
            c.refusals[#c.refusals + 1] = { label = "reload", holder = nil, lost = #c.pending }
        end
        c.pending = {}
        c.seq = msg.seq
        c.waitingForWhole = nil
        c.shadow = G.capture(c.graph)
        return true
    end
    if c.waitingForWhole then return true end   -- everything before the reload is in it
    -- edits in progress since the last boundary go out first, so nothing local is unrecorded below
    N.clientFlush(c, "edit in progress")
    local ok, why = takeBackPending(c)
    if not ok then
        c.stats.outOfStep = c.stats.outOfStep + 1
        c.log("out of step taking back own actions: " .. tostring(why))
        return false
    end
    if msg.kind == "applied" then
        if msg.bytes ~= nil then
            local a = C.unpack(msg.bytes)
            local done, err = G.apply(c.graph, a, false)
            if not done then
                c.stats.outOfStep = c.stats.outOfStep + 1
                c.log("out of step applying #" .. tostring(msg.seq) .. ": " .. tostring(err))
                return false
            end
        end
        c.seq = msg.seq
        local a = msg.bytes ~= nil and C.unpack(msg.bytes) or nil
        N.noteChanger(c.lastBy, a, msg.origin, msg.label or (a and a.label))
        if msg.origin == c.player then
            if msg.undoOf ~= nil then
                local e = c.history[msg.undoOf]
                if e ~= nil then e.state, e.asked = "undone", nil; c.redoOrder[#c.redoOrder + 1] = msg.undoOf end
            elseif msg.redoOf ~= nil then
                local e = c.history[msg.redoOf]
                if e ~= nil then e.state, e.asked = "done", nil end
                for i = #c.redoOrder, 1, -1 do if c.redoOrder[i] == msg.redoOf then table.remove(c.redoOrder, i) end end
            else
                if dropPending(c, msg.localId) then c.stats.confirmed = c.stats.confirmed + 1 end
                if a ~= nil then
                    c.history[msg.seq] = { seq = msg.seq, label = a.label, action = a, state = "done" }
                    c.historyOrder[#c.historyOrder + 1] = msg.seq
                    while #c.historyOrder > N.HISTORY_KEEP do c.history[table.remove(c.historyOrder, 1)] = nil end
                end
                for _, seq in ipairs(c.redoOrder) do
                    local e = c.history[seq]
                    if e ~= nil and e.state == "undone" then e.state = "dead" end
                end
                c.redoOrder = {}
            end
        end
    elseif msg.kind == "blocked" then
        local e = c.history[msg.seq]
        if e ~= nil then e.asked = nil end
        c.stats.blockedByServer = (c.stats.blockedByServer or 0) + 1
        c.said[#c.said + 1] = N.sayUndo(msg.redo, nil, { { label = e and e.label, byPlayer = msg.byPlayer, byLabel = msg.byLabel } })
    elseif msg.kind == "refused" then
        if dropPending(c, msg.localId) then
            c.stats.refused = c.stats.refused + 1
            c.refusals[#c.refusals + 1] = { label = msg.label, holder = msg.holder }
        end
    end
    putBackPending(c)
    c.shadow = G.capture(c.graph)
    if #c.pending == 0 and #c.queued > 0 then
        local kind = table.remove(c.queued, 1)
        N.clientUndo(c, kind == "redo")
    end
    return true
end

-- ================================================================ PER-PLAYER UNDO (step 6)
--[[ Each player undoes only their own actions. An action can be undone while everything it changed still
looks as it left it (GraphOps.fits); otherwise it is BLOCKED: undo skips it, takes back the newest one that
is not, and says what it skipped and who changed that spot. A blocked action fits again by itself once
whoever got in the way undoes their change. Redo the same way round.

The player picks which action to undo (it knows its own history and sees the same network), and asks the
server; the server checks again on its own network - it has the final say, since another action may
have got in first - then plays it (by tag), writes down exactly what that did, and sends it to everyone
as a normal numbered action marked undoOf / redoOf.

A new action of the player's own empties their redo, as in single player.
]]

N.HISTORY_KEEP = 200

function N.remember(s, seq, player, a)
    s.history[seq] = { player = player, action = a, label = a and a.label, state = "done" }
    s.historyOrder[#s.historyOrder + 1] = seq
    while #s.historyOrder > N.HISTORY_KEEP do
        s.history[table.remove(s.historyOrder, 1)] = nil
    end
end

function N.noteChanger(lastBy, a, player, label)
    if a == nil then return end
    for _, t in ipairs(G.touched(a)) do lastBy[t] = { player = player, label = label } end
end

--- Play undo (or redo) of action `seq` for `player` on the server's network, if it still fits.
--- Returns true, or false and a refusal message for the player.
function N.serverUndo(s, player, seq, redo)
    local e = s.history[seq]
    if e == nil or e.action == nil then
        return false, { kind = "blocked", seq = seq, redo = redo, why = "too old to undo" }
    end
    if e.player ~= player then
        return false, { kind = "blocked", seq = seq, redo = redo, why = "not yours" }
    end
    if (redo and e.state ~= "undone") or (not redo and e.state ~= "done") then
        return false, { kind = "blocked", seq = seq, redo = redo, why = "already " .. (redo and "done" or "undone") }
    end
    local ok, tag, why = G.fits(s.graph, e.action, not redo)
    if not ok then
        local by = tag ~= nil and s.lastBy[tag] or nil
        s.stats.undoBlocked = (s.stats.undoBlocked or 0) + 1
        return false, { kind = "blocked", seq = seq, redo = redo, why = why,
                        byPlayer = by and by.player, byLabel = by and by.label }
    end
    local before = G.capture(s.graph)
    G.replay(s.graph, e.action, not redo)
    -- what undo promises: the spot now looks exactly as before the action (and redo: as after it)
    if not G.fits(s.graph, e.action, redo) then s.stats.undoNotExact = (s.stats.undoNotExact or 0) + 1 end
    local label = (redo and "redo: " or "undo: ") .. tostring(e.label)
    local exact, why2 = G.diff(before, s.graph, label)
    if exact == nil and why2 ~= "nothing changed" then s.stats.indescribable = (s.stats.indescribable or 0) + 1 end
    e.state = redo and "done" or "undone"
    s.seq = s.seq + 1
    s.stats.applied = s.stats.applied + 1
    s.stats[redo and "redos" or "undos"] = (s.stats[redo and "redos" or "undos"] or 0) + 1
    N.noteChanger(s.lastBy, exact, player, label)
    N.remember(s, s.seq, nil, nil)   -- an undo is not itself undoable; it only moves its action's state
    broadcast(s, { kind = "applied", seq = s.seq, origin = player, localId = 0,
                   bytes = exact ~= nil and C.pack(exact) or nil, skipped = 0,
                   undoOf = (not redo) and seq or nil, redoOf = redo and seq or nil, label = label })
    return true
end

--- The host presses undo (redo): its own newest action that fits, skipping the blocked ones.
--- Returns a short text for the host's screen.
function N.serverHostUndo(s, host, redo)
    local skipped = {}
    local list = redo and s.hostRedo or s.historyOrder
    for i = #list, 1, -1 do
        local seq = list[i]
        local e = s.history[seq]
        if e ~= nil and e.player == host and e.state == (redo and "undone" or "done") then
            local ok, msg = N.serverUndo(s, host, seq, redo)
            if ok then
                if redo then table.remove(s.hostRedo, i) else s.hostRedo[#s.hostRedo + 1] = seq end
                return N.sayUndo(redo, e.label, skipped)
            end
            skipped[#skipped + 1] = { label = e.label, byPlayer = msg.byPlayer, byLabel = msg.byLabel }
        end
    end
    return N.sayUndo(redo, nil, skipped)
end

--- The words for the screen: what was undone, what was skipped and who changed that spot.
function N.sayUndo(redo, label, skipped)
    local verb = redo and "Redid" or "Undid"
    local text = label ~= nil and string.format("%s: %s.", verb, tostring(label))
        or string.format("Nothing to %s.", redo and "redo" or "undo")
    if #skipped > 0 then
        local first = skipped[1]
        local who = first.byPlayer ~= nil and string.format("%s changed that spot%s", tostring(first.byPlayer),
            first.byLabel ~= nil and (" (" .. tostring(first.byLabel) .. ")") or "") or "that spot changed since"
        text = text .. string.format(" Skipped %d: %s", #skipped, who)
        if #skipped > 1 then text = text .. " and more" end
        text = text .. "."
    end
    return text
end

-- ---------------------------------------------------------------- player side
--- The player presses undo (redo). Picks their newest own action that still fits on the network they
--- see, skips the blocked ones, asks the server. Waits while their own newest action is still on its
--- way (it cannot be undone before the server has numbered it). Returns the text for the screen.
function N.clientUndo(c, redo)
    if c.waitingForWhole then return "Waiting for the network." end
    if #c.pending > 0 then
        c.queued[#c.queued + 1] = redo and "redo" or "undo"
        return "Waiting for the server..."
    end
    local skipped = {}
    local list = redo and c.redoOrder or c.historyOrder
    for i = #list, 1, -1 do
        local e = c.history[list[i]]
        if e ~= nil and e.state == (redo and "undone" or "done") and not e.asked then
            local ok, tag = G.fits(c.graph, e.action, not redo)
            if ok then
                e.asked = true
                c.send({ kind = redo and "redo" or "undo", seq = e.seq })
                c.stats[redo and "redoAsked" or "undoAsked"] = (c.stats[redo and "redoAsked" or "undoAsked"] or 0) + 1
                local text = N.sayUndo(redo, e.label, skipped)
                c.said[#c.said + 1] = text
                return text
            end
            local by = tag ~= nil and c.lastBy[tag] or nil
            skipped[#skipped + 1] = { label = e.label, byPlayer = by and by.player, byLabel = by and by.label }
            c.stats.skippedBlocked = (c.stats.skippedBlocked or 0) + 1
        end
    end
    local text = N.sayUndo(redo, nil, skipped)
    c.said[#c.said + 1] = text
    return text
end

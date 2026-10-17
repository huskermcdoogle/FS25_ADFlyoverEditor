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
    local exact = G.diff(before, s.graph, a.label)
    s.seq = s.seq + 1
    s.stats.applied = s.stats.applied + 1
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
        if msg.origin == c.player then
            if dropPending(c, msg.localId) then c.stats.confirmed = c.stats.confirmed + 1 end
        end
    elseif msg.kind == "refused" then
        if dropPending(c, msg.localId) then
            c.stats.refused = c.stats.refused + 1
            c.refusals[#c.refusals + 1] = { label = msg.label, holder = msg.holder }
        end
    end
    putBackPending(c)
    c.shadow = G.capture(c.graph)
    return true
end

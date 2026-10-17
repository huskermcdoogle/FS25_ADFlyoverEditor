--[[ MULTIPLAYER STEPS 3-5 OFFLINE: A SERVER AND SEVERAL PLAYERS, IN ONE PROCESS

Every peer holds its own copy of a real network and edits it with AutoDrive's REAL GraphManager code
(the global ADGraphManager is pointed at a peer's tables before each of its edits). The rules are the
mod's own: scripts/editor/GraphOps.lua, ActionCodec.lua, NetCore.lua. Messages travel with random delays
(in order on each line, as one game connection keeps them) and arrive while players are mid-edit.

Players mostly work in their own part of the map; now and then (SHARED, default 0.15) one edits in a
strip all of them use, so zones get tested. The host edits the server's own network.

At the end every message is delivered and every network must be EXACTLY the server's (number, tag,
place, flags, both link lists in order, markers). Also counted: actions applied, refused by a zone,
links skipped (a point someone deleted first), players out of step (must be 0).

    lua sim.lua <AutoDrive GraphManager.lua> <network from export_full.py> [ticks] [seed] [players]
    env: SHARED=0.15 LAG_MIN=30 LAG_MAX=250 (ms) ZONE=15 LINGER=2000
]]

local GM_PATH, NET_PATH = arg[1], arg[2]
local TICKS = tonumber(arg[3] or "400")
local SEED = tonumber(arg[4] or "1")
local NPLAYERS = tonumber(arg[5] or "3")
local SHARED = tonumber(os.getenv("SHARED") or "0.15")
local LAG_MIN, LAG_MAX = tonumber(os.getenv("LAG_MIN") or "30"), tonumber(os.getenv("LAG_MAX") or "250")
assert(GM_PATH and NET_PATH, "usage: lua sim.lua <GraphManager.lua> <network.lua> [ticks] [seed] [players]")

function table:contains(value) for _, v in pairs(self) do if v == value then return true end end return false end
function table:indexOf(value) for k, v in pairs(self) do if v == value then return k end end return nil end
function table:removeValue(value)
    for k, v in pairs(self) do if v == value then table.remove(self, k) return true end end
    return false
end
function table:count() local c = 0 for _ in pairs(self) do c = c + 1 end return c end
bit32 = bit32 or { band = function(a, b)
    local r, bitv = 0, 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then r = r + bitv end
        a, b, bitv = math.floor(a / 2), math.floor(b / 2), bitv * 2
    end
    return r
end }
Logging = { info = function() end, warning = print, error = print }
g_server, g_client = {}, nil
AutoDrive = { Hud = { lastUIScale = 0 }, FLAG_NONE = 0, FLAG_SUBPRIO = 1,
              getAllVehicles = function() return {} end, notifyDestinationListeners = function() end }

dofile(GM_PATH)
dofile("../../scripts/editor/GraphOps.lua")
dofile("../../scripts/editor/ActionCodec.lua")
dofile("../../scripts/editor/NetCore.lua")
local GM, G, C, N = ADGraphManager, ADFlyoverGraphOps, ADFlyoverActionCodec, ADFlyoverNet

-- ------------------------------------------------------------------ the network, tagged once (slot 0)
local net = dofile(NET_PATH)
local base = { wayPoints = {}, mapMarkers = {}, groups = { All = 1 } }
for i, w in ipairs(net.wayPoints) do
    base.wayPoints[i] = GM:createNode(i, w.x, w.y, w.z, { unpack(w.out) }, { unpack(w.incoming) }, w.flags, nil, nil)
end
for i, m in ipairs(net.mapMarkers or {}) do
    base.mapMarkers[i] = { id = m.id, name = m.name, group = m.group, markerIndex = i }
end
G.setTagSpace(0)
G.tagAll(base.wayPoints)
local minX, maxX = math.huge, -math.huge
for _, w in ipairs(base.wayPoints) do minX = math.min(minX, w.x); maxX = math.max(maxX, w.x) end

-- ------------------------------------------------------------------ peers
-- Each peer has its own graph and its own tag space; `as(peer)` points AutoDrive and GraphOps at it.
local now = 0
local peers = {}
local function as(peer)
    GM.wayPoints, GM.mapMarkers, GM.groups = peer.graph.wayPoints, peer.graph.mapMarkers, peer.graph.groups
    G.tagBase, G.nextTag = peer.tagBase, peer.nextTag
end
local function leave(peer) peer.nextTag = G.nextTag end

-- the wire: per (from,to) line, in order, each message after a random delay
local inflight = {}
local lineFree = {}
local sentCount, sentBytes = 0, 0
local postOrder = 0
local function post(from, to, msg)
    local key = from .. ">" .. to
    local at = math.max(lineFree[key] or 0, now + math.random(LAG_MIN, LAG_MAX))
    lineFree[key] = at
    postOrder = postOrder + 1   -- a global count: equal arrival times keep the order they were sent in
    inflight[#inflight + 1] = { at = at, from = from, to = to, msg = msg, order = postOrder }
    sentCount = sentCount + 1
    sentBytes = sentBytes + (msg.bytes and #msg.bytes or 8)
end

local server = { name = "server", graph = G.copyGraph(base), tagBase = 0, nextTag = G.nextTag }
server.net = N.newServer({
    graph = server.graph,
    send = function(player, msg)
        if DEBUG and msg.kind == "applied" and serverAt[msg.seq] == nil then serverAt[msg.seq] = G.copyGraph(server.graph) end
        post("server", player, msg)
    end,
    now = function() return now end,
    zoneRadius = tonumber(os.getenv("ZONE") or "15"),
    linger = tonumber(os.getenv("LINGER") or "2000"),
})
-- the host edits the server's network directly, through its own boundary
server.hostShadow = G.capture(server.graph)
peers.server = server

local players = {}
for i = 1, NPLAYERS do
    local name = "p" .. i
    local p = { name = name, graph = G.copyGraph(base), tagBase = i * G.TAG_BLOCK, nextTag = i * G.TAG_BLOCK }
    -- each player's home: one slice of the map (x), the shared strip is in the middle
    p.home = { minX + (maxX - minX) * (i - 1) / NPLAYERS, minX + (maxX - minX) * i / NPLAYERS }
    as(p)
    p.net = N.newClient({ graph = p.graph, player = name, send = function(msg) post(name, "server", msg) end,
        log = os.getenv("DEBUG") == "1" and function(s) print(name .. ": " .. s) end or nil })
    leave(p)
    N.serverAddPlayer(server.net, name)
    peers[name] = p
    players[#players + 1] = p
end
server.home = { minX, maxX }
local mid = (minX + maxX) / 2

-- ------------------------------------------------------------------ editing
local function pick(peer)
    local wps = peer.graph.wayPoints
    local lo, hi = peer.home[1], peer.home[2]
    if math.random() < SHARED then lo, hi = mid - 60, mid + 60 end
    for _ = 1, 200 do
        local w = wps[math.random(1, #wps)]
        if w.x >= lo and w.x <= hi then return w end
    end
    return wps[math.random(1, #wps)]
end
local function nearby(peer, a)
    local wps = peer.graph.wayPoints
    for _ = 1, 200 do
        local w = wps[math.random(1, #wps)]
        if math.abs(w.x - a.x) < 40 and math.abs(w.z - a.z) < 40 and w ~= a then return w end
    end
    return nil
end

local function edit(peer)
    local r = math.random()
    local a = pick(peer)
    if r < 0.20 then
        GM:removeWayPoint(a.id, false)
    elseif r < 0.36 then
        local wp = GM:recordWayPoint(a.x + 3, a.y, a.z + 3, false, false, false, 0, 0, false)
        GM:toggleConnectionBetween(a, wp, false, math.random() < 0.3, false)
    elseif r < 0.56 then
        GM:moveWayPoint(a.id, a.x + math.random() - 0.5, a.y, a.z + math.random() - 0.5, a.flags, false)
    elseif r < 0.62 then
        GM:setWayPointFlags(a.id, (a.flags == 0) and 1 or 0, false)
    elseif r < 0.78 then
        local b = nearby(peer, a)
        if b ~= nil then GM:toggleConnectionBetween(a, b, false, math.random() < 0.3, false) end
    elseif r < 0.88 then
        local b = nearby(peer, a)
        if b ~= nil then
            local pts = {}
            for k = 1, math.random(2, 5) do
                local f = k / 6
                pts[k] = { x = a.x + (b.x - a.x) * f, y = a.y, z = a.z + (b.z - a.z) * f }
            end
            GM:createSplineConnection(a.id, pts, b.id, false, false)
        end
    elseif r < 0.94 then
        GM:createMapMarker(a.id, peer.name .. " spot " .. math.random(1, 9999), false)
    else
        -- the editor's hand-made link changes
        local b = nearby(peer, a)
        if b ~= nil and not table.contains(a.out, b.id) then
            table.insert(a.out, b.id); table.insert(b.incoming, a.id)
        end
    end
end

-- ------------------------------------------------------------------ run
math.randomseed(SEED)
local hostRefused, outOfStep = 0, 0
DEBUG = os.getenv("DEBUG") == "1"
serverAt = { [0] = G.copyGraph(base) }
local function deliver(upTo)
    table.sort(inflight, function(x, y) if x.at ~= y.at then return x.at < y.at end return x.order < y.order end)
    while #inflight > 0 and inflight[1].at <= upTo do
        local m = table.remove(inflight, 1)
        now = math.max(now, m.at)
        local peer = peers[m.to]
        as(peer)
        if m.to == "server" then
            N.serverReceive(server.net, m.from, m.msg)
            -- the host's own boundary must not take the players' actions for the host's
            server.hostShadow = G.capture(server.graph)
        else
            if DEBUG and m.msg.kind == "applied" and serverAt[m.msg.seq - 1] ~= nil then
                -- the player with its own actions taken back must be the server as of the action before
                local copy = G.copyGraph(peer.graph)
                local okBack = true
                for i = #peer.net.pending, 1, -1 do
                    local pa = peer.net.pending[i].action
                    if pa ~= nil and not G.apply(copy, pa, true) then okBack = false end
                end
                local same, why = G.same(copy, serverAt[m.msg.seq - 1])
                if not same or not okBack then
                    print(string.format("DEBUG %s before #%d (%s, origin %s): %s; pending %d", peer.name, m.msg.seq,
                        m.msg.kind, m.msg.origin, okBack and tostring(why) or "could not take back", #peer.net.pending))
                    local inA, inB = {}, {}
                    for _, w in ipairs(copy.wayPoints) do inA[w.fxTag] = w end
                    for _, w in ipairs(serverAt[m.msg.seq - 1].wayPoints) do inB[w.fxTag] = w end
                    for t, w in pairs(inB) do if not inA[t] then print("  only on server: tag " .. t .. string.format(" at %.1f,%.1f", w.x, w.z)) end end
                    for t, w in pairs(inA) do if not inB[t] then print("  only on player: tag " .. t) end end
                    for i, p in ipairs(peer.net.pending) do
                        local d = {}
                        for _, x in ipairs(p.action and p.action.dels or {}) do d[#d + 1] = x.tag .. "@" .. x.index end
                        print("  pending " .. p.localId .. ": " .. G.describe(p.action) .. " | dels " .. table.concat(d, ","))
                    end
                    print("  player seq " .. peer.net.seq .. ", server seq " .. server.net.seq)
                    DEBUG = false
                end
            end
            local pendBefore = #peer.net.pending
            if not N.clientReceive(peer.net, m.msg) then
                outOfStep = outOfStep + 1
                N.clientHello(peer.net)
            end
            if DEBUG then
                local copy = G.copyGraph(peer.graph)
                for i = #peer.net.pending, 1, -1 do
                    local pa = peer.net.pending[i].action
                    if pa ~= nil then G.apply(copy, pa, true) end
                end
                local same, why = G.same(copy, serverAt[peer.net.seq])
                if not same then
                    print(string.format("DEBUG %s AFTER %s seq=%s origin=%s localId=%s (pending %d -> %d): %s",
                        peer.name, m.msg.kind, tostring(m.msg.seq), tostring(m.msg.origin), tostring(m.msg.localId),
                        pendBefore, #peer.net.pending, tostring(why)))
                    DEBUG = false
                end
            end
        end
        leave(peer)
    end
end

local LATE = os.getenv("LATE") ~= "0"
local function joinLate()
    local i = NPLAYERS + 1
    local name = "p" .. i .. " (late)"
    local p = { name = name, graph = G.copyGraph(base), tagBase = i * G.TAG_BLOCK, nextTag = i * G.TAG_BLOCK }
    p.home = { minX, maxX }
    as(p)
    p.net = N.newClient({ graph = p.graph, player = name, send = function(msg) post(name, "server", msg) end,
        log = os.getenv("DEBUG") == "1" and function(s) print(name .. ": " .. s) end or nil })
    N.clientHello(p.net)
    leave(p)
    peers[name] = p
    players[#players + 1] = p
end

local t0 = os.clock()
for tick = 1, TICKS do
    now = now + 50
    if LATE and tick == math.floor(TICKS / 2) then joinLate() end
    -- one random peer makes an action of 1-6 edits, then its boundary
    local who = math.random(0, #players)
    local peer = who == 0 and server or players[who]
    as(peer)
    -- a player still waiting for the whole network has nothing to edit yet
    local waiting = peer.net ~= nil and peer.net.waitingForWhole
    if not waiting then for _ = 1, math.random(1, 6) do edit(peer) end end
    if waiting then
        -- nothing
    elseif peer == server then
        local a, after = G.diff(server.hostShadow, server.graph, "host " .. tick)
        if a ~= nil then
            local ok = N.serverHostAction(server.net, "server", a)
            if not ok then hostRefused = hostRefused + 1 end
            server.hostShadow = G.capture(server.graph)
        end
    else
        N.clientFlush(peer.net, peer.name .. " " .. tick)
    end
    leave(peer)
    deliver(now)
end
deliver(math.huge)
-- the last messages may have been answered by actions flushed on arrival; settle fully
for _ = 1, 5 do
    for _, p in ipairs(players) do as(p); N.clientFlush(p.net, "last"); leave(p) end
    deliver(math.huge)
end

-- ------------------------------------------------------------------ verdict
local allSame = true
for _, p in ipairs(players) do
    local same, why = G.same(p.graph, server.graph)
    local pend = #p.net.pending
    print(string.format("%s: %s | sent %d, confirmed %d, refused %d, still pending %d, out of step %d",
        p.name, same and "SAME AS SERVER" or ("DIFFERS: " .. tostring(why)), p.net.stats.sent,
        p.net.stats.confirmed, p.net.stats.refused, pend, p.net.stats.outOfStep))
    if not same or pend > 0 then allSame = false end
end
local st = server.net.stats
print(string.format("server: %d actions in order, %d refused by a zone (host %d), %d links skipped; network %d -> %d points",
    st.applied, st.refused, hostRefused, st.skipped, #base.wayPoints, #server.graph.wayPoints))
print(string.format("wire: %d messages, %d KB; %.1f s", sentCount, math.floor(sentBytes / 1024), os.clock() - t0))
print(allSame and outOfStep == 0 and "RESULT: every player ends exactly like the server" or "RESULT: FAIL")
if not allSame or outOfStep > 0 then os.exit(1) end

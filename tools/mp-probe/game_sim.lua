--[[ THE GAME SIDE, OFFLINE: the real NetEvent.lua + NetGame.lua (and everything under them) on three "PCs"

Each PC is its own Lua environment (setfenv) with its own copy of every global the mod files make -
ADGraphManager (AutoDrive's REAL GraphManager.lua), ADFlyoverNetGame, the event class - and the bits of
FS25 the files touch, faked: Class/Event/InitEventClass, stream read/write (messages really are written
to bytes and read back, field by field, as the engine would), g_server/g_client, connections, the user
manager. PC 1 hosts (server + a player at it), PCs 2 and 3 join.

What it plays: join (whole network), edits on all three with boundaries as EditorHistory gives them,
undo/redo, AutoDrive's OWN recording on one PC (its event reaching every PC behind ours - the safety
net), and at the end every network must be exactly the host's.

    lua game_sim.lua <AutoDrive GraphManager.lua> <network from export_full.py> [rounds] [seed]
]]
local GM_PATH, NET_PATH = arg[1], arg[2]
local ROUNDS = tonumber(arg[3] or "40")
local SEED = tonumber(arg[4] or "1")
assert(GM_PATH and NET_PATH, "usage: lua game_sim.lua <GraphManager.lua> <network.lua> [rounds] [seed]")
math.randomseed(SEED)

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

local net = dofile(NET_PATH)
local clock = 0
local wire = {}           -- { to = pc, bytes = serialized, from = pc, class = name }
local wireBytes, wireCount = 0, 0
local LOG_ALL = os.getenv("VERBOSE") == "1"

-- ---------------------------------------------------------------- one PC
local function newPC(name, userId, isServer)
    local env = setmetatable({}, { __index = _G })
    env._G = env
    env.pcName = name
    local logs = {}
    env.logs = logs
    local function logf(fmt, ...)
        local ok, s = pcall(string.format, fmt, ...)
        s = ok and s or tostring(fmt)
        logs[#logs + 1] = s
        if LOG_ALL then print(name .. ": " .. s) end
    end
    env.Logging = { info = logf, warning = function(f, ...) logf("WARN " .. f, ...) end,
                    error = function(f, ...) logf("ERROR " .. f, ...); print(name .. " ERROR: " .. string.format(f, ...)) end }
    env.g_time = 0
    -- FS classes and events
    env.Class = function(t, base) setmetatable(t, { __index = base }); return { __index = t } end
    env.Event = { new = function(mt) return setmetatable({}, mt) end }
    env.eventClasses = {}
    env.InitEventClass = function(cls, cname) env.eventClasses[cname] = cls; cls.className = cname end
    -- streams: a stream is a list of values written in order
    local streams, nextStream = {}, 0
    env.newStream = function() nextStream = nextStream + 1; streams[nextStream] = { pos = 1 }; return nextStream end
    env.streamOf = function(id) return streams[id] end
    local function w(id, v) local s = streams[id]; s[#s + 1] = v end
    local function r(id) local s = streams[id]; local v = s[s.pos]; s.pos = s.pos + 1; return v end
    env.streamWriteUInt8 = function(id, v) assert(v >= 0 and v <= 255 and v == math.floor(v), "UInt8 " .. tostring(v)); w(id, v) end
    env.streamWriteInt32 = function(id, v) assert(v >= -2147483648 and v <= 2147483647 and v == math.floor(v), "Int32 " .. tostring(v)); w(id, v) end
    env.streamWriteString = function(id, v) assert(type(v) == "string"); w(id, v) end
    env.streamReadUInt8, env.streamReadInt32, env.streamReadString = r, r, r
    -- AutoDrive (the real graph code) and the bits of it the files touch
    env.AutoDrive = { Hud = { lastUIScale = 0 }, FLAG_NONE = 0, FLAG_SUBPRIO = 1,
                      getAllVehicles = function() return {} end, notifyDestinationListeners = function() end,
                      getControlledVehicle = function() return nil end, getSetting = function() return false end,
                      isInExtendedEditorMode = function() return false end, playSample = function() end }
    local chunk = assert(loadfile(GM_PATH)); setfenv(chunk, env); chunk()
    local GM = env.ADGraphManager
    GM.wayPoints, GM.mapMarkers, GM.groups = {}, {}, { All = 1 }
    for i, wp in ipairs(net.wayPoints) do
        GM.wayPoints[i] = GM:createNode(i, wp.x, wp.y, wp.z, { unpack(wp.out) }, { unpack(wp.incoming) }, wp.flags, nil, nil)
    end
    for i, m in ipairs(net.mapMarkers or {}) do GM.mapMarkers[i] = { id = m.id, name = m.name, group = m.group, markerIndex = i } end
    GM.changes = false
    -- AutoDrive's own "record a waypoint" event, so the safety net has something to wrap
    env.AutoDriveRecordWayPointEvent = {
        run = function(self) GM:recordWayPoint(self.x, self.y, self.z, self.connect, false, false, self.prev or 0, 0, false) end,
    }
    env.ADFlyoverArming = { env = env }
    env.ADFlyoverPrelude = {}
    -- multiplayer world
    env.g_currentMission = {
        missionDynamicInfo = { isMultiplayer = true }, playerUserId = userId,
        userManager = {
            getUserIdByConnection = function(_, conn) return conn.peerUserId end,
            getUserByUserId = function(_, id) return { getNickname = function() return "PC" .. tostring(id) end } end,
        },
    }
    if isServer then env.g_server = {} end
    env.g_client = {}
    -- the mod's files, as Prelude loads them
    for _, f in ipairs({ "../../scripts/NetEvent.lua", "../../scripts/editor/GraphOps.lua",
                         "../../scripts/editor/ActionCodec.lua", "../../scripts/editor/NetCore.lua",
                         "../../scripts/editor/NetGame.lua" }) do
        local c = assert(loadfile(f)); setfenv(c, env); c()
    end
    return { name = name, env = env, userId = userId, GM = GM }
end

local host = newPC("host", 1, true)
local pcs = { host, newPC("pc2", 7, false), newPC("pc3", 12, false) }

-- connections: sending writes the event into a stream on the SENDER, the bytes travel, the receiver reads
local function connect(fromPC, toPC, toIsServer)
    return {
        peerUserId = fromPC.userId,   -- seen from the receiver: who sent it
        getIsServer = function() return toIsServer end,
        sendEvent = function(self, ev)
            local e = fromPC.env
            local id = e.newStream()
            ev:writeStream(id, nil)
            local values = e.streamOf(id)
            wire[#wire + 1] = { to = toPC, from = fromPC, values = values, class = "ADFlyoverNetEvent" }
            wireCount = wireCount + 1
            wireBytes = wireBytes + #(ev.bytes or "")
        end,
    }
end
-- the host's connection objects for each player (server -> player), and each player's to the server
for i = 2, #pcs do
    local p = pcs[i]
    p.toServer = connect(p, host, false)   -- arrives at the server: connection:getIsServer() == false there
    p.env.g_client.getServerConnection = function() return p.toServer end
end
local function deliver()
    local n = 0
    while #wire > 0 do
        local m = table.remove(wire, 1)
        local e = m.to.env
        local cls = e.eventClasses[m.class]
        local ev = e.ADFlyoverNetEvent.emptyNew()
        local id = e.newStream()
        local s = e.streamOf(id)
        for i, v in ipairs(m.values) do s[i] = v end
        -- the connection the receiver sees: for the server, the player's; for a player, the server's
        local conn
        if m.to == host then
            conn = { peerUserId = m.from.userId, getIsServer = function() return false end,
                     sendEvent = function(self, ev2) connect(host, m.from, true).sendEvent(nil, ev2) end }
        else
            conn = { peerUserId = host.userId, getIsServer = function() return true end }
        end
        ev:readStream(id, conn)
        n = n + 1
    end
    return n
end
local function tick(ms)
    clock = clock + (ms or 50)
    for _, p in ipairs(pcs) do
        p.env.g_time = clock
        local ng = p.env.ADFlyoverNetGame
        if ng.active then ng.update(ms or 50) end
    end
end

-- ---------------------------------------------------------------- start: the host first, then the players join
for _, p in ipairs(pcs) do p.env.ADFlyoverNetGame.start() end
deliver()
for _, p in ipairs(pcs) do
    print(string.format("%s: active=%s canEdit=%s", p.name, tostring(p.env.ADFlyoverNetGame.active),
        tostring(p.env.ADFlyoverNetGame.canEdit())))
end

-- ---------------------------------------------------------------- play
local function anyPoint(p, near)
    local wps = p.GM.wayPoints
    for _ = 1, 300 do
        local wp = wps[math.random(1, #wps)]
        if near == nil or (math.abs(wp.x - near[1]) < 300) then return wp end
    end
    return wps[math.random(1, #wps)]
end
local homes = { { -600, 0 }, { 0, 0 }, { 600, 0 } }
local undos, edits, adRecords = 0, 0, 0
for round = 1, ROUNDS do
    local i = math.random(1, #pcs)
    local p = pcs[i]
    local ng, GM = p.env.ADFlyoverNetGame, p.GM
    local roll = math.random()
    if roll < 0.15 then
        ng.undo(math.random() < 0.25)
        undos = undos + 1
    elseif roll < 0.22 then
        -- AutoDrive's own recording, on every PC (AutoDrive's own message reaches all of them)
        local a = anyPoint(host, homes[i])
        local ev = { x = a.x + 5, y = a.y, z = a.z + 5, connect = false }
        for _, q in ipairs(pcs) do
            local cls = q.env.AutoDriveRecordWayPointEvent
            cls.run(setmetatable({ x = ev.x, y = ev.y, z = ev.z, connect = false }, { __index = cls }))
        end
        adRecords = adRecords + 1
    else
        -- an editor action: EditorHistory's snapshot marks the start (a boundary), then the edits
        p.env.ADEditorHistory = p.env.ADEditorHistory   -- (no EditorHistory here: call the boundary as it would)
        ng.boundary(); ng.label = "edit " .. round
        for _ = 1, math.random(1, 4) do
            local a = anyPoint(p, homes[i])
            local r = math.random()
            if r < 0.3 then GM:moveWayPoint(a.id, a.x + 1, a.y, a.z, a.flags, false)
            elseif r < 0.5 then GM:removeWayPoint(a.id, false)
            elseif r < 0.8 then
                local wp = GM:recordWayPoint(a.x + 2, a.y, a.z + 2, false, false, false, 0, 0, false)
                GM:toggleConnectionBetween(a, wp, false, false, false)
            else GM:createMapMarker(a.id, p.name .. " " .. round, false) end
            GM:markChanges()
        end
        edits = edits + 1
    end
    for _ = 1, 6 do tick(50); deliver() end
end
for _ = 1, 200 do tick(100); deliver() end

-- ---------------------------------------------------------------- verdict
local G = host.env.ADFlyoverGraphOps
local hostGraph = { wayPoints = host.GM.wayPoints, mapMarkers = host.GM.mapMarkers, groups = host.GM.groups }
local all = true
for i = 2, #pcs do
    local p = pcs[i]
    local same, why = G.same({ wayPoints = p.GM.wayPoints, mapMarkers = p.GM.mapMarkers, groups = p.GM.groups }, hostGraph)
    local c = p.env.ADFlyoverNetGame.client
    print(string.format("%s: %s | sent %d, confirmed %d, refused %d, out of step %d, pending %d", p.name,
        same and "SAME AS HOST" or ("DIFFERS: " .. tostring(why)), c.stats.sent, c.stats.confirmed, c.stats.refused,
        c.stats.outOfStep, #c.pending))
    if not same then all = false end
end
local errors = 0
for _, p in ipairs(pcs) do
    for _, l in ipairs(p.env.logs) do if l:find("^ERROR") then errors = errors + 1 end end
end
local shown = 0
for _, p in ipairs(pcs) do
    for _, l in ipairs(p.env.logs) do
        if (l:find("Skipped") or l:find("Not applied") or l:find("loading the whole") or l:find("loaded the whole")) and shown < 6 then
            print("  " .. p.name .. " log: " .. l); shown = shown + 1
        end
    end
end
print(string.format("rounds %d: %d editor actions, %d undo/redo presses, %d AutoDrive recordings; %d messages, %d KB of action bytes; %d errors",
    ROUNDS, edits, undos, adRecords, wireCount, math.floor(wireBytes / 1024), errors))
print((all and errors == 0) and "RESULT: every PC ends exactly like the host" or "RESULT: FAIL")
if not all or errors > 0 then os.exit(1) end

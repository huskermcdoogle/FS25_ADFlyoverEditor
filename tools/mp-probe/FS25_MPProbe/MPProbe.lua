--[[ MP PROBE: how big can one network message be?

Multiplayer step 0 for the Flyover Editor. The plan sends a whole AutoDrive network (~230 KB at 17k
points) when a player joins or falls out of step, and cuts edits above 6 KB into pieces. Nobody has
written down how big a single FS25 event may be, so this measures it.

On a CLIENT, in the console:
    mpProbe 256      one 256 KB message client -> server, then the server sends 256 KB back
    mpProbe all      6, 64, 256, 512, 1024 KB, one after another

Both ends write to log.txt, all lines starting "[MPProbe]":
    client  sending 262144 bytes (run 3)
    server  got 262144 bytes, checksum ok, from <name> (run 3)
    client  server says: got 262144 bytes, checksum ok
    client  got 262144 bytes back, checksum ok, 412 ms round trip (run 3)

A size that never comes back within 20 s is reported as lost. Then read both logs for errors.

The event class is registered here, at source time (extraSourceFiles), the way the editor's own
network files will be: a class registered after a client joined is unknown to that client.
]]

MPProbe = {}
MPProbe.runs = {}
MPProbe.queue = {}
MPProbe.nextRun = 0
MPProbe.TIMEOUT_MS = 20000

local function log(fmt, ...)
    Logging.info("[MPProbe] " .. fmt, ...)
end

-- payload: n bytes as 32-bit words from a fixed generator; checksum is a running sum mod 2^31
local function word(i) return (i * 2654435761) % 2147483647 end

MPProbeEvent = {}
MPProbeEvent_mt = Class(MPProbeEvent, Event)
InitEventClass(MPProbeEvent, "MPProbeEvent")

MPProbeEvent.KIND_PAYLOAD_UP = 1    -- client -> server, big
MPProbeEvent.KIND_ACK = 2           -- server -> client, small: what the server got
MPProbeEvent.KIND_PAYLOAD_DOWN = 3  -- server -> client, big

function MPProbeEvent.emptyNew()
    return Event.new(MPProbeEvent_mt)
end

function MPProbeEvent.new(kind, run, bytes, okFlag)
    local self = MPProbeEvent.emptyNew()
    self.kind, self.runNo, self.bytes, self.ok = kind, run, bytes, okFlag
    return self
end

function MPProbeEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, self.kind)
    streamWriteInt32(streamId, self.runNo)
    streamWriteInt32(streamId, self.bytes)
    if self.kind == MPProbeEvent.KIND_ACK then
        streamWriteBool(streamId, self.ok == true)
        return
    end
    local words = math.floor(self.bytes / 4)
    local sum = 0
    for i = 1, words do
        local w = word(i + self.runNo)
        sum = (sum + w) % 2147483647
        streamWriteInt32(streamId, w)
    end
    streamWriteInt32(streamId, sum)
end

function MPProbeEvent:readStream(streamId, connection)
    self.kind = streamReadUInt8(streamId)
    self.runNo = streamReadInt32(streamId)
    self.bytes = streamReadInt32(streamId)
    if self.kind == MPProbeEvent.KIND_ACK then
        self.ok = streamReadBool(streamId)
    else
        local words = math.floor(self.bytes / 4)
        local sum, same = 0, true
        for i = 1, words do
            local w = streamReadInt32(streamId)
            if w ~= word(i + self.runNo) then same = false end
            sum = (sum + w) % 2147483647
        end
        local sent = streamReadInt32(streamId)
        self.ok = same and sent == sum
    end
    self:run(connection)
end

local function nameOf(connection)
    local ok, name = pcall(function()
        local um = g_currentMission.userManager
        local user = um:getUserByConnection(connection)
        return user ~= nil and user:getNickname() or "?"
    end)
    return ok and name or "?"
end

function MPProbeEvent:run(connection)
    if self.kind == MPProbeEvent.KIND_PAYLOAD_UP then
        -- on the server
        log("server got %d bytes, checksum %s, from %s (run %d)", self.bytes, self.ok and "ok" or "BAD",
            nameOf(connection), self.runNo)
        connection:sendEvent(MPProbeEvent.new(MPProbeEvent.KIND_ACK, self.runNo, self.bytes, self.ok))
        connection:sendEvent(MPProbeEvent.new(MPProbeEvent.KIND_PAYLOAD_DOWN, self.runNo, self.bytes))
    elseif self.kind == MPProbeEvent.KIND_ACK then
        log("server says: got %d bytes, checksum %s (run %d)", self.bytes, self.ok and "ok" or "BAD", self.runNo)
        local r = MPProbe.runs[self.runNo]
        if r ~= nil then r.up = self.ok end
    elseif self.kind == MPProbeEvent.KIND_PAYLOAD_DOWN then
        local r = MPProbe.runs[self.runNo]
        local ms = r ~= nil and (g_time - r.started) or -1
        log("client got %d bytes back, checksum %s, %d ms round trip (run %d)", self.bytes,
            self.ok and "ok" or "BAD", ms, self.runNo)
        if r ~= nil then r.down = self.ok; r.done = true end
        MPProbe:sendNext()
    end
end

function MPProbe:send(kb)
    self.nextRun = self.nextRun + 1
    local bytes = math.floor(kb * 1024)
    self.runs[self.nextRun] = { bytes = bytes, started = g_time }
    log("sending %d bytes (run %d)", bytes, self.nextRun)
    g_client:getServerConnection():sendEvent(MPProbeEvent.new(MPProbeEvent.KIND_PAYLOAD_UP, self.nextRun, bytes))
end

function MPProbe:sendNext()
    local kb = table.remove(self.queue, 1)
    if kb ~= nil then self:send(kb) end
end

function MPProbe:consoleProbe(arg)
    if g_currentMission == nil or g_currentMission.missionDynamicInfo == nil
        or not g_currentMission.missionDynamicInfo.isMultiplayer then
        return "mpProbe needs a multiplayer game"
    end
    if g_server ~= nil then
        return "run mpProbe on a CLIENT (a player who joined), not on the host"
    end
    if arg == "all" then
        self.queue = { 6, 64, 256, 512, 1024 }
        self:sendNext()
        return "sending 6, 64, 256, 512, 1024 KB - watch the log"
    end
    local kb = tonumber(arg or "")
    if kb == nil or kb <= 0 then return "usage: mpProbe <KB> | mpProbe all" end
    self:send(kb)
    return string.format("sending %s KB - watch the log", tostring(kb))
end

function MPProbe:update(dt)
    for run, r in pairs(self.runs) do
        if not r.done and not r.lost and g_time - r.started > self.TIMEOUT_MS then
            r.lost = true
            log("LOST: %d bytes (run %d) - nothing came back in %d s", r.bytes, run, self.TIMEOUT_MS / 1000)
            self:sendNext()
        end
    end
end

function MPProbe:loadMap()
    log("loaded (%s)", g_server ~= nil and "server" or "client")
end

addConsoleCommand("mpProbe", "Flyover MP test: send one message of <KB> to the server and back (or 'all')", "consoleProbe", MPProbe)
addModEventListener(MPProbe)

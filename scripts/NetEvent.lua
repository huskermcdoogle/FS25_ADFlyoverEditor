--[[ ADFlyoverNetEvent - THE ONE NETWORK MESSAGE of the multiplayer editor

Sourced EARLY, from Prelude at mod load, never with the editor files: an event class is registered by
name, and the server hands each joining player the list of names when they connect. A class registered
after a player joined is missing from that player's list and every send to them fails
(docs/multiplayer-plan.md 4.5). So this file defines the class and nothing that needs AutoDrive.

The message is generic: a kind, seven whole numbers, two strings and a slice of bytes (one piece of a
packed action, at most 6 KB - ActionCodec). What the kinds mean is NetGame.lua's business; this file
only carries them and hands each one that arrives to ADFlyoverPrelude.netReceive, which the editor files
set once they are loaded (until then a message is dropped: a player asks for the whole network as soon
as its editor files are in, so nothing before that matters).
]]

ADFlyoverNetEvent = {}
ADFlyoverNetEvent_mt = Class(ADFlyoverNetEvent, Event)
InitEventClass(ADFlyoverNetEvent, "ADFlyoverNetEvent")

ADFlyoverNetEvent.INTS = 7

function ADFlyoverNetEvent.emptyNew()
    local self = Event.new(ADFlyoverNetEvent_mt)
    self.ints = {}
    return self
end

--- kind (1-255), ints (up to 7 whole numbers, each fits a signed 32-bit), s1, s2 (strings), bytes (string)
function ADFlyoverNetEvent.new(kind, ints, s1, s2, bytes)
    local self = ADFlyoverNetEvent.emptyNew()
    self.kind = kind
    self.ints = ints or {}
    self.s1, self.s2 = s1 or "", s2 or ""
    self.bytes = bytes or ""
    return self
end

function ADFlyoverNetEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, self.kind)
    for i = 1, ADFlyoverNetEvent.INTS do
        streamWriteInt32(streamId, math.floor(self.ints[i] or 0))
    end
    streamWriteString(streamId, self.s1 or "")
    streamWriteString(streamId, self.s2 or "")
    local b = self.bytes or ""
    streamWriteInt32(streamId, #b)
    for i = 1, #b do
        streamWriteUInt8(streamId, b:byte(i))
    end
end

function ADFlyoverNetEvent:readStream(streamId, connection)
    self.kind = streamReadUInt8(streamId)
    self.ints = {}
    for i = 1, ADFlyoverNetEvent.INTS do
        self.ints[i] = streamReadInt32(streamId)
    end
    self.s1 = streamReadString(streamId)
    self.s2 = streamReadString(streamId)
    local n = streamReadInt32(streamId)
    local parts, chunk = {}, {}
    for i = 1, n do
        chunk[#chunk + 1] = streamReadUInt8(streamId)
        if #chunk == 4096 then
            parts[#parts + 1] = string.char(unpack(chunk))
            chunk = {}
        end
    end
    if #chunk > 0 then parts[#parts + 1] = string.char(unpack(chunk)) end
    self.bytes = table.concat(parts)
    self:run(connection)
end

function ADFlyoverNetEvent:run(connection)
    local P = ADFlyoverPrelude
    if P ~= nil and P.netReceive ~= nil then
        local ok, err = pcall(P.netReceive, self, connection)
        if not ok then
            Logging.error("[FlyoverEditor] network message %d failed: %s", tonumber(self.kind) or -1, tostring(err))
        end
    end
end

--- To the server (from a player).
function ADFlyoverNetEvent.toServer(ev)
    if g_client ~= nil then g_client:getServerConnection():sendEvent(ev) end
end

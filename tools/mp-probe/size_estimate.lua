--[[ MULTIPLAYER STEP 0: HOW BIG IS A WHOLE-NETWORK PUSH?

Counts the bits AutoDrive's own AutoDriveSync.streamWriteGraph (scripts/Sync.lua) writes for a real
network, field by field, with the stream calls replaced by a counter. One thing cannot be read
offline: how many bits NetworkUtil.writeCompressedWorldPosition spends per coordinate. Its source is
not in the extracted game scripts, so this prints a range for the plausible precisions; the in-game
probe (FS25_MPProbe) reads the real number from AutoDrive's own log line on join.

Also prints what our own tag table would add, and the size of the edit messages in the new
design, so the numbers on the plan page come from here.

    lua size_estimate.lua <network from export_full.py> [map size in m, default 2048]
]]

local net = dofile(assert(arg[1], "usage: lua size_estimate.lua <network.lua> [mapSize]"))
local MAP = tonumber(arg[2] or "2048")
local wps, markers = net.wayPoints, net.mapMarkers or {}
local n = #wps

local function ceilLog2(v) return math.ceil(math.log(v) / math.log(2)) end
local idBits = ceilLog2(n + 1)            -- MWPC_SEND_NUM_BITS
local links = 0
for _, w in ipairs(wps) do links = links + #w.out + #w.incoming end

-- everything except coordinates and strings, exactly as Sync.lua writes it
local fixed = 5 + idBits                                  -- header: bit width, count
fixed = fixed + n * (6 + 6 + 5)                           -- out count, incoming count, flags
fixed = fixed + links * idBits                            -- every out and incoming id
fixed = fixed + 12 + 10                                   -- marker count, group count
local strBytes = 0
local groups = {}
for _, m in ipairs(markers) do
    fixed = fixed + idBits + 1                            -- marker id, isADDebug
    -- streamWriteString: assumed 2-byte length + the bytes ("nil" for empty, as AutoDrive writes)
    local nm = (m.name ~= "" and m.name) or "nil"
    local gp = (m.group ~= "" and m.group) or "nil"
    strBytes = strBytes + 2 + #nm + 2 + #gp
    groups[gp] = true
end
for g in pairs(groups) do fixed = fixed + 10; strBytes = strBytes + 2 + #g end

print(string.format("network: %d points, %d links (out+incoming entries), %d markers; ids take %d bits",
    n, links, #markers, idBits))
print(string.format("without coordinates: %.0f KB", (fixed + strBytes * 8) / 8 / 1024))
print("")
print("whole-network push, by coordinate precision (x and z over the map, y over ~1000 m):")
for _, prec in ipairs({ 0.05, 0.02, 0.01, 0.005 }) do
    local xz = ceilLog2(MAP / prec)
    local y = ceilLog2(1000 / prec)
    local bits = fixed + strBytes * 8 + n * (2 * xz + y)
    print(string.format("  %5.3f m: %2d+%2d+%2d bits per point -> %4.0f KB", prec, xz, y, xz, bits / 8 / 1024))
end

-- our own tag table, sent beside AutoDrive's graph on join / reload
-- tags as player (8 bits) + counter (24 bits); a fresh session numbers the loaded points 1..n, so
-- runs of consecutive tags compress to (start, length)
print("")
print(string.format("tags, plain (32 bits each): %.0f KB", n * 32 / 8 / 1024))
print("tags, as runs: a few bytes per run; a fresh session is 1 run, every later add starts at most 1 more")

-- edit messages in the new design: tags instead of AutoDrive ids, undo info included
local TAG = 32
local MM = 32                                             -- one millimetre coordinate
local op = {
    add    = 4 + TAG + 3 * MM + 5,                        -- opcode, new tag, x y z, flags (fieldID rare)
    move   = 4 + TAG + 2 * (3 * MM + 5),                  -- new place + old place (undo)
    del    = 4 + TAG + 3 * MM + 5,                        -- tag + what it was (undo); links go as clears
    link   = 4 + 2 * TAG + 1,                             -- set/clear a -> b (+ dual bit)
}
local function kb(bits) return bits / 8 / 1024 end
print("")
print("edit messages (bytes), estimates for the new design:")
local rows = {
    { "place a point + link it", op.add + op.link },
    { "drag with falloff, 21 points", 21 * op.move },
    { "build a junction (60 add, 120 link, 40 delete)", 60 * op.add + 120 * op.link + 40 * (op.del + 2 * op.link) },
    { "delete a run of 300 points (+ its ~600 links)", 300 * op.del + 600 * op.link },
    { "field loop, 800 points", 800 * op.add + 800 * op.link },
    { "box-move 2,000 points", 2000 * op.move },
}
for _, r in ipairs(rows) do
    local b = r[2] / 8
    print(string.format("  %-50s %8.0f B  (%5.1f KB)%s", r[1], b, b / 1024, b > 6144 and "  -> pieces" or ""))
end

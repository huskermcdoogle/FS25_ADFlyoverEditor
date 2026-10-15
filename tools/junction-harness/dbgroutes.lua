-- Print the routes a junction's type is read from: jp.pathRoutes.through and .side, each end as a
-- bearing and distance from the centre the classifier uses, plus the arms it groups them into.
--   RIG_TRAILER=11 LEAVE=0|1 lua dbgroutes.lua CX CZ
-- Bearings are the editor's own (atan2(dx, dz): 0 = south, 90 = east, since FS25 z grows south),
-- with the compass direction alongside.
local H = dofile("harness.lua")
local jp = H.lock(tonumber(arg[1]), tonumber(arg[2]), { mode = "clear", radius = 12, leaveThrough = (os.getenv("LEAVE") == "1") })
local c = jp._boxCentre or jp.boxCentre or jp.tracksCentre
local NAMES = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
local function brg(w)
    local b = math.deg(math.atan2(w.x - c.x, w.z - c.z)) % 360
    local compass = (180 - b) % 360
    return string.format("%3.0f (%s)", b, NAMES[math.floor((compass + 22.5) / 45) % 8 + 1])
end
local function dist(w) return math.sqrt((w.x - c.x) ^ 2 + (w.z - c.z) ^ 2) end
local function len(nodes)
    local l = 0
    for i = 2, #nodes do l = l + math.sqrt((nodes[i].x - nodes[i - 1].x) ^ 2 + (nodes[i].z - nodes[i - 1].z) ^ 2) end
    return l
end

print(string.format("centre %.1f, %.1f   type: %s", c.x, c.z, tostring(ADFlyoverEditor.junctionClassify(ADFlyoverEditor, jp))))
local r = jp.pathRoutes or {}
print(string.format("\nTHROUGH routes: %d", #(r.through or {})))
for i, t in ipairs(r.through or {}) do
    local a, b = t[1], t[#t]
    print(string.format("  T%-2d %2d pts %5.1f m | from id %-5d bearing %s %5.1f m out -> to id %-5d bearing %s %5.1f m out",
        i, #t, len(t), a.id, brg(a), dist(a), b.id, brg(b), dist(b)))
end
print(string.format("\nSIDE routes: %d", #(r.side or {})))
for i, sl in ipairs(r.side or {}) do
    local n = sl.nodes or {}
    local far, fd, near, nd = n[1], -1, n[1], math.huge
    for _, w in ipairs(n) do
        local d = dist(w)
        if d > fd then fd, far = d, w end
        if d < nd then nd, near = d, w end
    end
    if far then
        print(string.format("  S%-2d %2d pts %5.1f m %s | far end id %-5d bearing %s %5.1f m out | nearest id %-5d %5.1f m out%s",
            i, #n, len(n), sl.useOut and "in " or "out", far.id, brg(far), fd, near.id, nd,
            sl.cutNode and string.format(" | cut at id %d", sl.cutNode.id) or ""))
    end
end

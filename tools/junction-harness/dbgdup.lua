LOG_ECHO = false
local H = dofile("harness.lua")
local CX, CZ = tonumber(arg[1]), tonumber(arg[2])
local jp = H.lock(CX, CZ, { mode = "clear", radius = 12, leaveThrough = false })
local aps = jp.approaches or {}
print("approach anchors, and how far apart they lie ACROSS the road:")
for i, a in ipairs(aps) do
    print(string.format("   #%d bearing %5.1f  anchor %7.1f,%6.1f  dir=%s",
        i, math.deg(a.bearing or 0) % 360, a.wp.x, a.wp.z, tostring(a.dir)))
end
print("\npairs on a similar bearing - lateral offset between their lines:")
for i = 1, #aps do
    for j = i + 1, #aps do
        local bi, bj = math.deg(aps[i].bearing or 0) % 360, math.deg(aps[j].bearing or 0) % 360
        local sep = math.abs(bi - bj) % 360
        if sep > 180 then sep = 360 - sep end
        local anti = math.abs(sep - 180)
        if sep <= 25 or anti <= 25 then
            -- perpendicular distance from j's anchor to the line through i's anchor on i's bearing
            local dx, dz = math.sin(aps[i].bearing), math.cos(aps[i].bearing)
            local ex, ez = aps[j].wp.x - aps[i].wp.x, aps[j].wp.z - aps[i].wp.z
            local across = math.abs(ex * dz - ez * dx)
            local along = math.abs(ex * dx + ez * dz)
            print(string.format("   #%d (%5.1f) vs #%d (%5.1f): %s by %4.1f deg, %5.2f m across, %5.2f m along",
                i, bi, j, bj, sep <= 25 and "same way" or "opposite", math.min(sep, anti), across, along))
        end
    end
end

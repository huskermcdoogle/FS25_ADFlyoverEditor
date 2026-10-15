-- Dump a site's geometry before and after a clear, for plot.py.
--   lua dump_site.lua CX CZ R on|off out.txt [span]
local H = dofile("harness.lua")
local CX, CZ, R = tonumber(arg[1]), tonumber(arg[2]), tonumber(arg[3]) or 14
local LT = (arg[4] ~= "off")
local OUT = arg[5] or "site.txt"
local SPAN = tonumber(arg[6]) or 45
local f = assert(io.open(OUT, "w"))
local jp = H.lock(CX, CZ, { mode = "clear", radius = R, leaveThrough = LT })
local c = jp.boxCentre or jp.tracksCentre or { x = CX, z = CZ }
f:write(string.format("VIEW %.2f %.2f %.1f\n", c.x, c.z, SPAN))
f:write(string.format("CLICK %.2f %.2f %.1f\n", CX, CZ, R))
if jp.tracksCentre then f:write(string.format("LOCKED %.2f %.2f\n", jp.tracksCentre.x, jp.tracksCentre.z)) end
if jp.boxCentre then f:write(string.format("BOX %.2f %.2f\n", jp.boxCentre.x, jp.boxCentre.z)) end
local function dumpGraph(tag)
    for _, n in pairs(ADGraphManager:getWayPoints()) do
        if n ~= nil and n.id ~= nil and (n.x - c.x) ^ 2 + (n.z - c.z) ^ 2 <= (SPAN * 1.5) ^ 2 then
            f:write(string.format("%sN %d %.2f %.2f\n", tag, n.id, n.x, n.z))
            for _, oid in pairs(n.out or {}) do
                local o = ADGraphManager:getWayPointById(oid)
                if o ~= nil then
                    local dual = false
                    for _, b in pairs(o.out or {}) do if b == n.id then dual = true end end
                    f:write(string.format("%sL %.2f %.2f %.2f %.2f %d\n", tag, n.x, n.z, o.x, o.z, dual and 1 or 0))
                end
            end
        end
    end
end
dumpGraph("B")
local leave = LT
for _, w in ipairs((leave and jp.turnDebris or jp.debris) or {}) do f:write(string.format("DOOMED %.2f %.2f\n", w.x, w.z)) end
for _, w in ipairs(type(jp.boxSweep) == "table" and jp.boxSweep or {}) do f:write(string.format("SWEPT %.2f %.2f\n", w.x, w.z)) end
for _, b in ipairs(type(jp.tidyBands) == "table" and jp.tidyBands or {}) do f:write(string.format("BAND %.2f %.2f %.2f %.2f\n", b.ax, b.az, b.bx, b.bz)) end
for _, e in ipairs(type(jp.tidyEnds) == "table" and jp.tidyEnds or {}) do f:write(string.format("END %.2f %.2f\n", e.x, e.z)) end
for ri, r in ipairs(jp.tidyRoads or {}) do
    for k = 2, #r.centre do
        f:write(string.format("ROAD %d %.2f %.2f %.2f %.2f\n", ri, r.centre[k - 1].x, r.centre[k - 1].z, r.centre[k].x, r.centre[k].z))
    end
end
for i, ap in ipairs(jp.approaches or {}) do
    f:write(string.format("AP %d %s %.2f %.2f %.1f\n", i, ap.dir, ap.wp.x, ap.wp.z, math.deg(ap.bearing or 0)))
end
local log = H.apply()
dumpGraph("A")
f:close()
for _, l in ipairs(log) do print("  APPLY " .. l:gsub(".*FlyoverEditor%]: ", "")) end

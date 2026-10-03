-- Dump a site as the build sees it, for drawing a pattern over it (tools/xt-study/fitpattern.py):
-- clear it with through roads kept, write every link that is left, then run today's build and write
-- the links it added.
--   lua dump_build.lua CX CZ out.txt [span]
--   GRAPH=<network .lua>   the exported map
-- Lines: VIEW cx cz span | C x1 z1 x2 z2 dual (left after the clear) | B x1 z1 x2 z2 dual (added by the build)
local H = dofile("harness.lua")
local CX, CZ = tonumber(arg[1]), tonumber(arg[2])
local OUT = arg[3] or "build_site.txt"
local SPAN = tonumber(arg[4]) or 30

local function links()
    local t = {}
    for _, a in pairs(ADGraphManager:getWayPoints()) do
        if a ~= nil and a.id ~= nil and (a.x - CX) ^ 2 + (a.z - CZ) ^ 2 <= SPAN * SPAN then
            for _, bid in ipairs(a.out or {}) do
                local b = ADGraphManager:getWayPointById(bid)
                if b ~= nil then
                    local dual = false
                    for _, x in ipairs(b.out or {}) do if x == a.id then dual = true end end
                    t[#t + 1] = { a = a, b = b, dual = dual }
                end
            end
        end
    end
    return t
end

local cjp = H.lock(CX, CZ, { mode = "clear", radius = 12, leaveThrough = true })
if cjp ~= nil then H.apply() end
local f = assert(io.open(OUT, "w"))
f:write(string.format("VIEW %.2f %.2f %.1f\n", CX, CZ, SPAN))
local before = {}
for _, L in ipairs(links()) do
    before[L.a] = before[L.a] or {}
    before[L.a][L.b] = true
    f:write(string.format("C %.2f %.2f %.2f %.2f %d\n", L.a.x, L.a.z, L.b.x, L.b.z, L.dual and 1 or 0))
end
local jp = H.lock(CX, CZ, { mode = "build", radius = 15, turnRadius = 12 })
if jp ~= nil then H.build() end
for _, L in ipairs(links()) do
    if not (before[L.a] and before[L.a][L.b]) then
        f:write(string.format("B %.2f %.2f %.2f %.2f %d\n", L.a.x, L.a.z, L.b.x, L.b.z, L.dual and 1 or 0))
    end
end
f:close()
print("wrote " .. OUT)

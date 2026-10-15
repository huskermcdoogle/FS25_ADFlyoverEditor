LOG_ECHO = false
local H = dofile("harness.lua")
local CX, CZ = tonumber(arg[1]), tonumber(arg[2])
-- the component every node belongs to, so we can ask whether a thing is wired to the road at all
local comp, size = {}, {}
local function walk(seed, id)
    local q, n = { seed }, 0
    comp[seed] = id
    while #q > 0 do
        local w = table.remove(q)
        n = n + 1
        for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
            for _, i in ipairs(lst) do
                local t = ADGraphManager:getWayPointById(i)
                if t ~= nil and comp[t] == nil then comp[t] = id q[#q+1] = t end
            end
        end
    end
    size[id] = n
end
local k = 0
for _, w in pairs(ADGraphManager:getWayPoints()) do
    if w ~= nil and comp[w] == nil then k = k + 1 walk(w, k) end
end
local main, best = nil, 0
for id, n in pairs(size) do if n > best then best, main = n, id end end
print(string.format("network: %d component(s); the road network is #%d with %d points", k, main, best))

local jp = H.lock(CX, CZ, { mode = "clear", radius = 12, leaveThrough = false })
print("\nthe approaches the clear is working from:")
for i, ap in ipairs(jp.approaches or {}) do
    local w = ap.wp
    local c = comp[w]
    print(string.format("   #%d bearing %5.1f  %s",
        i, math.deg(ap.bearing or 0) % 360,
        c == main and "on the road network" or string.format("*** NOT WIRED TO THE ROAD (component of %d points) ***", size[c] or 0)))
end
-- and anything the box/track measuring might see
local stray = 0
for _, w in pairs(ADGraphManager:getWayPoints()) do
    if w ~= nil and comp[w] ~= main and math.sqrt((w.x-CX)^2 + (w.z-CZ)^2) <= 60 then stray = stray + 1 end
end
print(string.format("\npoints within 60 m that are NOT wired to the road network: %d", stray))

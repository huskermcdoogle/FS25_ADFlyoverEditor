-- List every piece of network (connected component) with a point within R of a site.
--   lua islands.lua CX CZ [R]
dofile("harness.lua")
local CX, CZ, R = tonumber(arg[1]), tonumber(arg[2]), tonumber(arg[3]) or 60
local done = {}
for _, w in pairs(ADGraphManager:getWayPoints()) do
    if w ~= nil and not done[w] and (w.x - CX) ^ 2 + (w.z - CZ) ^ 2 <= R * R then
        local st, n, near = { w }, 1, math.huge
        local x0, x1, z0, z1 = w.x, w.x, w.z, w.z
        done[w] = true
        while #st > 0 and n < 5000 do
            local a = table.remove(st)
            near = math.min(near, math.sqrt((a.x - CX) ^ 2 + (a.z - CZ) ^ 2))
            for _, lst in ipairs({ a.out or {}, a.incoming or {} }) do
                for _, id in pairs(lst) do
                    local t = ADGraphManager:getWayPointById(id)
                    if t ~= nil and not done[t] then
                        done[t] = true
                        n = n + 1
                        st[#st + 1] = t
                        x0, x1 = math.min(x0, t.x), math.max(x1, t.x)
                        z0, z1 = math.min(z0, t.z), math.max(z1, t.z)
                    end
                end
            end
        end
        print(string.format("piece from id %d: %s points, span %.0f m, nearest %.1f m from the site",
            w.id, n >= 5000 and "5000+" or tostring(n), math.sqrt((x1 - x0) ^ 2 + (z1 - z0) ^ 2), near))
    end
end

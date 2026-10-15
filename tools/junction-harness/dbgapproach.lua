-- The spacing on every approach, before and after, close in. "Extra points leading into the
-- junction" means gaps that got shorter near the box - so compare the gaps, not the totals.
LOG_ECHO = false
local H = dofile("harness.lua")
local CX, CZ, R = tonumber(arg[1]), tonumber(arg[2]), tonumber(arg[3] or "22")
local function gaps()
    local g = {}
    for _, w in pairs(ADGraphManager:getWayPoints()) do
        if w ~= nil and w.id ~= nil then
            for _, id in ipairs(w.out or {}) do
                local t = ADGraphManager:getWayPointById(id)
                if t ~= nil then
                    local mx, mz = (w.x + t.x) / 2, (w.z + t.z) / 2
                    local d = math.sqrt((mx - CX) ^ 2 + (mz - CZ) ^ 2)
                    if d <= R then
                        g[#g + 1] = { len = math.sqrt((w.x - t.x) ^ 2 + (w.z - t.z) ^ 2), d = d }
                    end
                end
            end
        end
    end
    table.sort(g, function(a, b) return a.len < b.len end)
    return g
end
local function show(tag, g)
    local n, short = #g, 0
    local sum = 0
    for _, v in ipairs(g) do sum = sum + v.len if v.len < 2.0 then short = short + 1 end end
    print(string.format("%-7s %3d link(s) within %d m | under 2 m: %2d | mean gap %.2f | shortest %.2f",
        tag, n, R, short, n > 0 and sum / n or 0, g[1] and g[1].len or 0))
    for i = 1, math.min(6, n) do
        print(string.format("        %.2f m gap, %.0f m from the middle", g[i].len, g[i].d))
    end
end
local b = gaps()
H.lock(CX, CZ, { mode = "clear", radius = 12, leaveThrough = (os.getenv("LEAVE") == "1") })
H.apply()
show("BEFORE", b)
show("AFTER", gaps())

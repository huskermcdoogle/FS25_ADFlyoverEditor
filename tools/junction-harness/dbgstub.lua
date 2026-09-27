LOG_ECHO = false
local H = dofile("harness.lua")
local CX, CZ = tonumber(arg[1]), tonumber(arg[2])
local jp = H.lock(CX, CZ, { mode = "clear", radius = 12, leaveThrough = false })
local function deg(w)
    local s, n = {}, 0
    for _, l in ipairs({ w.out or {}, w.incoming or {} }) do
        for _, i in ipairs(l) do if not s[i] then s[i] = true n = n + 1 end end
    end
    return n
end
print("does each arm actually go anywhere?")
for i, ap in ipairs(jp.approaches or {}) do
    -- walk outward from the anchor, away from the junction, and see how far before it stops
    local w, prev, run, steps = ap.wp, nil, 0, 0
    local deadEnd = false
    while steps < 40 do
        local nxt, bd = nil, math.huge
        for _, l in ipairs({ w.out or {}, w.incoming or {} }) do
            for _, id in ipairs(l) do
                local t = ADGraphManager:getWayPointById(id)
                if t ~= nil and t ~= prev then
                    local d = (t.x - CX) ^ 2 + (t.z - CZ) ^ 2
                    if d > (w.x - CX) ^ 2 + (w.z - CZ) ^ 2 and d < bd then bd, nxt = d, t end
                end
            end
        end
        if nxt == nil then deadEnd = true break end
        run = run + math.sqrt((nxt.x - w.x) ^ 2 + (nxt.z - w.z) ^ 2)
        prev, w = w, nxt
        steps = steps + 1
        if deg(w) >= 3 then break end
    end
    print(string.format("   bearing %5.1f  runs %5.1f m outward over %2d point(s)%s",
        math.deg(ap.bearing or 0) % 360, run, steps, deadEnd and "   *** DEAD END - goes nowhere ***" or ""))
end

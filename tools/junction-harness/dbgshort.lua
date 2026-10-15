LOG_ECHO = false
local H = dofile("harness.lua")
local CX, CZ = tonumber(arg[1]), tonumber(arg[2])
local LIM = tonumber(arg[3] or "0.8")
local function short()
    local out = {}
    for _, w in pairs(ADGraphManager:getWayPoints()) do
        if w ~= nil and w.id ~= nil then
            for _, id in ipairs(w.out or {}) do
                local t = ADGraphManager:getWayPointById(id)
                if t ~= nil then
                    local d = math.sqrt((w.x-t.x)^2 + (w.z-t.z)^2)
                    local c = math.min(math.sqrt((w.x-CX)^2+(w.z-CZ)^2), math.sqrt((t.x-CX)^2+(t.z-CZ)^2))
                    if d > 0 and d < LIM and c <= 60 then
                        out[#out+1] = string.format("%5.1f m out  span %4.2f  %.2f,%.2f", c, d, w.x, w.z)
                    end
                end
            end
        end
    end
    table.sort(out)
    return out
end
local b = short()
H.lock(CX, CZ, { mode="clear", radius=12, leaveThrough=(os.getenv("LEAVE") == "1") })
H.apply()
local a = short()
print(string.format("links under %.1f m within 60 m:  before %d   after %d", LIM, #b, #a))
print(" BEFORE:")
for _, l in ipairs(b) do print("   " .. l) end
print(" AFTER:")
for _, l in ipairs(a) do print("   " .. l) end

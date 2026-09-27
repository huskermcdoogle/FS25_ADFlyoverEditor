-- Shrink every loose piece of network near a site to its points within KEEP m, then lock the
-- site - a synthetic stand-in for debris, to check the size rule fires on a small fragment.
--   KEEP=25 lua dbgisland.lua CX CZ
LOG_ECHO = true
local H = dofile("harness.lua")
local CX, CZ = tonumber(arg[1]), tonumber(arg[2])
local KEEP = tonumber(os.getenv("KEEP") or "25")
local done, doomed = {}, {}
for _, w in pairs(ADGraphManager:getWayPoints()) do
    if w ~= nil and not done[w] and (w.x - CX) ^ 2 + (w.z - CZ) ^ 2 <= 60 * 60 then
        local piece, st = { w }, { w }
        done[w] = true
        while #st > 0 and #piece < 100 do
            local a = table.remove(st)
            for _, lst in ipairs({ a.out or {}, a.incoming or {} }) do
                for _, id in pairs(lst) do
                    local t = ADGraphManager:getWayPointById(id)
                    if t ~= nil and not done[t] then
                        done[t] = true
                        piece[#piece + 1] = t
                        st[#st + 1] = t
                    end
                end
            end
        end
        if #piece < 100 then
            for _, p in ipairs(piece) do
                if (p.x - CX) ^ 2 + (p.z - CZ) ^ 2 > KEEP * KEEP then doomed[#doomed + 1] = p.id end
            end
        end
    end
end
for _, id in ipairs(doomed) do ADGraphManager:removeWayPoint(id) end
print(string.format("-- removed %d far point(s) of loose pieces, keeping those within %.0f m", #doomed, KEEP))
H.lock(CX, CZ, { mode = "clear", radius = 12, leaveThrough = true })
LOG_ECHO = true
H.apply()

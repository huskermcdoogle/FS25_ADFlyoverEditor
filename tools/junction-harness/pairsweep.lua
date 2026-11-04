-- SPAN PICK SWEEP on the real network (2026-11-03): pairs of points 3..30 m apart, each picked as a
-- span the way two clicks pick one (spanPath + spanRouteIsDirect). One line per pair:
--   <from> <to> KEEP|REFUSE <points> short|LONG <route m> <straight m>
-- LONG = fails the plain length test. Run on two checkouts and join the outputs to see what a change to
-- the long-way-round rule lets through or refuses.
--   lua pairsweep.lua > out.txt        (from tools/junction-harness; needs the harness map data)
dofile("harness.lua")
local E = ADFlyoverEditor
local all = ADGraphManager:getWayPoints()
for i = 1, #all, 7 do
    local a = all[i]
    for j = i + 1, math.min(#all, i + 400) do
        local b = all[j]
        local d = math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2)
        if d > 3 and d < 30 and (i + j) % 5 == 0 then
            local span = E:spanPath(a.id, b.id)
            if span ~= nil and #span > 2 then
                local ok, len, st = E:spanRouteIsDirect(span)
                local byLen = not (len > st * E.ROUTE_MAX_RATIO and len - st > E.ROUTE_MAX_EXTRA)
                print(string.format("%d %d %s %d %s %.0f %.0f", a.id, b.id, ok and "KEEP" or "REFUSE", #span,
                    byLen and "short" or "LONG", len, st))
            end
        end
    end
end

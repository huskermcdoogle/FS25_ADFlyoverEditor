-- SPAN PICK ON A LOOP, offline (2026-11-03): the real span-pick click (spanPickClick, every span tool
-- uses it) on a made-up network - a one-way loop of 16 points (radius 25 m, traffic 1 -> 2 -> ... -> 16
-- -> 1) at the end of a two-lane road (in-lane 17 -> 18 -> 19 -> 1, out-lane 1 -> 20 -> 21).
--
-- Picks on the loop should not be refused as "the long way round"; a pick from one lane of the road to
-- the other (only joined by a U-turn at the loop's junction) still should be.
--   lua spanpick.lua           (from tools/junction-harness; no map data needed)
-- Prints PASS or FAIL lines and exits 1 on any FAIL.

local N, R = 16, 25
local graphFile = os.tmpname()
do
    local f = assert(io.open(graphFile, "w"))
    f:write("return {\n")
    for i = 1, N do
        local a = (i - 1) / N * 2 * math.pi
        f:write(string.format("  {id=%d,x=%.3f,y=0,z=%.3f,flags=0,out={%d}},\n",
            i, R * math.cos(a), R * math.sin(a), i % N + 1))
    end
    f:write(string.format("  {id=17,x=%.3f,y=0,z=-3,flags=0,out={18}},\n", R + 60))
    f:write(string.format("  {id=18,x=%.3f,y=0,z=-3,flags=0,out={19}},\n", R + 40))
    f:write(string.format("  {id=19,x=%.3f,y=0,z=-3,flags=0,out={1}},\n", R + 20))
    f:write(string.format("  {id=20,x=%.3f,y=0,z=3,flags=0,out={21}},\n", R + 20))
    f:write(string.format("  {id=21,x=%.3f,y=0,z=3,flags=0,out={}},\n", R + 40))
    -- A small one-way loop on its own (ids 22..33, radius 8 m, at z=100), its last point only 8 degrees
    -- short of its first: carried round, the span's two ends end up side by side.
    for k = 0, 11 do
        local a = math.rad(k * 32)
        f:write(string.format("  {id=%d,x=%.3f,y=0,z=%.3f,flags=0,out={%d}},\n",
            22 + k, 8 * math.cos(a), 100 + 8 * math.sin(a), 22 + (k + 1) % 12))
    end
    f:write("}\n")
    f:close()
end

local realGetenv = os.getenv
os.getenv = function(k) if k == "GRAPH" then return graphFile end return realGetenv(k) end
dofile("harness.lua")
os.getenv = realGetenv
os.remove(graphFile)
local E = ADFlyoverEditor

local warned
E.warnPlayer = function(_, m) warned = m end
E.selectionCount = 0
E.pickFilter = nil
local clock = 0
E.nowMs = function() return clock end

local from, to
local cfg = {
    getFrom = function() return from end,
    getTo = function() return to end,
    setEnds = function(a, b) from, to = a, b end,
}
local function click(id)
    clock = clock + 5000   -- never a double-click
    warned = nil
    E.hoverId = id
    E:spanPickClick(cfg)
end
local function fresh()
    from, to, E.spanIds = nil, nil, nil
end
local function spanText()
    if warned ~= nil then return "REFUSED" end
    if E.spanIds == nil then return "none" end
    return table.concat(E.spanIds, ",")
end

local fails = 0
local function check(what, got, want)
    local ok = got == want
    print(string.format("%s %s: got %s%s", ok and "PASS" or "FAIL", what, got, ok and "" or (", want " .. want)))
    if not ok then fails = fails + 1 end
end

fresh(); click(3); click(5)
check("loop, clicked with the traffic (3 then 5)", spanText(), "3,4,5")

fresh(); click(5); click(3)
check("loop, clicked against the traffic (5 then 3)", spanText(), "3,4,5")

fresh(); click(2); click(14)
check("loop, two clicks far round (2 then 14): the shorter side", spanText(), "14,15,16,1,2")

-- 12 is nearer the 8 end: that end moves on round the loop (225 degrees of it, past the length test).
fresh(); click(2); click(8); click(12)
check("loop, span 2..8 then click 12: grows on round the loop", spanText(), "2,3,4,5,6,7,8,9,10,11,12")

-- 14 is nearer the 2 end: that end moves back through the junction, and the span keeps 2..8.
fresh(); click(2); click(8); click(14)
check("loop, span 2..8 then click 14: grows back through the junction", spanText(), "14,15,16,1,2,3,4,5,6,7,8")

-- The user's case (2026-11-03, build 716): carry the end round a small loop one point at a time. Near the
-- end the click is nearer the span's OTHER end in a straight line; it must still move the end being carried.
fresh(); click(22); click(23)
local carried = true
for id = 24, 33 do
    click(id)
    local want = {}
    for k = 22, id do want[#want + 1] = k end
    if spanText() ~= table.concat(want, ",") then
        carried = false
        print(string.format("     click %d gave %s", id, spanText()))
        break
    end
end
check("small loop, end carried round point by point to the last one", carried and spanText() or "jumped",
    "22,23,24,25,26,27,28,29,30,31,32,33")

-- Span 3..8 on the big loop (8 placed last), click 2 just before the 3 end: that end moves, not 8 the
-- long way round.
fresh(); click(3); click(8); click(2)
check("loop, span 3..8 then click just before its start: the start moves", spanText(), "2,3,4,5,6,7,8")

-- A click on the span shrinks it from the end it is fewer points from.
fresh(); click(2); click(8); click(7)
check("loop, span 2..8 then click 7 on it: the 8 end comes back", spanText(), "2,3,4,5,6,7")

fresh(); click(18); click(21)
check("road, in-lane to out-lane (U-turn at the junction): still refused", spanText(), "REFUSED")

fresh(); click(17); click(19)
check("road, along one lane", spanText(), "17,18,19")

print(fails == 0 and "ALL PASS" or (fails .. " FAIL(S)"))
os.exit(fails == 0 and 0 or 1)

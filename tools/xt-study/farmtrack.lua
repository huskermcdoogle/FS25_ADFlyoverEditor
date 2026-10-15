-- A T OF SINGLE-TRACK FARM ROADS (101 on the survey map, the user's 2026-10-07 test): every road one
-- two-way lane. Two wirings of its turns:
--   "one-way turns"  - today's builder (doc 06, decided 2026-10-02): each direction its own one-way
--                      turn, both on the same line between the side road's mouth and the through road;
--   "two-way turns"  - one turn per side, linked both ways.
-- Two trucks, every pair of the six movements, starts -10 s .. +10 s apart in 0.5 s steps, both
-- check orders. Counts MEET (bodies overlap) and STUCK (both stopped for good) per wiring.
--   lua farmtrack.lua <repo scripts/editor dir> [rig: small|big|semi] [kmh] [turn radius]
local T = dofile("adtraffic.lua")
dofile(arg[1] .. "/SweptSim.lua")
local rigName = arg[2] or "big"
local raw = SweptSim.EXAMPLE_RIG
for _, r in ipairs(SweptSim.RIGS) do if r.key == rigName then raw = r end end
local RIG = T.rigFrom(raw)
local KMH = tonumber(arg[3]) or 20
local R = tonumber(arg[4]) or 8

local function build(layout)
    local net = T.network()
    -- the through road, west-east along z = 0, every 5 m, two-way; the ties at x = -R and +R
    local road = {}
    for x = -110, 110, 5 do road[#road + 1] = { "R" .. x, x, 0 } end
    local function insertAt(x)
        for i = 1, #road - 1 do
            if road[i][2] < x and road[i + 1][2] > x then table.insert(road, i + 1, { "R" .. x, x, 0 }) return end
        end
    end
    insertAt(-R) insertAt(R)
    T.lane(net, road, true)
    -- the side road, south from the mouth M at z = R, every 5 m, two-way
    local side = { { "M", 0, R } }
    for z = 15, 110, 5 do if z > R + 2 then side[#side + 1] = { "S" .. z, 0, z } end end
    T.lane(net, side, true)
    -- the turns: quarter circles from M (heading north) to the ties (heading west / east)
    local function arc(sign, tag)
        local pts = { { "M", 0, R } }
        local n = math.max(3, math.floor(R * math.pi / 2 / 2 + 0.5))
        for k = 1, n - 1 do
            local a = (math.pi / 2) * k / n
            -- centre (sign * R, R): from angle pi (M) towards the tie at angle pi/2 (top)
            local x = sign * R - sign * R * math.cos(a)
            local z = R - R * math.sin(a)
            pts[#pts + 1] = { tag .. k, x, z }
        end
        pts[#pts + 1] = { "R" .. (sign * R), sign * R, 0 }
        return pts
    end
    if layout == "one-way turns" then
        for _, sg in ipairs({ { -1, "W" }, { 1, "E" } }) do
            local out = arc(sg[1], "out" .. sg[2])            -- side road -> through road
            T.lane(net, out, false)
            local back = arc(sg[1], "in" .. sg[2])            -- through road -> side road, same line
            local rev = {}
            for i = #back, 1, -1 do rev[#rev + 1] = back[i] end
            T.lane(net, rev, false)
        end
    else
        for _, sg in ipairs({ { -1, "W" }, { 1, "E" } }) do T.lane(net, arc(sg[1], "turn" .. sg[2]), true) end
    end
    return net
end

local MOVES = {
    { "W->E", "R-110", "R110" }, { "E->W", "R110", "R-110" },
    { "W->S", "R-110", "S110" }, { "S->W", "S110", "R-110" },
    { "E->S", "R110", "S110" },  { "S->E", "S110", "R110" },
}

print(string.format("Farm-track T, %s rig, %d km/h, turns of %d m. Two trucks, every pair of movements, 41 start offsets, both check orders.", rigName, KMH, R))
local totals = {}
for _, layout in ipairs({ "one-way turns", "two-way turns" }) do
    local net = build(layout)
    local routes = {}
    for _, m in ipairs(MOVES) do
        routes[m[1]] = T.route(net, m[2], m[3])
        assert(routes[m[1]] ~= nil, layout .. ": no route " .. m[1])
    end
    print(string.format("\n== %s", layout))
    local tot = { ok = 0, MEET = 0, STUCK = 0 }
    local worst = {}
    for _, a in ipairs(MOVES) do
        for _, b in ipairs(MOVES) do
            local c = { ok = 0, MEET = 0, STUCK = 0 }
            for k = -20, 20 do
                local d = k * 0.5
                for _, order in ipairs({ { 1, 2 }, { 2, 1 } }) do
                    local res = T.run(net, {
                        { route = routes[a[1]], rig = RIG, kmh = KMH, start = math.max(0, -d), s0 = 10 },
                        { route = routes[b[1]], rig = RIG, kmh = KMH, start = math.max(0, d), s0 = 10 },
                    }, { order = order })
                    c[res] = c[res] + 1
                    tot[res] = tot[res] + 1
                end
            end
            -- Head-on on a shared single-track road: the two drive one road towards each other, and
            -- neither checks while on a two-way link - no junction wiring changes that.
            local headOn = (a[2] == b[3] and a[3] == b[2]) or (a[2] == b[3]) or (a[3] == b[2])
            worst[#worst + 1] = string.format("  %-5s + %-5s : %2d meet, %2d stuck of 82%s", a[1], b[1], c.MEET, c.STUCK,
                headOn and "   (head-on along a track)" or "")
            if not headOn then
                tot.jMEET, tot.jSTUCK, tot.jN = (tot.jMEET or 0) + c.MEET, (tot.jSTUCK or 0) + c.STUCK, (tot.jN or 0) + 82
            end
        end
    end
    for _, w in ipairs(worst) do print(w) end
    print(string.format("  TOTAL: %d ok, %d meet, %d stuck of %d", tot.ok, tot.MEET, tot.STUCK, tot.ok + tot.MEET + tot.STUCK))
    print(string.format("  AT THE JUNCTION ONLY (pairs not head-on along a track): %d meet, %d stuck of %d", tot.jMEET or 0, tot.jSTUCK or 0, tot.jN or 0))
    totals[layout] = tot
end

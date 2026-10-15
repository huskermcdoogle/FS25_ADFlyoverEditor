-- TRAFFIC THROUGH A JUNCTION THE EDITOR LAID (adtraffic.lua's rules): the network simexport.lua wrote,
-- every way in and out found at the edge, each movement routed by AutoDrive's own rules, then two
-- trucks through every pair of movements at many start offsets, both check orders.
--   lua junctionsim.lua <repo scripts/editor dir> <net.lua> [rig] [kmh] [variant]
-- variant: "as laid" (default) | "main two-way R" (the west-east road's lanes two-way within R m of the
-- middle: through traffic never waits there, and everyone else waits for it).
local T = dofile("adtraffic.lua")
dofile(arg[1] .. "/SweptSim.lua")
local rigName = arg[3] or "big"
local raw = SweptSim.EXAMPLE_RIG
for _, r in ipairs(SweptSim.RIGS) do if r.key == rigName then raw = r end end
local RIG = T.rigFrom(raw)
local KMH = tonumber(arg[4]) or 20
local VARIANT = arg[5] or "as laid"
local STEP = tonumber(os.getenv("STEP") or "1")

local data = dofile(arg[2])
local net = T.network()
for _, w in ipairs(data) do T.point(net, w.id, w.x, w.z) end
for _, w in ipairs(data) do
    for _, o in ipairs(w.out) do if net.pts[o] ~= nil then T.link(net, w.id, o) end end
end

-- THE MAIN ROAD TWO-WAY NEAR THE MIDDLE: every link of a lane running west-east (within 20 deg) with
-- both ends within R m of the middle gets its reverse too.
local mainR = VARIANT:match("^main two%-way (%d+)")
if mainR ~= nil then
    mainR = tonumber(mainR)
    local n = 0
    for _, w in ipairs(data) do
        local A = net.pts[w.id]
        for _, o in ipairs(w.out) do
            local B = net.pts[o]
            if B ~= nil and A.x * A.x + A.z * A.z <= mainR * mainR and B.x * B.x + B.z * B.z <= mainR * mainR then
                local dx, dz = B.x - A.x, B.z - A.z
                local L = math.sqrt(dx * dx + dz * dz)
                if L > 1e-6 and math.abs(dz) / L < math.sin(math.rad(20)) and math.abs(A.z) < 4 and math.abs(B.z) < 4 then
                    T.link(net, o, w.id)
                    n = n + 1
                end
            end
        end
    end
    print(string.format("variant: %d main-road link(s) within %d m of the middle made two-way", n, mainR))
end

-- "shared early": where two lanes run into one point (a merge), the second joins the first where their
-- paths first come within a truck's width (+0.4 m) of each other, not where they meet: the bodies touch
-- from there on, so that is where the waiting has to be about. Each incoming chain is followed back up
-- to 25 m; the one whose points come close first is cut there and linked across to the other.
local function sharedEarly()
    local moved = 0
    local P = net.pts
    local function back(id, skip)
        -- the chain behind a point, nearest first, through plain points only
        local out, cur, prev = {}, id, skip
        for _ = 1, 30 do
            local p = P[cur]
            out[#out + 1] = p
            if #p.incoming ~= 1 or #p.out > 1 and cur ~= id then break end
            prev, cur = cur, p.incoming[1]
            if P[cur] == nil then break end
        end
        return out
    end
    for _, id in ipairs(net.order) do
        local M = P[id]
        if #M.incoming == 2 and M.x * M.x + M.z * M.z < 40 * 40 then
            local A = back(M.incoming[1])
            local B = back(M.incoming[2])
            local bestA, bestB, bestD = nil, nil, -1
            for ia, a in ipairs(A) do
                for ib, b in ipairs(B) do
                    local d = math.sqrt((a.x - M.x) ^ 2 + (a.z - M.z) ^ 2)
                    if (a.x - b.x) ^ 2 + (a.z - b.z) ^ 2 < 3.0 * 3.0 and d > bestD and d < 25 then bestA, bestB, bestD = ia, ib, d end
                end
            end
            if bestA ~= nil and bestD > 2 then
                -- the chain that is the turn (more bend) joins the other at the matched point
                local a, b = A[bestA], B[bestB]
                -- cut b's chain from b onward to M, and link b's predecessor... keep it simple: b -> a
                local nb = b.out[1]
                if nb ~= nil and nb ~= a.id then
                    -- unlink b -> nb, link b -> a
                    for k, o in ipairs(b.out) do if o == nb then table.remove(b.out, k) break end end
                    for k, o in ipairs(P[nb].incoming) do if o == b.id then table.remove(P[nb].incoming, k) break end end
                    T.link(net, b.id, a.id)
                    moved = moved + 1
                end
            end
        end
    end
    return moved
end
-- "spaced": inside 40 m of the middle, plain points (one in, one out) closer than 3.5 m to the point
-- kept before them are dropped, their neighbours linked directly - so AutoDrive's five points ahead
-- reach about 17 m, more than a truck needs to stop from 20 km/h.
local function spaced(minGap)
    local P = net.pts
    local dropped = 0
    for _, id in ipairs(net.order) do
        local p = P[id]
        if p ~= nil and p.x * p.x + p.z * p.z < 40 * 40 and #p.incoming == 1 and #p.out == 1 then
            local a, b = P[p.incoming[1]], P[p.out[1]]
            if a ~= nil and b ~= nil and a ~= b and not (#a.out == 1 and #b.incoming == 1 and false) then
                local dA = math.sqrt((p.x - a.x) ^ 2 + (p.z - a.z) ^ 2)
                if dA < minGap and not has2(a, b) then
                    -- a -> p -> b becomes a -> b
                    for k, o in ipairs(a.out) do if o == id then a.out[k] = b.id break end end
                    for k, o in ipairs(b.incoming) do if o == id then b.incoming[k] = a.id break end end
                    p.out, p.incoming = {}, {}
                    dropped = dropped + 1
                end
            end
        end
    end
    return dropped
end
function has2(a, b) for _, o in ipairs(a.out) do if o == b.id then return true end end return false end
if VARIANT:find("shared early") then print(string.format("variant: %d merge(s) moved to where the paths first touch", sharedEarly())) end
if VARIANT:find("spaced") then
    local gap = tonumber(VARIANT:match("spaced (%d+%.?%d*)")) or 3.5
    print(string.format("variant: %d point(s) dropped, junction points at least %.1f m apart", spaced(gap), gap))
end

-- "box two-way R": every link with both ends within R m of the middle gets its reverse too. A truck
-- about to enter, still on a one-way link, then looks across the whole box (its check runs on while
-- the links ahead stay two-way) and waits for anyone inside it; a truck inside never waits.
local boxR = VARIANT:match("box two%-way (%d+)")
if boxR ~= nil then
    boxR = tonumber(boxR)
    local n = 0
    for _, w in ipairs(data) do
        local A = net.pts[w.id]
        for _, o in ipairs(w.out) do
            local B = net.pts[o]
            if B ~= nil and A.x * A.x + A.z * A.z <= boxR * boxR and B.x * B.x + B.z * B.z <= boxR * boxR then
                T.link(net, o, w.id)
                n = n + 1
            end
        end
    end
    print(string.format("variant: %d link(s) within %d m of the middle made two-way", n, boxR))
end

-- Ways in and out at the edge, and which arm each is on (by bearing from the middle).
local entries, exits = {}, {}
for _, id in ipairs(net.order) do
    local p = net.pts[id]
    if p.x * p.x + p.z * p.z > 100 * 100 then
        if #p.incoming == 0 then entries[#entries + 1] = p end
        if #p.out == 0 then exits[#exits + 1] = p end
    end
end
local function armOf(p)
    local a = math.deg(math.atan2(p.x, -p.z)) % 360
    if a < 45 or a >= 315 then return "N" elseif a < 135 then return "E" elseif a < 225 then return "S" end
    return "W"
end
local moves = {}
for _, e in ipairs(entries) do
    for _, x in ipairs(exits) do
        if armOf(e) ~= armOf(x) then
            local r = T.route(net, e.id, x.id)
            if r ~= nil then
                moves[#moves + 1] = { name = armOf(e) .. "->" .. armOf(x), route = r }
            else
                print("  no route " .. armOf(e) .. "->" .. armOf(x))
            end
        end
    end
end
table.sort(moves, function(a, b) return a.name < b.name end)
local names = {}
for _, m in ipairs(moves) do
    local L = 0
    for i = 2, #m.route do
        local a, b = net.pts[m.route[i - 1]], net.pts[m.route[i]]
        L = L + math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
    end
    names[#names + 1] = string.format("%s(%.0fm)", m.name, L)
end
print(string.format("%s | %s | %s rig, %d km/h | %d movements: %s", arg[2]:match("[^/\\]+$"), VARIANT, rigName, KMH, #moves, table.concat(names, " ")))

local tot = { ok = 0, MEET = 0, STUCK = 0 }
local lines = {}
for _, a in ipairs(moves) do
    for _, b in ipairs(moves) do
        local c = { ok = 0, MEET = 0, STUCK = 0 }
        local ex = nil
        for k = -10, 10, STEP do
            for _, order in ipairs({ { 1, 2 }, { 2, 1 } }) do
                local res, detail = T.run(net, {
                    { route = a.route, rig = RIG, kmh = KMH, start = math.max(0, -k), s0 = 20 },
                    { route = b.route, rig = RIG, kmh = KMH, start = math.max(0, k), s0 = 20 },
                }, { order = order })
                c[res] = c[res] + 1
                tot[res] = tot[res] + 1
                if res ~= "ok" and ex == nil then ex = string.format("%s at offset %+d s: %s", res, k, detail) end
            end
        end
        if c.MEET + c.STUCK > 0 then
            lines[#lines + 1] = string.format("  %-5s + %-5s : %2d meet, %2d stuck of %d   e.g. %s", a.name, b.name, c.MEET, c.STUCK,
                c.ok + c.MEET + c.STUCK, ex)
        end
    end
end
for _, l in ipairs(lines) do print(l) end
print(string.format("  TOTAL: %d ok, %d meet, %d stuck of %d", tot.ok, tot.MEET, tot.STUCK, tot.ok + tot.MEET + tot.STUCK))

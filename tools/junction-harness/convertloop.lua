-- The 1.0.2.1 hotfix on main: the convert tool's whole-run scope on a closed loop. The link that closes
-- the loop at the clicked point was left out, so it kept its old direction while the rest changed, and
-- a second click somewhere else picked it up (the "1 change" on every repeat in the game log).
--   lua convertloop.lua            (from main's 1.0.2.1 hotfix, 32ce9a3; 15 checks)
dofile("harness.lua")
local E = ADFlyoverEditor
local G = ADGraphManager
ADEditorHistory = ADEditorHistory or {}
ADEditorHistory.snapshot = function() end

local ok, failed = 0, 0
local function check(name, cond, detail)
    if cond then ok = ok + 1 print("ok    " .. name)
    else failed = failed + 1 print("FAIL  " .. name .. (detail and ("  (" .. detail .. ")") or "")) end
end
local function has(t, v) for _, x in ipairs(t) do if x == v then return true end end return false end
local function link(a, b)
    local aw, bw = G:getWayPointById(a), G:getWayPointById(b)
    if not has(aw.out, b) then table.insert(aw.out, b) end
    if not has(bw.incoming, a) then table.insert(bw.incoming, a) end
end
local function both(a, b) link(a, b) link(b, a) end
local function points(n, x0, z0)
    local ids = {}
    for i = 1, n do ids[i] = G:recordWayPoint(x0 + 10 * i, 0, z0 + (i % 2), false, false, false, nil, 0).id end
    return ids
end
-- One character per consecutive pair (and the closing pair when `closed`): ">" only forward,
-- "<" only backward, "=" both ways, "." not linked.
local function state(ids, closed)
    local s = {}
    local n = #ids
    for i = 1, closed and n or n - 1 do
        local a, b = ids[i], ids[i % n + 1]
        local f = has(G:getWayPointById(a).out, b)
        local r = has(G:getWayPointById(b).out, a)
        s[#s + 1] = (f and r) and "=" or f and ">" or r and "<" or "."
    end
    return table.concat(s)
end
local function convert(seed, op)
    E.hoverId, E.convertScope, E.convertOp = seed, E.DELETE_SCOPE.RUN, op
    E:convertAtCursor()
end
local OP = E.CONVERT_OP
local function allOf(s, c) return s:match("^%" .. c .. "+$") ~= nil end

-- 1. a loop on its own, like AutoDrive's field loop: 12 points, two-way all round
local ring = points(12, 60000, 60000)
for i = 1, 12 do both(ring[i], ring[i % 12 + 1]) end
convert(ring[1], OP.ONEWAY)
local s1 = state(ring, true)
check("loop, one-way: every link one-way, all the same way round (closing link too)",
    allOf(s1, ">") or allOf(s1, "<"), s1)
convert(ring[5], OP.ONEWAY)
check("loop, one-way again from another point: nothing changes", state(ring, true) == s1, state(ring, true))
convert(ring[12], OP.ONEWAY)
check("loop, one-way again from the point before the first click: nothing changes", state(ring, true) == s1, state(ring, true))
convert(ring[3], OP.REVERSE)
local s2 = state(ring, true)
check("loop, other way: every link flipped, closing link too",
    s2 == s1:gsub(".", { [">"] = "<", ["<"] = ">" }), s1 .. " -> " .. s2)
convert(ring[8], OP.REVERSE)
check("loop, other way twice: back as it was", state(ring, true) == s1, state(ring, true))
convert(ring[2], OP.TWOWAY)
check("loop, two-way: every link two-way, closing link too", allOf(state(ring, true), "="), state(ring, true))
convert(ring[10], OP.TWOWAY)
check("loop, two-way again: still two-way", allOf(state(ring, true), "="), state(ring, true))

-- 2. a one-way loop clicked on a stretch that is two-way: it keeps the way the rest of it runs
for i = 1, 12 do G:getWayPointById(ring[i]).out, G:getWayPointById(ring[i]).incoming = {}, {} end
for i = 1, 12 do link(ring[i % 12 + 1], ring[i]) end -- one-way, against the ids
both(ring[6], ring[7]) both(ring[7], ring[8])           -- two links round the clicked point two-way
convert(ring[7], OP.ONEWAY)
check("loop mostly one-way, clicked where it is two-way: follows the rest", allOf(state(ring, true), "<"), state(ring, true))

-- 3. a loop hanging off one junction: the link back into the junction is part of the run
local J = points(1, 61000, 60000)[1]
local stub = points(2, 61000, 60100)
both(J, stub[1]) both(stub[1], stub[2])
local loop = points(6, 61000, 60050)
both(J, loop[1])
for i = 1, 5 do both(loop[i], loop[i + 1]) end
both(loop[6], J)
local lollipop = { J, loop[1], loop[2], loop[3], loop[4], loop[5], loop[6] }
convert(loop[3], OP.ONEWAY)
local s3 = state(lollipop, true)
check("loop off one junction, one-way: all 7 links one-way, the same way round",
    allOf(s3, ">") or allOf(s3, "<"), s3)
check("loop off one junction: the other road at the junction is left alone", state({ J, stub[1] }, false) == "=")
convert(loop[5], OP.ONEWAY)
check("loop off one junction, one-way again: nothing changes", state(lollipop, true) == s3, state(lollipop, true))

-- 4. a single point between two junctions: both its links are converted
local three = points(3, 62000, 60000)
local J1, p, J2 = three[1], three[2], three[3]
for k, j in ipairs({ J1, J2 }) do
    local legs = points(2, 62000 + 100 * k, 60100)
    both(j, legs[1]) both(j, legs[2])
end
both(J1, p) both(p, J2)
convert(p, OP.ONEWAY)
local s4 = state({ J1, p, J2 }, false)
check("one point between two junctions, one-way: both links one-way, the same way", s4 == ">>" or s4 == "<<", s4)

-- 5. an open run already one-way: one-way again keeps its direction, from either end
local open = points(6, 63000, 60000)
for i = 1, 5 do link(open[i + 1], open[i]) end
convert(open[2], OP.ONEWAY)
check("open run already one-way: one-way keeps its direction", state(open, false) == "<<<<<", state(open, false))
convert(open[5], OP.ONEWAY)
check("open run already one-way, clicked at the other end: still kept", state(open, false) == "<<<<<", state(open, false))

-- 6. an open run, two-way: one-way still works (direction from the walk), and a plain two-point
--    road is not treated as a loop
local pair = points(2, 64000, 60000)
both(pair[1], pair[2])
convert(pair[1], OP.ONEWAY)
local s6 = state(pair, false)
check("two points, one-way: one link one-way, not flipped back by a doubled pair", s6 == ">" or s6 == "<", s6)

print(string.format("%d ok, %d failed", ok, failed))

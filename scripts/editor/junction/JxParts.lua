-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua
-- loads it after FlyoverEditor.lua, in the old file's order.
-- MODSPLIT: HELPERS FROM THE FILES LOADED BEFORE THIS ONE (tools/modsplit/split.py writes this block)
for _, name in ipairs({ "JUNCTION_CLEARED_READ_R", "junctionAngDiff", "jxByPlace", "jxCompass", "jxPartNames", "jxSortParts" }) do
    if ADFlyoverEditor.shared == nil or ADFlyoverEditor.shared[name] == nil then
        Logging.error("[FlyoverEditor]: JxParts.lua needs %s, which no file loaded before it shares", name)
    end
end
local JUNCTION_CLEARED_READ_R = ADFlyoverEditor.shared.JUNCTION_CLEARED_READ_R
local junctionAngDiff = ADFlyoverEditor.shared.junctionAngDiff
local jxByPlace = ADFlyoverEditor.shared.jxByPlace
local jxCompass = ADFlyoverEditor.shared.jxCompass
local jxPartNames = ADFlyoverEditor.shared.jxPartNames
local jxSortParts = ADFlyoverEditor.shared.jxSortParts
-- MODSPLIT: end of the helpers

-- THE USER'S NAMES FOR THE PARTS OF A SPLIT JUNCTION (split_decisions.txt in the harness). The
-- number never changes; the parts carry 8-point compass letters. Two parts are each lettered by
-- their direction from the midpoint of the two (72w and 72e); of three, the middle one keeps the
-- bare number and the outer two are lettered by their direction from it (39, 39se, 39nw). Sets
-- p.letter on each of `pts` ({ x, z } each): "" for the bare number, nil for NO NAME. Four or more
-- has no rule from the user, and neither has a letter that would come out twice - lettered from
-- the middle of them all, four parts along one road gave two parts the same letter - so those are
-- left without names rather than given ones that mean nothing.
local function jxPartLetters(pts)
    for _, p in ipairs(pts) do p.letter = nil end
    if #pts == 1 then
        pts[1].letter = ""
    elseif #pts == 2 then
        local mx, mz = (pts[1].x + pts[2].x) / 2, (pts[1].z + pts[2].z) / 2
        for _, p in ipairs(pts) do p.letter = jxCompass(p.x - mx, p.z - mz) end
    elseif #pts == 3 then
        -- the middle one is the one nearest the other two together (first in the list on a tie)
        local mid, best = nil, math.huge
        for _, p in ipairs(pts) do
            local s = 0
            for _, q in ipairs(pts) do s = s + math.sqrt((p.x - q.x) ^ 2 + (p.z - q.z) ^ 2) end
            if s < best then best, mid = s, p end
        end
        for _, p in ipairs(pts) do
            if p == mid then p.letter = "" else p.letter = jxCompass(p.x - mid.x, p.z - mid.z) end
        end
    end
    local seen = {}
    for _, p in ipairs(pts) do
        if p.letter ~= nil then
            if seen[p.letter] then
                for _, q in ipairs(pts) do q.letter = nil end
                return
            end
            seen[p.letter] = true
        end
    end
end

-- JUNCTION_CLEARED_READ_R, how far out a cleared site's lanes are read, is set beside the junction
-- registry (above), which names cleared sites by it too.

--- A CLEARED (VIRGIN) SITE, GATHERED FOR READING: the lanes the circle of JUNCTION_CLEARED_READ_R
--- round the site's middle cuts, as approaches the way build gathers its own - an edge coming into
--- the circle is an entry, one going out an exit, anchored at the node inside - and folded the same
--- way (same direction, bearings within 35 degrees, within 6 m, and still within 5 m of each other
--- followed 5 m further out; a lane end on a loose piece gives way to one on the network). Only what
--- junctionClassify and junctionParts read of a cleared site is here: the approaches, the middle, and
--- no through routes (build works none out, and a cleared site is read from its lanes alone). Returns
--- a table to hand them.
function ADFlyoverEditor:junctionVirginReading(site)
    if site == nil then return nil end
    local cx, cz = site.x, site.z
    local R2 = JUNCTION_CLEARED_READ_R * JUNCTION_CLEARED_READ_R
    -- IN BUILD'S OWN ORDER, by place (jxByPlace), as build walks its circle. It matters because the
    -- classifier groups a cleared site's lanes first come, first served: the order alone has
    -- changed the kind read at 70 and 74. This used to be pairs() over the id-keyed table, an order
    -- a clear anywhere nearby reshuffles.
    local inside = {}
    for _, wp in pairs(ADGraphManager:getWayPoints()) do
        local dx, dz = wp.x - cx, wp.z - cz
        if dx * dx + dz * dz <= R2 then
            inside[wp.id] = wp
        end
    end
    local raw = {}
    for _, wp in jxByPlace(inside) do
        for _, tid in pairs(wp.out or {}) do
            if inside[tid] == nil then
                local t = ADGraphManager:getWayPointById(tid)
                if t ~= nil then
                    raw[#raw + 1] = { wp = wp, dir = "out", bearing = math.atan2(t.x - wp.x, t.z - wp.z) }
                end
            end
        end
        for _, sid in pairs(wp.incoming or {}) do
            if inside[sid] == nil then
                local s = ADGraphManager:getWayPointById(sid)
                if s ~= nil then
                    raw[#raw + 1] = { wp = wp, dir = "in", bearing = math.atan2(wp.x - s.x, wp.z - s.z) }
                end
            end
        end
    end
    local looseCache = {}
    local function onLoosePiece(wp)
        if looseCache[wp.id] ~= nil then return looseCache[wp.id] end
        local seen, stack, n = { [wp.id] = true }, { wp }, 0
        while #stack > 0 and n < 200 do
            local w = table.remove(stack)
            n = n + 1
            for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
                for _, id in pairs(lst) do
                    if not seen[id] then
                        seen[id] = true
                        local t = ADGraphManager:getWayPointById(id)
                        if t ~= nil then stack[#stack + 1] = t end
                    end
                end
            end
        end
        looseCache[wp.id] = (#stack == 0 and n < 200)
        return looseCache[wp.id]
    end
    local function outward(wp, dir, want)
        local prev, cur, run = nil, wp, 0
        for _ = 1, 30 do
            local lst = cur.incoming or {}
            if dir == "out" then lst = cur.out or {} end
            local nxt, best = nil, -math.huge
            for _, id in pairs(lst) do
                local t = ADGraphManager:getWayPointById(id)
                if t ~= nil and t ~= prev then
                    local d = (t.x - cx) ^ 2 + (t.z - cz) ^ 2
                    if d > best then best, nxt = d, t end
                end
            end
            if nxt == nil then break end
            run = run + math.sqrt((nxt.x - cur.x) ^ 2 + (nxt.z - cur.z) ^ 2)
            prev, cur = cur, nxt
            if run >= want then break end
        end
        return cur
    end
    local approaches = {}
    for _, ap in ipairs(raw) do
        local into = nil
        for _, g in ipairs(approaches) do
            if g.dir == ap.dir and junctionAngDiff(g.bearing, ap.bearing) < math.rad(35)
                and (g.wp.x - ap.wp.x) ^ 2 + (g.wp.z - ap.wp.z) ^ 2 < 36 then
                local fa, fb = outward(g.wp, ap.dir, 5), outward(ap.wp, ap.dir, 5)
                if (fa.x - fb.x) ^ 2 + (fa.z - fb.z) ^ 2 <= 5 * 5 then into = g break end
            end
        end
        if into ~= nil then
            into.count = into.count + 1
            if onLoosePiece(into.wp) and not onLoosePiece(ap.wp) then
                into.wp, into.bearing = ap.wp, ap.bearing
            elseif onLoosePiece(into.wp) == onLoosePiece(ap.wp) then
                -- The lane that runs on away from the junction speaks for the pair, as in build
                -- (updateJunctionPreview, at 39): the one ending farther out 20 m along, a dead heat
                -- to the more westerly, then the more northerly.
                local fi, fa = outward(into.wp, ap.dir, 20), outward(ap.wp, ap.dir, 20)
                local di = (fi.x - cx) ^ 2 + (fi.z - cz) ^ 2
                local da = (fa.x - cx) ^ 2 + (fa.z - cz) ^ 2
                if da > di + 1e-6 or (math.abs(da - di) <= 1e-6
                    and (ap.wp.x < into.wp.x or (ap.wp.x == into.wp.x and ap.wp.z < into.wp.z))) then
                    into.wp, into.bearing = ap.wp, ap.bearing
                end
            end
        else
            approaches[#approaches + 1] = { wp = ap.wp, dir = ap.dir, bearing = ap.bearing, count = 1 }
        end
    end
    return { approaches = approaches, tracksCentre = { x = cx, z = cz }, pathRoutes = { through = {}, side = {} },
        cx = cx, cz = cz }
end

--- WHERE THE ROADS MEET: ONE PLACE, OR SEVERAL. A site the selection locks as one junction can be
--- two junctions sharing a main road: 72 (by the registry) is a T square with a one-way Y merge
--- peeling off 11 m further on ("t square with y merge after"), 73 a Y merge followed by a T skew,
--- and the classifier gives each one kind for the lot. This reads the site again, road by road:
--- every side lane gets the point where it meets the main road's line, lanes that run side by side
--- are one side road, and side roads that meet the main road in the same place are one part.
---
--- It only SUGGESTS. Nothing is split, saved or cleared differently because of it; the card says
--- what it found and the user decides (split_decisions.txt in the harness holds the answers so far).
---
--- Reads the records junctionClassify left on jp, so it must run after it. Returns a table
--- { parts = { { x, z, along, kind, letter, roads } ... }, spread = metres } with the parts in map
--- order (west to east, or north to south; letter as jxPartLetters sets it, nil for no name), or nil
--- and why the site is not read for parts.
function ADFlyoverEditor:junctionParts(jp)
    if jp == nil then return nil, "no site" end
    local c = jp._boxCentre or jp.boxCentre or jp.tracksCentre
    if c == nil then return nil, "no centre" end
    local kind = tostring(jp.junctionType or "?")
    -- Two side lanes within SAME_ROAD_DEG of each other and SAME_ROAD_GAP metres apart across are
    -- one side road; side roads meeting the main road within SAME_SPOT of each other are one part
    -- (a crossroads), and so are side roads on opposite sides within STAGGER that someone can drive
    -- straight across (a staggered crossroads). Straight across = a lane in on one side lines up
    -- within STRAIGHT_DEG with a lane out on the other. Set from about ten junctions on the survey
    -- map: 36's Y has two lanes meeting the main road 13 m apart, and is still one road at 8 m across.
    -- Side roads on opposite sides within CROSS_SPOT are one crossroads whether or not they line
    -- up - the reach the classifier itself calls a crossroads rather than a "4W offset". 71 (by the
    -- registry, cleared; the user keeps it whole) has a single lane joining from the south at 40
    -- degrees and a road from the north-east at 71, 7 m apart along the main road: nothing drives
    -- straight over, and the straight-over test alone split it in two.
    local SAME_ROAD_DEG, SAME_ROAD_GAP, SAME_SPOT, STAGGER, STRAIGHT_DEG = 30, 8, 6, 15, 45
    local CROSS_SPOT = 10
    -- A ONE-WAY side road leaving or joining at up to ONE_WAY_Y degrees is a Y merge, not a T skew:
    -- 72's one-way lane peels off at 44 degrees, and the user has it as the Y merge after the T.
    -- The two-way T skews between 38 and 50 degrees (7, 41, 50, 52, 66) are not one-way and keep
    -- their kind; on the survey map this changes 72's Y part and nothing else.
    local ONE_WAY_Y = 50
    local function sep(a, b)
        local d = math.abs(a - b) % 360
        if d > 180 then d = 360 - d end
        return d
    end
    local function lineSep(a, b)
        local d = sep(a, b)
        return math.min(d, 180 - d)
    end
    local function unit(deg) return math.sin(math.rad(deg)), math.cos(math.rad(deg)) end
    local function brg(dx, dz) return math.deg(math.atan2(dx, dz)) % 360 end
    -- where the line P + t*u crosses Q + s*v; nil when they (nearly) run parallel
    local function meet(px, pz, ux, uz, qx, qz, vx, vz)
        local den = ux * vz - uz * vx
        if math.abs(den) < 0.05 then return nil end
        local t = ((qx - px) * vz - (qz - pz) * vx) / den
        return px + ux * t, pz + uz * t
    end

    local ax, az, ox, oz   -- the main road's line: direction and a point on it
    local lanes = {}       -- side lanes: meeting point x, z; line heading deg; angle to the main road
    local groups, pair, mainLanes = jp._clearedGroups, jp._clearedPair, jp._clearedLanes
    if jp._mainCleared and groups ~= nil and pair ~= nil then
        -- CLEARED: nothing joins the lanes, so each lane is read from its own end, and so is the main
        -- road. Its line is the one the classifier chose the main road by: an in-lane on one arm and
        -- an out-lane on the other that line up straight across the gap, read along those two
        -- lanes' own headings. NOT from where the two main groups sit seen from the site's middle:
        -- the middle sits off the main road, towards the side road, so that line leans - 14 degrees
        -- at 8 once cleared (a road running 74/254 was measured along 60/240) - and the main road's
        -- own lanes then read as a side road 12 to 14 degrees off it, a "Y merge" part beside a
        -- plain T at 8, 27 and 37. The turn is read from the same two lanes, for the same reason:
        -- from the groups' places, roads whose lanes turn under 30 degrees "turned" 30 to 57 (5, 13,
        -- 14, 19, 23, 25 and 34, once cleared) and were never read.
        local e, x = nil, nil
        if mainLanes ~= nil then e, x = mainLanes[1], mainLanes[2] end
        if e == nil or x == nil or e.bearing == nil or x.bearing == nil
            or (e.selWp or e.wp) == nil or (x.selWp or x.wp) == nil then
            return nil, "no main lanes (" .. kind .. ")"
        end
        local turn = math.deg(junctionAngDiff(e.bearing, x.bearing))
        if turn > 30 then
            return nil, string.format("main road turns %.0f deg (%s)", turn, kind)
        end
        -- e arrives along the road and x leaves along it, so their headings add up to its line
        ax, az = math.sin(e.bearing) + math.sin(x.bearing), math.cos(e.bearing) + math.cos(x.bearing)
        local l = math.sqrt(ax * ax + az * az)
        ax, az = ax / l, az / l
        local axisDeg = brg(ax, az)
        -- A LANE IS MAIN OR SIDE BY ITS OWN LINE, not by which place group it fell in: a main lane
        -- runs along one of the two lanes the road was chosen by (within MAIN_DEG - the classifier's
        -- own "clearly off the main road's line") and beside it (within MAIN_ACROSS: the lane back
        -- the other way, 4 to 5 m over). A Y branch sits beside its parent road and falls in that
        -- road's group, but leaves at its own angle (73's, 35 degrees); a main lane trimmed shorter
        -- than its twin can land in a group of its own (27's east-bound lane) or in no main group
        -- at all (37's south-bound one), and is main all the same. A list and a flag, not a set
        -- keyed by the approach tables: summing positions in pairs() order would follow memory
        -- addresses.
        local MAIN_DEG, MAIN_ACROSS = 12, 7
        local function alongLane(ap, lane)
            local lw, w = lane.selWp or lane.wp, ap.selWp or ap.wp
            if lineSep(math.deg(ap.bearing) % 360, math.deg(lane.bearing) % 360) > MAIN_DEG then return false end
            local hx, hz = math.sin(lane.bearing), math.cos(lane.bearing)
            return math.abs((w.x - lw.x) * hz - (w.z - lw.z) * hx) <= MAIN_ACROSS
        end
        local isMain, mains = {}, {}
        for _, ap in ipairs(jp.approaches or {}) do
            local w = ap.selWp or ap.wp
            if w ~= nil and ap.bearing ~= nil and (ap == e or ap == x or alongLane(ap, e) or alongLane(ap, x)) then
                isMain[ap] = true
                mains[#mains + 1] = w
            end
        end
        -- The main road's middle line: halfway between its outermost lanes, measured across from
        -- the two lanes it was chosen by (both of them one lane, the same way) - not the average of
        -- the lanes, which a lane trimmed into two pieces would pull towards its side.
        local px, pz = ((e.selWp or e.wp).x + (x.selWp or x.wp).x) / 2, ((e.selWp or e.wp).z + (x.selWp or x.wp).z) / 2
        local lo, hi = math.huge, -math.huge
        for _, w in ipairs(mains) do
            local s = (w.x - px) * az - (w.z - pz) * ax
            lo, hi = math.min(lo, s), math.max(hi, s)
        end
        local mid = (lo + hi) / 2
        ox, oz = px + az * mid, pz - ax * mid
        local function onMain(w)
            return math.abs((w.x - ox) * az - (w.z - oz) * ax) <= 3
        end
        -- Walk a side lane from its end at the circle towards the junction: to where it ends, or
        -- comes within 3 m of the main line, whichever is first. Returns that tip and a node back out
        -- along the lane, for the lane's own line: a lane that runs on into the main road is curving
        -- there, so it is read 4 to 14 m back from the tip; a lane that simply ends, over its last
        -- 10 m.
        -- EACH STEP GOES THE WAY IT MEANS TO GO, told by distance from the site's middle (the way
        -- junctionVirginReading's outward() picks), not by which list the next node is in. A
        -- two-way lane lists both its neighbours as both "out" and "incoming", and the one listed
        -- first is as often the one further out: taken as listed, the walk "in" from 74's side road
        -- (a single two-way lane) set off up that road instead, read its line 99 m out, and the
        -- lane was dropped as meeting the main road 51 m away - 74 read "no side lanes", and so
        -- did 4, 65 and 66 once cleared (their lane tips 126 to 276 m out). At 71 the 10 m back out
        -- ran inward instead and came to 3.9 m of lane.
        local function laneTip(ap)
            local anchor = ap.selWp or ap.wp
            local inward, outward = "incoming", "out"
            if ap.dir == "in" then inward, outward = "out", "incoming" end
            -- the neighbour in `key` nearest the middle (towards) or furthest from it; on a tie the
            -- first listed, so the walk does not depend on anything but the lists themselves
            local function step(node, key, cameFrom, towards)
                local best, bd = nil, nil
                for _, id in ipairs(node[key] or {}) do
                    if id ~= cameFrom then
                        local t = ADGraphManager:getWayPointById(id)
                        if t ~= nil then
                            local d = (t.x - c.x) ^ 2 + (t.z - c.z) ^ 2
                            if bd == nil or (towards and d < bd) or (not towards and d > bd) then
                                best, bd = t, d
                            end
                        end
                    end
                end
                return best
            end
            -- outward first (up to 10 m), so a lane that ends right at the anchor still has a line
            local seq, node, prev, run = { anchor }, anchor, nil, 0
            while run < 10 do
                local cameFrom = nil
                if prev ~= nil then cameFrom = prev.id end
                local nxt = step(node, outward, cameFrom, false)
                if nxt == nil then break end
                run = run + math.sqrt((nxt.x - node.x) ^ 2 + (nxt.z - node.z) ^ 2)
                table.insert(seq, 1, nxt)
                prev, node = node, nxt
            end
            node, prev = anchor, nil
            for _ = 1, 60 do
                if onMain(node) then break end
                local cameFrom = nil
                if prev ~= nil then cameFrom = prev.id end
                local nxt = step(node, inward, cameFrom, true)
                if nxt == nil then break end
                prev, node = node, nxt
                seq[#seq + 1] = node
            end
            local tip = seq[#seq]
            local reached = onMain(tip)
            local near, back, r = tip, tip, 0
            local reach = 10
            if reached then reach = 14 end
            for i = #seq - 1, 1, -1 do
                r = r + math.sqrt((seq[i + 1].x - seq[i].x) ^ 2 + (seq[i + 1].z - seq[i].z) ^ 2)
                if reached and r < 4 then near = seq[i] end
                back = seq[i]
                if r >= reach then break end
            end
            return near, back
        end
        for _, ap in ipairs(jp.approaches or {}) do
            if not isMain[ap] and (ap.selWp or ap.wp) ~= nil then
                local tip, back = laneTip(ap)
                local ux, uz = tip.x - back.x, tip.z - back.z
                local ul = math.sqrt(ux * ux + uz * uz)
                if ul > 0.5 then
                    ux, uz = ux / ul, uz / ul
                    local mx, mz = meet(tip.x, tip.z, ux, uz, ox, oz, ax, az)
                    if mx ~= nil and (mx - c.x) ^ 2 + (mz - c.z) ^ 2 <= 25 * 25 then
                        lanes[#lanes + 1] = { x = mx, z = mz, deg = brg(ux, uz), far = back, ref = back,
                            flow = ap.dir, angle = lineSep(brg(ux, uz), axisDeg) }
                    end
                end
            end
        end
    else
        local T = jp._mainArms or {}
        if #T ~= 2 then return nil, string.format("%d main arms (%s)", #T, kind) end
        -- A MAIN ROAD THAT TURNS is never read for parts: the corner T's (24, 31) turn 52 and 75
        -- degrees inside the site, and a line along a bend is no line to measure along.
        if sep(T[1], T[2]) < 150 then
            return nil, string.format("main road turns %.0f deg (%s)", 180 - sep(T[1], T[2]), kind)
        end
        local ix, iz = unit(T[1])
        local jx, jz = unit(T[2])
        ax, az = ix - jx, iz - jz
        local l = math.sqrt(ax * ax + az * az)
        ax, az = ax / l, az / l
        ox, oz = c.x, c.z
        -- how far a point lies from a lane (its polyline)
        local function offLane(nodes, px, pz)
            local best = math.huge
            for k = 2, #nodes do
                local qx, qz = nodes[k - 1].x, nodes[k - 1].z
                local vx, vz = nodes[k].x - qx, nodes[k].z - qz
                local L2 = vx * vx + vz * vz
                local u = 0
                if L2 > 0 then u = math.max(0, math.min(1, ((px - qx) * vx + (pz - qz) * vz) / L2)) end
                best = math.min(best, math.sqrt((qx + u * vx - px) ^ 2 + (qz + u * vz - pz) ^ 2))
            end
            return best
        end
        for _, s in ipairs(jp._sideRead or {}) do
            local g = s.meet
            -- A MEETING POINT FAR FROM THE LANE ITSELF IS NOT WHERE THE LANE MEETS THE ROAD. The
            -- classifier reads a side road's line from the first fork out along it, and at 67 that
            -- fork is the loop road's: the in-lane joins the main road at x = -739, but its line was
            -- read along the loop road and met the main road 32 m from any point of the lane, on
            -- empty ground - a second "junction" there, 67e, a Y merge that is not. Over every side
            -- lane on the survey map a meeting point lies at most 14 m from its lane (3, a shallow
            -- one); a lane whose meeting point lies more than 20 m from it - the reach the
            -- classifier calls "at this junction" - is left out of the parts, as one meeting the
            -- main road elsewhere is. Not read from its nearest point instead: at 40e the NE road's
            -- out-lane (its line read at the next junction's fork, 41 m off) then came back as a
            -- road of its own 7 m from its twin lane, and split a plain T in two.
            local elsewhere = g ~= nil and s.route ~= nil and s.route.nodes ~= nil and #s.route.nodes >= 2
                and offLane(s.route.nodes, g.x, g.z) > 20
            local mx, mz, deg, angle
            if g ~= nil then
                mx, mz, deg = g.x, g.z, g.side
                angle = lineSep(g.side, g.main)
            else
                -- no measured meeting: the side lane's nearest point, dropped onto the main line
                local t = (s.pt.x - ox) * ax + (s.pt.z - oz) * az
                mx, mz = ox + ax * t, oz + az * t
                deg = brg(s.far.x - s.pt.x, s.far.z - s.pt.z)
                angle = lineSep(deg, brg(ax, az))
            end
            -- only a side road meeting the main road AT this junction (the classifier's own 20 m)
            if not elsewhere and (mx - c.x) ^ 2 + (mz - c.z) ^ 2 <= 20 * 20 then
                local ref = s.far
                if g ~= nil then ref = { x = g.toX, z = g.toZ } end
                lanes[#lanes + 1] = { x = mx, z = mz, deg = deg, far = s.far, ref = ref, flow = s.flow, angle = angle }
            end
        end
    end
    if #lanes == 0 then return nil, "no side lanes (" .. kind .. ")" end

    for _, ln in ipairs(lanes) do
        ln.along = (ln.x - ox) * ax + (ln.z - oz) * az
        local cr = ax * (ln.far.z - ln.z) - az * (ln.far.x - ln.x)
        if cr >= 0 then ln.side = "L" else ln.side = "R" end
    end
    local function byAlong(a, b)
        if a.along ~= b.along then return a.along < b.along end
        if a.x ~= b.x then return a.x < b.x end
        return a.z < b.z
    end
    table.sort(lanes, byAlong)

    -- LANES INTO SIDE ROADS: same side, near the same heading, and side by side - how far apart
    -- measured ACROSS the lanes, not along the main road (a shallow Y's two lanes meet the main road
    -- 10 m and more apart: 36's are 13 m apart and one road).
    local function off(a, b)   -- how far a's reference point lies from b's line
        local ux, uz = unit(b.deg)
        return math.abs((a.ref.x - b.x) * uz - (a.ref.z - b.z) * ux)
    end
    local roads = {}
    for _, ln in ipairs(lanes) do
        local hit = nil
        for _, r in ipairs(roads) do
            if r.side == ln.side and lineSep(r.deg, ln.deg) <= SAME_ROAD_DEG then
                for _, q in ipairs(r.lanes) do
                    if math.min(off(ln, q), off(q, ln)) <= SAME_ROAD_GAP then hit = r break end
                end
                if hit ~= nil then break end
            end
        end
        if hit == nil then
            hit = { side = ln.side, deg = ln.deg, lanes = {}, hasIn = false, hasOut = false }
            roads[#roads + 1] = hit
        end
        hit.lanes[#hit.lanes + 1] = ln
        if ln.flow == "in" then hit.hasIn = true else hit.hasOut = true end
        local sa, sx, sz, sang = 0, 0, 0, 0
        for _, q in ipairs(hit.lanes) do sa, sx, sz, sang = sa + q.along, sx + q.x, sz + q.z, sang + q.angle end
        local n = #hit.lanes
        hit.along, hit.x, hit.z, hit.angle = sa / n, sx / n, sz / n, sang / n
    end
    table.sort(roads, byAlong)

    -- straight across: a lane in on one road lines up with a lane out on the other
    local function straightOver(r1, r2)
        for _, a in ipairs(r1.lanes) do
            for _, b in ipairs(r2.lanes) do
                if a.flow ~= b.flow and lineSep(a.deg, b.deg) <= STRAIGHT_DEG then return true end
            end
        end
        return false
    end
    -- SIDE ROADS INTO PARTS, in order along the main road: a road joins the part before it when it
    -- meets the main road in the same place, or across the road from it - close by (CROSS_SPOT), or
    -- close enough, and lined up enough, to drive straight over.
    local parts = {}
    for _, r in ipairs(roads) do
        local p = parts[#parts]
        local join = false
        if p ~= nil then
            for _, q in ipairs(p.roads) do
                local d = math.abs(q.along - r.along)
                if d <= SAME_SPOT then join = true break end
                if q.side ~= r.side and d <= CROSS_SPOT then join = true break end
                if q.side ~= r.side and d <= STAGGER and straightOver(q, r) then join = true break end
            end
        end
        if join then
            p.roads[#p.roads + 1] = r
        else
            parts[#parts + 1] = { roads = { r } }
        end
    end
    -- ONE-WAY MEANS NO LANE RUNS THE OTHER WAY, not that only one lane was read. The classifier can
    -- follow one direction of a two-way side road and not the other (37's east road is read by its
    -- out-lane alone, though both its lanes cross the circle), so a road read with one flow is taken
    -- as one-way only when no approach runs the other way beside it: the opposite direction, within
    -- SAME_ROAD_DEG of the road's line, within SAME_ROAD_GAP across it, and on its side of the main
    -- road. 72's Y lane has none; nothing else on the survey map is read with one flow at 38-50
    -- degrees, where this decides the kind.
    local function laneBackBeside(r)
        local want = "in"
        if r.hasIn then want = "out" end
        for _, ap in ipairs(jp.approaches or {}) do
            local w = ap.selWp or ap.wp
            if w ~= nil and ap.dir == want and ap.bearing ~= nil then
                local h = math.deg(ap.bearing) % 360
                for _, ln in ipairs(r.lanes) do
                    local ux, uz = unit(ln.deg)
                    local across = math.abs((w.x - ln.x) * uz - (w.z - ln.z) * ux)
                    local onL = (ax * (w.z - ln.z) - az * (w.x - ln.x)) >= 0
                    if lineSep(h, ln.deg) <= SAME_ROAD_DEG and across <= SAME_ROAD_GAP and onL == (r.side == "L") then
                        return true
                    end
                end
            end
        end
        return false
    end
    for _, r in ipairs(roads) do
        r.oneWay = (r.hasIn ~= r.hasOut) and not laneBackBeside(r)
    end
    local function kindOfRoad(r)
        if r.oneWay and r.angle <= ONE_WAY_Y then return "Y merge" end
        if r.angle <= 38 then return "Y merge" end
        if r.angle <= 62 then return "T skew" end
        return "T square"
    end
    for _, p in ipairs(parts) do
        local sa, sx, sz, hasL, hasR = 0, 0, 0, false, false
        for _, r in ipairs(p.roads) do
            sa, sx, sz = sa + r.along, sx + r.x, sz + r.z
            if r.side == "L" then hasL = true else hasR = true end
        end
        p.along, p.x, p.z = sa / #p.roads, sx / #p.roads, sz / #p.roads
        if #p.roads == 1 then
            p.kind = kindOfRoad(p.roads[1])
        elseif hasL and hasR then
            local lo, hi = math.huge, -math.huge
            for _, r in ipairs(p.roads) do lo, hi = math.min(lo, r.along), math.max(hi, r.along) end
            -- offset past the classifier's own crossroads reach, as it says it
            if hi - lo > CROSS_SPOT then
                p.kind = string.format("4W offset (%.0f m)", hi - lo)
            else
                p.kind = "4W"
            end
        else
            p.kind = string.format("%d side roads, one side", #p.roads)
        end
    end

    -- IN MAP ORDER, AND NAMED THE USER'S WAY (jxPartLetters). The first part is the western one
    -- where the parts lie more east-west, the northern one where they lie more north-south.
    local first, last = parts[1], parts[#parts]
    local flip
    if math.abs(last.x - first.x) >= math.abs(last.z - first.z) then
        flip = last.x < first.x
    else
        flip = last.z < first.z
    end
    if flip then
        local rev = {}
        for i = #parts, 1, -1 do rev[#rev + 1] = parts[i] end
        parts = rev
    end
    local spread = 0
    for i = 1, #parts do
        for j = i + 1, #parts do
            spread = math.max(spread, math.sqrt((parts[i].x - parts[j].x) ^ 2 + (parts[i].z - parts[j].z) ^ 2))
        end
    end
    jxPartLetters(parts)
    return { parts = parts, roads = roads, spread = spread }
end

--- The road-meeting points (junctionCentres) that junction n would be shown for: those whose nearest
--- numbered junction within 30 m - the reach junctionNumberAt names a junction by - is n. Two or more
--- means the one number is standing for junctions the roads themselves say are separate: 20 (by the
--- registry) is two T squares 14 m apart on the same side of the road, and both halves show as j20
--- ("20n isn't being detected"); 14, 26, 39 and 40 are the others on the survey map. `reg` is the
--- list of numbered junctions to test against (the registry by default; the harness passes the file's).
--- In junctionCentres' own order.
function ADFlyoverEditor:junctionMeetingPointsOf(n, reg)
    local out = {}
    if n == nil then return out end
    reg = reg or self:junctionRegistry() or {}
    local all = self:junctionCentres() or {}
    -- A ROAD'S OWN BEND IS NOT A PLACE ROADS MEET. A meeting point is where the tangents of two
    -- fork-to-fork runs cross, and a road that curves between two junctions makes one too: at 40 the
    -- north-east road's two lanes bend 54 and 39 degrees between 40e and the next junction up the
    -- road, and their tangents cross on the road itself, 25 m from 40e - "c is not a junction" (the
    -- user). What gives it away is that it has no forks of its own: every fork its runs join is
    -- another meeting point's (40e's at one end, the next junction's at the other), where every
    -- real one on the survey map has forks that are its alone (20's two halves, 14 m apart, share
    -- two of their six). Only a meeting point whose forks all belong to meeting points that do have
    -- forks of their own is set aside, so two that share everything with each other both stay.
    -- Counted, never walked in order, so the sets keyed by waypoint tables cannot reorder anything.
    local users = {}
    for _, c in ipairs(all) do
        for w in pairs(c.forks or {}) do users[w] = (users[w] or 0) + 1 end
    end
    local function ownForks(c)
        local k = 0
        for w in pairs(c.forks or {}) do
            if users[w] == 1 then k = k + 1 end
        end
        return k
    end
    local function onlyABend(c)
        if ownForks(c) > 0 then return false end
        for _, d in ipairs(all) do
            if d ~= c and ownForks(d) == 0 then
                for w in pairs(c.forks or {}) do
                    if d.forks ~= nil and d.forks[w] then return false end
                end
            end
        end
        return true
    end
    for _, c in ipairs(all) do
        local best, bd = nil, 30 * 30
        for _, f in ipairs(reg) do
            local d = (f.x - c.x) ^ 2 + (f.z - c.z) ^ 2
            if d < bd then bd, best = d, f end
        end
        if best ~= nil and best.n == n and not onlyABend(c) then out[#out + 1] = c end
    end
    return out
end

--- The card's lines when a site may be more than one junction, or nil. Two findings, each only a
--- suggestion - nothing is split unless the user decides to: the part reader found the roads meeting
--- in more than one place ("may be 2 junctions, 10 m apart:" then "j72w T square + j72e Y merge"),
--- or the number stands for more than one place the roads meet ("may be 2 junctions; this one is
--- j20s" then "j20n is 14 m N"). Parts are named the user's way (jxPartLetters); where there is no
--- name, only the kind or the distance is given. n is the site's number and x, z where the selection
--- locked it; reg as for junctionMeetingPointsOf.
function ADFlyoverEditor:junctionPartsNote(jp, n, x, z, reg)
    if jp == nil then return nil end
    local lines = {}
    -- written the way the card's junction row writes the number (j20), the part's letters after
    -- it: a bare "20s" under "j20" read like "the twenties"
    local function nameOf(p)
        if n == nil or p.letter == nil then return nil end
        return string.format("j%02d%s", n, p.letter)
    end
    local r = jp.junctionParts
    if r ~= nil and r.parts ~= nil and #r.parts >= 2 then
        lines[#lines + 1] = string.format("may be %d junctions, %.0f m apart:", #r.parts, r.spread)
        local bits = {}
        for _, p in ipairs(r.parts) do
            local nm = nameOf(p)
            if nm ~= nil then
                bits[#bits + 1] = nm .. " " .. p.kind
            else
                bits[#bits + 1] = p.kind
            end
        end
        lines[#lines + 1] = table.concat(bits, " + ")
    end
    if n ~= nil then
        local mine = self:junctionMeetingPointsOf(n, reg)
        if #mine >= 2 then
            local pts = {}
            for _, m in ipairs(mine) do pts[#pts + 1] = { x = m.x, z = m.z } end
            jxPartLetters(pts)
            -- Measured from the meeting point this site IS: the nearest one within 10 m of where the
            -- selection locked it (which is a meeting point itself, when the roads found it). Not
            -- from the box's middle: at 26 that sits 7 m from the locked half, nearer its twin, and
            -- the note named the wrong half as this one.
            local c = { x = x, z = z }
            if x == nil or z == nil then c = jp._boxCentre or jp.boxCentre or jp.tracksCentre or { x = jp.cx, z = jp.cz } end
            local here, hd = nil, 10 * 10
            for _, p in ipairs(pts) do
                local d = (p.x - c.x) ^ 2 + (p.z - c.z) ^ 2
                if d < hd then hd, here = d, p end
            end
            local from = here or c
            -- the others NEAREST FIRST (then west to east, north to south: a fixed order on a tie)
            local others = {}
            for _, p in ipairs(pts) do
                if p ~= here then
                    p.d = math.sqrt((p.x - from.x) ^ 2 + (p.z - from.z) ^ 2)
                    others[#others + 1] = p
                end
            end
            table.sort(others, function(a, b)
                if a.d ~= b.d then return a.d < b.d end
                if a.x ~= b.x then return a.x < b.x end
                return a.z < b.z
            end)
            local hereName = nil
            if here ~= nil then hereName = nameOf(here) end
            if hereName ~= nil then
                lines[#lines + 1] = string.format("may be %d junctions; this one is %s", #pts, hereName)
            else
                lines[#lines + 1] = string.format("may be %d junctions", #pts)
            end
            local bits = {}
            for i, p in ipairs(others) do
                local where = string.format("%.0f m %s", p.d, string.upper(jxCompass(p.x - from.x, p.z - from.z)))
                local nm = nameOf(p)
                if nm ~= nil and i == 1 then
                    bits[#bits + 1] = nm .. " is " .. where
                elseif nm ~= nil then
                    bits[#bits + 1] = nm .. " " .. where
                elseif i == 1 and #others == 1 then
                    bits[#bits + 1] = "another is " .. where
                elseif i == 1 then
                    bits[#bits + 1] = "others are " .. where
                else
                    bits[#bits + 1] = where
                end
            end
            lines[#lines + 1] = table.concat(bits, ", ")
        end
    end
    if #lines == 0 then return nil end
    return lines
end

--- THE PARTS THE CARD WOULD SPLIT JUNCTION n INTO, if the user chooses to: { parts = { { letter, x,
--- z } ... }, names = { "j39nw", "j39", "j39se" } }, or nil and why not. The places the roads meet
--- that the number stands for when there are two or more (a wired site: 14, 20, 26, 39, 40, with
--- 40's bend already set aside), otherwise the part reader's parts (a cleared site: 72, 73) - on the
--- survey map these give exactly the names the user chose. Each part is saved where the roads meet,
--- which is also where a lock on that part lands, so the name can be found again from the lock.
--- Every part needs a name: four or more parts, or two the same letter, have none, and a split
--- with an unnamed part could never be told apart from its neighbour.
function ADFlyoverEditor:junctionSplitOffer(jp, n)
    if jp == nil or n == nil then return nil end
    local pts = {}
    local mine = self:junctionMeetingPointsOf(n)
    if #mine >= 2 then
        for _, m in ipairs(mine) do pts[#pts + 1] = { x = m.x, z = m.z } end
        jxPartLetters(pts)
    else
        local r = jp.junctionParts
        if r ~= nil and r.parts ~= nil and #r.parts >= 2 then
            for _, p in ipairs(r.parts) do pts[#pts + 1] = { x = p.x, z = p.z, letter = p.letter } end
        end
    end
    if #pts < 2 then return nil end
    for _, p in ipairs(pts) do
        if p.letter == nil then return nil, "these parts have no names yet - can't split here" end
    end
    jxSortParts(pts)
    return { parts = pts, names = jxPartNames(n, pts) }
end

-- MODSPLIT: SHARED WITH THE FILES LOADED AFTER THIS ONE (tools/modsplit/split.py writes this block)
ADFlyoverEditor.shared.jxPartLetters = jxPartLetters
-- MODSPLIT: end of the shared block

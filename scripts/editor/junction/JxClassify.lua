-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua
-- loads it after FlyoverEditor.lua, in the old file's order.
-- MODSPLIT: HELPERS FROM THE FILES LOADED BEFORE THIS ONE (tools/modsplit/split.py writes this block)
for _, name in ipairs({ "junctionAngDiff" }) do
    if ADFlyoverEditor.shared == nil or ADFlyoverEditor.shared[name] == nil then
        Logging.error("[FlyoverEditor]: JxClassify.lua needs %s, which no file loaded before it shares", name)
    end
end
local junctionAngDiff = ADFlyoverEditor.shared.junctionAngDiff
-- MODSPLIT: end of the helpers

--- THE SHAPE OF THE WIRED TURNS, a second say on Y merge or T. A Y merge's turns join the main road
--- almost in line, long and gentle, where a T's turns bend hard - the user's call on 50 (2026-10-05:
--- "clearly a y merge", shown by the shape of its connectors). A turn is measured the way a driver
--- makes it: from the lane's own direction arriving where the connector leaves to the lane's
--- direction past where it joins, the corners at both ends included (67's connectors leave the main
--- lane at a right angle and then run straight: 4 degrees of bend inside them, over 100 in all). Over
--- the 51 junctions the user labelled, the gentlest such turn is 25 degrees or less at every Y merge
--- and 42 or more at every T. It does not tell a T skew from a T square (they overlap from 53 to 65
--- degrees), so the angle keeps that call.
--- Only turns linking two different roads count: a piece that leaves a road and rejoins the same road
--- (40's duplicate beside its eastbound lane, 4 degrees) says nothing about how the two roads meet.
--- Which road an end is on: walk out along its own lane until 12 m from the centre, the way the
--- classifier reads an arm, and take the nearest arm there - at a tight Y the side road runs within
--- 20 degrees of the main road, and a fixed tolerance around the main arms swallowed it (53).
--- Reads what junctionClassify left on jp (_branchCentre, _mainArms, _sideRead), so it runs from
--- there. Returns the gentlest such turn in degrees, or nil when there is no wiring to read (a
--- cleared junction).
function ADFlyoverEditor:junctionGentlestTurn(jp)
    local c = jp._branchCentre
    if c == nil or jp.turnDebris == nil or #jp.turnDebris == 0 then return nil end
    local function wp(id) return ADGraphManager:getWayPointById(id) end
    local wire = {}
    for _, w in ipairs(jp.turnDebris) do
        if w.id ~= nil then wire[w.id] = true end
    end
    local function sep(a, b)
        local d = math.abs(a - b) % 360
        if d > 180 then d = 360 - d end
        return d
    end
    local function sortedIds(list)
        local r = {}
        for _, id in ipairs(list or {}) do r[#r + 1] = id end
        table.sort(r)
        return r
    end
    local arms = {}
    for _, m in ipairs(jp._mainArms or {}) do arms[#arms + 1] = { b = m, main = true } end
    local sideKeys = {}
    for k in pairs(jp._sideRead or {}) do sideKeys[#sideKeys + 1] = k end
    table.sort(sideKeys)
    for _, k in ipairs(sideKeys) do
        local s = jp._sideRead[k]
        if s.bearing ~= nil then arms[#arms + 1] = { b = s.bearing, main = false } end
    end
    if #arms == 0 then return nil end
    local function onMain(p, upstream)
        local cur, seen = p, { [p.id] = true }
        for _ = 1, 60 do
            if (cur.x - c.x) ^ 2 + (cur.z - c.z) ^ 2 >= 12 * 12 then break end
            local nxt = nil
            for _, id in ipairs(sortedIds(upstream and cur.incoming or cur.out)) do
                if not wire[id] and not seen[id] then
                    nxt = wp(id)
                    if nxt ~= nil then break end
                end
            end
            if nxt == nil then break end
            seen[nxt.id] = true
            cur = nxt
        end
        local b = math.deg(math.atan2(cur.x - c.x, cur.z - c.z)) % 360
        local best, isMain = math.huge, true
        for _, a in ipairs(arms) do
            local d = sep(b, a.b)
            if d < best then best, isMain = d, a.main end
        end
        return isMain
    end
    local function heading(a, b) return math.atan2(b.x - a.x, b.z - a.z) end
    local function wrap(d)
        while d > math.pi do d = d - 2 * math.pi end
        while d < -math.pi do d = d + 2 * math.pi end
        return d
    end
    -- each connector as a chain: from the lane point that feeds it, through the wiring, to the lane
    -- point it joins
    local wireIds = {}
    for id in pairs(wire) do wireIds[#wireIds + 1] = id end
    table.sort(wireIds)
    local gentlest = nil
    for _, first in ipairs(wireIds) do
        local fw = wp(first)
        for _, from in ipairs(fw ~= nil and sortedIds(fw.incoming) or {}) do
            local start = (not wire[from]) and wp(from) or nil
            if start ~= nil then
                local path, seen, cur, ended = { start, fw }, { [first] = true }, fw, false
                for _ = 1, 200 do
                    local outs, nxt = sortedIds(cur.out), nil
                    for _, oid in ipairs(outs) do
                        if wire[oid] and not seen[oid] then nxt = oid break end
                    end
                    if nxt == nil then
                        for _, oid in ipairs(outs) do
                            local w = (not wire[oid]) and wp(oid) or nil
                            if w ~= nil then path[#path + 1] = w ended = true break end
                        end
                        break
                    end
                    seen[nxt] = true
                    cur = wp(nxt)
                    if cur == nil then break end
                    path[#path + 1] = cur
                end
                if ended and #path >= 3 and onMain(path[1], true) ~= onMain(path[#path], false) then
                    -- the lane's own points either side, for the corners at both ends
                    local function laneStep(w, upstream)
                        for _, id in ipairs(sortedIds(upstream and w.incoming or w.out)) do
                            if not wire[id] then
                                local n = wp(id)
                                if n ~= nil then return n end
                            end
                        end
                        return nil
                    end
                    local ext = {}
                    local before, after = laneStep(path[1], true), laneStep(path[#path], false)
                    if before ~= nil then ext[#ext + 1] = before end
                    for _, w in ipairs(path) do ext[#ext + 1] = w end
                    if after ~= nil then ext[#ext + 1] = after end
                    local turn = 0
                    for i = 2, #ext - 1 do
                        turn = turn + wrap(heading(ext[i], ext[i + 1]) - heading(ext[i - 1], ext[i]))
                    end
                    local deg = math.abs(math.deg(turn))
                    if gentlest == nil or deg < gentlest then gentlest = deg end
                end
            end
        end
    end
    return gentlest
end

--- WHAT KIND OF JUNCTION THIS IS. Read off the tool's OWN pairing - which lanes it found carrying a
--- route straight across, and which stop here - not off the arm angles alone. Angles alone misread a
--- T whose through road bends through the junction (its two through arms 141 degrees apart) as a Y,
--- which is how one site was filed under the wrong heading for a whole survey. Angles still describe
--- the type once the pairing has decided it.
---
--- Nothing branches on this yet: it is recorded and logged so that per-type rules have somewhere to
--- attach later, without the order of the clear having to be taken apart a second time.
function ADFlyoverEditor:junctionClassify(jp)
    if jp == nil then return "?" end
    jp._branch = nil
    jp._turnVote = nil
    -- What the reading was made from, kept for junctionParts: one record per side route read (at
    -- its index in sB below, each naming its route; none on a cleared site, whose side roads are
    -- lane-end groups instead), the main road's arms, and on a cleared site those lane-end groups,
    -- which two of them are the main road and the two lanes that decided it. junctionParts reads
    -- the same site again for WHERE its roads meet, and has to see it the way this reading did.
    jp._sideRead, jp._mainArms, jp._mainCleared, jp._clearedGroups, jp._clearedPair = {}, nil, false, nil, nil
    jp._clearedLanes = nil
    local c = jp._boxCentre or jp.boxCentre or jp.tracksCentre
    if c == nil then return "?" end
    jp._branchCentre = c

    local function bearing(x, z)
        return math.deg(math.atan2(x - c.x, z - c.z)) % 360
    end
    local function sep(a, b)
        local d = math.abs(a - b) % 360
        if d > 180 then d = 360 - d end
        return d
    end
    -- Bearings that are within tol of each other are the same arm - the two lanes of one road, and
    -- the several near-coincident one-way tracks a busy arm is built from.
    local function arms(list, tol)
        local out = {}
        for _, a in ipairs(list) do
            local hit = nil
            for _, g in ipairs(out) do
                for _, b in ipairs(g) do
                    if sep(a, b) <= tol then hit = g break end
                end
                if hit ~= nil then break end
            end
            if hit == nil then out[#out + 1] = { a } else hit[#hit + 1] = a end
        end
        local means = {}
        for _, g in ipairs(out) do
            local sx, sz = 0, 0
            for _, v in ipairs(g) do
                sx = sx + math.sin(math.rad(v))
                sz = sz + math.cos(math.rad(v))
            end
            means[#means + 1] = math.deg(math.atan2(sx, sz)) % 360
        end
        table.sort(means)
        return means
    end

    local routes = jp.pathRoutes or {}
    local tB, sB, sPt = {}, {}, {}
    -- WHERE AND HOW EACH SIDE ROAD MEETS THE MAIN ROAD, for its angle. The angle used to be read from
    -- the junction centre out to points 12-60 m away, so a centre off the main road, or a side road
    -- that bends after it leaves, skewed it - "angles shouldn't radiate from the junction centre",
    -- "reads about half of actual" (the user, over the whole map). Now each road is read along its
    -- own line: the side road beyond its turn connector, the main road across all its lanes (see
    -- mainLineAt and meetingOf below).
    local sGeo = {}
    local sNodes = {}   -- each side route's waypoints, alongside sB (for the Corner T lane count)
    local function dirOf(a, b) return math.deg(math.atan2(b.x - a.x, b.z - a.z)) % 360 end
    local function gapOf(a, b) return math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2) end
    -- THE MAIN ROAD'S LINE AT A SPOT: every through lane passing within 20 m of it, averaged (lanes
    -- run both ways, so each is turned to agree). One lane over 10 m read a few degrees rotated
    -- wherever the lane kinks at the junction (22, 46, 61, 65 by the registry: "rotated clockwise
    -- 5-10 degrees"), which is why every lane is averaged in.
    -- ...BUT ONLY MAIN_HALF METRES EITHER SIDE, NOT 20. A 40 m chord is the road's line only where
    -- the road is straight for 40 m; where it bends within 20 m of the junction the chord leans
    -- towards the bend. 22's hairpin starts 17 m along ("main is reading off due to hairpin"), 51
    -- dips to the south-east 13 m off ("main is rotated slightly clockwise"), 12 turns north 10 m
    -- off ("main angle isn't reading right"), and 63 bends right where the side road joins, where
    -- the chord took in far more of the straight north leg than of the bend ("main is rotated
    -- clockwise"). 8 m either side is the road's own heading where the side road joins it, and
    -- averaging the lanes still evens out one lane's kink. Checked against the map's own road lines,
    -- the main road now reads within 2 degrees of them wherever the map's reading can be trusted,
    -- a quarter of a degree on average (the 20 m chord was 4 degrees out at 4, 51 and 63).
    -- ...AND FROM THE POINT ON THE LANE BESIDE THE SPOT, NOT THE LANE'S NEAREST NODE. Nodes on a
    -- straight run sit up to 13 m apart, and a window centred on a node 6 m away is centred 6 m
    -- away - on a road that bends, that is a different heading. The window is measured along the
    -- lane, so a lane that curves is still read over 8 m of its own length.
    -- Returns the point beside the spot on the nearest lane, the road's direction, and the road's
    -- MIDDLE beside the spot: halfway between its outermost lanes, measured across (not the lanes'
    -- average, which a lane two routes run along would pull towards its side). The side road meets
    -- the main road on that middle line (roadReading below). And, for the harness picture, the
    -- stretch each lane was read over (its two ends, MAIN_HALF metres either way along it).
    -- skip: side routes that are not the main road's other edge (see the one-lane rule below).
    local MAIN_HALF = 8
    local function mainLineAt(px, pz, skip)
        local sx, sz, cnt, best, bpt = 0, 0, 0, math.huge, nil
        local feet, wins = {}, {}
        for _, t in ipairs(routes.through or {}) do
            if #t >= 2 then
                -- the closest point on the lane: segment bi, fraction bu along it
                local bi, bu, bd = 1, 0, math.huge
                for i = 1, #t - 1 do
                    local ax, az = t[i].x, t[i].z
                    local vx, vz = t[i + 1].x - ax, t[i + 1].z - az
                    local L2 = vx * vx + vz * vz
                    local u = 0
                    if L2 > 0 then u = math.max(0, math.min(1, ((px - ax) * vx + (pz - az) * vz) / L2)) end
                    local d = (ax + u * vx - px) ^ 2 + (az + u * vz - pz) ^ 2
                    if d < bd then bi, bu, bd = i, u, d end
                end
                if bd <= 20 * 20 then
                    local cum = { 0 }
                    for i = 2, #t do cum[i] = cum[i - 1] + gapOf(t[i - 1], t[i]) end
                    local s0 = cum[bi] + bu * (cum[bi + 1] - cum[bi])
                    -- the point s metres along the lane (held to its ends)
                    local function at(s)
                        s = math.max(0, math.min(cum[#t], s))
                        local i = 1
                        while i < #t - 1 and cum[i + 1] < s do i = i + 1 end
                        local L = cum[i + 1] - cum[i]
                        local f = 0
                        if L > 0 then f = (s - cum[i]) / L end
                        return t[i].x + f * (t[i + 1].x - t[i].x), t[i].z + f * (t[i + 1].z - t[i].z)
                    end
                    local ax, az = at(s0 - MAIN_HALF)
                    local bx, bz = at(s0 + MAIN_HALF)
                    local dx, dz = bx - ax, bz - az
                    local l = math.sqrt(dx * dx + dz * dz)
                    if l > 1 then
                        dx, dz = dx / l, dz / l
                        if cnt > 0 and dx * sx + dz * sz < 0 then dx, dz = -dx, -dz end
                        sx, sz, cnt = sx + dx, sz + dz, cnt + 1
                        local qx, qz = at(s0)
                        feet[#feet + 1] = { x = qx, z = qz }
                        wins[#wins + 1] = { ax = ax, az = az, bx = bx, bz = bz }
                        if bd < best then
                            best, bpt = bd, { x = qx, z = qz }
                        end
                    end
                end
            end
        end
        if cnt == 0 then return nil end
        local l = math.sqrt(sx * sx + sz * sz)
        local ux, uz = sx / l, sz / l
        -- ONE THROUGH LANE IS ONE EDGE OF THE ROAD, not its middle. Where the road's other lane is
        -- carried by a side route - 40's south lane, 65's turnaround loop - the middle taken from the
        -- through lane alone was that lane, and the side road was taken to meet the main road 2.5 m
        -- off its middle. So with one through lane, a side route running alongside it here (within
        -- 15 degrees of its line, 2 to 8 m across: a lane's width, not the same lane and not another
        -- road) is its other edge - the nearest stretch of it that is, since 65's loop runs over the
        -- through lane itself before it comes back beside it. Only the middle: the road's direction
        -- is still read from the through lanes.
        -- ...WHERE IT CROSSES THE LINE STRAIGHT ACROSS THE ROAD from the through lane's point, not
        -- its point nearest the spot: that could lie up to 20 m along the road (with a through lane
        -- dropped, 36's side route was taken 12 m along), where "across" on the line at the spot
        -- says nothing about the road's width. And never a side road's lanes (skip): at a shallow Y
        -- they run beside the main road too, and with one through lane dropped both of 53's were
        -- taken for the main road's other edge. Only 40 and 65 have one through lane; their other
        -- edges (40's south lane, 65's loop) are not counted as side roads, and are unchanged by
        -- either (65's dot moves 1 cm).
        if #feet == 1 then
            local q0 = feet[1]
            local nx, nz = uz, -ux   -- straight across the road
            local cosMax = math.cos(math.rad(15))
            for _, sl in ipairs(routes.side or {}) do
                local t = sl.nodes or {}
                local bq, bt = nil, math.huge
                if skip == nil or not skip[sl] then
                    for i = 2, #t do
                        local ax, az = t[i - 1].x, t[i - 1].z
                        local vx, vz = t[i].x - ax, t[i].z - az
                        local L = math.sqrt(vx * vx + vz * vz)
                        -- lined up with the road, so never parallel to the line across it
                        if L > 0 and math.abs(vx * ux + vz * uz) / L >= cosMax then
                            local den = vx * nz - vz * nx
                            local wx, wz = q0.x - ax, q0.z - az
                            local f = (wx * nz - wz * nx) / den
                            local across = math.abs((wx * vz - wz * vx) / den)
                            if f >= 0 and f <= 1 and across >= 2 and across <= 8 and across < bt then
                                bq, bt = { x = ax + f * vx, z = az + f * vz }, across
                            end
                        end
                    end
                end
                if bq ~= nil then feet[#feet + 1] = bq end
            end
        end
        local lo, hi = math.huge, -math.huge
        for _, q in ipairs(feet) do
            local across = (q.x - px) * uz - (q.z - pz) * ux
            lo, hi = math.min(lo, across), math.max(hi, across)
        end
        local mid = (lo + hi) / 2
        return bpt, ux, uz, { x = px + uz * mid, z = pz - ux * mid }, wins
    end
    -- WHERE AND HOW A SIDE ROAD MEETS THE MAIN ROAD. The side road is read from ITS OWN START: the
    -- first fork out along it, where the turn connector from the other direction joins - over 6 m
    -- from there (15, then 10, took in side roads already curving; see SIDE_LEN). The turn
    -- connectors between the main road and that fork leave the main road almost tangentially, so
    -- reading the first 15 m after the lane left the main road made every angle too acute ("reading
    -- off the connector", 1, 34, 42, 66); reading 10-35 m out instead caught side roads that curve
    -- away afterwards (66 curves round to run alongside, 50 dips across). With no fork within 30 m
    -- there is no connector, and the first 6 m after the lane leaves is the side road itself. A lane
    -- that never reaches the main road (1) is read from its end nearest to it. The meeting point is
    -- where the two lines cross.
    local function degreeOf(w)
        local seen, d = {}, 0
        for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
            for _, id in pairs(lst) do if not seen[id] then seen[id] = true d = d + 1 end end
        end
        return d
    end
    local SIDE_LEN = 6   -- how far out a side road's direction is read (why 6: in meetingOf)
    -- the side road's own start on a lane (seq: the lane from where it leaves the main road outward):
    -- the first fork within 30 m of the leave point, or the leave point itself
    local function firstFork(seq)
        local run = 0
        for k = 2, #seq do
            run = run + gapOf(seq[k - 1], seq[k])
            if run > 30 then break end
            if degreeOf(seq[k]) >= 3 then return k end
        end
        return 1
    end
    local function meetingOf(n, counts, far)
        local fi = nil
        for i, w in ipairs(n) do if w == far then fi = i break end end
        if fi == nil then return nil end
        local s1, e1 = fi, fi
        while s1 > 1 and counts[s1 - 1] do s1 = s1 - 1 end
        while e1 < #n and counts[e1 + 1] do e1 = e1 + 1 end
        local j, step
        if s1 > 1 then j, step = s1 - 1, 1          -- leaves at n[s1-1], outward is +1
        elseif e1 < #n then j, step = e1 + 1, -1    -- leaves at n[e1+1], outward is -1
        else
            -- the whole lane is off the main road: start from its end nearest to it
            local function nearMain(w)
                local P0 = mainLineAt(w.x, w.z)
                return P0 ~= nil and (P0.x - w.x) ^ 2 + (P0.z - w.z) ^ 2 or math.huge
            end
            if nearMain(n[1]) <= nearMain(n[#n]) then j, step = 1, 1 else j, step = #n, -1 end
        end
        local leave = n[j]
        -- THE MAIN ROAD IS READ BESIDE WHERE THE SIDE LANE LEAVES IT, NOT WHERE THE TWO LINES CROSS.
        -- On a skewed junction the crossing lies well up the main road from the leave point, and
        -- where the main road bends that is a different heading: at 50 the main road read at the
        -- crossing turns the angle into a Y merge (under 38 degrees), where the user has it as a
        -- T skew. Beside the leave point it holds at about 40.
        -- (This one lane's reading is what junctionParts goes by. A T's label is now read by
        -- roadReading below, which does read the main road where the side road's MIDDLE line crosses
        -- it - the user's recipe - and 50 reads 35.7 there, a Y merge. The map's own road lines give
        -- 35.9 at that spot, but rate that reading unreliable there; the map's roads leaving the
        -- junction say T skew. See roadReading.)
        local P, mx, mz = mainLineAt(leave.x, leave.z)
        if P == nil then return nil end
        local seq = { leave }
        local i = j + step
        while i >= 1 and i <= #n and (counts[i] or i == j + step) do
            seq[#seq + 1] = n[i]
            i = i + step
        end
        -- the side road's own start: the first fork within 30 m of the leave point
        local st = firstFork(seq)
        -- ...and SIDE_LEN metres of it, to the exact point that far along (between nodes). Taking
        -- whole segments until 10 m was passed read 11-14 m wherever the nodes were coarse, and a
        -- side road that bends after it leaves bends within that: 26, 27 and 34 swing round towards
        -- the main road's direction ("angle is too acute on side road", "too acute for meeting
        -- point", "tangent to a connector"), 66 turns south 5 m past its fork, 42 turns north-east
        -- 7 m out ("side road is slightly too acute"). The side road's direction is the one it has
        -- where it starts: read over the same 6 m, the map's own road lines give the same angle
        -- within about 1 degree at 26, 27, 34 and 42 (66's map road starts too far out to check).
        -- 10 m keeps 42 a T skew if that turns out to be the right answer there; it reads 64.7, a
        -- T square, at 6 m, and so does the map.
        local first = seq[st]
        local lx, lz = seq[#seq].x, seq[#seq].z
        local r2 = 0
        for k = st, #seq - 1 do
            local g = gapOf(seq[k], seq[k + 1])
            if r2 + g >= SIDE_LEN then
                local f = (SIDE_LEN - r2) / g
                lx, lz = seq[k].x + f * (seq[k + 1].x - seq[k].x), seq[k].z + f * (seq[k + 1].z - seq[k].z)
                break
            end
            r2 = r2 + g
        end
        local last = { x = lx, z = lz }
        if gapOf(first, last) < 3 then return nil end
        local sx, sz = last.x - first.x, last.z - first.z
        local sl = math.sqrt(sx * sx + sz * sz)
        sx, sz = sx / sl, sz / sl
        -- where the side road's line crosses the main road's (the leave point if they barely cross)
        local ix, iz = leave.x, leave.z
        local den = sx * mz - sz * mx
        if math.abs(den) > 0.05 then
            local t = ((P.x - first.x) * mz - (P.z - first.z) * mx) / den
            ix, iz = first.x + sx * t, first.z + sz * t
        end
        -- (seq and st kept for roadReading: the lane from where it leaves the main road outward, and
        -- where the side road starts on it - the start roadReading reads it from too)
        return { x = ix, z = iz, side = math.deg(math.atan2(sx, sz)) % 360, main = math.deg(math.atan2(mx, mz)) % 360,
            fromX = first.x, fromZ = first.z, toX = last.x, toZ = last.z, seq = seq, st = st }
    end
    -- A SIDE ROAD MEETS THE MAIN ROAD ONCE, IN THE MIDDLE OF ITS MOUTH, AND THE MAIN ROAD IS READ
    -- THERE (the user's own recipe). meetingOf reads one lane: from its own start, with the main road
    -- read beside where THAT lane leaves it. A two-lane side road was two such readings, taken at the
    -- two ends of its mouth - a lane's width and more apart, on a main road that may bend right there
    -- - and the angle was the average of the two lanes' angles. Now:
    --   each lane is read as meetingOf reads it, SIDE_LEN metres from its own start (its first fork),
    --     no further out, and the side road's middle line runs from midway between the two lanes'
    --     starts to midway between the ends of their SIDE_LEN metres: it heads the way the two lanes
    --     do together, wherever along the road each lane's start lies, and lies midway across;
    --   it meets the main road where that line crosses the main road's middle line: the middle of
    --     the side road's mouth, not one lane's end;
    --   the main road is every main lane read MAIN_HALF metres either way beside that one point, so
    --     both lanes are read at the same place (mainLineAt);
    --   the angle is the sharper one between the two lines - one reading for the road.
    -- The main road is read where the middle line crosses it, and the crossing moves with what is
    -- read there, so the two are settled together: read, cross, read again at the crossing, until
    -- the crossing stays put.
    -- ...FROM EACH LANE'S OWN START, NOT FROM WHERE BOTH HAVE STARTED. Read 6 m on from the further
    -- out of the two lanes' starts, past the outermost turn connector on either (tried 2026-09-29),
    -- a side road that curves away was read further round its curve, and so more acute: 27 read 70.9
    -- and 42 63.1, where the user already has both as too acute at 73.5 and 64.7. From each lane's
    -- own start they read 73.5 and 64.2.
    -- A SINGLE-LANE side road - one route, or routes over the same waypoints (a two-way lane is
    -- walked once each way) - is read along its lane, from the same start. So is one whose lanes do
    -- not lie side by side (more than PAIR_GAP apart across the road, or heading more than 30 degrees
    -- apart): by the lane meeting the main road nearest the junction's centre.
    -- Against the map's own road lines, read at this meeting point for both (the 42 junctions where
    -- the map's lines can be trusted): the angle reads 0.53 degrees off them on average, where the
    -- lanes read one by one and averaged read 0.66 (median 0.33 against 0.43). Read at the lanes'
    -- own meeting points instead, both are further off (0.69 against 0.91): where the map is read
    -- moves the score as much as how the road is read, so compare at one place.
    -- It moves one sure label: 50 (a T skew to the user) reads 35.7, a Y merge. Not by its side
    -- road - 233.4 down its middle, where its two lanes read 233.2 and 233.5 - but by its main road:
    -- 50 sits on a bend (the map's roads leave the junction heading 185 one way and 30 the other),
    -- and read at the middle of the mouth the main road heads 17.6, where beside the two lanes'
    -- leave points, 7 and 10 m up the road, it heads 14.3 and 12.9. The map's own road lines give 35.9
    -- at the middle of the mouth (35.8 beside the lane), but rate that reading unreliable there (the
    -- side road swings 28 degrees just past the stretch read, and under 38 degrees the map's lane
    -- choice decides it); read by which way the map's roads leave the junction, 50 is a T skew.
    -- Reading the main road's direction beside the leave points again, with the meeting point kept
    -- in the middle of the mouth, keeps 50 a T skew - and gives today's angle at 51 of 54
    -- junctions, so it gives up the gain above. Which one is right is the user's call.
    -- WHERE THE SIDE ROAD RUNS NEARLY ALONG THE MAIN ROAD the two lines cross at a shallow angle, so
    -- a line read a little to one side crosses a long way up the road. 53's was read down one lane
    -- (its other lane was never counted as a side road; see "A LANE THE SIDE-ROAD COUNT MISSED"),
    -- crossed 24 m out and read 8.1; down its middle it crosses 8 m from the centre, inside the
    -- mouth, and reads 12.3 (the map 11.1 there, 12.0 at the junction's centre). The corner T 31
    -- crossed 19 m up its north-west leg and read 2.3: its side road carries straight on from that
    -- leg, so the two lines barely cross anywhere. A crossing that far past the mouth is not taken
    -- (see "A CROSSING WELL PAST THE MOUTH"); held at its corner it reads 51.9, as before. Its kind
    -- is not read from the angle, and a corner T's angle has no rule yet.
    local PAIR_GAP = 12
    -- how far a point lies from the nearest of the main road's lanes
    local function offThrough(w)
        local best = math.huge
        for _, t in ipairs(routes.through or {}) do
            for i = 2, #t do
                local ax, az = t[i - 1].x, t[i - 1].z
                local vx, vz = t[i].x - ax, t[i].z - az
                local L2 = vx * vx + vz * vz
                local u = 0
                if L2 > 0 then u = math.max(0, math.min(1, ((w.x - ax) * vx + (w.z - az) * vz) / L2)) end
                best = math.min(best, (ax + u * vx - w.x) ^ 2 + (az + u * vz - w.z) ^ 2)
            end
        end
        return math.sqrt(best)
    end
    -- A lane read from where the side road starts on it: its seq, that start (k), the start point
    -- and the point SIDE_LEN metres along the lane from it, and the heading between the two. nil
    -- when the lane runs on less than 3 m from its start.
    local function laneFrom(seq, k0, flow)
        local lx, lz = seq[#seq].x, seq[#seq].z
        local run = 0
        for k = k0, #seq - 1 do
            local d = gapOf(seq[k], seq[k + 1])
            if run + d >= SIDE_LEN then
                local f = (SIDE_LEN - run) / d
                lx, lz = seq[k].x + f * (seq[k + 1].x - seq[k].x), seq[k].z + f * (seq[k + 1].z - seq[k].z)
                break
            end
            run = run + d
        end
        local first = seq[k0]
        if (lx - first.x) ^ 2 + (lz - first.z) ^ 2 < 3 * 3 then return nil end
        return { seq = seq, k = k0, from = { x = first.x, z = first.z }, to = { x = lx, z = lz },
            dir = math.deg(math.atan2(lx - first.x, lz - first.z)) % 360, flow = flow }
    end
    -- one of this side road's lanes (an index into sB), read from where the side road starts on it:
    -- its first fork, as meetingOf reads it
    local function sideLane(i)
        local g = sGeo[i]
        return laneFrom(g.seq, g.st, jp._sideRead[i].flow)
    end
    local function sameLane(p, q)
        local on, shared = {}, 0
        for _, w in ipairs(p) do on[w] = true end
        for _, w in ipairs(q) do if on[w] then shared = shared + 1 end end
        return shared >= 0.5 * math.min(#p, #q)
    end
    -- idx: the side road's lanes, as indices into sB (each one's meetingOf reading in sGeo). nil
    -- when there is not 3 m of side road to read, or no main road beside the mouth.
    local function roadReading(idx)
        -- the distinct lanes, first come first served in sB's order
        local lanes = {}
        for _, i in ipairs(idx) do
            local dup = false
            for _, k in ipairs(lanes) do
                if sameLane(sNodes[k], sNodes[i]) then dup = true break end
            end
            if not dup then lanes[#lanes + 1] = i end
        end
        if #lanes == 0 then return nil end
        -- the lane meeting the main road nearest the centre (of those with 3 m of side road to read:
        -- one too short to read does not throw away a partner that can be), and its partner: the
        -- other lane nearest to it where the side road starts, one running the other way wherever
        -- there is one
        local function gd(i) return (sGeo[i].x - c.x) ^ 2 + (sGeo[i].z - c.z) ^ 2 end
        local order = {}
        for k, i in ipairs(lanes) do order[k] = i end
        table.sort(order, function(p, q)
            if gd(p) ~= gd(q) then return gd(p) < gd(q) end
            return p < q
        end)
        local a, la = nil, nil
        for _, i in ipairs(order) do
            local li = sideLane(i)
            if li ~= nil then
                a, la = i, li
                break
            end
        end
        if a == nil then return nil end
        local b, lb, bd = nil, nil, math.huge
        for _, i in ipairs(lanes) do
            if i ~= a then
                local li = sideLane(i)
                if li ~= nil then
                    local d = gapOf(la.from, li.from)
                    if li.flow == la.flow then d = d + 1000 end
                    if d < bd then b, lb, bd = i, li, d end
                end
            end
        end
        -- A LANE THE SIDE-ROAD COUNT MISSED can still be the other half of the road. A route only
        -- counts as a side road where it runs more than 6 m off the main road within 25 m of the
        -- centre, and the inner lane of a shallow Y hugs the main road further out than that: at 53
        -- the south lane stays within 6 m of it for 31 m, so the road was read down its north lane
        -- alone, and the red dot landed 24 m up the main road, outside the mouth. With no partner
        -- among the counted lanes, every other side route is tried: from its point nearest where
        -- this lane leaves the main road (within PAIR_GAP of it), outward, from where the side road
        -- starts on it - its first fork, as for any lane (53's south lane: where the connector from
        -- the south-east joins, 14 m from the centre). Below, it still has to lie beside this lane
        -- over the whole stretch read, and there run more than 2 m off the main road's lanes - a lane
        -- of the main road itself is not the side road's. Only this reading changes: the count, the
        -- arms and the part reader are as they were.
        -- NOT THE MAIN ROAD'S OTHER LANE. A route that heads more along the main road than along this
        -- lane is carrying the main road, whatever else it does: 65's turnaround loop comes back as
        -- the main road's other lane (mainLineAt takes it as the road's other edge) 4 m off the
        -- through lane, where "2 m off the main road's lanes" does not rule it out; at a side road
        -- meeting the main road under 30 degrees "beside this lane" would not either. 53's south
        -- lane heads 1.4 degrees off its north lane and 17.4 off the main road.
        -- (Counted side routes not read with this road are still tried; only this road's own lanes -
        -- idx, already tried above - are not. A lane can be counted and still not be read with its
        -- road, when its own meeting point lies over 20 m from the centre. Locked 9 m east of 40, its
        -- south road's other lane is one such, and without it the road read 82.3 along one lane,
        -- against 88.5 down its middle - 87.9 at the usual lock. Another road's lane does not lie
        -- beside this one over the whole stretch read, which is tested below.)
        local borrowed, bRoute = false, nil
        if lb == nil then
            local lead = la.seq[1]
            local ux0, uz0 = math.sin(math.rad(la.dir)), math.cos(math.rad(la.dir))
            local counted = {}
            for _, i in ipairs(idx) do counted[jp._sideRead[i].route] = true end
            local mainDir = nil
            do
                local P0, mx0, mz0 = mainLineAt(lead.x, lead.z)
                if P0 ~= nil then mainDir = math.deg(math.atan2(mx0, mz0)) % 360 end
            end
            -- the angle between two lines (lanes run either way)
            local function lineSep(p, q)
                local d = sep(p, q)
                return math.min(d, 180 - d)
            end
            for _, sl in ipairs(routes.side or {}) do
                local n = sl.nodes
                if not counted[sl] and n ~= nil and #n >= 2 and not sameLane(sNodes[a], n) then
                    local k, kd = 1, math.huge
                    for m, w in ipairs(n) do
                        local d = (w.x - lead.x) ^ 2 + (w.z - lead.z) ^ 2
                        if d < kd then k, kd = m, d end
                    end
                    if kd <= PAIR_GAP * PAIR_GAP then
                        -- outward: whichever way along the route heads out along this lane
                        local fwd, back = -math.huge, -math.huge
                        if k < #n then fwd = (n[k + 1].x - n[k].x) * ux0 + (n[k + 1].z - n[k].z) * uz0 end
                        if k > 1 then back = (n[k - 1].x - n[k].x) * ux0 + (n[k - 1].z - n[k].z) * uz0 end
                        local step = 1
                        if back > fwd then step = -1 end
                        local seq, m = {}, k
                        while m >= 1 and m <= #n do
                            seq[#seq + 1] = n[m]
                            m = m + step
                        end
                        local flow = "out"
                        if sl.useOut then flow = "in" end
                        local li = laneFrom(seq, firstFork(seq), flow)
                        if li ~= nil and (mainDir == nil or lineSep(li.dir, la.dir) < lineSep(li.dir, mainDir)) then
                            local d = gapOf(la.from, li.from)
                            if li.flow == la.flow then d = d + 1000 end
                            if d < bd then b, lb, bd, borrowed, bRoute = nil, li, d, true, sl end
                        end
                    end
                end
            end
        end
        local fx, fz, tx, tz = la.from.x, la.from.z, la.to.x, la.to.z
        local read = { la }
        if lb ~= nil and sep(la.dir, lb.dir) <= 30 then
            -- the middle line: from midway between the two lanes' starts to midway between the ends of
            -- their SIDE_LEN metres. Its heading is the two lanes' own readings together (the two
            -- stretches added), wherever along the road each lane's start lies; it lies midway across.
            local mfx, mfz = (la.from.x + lb.from.x) / 2, (la.from.z + lb.from.z) / 2
            local mtx, mtz = (la.to.x + lb.to.x) / 2, (la.to.z + lb.to.z) / 2
            local ux, uz = mtx - mfx, mtz - mfz
            local ul = math.sqrt(ux * ux + uz * uz)
            -- side by side: within PAIR_GAP of each other straight across that line, at both ends
            local function acrossGap(p, q) return math.abs((p.x - q.x) * uz - (p.z - q.z) * ux) / ul end
            if ul >= 3 and acrossGap(la.from, lb.from) <= PAIR_GAP and acrossGap(la.to, lb.to) <= PAIR_GAP
                and (not borrowed or (offThrough(lb.from) > 2 and offThrough(lb.to) > 2)) then
                fx, fz, tx, tz = mfx, mfz, mtx, mtz
                read = { la, lb }
            end
        end
        local sx, sz = tx - fx, tz - fz
        local sl = math.sqrt(sx * sx + sz * sz)
        if sl < 3 then return nil end
        sx, sz = sx / sl, sz / sl
        -- side roads' lanes, which are never the main road's other edge (mainLineAt): every route
        -- counted as a side road - one that leaves the main road here, read or not (with a through
        -- lane dropped, 53's north lane met the main road over 20 m out, was not read, and was taken
        -- for the other edge) - and the lane borrowed above. The other edges the rule is for stay
        -- with the main road, and are not counted (40's south lane, 65's loop).
        local own = {}
        for _, sr in pairs(jp._sideRead) do own[sr.route] = true end
        if borrowed and #read == 2 then own[bRoute] = true end
        -- where the middle line crosses the main road's middle line, starting from where the lanes'
        -- own readings met it
        local px, pz = sGeo[a].x, sGeo[a].z
        if #read == 2 and b ~= nil then px, pz = (px + sGeo[b].x) / 2, (pz + sGeo[b].z) / 2 end
        local mx, mz, wins, turns, settled = nil, nil, nil, 0, false
        for k = 1, 10 do
            local P, ux, uz, mid, w = mainLineAt(px, pz, own)
            if P == nil then return nil end
            mx, mz, wins, turns = ux, uz, w, k
            local nx, nz = mid.x, mid.z
            local den = sx * mz - sz * mx
            if math.abs(den) > 0.05 then
                local t = ((mid.x - fx) * mz - (mid.z - fz) * mx) / den
                nx, nz = fx + sx * t, fz + sz * t
            end
            local moved = (nx - px) ^ 2 + (nz - pz) ^ 2
            px, pz = nx, nz
            if moved < 0.01 * 0.01 then
                settled = true
                break
            end
        end
        if not settled then
            -- still moving after ten turns (never on the survey map): the main road read where the
            -- point ended up, so the two halves of the reading are of the same place
            local P, ux, uz, _, w = mainLineAt(px, pz, own)
            if P == nil then return nil end
            mx, mz, wins = ux, uz, w
        end
        -- A CROSSING WELL PAST THE MOUTH IS NOT WHERE THE SIDE ROAD MEETS THE MAIN ROAD. Where the
        -- side road carries on nearly along the main road the two lines barely cross, and each turn
        -- above reads the main road further along, where it lies even closer to the side road's
        -- line: at the corner T 31 the point ran 18 m up the north-west leg, 25 m past where the
        -- side lane leaves the main road, and read 2.3 degrees. So when the crossing lies more than
        -- twice MAIN_HALF along the main road past every lane's leave point - the whole stretch the
        -- main road is read over clear of the mouth - the meeting point is held at the mouth: the
        -- main road's middle beside the lanes' leave points, read there. Everywhere else on the
        -- survey map the crossing lies within 11 m of a leave point (36 and 53, shallow Ys, about 10
        -- and 9), so only 31 is held; it reads 51.9 at its corner, and as a corner T its kind is not
        -- read from the angle anyway.
        local held = false
        do
            local lo, hi, lx, lz = math.huge, -math.huge, 0, 0
            for _, l in ipairs(read) do
                local w = l.seq[1]
                local al = (w.x - px) * mx + (w.z - pz) * mz
                lo, hi = math.min(lo, al), math.max(hi, al)
                lx, lz = lx + w.x / #read, lz + w.z / #read
            end
            if lo > 2 * MAIN_HALF or hi < -2 * MAIN_HALF then
                local P, ux, uz, mid, w = mainLineAt(lx, lz, own)
                if P ~= nil then
                    px, pz, mx, mz, wins, held = mid.x, mid.z, ux, uz, w, true
                end
            end
        end
        -- each lane read: where the side road starts on it and the end of its SIDE_LEN metres (for
        -- the picture)
        local starts = {}
        for _, l in ipairs(read) do
            starts[#starts + 1] = { x = l.from.x, z = l.from.z, flow = l.flow, toX = l.to.x, toZ = l.to.z }
        end
        return { x = px, z = pz, side = math.deg(math.atan2(sx, sz)) % 360, main = math.deg(math.atan2(mx, mz)) % 360,
            fromX = fx, fromZ = fz, toX = tx, toZ = tz, starts = starts, lanes = #lanes, turns = turns,
            borrowed = borrowed and #read == 2, held = held, windows = wins }
    end
    -- EACH END OF THE MAIN ROAD IS READ BY THE WAY IT LEAVES, 12 m out, not where the route ends
    -- 60 m out. A road that bends soon after the junction put its two lanes' far ends on very
    -- different bearings - at 22 (by the registry) the inside and outside of a hairpin read as two
    -- separate arms, and a T was called a Y.
    local function leaving(t, step)
        local k, kd = 1, math.huge
        for i, w in ipairs(t) do
            local d = (w.x - c.x) ^ 2 + (w.z - c.z) ^ 2
            if d < kd then kd, k = d, i end
        end
        local i = k
        while i + step >= 1 and i + step <= #t do
            i = i + step
            if (t[i].x - c.x) ^ 2 + (t[i].z - c.z) ^ 2 >= 12 * 12 then break end
        end
        return t[i]
    end
    for _, t in ipairs(routes.through or {}) do
        if #t >= 2 then
            local a, b = leaving(t, -1), leaving(t, 1)
            tB[#tB + 1] = bearing(a.x, a.z)
            tB[#tB + 1] = bearing(b.x, b.z)
        end
    end
    for _, sl in ipairs(routes.side or {}) do
        local n = sl.nodes
        if n ~= nil and #n >= 1 then
            -- TWO DIFFERENT ENDS ANSWER TWO DIFFERENT QUESTIONS. Which way the arm lies is read off
            -- the end FURTHEST out, because a bearing taken from a node a metre from the centre is
            -- mostly noise. WHERE it joins is read off the end NEAREST in - taking that from the far
            -- end too had a side road that runs 95 m away reported as a 95 m stagger, which is how a
            -- plain crossroads gets filed as a staggered one.
            -- ONLY THE PART THAT LEAVES THE THROUGH ROAD SAYS WHERE A SIDE ROAD GOES. A side route can
            -- run along the main road before it turns off (at 50 by the registry both side routes ran
            -- 60 m up the main road, then swung south), and a lane the through routes missed runs
            -- beside the main road the whole way (66's). So every node is tested against the through
            -- routes: within BESIDE metres of one, it is on the main road. A route with nothing off
            -- the main road is part of it and is not a side road at all; for the rest, the arm is
            -- read from the part that is off it. (A 20-degree test on the far end did this first,
            -- and threw away 50's real side road because its far end lay up the main road.)
            -- ...AND PAST THE END OF THE THROUGH ROUTE IS STILL THE MAIN ROAD. The through routes stop
            -- about 60 m out; a turn lane that joined the main road carries on beyond that, and its
            -- tail - nearest to where a through route ENDS - read as a phantom arm (22, 23, 36, 65).
            local BESIDE = 6
            local function besideThrough(w)
                local best, atEnd = math.huge, false
                for _, t in ipairs(routes.through or {}) do
                    for i = 2, #t do
                        local ax, az, bx, bz = t[i - 1].x, t[i - 1].z, t[i].x, t[i].z
                        local vx, vz = bx - ax, bz - az
                        local L2 = vx * vx + vz * vz
                        local u = (L2 > 0) and ((w.x - ax) * vx + (w.z - az) * vz) / L2 or 0
                        local end_ = (i == 2 and u < 0) or (i == #t and u > 1)
                        if end_ and L2 > 0 then
                            -- only IN LINE with the main road past its end: at a tight Y (53) a
                            -- branch 25 m off to the side was nearest to the route's end, and
                            -- counted as the main road carrying on
                            local side = math.abs((w.x - ax) * vz - (w.z - az) * vx) / math.sqrt(L2)
                            if side > 2 * BESIDE then end_ = false end
                        end
                        u = math.max(0, math.min(1, u))
                        local px, pz = ax + u * vx - w.x, az + u * vz - w.z
                        local d2 = px * px + pz * pz
                        if d2 < best then best, atEnd = d2, end_ end
                    end
                end
                return best <= BESIDE * BESIDE or atEnd
            end
            -- A STRETCH THAT COMES BACK TO THE MAIN ROAD IS NOT A ROAD LEAVING IT. Only an off-road
            -- stretch that runs to an end of the route counts; one with the main road on both sides
            -- is a loop-back or a lay-by. At 65 (by the registry) the turnaround loop at the end of
            -- the main road bulged 15 m off it and was read as a fourth arm.
            local on = {}
            for i, w in ipairs(n) do on[i] = besideThrough(w) end
            -- ...and a stretch that leaves the main road far out is the NEXT junction's side road:
            -- at 31 (by the registry) a lane ran 45 m up the main road and turned off at the
            -- neighbour. A stretch only counts if it comes within 25 m of this junction's centre.
            local counts = {}
            local function takeRun(from, to, step)
                local run, near = {}, math.huge
                for i = from, to, step do
                    if on[i] then break end
                    run[#run + 1] = i
                    near = math.min(near, (n[i].x - c.x) ^ 2 + (n[i].z - c.z) ^ 2)
                end
                if near <= 25 * 25 then
                    for _, i in ipairs(run) do counts[i] = true end
                end
            end
            takeRun(1, #n, 1)
            takeRun(#n, 1, -1)
            local far, fd, nearW, nd = nil, -1, nil, math.huge
            for i, w in ipairs(n) do
                if counts[i] then
                    local d = (w.x - c.x) ^ 2 + (w.z - c.z) ^ 2
                    if d > fd then fd, far = d, w end
                    if d < nd then nd, nearW = d, w end
                end
            end
            if far ~= nil then
                sB[#sB + 1] = bearing(far.x, far.z)
                sPt[#sPt + 1] = nearW
                -- AT sB's INDEX, NOT APPENDED. meetingOf can answer nil (no main road beside where the
                -- lane leaves, or under 3 m of side road to read), and appending nil adds nothing: the
                -- entries after it slid down one place, so each later side road read the NEXT road's
                -- meeting point, since sGeo is read by sB's index below. No junction on the survey map hits it today
                -- (checked over all 75); the part reader relies on each road's own meeting point.
                local geo = meetingOf(n, counts, far)
                sGeo[#sB] = geo
                local flow = "out"
                if sl.useOut then flow = "in" end
                jp._sideRead[#sB] = { route = sl, bearing = sB[#sB], pt = nearW, far = far, meet = geo, flow = flow }
                do
                    -- only the part off the main road: the lane's connector and main-road stretch
                    -- differ between the two directions of one two-way lane
                    local offRoad = {}
                    for i2, w in ipairs(n) do if counts[i2] then offRoad[#offRoad + 1] = w end end
                    sNodes[#sNodes + 1] = offRoad
                end
            end
        end
    end

    -- A CLEARED JUNCTION HAS NO MAIN ROAD TO READ - nothing joins its lanes - so it is read from the
    -- lane ends themselves: group them into arms by where they sit, and the main road is the pair of
    -- arms whose lanes line up straight across the gap (a lane arriving on one heading the way a lane
    -- leaves on the other, and roughly in line with it). Every side route then counts as an arm by
    -- where it sits. Without this every cleared junction read as "Y" (69-75 by the registry).
    local cleared = false
    if #tB == 0 and jp.approaches ~= nil and #jp.approaches >= 2 then
        local function place(ap)
            local w = ap.selWp or ap.wp
            return bearing(w.x, w.z)
        end
        local groups = {}
        for _, ap in ipairs(jp.approaches) do
            if (ap.selWp or ap.wp) ~= nil then
                local p, hit = place(ap), nil
                for _, g in ipairs(groups) do
                    if sep(p, g.p) <= 35 then hit = g break end
                end
                if hit == nil then
                    hit = { p = p, aps = {} }
                    groups[#groups + 1] = hit
                end
                hit.aps[#hit.aps + 1] = ap
            end
        end
        -- A SINGLE-LANE ROAD IS NOT THE MAIN ROAD when AT LEAST TWO two-lane roads enter (with one,
        -- a single lane can still be half of the main road): its lane ends all sit
        -- on one spot (one lane used both ways, or one way only). At 75 (by the registry) a single
        -- lane lined up dead straight with the south road and was taken for the main road, which in
        -- fact turns the corner east - so between two-lane arms the main road may turn (up to 100
        -- degrees); only when no two two-lane arms exist does it have to line up straight.
        for _, g in ipairs(groups) do
            local a = g.aps[1].selWp or g.aps[1].wp
            g.single = true
            for _, ap in ipairs(g.aps) do
                local w = ap.selWp or ap.wp
                -- (count > 1: lanes running the same way side by side were folded into this one)
                if (ap.count or 1) > 1 or (w.x - a.x) ^ 2 + (w.z - a.z) ^ 2 > 1.5 * 1.5 then g.single = false break end
            end
        end
        local function bestPair(twoLaneOnly, maxTurn)
            local best, bi, bj, be, bx = math.huge, nil, nil, nil, nil
            for i = 1, #groups do
                for j = 1, #groups do
                    if i ~= j and (not twoLaneOnly or (not groups[i].single and not groups[j].single)) then
                        for _, e in ipairs(groups[i].aps) do
                            for _, x in ipairs(groups[j].aps) do
                                if e.dir == "in" and x.dir == "out" and e.bearing ~= nil and x.bearing ~= nil then
                                    local turn = math.deg(junctionAngDiff(e.bearing, x.bearing))
                                    local ew, xw = e.selWp or e.wp, x.selWp or x.wp
                                    local hx, hz = math.sin(e.bearing), math.cos(e.bearing)
                                    local off = math.abs((xw.x - ew.x) * hz - (xw.z - ew.z) * hx)
                                    local cost = turn + 3 * off
                                    if turn <= maxTurn and cost < best then best, bi, bj, be, bx = cost, i, j, e, x end
                                end
                            end
                        end
                    end
                end
            end
            return bi, bj, be, bx
        end
        local nSingle = 0
        for _, g in ipairs(groups) do if g.single then nSingle = nSingle + 1 end end
        local bi, bj, be, bx = nil, nil, nil, nil
        if nSingle > 0 and #groups - nSingle >= 2 then bi, bj, be, bx = bestPair(true, 100) end
        if bi == nil then bi, bj, be, bx = bestPair(false, 40) end
        if bi ~= nil then
            cleared = true
            tB[#tB + 1], tB[#tB + 2] = groups[bi].p, groups[bj].p
            jp._clearedMain = { groups[bi].p, groups[bj].p }
            jp._mainCleared, jp._clearedGroups, jp._clearedPair = true, groups, { bi, bj }
            -- and the two lanes that lined up (the in-lane, then the out-lane): the main road's own
            -- line, which junctionParts measures along
            jp._clearedLanes = { be, bx }
            sB, sPt, sGeo, sNodes = {}, {}, {}, {}
            jp._sideRead = {}
            for k, g in ipairs(groups) do
                if k ~= bi and k ~= bj then
                    sB[#sB + 1] = g.p
                    sPt[#sPt + 1] = g.aps[1].selWp or g.aps[1].wp
                end
            end
        end
    end
    -- The main road's own ends group more loosely (45): its two lanes are 4 m apart, and read close
    -- to the middle on a bend - 22's hairpin - they can sit 43 degrees apart and still be one arm.
    local T, S = arms(tB, 45), arms(sB, 30)
    local nT, nS = #T, #S
    jp._mainArms = T

    local function cross(a)
        local x = math.min(a, 180 - a)
        return (x >= 78) and "4W square" or ((x >= 55) and "4W skew" or "4W very skew")
    end

    if nT >= 4 then
        local worst = 180
        for i = 1, nT do
            for j = i + 1, nT do
                local d = sep(T[i], T[j])
                if d < worst then worst = d end
            end
        end
        return cross(worst)
    elseif nT == 2 and nS >= 2 then
        -- A through road with two side roads on it. Meeting it in the same place is a crossroads;
        -- meeting it a way apart is a STAGGERED crossing - two T's sharing one road - and the two
        -- must not be taken for one junction. Measured ALONG the through road, which needs no angle.
        local hx, hz = math.sin(math.rad(T[1])), math.cos(math.rad(T[1]))
        local lo, hi = math.huge, -math.huge
        for _, p in ipairs(sPt) do
            local along = (p.x - c.x) * hx + (p.z - c.z) * hz
            if along < lo then lo = along end
            if along > hi then hi = along end
        end
        if (hi - lo) > 10 then
            -- SIDE ROADS ALL ON ONE SIDE ARE NOT A STAGGERED CROSSING: nothing carries on across the
            -- main road. 72 (by the registry) is a T square and, 11 m on, a one-way Y merge, both
            -- off the south side, and read "4W offset (19 m stagger)" ("t square with y merge
            -- after"). Said as what it is; junctionParts reads the two places they meet. Only a side
            -- road clearly off the main road's line counts (more than about 12 degrees off it).
            -- Only in place of the offset reading, which is all 72 needed: side roads meeting within
            -- 10 m keep their crossroads kind (once cleared, 10, 41, 44, 57, 60 and 62 read "2 side
            -- roads, one side" in place of their 4W kinds when this came first). And only on a main
            -- road running straight through (turning 30 degrees or less, the limit junctionParts
            -- reads by): across a bend the line between the two main arms says nothing about sides -
            -- 58, once cleared, pairs main arms turning 75 degrees.
            local ux = math.sin(math.rad(T[1])) - math.sin(math.rad(T[2]))
            local uz = math.cos(math.rad(T[1])) - math.cos(math.rad(T[2]))
            local ul = math.sqrt(ux * ux + uz * uz)
            if ul > 0.3 and 180 - sep(T[1], T[2]) <= 30 then
                local left, right = 0, 0
                for _, s in ipairs(S) do
                    local cr = (ux * math.cos(math.rad(s)) - uz * math.sin(math.rad(s))) / ul
                    if cr > 0.2 then left = left + 1 elseif cr < -0.2 then right = right + 1 end
                end
                if left == nS or right == nS then
                    return string.format("%d side roads, one side", nS)
                end
            end
            return string.format("4W offset (%.0f m stagger)", hi - lo)
        end
        local branch = math.min(sep(S[1], T[1]), sep(S[1], T[2]))
        jp._branch = { angle = branch, main = (sep(S[1], T[1]) <= sep(S[1], T[2])) and T[1] or T[2], side = S[1], other = T }
        return cross(branch)
    elseif nT == 2 and nS == 0 then
        -- Nothing left off the through road. This used to fall through as "T square", which looked
        -- like an answer and was not one.
        return "no side road found"
    elseif nT == 2 then
        local branch = 90
        if nS == 1 then
            branch = math.min(sep(S[1], T[1]), sep(S[1], T[2]))
            -- kept for the card and the harness overlay: the angle, the main-road arm it was measured
            -- from, and the side arm (bearings as bearing() gives them)
            jp._branch = { angle = branch, main = (sep(S[1], T[1]) <= sep(S[1], T[2])) and T[1] or T[2], side = S[1], other = T }
            -- Measured where the side road meets the main road when that is known: the side road
            -- read once, down its middle, and the main road where that middle meets it (roadReading),
            -- the sharper angle between the two lines.
            -- only lanes meeting the main road AT this junction (within 20 m of its centre): at 2 a
            -- road joining the side road further up met the main road's line 31 m away, 13 degrees
            -- to it, and was read with it
            local acc, cnt, g0, g0d = 0, 0, nil, math.huge
            local mine = {}
            for i, v in ipairs(sB) do
                local g = sGeo[i]
                local gd = math.huge
                if g ~= nil then gd = (g.x - c.x) ^ 2 + (g.z - c.z) ^ 2 end
                if g ~= nil and sep(v, S[1]) <= 30 and gd <= 20 * 20 then
                    mine[#mine + 1] = i
                    local a = sep(g.side, g.main)
                    acc = acc + math.min(a, 180 - a)
                    cnt = cnt + 1
                    if gd < g0d then g0, g0d = g, gd end
                end
            end
            local road = roadReading(mine)
            if road ~= nil then
                local a = sep(road.side, road.main)
                branch = math.min(a, 180 - a)
                jp._branch = { angle = branch, meet = road }
            elseif cnt > 0 then
                -- the main road could not be read beside the mouth: the lanes' own readings, averaged,
                -- as before the road was read as one
                branch = acc / cnt
                jp._branch = { angle = branch, meet = g0 }
            end
        end
        -- A CORNER T: the main road turns the corner at the junction and a SINGLE-LANE road carries
        -- straight on from one of its legs (24 and 31 by the registry; the user's own category, with
        -- its own rules to come). A two-lane road in that place is an ordinary side road and the
        -- junction stays a T (46). One lane = one side route, or routes whose off-road parts run over
        -- the same waypoints (a single two-way lane is walked once each way: 24 and 31 share all of
        -- them, two-lane roads none).
        if nS == 1 then
            local bend = 180 - sep(T[1], T[2])
            -- the side road's direction where it leaves (sGeo), not towards its far end: 24's single
            -- lane leaves due west, straight on from the main road's east leg, then curves away
            local sx, sz, sd = 0, 0, S[1]
            for i, v in ipairs(sB) do
                local g = sGeo[i]
                if g ~= nil and sep(v, S[1]) <= 30 then
                    sx, sz = sx + math.sin(math.rad(g.side)), sz + math.cos(math.rad(g.side))
                end
            end
            if sx ~= 0 or sz ~= 0 then sd = math.deg(math.atan2(sx, sz)) % 360 end
            local straightOn = math.min(sep(sd, (T[1] + 180) % 360), sep(sd, (T[2] + 180) % 360))
            if bend >= 45 and straightOn <= 30 then
                local lanes = {}
                for i, v in ipairs(sB) do
                    if sNodes[i] ~= nil and sep(v, S[1]) <= 30 then lanes[#lanes + 1] = sNodes[i] end
                end
                local single = (#lanes <= 1)
                if not single then
                    local first = {}
                    for _, w in ipairs(lanes[1]) do first[w] = true end
                    single = true
                    for k = 2, #lanes do
                        local shared = 0
                        for _, w in ipairs(lanes[k]) do if first[w] then shared = shared + 1 end end
                        if shared < 0.5 * #lanes[k] then single = false break end
                    end
                end
                if single then
                    -- ...AND ITS T ANGLE IS NOT ITS ANSWER. The main road turns the corner right where
                    -- the side road meets it, so the main road's line there (MAIN_HALF metres either
                    -- way) is a chord across the corner - 24 reads 31.4 and 31 51.9, and the map's own
                    -- road lines swing by 27 degrees within a metre at 24's corner. What decided the
                    -- kind is kept for the harness picture to show in its place: how far the main road
                    -- turns, and how close to straight on from one of its legs the side road carries.
                    if jp._branch ~= nil then
                        jp._branch.corner = { bend = bend, straightOn = straightOn, legs = { T[1], T[2] }, side = sd }
                    end
                    return "Corner T"
                end
            end
        end
        local kind = (branch <= 38) and "Y merge" or ((branch <= 62) and "T skew" or "T square")
        -- A SECOND SAY ON Y MERGE OR T: the shape of the wired turns (junctionGentlestTurn). Over the
        -- user's labels it splits the two cleanly where the angle once did not (50), so where it is
        -- clear - 30 degrees or less a Y merge, 37 or more a T - it decides Y merge or T. Between the
        -- two it has no say (35, which the user marked "Y?", turns 33) and the angle stands. The
        -- angle always decides T skew or T square.
        local gentlest = self:junctionGentlestTurn(jp)
        if gentlest ~= nil then
            local byAngle = kind
            if gentlest <= 30 and kind ~= "Y merge" then
                kind = "Y merge"
            elseif gentlest >= 37 and kind == "Y merge" then
                kind = "T skew"
            end
            jp._turnVote = { deg = gentlest, byAngle = byAngle, kind = kind }
            if kind ~= byAngle then
                Logging.info("[FlyoverEditor]: junction kind - the angle (%.0f degrees) reads %s, but the gentlest wired turn bends %.0f degrees: %s",
                    branch, byAngle, gentlest, kind)
            end
        end
        return kind
    elseif nT == 0 then
        -- Nothing runs straight through and nothing lines up across the gap. This used to read "Y".
        return "no main road found"
    elseif nT >= 3 then
        -- Every arm pairs with every other, because in a Y each one really does run into each other
        -- fairly straight. Nothing here is a side road off a main road, which is why no box forms.
        return "Y"
    end
    return "?"
end

-- The 8-point compass word for a direction on the map, lower case ("n" ... "nw"). FS25's z grows
-- SOUTHWARD, so north is -z.
local function jxCompass(dx, dz)
    local b = math.deg(math.atan2(dx, -dz)) % 360
    local names = { "n", "ne", "e", "se", "s", "sw", "w", "nw" }
    return names[math.floor((b + 22.5) / 45) % 8 + 1]
end

-- MODSPLIT: SHARED WITH THE FILES LOADED AFTER THIS ONE (tools/modsplit/split.py writes this block)
ADFlyoverEditor.shared.jxCompass = jxCompass
-- MODSPLIT: end of the shared block

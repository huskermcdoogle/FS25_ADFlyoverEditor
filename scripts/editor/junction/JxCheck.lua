-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua
-- loads it after FlyoverEditor.lua, in the old file's order.
-- MODSPLIT: HELPERS FROM THE FILES LOADED BEFORE THIS ONE (tools/modsplit/split.py writes this block)
for _, name in ipairs({ "JX_WHOLE_PIECE_REACH", "junctionAngDiff", "jxCompass", "jxRightOfWay", "jxRightOfWayLists", "jxSiteHas" }) do
    if ADFlyoverEditor.shared == nil or ADFlyoverEditor.shared[name] == nil then
        Logging.error("[FlyoverEditor]: JxCheck.lua needs %s, which no file loaded before it shares", name)
    end
end
local JX_WHOLE_PIECE_REACH = ADFlyoverEditor.shared.JX_WHOLE_PIECE_REACH
local junctionAngDiff = ADFlyoverEditor.shared.junctionAngDiff
local jxCompass = ADFlyoverEditor.shared.jxCompass
local jxRightOfWay = ADFlyoverEditor.shared.jxRightOfWay
local jxRightOfWayLists = ADFlyoverEditor.shared.jxRightOfWayLists
local jxSiteHas = ADFlyoverEditor.shared.jxSiteHas
-- MODSPLIT: end of the helpers

--- THE CLEAR CHECKS ITS OWN WORK. Two checks, run on the network the clear has just left, and
--- REPORT ONLY: nothing here undoes, refuses or changes anything. What to do when one fails is
--- still the user's call (docs/junction-tool/04, Still open 9).
---
--- 1. THE MIDDLE IS EMPTY. Nothing in the middle of the cleared junction - out as far as its own
---    forks lay before the clear, inside the bound the deletions obey - lets a lane coming in on one
---    road drive out on another, and none of AutoDrive's merge points (teal dots) is left there.
---    Further out, to 45 m, a teal dot the clear made is reported too (65 and 2, where a side road
---    came out doubled), and one fed by the end of a turn the clear cut (36). Those dots found 24
---    missed links across 14 of 60 junctions that our own counts had called clean, and only a drive
---    through the junction, not a count, says whether two roads are still joined. Whether a join or
---    a dot was there BEFORE the clear is asked of the network as it was, by place: the clean-up
---    folds points within 0.3 m into one, and that both moves dots (40) and joins roads that never
---    met (16). Cases that are not a missed connection are named apart, so none is taken for one: a
---    crossroads cleared with through roads kept, whose two kept roads still share the point where
---    they cross, as they did before (decided, not built yet: nothing joins them there) - or which
---    the clear joined there; a site with no box; one lane splitting and joining itself; one road's
---    own lanes; and, at a junction the user wants split, the other part's own wiring, which the
---    clear leaves alone.
--- 2. NOTHING ELSE TOUCHED. The network before against the network after, matched against the
---    clear's own record of every edit it made (jxJournal): a difference nobody recorded is a change
---    no stage meant. Every edit must also lie inside this junction - the respacing may run a
---    stretch out to the first point past the edge, and no further along a lane than its own reach;
---    a stretch it re-lays wholly outside the edge but within that reach is a note, the user's call;
---    every road that drove through the junction must still drive end to end when through roads are
---    kept; every lane must still run its own way - a lane that came in still comes in, one that went
---    out still goes out; and no fork may gain a way out that leads to a dead end (58).
---
--- `ck` is what applyJunctionClear gathered: the site, the preview it worked from, the network
--- before (jxSnapshot), the record, the through roads' lines, the through-roads setting, and the
--- places the roads met before the clear. Logs a summary line and one line per problem, keeps the
--- result in self.junctionLastCheck for the card, and returns it.

local JX_WORD = { n = "north", ne = "north-east", e = "east", se = "south-east",
                  s = "south", sw = "south-west", w = "west", nw = "north-west" }

--- In a fixed order: sets keyed by points come back from pairs() in address order, which is a
--- different order in every process. By place, then by id for two points on the same spot.
local function jxByPos(a, b)
    if a.x ~= b.x then return a.x < b.x end
    if a.z ~= b.z then return a.z < b.z end
    if (a.y or 0) ~= (b.y or 0) then return (a.y or 0) < (b.y or 0) end
    return (a.id or 0) < (b.id or 0)
end

--- Distance from a line of points, how far along it, and which way it runs there.
local function jxOnLine(pts, x, z)
    local bd, bs, bdx, bdz, run = math.huge, 0, 0, 0, 0
    for i = 2, #pts do
        local a, b = pts[i - 1], pts[i]
        local ex, ez = b.x - a.x, b.z - a.z
        local l2 = ex * ex + ez * ez
        local l = math.sqrt(l2)
        local t = 0
        if l2 > 1e-9 then t = math.max(0, math.min(1, ((x - a.x) * ex + (z - a.z) * ez) / l2)) end
        local px, pz = a.x + ex * t, a.z + ez * t
        local d = math.sqrt((x - px) ^ 2 + (z - pz) ^ 2)
        if d < bd then
            bd, bs = d, run + l * t
            if l > 1e-6 then bdx, bdz = ex / l, ez / l end
        end
        run = run + l
    end
    return bd, bs, bdx, bdz
end

--- Unit heading from p to q, or nil when they stand on the same spot.
local function jxHeading(p, q)
    local dx, dz = q.x - p.x, q.z - p.z
    local l = math.sqrt(dx * dx + dz * dz)
    if l < 1e-6 then return nil end
    return dx / l, dz / l
end

--- What the check works from: where the junction is, how far its middle reaches, and which points
--- stand in it now. Nil when the clear left nothing to say where the junction was.
local function jxCheckSetup(ck)
    local site, jp = ck.site, ck.jp
    local cx, cz
    if site ~= nil then
        cx, cz = site.x, site.z
    elseif jp ~= nil then
        local c = jp._boxCentre or jp.tracksCentre
        if c ~= nil then cx, cz = c.x, c.z end
    end
    if cx == nil then return nil end
    local C = { site = site, jp = jp, leave = ck.leave ~= false, before = ck.before,
                journal = ck.journal or {}, lines = ck.routeLines or {}, cx = cx, cz = cz,
                meetings = ck.meetings, name = ck.name, twin = ck.twin, parts = ck.parts }
    local CORE = AutoDrive.FLYOVER_JUNCTION_CLEAR_SCOPE or 12
    local bounded = site ~= nil and site.roads ~= nil and #site.roads > 0
    -- The cleared area is the clear's own idea of this junction: the bound every deletion obeys.
    function C.inArea(x, z)
        if bounded then return jxSiteHas(site, x, z) end
        return (x - cx) ^ 2 + (z - cz) ^ 2 <= CORE * CORE
    end
    function C.node(id) return ADGraphManager:getWayPointById(id) end
    function C.dist(p) return math.sqrt((p.x - cx) ^ 2 + (p.z - cz) ^ 2) end
    function C.at(x, z) return string.format("(%.1f, %.1f)", x, z) end
    function C.wordAt(x, z) return JX_WORD[jxCompass(x - cx, z - cz)] or "?" end
    -- THE MIDDLE, for check 1: as far out as the junction's own forks lay before the clear - where
    -- its turns left and joined the lanes - and 3 m more, never under the clear's core, never over
    -- 30 m, and never past the bound. The bound alone is no good here: it runs every arm out to the
    -- next junction, 44 m where nothing stops it, and that far out it takes in other roads. At 1 a
    -- road joining its two roads 40 m out read as four missed connections and four U-turns.
    local midR = CORE
    for _, f in ipairs(ck.forkSpots or {}) do
        midR = math.max(midR, math.sqrt((f.x - cx) ^ 2 + (f.z - cz) ^ 2) + 3)
    end
    midR = math.min(midR, 30)
    C.midR = midR
    function C.inMiddle(x, z)
        return (x - cx) ^ 2 + (z - cz) ^ 2 <= midR * midR and C.inArea(x, z)
    end
    local live = {}
    for _, w in pairs(ADGraphManager:getWayPoints()) do
        if w ~= nil and w.id ~= nil then live[w] = true end
    end
    C.live = live
    local inA, inMid, area = {}, {}, {}
    for w in pairs(live) do
        if C.inArea(w.x, w.z) then
            inA[w] = true
            area[#area + 1] = w
            if C.inMiddle(w.x, w.z) then inMid[w] = true end
        end
    end
    table.sort(area, jxByPos)
    C.inA, C.inMid, C.area = inA, inMid, area
    C.noBox = (jp ~= nil and jp._box == nil)
    -- Out to 60 m, past the junction's edge: a teal dot or a dead-end spur the clear left there is
    -- still the clear's doing (36's half-cut turn left a teal dot 15 m out, just past the edge; 58's
    -- spur split off its lane 25 m out).
    local near = {}
    for w in pairs(live) do
        if (w.x - cx) ^ 2 + (w.z - cz) ^ 2 <= 60 * 60 then near[#near + 1] = w end
    end
    table.sort(near, jxByPos)
    C.near = near

    -- WHAT STOOD HERE BEFORE, BY PLACE. The clean-up folds two points within 0.3 m into one, and
    -- the one it keeps is not always the one a teal dot sat on: 40e's merge moved 0.5 m onto the
    -- neighbouring point and was called new, though it had been a teal dot all along. So whether a
    -- dot was there before is asked of the place, not of the point.
    local before = C.before
    local dotsBefore, goneBefore = {}, {}
    for w, b0 in pairs(before) do
        if (b0.x - cx) ^ 2 + (b0.z - cz) ^ 2 <= 80 * 80 then
            if jxRightOfWayLists(b0.out, b0.inn) then dotsBefore[#dotsBefore + 1] = b0 end
            if not live[w] then goneBefore[#goneBefore + 1] = { w = w, b = b0 } end
        end
    end
    --- How far the nearest teal dot that stood within 1 m of (x, z) before the clear was, or nil.
    function C.dotBefore(x, z)
        local bd = nil
        for _, b0 in ipairs(dotsBefore) do
            local d = math.sqrt((b0.x - x) ^ 2 + (b0.z - z) ^ 2)
            if d <= 1 and (bd == nil or d < bd) then bd = d end
        end
        return bd
    end
    --- A point folded into w: one that stood within 0.5 m of it - before the clear, or where the
    --- clear took it out - is gone now, and brought links w did not have. Returns how far apart the
    --- two stood, or nil. Where it was taken out counts too: at 30 the tidy moved a point of each
    --- kept road to 0.28 m from the other's, and the final sweep folded the two into one.
    local goneAt, respaceLinks = {}, {}
    for _, e in ipairs(C.journal) do
        if e.op == "remove" then goneAt[e.a] = e end
        if e.op == "out+" and e.respace and e.b ~= nil then
            respaceLinks[e.a] = respaceLinks[e.a] or {}
            respaceLinks[e.a][e.b] = true
        end
    end
    C.respaceLinks = respaceLinks
    --- The points folded into w, gone now, with how far apart the two stood when folded. Not how far
    --- apart they stood before the clear: the respacing slides a lane's points along it, and at 30 the
    --- two folded there had stood 30 m apart. `bringing`: only those that brought links w did not have.
    local function folds(w, bringing)
        local b0 = before[w]
        local list = {}
        if b0 == nil then return list end
        local mine = { [w] = true }
        for _, lst in ipairs({ b0.out, b0.inn }) do
            for _, t in ipairs(lst) do mine[t] = true end
        end
        for _, g in ipairs(goneBefore) do
            local d = math.sqrt((g.b.x - b0.x) ^ 2 + (g.b.z - b0.z) ^ 2)
            local e = goneAt[g.w]
            if e ~= nil then d = math.min(d, math.sqrt((e.x - w.x) ^ 2 + (e.z - w.z) ^ 2)) end
            if d <= 0.5 then
                local brings = false
                for _, lst in ipairs({ g.b.out, g.b.inn }) do
                    for _, t in ipairs(lst) do
                        if not mine[t] and t ~= g.w then brings = true end
                    end
                end
                if brings or not bringing then list[#list + 1] = { w = g.w, d = d } end
            end
        end
        return list
    end
    C.folds = folds
    --- The points of the network before the clear that w stands for now: itself, when it was there,
    --- and every point gone now that stood within 0.5 m of it - before the clear, or where the clear
    --- took it out. A point the clear laid on the spot of one it took out stands for that one.
    function C.standsFor(w)
        local list, b0 = {}, before[w]
        if b0 ~= nil then list[1] = w end
        for _, g in ipairs(goneBefore) do
            local d = math.sqrt((g.b.x - w.x) ^ 2 + (g.b.z - w.z) ^ 2)
            if b0 ~= nil then d = math.min(d, math.sqrt((g.b.x - b0.x) ^ 2 + (g.b.z - b0.z) ^ 2)) end
            local e = goneAt[g.w]
            if e ~= nil then d = math.min(d, math.sqrt((e.x - w.x) ^ 2 + (e.z - w.z) ^ 2)) end
            if d <= 0.5 then list[#list + 1] = g.w end
        end
        return list
    end
    function C.foldedInto(w)
        local bd = nil
        for _, f in ipairs(folds(w, true)) do
            if bd == nil or f.d < bd then bd = f.d end
        end
        return bd
    end
    return C
end

--- THE JUNCTION'S ROADS AND LANES, AS THEY LIE NOW. Which road a drive came in on and went out on
--- is read off the clear's own lanes (its approaches), not off bearings: a road's two lanes can
--- leave the middle 40 degrees apart (10's west road read as two roads, and its own stub as joining
--- it), and 40 m out a bending road lies off its own arm (62's west road read as its south one).
--- Each lane is walked from its far end in towards the middle, the way it is driven, keeping to the
--- straightest way on, until it has passed through the middle; every point it runs over is that
--- lane's. EVERY approach, including those the clear set aside as a duplicate or a loose piece
--- (ap._debris): the shadow rule also catches a short arm lined up with the opposite arm of a
--- straight road, and at 16 that hid the whole east road - both ends of two kept through roads -
--- so a join onto it could not be seen.
---
--- Each lane also belongs to one ROAD, named once. Lanes are one road when they lie side by side:
--- read where each lane is exactly 30 m from the middle (or as far out as it goes), within 20
--- degrees of each other seen from the middle and within 7 m across. Not by the arms the selection
--- found: those fold roads within 30 degrees into one, which put both branches of 36's Y on one
--- road, so a turn from one branch to the other would have read as a U-turn. And not from where a
--- drive happened to leave a lane: named that way, 16's south-south-east road was "south" in one
--- line and "south-east" in the next, and a U-turn on its north-west road read as a join between
--- two roads.
--- Known and left: a lane that goes less than 30 m out is read where it stops, and that close in
--- two lanes 5 m apart are more than 20 degrees apart seen from the middle. Every road of 68's grid
--- (read 7 to 8 m out) reads as two roads, so its U-turns read as joins between two, and 67's east
--- road (read 13 and 10 m out) as "east" and "east-south-east". 67 and 68 are test leftovers
--- (truth_types.txt skips them). The one real road still read as two is 22's west road, which loops
--- through a hairpin: the clear followed its lane out only 27 m out, and there it lies 11 m across
--- from where its lane in is read, 30 m out, so it is "south-west" and "south". Neither is worth a rule
--- that every real junction would have to be checked against.
local JX_WORD16 = { "north", "north-north-east", "north-east", "east-north-east", "east", "east-south-east",
                    "south-east", "south-south-east", "south", "south-south-west", "south-west",
                    "west-south-west", "west", "west-north-west", "north-west", "north-north-west" }
local function jxCheckLanes(C)
    local jp, cx, cz = C.jp, C.cx, C.cz
    local approaches = (jp ~= nil and jp.approaches) or {}
    C.approaches = approaches

    -- A point two lanes run over belongs to the one whose own end it is nearest, along the lane. Each
    -- walk carries on through the middle and out the far side, so the lane leaving 68's grid walked
    -- back up to where the lane coming in starts, 7.5 m out, and that lane's drive was named after
    -- the far side's road ("the lane starting on the east-south-east", for a lane in from the west).
    -- Each walk's points are kept in order (walked), for reading where the lane lies 30 m out.
    local inLane, outLane, inRun, outRun = {}, {}, {}, {}
    local walked = {}
    for idx, ap in ipairs(approaches) do
        local A = ap.wp
        if A ~= nil and C.live[A] then
            local fwd = (ap.dir == "in")
            local mark, runAt = outLane, outRun
            if fwd then mark, runAt = inLane, inRun end
            local hx, hz = cx - A.x, cz - A.z
            local hl = math.sqrt(hx * hx + hz * hz)
            if hl > 1e-6 then hx, hz = hx / hl, hz / hl end
            local cur, seen, entered = A, { [A] = true }, C.inMid[A] == true
            local run = 0
            local seq = { A }
            walked[idx] = seq
            if runAt[A] == nil or run < runAt[A] then mark[A], runAt[A] = idx, run end
            for _ = 1, 300 do
                local best, bd = nil, -math.huge
                local lst = cur.incoming or {}
                if fwd then lst = cur.out or {} end
                for _, id in ipairs(lst) do
                    local t = C.node(id)
                    if t ~= nil and t ~= cur and not seen[t] then
                        local dx, dz = t.x - cur.x, t.z - cur.z
                        local l = math.sqrt(dx * dx + dz * dz)
                        if l > 1e-6 and (dx * hx + dz * hz) / l > bd then bd, best = (dx * hx + dz * hz) / l, t end
                    end
                end
                if best == nil or bd < 0.3 then break end
                hx, hz = jxHeading(cur, best)
                run = run + math.sqrt((best.x - cur.x) ^ 2 + (best.z - cur.z) ^ 2)
                cur = best
                seen[cur] = true
                seq[#seq + 1] = cur
                if runAt[cur] == nil or run < runAt[cur] then mark[cur], runAt[cur] = idx, run end
                if C.inMid[cur] then entered = true elseif entered then break end
            end
        end
    end
    C.inLane, C.outLane, C.inRun, C.outRun = inLane, outLane, inRun, outRun

    -- Where each lane lies 30 m out: exactly 30 m, where the lane crosses that distance from the
    -- middle - not at its first point past it, which on a road with sparse points lies 44-50 m out,
    -- and a lane read 30 m out beside its partner read 44 m out is more than 7 m across from it.
    -- Read on the lane as the walk found it, coming in from its far end; only a lane whose walk does
    -- not cross 30 m is read off the clear's own run of it (ap.runPath), as far as that goes. Read
    -- off the run alone, a long link of the old network (37 m at 30's north-east road, 28 m at 63's
    -- south-east road) cut the corner of a bend the lane now follows. Between them, 1, 29, 30, 34,
    -- 46 and 63 each read one road as two, so a U-turn on it would have read as a join between two.
    local function at30(p, q)
        -- where the line from p (inside 30 m) to q (outside) crosses 30 m from the middle
        local dx, dz, fx, fz = q.x - p.x, q.z - p.z, p.x - cx, p.z - cz
        local a, b, c = dx * dx + dz * dz, 2 * (fx * dx + fz * dz), fx * fx + fz * fz - 900
        local t = 1
        if a > 1e-9 and b * b - 4 * a * c >= 0 then
            t = math.max(0, math.min(1, (-b + math.sqrt(b * b - 4 * a * c)) / (2 * a)))
        end
        return p.x + dx * t, p.z + dz * t
    end
    local spot = {}
    for idx, ap in ipairs(approaches) do
        local sx, sz = nil, nil
        local seq = walked[idx] or {}
        for k = 2, #seq do
            if C.dist(seq[k]) < 30 and C.dist(seq[k - 1]) >= 30 then
                sx, sz = at30(seq[k], seq[k - 1])
                break
            end
        end
        if sx == nil then
            local p, q = nil, nil
            for _, w in ipairs(ap.runPath or {}) do
                if C.dist(w) >= 30 then
                    q = w
                    break
                end
                p = w
            end
            if p ~= nil and q ~= nil then
                sx, sz = at30(p, q)
            else
                local w = q or p or ap.wp
                if w ~= nil then sx, sz = w.x, w.z end
            end
        end
        if sx ~= nil and (sx - cx) ^ 2 + (sz - cz) ^ 2 > 1e-6 then
            spot[idx] = { x = sx, z = sz, b = math.atan2(sx - cx, sz - cz) }
        end
    end
    C.laneSpots = spot
    local apRoad, roads = {}, {}
    for idx = 1, #approaches do
        local s1 = spot[idx]
        if s1 ~= nil then
            for j = 1, idx - 1 do
                local s2 = spot[j]
                if apRoad[idx] == nil and s2 ~= nil and junctionAngDiff(s1.b, s2.b) <= math.rad(20) then
                    local across = math.abs((s2.x - cx) * math.cos(s1.b) - (s2.z - cz) * math.sin(s1.b))
                    if across <= 7 then apRoad[idx] = apRoad[j] end
                end
            end
            if apRoad[idx] == nil then
                roads[#roads + 1] = { sx = 0, sz = 0 }
                apRoad[idx] = #roads
            end
            local r = roads[apRoad[idx]]
            r.sx, r.sz = r.sx + math.sin(s1.b), r.sz + math.cos(s1.b)
        end
    end
    -- Named by compass point; where two roads would share a name, both get the finer one.
    local function name8(r) return JX_WORD[jxCompass(r.sx, r.sz)] or "?" end
    local function name16(r)
        local b = math.deg(math.atan2(r.sx, -r.sz)) % 360
        return JX_WORD16[math.floor((b + 11.25) / 22.5) % 16 + 1]
    end
    local used = {}
    for _, r in ipairs(roads) do
        r.name = name8(r)
        used[r.name] = (used[r.name] or 0) + 1
    end
    for _, r in ipairs(roads) do
        if used[r.name] > 1 then r.name = name16(r) end
    end
    C.roads, C.apRoad = roads, apRoad
    function C.roadName(idx)
        local r = apRoad[idx]
        if r ~= nil then return roads[r].name end
        local ap = approaches[idx]
        if ap ~= nil and ap.wp ~= nil then return C.wordAt(ap.wp.x, ap.wp.z) end
        return "?"
    end
end

--- The drive from A to B as the network stands: the shortest by length, over points within `lim` of
--- the middle and, when a line is given, within `corridor` metres of it. Returns the points of the
--- drive in order, or nil and every point it could reach (in the order it reached them).
--- `old`: drive the network as it was before the clear instead (C.before), where it stood then.
local function jxDrive(C, A, B, pts, corridor, lim, old)
    local before = C.before
    local function at(t)
        if old then return before[t] end
        return t
    end
    local function outs(w)
        if old then return before[w].out end
        local list = {}
        for _, id in ipairs(w.out or {}) do
            local t = C.node(id)
            if t ~= nil then list[#list + 1] = t end
        end
        return list
    end
    local near = {}
    local function allowed(t)
        local p = at(t)
        if p == nil or C.dist(p) > lim then return false end
        if pts == nil then return true end
        if near[t] == nil then near[t] = (jxOnLine(pts, p.x, p.z) <= corridor) end
        return near[t]
    end
    local best, prev, done = { [A] = 0 }, {}, {}
    local open, reached = { A }, { A }
    while #open > 0 do
        local bi = 1
        for i = 2, #open do
            local a, b = open[i], open[bi]
            if best[a] < best[b] or (best[a] == best[b] and jxByPos(at(a), at(b))) then bi = i end
        end
        local w = table.remove(open, bi)
        if w == B then break end
        if not done[w] then
            done[w] = true
            local pw = at(w)
            for _, t in ipairs(outs(w)) do
                if t ~= w and not done[t] and allowed(t) then
                    local pt = at(t)
                    local d = best[w] + math.sqrt((pt.x - pw.x) ^ 2 + (pt.z - pw.z) ^ 2)
                    if best[t] == nil then
                        best[t], prev[t] = d, w
                        open[#open + 1] = t
                        reached[#reached + 1] = t
                    elseif d < best[t] then
                        best[t], prev[t] = d, w
                    end
                end
            end
        end
    end
    if best[B] == nil then return nil, reached end
    local path, w = {}, B
    while w ~= nil do
        table.insert(path, 1, w)
        w = prev[w]
    end
    return path, reached
end

--- Do the segments p1-p2 and p3-p4 cross (not merely touch)?
local function jxSegmentsCross(p1, p2, p3, p4)
    local function side(a, b, c) return (b.x - a.x) * (c.z - a.z) - (b.z - a.z) * (c.x - a.x) end
    local d1, d2 = side(p3, p4, p1), side(p3, p4, p2)
    local d3, d4 = side(p1, p2, p3), side(p1, p2, p4)
    return ((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0)) and ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0))
end

--- EVERY ROAD THROUGH THE JUNCTION, read off the network as it was before the clear. The clear's own
--- list of through roads misses some: it is built from its approaches, and a lane whose end was set
--- aside (ap._debris) or never found has no route. 65's and 39's south-east-bound main-road lanes
--- were cut with through roads kept, and nothing said so. So every lane that comes into the
--- junction is driven on from where it enters, straight on at every fork, until it leaves again
--- past the middle. Each such drive is a PASSAGE, with how far it turned, whether it met a fork in
--- the middle, and whether it crossed another of the junction's lanes without sharing a point
--- with it - a road that runs across the junction without joining it, like the loop road over 67.
local function jxCheckPassages(C)
    local before, cx, cz = C.before, C.cx, C.cz
    local entries, links = {}, {}
    for w, b0 in pairs(before) do
        if (b0.x - cx) ^ 2 + (b0.z - cz) ^ 2 <= 100 * 100 then
            local inside = C.inArea(b0.x, b0.z)
            for _, t in ipairs(b0.out) do
                local b1 = before[t]
                if b1 ~= nil and t ~= w and C.inArea(b1.x, b1.z) then
                    if inside then
                        links[#links + 1] = { a = w, b = t, pa = b0, pb = b1 }
                    else
                        entries[#entries + 1] = { u = w, v = t, pu = b0, pv = b1 }
                    end
                end
            end
        end
    end
    table.sort(entries, function(p, q)
        if p.pv.x ~= q.pv.x then return p.pv.x < q.pv.x end
        if p.pv.z ~= q.pv.z then return p.pv.z < q.pv.z end
        if p.pu.x ~= q.pu.x then return p.pu.x < q.pu.x end
        if p.pu.z ~= q.pu.z then return p.pu.z < q.pu.z end
        return (p.pu.y or 0) < (q.pu.y or 0)
    end)
    local function isFork(w)
        local b0, seen, n = before[w], {}, 0
        for _, lst in ipairs({ b0.out, b0.inn }) do
            for _, t in ipairs(lst) do
                if t ~= w and not seen[t] then seen[t] = true n = n + 1 end
            end
        end
        return n >= 3
    end
    local passages = {}
    for _, e in ipairs(entries) do
        local path, P = { e.u, e.v }, { e.pu, e.pv }
        local seen = { [e.u] = true, [e.v] = true }
        local hx, hz = jxHeading(e.pu, e.pv)
        local cur, mid, out = e.v, C.inMiddle(e.pv.x, e.pv.z), false
        if hx ~= nil then
            for _ = 1, 300 do
                local bc = before[cur]
                local best, bd = nil, -math.huge
                for _, t in ipairs(bc.out) do
                    local bt = before[t]
                    if bt ~= nil and t ~= cur and not seen[t] then
                        local dx, dz = bt.x - bc.x, bt.z - bc.z
                        local l = math.sqrt(dx * dx + dz * dz)
                        if l > 1e-6 and (dx * hx + dz * hz) / l > bd then bd, best = (dx * hx + dz * hz) / l, t end
                    end
                end
                if best == nil or bd < 0.3 then break end
                local bb = before[best]
                hx, hz = jxHeading(bc, bb)
                path[#path + 1], P[#P + 1] = best, bb
                seen[best] = true
                cur = best
                if C.inMiddle(bb.x, bb.z) then mid = true end
                if not C.inArea(bb.x, bb.z) then
                    out = mid
                    break
                end
            end
        end
        if out then
            -- How far it turned: its heading over the first 6 m against its heading over the last 6.
            local k, j = 2, #P - 1
            while k < #P and (P[k].x - P[1].x) ^ 2 + (P[k].z - P[1].z) ^ 2 < 36 do k = k + 1 end
            while j > 1 and (P[#P].x - P[j].x) ^ 2 + (P[#P].z - P[j].z) ^ 2 < 36 do j = j - 1 end
            local ax, az = jxHeading(P[1], P[k])
            local bx, bz = jxHeading(P[j], P[#P])
            if ax ~= nil and bx ~= nil then
                local turn = math.deg(math.acos(math.max(-1, math.min(1, ax * bx + az * bz))))
                local fork, forkInArea, crosses = false, false, false
                local onIt = {}
                for i, w in ipairs(path) do
                    onIt[w] = true
                    if i > 1 and i < #path and isFork(w) then
                        forkInArea = true
                        if C.inMiddle(P[i].x, P[i].z) then fork = true end
                    end
                end
                if not forkInArea then
                    for i = 1, #path - 1 do
                        for _, l in ipairs(links) do
                            if not onIt[l.a] and not onIt[l.b] and jxSegmentsCross(P[i], P[i + 1], l.pa, l.pb) then
                                crosses = true
                                break
                            end
                        end
                        if crosses then break end
                    end
                end
                passages[#passages + 1] = { path = path, pts = P, A = e.u, B = path[#path], turn = turn,
                                            noFork = not fork, unjoined = crosses }
            end
        end
    end
    C.passages = passages
end

--- THE ROADS THAT MUST STILL DRIVE, AND HOW THEY DRIVE NOW. With through roads kept: the clear's own
--- through roads, every passage that turned 40 degrees or less, and every passage that met no fork
--- in the middle. Either way: a road that crossed the junction without joining it. Each is driven
--- again, A to B, along its own line (within 2.5 m of where it ran): the links of those drives are
--- the KEPT links, and where two of them cross at a shared point is a crossing of kept roads. A
--- road that no longer drives from A to B by any way at all is cut.
local function jxCheckKept(C)
    local kept = {}
    if C.leave then
        for _, L in ipairs(C.lines) do
            kept[#kept + 1] = { pts = L.pts, A = L.first, B = L.last, kind = "own" }
        end
    end
    for _, p in ipairs(C.passages or {}) do
        local want = nil
        if p.unjoined then
            want = "unjoined"
        elseif C.leave and (p.turn <= 40 or p.noFork) then
            want = "straight"
        end
        -- A passage the clear's own through roads already cover, at its way in or its way out, is
        -- left to them: they say which way that lane goes on, and at a Y the straightest way on is
        -- not always the through road (36's north road runs straight into its side branch).
        if want ~= nil then
            local n = #p.pts
            for _, L in ipairs(C.lines) do
                local function on(q) return jxOnLine(L.pts, q.x, q.z) <= 2.5 end
                if (on(p.pts[1]) and on(p.pts[2])) or (on(p.pts[n - 1]) and on(p.pts[n])) then want = nil break end
            end
        end
        if want ~= nil then kept[#kept + 1] = { pts = p.pts, A = p.A, B = p.B, kind = want } end
    end
    local keptLinks, keptAt, broken = {}, {}, {}
    C.detours = 0
    for k, item in ipairs(kept) do
        local A, B = item.A, item.B
        if not C.live[A] or not C.live[B] then
            local gw = A
            if C.live[A] then gw = B end
            broken[#broken + 1] = { item = item, x = gw.x, z = gw.z, lost = true }
        else
            local lim = math.max(C.dist(A), C.dist(B)) + 20
            local path, along = jxDrive(C, A, B, item.pts, 2.5, lim)
            if path ~= nil then
                for i = 1, #path - 1 do
                    local a, b = path[i], path[i + 1]
                    keptLinks[a] = keptLinks[a] or {}
                    keptLinks[a][b] = keptLinks[a][b] or {}
                    keptLinks[a][b][k] = true
                end
                for i, w in ipairs(path) do
                    local hx, hz = jxHeading(path[math.max(1, i - 1)], path[math.min(#path, i + 1)])
                    if hx ~= nil then
                        keptAt[w] = keptAt[w] or {}
                        keptAt[w][#keptAt[w] + 1] = { k = k, hx = hx, hz = hz }
                    end
                end
            else
                -- Where it stops along its own line: of everything still reached, the point
                -- furthest along it. Then whether it still gets there at all, by some other way: a
                -- road that only gets through by leaving its own line - across a crossing, down a
                -- turn and back - is not the road it was. Over all 68 junctions no kept road needed
                -- that, so it is said rather than allowed.
                local stop, far = A, -1
                for _, p in ipairs(along) do
                    local d, s = jxOnLine(item.pts, p.x, p.z)
                    if d <= 4 and (s > far or (s == far and jxByPos(p, stop))) then far, stop = s, p end
                end
                local any = jxDrive(C, A, B, nil, nil, lim)
                if any ~= nil then C.detours = C.detours + 1 end
                broken[#broken + 1] = { item = item, x = stop.x, z = stop.z, detour = (any ~= nil) }
            end
        end
    end
    C.kept, C.keptLinks, C.keptAt, C.broken = kept, keptLinks, keptAt, broken
    --- A point where two kept roads cross: it lies on both, and they head more than 30 degrees
    --- apart there. The two lanes of one road never qualify - they run opposite ways. Returns the
    --- two roads' entries there (which road, and its heading), or nil.
    function C.crossPair(w)
        local list = keptAt[w]
        if list == nil then return nil end
        for i = 1, #list do
            for j = i + 1, #list do
                if list[i].k ~= list[j].k
                    and math.abs(list[i].hx * list[j].hx + list[i].hz * list[j].hz) < math.cos(math.rad(30)) then
                    return list[i], list[j]
                end
            end
        end
        return nil
    end
    function C.crossing(w) return C.crossPair(w) ~= nil end
    --- DID THE TWO KEPT ROADS ALREADY SHARE THIS POINT BEFORE THE CLEAR? Each must have run through
    --- it then: a link into or out of it, lying on that road's line and heading its way. At 16 they
    --- did not - each road had a point of its own, 0.06 to 0.22 m from the other's, and the clean-up
    --- folded each pair into one - so "still joins where they cross" was wrong there: the clear had
    --- joined them. At 64 and 68 the roads shared the point all along.
    function C.sharedBefore(w)
        local e1, e2 = C.crossPair(w)
        local b0 = C.before[w]
        if e1 == nil or b0 == nil then return false end
        local sep = math.deg(math.acos(math.min(1, math.abs(e1.hx * e2.hx + e1.hz * e2.hz))))
        local tol = math.cos(math.rad(math.min(25, sep / 2)))
        for _, e in ipairs({ e1, e2 }) do
            local line, found = kept[e.k].pts, false
            for _, f in ipairs(b0.inn) do
                local bf = C.before[f]
                local hx, hz = nil, nil
                if bf ~= nil then hx, hz = jxHeading(bf, b0) end
                if hx ~= nil and hx * e.hx + hz * e.hz >= tol and jxOnLine(line, bf.x, bf.z) <= 2.5 then found = true end
            end
            for _, t in ipairs(b0.out) do
                local bt = C.before[t]
                local hx, hz = nil, nil
                if bt ~= nil then hx, hz = jxHeading(b0, bt) end
                if hx ~= nil and hx * e.hx + hz * e.hz >= tol and jxOnLine(line, bt.x, bt.z) <= 2.5 then found = true end
            end
            if not found then return false end
        end
        return true
    end
    --- HOW CLOSE THE TWO KEPT ROADS CAME, BEFORE THE CLEAR, where they now share w: the nearest two
    --- points, one on each road's line, within 2 m of w. Nil when either road had none there. At 30
    --- they came within 0.75 m; the clear then moved a point of each to 0.28 m and folded the two,
    --- and "0.28 m apart" alone read as if they had stood that close all along.
    function C.crossGapBefore(w)
        local e1, e2 = C.crossPair(w)
        if e1 == nil then return nil end
        local l1, l2 = kept[e1.k].pts, kept[e2.k].pts
        local on1, on2 = {}, {}
        for v, b0 in pairs(C.before) do
            if (b0.x - w.x) ^ 2 + (b0.z - w.z) ^ 2 <= 4 then
                if jxOnLine(l1, b0.x, b0.z) <= 0.5 then on1[#on1 + 1] = v end
                if jxOnLine(l2, b0.x, b0.z) <= 0.5 then on2[#on2 + 1] = v end
            end
        end
        local bd = nil
        for _, p in ipairs(on1) do
            for _, q in ipairs(on2) do
                if p ~= q then
                    local bp, bq = C.before[p], C.before[q]
                    local d = math.sqrt((bp.x - bq.x) ^ 2 + (bp.z - bq.z) ^ 2)
                    if bd == nil or d < bd then bd = d end
                end
            end
        end
        return bd
    end
    function C.keptLink(a, b)
        return keptLinks[a] ~= nil and keptLinks[a][b] ~= nil
    end
end

--- ONE LANE THAT SPLITS AND JOINS ITSELF AGAIN is a merge to AutoDrive too, and is drawn teal, but
--- no second road comes into it: two of the ways in lead back, within a few points, to the same
--- point. At 2 a lane carried a link that skipped one of its own points, 10 m from the middle.
--- Said as what it is, so it is not taken for a missed turn. `old`: asked of the network as it was
--- before the clear - at 2 the self-join was what the clear left of a turn meeting the lane (its
--- clean-up folded the turn's point into the lane's), not something that was there already.
local function jxSelfJoin(C, w, old)
    local before = C.before
    local function inc(v)
        if old then return (before[v] and before[v].inn) or {} end
        local list = {}
        for _, id in ipairs(v.incoming or {}) do
            local t = C.node(id)
            if t ~= nil then list[#list + 1] = t end
        end
        return list
    end
    local function at(v)
        if old then return before[v] end
        return v
    end
    if old and before[w] == nil then return false end
    local back = {}
    for _, f in ipairs(inc(w)) do
        if f ~= w then
            local seen, cur, run = { [f] = true }, f, 0
            for _ = 1, 4 do
                local list = inc(cur)
                if #list ~= 1 then break end
                local p = list[1]
                if p == w or seen[p] then break end
                local pp, pc = at(p), at(cur)
                run = run + math.sqrt((pp.x - pc.x) ^ 2 + (pp.z - pc.z) ^ 2)
                if run > 15 then break end
                seen[p] = true
                cur = p
            end
            back[#back + 1] = seen
        end
    end
    -- The point the two ways in split from, for the log: the nearest such point to w, so the same
    -- one is named every run (the sets are keyed by points, and pairs() runs in address order).
    local found, fd = nil, math.huge
    for i = 1, #back do
        for j = i + 1, #back do
            for p in pairs(back[i]) do
                if back[j][p] then
                    local pp, pw = at(p), at(w)
                    local d = (pp.x - pw.x) ^ 2 + (pp.z - pw.z) ^ 2
                    if found == nil or d < fd or (d == fd and jxByPos(pp, at(found))) then found, fd = p, d end
                end
            end
        end
    end
    if found ~= nil then return true, found end
    return false
end

--- THE END OF A TURN THE CLEAR CUT, STILL JOINED TO A LANE: a way into a teal dot that leads back,
--- point by point and without a fork, at most 15 m, to a start nothing feeds any more - though
--- something did before the clear, or the clear laid it - and that is none of this junction's own
--- lanes (a lane leaving the junction starts like that on purpose). At 36 the clear took most of
--- the side road's turn but left its last 2 points, 2.6 m, fed by nothing and still joined to the
--- main lane 15 m out: a teal dot past the junction's edge, which the check, looking no further
--- than the edge, passed as "middle empty". Not a longer stretch, nor one that forks: that is a
--- lane the clear cut, not a turn's end - at 39 the main road's lane, 24 m to where it merges with
--- the next road (already said, as a road cut), and at 20 a stub that forks into the next part's
--- own two turns. Returns where that stretch starts, or nil.
---
--- NOR ONE OF THIS CLEAR'S OWN THROUGH ROADS, CUT AT THE BOX. With through roads off every through
--- road is cut where it meets the box and its leg out is left starting loose, on purpose - that is
--- what "off" asks for. At 39 the south-to-north road leaves the box and, 10 m on, merges into
--- 39se's lane: its leg is fed by nothing now and still joins that lane, which read exactly like a
--- turn's end. The lane walk that marks the lanes out (C.outLane) cannot tell, because at the merge
--- it follows 39se's lane, the straighter way back. The through roads as they lay before the clear
--- (C.lines) can: a stretch lying along one of them, all of it within 2.5 m, is that road's leg.
--- Then the second value is where the leg starts, so the dot can be said for what it is.
local function jxTail(C, w)
    local function alongThrough(stretch)
        if C.leave then return false end
        for _, L in ipairs(C.lines or {}) do
            local all = true
            for _, q in ipairs(stretch) do
                if jxOnLine(L.pts, q.x, q.z) > 2.5 then all = false break end
            end
            if all then return true end
        end
        return false
    end
    for _, id in ipairs(w.incoming or {}) do
        local f = C.node(id)
        if f ~= nil and f ~= w then
            local cur, run, seen = f, math.sqrt((f.x - w.x) ^ 2 + (f.z - w.z) ^ 2), { [w] = true, [f] = true }
            local stretch = { w, f }
            for _ = 1, 40 do
                if run > 15 or #(cur.out or {}) ~= 1 then break end
                local inc = cur.incoming or {}
                if #inc == 0 then
                    local b0 = C.before[cur]
                    if (b0 == nil or #b0.inn > 0) and C.inLane[cur] == nil and C.outLane[cur] == nil then
                        if alongThrough(stretch) then return nil, cur end
                        return cur
                    end
                    break
                end
                if #inc ~= 1 then break end
                local p = C.node(inc[1])
                if p == nil or seen[p] then break end
                run = run + math.sqrt((p.x - cur.x) ^ 2 + (p.z - cur.z) ^ 2)
                seen[p] = true
                stretch[#stretch + 1] = p
                cur = p
            end
        end
    end
    return nil
end

--- THE DRIVE CARRIED ON TO WHAT WAS THERE BEFORE, for jxJoinWas: each end carried on the way it is
--- driven to the first point that was there before the clear - straight on at a fork, the same
--- point first on a tie, up to 80 m (the respacing re-lays up to 50 m of a lane). An end that
--- reaches no old point is left as it was.
local function jxOnToOld(C, path)
    local before = C.before
    local P, on = {}, {}
    for i, p in ipairs(path) do
        P[i] = p
        on[p] = true
    end
    local function carry(fwd)
        local added, run = {}, 0
        for _ = 1, 200 do
            local cur = P[1]
            if fwd then cur = P[#P] end
            if before[cur] ~= nil then return end
            local prev = P[2]
            if fwd then prev = P[#P - 1] end
            local hx, hz = nil, nil
            if prev ~= nil then
                if fwd then hx, hz = jxHeading(prev, cur) else hx, hz = jxHeading(cur, prev) end
            end
            local lst = cur.incoming or {}
            if fwd then lst = cur.out or {} end
            local best, bd = nil, -math.huge
            for _, id in ipairs(lst) do
                local t = C.node(id)
                if t ~= nil and t ~= cur and not on[t] then
                    local dx, dz
                    if fwd then dx, dz = jxHeading(cur, t) else dx, dz = jxHeading(t, cur) end
                    if dx ~= nil then
                        local c = 1
                        if hx ~= nil then c = dx * hx + dz * hz end
                        if best == nil or c > bd or (c == bd and jxByPos(t, best)) then bd, best = c, t end
                    end
                end
            end
            if best == nil or bd < 0.3 then break end
            run = run + math.sqrt((best.x - cur.x) ^ 2 + (best.z - cur.z) ^ 2)
            if run > 80 then break end
            on[best] = true
            added[#added + 1] = best
            if fwd then P[#P + 1] = best else table.insert(P, 1, best) end
        end
        -- Reached no old point: put back as it was.
        for _, w in ipairs(added) do
            on[w] = nil
            if fwd then table.remove(P) else table.remove(P, 1) end
        end
    end
    carry(true)
    carry(false)
    return P
end

--- How far a drive turns at point a, coming from p and going on to b, in radians; 0 where a link has
--- no length or there is no point on one side.
local function jxTurnAt(p, a, b)
    if p == nil or a == nil or b == nil then return 0 end
    local ax, az = jxHeading(p, a)
    local bx, bz = jxHeading(a, b)
    if ax == nil or bx == nil then return 0 end
    return math.acos(math.max(-1, math.min(1, ax * bx + az * bz)))
end

--- WAS THIS JOIN THERE BEFORE THE CLEAR? A join that was not is not one the clear missed: it is new,
--- and is said so - a link put in at 8 after the clear read "still joins ... a connection the clear
--- missed", and its teal dot "a connection the clear missed; the clear made it". Two questions:
--- 1. Does it use a link that was not there before, between two points that were? That link is
---    new, whatever else drove there. Not one the respacing laid, nor a kept road's: a lane's own
---    links are re-laid by the respacing all the time, bridging over the points it takes out. And a
---    link the clean-up only moved, by folding a point into its neighbour, counts as the old link
---    (40e's turn). Not asked by which lane a point is on: those are read off the network as it is
---    now, and a lane walked on over the new link at 8 took the main road's lane for its own.
--- 1b. Does it use a link to a point the clear laid, that is neither the respacing's nor a kept
---    road's? Asking only of links between two old points let a join made that way read "still
---    joins ... a connection the clear missed" - and the tidy re-lays the lane ends at most
---    junctions, so a tidy that wired one stub to another would have been named a miss. A laid
---    point stands for any old point it was laid on (within 0.5 m of where that one stood, or of
---    where the clear took it out); the link is old only when one of those carried it. Not "did a
---    drive run near there": at 20, with through roads not kept, an old turn had run within 2 m of
---    where the south road's stub was wired to the east road's (dbgcheck.lua WIRE=1), and that
---    passed the wiring off as a missed turn. Only links between the first and last old points of
---    the drive: before them, or after, is a lane's own end, re-laid where it starts or stops. And
---    the drive is first carried on along its lanes, at both ends, to the first point that was there
---    before (jxOnToOld): the respacing re-lays a lane out for up to 50 m, so at 38, 58, 63 and 65,
---    with through roads not kept, every point after the wired link was laid, the drive's last old
---    point was on the lane coming in, and a tidy that wired the two lanes together read "still
---    joins ... a connection the clear missed". Carried on, the wired link lies between old points.
---    The link named is the one the drive turns most at, at its two ends: the lanes' own re-laid
---    ends run straight on, and the link that joins two lanes is where the drive changes road
---    (dbgcheck.lua WIRE=1 at every junction, both ways: the wired link turned most every time).
--- 1c. Does it change road at a point the clean-up folded another into? Each of its two links can
---    have been there before - one into each of the two points - while no drive went from one to
---    the other, because they were two points. At 30, with through roads kept, the lane in from the
---    south-west ran 0.13 m past the last point of a turn onto the south-east road; the clean-up
---    folded the two points into one, so the lane now drives on over that turn's last link and out
---    to the south-east: "a connection the clear missed", said of a join the clear's own clean-up
---    made.
--- 2. Otherwise, did it drive before, along the same line (within 3 m of it), between the first and
---    last of its points that were there then?
--- Returns whether it was there, and when that is why not, the new link's two ends, or the point
--- where the fold joined two ways.
local function jxJoinWas(C, path)
    path = jxOnToOld(C, path)
    local before = C.before
    local function near(p, q) return p ~= nil and q ~= nil and (p.x - q.x) ^ 2 + (p.z - q.z) ^ 2 <= 0.25 end
    local function linkedBefore(a, b)
        local ba, bb = before[a], before[b]
        for _, t in ipairs(ba.out) do
            if t == b or (not C.live[t] and (near(before[t], b) or near(before[t], bb))) then return true end
        end
        for _, f in ipairs(bb.inn) do
            if f == a or (not C.live[f] and (near(before[f], a) or near(before[f], ba))) then return true end
        end
        return false
    end
    local function relaid(a, b) return C.respaceLinks[a] ~= nil and C.respaceLinks[a][b] == true end
    for i = 1, #path - 1 do
        local a, b = path[i], path[i + 1]
        if before[a] ~= nil and before[b] ~= nil and not relaid(a, b) and not C.keptLink(a, b)
            and not linkedBefore(a, b) then
            return false, a, b
        end
    end
    -- 1b: links touching a point the clear laid, between the first and last old points of the drive.
    local firstOld, lastOld = nil, nil
    for k = 1, #path do
        if before[path[k]] ~= nil then
            firstOld = firstOld or k
            lastOld = k
        end
    end
    if firstOld ~= nil then
        local la, lb, lt = nil, nil, -1
        for k = firstOld, lastOld - 1 do
            local a, b = path[k], path[k + 1]
            if (before[a] == nil or before[b] == nil) and not relaid(a, b) and not C.keptLink(a, b) then
                local was = false
                local sb = C.standsFor(b)
                for _, a0 in ipairs(C.standsFor(a)) do
                    for _, t in ipairs(before[a0].out) do
                        for _, b0 in ipairs(sb) do
                            if t == b0 then was = true end
                        end
                    end
                end
                -- Named by the link the drive turns most at: that is where two ways were wired
                -- together, not where a lane's own end was re-laid straight on.
                if not was then
                    local turn = jxTurnAt(path[k - 1], a, b) + jxTurnAt(a, b, path[k + 2])
                    if turn > lt then la, lb, lt = a, b, turn end
                end
            end
        end
        if la ~= nil then return false, la, lb end
    end
    -- 1c: where a point was folded into one the drive changes road at.
    local function counterparts(w)
        local s = { w }
        for _, f in ipairs(C.folds(w, false)) do s[#s + 1] = f.w end
        return s
    end
    local function linked(p0, w0)
        for _, t in ipairs(before[p0].out) do
            if t == w0 then return true end
        end
        return false
    end
    for k = 2, #path - 1 do
        local p, w, n = path[k - 1], path[k], path[k + 1]
        if before[p] ~= nil and before[w] ~= nil and before[n] ~= nil and not relaid(p, w) and not relaid(w, n)
            and not (C.keptLink(p, w) and C.keptLink(w, n)) and #C.folds(w, true) > 0 then
            local passed = false
            local cp, cn = counterparts(p), counterparts(n)
            -- In through one of the points and out through the other is the old drive too where
            -- the first led into the second: at 26 two ends of 26n's turns stood 0.02 m apart, one
            -- linked on into the other, and folding them joined nothing - but was said as a join
            -- the clean-up made.
            local cw = counterparts(w)
            for _, wa in ipairs(cw) do
                for _, wb in ipairs(cw) do
                    if wa == wb or linked(wa, wb) then
                        local into, onto = false, false
                        for _, p0 in ipairs(cp) do
                            if linked(p0, wa) then into = true end
                        end
                        for _, n0 in ipairs(cn) do
                            if linked(wb, n0) then onto = true end
                        end
                        if into and onto then passed = true end
                    end
                end
            end
            if not passed then return false, nil, nil, w end
        end
    end
    local A, B = nil, nil
    for i = 1, #path do
        if before[path[i]] ~= nil then A = path[i] break end
    end
    for i = #path, 1, -1 do
        if before[path[i]] ~= nil then B = path[i] break end
    end
    if A == nil or B == nil or A == B then return false end
    local pts, lim = {}, 0
    for _, p in ipairs(path) do
        pts[#pts + 1] = { x = p.x, z = p.z }
        lim = math.max(lim, C.dist(p))
    end
    -- Where only points the clear laid come before the first old point (or after the last), the
    -- drive came in (or went on) over that point or over any point folded into it: at 40, with the
    -- user's split saved and through roads off, 40e's cut lane starts 5 m before where 40w's right
    -- turn leaves it, and the pre-clear clean-up had folded the lane's point there (0.29 m from a
    -- point of a lane beside it) into one - so the turn now leaves from the point it was not wired to
    -- before, and the drive along the cut lane onto it read "a connection that did not drive before
    -- the clear" while it drove exactly so over the folded point.
    local starts, stops = { A }, { B }
    if path[1] ~= A then
        for _, g in ipairs(C.standsFor(A)) do
            if g ~= A and not C.live[g] then starts[#starts + 1] = g end
        end
    end
    if path[#path] ~= B then
        for _, g in ipairs(C.standsFor(B)) do
            if g ~= B and not C.live[g] then stops[#stops + 1] = g end
        end
    end
    for _, a0 in ipairs(starts) do
        for _, b0 in ipairs(stops) do
            if a0 ~= b0 and jxDrive(C, a0, b0, pts, 3, lim + 20, true) ~= nil then return true end
        end
    end
    return false
end

--- WHERE A DRIVE TURNS OFF ITS ROAD, and whether it only ever ran on kept roads. A drive that never
--- leaves the kept roads changes road at a point two of them share: where they cross, the known
--- case. Anything else turned off somewhere - where it left a kept road, or where it came onto one,
--- or else at its first fork. Named by the drive's own links, not by any point it passes: with
--- through roads kept every drive along a kept road passes the crossing, and a turn that left
--- 16's kept road 7 m past it was reported AT the crossing, as the known case (16; and 30, whose
--- lane only passes 0.07 m from a turn's point without using it).
--- Returns the point, and "through" (one kept road all the way), "crossing", or "turn".
local function jxTurnOf(C, path)
    local S, allK, sw, leaveAt, joinAt, sawK = nil, true, nil, nil, nil, false
    for i = 1, #path - 1 do
        local a, b = path[i], path[i + 1]
        local R = C.keptLinks[a] and C.keptLinks[a][b]
        if R == nil then
            allK = false
            if sawK and leaveAt == nil then leaveAt = a end
            S = nil
        else
            if not sawK and i > 1 and joinAt == nil then joinAt = a end
            sawK = true
            if S == nil then
                S = R
            else
                local S2, any = {}, false
                for k in pairs(S) do
                    if R[k] then S2[k] = true any = true end
                end
                if any then
                    S = S2
                else
                    if sw == nil then sw = a end
                    S = R
                end
            end
        end
    end
    if allK then
        if sw == nil then return nil, "through" end
        if C.crossing(sw) then return sw, "crossing" end
        return sw, "turn"
    end
    if leaveAt ~= nil then return leaveAt, "turn" end
    if joinAt ~= nil then return joinAt, "turn" end
    for i = 2, #path - 1 do
        local p, w, n = path[i - 1], path[i], path[i + 1]
        if C.inA[w] then
            for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
                for _, id in ipairs(lst) do
                    local t = C.node(id)
                    if t ~= nil and t ~= w and t ~= n and t ~= p then return w, "turn" end
                end
            end
        end
    end
    return nil, "turn"
end

--- The part of a split junction a place belongs to, when it is nearer another of the places the
--- roads met (before the clear) than the one this clear worked on. Nil otherwise.
local function jxOtherPart(C, x, z)
    local M = C.meetings
    if M == nil or M.here == nil then return nil end
    local best, bd = nil, (x - M.here.x) ^ 2 + (z - M.here.z) ^ 2
    for _, p in ipairs(M.pts) do
        if p ~= M.here then
            local d = (x - p.x) ^ 2 + (z - p.z) ^ 2
            if d < bd then bd, best = d, p end
        end
    end
    return best
end

--- Where the turn into a teal dot came from: the way in that arrives most turned, followed back up
--- to the fork where it left its road. Half-way along it is where that turn belongs. At 39 a dot 10 m
--- from the middle and 12 m from 39se's meeting point is the merge of 39se's own turn off its south
--- road; by the dot's own place it read as this junction's missed connection.
local function jxTurnFrom(C, w)
    local ox, oz = 0, 0
    for _, id in ipairs(w.out or {}) do
        local t = C.node(id)
        if t ~= nil and t ~= w then
            local hx, hz = jxHeading(w, t)
            if hx ~= nil then ox, oz = ox + hx, oz + hz end
        end
    end
    local best, bd = nil, math.huge
    for _, id in ipairs(w.incoming or {}) do
        local f = C.node(id)
        if f ~= nil and f ~= w then
            local hx, hz = jxHeading(f, w)
            if hx ~= nil and hx * ox + hz * oz < bd then bd, best = hx * ox + hz * oz, f end
        end
    end
    if best == nil then return w end
    -- A FORK AS IT WAS BEFORE THE CLEAR as well as now. The clear takes the other connectors off the
    -- point a turn leaves its road at, and then nothing stops the walk there: at 39 (the game's own
    -- network, through roads kept) 39se's turn was followed on back down 39's south lane into 39's
    -- middle, and its dot was called a connection 39's clear missed.
    local function forks(v)
        local seen, n = {}, 0
        for _, lst in ipairs({ v.out or {}, v.incoming or {} }) do
            for _, id in ipairs(lst) do
                if id ~= v.id and not seen[id] then seen[id] = true n = n + 1 end
            end
        end
        if n >= 3 then return true end
        local b0 = C.before ~= nil and C.before[v] or nil
        if b0 == nil then return false end
        local seenB, nb = {}, 0
        for _, lst in ipairs({ b0.out or {}, b0.inn or {} }) do
            for _, t in ipairs(lst) do
                if t ~= v and not seenB[t] then seenB[t] = true nb = nb + 1 end
            end
        end
        return nb >= 3
    end
    local prev, cur, run = w, best, math.sqrt((best.x - w.x) ^ 2 + (best.z - w.z) ^ 2)
    local walked = { w, best }
    for _ = 1, 40 do
        if run >= 40 or forks(cur) then break end
        local nxt = nil
        for _, id in ipairs(cur.incoming or {}) do
            local f = C.node(id)
            if f ~= nil and f ~= prev and f ~= cur then
                if nxt ~= nil then nxt = nil break end
                nxt = f
            end
        end
        if nxt == nil or nxt == w then break end
        -- ...and where it comes off a kept through road: that is its road. With through roads kept
        -- the clear gives the kept road its own copy of a fork it shares with a turn, so neither
        -- copy is a fork afterwards, nor (being new) one before - and 39se's turn was walked back
        -- 40 m down 39's south road.
        if C.keptLink ~= nil and C.keptLink(nxt, cur) then break end
        run = run + math.sqrt((nxt.x - cur.x) ^ 2 + (nxt.z - cur.z) ^ 2)
        prev, cur = cur, nxt
        walked[#walked + 1] = cur
    end
    -- HALF-WAY ALONG THE TURN, not half-way across from the dot to its fork. A turn bows out, and
    -- the straight line between its ends cuts the corner back towards where it left its road: at 39
    -- (the game's own network) 39se's turn into the dot at (12.1, 6.3) came out 13.7 m from 39's
    -- middle and 13.8 m from 39se's by its ends, and was called a connection 39's clear missed;
    -- along the turn its middle is 11.5 m from 39se's and 14.4 m from 39's.
    local half, acc = run / 2, 0
    for i = 2, #walked do
        local a, b = walked[i - 1], walked[i]
        local l = math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
        if acc + l >= half and l > 0 then
            local t = (half - acc) / l
            return { x = a.x + (b.x - a.x) * t, z = a.z + (b.z - a.z) * t }
        end
        acc = acc + l
    end
    return { x = (w.x + cur.x) / 2, z = (w.z + cur.z) / 2 }
end

--- ONE ROAD'S OWN LANES: every way in and out of a teal dot leads, within 40 m, to lanes of one and
--- the same road, or to a dead end. At 31 the two-way side road splits into a two-way stub and a
--- one-way one; AutoDrive draws that teal, but no second road comes into it.
local function jxOneRoad(C, w)
    local road, any = nil, false
    local function roadOf(v)
        local m = C.inLane[v] or C.outLane[v]
        if m == nil then return nil end
        return C.apRoad[m]
    end
    local seen0 = {}
    for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
        for _, id in ipairs(lst) do
            local n = C.node(id)
            if n ~= nil and n ~= w and not seen0[n] then
                seen0[n] = true
                local prev, cur, run, found, dead = w, n, 0, nil, false
                for _ = 1, 40 do
                    found = roadOf(cur)
                    if found ~= nil then break end
                    local nxt, k = nil, 0
                    for _, l2 in ipairs({ cur.out or {}, cur.incoming or {} }) do
                        for _, id2 in ipairs(l2) do
                            local t = C.node(id2)
                            if t ~= nil and t ~= prev and t ~= cur and t ~= nxt then
                                k = k + 1
                                nxt = t
                            end
                        end
                    end
                    if k == 0 then dead = true break end
                    if k > 1 then break end
                    run = run + math.sqrt((nxt.x - cur.x) ^ 2 + (nxt.z - cur.z) ^ 2)
                    if run > 40 then break end
                    prev, cur = cur, nxt
                end
                if found ~= nil then
                    if road ~= nil and road ~= found then return false end
                    road, any = found, true
                elseif not dead then
                    return false
                end
            end
        end
    end
    if roadOf(w) ~= nil and road ~= nil and roadOf(w) ~= road then return false end
    return any
end

--- PAST THE EDGE, ONTO WHICH LANE. A drive that leaves the junction where none of the lanes the
--- check walked runs is followed on, the way it is driven, until it reaches one of the junction's
--- lanes out: up to 40 m, and never back into the middle (a drive that comes back in is found from
--- its own way in). Shortest first, the same point first on a tie, so every run names the same lane.
--- Before this, such a drive was never counted: at 20, with through roads kept, the lane in from the
--- south splits inside the middle, 8.7 m out, and its branch to the north-east - 20n's own turn -
--- leaves the junction 12 m out on a stretch no lane walk had marked, reaching the north-east
--- road's lane out 4 m further on; a split makes no teal dot, so nothing said it. The same lane's
--- other branch, and 62's south-east lane looping out past the edge, reach the lane out of their
--- own kept through road, and stay unsaid for that reason. Returns the points after `t`, and the
--- lane reached, or no lane when it reached none.
--- `marks`: the lanes to look for - the lanes out (C.outLane) unless given. A way in that lies on
--- no lane the check walked is followed on the same way to the lane in it becomes (C.inLane).
local function jxDriveOn(C, t, marks)
    marks = marks or C.outLane
    local best, prev, done, open = { [t] = 0 }, {}, {}, { t }
    while #open > 0 do
        local bi = 1
        for i = 2, #open do
            local a, b = open[i], open[bi]
            if best[a] < best[b] or (best[a] == best[b] and jxByPos(a, b)) then bi = i end
        end
        local w = table.remove(open, bi)
        if not done[w] then
            done[w] = true
            if marks[w] ~= nil then
                local path, v = {}, w
                while v ~= nil and v ~= t do
                    table.insert(path, 1, v)
                    v = prev[v]
                end
                return path, marks[w]
            end
            for _, id in ipairs(w.out or {}) do
                local n = C.node(id)
                if n ~= nil and n ~= w and not done[n] and not C.inMid[n] then
                    local d = best[w] + math.sqrt((n.x - w.x) ^ 2 + (n.z - w.z) ^ 2)
                    if d <= 40 and (best[n] == nil or d < best[n]) then
                        if best[n] == nil then open[#open + 1] = n end
                        best[n], prev[n] = d, w
                    end
                end
            end
        end
    end
    return {}, nil
end

--- THE LANE A LANE START BECOMES. From w, the way it is driven, straight on at every fork - the way
--- the lanes themselves are walked - through the middle or not, up to 40 m, to the first point a
--- walked lane runs over. Returns that lane, and whether it is a lane in (where a lane in and a lane
--- out both run over the point, the one whose own end it is nearer), or nil when it reaches none.
local function jxLaneAhead(C, w)
    local cur, prev, run, seen = w, nil, 0, { [w] = true }
    for _ = 1, 200 do
        local o, i = C.outLane[cur], C.inLane[cur]
        if o ~= nil and i ~= nil and C.inRun[cur] < C.outRun[cur] then o = nil end
        if o ~= nil then return o, false end
        if i ~= nil then return i, true end
        local hx, hz = nil, nil
        if prev ~= nil then hx, hz = jxHeading(prev, cur) end
        local best, bd = nil, -math.huge
        for _, id in ipairs(cur.out or {}) do
            local t = C.node(id)
            if t ~= nil and t ~= cur and not seen[t] then
                local dx, dz = jxHeading(cur, t)
                if dx ~= nil then
                    local c = 1
                    if hx ~= nil then c = dx * hx + dz * hz end
                    if best == nil or c > bd or (c == bd and jxByPos(t, best)) then bd, best = c, t end
                end
            end
        end
        if best == nil or bd < 0.3 then return nil end
        run = run + math.sqrt((best.x - cur.x) ^ 2 + (best.z - cur.z) ^ 2)
        if run > 40 then return nil end
        prev, cur = cur, best
        seen[cur] = true
    end
    return nil
end

--- ANOTHER PART'S TURN: DOES IT STILL DRIVE? (split junctions, the user's rule 4 of 2026-10-03). The
--- clear lists, before it cuts anything, every turn of another part's that runs in this part's area
--- (junctionTwinTurns), and leaves each one working (rule 1). The check follows each one end to end
--- on the network as the clear left it: from the point it leaves its road to the point it joins one,
--- along links, every point within 2 m of where the turn ran (the respacing slides points along a
--- lane; a point slid off its place is found by the link that now runs over it, within 0.75 m). It
--- then asks whether a vehicle can get onto it - a way in to its first point - and off it - a way on
--- from its last. Each way is followed up to 60 m: one that runs that far drives; one that stops
--- short at a lane start (or end) is the stub this part's clear cut, with through roads off; one
--- with no way at all is a turn nothing can be driven onto (or off). A way that was just as short
--- before the clear is not this clear's doing. Only a turn that is whole and drives NOW - a way onto
--- it and a way off it, each 60 m or as far as before the clear - is called fine (r.ok): the
--- user's rule asks whether a vehicle can get onto it and off it, and a turn reached only over this
--- clear's 5 m stub cannot be until this part is built (the parked rounds of 2026-10-03 were turned
--- down for calling exactly that fine). A join or teal dot over a listed turn is said as that
--- part's turn - left working where it drives, "does not drive now" where it does not - instead of
--- as a connection this clear missed; and every turn that does not drive is also a problem of its
--- own (kind "twin"), never relabelled. EXCEPT ONE THAT WAITS FOR THE BUILD (the user's call of
--- 2026-10-05): with through roads off, a turn that is whole but whose only way on or off is this
--- clear's cut lane drives again once this part is built - expected, and no clear can avoid it while
--- it empties this part's middle. It is said as waiting for the build (r.waits), a note and not a
--- problem. One with no way in or out at all, or cut part-way, stays a problem. A turn this part's clear takes as its own is never on the
--- list, so a turn of this part's that the clear missed cannot be passed as another part's. Sets
--- C.twinMoves (one entry a turn: state, the points it was followed over) and C.twinSpan (the
--- stretches of road kept for them).
local JX_TWIN_FAR = 60
local function jxCheckTwin(C)
    C.twinMoves, C.twinSpan = {}, {}
    local tw = C.twin
    if tw == nil or tw.moves == nil then return end
    local pts = {}
    for w in pairs(C.live) do
        if (w.x - C.cx) ^ 2 + (w.z - C.cz) ^ 2 <= 110 * 110 then pts[#pts + 1] = w end
    end
    table.sort(pts, jxByPos)
    local function at(p, tol)
        local best, bd = nil, tol * tol
        for _, w in ipairs(pts) do
            local d = (w.x - p.x) ^ 2 + (w.z - p.z) ^ 2
            if d <= bd then bd, best = d, w end
        end
        return best
    end
    local function segD(px, pz, a, b)
        local vx, vz = b.x - a.x, b.z - a.z
        local L2 = vx * vx + vz * vz
        local t = 0
        if L2 > 1e-9 then t = math.max(0, math.min(1, ((px - a.x) * vx + (pz - a.z) * vz) / L2)) end
        return math.sqrt((px - a.x - vx * t) ^ 2 + (pz - a.z - vz * t) ^ 2)
    end
    for _, sp in ipairs(tw.spans or {}) do
        local w = at(sp, 0.3)
        if w ~= nil then C.twinSpan[w] = true end
    end
    -- How far a vehicle can come to w (back) or go on from it, up to JX_TWIN_FAR metres, never over
    -- `skip`: now, or (old) on the network as it was before the clear.
    local function reach(w, back, skip, old)
        local best, open, far, maxd = { [w] = 0 }, { w }, false, 0
        local h = 1
        while h <= #open and not far do
            local c = open[h]
            h = h + 1
            local list
            if old then
                local b0 = C.before[c]
                list = (b0 ~= nil) and (back and b0.inn or b0.out) or {}
            else
                list = {}
                for _, id in ipairs((back and c.incoming or c.out) or {}) do
                    local t = C.node(id)
                    if t ~= nil then list[#list + 1] = t end
                end
            end
            for _, t in ipairs(list) do
                if t ~= c and not skip[t] then
                    local b0 = old and C.before[t] or t
                    local cc = old and C.before[c] or c
                    if b0 ~= nil and cc ~= nil then
                        local d = best[c] + math.sqrt((b0.x - cc.x) ^ 2 + (b0.z - cc.z) ^ 2)
                        if best[t] == nil or d < best[t] then
                            best[t] = d
                            if d > maxd then maxd = d end
                            if d >= JX_TWIN_FAR then far = true else open[#open + 1] = t end
                        end
                    end
                end
            end
        end
        return far, maxd
    end
    for _, m in ipairs(tw.moves) do
        local P = m.pts
        local a, b = P[1], P[#P]
        local r = { name = m.name, a = a, b = b, pts = P, ok = false }
        local E = at(a, 0.5)
        if E == nil then
            for _, w in ipairs(pts) do
                if (w.x - a.x) ^ 2 + (w.z - a.z) ^ 2 <= 100 then
                    for _, id in ipairs(w.out or {}) do
                        local t = C.node(id)
                        if t ~= nil and t ~= w and segD(a.x, a.z, w, t) <= 0.75 then E = t end
                    end
                end
            end
        end
        local function nearLine(w)
            for k = 2, #P do
                if segD(w.x, w.z, P[k - 1], P[k]) <= 2 then return true end
            end
            return false
        end
        local X, par = nil, nil
        if E ~= nil then
            par = { [E] = false }
            local q, h = { E }, 1
            if (E.x - b.x) ^ 2 + (E.z - b.z) ^ 2 <= 0.25 then X = E end
            while h <= #q and X == nil do
                local c = q[h]
                h = h + 1
                local outs = {}
                for _, id in ipairs(c.out or {}) do
                    local t = C.node(id)
                    if t ~= nil and t ~= c and par[t] == nil then outs[#outs + 1] = t end
                end
                table.sort(outs, jxByPos)
                for _, t in ipairs(outs) do
                    if X == nil then
                        if segD(b.x, b.z, c, t) <= 0.75 then
                            par[t], X = c, t
                        elseif nearLine(t) then
                            par[t] = c
                            q[#q + 1] = t
                        end
                    end
                end
            end
        end
        if E == nil then
            r.state, r.why = "broken", "its start is gone"
        elseif X == nil then
            r.state, r.why = "broken", "it is cut part-way along, or where it joins the road is gone"
        else
            local on, inner = { [E] = true, [X] = true }, {}
            local c = par[X]
            while c and c ~= E do
                on[c], inner[c] = true, true
                c = par[c]
            end
            r.E, r.X, r.on = E, X, on
            local inFar, inD = reach(E, true, inner, false)
            local outFar, outD = reach(X, false, inner, false)
            r.inD, r.outD, r.inFar, r.outFar = inD, outD, inFar, outFar
            -- before the clear, from the same points (where they were there)
            local E0, X0 = m.nodes and m.nodes[1], m.nodes and m.nodes[#m.nodes]
            local inner0 = {}
            for k = 2, #(m.nodes or {}) - 1 do inner0[m.nodes[k]] = true end
            local inFar0, outFar0 = true, true
            if E0 ~= nil and C.before[E0] ~= nil then inFar0 = reach(E0, true, inner0, true) end
            if X0 ~= nil and C.before[X0] ~= nil then outFar0 = reach(X0, false, inner0, true) end
            r.fromCut = (not inFar) and inFar0
            r.toCut = (not outFar) and outFar0
            local built = C.name or "this part"
            if r.fromCut and inD < 1 then
                r.state, r.why = "nowayin", "nothing leads onto it any more"
            elseif r.toCut and outD < 1 then
                r.state, r.why = "nowayout", "it leads nowhere any more"
            elseif r.fromCut and r.toCut then
                r.state = "cut"
                r.why = string.format("the only way onto it is this clear's cut lane, %.1f m long, and it leads only into another, %.1f m long - it can drive again once %s is built", inD, outD, built)
            elseif r.fromCut then
                r.state = "fromcut"
                r.why = string.format("the only way onto it is this clear's cut lane, %.1f m long - it can drive again once %s is built", inD, built)
            elseif r.toCut then
                r.state = "tocut"
                r.why = string.format("it leads only into this clear's cut lane, %.1f m long - it can drive again once %s is built", outD, built)
            else
                r.ok = true
                r.state = "drives"
            end
            r.waits = (not C.leave) and (r.state == "cut" or r.state == "fromcut" or r.state == "tocut")
        end
        C.twinMoves[#C.twinMoves + 1] = r
    end
end

--- The turn of another part's, left by this clear, that a join drives over (jxCheckTwin) - whether
--- it still drives or not (r.ok says which): the join's own turning runs along it from where it
--- leaves the road, and the rest of the drive is road - before the turn a kept through road, the
--- stretch kept for that turn, a lane in the check walked or road outside this junction; past it a
--- lane the check walked or road outside this junction. The drive may also stop ON the turn, where
--- the check's walk of a lane out reaches it: on the game's network at 20 (live.lua), 20n's lane out
--- to the south-east is walked in along the last 6 m of 20s's left turn, so the drive from the lane
--- in stops there and never reaches the turn's last point - and was said as a connection the clear
--- missed. Nil otherwise: a drive that turns anywhere else is said for what it is.
local function jxTwinJoin(C, path)
    for _, r in ipairs(C.twinMoves or {}) do
        if r.E ~= nil and r.on ~= nil then
            local iE, iX = nil, nil
            for k, v in ipairs(path) do
                if v == r.E and iE == nil then iE = k end
                if v == r.X and iE ~= nil and iX == nil and k > iE then iX = k end
            end
            -- stopped on the turn: every point after its start is the turn's, to the drive's end
            if iE ~= nil and iX == nil and iE < #path then
                local all = true
                for k = iE + 1, #path do
                    if not r.on[path[k]] then all = false break end
                end
                if all then iX = #path end
            end
            if iE ~= nil and iX ~= nil then
                local good = true
                for k = iE + 1, iX - 1 do
                    if not r.on[path[k]] then good = false break end
                end
                -- Road before the turn: each end of each link a lane in, the stretch kept for the
                -- turn or outside this junction's area (at 39 with turn radius 2, after 39nw's clear,
                -- the drive came onto the lane in from the north-west from a point outside the area,
                -- over a link no kept road claims, and was said as a connection the clear missed).
                -- Never a point of wiring inside the area: a turn of this junction's own that runs
                -- into the other part's is said for what it is.
                local function roadEnd(w)
                    return C.twinSpan[w] or not C.inA[w] or C.inLane[w] ~= nil
                end
                for k = 1, iE - 1 do
                    local u, v = path[k], path[k + 1]
                    local road = C.keptLink(u, v) or (roadEnd(u) and (roadEnd(v) or v == r.E))
                    if not road then good = false break end
                end
                for k = iX, #path - 1 do
                    local u, v = path[k], path[k + 1]
                    local road = C.keptLink(u, v) or not C.inA[v] or C.outLane[v] ~= nil or C.inLane[v] ~= nil
                    if not road then good = false break end
                end
                if good then return r end
            end
        end
    end
    return nil
end

--- A teal dot on a turn of another part's that this clear left (driving or not: r.ok): where it
--- joins its road, or on it - and nothing else meets there but road: every way in and out of it is
--- that turn, a lane the check walked, a kept through road, the stretch kept for that turn, or road
--- outside this junction. A dot where wiring of this junction's own meets it too (a turn the clear
--- missed, leaving the same point) is said for that, not as the other part's turn.
local function jxTwinAt(C, w)
    for _, r in ipairs(C.twinMoves or {}) do
        if r.on ~= nil and (r.X == w or r.on[w]) then
            local road = true
            for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
                for _, id in ipairs(lst) do
                    local t = C.node(id)
                    if t ~= nil and t ~= w and not (r.on[t] or C.inLane[t] ~= nil or C.outLane[t] ~= nil
                        or C.keptLink(w, t) or C.keptLink(t, w) or C.twinSpan[t] or not C.inA[t]) then
                        road = false
                    end
                end
            end
            if road then return r end
        end
    end
    return nil
end

--- CHECK 1: THE MIDDLE IS EMPTY.
local function jxCheckMiddle(C)
    local inLane, outLane, inA, inMid = C.inLane, C.outLane, C.inA, C.inMid
    local approaches, before = C.approaches, C.before

    -- The lanes a through road joins, by the clear's own list: the lane it came in on and the lane
    -- it went out on.
    local throughPair = {}
    for _, L in ipairs(C.lines) do
        throughPair[L.first] = throughPair[L.first] or {}
        throughPair[L.first][L.last] = true
    end
    local function isThroughPair(a, b)
        local A, B = approaches[a], approaches[b]
        return A ~= nil and B ~= nil and throughPair[A.wp] ~= nil and throughPair[A.wp][B.wp] == true
    end

    -- A JOIN IS A DRIVE: in on one of the junction's lanes, through the middle, and out on another
    -- of them that is not the same road going on. The drive may use all of the junction, out to its
    -- bound, so a turn that leaves its lane 20 m out still counts; but it has to pass through the
    -- middle, or a road that cuts the corner 40 m out (1) would be a join of this junction. A way in
    -- is a link from a point outside the bound to a point inside it - found from the outside points'
    -- own links, which are what a vehicle drives - or a lane that starts inside the bound with
    -- nothing leading into it (the stub of a lane leaving, as a clear cuts it). A way out is a link
    -- out of the bound, or a lane out that ends inside it: 68 is a grid of short one-way lanes that
    -- all start and end inside its bound, and its four corner links joined them unseen.
    local cx, cz = C.cx, C.cz
    local entries, hasIn = {}, {}
    for u in pairs(C.live) do
        if (u.x - cx) ^ 2 + (u.z - cz) ^ 2 <= 100 * 100 then
            for _, id in ipairs(u.out or {}) do
                local v = C.node(id)
                if v ~= nil and v ~= u then
                    hasIn[v] = true
                    if inA[v] and not inA[u] then entries[#entries + 1] = { u = u, v = v } end
                end
            end
        end
    end
    for _, w in ipairs(C.area) do
        if not hasIn[w] then entries[#entries + 1] = { u = nil, v = w } end
    end
    table.sort(entries, function(p, q)
        if p.v ~= q.v then return jxByPos(p.v, q.v) end
        if p.u == nil or q.u == nil then return q.u == nil and p.u ~= nil end
        return jxByPos(p.u, q.u)
    end)
    local joins, seenJoin = {}, {}
    for _, e in ipairs(entries) do
        -- Which lane this is: one coming in, or one that starts here and goes out. Where a lane in
        -- and a lane out both run over the point, it is the lane whose own end it is nearer (68).
        local laneIn, laneStart = nil, nil
        -- Where the drive starts (ev), the point it came from (cameFrom0, never driven straight back
        -- to), and the point the drive is said from (eu): the way in, unless that lies before its
        -- lane (below).
        local eu, ev, cameFrom0 = e.u, e.v, e.u
        if e.u ~= nil then
            laneIn = inLane[e.v] or inLane[e.u]
            -- A way in on no lane the check walked: followed on to the lane in it becomes, and driven
            -- from where it reaches that lane. Each lane is walked from its own far end, and where
            -- that end lies inside the bound the way in lies before it: 40's west lane starts 20 m
            -- out, where a side road merges into it, and 62's north-west lane 36 m out, on the far
            -- side of a hairpin. Neither lane's drives were looked at, so a link wired from either
            -- into another road read "middle empty". Driven from the lane's own end, not from the
            -- way in: from the way in, 40's side road merging into the west lane read as a join of
            -- this junction, 20 m out and past its middle - and it is a road meeting the lane before
            -- the lane is this junction's.
            if laneIn == nil then
                local onto, found = jxDriveOn(C, e.v, inLane)
                if found ~= nil then
                    laneIn = found
                    ev, eu = onto[#onto], nil
                    cameFrom0 = onto[#onto - 1] or e.v
                end
            end
        else
            local o, i = outLane[e.v], inLane[e.v]
            if o ~= nil and i ~= nil and C.inRun[e.v] < C.outRun[e.v] then o = nil end
            if o ~= nil then laneStart = o else laneIn = i end
            -- A lane start on no lane the check walked: the lane it runs on into (jxLaneAhead). At
            -- 20, with through roads not kept, the tidy cut the north lane out at the box and laid
            -- its new start 6 m from the middle; the north lane's walk, coming back in, kept to the
            -- north-east road at 20n and missed it, so the stub's split onto 20n's turn to the
            -- north-east went unsaid - while the same kind of split off the stub of 40's north-east
            -- lane out, which its walk did cover, was said.
            if o == nil and i == nil then
                local found, isIn = jxLaneAhead(C, e.v)
                if found ~= nil and isIn then laneIn = found elseif found ~= nil then laneStart = found end
            end
        end
        if laneIn ~= nil or laneStart ~= nil then
            -- Drive on from the way in, inside the bound, remembering whether the middle has been
            -- passed yet - a point can be reached both ways, so each is a state of its own - and
            -- note every way out taken after the middle.
            local par = { [false] = {}, [true] = {} }
            local f0 = inMid[ev] == true
            par[f0][ev] = false
            local q, head = { { ev, f0 } }, 1
            local exits = {}
            while head <= #q do
                local w, f = q[head][1], q[head][2]
                head = head + 1
                -- Never straight back to the point it came from: that is a two-way lane driven
                -- both ways, not a turn (65's two-way side road read as two U-turns).
                local cameFrom = cameFrom0
                if par[f][w] then cameFrom = par[f][w][1] end
                local outs = w.out or {}
                for _, id in ipairs(outs) do
                    local t = C.node(id)
                    if t ~= nil and t ~= w and t ~= cameFrom then
                        if inA[t] then
                            local g = f or (inMid[t] == true)
                            if par[g][t] == nil then
                                par[g][t] = { w, f }
                                q[#q + 1] = { t, g }
                            end
                        elseif f then
                            exits[#exits + 1] = { w = w, t = t }
                        end
                    end
                end
                if f and #outs == 0 and outLane[w] ~= nil then exits[#exits + 1] = { w = w } end
            end
            local inIdx = laneIn or laneStart
            for _, x in ipairs(exits) do
                local laneOut = outLane[x.w]
                if laneOut == nil and x.t ~= nil then laneOut = outLane[x.t] end
                -- PAST A LANE'S OWN FAR END THE DRIVE IS STILL ON THAT LANE. Each lane out is walked in
                -- from its far end - the point the clear followed its run out to - and that end can lie
                -- inside the bound: the clear follows a run only as far as its turns need (about 30 m
                -- at a 2 m turn radius), while the bound runs every arm out to the next junction. At 65,
                -- turn radius 2, through roads not kept, the south-east lane out's far end lay 40 m from
                -- the middle and the bound reached past 42 m; the lane's last 2 m inside the bound was
                -- walked by no lane, so a drive from the lane's own new start, straight along it, read as
                -- joining "a road the clear did not count as one of this junction's" - itself - and as a
                -- connection the clear missed, where nothing joined anything. So where the last point
                -- of the drive that a lane walk covered is a lane out's own far end, and from there the
                -- drive runs on with no way to choose (one way on at every point, not counting the way
                -- back on a two-way road), the drive left on that lane. The same rule as a way in that
                -- lies before its lane (jxDriveOn, above): what lies along a lane beyond its own end is
                -- not this junction's. Not where the lane ends at a fork, or meets one after its end: the
                -- east lane out of the unnumbered junction south of 40 (x2 in extra_sites.txt) ends 15 m
                -- out where its road splits in two, and a drive onto either branch is still said.
                if laneOut == nil then
                    local st, plain = { x.w, true }, true
                    while st do
                        local v, from = st[1], par[st[2]][st[1]]
                        local ways, n = {}, 0
                        for _, id in ipairs(v.out or {}) do
                            local t = C.node(id)
                            if t ~= nil and t ~= v and not (from and t == from[1]) and not ways[t] then
                                ways[t] = true
                                n = n + 1
                            end
                        end
                        if outLane[v] ~= nil or inLane[v] ~= nil then
                            if plain and n == 1 and outLane[v] ~= nil and C.outRun[v] == 0 then laneOut = outLane[v] end
                            break
                        end
                        if n ~= 1 then plain = false end
                        st = from
                    end
                end
                -- Leaving where no walked lane runs: followed on to the lane it reaches (jxDriveOn).
                -- One that reaches none is still a join - onto a road the clear found no lane of -
                -- and is said as that, not passed as the same lane going on.
                local onward, offLanes = nil, false
                if laneOut == nil and x.t ~= nil then
                    onward, laneOut = jxDriveOn(C, x.t)
                    offLanes = (laneOut == nil)
                end
                local same = (laneOut == nil and not offLanes) or (laneStart ~= nil and laneOut == laneStart)
                if not same then
                    local path, st = {}, { x.w, true }
                    while st do
                        table.insert(path, 1, st[1])
                        st = par[st[2]][st[1]]
                    end
                    if eu ~= nil then table.insert(path, 1, eu) end
                    if x.t ~= nil then path[#path + 1] = x.t end
                    for _, v in ipairs(onward or {}) do path[#path + 1] = v end
                    local where, kind = jxTurnOf(C, path)
                    local through = (laneIn ~= nil and isThroughPair(laneIn, laneOut)) or kind == "through"
                    -- A kept through road running end to end is what "through roads kept" asked for.
                    if not (through and C.leave) then
                        if where == nil then
                            local bd = math.huge
                            for _, pp in ipairs(path) do
                                if inMid[pp] then
                                    local d = C.dist(pp)
                                    if d < bd then bd, where = d, pp end
                                end
                            end
                            where = where or path[math.floor((#path + 1) / 2)]
                        end
                        local key = string.format("%d>%d@%d,%d", laneIn or -(laneStart or 0), laneOut or 0,
                            math.floor(where.x * 2 + 0.5), math.floor(where.z * 2 + 0.5))
                        if not seenJoin[key] then
                            seenJoin[key] = true
                            -- Was it there before the clear? Where two kept roads cross, that is
                            -- whether they shared the point then (16: they did not, the clean-up
                            -- joined them); anywhere else, whether the drive drove then.
                            local why, part, was, fold, foldWas, la, lb = "missed", nil, true, nil, nil, nil, nil
                            local twin = nil
                            local old, na, nb, fw = true, nil, nil, nil
                            if kind ~= "crossing" then old, na, nb, fw = jxJoinWas(C, path) end
                            if kind == "crossing" then
                                if C.sharedBefore(where) then
                                    why = "crossing"
                                else
                                    why, was, fold = "crossmade", false, C.foldedInto(where)
                                    foldWas = C.crossGapBefore(where)
                                end
                            elseif not old then
                                why, was = "made", false
                                if na ~= nil then la, lb = { x = na.x, z = na.z }, { x = nb.x, z = nb.z } end
                                if fw ~= nil then
                                    fold, la = C.foldedInto(fw), { x = fw.x, z = fw.z }
                                end
                            elseif through then
                                why = "through"
                            elseif jxTwinJoin(C, path) ~= nil then
                                -- another part's turn, left by this clear (jxCheckTwin): working,
                                -- waiting for the build, or not drivable now - said so either way,
                                -- and the last is also a problem of its own
                                twin = jxTwinJoin(C, path)
                                if twin.ok then
                                    why = "twin"
                                elseif twin.waits then
                                    why = "twinwait"
                                else
                                    why = "twinstuck"
                                end
                            else
                                part = jxOtherPart(C, where.x, where.z)
                                -- A drive followed on past the edge is also asked half-way between
                                -- where it turns off and where it gets to, as a teal dot's turn is
                                -- (jxTurnFrom): at 40, with through roads not kept, the west road's
                                -- lane splits 10.5 m from 40w's middle and 11.2 m from 40e's, and its
                                -- branch runs on to 40e's east road.
                                if part == nil and onward ~= nil then
                                    local far = path[#path]
                                    part = jxOtherPart(C, (where.x + far.x) / 2, (where.z + far.z) / 2)
                                end
                                if part ~= nil then
                                    why = "part"
                                elseif C.noBox then
                                    why = "nobox"
                                end
                            end
                            local pts = {}
                            for _, pp in ipairs(path) do pts[#pts + 1] = { x = pp.x, z = pp.z } end
                            local rIn, rOut = C.apRoad[inIdx], nil
                            if laneOut ~= nil then rOut = C.apRoad[laneOut] end
                            local to
                            if laneOut ~= nil then to = C.roadName(laneOut) else to = C.wordAt(x.t.x, x.t.z) end
                            local startAt = nil
                            if laneStart ~= nil then startAt = { x = ev.x, z = ev.z } end
                            joins[#joins + 1] = { x = where.x, z = where.z, why = why, path = pts, part = part, twin = twin, nodes = path, at = where,
                                starts = (laneStart ~= nil), startAt = startAt, uturn = (rIn ~= nil and rIn == rOut), was = was, fold = fold,
                                foldWas = foldWas, foldAt = (fw ~= nil), linkFrom = la, linkTo = lb, offLanes = offLanes,
                                from = C.roadName(inIdx), to = to }
                        end
                    end
                end
            end
        end
    end
    table.sort(joins, function(p, q)
        if p.x ~= q.x then return p.x < q.x end
        if p.z ~= q.z then return p.z < q.z end
        if p.from ~= q.from then return p.from < q.from end
        if p.to ~= q.to then return p.to < q.to end
        if p.why ~= q.why then return p.why < q.why end
        return (p.uturn and 1 or 0) < (q.uturn and 1 or 0)
    end)

    -- THE TEAL DOTS: in the middle, all of them. Further out, to 45 m - the reach of the clear's
    -- own clean-up, past the junction's edge - only those the clear made, and those fed by the end
    -- of a turn it cut: a merge out there that was already one, and still is for the same reason,
    -- is as likely the next junction's. A dot that a join drives through is said for the same reason
    -- as the join; any other is named for what made it.
    local function allKept(w)
        for _, id in ipairs(w.out or {}) do
            local t = C.node(id)
            if t ~= nil and not C.keptLink(w, t) then return false end
        end
        for _, id in ipairs(w.incoming or {}) do
            local f = C.node(id)
            if f ~= nil and not C.keptLink(f, w) then return false end
        end
        return true
    end
    -- A join's own points are where it turns: every point on a link of the drive that is not a kept
    -- road's, and the point it turns at. Not the whole drive - along a kept road that would hand the
    -- join's reason to a dot it merely passes.
    local RANK = { made = 7, crossmade = 6, missed = 5, twinstuck = 5, part = 4, twinwait = 4, twin = 4, nobox = 3, through = 2, crossing = 1 }
    local onJoin = {}
    local function mark(v, j)
        local o = onJoin[v]
        if o == nil or (RANK[j.why] or 0) > (RANK[o.why] or 0) then onJoin[v] = j end
    end
    for _, j in ipairs(joins) do
        local path = j.nodes
        for i = 1, #path - 1 do
            if not C.keptLink(path[i], path[i + 1]) then
                mark(path[i], j)
                mark(path[i + 1], j)
            end
        end
        if j.at ~= nil then mark(j.at, j) end
    end
    local dots = {}
    for _, w in ipairs(C.near) do
        if C.dist(w) <= 45 and jxRightOfWay(w) then
            local was = C.dotBefore(w.x, w.z) ~= nil
            local tail, leg = jxTail(C, w)
            if inMid[w] or not was or tail ~= nil then
                local why, part, fold, foldWas, from, viaJoin = "missed", nil, nil, nil, nil, nil
                local twin = nil
                local joinsItself, split = jxSelfJoin(C, w)
                if C.leave and C.crossing(w) and allKept(w) then
                    if C.sharedBefore(w) then
                        why = "crossing"
                    else
                        why, fold, foldWas = "crossmade", C.foldedInto(w), C.crossGapBefore(w)
                    end
                elseif joinsItself then
                    -- Was it one lane joining itself before the clear too? At 2 it was not: the
                    -- clean-up folded a turn's point into the lane's, and what is left of the turn
                    -- now runs beside the lane into the same point.
                    if jxSelfJoin(C, w, true) then
                        why = "selfjoin"
                    else
                        why, from, fold = "selfmade", split, C.foldedInto(split)
                    end
                -- A TAIL IS SAID AS A TAIL even where another part's own drive passes the dot too. At
                -- 39 with through roads off, 39se's turn lost the fork it left 39's south road at and
                -- is fed by nothing, but 39se's south-east to south drive runs through its merge, so
                -- the dot was passed as "39se's own wiring". A join's reason still wins where it is
                -- this clear's doing or a miss (made, crossmade, missed): those are worse.
                elseif onJoin[w] ~= nil and not (tail ~= nil and (RANK[onJoin[w].why] or 0) < RANK.missed) then
                    viaJoin = onJoin[w]
                    why, part, fold, foldWas = viaJoin.why, viaJoin.part, viaJoin.fold, viaJoin.foldWas
                    twin = viaJoin.twin
                elseif tail ~= nil then
                    why, from = "tail", tail
                elseif not was then
                    why = "new"
                -- WHERE A THROUGH ROAD THIS CLEAR CUT AT THE BOX MERGES INTO ANOTHER PART'S LANE. At 39
                -- with through roads off, the south-to-north road's leg out, cut loose on purpose,
                -- still merges into 39se's lane at the dot. The lanes out are walked the straighter
                -- way back at that merge, along 39se's lane, so on the game's network the dot read as
                -- "one road's own lanes" (both ways in looked like the north road). It is the merge
                -- of two roads, and it lies in the other part: that part's wiring.
                elseif leg ~= nil and jxOtherPart(C, w.x, w.z) ~= nil then
                    why, part = "part", jxOtherPart(C, w.x, w.z)
                elseif jxTwinAt(C, w) ~= nil then
                    -- where another part's turn, left by this clear, joins its road (jxCheckTwin)
                    twin = jxTwinAt(C, w)
                    if twin.ok then
                        why = "twin"
                    elseif twin.waits then
                        why = "twinwait"
                    else
                        why = "twinstuck"
                    end
                elseif jxOneRoad(C, w) then
                    why = "oneroad"
                else
                    local turned = jxTurnFrom(C, w)
                    part = jxOtherPart(C, turned.x, turned.z)
                    if part ~= nil then
                        why = "part"
                    elseif C.noBox then
                        why = "nobox"
                    end
                end
                local d = { x = w.x, z = w.z, why = why, was = was, part = part, twin = twin, fold = fold, foldWas = foldWas }
                if from ~= nil then d.fx, d.fz = from.x, from.z end
                if viaJoin ~= nil then d.linkFrom, d.linkTo, d.foldAt = viaJoin.linkFrom, viaJoin.linkTo, viaJoin.foldAt end
                dots[#dots + 1] = d
            end
        end
    end
    for _, j in ipairs(joins) do j.nodes, j.at = nil, nil end
    -- the turn's own points are not kept with the result: only what the lines say of it
    local function plainTwin(it)
        local r = it.twin
        if r ~= nil then
            it.twin = { name = r.name, ok = r.ok, state = r.state, why = r.why, fromCut = r.fromCut, toCut = r.toCut, inD = r.inD, outD = r.outD }
        end
    end
    for _, j in ipairs(joins) do plainTwin(j) end
    for _, d in ipairs(dots) do plainTwin(d) end
    C.joins, C.dots = joins, dots
end

--- CHECK 2: NOTHING ELSE TOUCHED.
local function jxCheckTouched(C)
    local before, journal, live = C.before, C.journal, C.live
    local at, node = C.at, C.node
    local issues = {}
    local function issue(kind, x, z, text, far)
        issues[#issues + 1] = { kind = kind, x = x, z = z, text = text, far = far }
    end

    -- THE RECORD, PLAYED OVER THE NETWORK AS IT WAS: what the clear meant the network to become.
    -- Only the points the record touches are copied; everything else is expected as it was. Each
    -- move is measured against where the point stood before it, so a move of nothing is not
    -- counted as an edit: the lane-end tidy records its nudge even when the nudge is zero, and at
    -- 24 a point "moved" 0.000 m, 63 m out, was reported as the tidy reaching outside the junction.
    local model, gone, added = {}, {}, {}
    local function setOf(list)
        local s = {}
        for _, t in ipairs(list or {}) do s[t] = true end
        return s
    end
    local function M(w, e)
        local m = model[w]
        if m == nil then
            local b0 = before[w]
            if b0 ~= nil then
                m = { x = b0.x, y = b0.y, z = b0.z, out = setOf(b0.out), inn = setOf(b0.inn) }
            elseif e ~= nil then
                m = { x = e.x, y = e.y, z = e.z, out = {}, inn = {} }
            else
                m = { x = w.x, y = w.y, z = w.z, out = {}, inn = {} }
            end
            model[w] = m
        end
        return m
    end
    local moveBy = {}
    for i, e in ipairs(journal) do
        if e.op == "add" then
            model[e.a] = { x = e.x, y = e.y, z = e.z, out = {}, inn = {} }
            added[e.a] = e
            gone[e.a] = nil
        elseif e.op == "remove" then
            local m = M(e.a, e)
            for t in pairs(m.out) do if t ~= e.a then M(t).inn[e.a] = nil end end
            for f in pairs(m.inn) do if f ~= e.a then M(f).out[e.a] = nil end end
            gone[e.a] = e
        elseif e.op == "move" then
            local m = M(e.a, e)
            moveBy[i] = math.sqrt((e.x - m.x) ^ 2 + ((e.y or 0) - (m.y or 0)) ^ 2 + (e.z - m.z) ^ 2)
            m.x, m.y, m.z = e.x, e.y, e.z
        elseif e.op == "out+" then M(e.a, e).out[e.b] = true
        elseif e.op == "out-" then M(e.a, e).out[e.b] = nil
        elseif e.op == "in+" then M(e.a, e).inn[e.b] = true
        elseif e.op == "in-" then M(e.a, e).inn[e.b] = nil
        end
    end

    -- A link that now runs the other way between two points that were both there before. Never
    -- something a clear means to do, recorded or not: it turns a lane round.
    local flipped = {}
    for w, b0 in pairs(before) do
        if live[w] then
            for _, t in ipairs(b0.out) do
                if live[t] and t ~= w and not table.contains(w.out or {}, t.id)
                    and table.contains(t.out or {}, w.id) then
                    local back = false
                    for _, f in ipairs((before[t] and before[t].out) or {}) do
                        if f == w then back = true break end
                    end
                    if not back then
                        flipped[w] = flipped[w] or {}
                        flipped[w][t] = true
                        issue("flip", (w.x + t.x) / 2, (w.z + t.z) / 2,
                            string.format("the link from %s to %s now runs the other way", at(w.x, w.z), at(t.x, t.z)))
                    end
                end
            end
        end
    end
    local function isFlip(a, b)
        return (flipped[a] ~= nil and flipped[a][b]) or (flipped[b] ~= nil and flipped[b][a]) or false
    end

    local function nowSet(list)
        local s = {}
        for _, id in ipairs(list or {}) do
            local t = node(id)
            if t ~= nil then s[t] = true end
        end
        return s
    end
    -- Compare one surviving point with what the record says it should be.
    local outDiff, inDiff = {}, {}
    local function compare(w, m)
        local d = math.sqrt((w.x - m.x) ^ 2 + ((w.y or 0) - (m.y or 0)) ^ 2 + (w.z - m.z) ^ 2)
        if d > 0.01 then
            if model[w] ~= nil and before[w] ~= nil
                and (m.x ~= before[w].x or m.y ~= before[w].y or m.z ~= before[w].z) then
                issue("moved", w.x, w.z, string.format("a point the clear moved to %s stands %.1f m from there", at(m.x, m.z), d))
            else
                issue("moved", w.x, w.z, string.format("a point moved %.1f m, and no part of the clear moved it", d))
            end
        end
        -- Link differences are gathered and said once the whole network has been compared, so a
        -- link that appeared is one line, not one for each end of it.
        for t in pairs(nowSet(w.out)) do
            if not m.out[t] then outDiff[#outDiff + 1] = { a = w, b = t, ex = true } end
        end
        for t in pairs(m.out) do
            if live[t] and not table.contains(w.out or {}, t.id) then outDiff[#outDiff + 1] = { a = w, b = t, ex = false } end
        end
        for f in pairs(nowSet(w.incoming)) do
            if not m.inn[f] then inDiff[#inDiff + 1] = { a = f, b = w, ex = true } end
        end
        for f in pairs(m.inn) do
            if live[f] and not table.contains(w.incoming or {}, f.id) then inDiff[#inDiff + 1] = { a = f, b = w, ex = false } end
        end
    end
    -- Untouched points are compared list against list first: the cheap way, for the thousands that
    -- the clear never came near.
    local function sameAsBefore(w, b0)
        if w.x ~= b0.x or w.y ~= b0.y or w.z ~= b0.z then return false end
        local o, i = w.out or {}, w.incoming or {}
        if #o ~= #b0.out or #i ~= #b0.inn then return false end
        for k = 1, #o do if node(o[k]) ~= b0.out[k] then return false end end
        for k = 1, #i do if node(i[k]) ~= b0.inn[k] then return false end end
        return true
    end
    for w, b0 in pairs(before) do
        if not live[w] then
            if gone[w] == nil then
                issue("gone", b0.x, b0.z, "a point was removed, and no part of the clear removed it")
            end
        elseif gone[w] ~= nil then
            issue("stayed", w.x, w.z, "the clear removed this point, but it is still there")
        elseif model[w] ~= nil then
            compare(w, model[w])
        elseif not sameAsBefore(w, b0) then
            compare(w, M(w))
        end
    end
    for w in pairs(live) do
        if before[w] == nil then
            if added[w] == nil then
                issue("new", w.x, w.z, "a point appeared, and no part of the clear laid it")
            elseif gone[w] ~= nil then
                issue("stayed", w.x, w.z, "the clear laid this point and removed it again, but it is still there")
            else
                compare(w, model[w])
            end
        end
    end
    for w, e in pairs(added) do
        if not live[w] and gone[w] == nil then
            issue("vanished", e.x, e.z, "a point the clear laid is gone, and no part of the clear removed it")
        end
    end
    -- A link is the outgoing list of one point and the incoming list of the other. Where both
    -- disagree with the record it is one link, said once; where only the incoming side does, it is
    -- half a link - the kind of disagreement AutoDrive's own merge test reads wrongly.
    local outSeen = {}
    for _, d in ipairs(outDiff) do
        outSeen[d.a] = outSeen[d.a] or {}
        outSeen[d.a][d.b] = d.ex
        if not isFlip(d.a, d.b) then
            if d.ex then
                issue("link", d.a.x, d.a.z, string.format("a link from here to %s appeared, and no part of the clear made it", at(d.b.x, d.b.z)))
            else
                issue("link", d.a.x, d.a.z, string.format("the link from here to %s is gone, and no part of the clear cut it", at(d.b.x, d.b.z)))
            end
        end
    end
    for _, d in ipairs(inDiff) do
        local same = outSeen[d.a] ~= nil and outSeen[d.a][d.b] == d.ex
        if not same and not isFlip(d.a, d.b) then
            if d.ex then
                issue("link", d.b.x, d.b.z, string.format("the point now lists %s as leading into it, but no link runs from there - half a link no part of the clear made", at(d.a.x, d.a.z)))
            else
                issue("link", d.b.x, d.b.z, string.format("the point no longer lists %s as leading into it, though the link from there still runs - half a link no part of the clear cut", at(d.a.x, d.a.z)))
            end
        end
    end

    -- EACH EDIT STAYS INSIDE THIS JUNCTION. Deletions are bounded at jxRemove already; this asks the
    -- same of every edit, so a stage that wires or moves something past the junction is named. The
    -- respacing has a reach of its own: it may not work further along a lane, from the lane's end,
    -- than FLYOVER_JUNCTION_RESPACE_LEN (plus the one gap that takes it there), measured along the
    -- lane as the respacing measures it - a straight line from the middle said "57 m" of a stretch
    -- 49 m along the lane (1). Past that it is a problem. Inside that reach, a stretch lying wholly
    -- outside the junction is only a NOTE: the design gives the respacing "up to 50 m out" and "its
    -- own limit" (docs/junction-tool/04, check 2), while the respacing's own comment says the far
    -- part is "simply not this junction's to touch", and a two-point stretch with both ends past the
    -- edge gets through its rule all the same (1: a 13 m link 45-58 m out divided at 51 m). Which
    -- of the two is right is the user's call; counted as problems, they failed 37 of 68 clears and
    -- buried the three real road cuts among them.
    local reach = {}
    local VERB = { add = "laid", move = "moved", remove = "removed", ["out+"] = "made", ["out-"] = "cut" }
    local function runInside(run)
        if run.inside == nil then
            run.inside = false
            for _, p in ipairs(run.pts or {}) do
                if C.inArea(p.x, p.z) then run.inside = true break end
            end
        end
        return run.inside
    end
    -- A DELETE RUNS TO THE FIRST FORK. A turn that the clear takes out is taken whole, up to the
    -- lanes it joined, even where its ends lie past the edge of the area: at 36 the area's arms were
    -- read off-line and the last 1-2 points of two turns, 13-15 m out, fell outside it, and leaving
    -- them left a dead end and a turn tail still joined to its lane. So a removed point outside the
    -- area counts as inside when, in the network before, it lies on a run without forks, every point
    -- of it removed, that reaches a removed point inside the area no more than JX_WHOLE_PIECE_REACH
    -- away - the clear's own limit, so a piece that ran further is still reported. Worked out from the network
    -- before and the record alone, not from anything the clear says about itself.
    local removedSet = {}
    for _, e in ipairs(journal) do
        if e.op == "remove" and e.a ~= nil then removedSet[e.a] = true end
    end
    local function plainPoint(w)
        local b0 = before[w]
        if b0 == nil then return false end
        local seen, n = {}, 0
        for _, lst in ipairs({ b0.out or {}, b0.inn or {} }) do
            for _, t in ipairs(lst) do
                if t ~= w and not seen[t] then seen[t] = true n = n + 1 end
            end
        end
        return n <= 2
    end
    local function forklessToInside(w)
        if not removedSet[w] or not plainPoint(w) then return false end
        local seen, stack = { [w] = true }, { w }
        while #stack > 0 do
            local p = table.remove(stack)
            if C.inArea(before[p].x, before[p].z)
                and (before[p].x - before[w].x) ^ 2 + (before[p].z - before[w].z) ^ 2 <= JX_WHOLE_PIECE_REACH ^ 2 then
                return true
            end
            for _, lst in ipairs({ before[p].out or {}, before[p].inn or {} }) do
                for _, t in ipairs(lst) do
                    if not seen[t] and removedSet[t] and plainPoint(t) then
                        seen[t] = true
                        stack[#stack + 1] = t
                    end
                end
            end
        end
        return false
    end
    for i, e in ipairs(journal) do
        -- One count per edit: a link is counted from its outgoing side, its mirror is not.
        local verb = VERB[e.op]
        if verb == "moved" and (moveBy[i] or 0) < 0.01 then verb = nil end
        if verb ~= nil then
            local d = C.dist(e)
            local outside
            if e.b ~= nil then
                outside = not C.inArea(e.x, e.z) and not C.inArea(e.b.x, e.b.z)
            else
                outside = not C.inArea(e.x, e.z)
            end
            if e.respace and e.run ~= nil and runInside(e.run) then outside = false end
            if outside and e.op == "remove" and e.b == nil and forklessToInside(e.a) then outside = false end
            local key, far = nil, false
            if outside then
                key = (e.respace and "1 " or "0 ") .. e.stage
            end
            if e.respace and e.run ~= nil and e.run.cap ~= nil
                and (e.run.along or 0) - (e.run.firstGap or 0) > e.run.cap then
                key, far = "2 " .. e.stage, true
            end
            if key ~= nil then
                local r = reach[key]
                if r == nil then
                    r = { key = key, stage = e.stage, respace = e.respace, far = -1, near = math.huge, n = {}, runs = {}, nRuns = 0 }
                    if far then r.along, r.cap = e.run.along, e.run.cap end
                    reach[key] = r
                end
                r.n[verb] = (r.n[verb] or 0) + 1
                if e.run ~= nil and not r.runs[e.run] then
                    r.runs[e.run] = true
                    r.nRuns = r.nRuns + 1
                end
                if far and e.run.along > (r.along or 0) then r.along = e.run.along end
                if d > r.far then r.far, r.x, r.z = d, e.x, e.z end
                if d < r.near then r.near = d end
            end
        end
    end
    local stages = {}
    for _, r in pairs(reach) do stages[#stages + 1] = r end
    table.sort(stages, function(p, q) return p.key < q.key end)
    local notes = {}
    for _, r in ipairs(stages) do
        local who = "the respacing"
        if r.stage ~= "respacing" then who = string.format("the respacing (while %s)", r.stage) end
        -- "between 15 and 25 m": at 58 a lone "the farthest 25 m" was where the lane split, while
        -- the points it laid were 15 and 20 m out.
        local span = string.format("%.0f m from the middle", r.far)
        if r.far - r.near >= 1 then span = string.format("between %.0f and %.0f m from the middle", r.near, r.far) end
        if r.key:sub(1, 1) == "2" then
            issue("reach", r.x, r.z, string.format("%s worked %.0f m along a lane from its end, past its %.0f m reach",
                who, r.along or 0, r.cap or 0), r.far)
        elseif r.respace then
            -- Two distances, said as two: how far from the middle in a straight line, and how far
            -- along the lane from where it now ends - which is how the respacing's reach is
            -- measured. "Between 50 and 61 m from the middle. Within its own 50 m reach" (30) read
            -- as a contradiction; "its own code says it should stop at the edge" was about the
            -- code, not the road.
            local what = string.format("re-laid %d stretch%s of road", r.nRuns, (r.nRuns == 1) and "" or "es")
            if r.nRuns == 0 then what = "changed road" end
            notes[#notes + 1] = { x = r.x, z = r.z, far = r.far, text = string.format(
                "%s %s lying wholly outside this junction, %s in a straight line. Not counted as a problem: measured along the lane from the lane's end at the junction, it is inside the %.0f m the respacing may work over. Whether it should work past the junction's edge at all is your call",
                who, what, span, AutoDrive.FLYOVER_JUNCTION_RESPACE_LEN or 50) }
        else
            local parts = {}
            for _, v in ipairs({ "laid", "moved", "removed", "made", "cut" }) do
                local n = r.n[v]
                if n ~= nil then
                    local unit = "point"
                    if v == "made" or v == "cut" then unit = "link" end
                    if n ~= 1 then unit = unit .. "s" end
                    parts[#parts + 1] = string.format("%s %d %s", v, n, unit)
                end
            end
            local what = parts[1] or "changed nothing"
            if #parts > 1 then
                what = table.concat(parts, ", ", 1, #parts - 1) .. " and " .. parts[#parts]
            end
            issue("reach", r.x, r.z, string.format("%s %s outside this junction, %s",
                r.stage, what, span), r.far)
        end
    end

    -- A LANE THAT NOW SPLITS INTO DEAD ENDS. At 58 the tidy laid a new spur beside a lane's old end:
    -- the lane coming in from the south split 25 m out into two dead ends side by side, 3 m apart,
    -- and the only report was "laid 2 points outside this junction". Each way out of a fork is
    -- followed, never straight back, until it forks again, ends, or runs 30 m; a fork the clear gave
    -- more ways out than it had, with more of its ways ending than before, is said, out to 60 m.
    -- More ways out, not merely new ones: a road that already split into two lanes before the
    -- junction, both now cut to stubs, is what a clear leaves on purpose - at 31 the tidy re-laid
    -- one of the side road's two stubs, a new way out in place of an old one.
    local function deadEnds(w, old)
        local function outs(v, from)
            local list = {}
            if old then
                for _, t in ipairs((before[v] and before[v].out) or {}) do
                    if t ~= v and t ~= from then list[#list + 1] = t end
                end
            else
                for _, id in ipairs(v.out or {}) do
                    local t = node(id)
                    if t ~= nil and t ~= v and t ~= from then list[#list + 1] = t end
                end
            end
            return list
        end
        local function pos(v)
            if old then return before[v] end
            return v
        end
        local ends = {}
        local first = outs(w, nil)
        if #first < 2 then return ends end
        for _, t in ipairs(first) do
            local prev, cur = w, t
            local run = math.sqrt((pos(t).x - pos(w).x) ^ 2 + (pos(t).z - pos(w).z) ^ 2)
            for _ = 1, 40 do
                local nx = outs(cur, prev)
                if #nx == 0 then ends[#ends + 1] = cur break end
                if #nx > 1 then break end
                run = run + math.sqrt((pos(nx[1]).x - pos(cur).x) ^ 2 + (pos(nx[1]).z - pos(cur).z) ^ 2)
                if run > 30 then break end
                prev, cur = cur, nx[1]
            end
        end
        return ends
    end
    local function newWayOut(w)
        local now, was, seen = 0, 0, {}
        for _, id in ipairs(w.out or {}) do
            local t = node(id)
            if t ~= nil and t ~= w and not seen[t] then seen[t] = true now = now + 1 end
        end
        seen = {}
        for _, t in ipairs((before[w] and before[w].out) or {}) do
            if t ~= w and not seen[t] then seen[t] = true was = was + 1 end
        end
        return now > was
    end
    local spurAt = {}
    -- Every dead end a line below has already said, so the rule for a turn left leading nowhere
    -- (further down) does not say the same end again.
    local saidEnd = {}
    for _, w in ipairs(C.near) do
        local ends = {}
        if newWayOut(w) then ends = deadEnds(w, false) end
        if #ends >= 2 then
            local was = 0
            if before[w] ~= nil then was = #deadEnds(w, true) end
            if was < #ends then
                spurAt[w] = true
                for _, t in ipairs(ends) do saidEnd[t] = true end
                table.sort(ends, jxByPos)
                local where = {}
                for _, t in ipairs(ends) do where[#where + 1] = at(t.x, t.z) end
                local list = table.concat(where, " and ")
                if #where > 2 then list = table.concat(where, ", ", 1, #where - 1) .. " and " .. where[#where] end
                local earlier = "none of its ways ended"
                if was == 1 then earlier = "only one of them did" elseif was > 1 then earlier = string.format("only %d did", was) end
                issue("spur", w.x, w.z, string.format("a lane now splits here into %d dead ends, at %s; before the clear %s",
                    #ends, list, earlier))
            end
        end
    end

    -- THE START OF A TURN THE CLEAR CUT, LEFT HANGING OFF A LANE: the other end of the tail
    -- (jxTail). A way out of a fork that runs, point by point and without a fork, at most 15 m to a
    -- dead end that was there before the clear and led on then, while another way out of the same
    -- fork is not such a piece. At 36, with through roads kept, the clear cut the Y's branch to the
    -- south but left its first 4 m on the north road's lane, 15 m out, just past the edge the
    -- deletions obey: a lane splitting makes no teal dot, and with one dead end the rule above had
    -- nothing to say, so nothing said it. Not a lane of this junction stopping on purpose: the end of
    -- a lane coming in is on the lanes the check walked, and is left out. Nor a dead end the clear
    -- laid: that is a lane's end the tidy re-laid (31's one-way stub, beside the side road's two-way
    -- one), or else the rule above's.
    local function liveOuts(v, from)
        local list, seen = {}, {}
        for _, id in ipairs(v.out or {}) do
            local t = node(id)
            if t ~= nil and t ~= v and t ~= from and not seen[t] then
                seen[t] = true
                list[#list + 1] = t
            end
        end
        return list
    end
    -- A fork is a point with three or more neighbours: along a two-way road every point has two
    -- ways out, forward and back, and taking that for a split read every point of 26's two-way side
    -- road as a fork with a dead end hanging off it.
    local function isFork(v)
        local seen, k = {}, 0
        for _, lst in ipairs({ v.out or {}, v.incoming or {} }) do
            for _, id in ipairs(lst) do
                local t = node(id)
                if t ~= nil and t ~= v and not seen[t] then
                    seen[t] = true
                    k = k + 1
                end
            end
        end
        return k >= 3
    end
    for _, w in ipairs(C.near) do
        local first = liveOuts(w, nil)
        if not spurAt[w] and #first >= 2 and isFork(w) then
            local pieces = {}
            for _, t in ipairs(first) do
                local prev, cur = w, t
                local run = math.sqrt((t.x - w.x) ^ 2 + (t.z - w.z) ^ 2)
                local stop = nil
                for _ = 1, 40 do
                    local nx = liveOuts(cur, prev)
                    if #nx == 0 then stop = cur break end
                    if #nx > 1 or run > 15 then break end
                    run = run + math.sqrt((nx[1].x - cur.x) ^ 2 + (nx[1].z - cur.z) ^ 2)
                    prev, cur = cur, nx[1]
                end
                local b0 = nil
                if stop ~= nil then b0 = before[stop] end
                if b0 ~= nil and run <= 15 and C.inLane[stop] == nil and C.outLane[stop] == nil then
                    local ledOn = false
                    for _, o in ipairs(b0.out) do
                        if o ~= stop then ledOn = true end
                    end
                    if ledOn then pieces[#pieces + 1] = { e = stop, run = run } end
                end
            end
            if #pieces > 0 and #pieces < #first then
                table.sort(pieces, function(p, q) return jxByPos(p.e, q.e) end)
                for _, p in ipairs(pieces) do
                    saidEnd[p.e] = true
                    issue("leftover", w.x, w.z, string.format(
                        "a lane now splits here into a dead end %.0f m long, ending at %s - the start of a turn the clear cut, left behind; before the clear that way led on",
                        p.run, at(p.e.x, p.e.z)))
                end
            end
        end
    end

    -- A TURN LEFT LEADING NOWHERE, OR FED BY NOTHING. The rule above reads a dead end only 15 m out
    -- from the fork it hangs off. In the missed-turn test (missed.lua), j39's own turn from the main
    -- road onto the north road, kept on purpose, runs 18 m to where the north road's northbound lane
    -- started before the clear. The clear now carries that lane on to the box, and the point the turn
    -- led into went with the old start. The turn then led nowhere, nothing drove over it, and the
    -- check said nothing at all; before, the lane still started there, and the drive over the turn
    -- was said as missed. So every point near here that has no way out now, though it led on before
    -- the clear, is walked back point by point (one way in and one way out, out to 60 m) to where its
    -- piece leaves the rest, and said. And the mirror: every point with nothing leading into it now,
    -- though something did before, is walked on to where its piece joins the rest, and said (at 39 a
    -- turn of its own onto the north-west road, kept the same way, lost the point that fed it).
    -- It only adds lines: it never changes or hides another line. Not said twice: an end the two
    -- rules above said, or a piece whose first point a teal dot already says as the start of a cut
    -- turn's end (jxTail). Not a lane that stops on purpose: a point on the lanes the check walked
    -- (a lane in cut at the box ends there, a lane out cut at the box starts there), or a piece lying
    -- all along one of the through roads read before the clear (C.lines, within 2.5 m: with through
    -- roads off they are cut at the box on purpose). Nor a piece whose loose end lies on a road the
    -- road-cut rule (below) already says is cut: at 67 the clear cuts a road that crossed it without
    -- joining, and the rest of that road past where the check drove it, fed by nothing now, is that
    -- same cut. A piece joined to nothing at either end is the scrap rule's, below.
    -- AutoDrive.FLYOVER_JUNCTION_LOOSE_ENDS = false turns this off, for the harness only.
    if AutoDrive.FLYOVER_JUNCTION_LOOSE_ENDS ~= false then
        local function liveIns(v)
            local list, seen = {}, {}
            for _, id in ipairs(v.incoming or {}) do
                local t = node(id)
                if t ~= nil and t ~= v and not seen[t] then
                    seen[t] = true
                    list[#list + 1] = t
                end
            end
            return list
        end
        local function step(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2) end
        local function onLane(v) return C.inLane[v] ~= nil or C.outLane[v] ~= nil end
        -- WHETHER THE WAY LED SOMEWHERE BEFORE THE CLEAR: walked on (fwd) or back from v over the
        -- network as it was, point by point, until it reaches a fork or a merge (it did) or stops
        -- (it did not: it ended, or started, loose already). At 68 a turn the clear took started
        -- at a point nothing led into, and what was left of it read as cut off at its start; it had
        -- been fed by nothing before the clear too. Out to 60 m: further, it ran somewhere.
        local function ledSomewhere(v, fwd)
            local cur, run, seenB = v, 0, { [v] = true }
            for _ = 1, 200 do
                local b = before[cur]
                if b == nil then return true end
                local ways, nb = {}, nil
                for _, t in ipairs(fwd and b.out or b.inn) do
                    if t ~= cur and not ways[t] then
                        ways[t] = true
                        if nb == nil then nb = t elseif nb ~= t then return true end
                    end
                end
                if nb == nil then return false end
                if seenB[nb] then return true end
                local bn = before[nb]
                if bn == nil then return true end
                local back = {}
                local nBack = 0
                for _, t in ipairs(fwd and bn.inn or bn.out) do
                    if t ~= nb and not back[t] then
                        back[t] = true
                        nBack = nBack + 1
                    end
                end
                if nBack > 1 then return true end
                run = run + math.sqrt((bn.x - b.x) ^ 2 + (bn.z - b.z) ^ 2)
                if run > 60 then return true end
                seenB[nb] = true
                cur = nb
            end
            return true
        end
        local function alongRoad(piece)
            for _, Lr in ipairs(C.lines or {}) do
                local all = true
                for _, v in ipairs(piece) do
                    if jxOnLine(Lr.pts, v.x, v.z) > 2.5 then all = false break end
                end
                if all then return true end
            end
            return false
        end
        -- The loose end of a piece lies on a road the road-cut rule says is cut.
        local function onCutRoad(v)
            for _, b in ipairs(C.broken or {}) do
                if jxOnLine(b.item.pts, v.x, v.z) <= 2.5 then return true end
            end
            return false
        end
        local tailFrom = {}
        for _, dt in ipairs(C.dots or {}) do
            if dt.fx ~= nil then tailFrom[#tailFrom + 1] = dt end
        end
        local function saidAsTail(v)
            for _, dt in ipairs(tailFrom) do
                if math.abs(dt.fx - v.x) < 0.01 and math.abs(dt.fz - v.z) < 0.01 then return true end
            end
            return false
        end
        -- Leading nowhere: from the dead end back to where its piece leaves a fork or a merge.
        for _, d in ipairs(C.near) do
            local b0 = before[d]
            if b0 ~= nil and not saidEnd[d] and not onLane(d) and #liveOuts(d, nil) == 0 and #liveIns(d) == 1
                and ledSomewhere(d, true) then
                local piece, cur, run, from = { d }, d, 0, nil
                local seenN = { [d] = true }
                for _ = 1, 200 do
                    local q = liveIns(cur)[1]
                    if q == nil or seenN[q] then break end
                    run = run + step(q, cur)
                    if run > 60 then break end
                    local qi, qo = #liveIns(q), #liveOuts(q, nil)
                    if qo > 1 or qi > 1 then from = q break end
                    if qi == 0 then break end
                    seenN[q] = true
                    piece[#piece + 1] = q
                    cur = q
                end
                if from ~= nil and not alongRoad(piece) and not onCutRoad(d) then
                    issue("leftover", from.x, from.z, string.format(
                        "a way off the lane here now leads nowhere: it stops %.0f m on, at %s, where before the clear it led on - a turn left in place, cut off at its far end",
                        run, at(d.x, d.z)))
                end
            end
        end
        -- Fed by nothing: from the loose start on to where its piece joins a merge or a fork.
        for _, s in ipairs(C.near) do
            local b0 = before[s]
            if b0 ~= nil and not onLane(s) and #liveIns(s) == 0 and #liveOuts(s, nil) == 1
                and ledSomewhere(s, false) and not saidAsTail(s) then
                local piece, cur, run, into = { s }, s, 0, nil
                local seenN = { [s] = true }
                for _ = 1, 200 do
                    local t = liveOuts(cur, nil)[1]
                    if t == nil or seenN[t] then break end
                    run = run + step(cur, t)
                    if run > 60 then break end
                    local ti, to = #liveIns(t), #liveOuts(t, nil)
                    if ti > 1 or to > 1 then into = t break end
                    if to == 0 then break end
                    seenN[t] = true
                    piece[#piece + 1] = t
                    cur = t
                end
                if into ~= nil and not alongRoad(piece) and not onCutRoad(s) then
                    issue("leftover", s.x, s.z, string.format(
                        "a way that starts here is now fed by nothing: %.0f m of it still joins at %s, where before the clear something led into it - a turn left in place, cut off at its start",
                        run, at(into.x, into.z)))
                end
            end
        end
    end

    -- A SCRAP CUT LOOSE FROM EVERYTHING. Clearing 39 and then 39se, both with through roads off, left
    -- two points of 39se's turn with nothing leading in and nothing leading out, and the card said
    -- "middle empty, nothing else touched": no rule here read a piece that joins nothing. So every
    -- piece of wiring near here that is joined to nothing else - at most 8 points, under 15 m end to
    -- end - and had a link before the clear that it has not now, is said. A piece that was already
    -- loose before, and is as it was, is not this clear's.
    do
        local seenI = {}
        for _, s in ipairs(C.near) do
            if not seenI[s] then
                local comp, stack, big = {}, { s }, false
                seenI[s] = true
                while #stack > 0 do
                    local v = table.remove(stack)
                    comp[#comp + 1] = v
                    if #comp > 8 then big = true end
                    for _, lst in ipairs({ v.out or {}, v.incoming or {} }) do
                        for _, id in ipairs(lst) do
                            local t = node(id)
                            if t ~= nil and t ~= v and not seenI[t] then
                                seenI[t] = true
                                stack[#stack + 1] = t
                            end
                        end
                    end
                end
                if not big and #comp >= 2 then
                    local inComp = {}
                    for _, v in ipairs(comp) do inComp[v] = true end
                    local x0, x1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
                    local lost = false
                    for _, v in ipairs(comp) do
                        x0, x1, z0, z1 = math.min(x0, v.x), math.max(x1, v.x), math.min(z0, v.z), math.max(z1, v.z)
                        local b0 = before[v]
                        if b0 ~= nil then
                            for _, lst in ipairs({ b0.out, b0.inn }) do
                                for _, t in ipairs(lst) do
                                    if t ~= v and not inComp[t] then lost = true end
                                end
                            end
                        else
                            -- laid by this clear, and joined to nothing else: this clear's too
                            lost = true
                        end
                    end
                    local span = math.sqrt((x1 - x0) ^ 2 + (z1 - z0) ^ 2)
                    -- Not road: a lane cut at two boxes - between two parts of a split junction, or
                    -- two junctions, both cleared with through roads off - is the road the next
                    -- build joins up to, however short, and is left on purpose. Road is a piece lying
                    -- all along one of the through roads read before the clear (C.lines, within 2.5 m,
                    -- as jxTail reads a leg). Not by passages: a turn's loose piece is driven like a
                    -- lane from its first point, and read so, 39se's 2-point scrap was "road".
                    local road = false
                    for _, Lr in ipairs(C.lines or {}) do
                        local all = true
                        for _, v in ipairs(comp) do
                            if jxOnLine(Lr.pts, v.x, v.z) > 2.5 then all = false break end
                        end
                        if all then road = true break end
                    end
                    if lost and span < 15 and not road then
                        table.sort(comp, jxByPos)
                        issue("leftover", comp[1].x, comp[1].z, string.format(
                            "a scrap of %d points, %.0f m end to end, is left joined to nothing - the clear cut it loose from what it was on",
                            #comp, span))
                    end
                end
            end
        end
    end

    -- EVERY ROAD THAT HAS TO STILL DRIVE, STILL DRIVES (jxCheckKept found which ones, and where each
    -- one stops).
    for _, b in ipairs(C.broken or {}) do
        local it = b.item
        -- Named by the junction's own roads where the ends lie on its lanes, as the joins are.
        local from, to = C.wordAt(it.A.x, it.A.z), C.wordAt(it.B.x, it.B.z)
        local ia, ob = C.inLane[it.A] or C.outLane[it.A], C.outLane[it.B] or C.inLane[it.B]
        if ia ~= nil then from = C.roadName(ia) end
        if ob ~= nil then to = C.roadName(ob) end
        local text
        local stops = "no longer drives through: it stops here"
        if b.detour then stops = "now gets through only by leaving its own line: along it, it stops here" end
        if b.lost then
            text = string.format("the road in from the %s, out to the %s, lost its end point", from, to)
        elseif it.kind == "unjoined" then
            text = string.format("the road in from the %s, out to the %s, runs across the junction without joining it, and %s", from, to, stops)
        elseif it.kind == "own" then
            text = string.format("the kept through road in from the %s, out to the %s, %s", from, to, stops)
        else
            text = string.format("the road in from the %s, out to the %s, drove straight through before the clear and %s", from, to, stops)
        end
        issue("through", b.x, b.z, text)
    end

    -- EVERY LANE STILL RUNS ITS OWN WAY. Walked from its far end in towards the middle, keeping to the
    -- straightest way on, and every link it crosses must run the way the lane does. A link that ran
    -- the wrong way before the clear as well is said, but is not this clear's doing.
    local wrongBefore = {}
    for idx, ap in ipairs(C.approaches) do
        local A = ap.wp
        if A ~= nil and live[A] then
            local wantIn = (ap.dir == "in")
            local name = string.format("the lane %s the %s", wantIn and "in from" or "out to", C.roadName(idx))
            local hx, hz = C.cx - A.x, C.cz - A.z
            local hl = math.sqrt(hx * hx + hz * hz)
            if hl > 1e-6 then hx, hz = hx / hl, hz / hl end
            -- THE FIRST STEP IS THE LANE'S OWN: downstream from where a lane in starts, upstream from
            -- where a lane out ends. Straight at the middle is no good where the lane bends - at 62
            -- the west road's lane runs north at its far end, and a first step aimed at the middle
            -- went on down it, the way traffic leaves.
            do
                local first, fd = nil, -math.huge
                local lst = A.incoming or {}
                if wantIn then lst = A.out or {} end
                for _, id in ipairs(lst) do
                    local t = node(id)
                    if t ~= nil and t ~= A then
                        local dx, dz = t.x - A.x, t.z - A.z
                        local l = math.sqrt(dx * dx + dz * dz)
                        if l > 1e-6 and (dx * hx + dz * hz) / l > fd then fd, first = (dx * hx + dz * hz) / l, t end
                    end
                end
                if first ~= nil then hx, hz = jxHeading(A, first) end
            end
            local prev, cur, seen, entered = nil, A, { [A] = true }, C.inA[A] == true
            for _ = 1, 300 do
                local best, bd = nil, -math.huge
                for _, lst in ipairs({ cur.out or {}, cur.incoming or {} }) do
                    for _, id in ipairs(lst) do
                        local t = node(id)
                        if t ~= nil and t ~= prev and t ~= cur and not seen[t] then
                            local dx, dz = t.x - cur.x, t.z - cur.z
                            local l = math.sqrt(dx * dx + dz * dz)
                            if l > 1e-6 and (dx * hx + dz * hz) / l > bd then bd, best = (dx * hx + dz * hz) / l, t end
                        end
                    end
                end
                if best == nil or bd < 0.3 then break end
                local fwd = table.contains(cur.out or {}, best.id)
                local bwd = table.contains(best.out or {}, cur.id)
                if (wantIn and not fwd) or (not wantIn and not bwd) then
                    local mx, mz = (cur.x + best.x) / 2, (cur.z + best.z) / 2
                    local b0, b1 = before[cur], before[best]
                    local was = false
                    if b0 ~= nil and b1 ~= nil then
                        local f0, r0 = false, false
                        for _, t in ipairs(b0.out) do if t == best then f0 = true end end
                        for _, t in ipairs(b1.out) do if t == cur then r0 = true end end
                        was = (f0 == fwd) and (r0 == bwd)
                    end
                    local text = string.format("%s no longer %s: the link here runs the wrong way", name, wantIn and "drives in" or "drives out")
                    if was then
                        wrongBefore[#wrongBefore + 1] = { x = mx, z = mz, text = name .. ": the link here ran the wrong way before the clear too" }
                    else
                        issue("stub", mx, mz, text)
                    end
                    break
                end
                hx, hz = jxHeading(cur, best)
                prev, cur = cur, best
                seen[cur] = true
                if C.inA[cur] then entered = true elseif entered then break end
            end
        end
    end
    C.issues, C.wrongBefore, C.notes = issues, wrongBefore, notes
end

--- WHAT THE CHECK SAYS OF ANOTHER PART'S TURNS AND THE ROAD BETWEEN (split junctions, the user's rules 2
--- and 4 of 2026-10-03). A turn of another part's that no longer drives is a problem (kind "twin"),
--- whatever else is said there - unless it waits for the build (r.waits, see jxCheckTwin): then a
--- note (kind "twinwait"). And with through roads off, a piece of main road lying between this
--- part and another, left with a lane start at one end and a lane end at the other - the road between
--- the two once both are cleared - is said as left on purpose, for the builder to join to (a note,
--- not a problem): a plain run of points (one way in, one way out), within 12 m of the line between
--- the two parts and no further along it than a fifth of that line past either part (a cut can lie
--- just past a part's saved point: at 26, cleared 26s's lane north starts 0.3 m past it), with a
--- point in this junction's area or within 15 m of its middle.
local function jxCheckTwinReport(C)
    local at = C.at
    for _, r in ipairs(C.twinMoves or {}) do
        -- turn: where the turn ran, for the harness (dbgtwin.lua) to tell which turn it is
        if not r.ok and r.waits then
            C.notes[#C.notes + 1] = { kind = "twinwait", x = r.a.x, z = r.a.z, turn = r.pts,
                text = string.format("%s's turn from %s to %s waits for the build: %s", r.name, at(r.a.x, r.a.z), at(r.b.x, r.b.z), r.why) }
        elseif not r.ok then
            C.issues[#C.issues + 1] = { kind = "twin", x = r.a.x, z = r.a.z, far = nil, turn = r.pts,
                text = string.format("%s's turn from %s to %s does not drive now: %s", r.name, at(r.a.x, r.a.z), at(r.b.x, r.b.z), r.why) }
        end
    end
    local parts = C.parts
    if C.leave or parts == nil or parts.here == nil then return end
    local here = parts.here
    local seen = {}
    local function nbs(w)
        local list, set = {}, {}
        for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
            for _, id in ipairs(lst) do
                local t = C.node(id)
                if t ~= nil and t ~= w and not set[t] then set[t] = true list[#list + 1] = t end
            end
        end
        return list
    end
    for _, P in ipairs(parts.others) do
        local vx, vz = P.x - here.x, P.z - here.z
        local L2 = vx * vx + vz * vz
        local function inCorridor(w)
            if L2 < 1e-6 then return false end
            local t = ((w.x - here.x) * vx + (w.z - here.z) * vz) / L2
            if t < -0.2 or t > 1.2 then return false end
            return math.sqrt((w.x - here.x - vx * t) ^ 2 + (w.z - here.z - vz * t) ^ 2) <= 12
        end
        for _, w in ipairs(C.near) do
            if not seen[w] and inCorridor(w) and #(w.incoming or {}) == 0 and #(w.out or {}) == 1 then
                -- a lane start: follow its one way on to a lane end
                local run, cur, ok = { w }, w, false
                for _ = 1, 40 do
                    local outs = cur.out or {}
                    if #outs == 0 then ok = (#(cur.incoming or {}) == 1) break end
                    if #outs ~= 1 then break end
                    local t = C.node(outs[1])
                    if t == nil or t == w or not inCorridor(t) or #nbs(t) > 2 then break end
                    run[#run + 1] = t
                    cur = t
                end
                if ok and #run >= 2 then
                    local mine = false
                    for _, v in ipairs(run) do
                        seen[v] = true
                        if C.inA[v] or C.dist(v) <= 15 then mine = true end
                    end
                    if mine then
                        local len = 0
                        for k = 2, #run do
                            len = len + math.sqrt((run[k].x - run[k - 1].x) ^ 2 + (run[k].z - run[k - 1].z) ^ 2)
                        end
                        local a, b = run[1], run[#run]
                        C.notes[#C.notes + 1] = { x = a.x, z = a.z,
                            text = string.format("the road between %s and %s, from %s to %s (%.1f m), is left as a piece of main road for the builder to join to - on purpose (both parts cleared, through roads off)",
                                here.name, P.name, at(a.x, a.z), at(b.x, b.z), len) }
                    end
                end
            end
        end
    end
end

--- What the check found, in the log and on the card. Plain words, one name for each thing: a "teal
--- dot" everywhere (the log once said "merge point" and the card "teal dot", for the same dot).
---
--- Every reason a join or teal dot can be left for, worst first. `card` is the few words the card
--- has room for; `short` names the group in the log's summary line.
local JX_REASONS = {
    { key = "made", short = "made during the clear", card = "joined by the clear" },
    { key = "crossmade", short = "where the clear joined the two kept through roads", card = "clear joined kept roads" },
    { key = "new", short = "made by the clear", card = "made by the clear" },
    { key = "selfmade", short = "left of two ways meeting, now one lane joining itself", card = "left of a cut turn" },
    { key = "tail", short = "fed by the end of a turn the clear cut", card = "end of a cut turn" },
    { key = "twinstuck", short = "another part's turn, left but not drivable now", card = "next part's turn, not drivable now" },
    { key = "missed", short = "missed by the clear", card = "missed" },
    { key = "nobox", short = "where no box could be built", card = "no box here" },
    { key = "through", short = "a through road still running through", card = "through road runs on" },
    { key = "part", short = "another part's own wiring", card = "next part's wiring" },
    { key = "twinwait", short = "another part's turn, waiting for the build", card = "next part's turn, waits for the build" },
    { key = "twin", short = "another part's turn, left working", card = "next part's turn, left working" },
    { key = "oneroad", short = "one road's own lanes", card = "one road's own lanes" },
    { key = "selfjoin", short = "one lane joining itself, as before the clear", card = "lane joins itself" },
    { key = "crossing", short = "where the kept through roads cross, as before the clear", card = "where kept roads cross" },
}

local function jxCheckReport(C)
    local joins, dots, issues, wrongBefore, notes = C.joins, C.dots, C.issues, C.wrongBefore, C.notes or {}
    local at = C.at
    local KIND = { twin = 0, gone = 1, stayed = 2, new = 3, vanished = 4, moved = 5, link = 6, flip = 7,
                   through = 8, stub = 9, spur = 10, leftover = 11, reach = 12 }
    table.sort(issues, function(p, q)
        if p.kind ~= q.kind then return (KIND[p.kind] or 99) < (KIND[q.kind] or 99) end
        if p.x ~= q.x then return p.x < q.x end
        if p.z ~= q.z then return p.z < q.z end
        return p.text < q.text
    end)
    table.sort(dots, function(p, q)
        if p.x ~= q.x then return p.x < q.x end
        if p.z ~= q.z then return p.z < q.z end
        return p.why < q.why
    end)
    for _, list in ipairs({ wrongBefore, notes }) do
        table.sort(list, function(p, q)
            if p.x ~= q.x then return p.x < q.x end
            if p.z ~= q.z then return p.z < q.z end
            return p.text < q.text
        end)
    end
    local function partName(p)
        if p == nil then return "the next part" end
        if p.name ~= nil then return p.name end
        return string.format("the part %.0f m %s", math.sqrt((p.x - C.cx) ^ 2 + (p.z - C.cz) ^ 2),
            JX_WORD[jxCompass(p.x - C.cx, p.z - C.cz)] or "away")
    end
    -- Where two kept roads were joined, the clear had sometimes moved them together first: at 30 the
    -- two roads came within 0.75 m of each other before the clear, and a point of each stood 0.28 m
    -- apart when the two were folded. Said as both, so "0.28 m apart" is not read as how they stood.
    local function movedFirst(it)
        return it.fold ~= nil and it.foldWas ~= nil and it.foldWas - it.fold >= 0.05
    end
    local function why(it)
        local w = it.why
        if w == "missed" then return "a connection the clear missed" end
        if w == "made" then
            if it.foldAt and it.linkFrom ~= nil then
                return string.format("the clear made this join: its clean-up folded two points, %.2f m apart, into one at %s, joining two ways that did not meet",
                    it.fold or 0, at(it.linkFrom.x, it.linkFrom.z))
            end
            if it.linkFrom ~= nil then
                return string.format("joined by a link that was not there before the clear, from %s to %s",
                    at(it.linkFrom.x, it.linkFrom.z), at(it.linkTo.x, it.linkTo.z))
            end
            return "a connection that did not drive before the clear"
        end
        if w == "crossing" then
            return "where the two kept through roads cross, which shared this point before the clear too (nothing keeps them apart there yet)"
        end
        if w == "crossmade" then
            if movedFirst(it) then
                return string.format("where the two kept through roads cross - the clear joined them here: before it they shared no point, the nearest two %.2f m apart; it moved a point of each together first, to %.2f m, and then folded the two into one", it.foldWas, it.fold)
            end
            if it.fold ~= nil then
                return string.format("where the two kept through roads cross - the clear joined them here: they shared no point before it, and it folded a point of each, %.2f m apart, into one", it.fold)
            end
            return "where the two kept through roads cross - the clear joined them here: they shared no point before it"
        end
        if w == "nobox" then return "no box could be built here, so the clear could not cut everything in the middle" end
        if w == "through" then return "a through road still runs through, though through roads were not kept" end
        if w == "selfjoin" then return "one lane splitting and joining itself again, not two roads" end
        if w == "selfmade" then
            local s = string.format("one lane now splits at %s and joins itself again here, left so by the clear", at(it.fx or it.x, it.fz or it.z))
            if it.fold ~= nil then
                s = s .. string.format(": its clean-up folded two points %.2f m apart there into one", it.fold)
            end
            if it.was then s = s .. "; before the clear, two separate ways met here" end
            return s
        end
        if w == "tail" then
            return string.format("the end of a turn the clear cut: its last stretch, from %s, is fed by nothing now but still joins the lane here",
                at(it.fx or it.x, it.fz or it.z))
        end
        if w == "new" then return "the clear made it: there was no teal dot here before" end
        if w == "oneroad" then return "one road's own lanes splitting or ending here, not two roads joined" end
        if w == "part" then return string.format("%s's own wiring, which this clear leaves alone", partName(it.part)) end
        if w == "twin" then
            local t = it.twin or {}
            return string.format("%s's turn, left working: it still drives end to end", t.name or "another part")
        end
        if w == "twinwait" then
            local t = it.twin or {}
            return string.format("%s's turn, left for %s: it waits for the build - %s", t.name or "another part",
                t.name or "that part", t.why or "its way on or off is this clear's cut lane")
        end
        if w == "twinstuck" then
            local t = it.twin or {}
            return string.format("%s's turn, left for %s, but it does not drive now: %s", t.name or "another part",
                t.name or "that part", t.why or "it was not followed end to end")
        end
        return w
    end
    -- Whether the dot is old is worth saying only where the reason does not say it already.
    local SAYS_WHEN = { made = true, crossmade = true, new = true, selfmade = true, tail = true }
    local function count(n, one, many)
        if n == 1 then return "1 " .. one end
        return string.format("%d %s", n, many)
    end
    local function both(nj, nd, sep)
        local parts = {}
        if nj > 0 then parts[#parts + 1] = count(nj, "join", "joins") end
        if nd > 0 then parts[#parts + 1] = count(nd, "teal dot", "teal dots") end
        return table.concat(parts, sep)
    end
    local nJoin, nDot = #joins, #dots
    local byJ, byD = {}, {}
    for _, j in ipairs(joins) do byJ[j.why] = (byJ[j.why] or 0) + 1 end
    for _, d in ipairs(dots) do byD[d.why] = (byD[d.why] or 0) + 1 end
    local groups = {}
    for _, R in ipairs(JX_REASONS) do
        local nj, nd = byJ[R.key] or 0, byD[R.key] or 0
        if nj + nd > 0 then groups[#groups + 1] = { R = R, nj = nj, nd = nd } end
    end
    local num = nil
    if C.jp ~= nil then num = C.jp.junctionNumber end
    -- By the name the lock was given ("j39se" once 39 is split), so the line says which part was
    -- cleared; the bare number where there is no name.
    local name = C.name
    if name == nil and num ~= nil then name = string.format("j%02d", num) end
    local label = ""
    if name ~= nil then label = string.format(" (%s)", name) end
    -- What was looked at is said every time, and said as a place, not a radius: "looked at 23 m out"
    -- at 39 read as everything within 23 m, while a teal dot 20 m out past the junction's edge - the
    -- next part's own - was rightly not mentioned.
    local looked = string.format("looked at: the middle, up to %.0f m out inside this junction's edge, and teal dots the clear left up to 45 m out", C.midR)
    local middle
    if nJoin + nDot == 0 then
        middle = string.format("middle empty (%s)", looked)
    else
        local named = {}
        for _, g in ipairs(groups) do
            named[#named + 1] = string.format("%s %s", both(g.nj, g.nd, " and "), g.R.short)
        end
        if #groups == 1 and nJoin + nDot > 1 then named = { "all " .. groups[1].R.short } end
        if #groups == 1 and nJoin + nDot == 1 then named = { groups[1].R.short } end
        middle = string.format("%s left (%s): %s", both(nJoin, nDot, " and "), looked, table.concat(named, ", "))
    end
    local elsewhere = "nothing else touched"
    if #issues > 0 then elsewhere = count(#issues, "other problem found", "other problems found") end
    if #notes > 0 then elsewhere = elsewhere .. "; " .. count(#notes, "note", "notes") end
    Logging.info("[FlyoverEditor]: junction - check after the clear%s: %s; %s.", label, middle, elsewhere)
    for _, j in ipairs(joins) do
        -- A lane that starts inside the junction is named as the lane out it is, and where it starts:
        -- "the lane starting on the north-east" at 40 named a stub 5 m south-east of the middle -
        -- the start of the lane out to the north-east.
        local lane = string.format("the lane in from the %s", j.from)
        if j.starts and j.startAt ~= nil then
            lane = string.format("the lane out to the %s, from its start at %s,", j.from, at(j.startAt.x, j.startAt.z))
        end
        local still = "still"
        if not j.was then still = "now" end
        if j.uturn then
            Logging.info("[FlyoverEditor]: junction - check: %s %s turns back out along the same road at %s - %s.",
                lane, still, at(j.x, j.z), why(j))
        elseif j.offLanes then
            -- Leaves onto a road none of this junction's lanes is on (jxDriveOn reached none). Not
            -- "none of this junction's own": the road is only one the clear found no lane of - at 40
            -- it is the south-east road, the junction's own main road by the user's reading, which
            -- the clear read as running west to north-east.
            Logging.info("[FlyoverEditor]: junction - check: %s %s joins a road the clear did not count as one of this junction's, leaving to the %s, at %s - %s.",
                lane, still, j.to, at(j.x, j.z), why(j))
        else
            Logging.info("[FlyoverEditor]: junction - check: %s %s joins the lane out to the %s at %s - %s.",
                lane, still, j.to, at(j.x, j.z), why(j))
        end
    end
    for _, d in ipairs(dots) do
        local tail = ""
        if not SAYS_WHEN[d.why] then
            if d.was then tail = "; it was a teal dot before the clear too" else tail = "; there was no teal dot here before the clear" end
        end
        Logging.info("[FlyoverEditor]: junction - check: a teal dot (AutoDrive's merge point) is left at %s - %s%s.",
            at(d.x, d.z), why(d), tail)
    end
    for _, it in ipairs(issues) do
        Logging.info("[FlyoverEditor]: junction - check: at %s, %s.", at(it.x, it.z), it.text)
    end
    for _, it in ipairs(notes) do
        Logging.info("[FlyoverEditor]: junction - check (note): at %s, %s.", at(it.x, it.z), it.text)
    end
    for _, it in ipairs(wrongBefore) do
        Logging.info("[FlyoverEditor]: junction - check (not this clear's doing): at %s, %s.", at(it.x, it.z), it.text)
    end

    -- THE CARD: one short line, two when both checks have something to say. A note row is a single
    -- line, drawn as it is - it is neither wrapped nor shrunk to fit - so each says the main thing
    -- and leaves the rest to the log. Joins and teal dots are counted apart - "(12)" at 16 added the
    -- two together without saying so - and what is named is the worst reason found, as a reason and
    -- with no number of its own: "3 joins, 2 teal dots left (3 clear joined kept roads)" at 30 added
    -- two joins and a teal dot of one reason together, and read as three kept roads. The second line names
    -- the worst kind of problem, not a bare count: "1 other change" read like damage where the only
    -- thing found was the respacing going 1 m too far.
    local card = {}
    -- THE OTHER PARTS BY NAME ON THE CARD. "next part's wiring" named nobody: after clearing 39se the
    -- user was asked to find the check naming 39's wiring as 39's, and the card is the check they
    -- read - the names were in the log alone. So where every part the check names has a name
    -- ("j39", "j39nw"), the card says them; a part known only by where it lies ("the part 20 m
    -- north-west") is too long for the card's one line, which then keeps the short words.
    local function cardWhy(g)
        if g.R.key == "twin" or g.R.key == "twinwait" or g.R.key == "twinstuck" then
            local names, seen = {}, {}
            for _, list in ipairs({ joins, dots }) do
                for _, it in ipairs(list) do
                    local n = it.why == g.R.key and it.twin and it.twin.name or nil
                    if n ~= nil and not seen[n] then seen[n] = true names[#names + 1] = n end
                end
            end
            if #names == 0 then return g.R.card end
            table.sort(names)
            if g.R.key == "twinstuck" then return table.concat(names, "'s and ") .. "'s turn, not drivable now" end
            if g.R.key == "twinwait" then return table.concat(names, "'s and ") .. "'s turn, waits for the build" end
            return table.concat(names, "'s and ") .. "'s turn, left working"
        end
        if g.R.key ~= "part" then return g.R.card end
        local names, seen = {}, {}
        for _, list in ipairs({ joins, dots }) do
            for _, it in ipairs(list) do
                if it.why == "part" then
                    if it.part == nil or it.part.name == nil then return g.R.card end
                    if not seen[it.part.name] then
                        seen[it.part.name] = true
                        names[#names + 1] = it.part.name
                    end
                end
            end
        end
        if #names == 0 then return g.R.card end
        table.sort(names)
        return table.concat(names, "'s and ") .. "'s own wiring"
    end
    local first
    if nJoin + nDot == 0 then
        first = "Check: middle empty"
    elseif #groups == 1 then
        first = string.format("Check: %s - %s", both(nJoin, nDot, ", "), cardWhy(groups[1]))
    else
        first = string.format("Check: %s - worst: %s", both(nJoin, nDot, ", "), cardWhy(groups[1]))
    end
    local noted = ""
    if #notes > 0 then noted = string.format(" (%s)", count(#notes, "note", "notes")) end
    if #issues == 0 then
        if nJoin + nDot == 0 then
            card[1] = first .. ", nothing else touched" .. noted
        else
            card[1] = first
            card[2] = "nothing else touched" .. noted
        end
    else
        card[1] = first
        local kinds, reachFar = {}, 0
        local ORDER = { "twin", "through", "stub", "flip", "spur", "leftover", "change", "reach" }
        for _, it in ipairs(issues) do
            local k = it.kind
            if k ~= "twin" and k ~= "through" and k ~= "stub" and k ~= "flip" and k ~= "spur" and k ~= "leftover" and k ~= "reach" then
                k = "change"
            end
            kinds[k] = (kinds[k] or 0) + 1
            if k == "reach" and (it.far or 0) > reachFar then reachFar = it.far end
        end
        local SAY = {
            twin = { "turn of another part does not drive now", "turns of other parts do not drive now" },
            through = { "road cut", "roads cut" },
            stub = { "lane turned round", "lanes turned round" },
            flip = { "link turned round", "links turned round" },
            spur = { "lane split into dead ends", "lanes split into dead ends" },
            leftover = { "piece of a cut turn left", "pieces of cut turns left" },
            change = { "change no part made", "changes no part made" },
            reach = { "edit outside the junction", "edits outside the junction" },
        }
        local said, more = nil, 0
        for _, k in ipairs(ORDER) do
            if kinds[k] ~= nil then
                if said == nil then
                    said = count(kinds[k], SAY[k][1], SAY[k][2])
                    if k == "reach" then said = string.format("%s, to %.0f m", said, reachFar) end
                else
                    more = more + kinds[k]
                end
            end
        end
        if more > 0 then said = string.format("%s, %d more", said, more) end
        card[2] = said .. " - see the log"
    end
    return { number = num, name = name, x = C.cx, z = C.cz, middleR = C.midR, leave = C.leave, joins = joins, dots = dots,
             issues = issues, wrongBefore = wrongBefore, notes = notes, card = card,
             middleEmpty = (nJoin + nDot == 0), untouched = (#issues == 0) }
end

-- MODSPLIT: SHARED WITH THE FILES LOADED AFTER THIS ONE (tools/modsplit/split.py writes this block)
ADFlyoverEditor.shared.jxCheckKept = jxCheckKept
ADFlyoverEditor.shared.jxCheckLanes = jxCheckLanes
ADFlyoverEditor.shared.jxCheckMiddle = jxCheckMiddle
ADFlyoverEditor.shared.jxCheckPassages = jxCheckPassages
ADFlyoverEditor.shared.jxCheckReport = jxCheckReport
ADFlyoverEditor.shared.jxCheckSetup = jxCheckSetup
ADFlyoverEditor.shared.jxCheckTouched = jxCheckTouched
ADFlyoverEditor.shared.jxCheckTwin = jxCheckTwin
ADFlyoverEditor.shared.jxCheckTwinReport = jxCheckTwinReport
-- MODSPLIT: end of the shared block

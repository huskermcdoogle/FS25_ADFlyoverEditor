-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua
-- loads it after FlyoverEditor.lua, in the old file's order.
-- MODSPLIT: HELPERS FROM THE FILES LOADED BEFORE THIS ONE (tools/modsplit/split.py writes this block)
for _, name in ipairs({ "JUNCTION_FORK_LINK", "junctionCentroidClusters", "jxBeforeInPlace", "jxByPlace", "jxCrossingPairs" }) do
    if ADFlyoverEditor.shared == nil or ADFlyoverEditor.shared[name] == nil then
        Logging.error("[FlyoverEditor]: JxFind.lua needs %s, which no file loaded before it shares", name)
    end
end
local JUNCTION_FORK_LINK = ADFlyoverEditor.shared.JUNCTION_FORK_LINK
local junctionCentroidClusters = ADFlyoverEditor.shared.junctionCentroidClusters
local jxBeforeInPlace = ADFlyoverEditor.shared.jxBeforeInPlace
local jxByPlace = ADFlyoverEditor.shared.jxByPlace
local jxCrossingPairs = ADFlyoverEditor.shared.jxCrossingPairs
-- MODSPLIT: end of the helpers

-- THE VIRGIN FORM OF A JUNCTION, found ONE way for everyone who asks. The selection needs it to
-- lock onto a cleared junction and the registry needs it to keep that junction's name, and if the
-- two each had their own idea of it, the card would sooner or later name a site the tool refuses
-- to lock, or lock one it cannot name.
--
-- Lane ends only form clusters of their OWN, away from any fork cluster - an end dangling beside a
-- wired junction is that junction's debris, not a second junction - and it takes three of them,
-- since two lane ends facing each other is a gap in a road. `forkSites` are centroid clusters of
-- forks (JUNCTION_FORK_LINK); `ends` are the points with exactly one neighbour.
local function junctionVirginSites(forkSites, ends)
    local loose = {}
    for _, e in ipairs(ends) do
        local nearFork = false
        for _, s in ipairs(forkSites) do
            if (s.x - e.x) ^ 2 + (s.z - e.z) ^ 2 <= 15 * 15 then nearFork = true break end
        end
        if not nearFork then loose[#loose + 1] = e end
    end
    local out = {}
    for _, s in ipairs(junctionCentroidClusters(loose, 14)) do
        if #s.nodes >= 3 then
            s.virgin = true
            out[#out + 1] = s
        end
    end
    return out
end

--- WHICH NETWORK A KEPT ANSWER WAS WORKED OUT ON. junctionCentres, junctionVirginCentres and
--- junctionRegistry keep their last answer while the number of points is unchanged. But undo and
--- redo put back a COPY of the whole network (EditorHistory's restore), with the same number of
--- points as before the clear, and the kept answer then named point tables that were no longer the
--- network's - moved by the clear that was undone, and renumbered by it. At 24, cleared in game right
--- after 16 had been cleared and undone, its forks were such dead points: the arms were walked from
--- the wrong live points, the bound read the two-way west road as not this junction's beyond 12 m,
--- and the tidy laid the road's new end one way only, the wrong way for traffic leaving. At 65,
--- cleared again after an undo, the check read its middle out to 30 m instead of 12. Point 1 stands
--- for the whole network: an edit in place keeps that table (or changes the count), and a swap of the
--- whole network - undo, redo, a route loaded - replaces it. Not the list table itself: the harness
--- makes a new list on every removal, and AutoDrive does not, so the two would stop agreeing.
--- Still not seen: an edit that moves points or links without changing the count (the move tool).
local function jxNetworkMark() return ADGraphManager:getWayPointById(1) end
local function jxSameNetwork(mark) return mark == ADGraphManager:getWayPointById(1) end

--- WHERE THE ROADS MEET, found from the roads and not from the forks. A cluster of forks is where
--- CONNECTORS START, and at a wide junction the tie forks sit 15-20 m out along every arm: clustering
--- them finds several "junctions" around one, puts the chosen one's middle on one end of it, and
--- leaves every later step - scope, arms, box, whose wiring is whose - working from the wrong place.
---
--- A turn connector bends from one road into another, so its two END TANGENTS, carried on, meet at
--- the corner it cuts - which is where those two roads cross. Every connector of a junction points
--- at the same spot, a kickout that starts 20 m up an arm included, so a junction's own far tie
--- forks need no rule to be recognised as its own; and a genuine neighbour is a different spot.
--- Checked against 34 hand labels of "separate junction" / "part of this one": all 34.
---
--- FLYOVER_JUNCTION_MERGE is how close two meeting points must be to count as ONE junction, and
--- it is the whole of the difference between reading a staggered crossing as two T's (10 m) or as
--- one offset 4-way (20 m).
---
--- It cannot see a junction with no connectors (a cleared one - the ring of lane ends finds those)
--- nor a shallow merge, whose branches leave at 15 degrees and cut no corner. Where it finds
--- nothing the selection falls back to the fork clusters, exactly as before.
--- WHERE A JUNCTION USED TO BE. A cleared junction has no connectors left to point at its middle,
--- so junctionCentres cannot see it - and everything around it then belongs to whatever wired
--- junction is nearest, which at a close pair is its neighbour. Clearing one of a pair and then the
--- other therefore ate the first one's road. What a cleared junction DOES have is a ring of lane
--- ends facing each other across where the roads met, and that ring is as good a marker as the
--- connectors were. Three or more, away from any fork, and their middle is the junction.
function ADFlyoverEditor:junctionVirginCentres()
    local count = ADGraphManager:getWayPointsCount()
    if self._jxVirgin ~= nil and self._jxVirginCount == count and jxSameNetwork(self._jxVirginNet) then
        return self._jxVirgin
    end
    local forks, ends = {}, {}
    for _, w in pairs(ADGraphManager:getWayPoints()) do
        if w ~= nil and w.id ~= nil then
            local s2, d = {}, 0
            for _, id in ipairs(w.out or {}) do if not s2[id] then s2[id] = true d = d + 1 end end
            for _, id in ipairs(w.incoming or {}) do if not s2[id] then s2[id] = true d = d + 1 end end
            if d >= 3 then forks[#forks + 1] = w elseif d == 1 then ends[#ends + 1] = w end
        end
    end
    local loose = {}
    for _, e in ipairs(ends) do
        -- Only a fork that is NOT itself a cut lane end's neighbour counts as "this end belongs to a
        -- wired junction": at a close pair the cleared branch's ends sit a few metres from the other
        -- junction's forks, and excluding them left the cleared junction invisible.
        local nearFork = false
        for _, f in ipairs(forks) do
            if (f.x - e.x) ^ 2 + (f.z - e.z) ^ 2 <= 4 * 4 then nearFork = true break end
        end
        if not nearFork then loose[#loose + 1] = e end
    end
    local used, out = {}, {}
    for i = 1, #loose do
        if not used[i] then
            used[i] = true
            local grp, sx, sz, grew = { loose[i] }, loose[i].x, loose[i].z, true
            while grew do
                grew = false
                for j = 1, #loose do
                    if not used[j] then
                        local mx, mz = sx / #grp, sz / #grp
                        if (loose[j].x - mx) ^ 2 + (loose[j].z - mz) ^ 2 <= 14 * 14 then
                            used[j] = true
                            grp[#grp + 1] = loose[j]
                            sx, sz, grew = sx + loose[j].x, sz + loose[j].z, true
                        end
                    end
                end
            end
            -- TWO IS ENOUGH TO OWN A ROAD. A junction cleared with through paths kept loses only its
            -- branch, so it shows just the two ends of that branch - not the three or more a fully
            -- cleared one shows. For SELECTION that is too little to call a junction; for saying
            -- whose road is whose it is plenty, and without it a cleared neighbour owns nothing and
            -- its road is eaten by the next clear along.
            if #grp >= 2 then
                out[#out + 1] = { x = sx / #grp, z = sz / #grp, n = #grp, virgin = true }
            end
        end
    end
    self._jxVirgin, self._jxVirginCount, self._jxVirginNet = out, count, jxNetworkMark()
    return out
end

-- WHERE LANES CROSS, ROADS MEET - the meeting points a corner cannot show. A shallow Y has no corner
-- to cut: its side road runs into the main road at 15-25 deg, its sharp turns double back past 150,
-- and the tangents the corners below are found by never meet. The Y at (788, 891) on the survey map
-- was three pairs of forks 18-20 m apart, numbered three times (j82, j83, j84 - "the same junction",
-- the user), and a clear on the middle pair left the far pair's turn behind. What every such Y does
-- have is lanes crossing: the side road's lane out crosses the main road's lane in, and the sharp
-- turns cross both, all within a few metres of each other. So the runs between forks are tested for
-- crossing one another, and where crossings gather with NO corner meeting point near them, they are
-- a meeting point of their own; its forks are the ends of the crossing runs.
-- Only where no corner is near (JX_CROSS_GAP): at a wired T or X the left turns cross each other
-- too, and those junctions are already found where they were - a second point beside each would move
-- every clear on the map. On the survey map that leaves three, all the same kind of Y (the user,
-- 2026-10-07: one rule for all three): the Y above, 36 at (887, 765) and 53 at (214, -756), whose
-- far turn 22 m out had been numbered by itself (j91). 36 and 53 were found before by their forks
-- (four or more within 15 m) - only 3 m closer together than the Y's - and clear a little
-- differently from this point.
-- Crossings at different heights are a bridge, not a junction (JX_CROSS_DY).
local JX_CROSS_GAP, JX_CROSS_LINK, JX_CROSS_DY = 25, 15, 2.5
local function jxLaneCrossingCentres(runs, corners)
    local boxes = {}
    for i, ch in ipairs(runs) do
        local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
        for _, w in ipairs(ch) do
            x0, z0, x1, z1 = math.min(x0, w.x), math.min(z0, w.z), math.max(x1, w.x), math.max(z1, w.z)
        end
        boxes[i] = { x0, z0, x1, z1 }
    end
    local pts = {}
    for i = 1, #runs do
        local A, ba = runs[i], boxes[i]
        for j = i + 1, #runs do
            local B, bb = runs[j], boxes[j]
            if ba[1] <= bb[3] and bb[1] <= ba[3] and ba[2] <= bb[4] and bb[2] <= ba[4] then
                for p = 1, #A - 1 do
                    local p1, p2 = A[p], A[p + 1]
                    for q = 1, #B - 1 do
                        local p3, p4 = B[q], B[q + 1]
                        if p1 ~= p3 and p1 ~= p4 and p2 ~= p3 and p2 ~= p4 then
                            local d1x, d1z, d2x, d2z = p2.x - p1.x, p2.z - p1.z, p4.x - p3.x, p4.z - p3.z
                            local den = d1x * d2z - d1z * d2x
                            if math.abs(den) > 1e-9 then
                                local t = ((p3.x - p1.x) * d2z - (p3.z - p1.z) * d2x) / den
                                local u = ((p3.x - p1.x) * d1z - (p3.z - p1.z) * d1x) / den
                                if t > 0.001 and t < 0.999 and u > 0.001 and u < 0.999 then
                                    local ya = (p1.y or 0) + ((p2.y or 0) - (p1.y or 0)) * t
                                    local yb = (p3.y or 0) + ((p4.y or 0) - (p3.y or 0)) * u
                                    local x, z = p1.x + d1x * t, p1.z + d1z * t
                                    local gap = true
                                    for _, c in ipairs(corners) do
                                        if (c.x - x) ^ 2 + (c.z - z) ^ 2 <= JX_CROSS_GAP * JX_CROSS_GAP then gap = false break end
                                    end
                                    if gap and math.abs(ya - yb) <= JX_CROSS_DY then
                                        pts[#pts + 1] = { x = x, z = z, a = A, b = B }
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    -- By position, so the sums below come out the same whatever order the runs were found in.
    table.sort(pts, function(a, b)
        if a.x ~= b.x then return a.x < b.x end
        return a.z < b.z
    end)
    local out, done = {}, {}
    for i = 1, #pts do
        if not done[i] then
            done[i] = true
            local grp, stack = {}, { i }
            while #stack > 0 do
                local k = table.remove(stack)
                grp[#grp + 1] = k
                for j = 1, #pts do
                    if not done[j] and (pts[j].x - pts[k].x) ^ 2 + (pts[j].z - pts[k].z) ^ 2 <= JX_CROSS_LINK * JX_CROSS_LINK then
                        done[j] = true
                        stack[#stack + 1] = j
                    end
                end
            end
            -- Two crossings at least: one lane over another, alone, is not yet a place roads meet.
            if #grp >= 2 then
                table.sort(grp)
                local c = { sx = 0, sz = 0, n = #grp, forks = {}, wiring = {}, crossed = true }
                for _, k in ipairs(grp) do
                    local p = pts[k]
                    c.sx, c.sz = c.sx + p.x, c.sz + p.z
                    for _, ch in ipairs({ p.a, p.b }) do
                        c.forks[ch[1]] = true
                        c.forks[ch[#ch]] = true
                        for m = 2, #ch - 1 do c.wiring[ch[m]] = true end
                    end
                end
                c.x, c.z = c.sx / c.n, c.sz / c.n
                out[#out + 1] = c
            end
        end
    end
    return out
end

function ADFlyoverEditor:junctionCentres()
    local count = ADGraphManager:getWayPointsCount()
    local merge = AutoDrive.FLYOVER_JUNCTION_MERGE or 10
    if self._jxCentres ~= nil and self._jxCentresCount == count and self._jxCentresMerge == merge
        and jxSameNetwork(self._jxCentresNet) then
        return self._jxCentres
    end
    local wps = ADGraphManager:getWayPoints()
    local deg = {}
    for _, w in pairs(wps) do
        if w ~= nil and w.id ~= nil then
            local s, n = {}, 0
            for _, id in ipairs(w.out or {}) do if not s[id] then s[id] = true n = n + 1 end end
            for _, id in ipairs(w.incoming or {}) do if not s[id] then s[id] = true n = n + 1 end end
            deg[w] = n
        end
    end
    local function wrap(d)
        while d > math.pi do d = d - 2 * math.pi end
        while d < -math.pi do d = d + 2 * math.pi end
        return d
    end
    -- TWO LANES CROSSING ARE NOT A FORK (39, in the game). Two turns crossing inside 39 had a point
    -- each 0.23 m apart, folded into one before the session (jxCrossingPairs). That point has two ways
    -- in and two ways out and read as a fork: it cut a 22 m turn in half, the half-turn's corner
    -- started 39's group early and let a stray corner in, and 39's middle moved 3.4 m. Its circle then
    -- cut the roads inside their bends, and the main road was no longer read as running through - cut
    -- at (0.9, -13.6). Each lane is walked straight through such a point, and it starts no chain.
    local passOn = {}
    for _, w in pairs(wps) do
        if w ~= nil and deg[w] == 4 then passOn[w] = jxCrossingPairs(w) end
    end
    for w in pairs(passOn) do deg[w] = 2 end
    local corners, runs = {}, {}
    for _, f in pairs(wps) do
        if f ~= nil and (deg[f] or 0) >= 3 then
            for _, oid in ipairs(f.out or {}) do
                local o = ADGraphManager:getWayPointById(oid)
                if o ~= nil then
                    local chain, prev, cur, len = { f, o }, f, o, math.sqrt((o.x - f.x) ^ 2 + (o.z - f.z) ^ 2)
                    while (deg[cur] or 0) == 2 and #chain < 200 and len <= 60 do
                        local nxt = passOn[cur] and passOn[cur][prev] or nil
                        if passOn[cur] == nil then
                            for _, nid in ipairs(cur.out or {}) do
                                local w = ADGraphManager:getWayPointById(nid)
                                if w ~= nil and w ~= prev then nxt = w break end
                            end
                        end
                        if nxt == nil then break end
                        len = len + math.sqrt((nxt.x - cur.x) ^ 2 + (nxt.z - cur.z) ^ 2)
                        prev, cur = cur, nxt
                        chain[#chain + 1] = cur
                    end
                    local last = chain[#chain]
                    if (deg[last] or 0) >= 3 and len <= 60 then runs[#runs + 1] = chain end
                    if #chain >= 3 and (deg[last] or 0) >= 3 and len <= 60 then
                        local a0 = math.atan2(chain[2].x - chain[1].x, chain[2].z - chain[1].z)
                        local a1 = math.atan2(last.x - chain[#chain - 1].x, last.z - chain[#chain - 1].z)
                        local turn = math.abs(wrap(a1 - a0))
                        if turn >= math.rad(30) and turn <= math.rad(150) then
                            local d1x, d1z, d2x, d2z = math.sin(a0), math.cos(a0), math.sin(a1), math.cos(a1)
                            local den = d1x * d2z - d1z * d2x
                            if math.abs(den) > 1e-6 then
                                local t = ((last.x - f.x) * d2z - (last.z - f.z) * d2x) / den
                                local px, pz = f.x + d1x * t, f.z + d1z * t
                                if (px - f.x) ^ 2 + (pz - f.z) ^ 2 <= 60 * 60 then
                                    corners[#corners + 1] = { x = px, z = pz, chain = chain }
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    local groups = {}
    for _, c in ipairs(corners) do
        local hit = nil
        for _, g in ipairs(groups) do
            if (c.x - g.x) ^ 2 + (c.z - g.z) ^ 2 <= merge * merge then hit = g break end
        end
        if hit == nil then
            hit = { x = c.x, z = c.z, sx = 0, sz = 0, n = 0, forks = {}, wiring = {} }
            groups[#groups + 1] = hit
        end
        hit.sx, hit.sz, hit.n = hit.sx + c.x, hit.sz + c.z, hit.n + 1
        hit.x, hit.z = hit.sx / hit.n, hit.sz / hit.n
        hit.forks[c.chain[1]] = true
        hit.forks[c.chain[#c.chain]] = true
        for i = 2, #c.chain - 1 do hit.wiring[c.chain[i]] = true end
    end
    local out = {}
    for _, g in ipairs(groups) do
        if g.n >= 2 then out[#out + 1] = g end
    end
    if AutoDrive.FLYOVER_JUNCTION_LANE_CROSSINGS ~= false then
        for _, c in ipairs(jxLaneCrossingCentres(runs, out)) do out[#out + 1] = c end
    end
    self._jxCentres, self._jxCentresCount, self._jxCentresMerge = out, count, merge
    self._jxCentresNet = jxNetworkMark()
    return out
end

--- STEP 1 OF A CLEAR: pick ONE junction from a click, and say whether it is a junction at all.
---
--- The cluster of forks nearest the cursor is the site. What it does NOT do is decide how much road
--- belongs to that site - that is a property of the road, settled later by walking each arm out to
--- the next fork - so two crossings a few metres apart may well land in one cluster here and still
--- be worked on separately afterwards.
---
--- REAL OR FAUX. A junction is where roads meet, so it needs at least three arms that actually go
--- somewhere. Counted by BEARING, not by lane, or a plain T with two lanes on each of its roads
--- reads as six arms; and measured by how far each one runs before it forks again or simply stops.
--- A field entrance, a lay-by, and the stub of a connector whose junction was removed years ago all
--- present as a third arm a few metres long, and clearing around one does damage for no gain.
---
--- Returns a site table, or nil and a reason - and a reason is meant to be shown, not swallowed:
--- refusing without saying why is indistinguishable from the tool being broken.
-- How far out an arm's direction is read (evaluate, below).
local JX_ARM_AIM = 12
function ADFlyoverEditor:junctionSelect(cx, cz)
    if cx == nil or cz == nil then return nil, "no cursor" end
    local SELECT = AutoDrive.FLYOVER_JUNCTION_SELECT_RADIUS or 20
    local MINARM = AutoDrive.FLYOVER_JUNCTION_MIN_ARM or 15
    local GATHER, LINK = 70, JUNCTION_FORK_LINK
    local WALK = 40

    local function neighbours(w)
        local s, n = {}, 0
        for _, id in ipairs(w.out or {}) do
            if not s[id] then s[id] = true n = n + 1 end
        end
        for _, id in ipairs(w.incoming or {}) do
            if not s[id] then s[id] = true n = n + 1 end
        end
        return s, n
    end

    -- A JUNCTION COMES IN TWO FORMS, and both are junctions. WIRED: its roads are joined by turn
    -- connectors, and it shows as a cluster of forks. VIRGIN: cleared, or never built - the roads
    -- cross but nothing joins them, and it shows as a ring of LANE ENDS facing each other across the
    -- crossing. The virgin form is the one a build starts from, and if anything it is the easier to
    -- recognise; a selection that only knew forks could not see a junction the moment it had been
    -- cleared.
    local forks, ends = {}, {}
    for _, w in pairs(ADGraphManager:getWayPoints()) do
        if w ~= nil and w.id ~= nil and (w.x - cx) ^ 2 + (w.z - cz) ^ 2 <= GATHER * GATHER then
            local _, deg = neighbours(w)
            if deg >= 3 then forks[#forks + 1] = w
            elseif deg == 1 then ends[#ends + 1] = w end
        end
    end

    -- Forks are clustered exactly as they always were, so a wired junction is found just where it
    -- was found before. The virgin sites come from the helper the registry shares (above), which
    -- holds the rule for them: clusters of lane ends, away from every fork cluster, three or more.
    local sites = junctionCentroidClusters(forks, LINK)
    for _, s in ipairs(junctionVirginSites(sites, ends)) do
        sites[#sites + 1] = s
    end
    if #sites == 0 then return nil, "no junction near the cursor" end

    for _, s in ipairs(sites) do s.d2 = (s.x - cx) ^ 2 + (s.z - cz) ^ 2 end
    table.sort(sites, function(a, b) return a.d2 < b.d2 end)
    if sites[1].d2 > SELECT * SELECT then
        return nil, string.format("the nearest junction is %.0f m away - click closer to it",
            math.sqrt(sites[1].d2))
    end

    -- REAL OR FAUX, asked of each candidate in turn from the nearest outwards: the first that passes
    -- is the site. Taking the nearest and stopping there let a stray cluster beside a real junction
    -- - three lane ends at a field gate - be picked, fail, and refuse the click outright with the
    -- real junction a few metres further on.
    local function evaluate(best, allowAim)
        local inCluster = {}
        for _, f in ipairs(best.nodes) do inCluster[f.id] = true end
        local arms = {}
        for _, f in ipairs(best.nodes) do
            local nb = neighbours(f)
            for id in jxByPlace(nb) do
                if not inCluster[id] then
                    local w = ADGraphManager:getWayPointById(id)
                    -- a way on that is one of this junction's own connectors is not an arm of it
                    if w ~= nil and best.wiring ~= nil and best.wiring[w] then w = nil end
                    if w ~= nil then
                        local len, prev, cur, hitFork = 0, f, w, false
                        local seen = { [f.id] = true }
                        local walked = {}
                        while cur ~= nil and len < WALK do
                            len = len + math.sqrt((cur.x - prev.x) ^ 2 + (cur.z - prev.z) ^ 2)
                            seen[cur.id] = true
                            walked[#walked + 1] = cur
                            local cnb, cdeg = neighbours(cur)
                            if cdeg >= 3 then hitFork = true break end
                            local nxt = nil
                            for nid in jxByPlace(cnb) do
                                if not seen[nid] then nxt = ADGraphManager:getWayPointById(nid) break end
                            end
                            if nxt == nil then break end
                            prev, cur = cur, nxt
                        end
                        -- THE WAY AN ARM GOES, 12 m out, as well as its first step (aimBearing; used only
                        -- where the first steps make fewer than three roads, below).
                        local aim = walked[#walked] or w
                        for _, q in ipairs(walked) do
                            if (q.x - best.x) ^ 2 + (q.z - best.z) ^ 2 >= JX_ARM_AIM * JX_ARM_AIM then aim = q break end
                        end
                        arms[#arms + 1] = {
                            bearing = math.atan2(w.x - best.x, w.z - best.z),
                            aimBearing = math.atan2(aim.x - best.x, aim.z - best.z),
                            -- Clamped, because the walk adds a whole segment before it re-tests the
                            -- cap: a 10 m hop at the end of a 39 m arm had the arm reported as 49 m,
                            -- and the bound is only ever as tight as the arm it is told about.
                            len = math.min(len, WALK), node = w, fork = hitFork,
                            stop = hitFork and cur or nil,
                            deadEnd = (not hitFork and len < WALK) and cur or nil,
                            walked = walked,
                        }
                    end
                end
            end
        end

        -- Fold the lanes of one road together: same bearing, so a two-lane road counts once. The arm
        -- keeps the LONGEST of its lanes - one lane of a road being stubbed does not shorten the road.
        -- TWO WAYS LEAVING ONE FORK SIDE BY SIDE AND PARTING LATER are one road by their first steps:
        -- at 101 (a T of farm tracks) the turn up to the north road and the track to the south-east leave
        -- the west road's fork 4 m apart, heading east, and the junction was refused as "only 2 roads" -
        -- it would not lock or clear (the user's 2026-10-08 test). So where the first steps make fewer
        -- than three roads, the arms are folded again by where they are 12 m out. Only then: read that
        -- way everywhere, the clears of 26 junctions that worked moved (19 cut 26 m out, not 14).
        local useAim = false
        do
            local seenB = {}
            for _, a in ipairs(arms) do
                local found = false
                for _, b in ipairs(seenB) do
                    local d = math.abs(a.bearing - b) % (2 * math.pi)
                    if d > math.pi then d = 2 * math.pi - d end
                    if d <= math.rad(30) then found = true break end
                end
                if not found then seenB[#seenB + 1] = a.bearing end
            end
            -- ...and only where every way out is a road in its own right, running the whole walk
            -- without forking: read 12 m out, a merge on the road between 87 and 88 (its ways forking
            -- again 17 and 25 m on) came out as three roads.
            local allRoads = true
            for _, a in ipairs(arms) do
                if a.fork or a.len < WALK - 1e-6 then allRoads = false break end
            end
            if #seenB < 3 and allowAim and allRoads then
                for _, a in ipairs(arms) do a.bearing = a.aimBearing end
                useAim = true
            end
        end
        local roads = {}
        for _, a in ipairs(arms) do
            local joined = nil
            for _, r in ipairs(roads) do
                local d = math.abs(a.bearing - r.bearing) % (2 * math.pi)
                if d > math.pi then d = 2 * math.pi - d end
                if d <= math.rad(30) then joined = r break end
            end
            if joined == nil then
                joined = { bearing = a.bearing, len = a.len, n = 1, fork = a.fork, stops = {}, deadEnds = {} }
                roads[#roads + 1] = joined
            else
                joined.n = joined.n + 1
                if a.len > joined.len then joined.len, joined.fork = a.len, a.fork end
            end
            if a.stop ~= nil then joined.stops[#joined.stops + 1] = a.stop end
            if a.deadEnd ~= nil then joined.deadEnds[#joined.deadEnds + 1] = a.deadEnd end
            joined.walked = joined.walked or {}
            for _, wn in ipairs(a.walked or {}) do joined.walked[wn] = true end
        end

        -- A CLEARED PART BESIDE ITS TWIN: an arm that runs into the twin's forks goes somewhere,
        -- however short. With the user's split saved and through roads off, a part's clear keeps
        -- the road its twin's turn leaves and stops short of it, so the arm from cleared 26s towards
        -- 26n ends 5 m out, at the fork 26n's left turn leaves the road from (best.partOf: the site
        -- found below, "A CLEARED PART OF A SPLIT JUNCTION").
        local inOther = {}
        if best.partOf then
            for _, s2 in ipairs(sites) do
                if s2 ~= best and not s2.virgin and s2.nodes ~= nil and #s2.nodes >= 2 then
                    for _, fk in ipairs(s2.nodes) do inOther[fk] = true end
                end
            end
        end
        local going = 0
        for _, r in ipairs(roads) do
            local toTwin = false
            if best.partOf then
                for _, st in ipairs(r.stops or {}) do
                    if inOther[st] and not inCluster[st.id] then toTwin = true end
                end
            end
            if r.len >= MINARM or toTwin then going = going + 1 end
        end
        if #roads < 3 then
            return nil, string.format("only %d road%s meets here - not a junction",
                #roads, #roads == 1 and "" or "s")
        end
        -- The arm-length test polices STRAYS - a lone fork, a field gate, a lay-by. A proper cluster
        -- of forks is a junction by the survey's own definition and is not asked to prove it: at a
        -- close pair, once the neighbour is cleared, the arm towards it ends at the neighbour's box
        -- 13 m away, and a junction with seven forks of wiring in it was refused as "a turning or
        -- an entrance" for having only two long arms.
        local proper = ((not best.virgin) and #best.nodes >= 4) or best.fromRoads == true
        if going < 3 and not proper then
            return nil, string.format("%d of the %d arms here go anywhere (the rest stop within %d m) - a turning or an entrance, not a junction",
                going, #roads, MINARM)
        end
        return { x = best.x, z = best.z, forks = best.nodes, roads = roads, nArms = #roads,
                 virgin = (best.virgin == true), fromRoads = (best.fromRoads == true) }
    end

    -- ...BUT NEVER PAST A REAL JUNCTION. Trying the next candidate is for stepping over a stray -
    -- three lane ends at a field gate. When the nearest candidate is itself a proper cluster of
    -- forks, that IS what was clicked on, and its verdict stands whether it passes or not: carrying
    -- on past it answered a click on a wired junction with the state of the one next door, 17 m
    -- away and already cleared - "this junction is already clear", said of a junction with seven
    -- forks still in it.
    -- A CLEARED PART OF A SPLIT JUNCTION, BESIDE ITS TWIN STILL WIRED. A cleared junction is found by
    -- its ring of lane ends, held 15 m clear of every fork - an end beside a wired junction is that
    -- junction's. The parts of a split can be closer than that: 26n and 26s are 12 m apart, and
    -- once 26s is cleared with through roads off and 26n left working (the user's rules of
    -- 2026-10-03), every lane end of 26s lies within 15 m of 26n's forks, no ring is found, and a
    -- click on cleared 26s locked 26n. So where the click is on a part the user saved (within 5 m,
    -- JX_PART_AT, which is declared further down), no place where roads meet lies within 8 m of it
    -- (it has no wiring of its own), another part of the same junction is still wired, and three or
    -- more lane ends lie within 15 m of it, those ends are that part's cleared site, asked the same
    -- questions as any other - but only where the usual selection below would lock a site 8 m or
    -- more from the part (its twin) or nothing at all: at 20, cleared 20s is found by its ring as
    -- before. Never where both parts are cleared (72, 73): the usual ring finds their shared middle.
    -- Read from the registry as it was last built (self._jxReg), never by building it: the registry
    -- asks this selection about every cleared site while it is being built.
    -- AutoDrive.FLYOVER_JUNCTION_PART_ROAD = false turns this off, with the road between parts.
    local onPart, partSite = nil, nil
    if self._jxReg ~= nil and AutoDrive.FLYOVER_JUNCTION_PART_ROAD ~= false then
        local centres = nil
        local function wiredAt(q)
            centres = centres or (self:junctionCentres() or {})
            for _, c in ipairs(centres) do
                if (c.x - q.x) ^ 2 + (c.z - q.z) ^ 2 <= 8 * 8 then return true end
            end
            for _, s2 in ipairs(sites) do
                if not s2.virgin and s2.nodes ~= nil and #s2.nodes >= 4
                    and (s2.x - q.x) ^ 2 + (s2.z - q.z) ^ 2 <= 8 * 8 then return true end
            end
            return false
        end
        for _, f in ipairs(self._jxReg) do
            if onPart == nil and f.decision == "split" and f.parts ~= nil then
                for _, p in ipairs(f.parts) do
                    if onPart == nil and (p.x - cx) ^ 2 + (p.z - cz) ^ 2 <= 5 * 5 and not wiredAt(p) then
                        local twinWired = false
                        for _, q in ipairs(f.parts) do
                            if q ~= p and wiredAt(q) then twinWired = true end
                        end
                        if twinWired then onPart = p end
                    end
                end
            end
        end
    end
    -- The cleared part's own site, tried only where the usual answer is its twin or nothing.
    local function partSiteFor(site)
        if onPart == nil then return site end
        if site ~= nil and (site.x - onPart.x) ^ 2 + (site.z - onPart.z) ^ 2 < 8 * 8 then return site end
        if partSite == nil then
            local own, sx, sz = {}, 0, 0
            for _, e in ipairs(ends) do
                if (e.x - onPart.x) ^ 2 + (e.z - onPart.z) ^ 2 <= 15 * 15 then
                    own[#own + 1] = e
                    sx, sz = sx + e.x, sz + e.z
                end
            end
            partSite = false
            if #own >= 3 then
                table.sort(own, jxBeforeInPlace)
                partSite = evaluate({ x = sx / #own, z = sz / #own, nodes = own, virgin = true, partOf = true }) or false
            end
            -- A T cleared with its through road kept leaves only its side road's two lane ends, too few
            -- to read as a junction, and the click went to the wired twin 20 m off (the course's 1e,
            -- 2026-10-15: its clear + build then built on 1w). The part was clicked and is known; it is
            -- the site, cleared.
            if not partSite then
                table.sort(own, jxBeforeInPlace)
                partSite = { x = onPart.x, z = onPart.z, nodes = own, virgin = true, partOf = true }
            end
        end
        if partSite then return partSite end
        return site
    end
    -- ROADS FIRST. Where the roads themselves say there is a junction near the click, that is the
    -- junction: its middle is where they meet, and its forks are the ends of the connectors that
    -- point there - however far up the arms those sit. The fork clusters below are only the
    -- fallback, for what the roads cannot show: a cleared junction (no connectors left to point
    -- anywhere) and a shallow merge (no corner cut). A cleared junction that is NEARER the click
    -- than any wired one still wins, so a virgin site beside a wired one can be picked.
    if AutoDrive.FLYOVER_JUNCTION_ROADS_FIRST ~= false then
        local bestC, bd = nil, SELECT * SELECT
        for _, c in ipairs(self:junctionCentres() or {}) do
            local d = (c.x - cx) ^ 2 + (c.z - cz) ^ 2
            if d < bd then bd, bestC = d, c end
        end
        local virginNearer = false
        for _, s in ipairs(sites) do
            if s.virgin and s.d2 < bd then virginNearer = true break end
        end
        if bestC ~= nil and not virginNearer then
            -- IN A FIXED ORDER. `forks` is a set keyed by the node TABLES, and Lua hashes a table
            -- key by its address, so pairs() walks it in whatever order the memory happened to fall
            -- in - a different order in every process. That order reaches the arms, and through them
            -- the box and what gets cleared: the same clear on the same network took 43 points
            -- reaching 43 m four runs out of five, and 42 points reaching 17 m on the fifth.
            --
            -- Sorted by POSITION, not by id, because ids are reissued by every removal while a
            -- point's place on the map is its own.
            local nodes = {}
            for fk in pairs(bestC.forks) do
                if fk.id ~= nil then nodes[#nodes + 1] = fk end
            end
            table.sort(nodes, function(a, b)
                if a.x ~= b.x then return a.x < b.x end
                if a.z ~= b.z then return a.z < b.z end
                return (a.y or 0) < (b.y or 0)
            end)
            local site = evaluate({ x = bestC.x, z = bestC.z, nodes = nodes, wiring = bestC.wiring, fromRoads = true })
            if site ~= nil then return partSiteFor(site) end
        end
    end
    local firstWhy = nil
    for _, s in ipairs(sites) do
        if s.d2 > SELECT * SELECT then break end
        local site, why = evaluate(s)
        if site ~= nil then return partSiteFor(site) end
        firstWhy = firstWhy or why
        if not s.virgin and #s.nodes >= 4 then break end
    end
    -- ...and only where none passes, the arms read 12 m out (evaluate's allowAim): read that way first,
    -- a fork group beside 86 that used to be refused was picked before its cleared site, and place
    -- refused it as still wired.
    for _, s in ipairs(sites) do
        if s.d2 > SELECT * SELECT then break end
        local site = evaluate(s, true)
        if site ~= nil then return partSiteFor(site) end
        if not s.virgin and #s.nodes >= 4 then break end
    end
    local ps = partSiteFor(nil)
    if ps ~= nil then return ps end
    return nil, firstWhy or "no junction near the cursor"
end

-- Where the numbers live between sessions: beside AutoDrive's own route file, in the savegame's
-- folder, because they name the junctions of THIS network and a second savegame on the same map
-- carries a different one. The folder is worked out the way AutoDrive works out its own
-- (XML.lua, getXMLFile_new), so the two files cannot end up in different places.
local JUNCTION_REGISTRY_FILE = "ADFlyoverEditor_junctions.xml"

local function junctionRegistryFolder()
    local info = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    if info == nil then return nil end
    if info.savegameDirectory ~= nil then return info.savegameDirectory .. "/" end
    if info.savegameIndex ~= nil and getUserProfileAppPath ~= nil then
        return getUserProfileAppPath() .. "savegame" .. info.savegameIndex .. "/"
    end
    return nil
end

-- WHOSE NUMBERS THEY ARE. The numbers and decisions in memory belong to the game they were read in
-- and the folder they were read from (the registry's "home"), and are only ever written back there.
-- This table outlives a mission: leave to the menu and load another savegame, and the old editor
-- keeps getting update() until its files are sourced again - and the folder, worked out afresh at
-- write time, was by then the other career's. A decision waiting for a career's first save was
-- written into the next career loaded, over that career's own numbers and decisions.
--
-- A folder compared as a folder: one slash kind, no doubled or trailing slash, any case (Windows).
-- A career's first save sets savegameDirectory, where the folder was worked out from the slot
-- number until then - the same folder, the same key.
local function jxFolderKey(folder)
    if folder == nil then return nil end
    return (folder:gsub("\\", "/"):gsub("/+", "/"):gsub("/$", ""):lower())
end

--- The game loaded now and its folder: what a registry read now belongs to.
local function jxHomeNow()
    local folder = junctionRegistryFolder()
    return { mission = g_currentMission, folder = folder, key = jxFolderKey(folder) }
end

--- Is `home` still the game loaded now, with the same folder?
local function jxHomeIsHere(home)
    if home == nil or g_currentMission == nil or home.mission ~= g_currentMission then return false end
    local folder = junctionRegistryFolder()
    if folder == home.folder then return true end
    return jxFolderKey(folder) == home.key
end

-- MODSPLIT: SHARED WITH THE FILES LOADED AFTER THIS ONE (tools/modsplit/split.py writes this block)
ADFlyoverEditor.shared.JUNCTION_REGISTRY_FILE = JUNCTION_REGISTRY_FILE
ADFlyoverEditor.shared.junctionRegistryFolder = junctionRegistryFolder
ADFlyoverEditor.shared.junctionVirginSites = junctionVirginSites
ADFlyoverEditor.shared.jxHomeIsHere = jxHomeIsHere
ADFlyoverEditor.shared.jxHomeNow = jxHomeNow
ADFlyoverEditor.shared.jxNetworkMark = jxNetworkMark
ADFlyoverEditor.shared.jxSameNetwork = jxSameNetwork
-- MODSPLIT: end of the shared block

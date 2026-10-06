-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua
-- loads it after FlyoverEditor.lua, in the old file's order.
-- MODSPLIT: HELPERS FROM THE FILES LOADED BEFORE THIS ONE (tools/modsplit/split.py writes this block)
for _, name in ipairs({ "isRoadAt", "junctionAngDiff", "junctionBiarc", "junctionBranchTurn", "junctionChainIndexNear", "junctionConnect", "junctionDisconnect", "junctionDubins", "junctionSegDir", "junctionWalkBack", "jxNoteAdded", "roadNote" }) do
    if ADFlyoverEditor.shared == nil or ADFlyoverEditor.shared[name] == nil then
        Logging.error("[FlyoverEditor]: JxSwept.lua needs %s, which no file loaded before it shares", name)
    end
end
local isRoadAt = ADFlyoverEditor.shared.isRoadAt
local junctionAngDiff = ADFlyoverEditor.shared.junctionAngDiff
local junctionBiarc = ADFlyoverEditor.shared.junctionBiarc
local junctionBranchTurn = ADFlyoverEditor.shared.junctionBranchTurn
local junctionChainIndexNear = ADFlyoverEditor.shared.junctionChainIndexNear
local junctionConnect = ADFlyoverEditor.shared.junctionConnect
local junctionDisconnect = ADFlyoverEditor.shared.junctionDisconnect
local junctionDubins = ADFlyoverEditor.shared.junctionDubins
local junctionSegDir = ADFlyoverEditor.shared.junctionSegDir
local junctionWalkBack = ADFlyoverEditor.shared.junctionWalkBack
local jxNoteAdded = ADFlyoverEditor.shared.jxNoteAdded
local roadNote = ADFlyoverEditor.shared.roadNote
-- MODSPLIT: end of the helpers

--- Drive the design rig through one movement with the stock-driver twin (SweptSim) and return the
--- predicted tracks and the trailer's worst inside cut-in relative to the connector. The simulated
--- route is: a 40 m straight run-in (extrapolated back along the entry lane), the entry lane's real
--- nodes up to the tie-in, the connector as it would be laid, the exit lane's real nodes from its
--- tie-in outward, and a 40 m straight run-out - the transitions are where the cut-in happens, so the
--- rig has to arrive already settled on the straight. Returns nil when the geometry is unusable.
function ADFlyoverEditor:junctionSweptPredict(fromAp, toAp, c, cx, cz, radius, rig)
    local chainA = self:junctionChain(fromAp, cx, cz, radius)
    local chainB = self:junctionChain(toAp, cx, cz, radius)
    local path = {}
    -- Entry lane: chain[1] is the boundary, increasing toward the interior; keep the nodes the tie-in
    -- lies AHEAD of (those the rig drives over before the connector starts).
    for k = 1, math.min(#chainA, junctionChainIndexNear(chainA, c.ax, c.az)) do
        local n = chainA[k]
        local dx, dz = junctionSegDir(chainA, k)
        if (c.ax - n.x) * dx + (c.az - n.z) * dz > 0.3 then
            path[#path + 1] = { x = n.x, y = n.y, z = n.z }
        end
    end
    path[#path + 1] = { x = c.ax, y = c.ay, z = c.az }
    for _, p in ipairs(c.points) do path[#path + 1] = { x = p.x, y = p.y, z = p.z } end
    local firstConnector = #path - #c.points     -- index of the tie-in A in `path`
    path[#path + 1] = { x = c.bx, y = c.by, z = c.bz }
    local lastConnector = #path
    -- Exit lane: walked from the boundary inward, so travel is index-DEcreasing; keep the nodes that
    -- lie beyond the tie-in in the outward direction, interior first.
    for k = math.min(#chainB, junctionChainIndexNear(chainB, c.bx, c.bz)), 1, -1 do
        local n = chainB[k]
        local dx, dz = junctionSegDir(chainB, k)
        if (n.x - c.bx) * -dx + (n.z - c.bz) * -dz > 0.3 then
            path[#path + 1] = { x = n.x, y = n.y, z = n.z }
        end
    end
    if #path < 3 then return nil end
    -- Straight run-in / run-out along the first / last real segment.
    local function unit(ax, az, bx, bz)
        local dx, dz = bx - ax, bz - az
        local l = math.sqrt(dx * dx + dz * dz)
        if l < 1e-6 then return nil end
        return dx / l, dz / l
    end
    local ux, uz = unit(path[1].x, path[1].z, path[2].x, path[2].z)
    local vx, vz = unit(path[#path - 1].x, path[#path - 1].z, path[#path].x, path[#path].z)
    if ux == nil or vx == nil then return nil end
    table.insert(path, 1, { x = path[1].x - ux * 40, y = path[1].y, z = path[1].z - uz * 40 })
    path[#path + 1] = { x = path[#path].x + vx * 40, y = path[#path].y, z = path[#path].z + vz * 40 }
    firstConnector, lastConnector = firstConnector + 1, lastConnector + 1

    local heading = math.atan2(ux, uz)
    local sim = SweptSim.simulate(path, rig, SweptSim.STOCK_DRIVER,
        { x = path[1].x, z = path[1].z, heading = heading, trailerHeading = heading, speed = 30, rot = 0 },
        { dt = 0.02, maxTime = 60, speedLimitKmh = 40 })
    if #sim < 10 then return nil end

    -- Cut-in is measured against the CONNECTOR only (its inside is the corner), for the steps whose
    -- trailer axle projects inside it. Turn sense from the connector's end tangents: with forward =
    -- (sin h, cos h) and left = (cos h, -sin h), a left turn has a NEGATIVE cross of entry x exit.
    local con = {}
    for k = firstConnector, lastConnector do con[#con + 1] = path[k] end
    local cross = ux * vz - uz * vx
    local leftTurn = cross < 0
    local trailerIn, towIn, trailerOut = 0, 0, 0
    local a, b = con[1], con[#con]
    local function insideConnector(px, pz)
        local inA = (px - a.x) * (con[2].x - a.x) + (pz - a.z) * (con[2].z - a.z) > 0
        local inB = (px - b.x) * (con[#con - 1].x - b.x) + (pz - b.z) * (con[#con - 1].z - b.z) > 0
        return inA and inB
    end
    -- The TURN EVENT: from the tow's rear axle entering the connector until the trailer axle has
    -- left it. The envelope probes below (road surface, obstacles) cover exactly this window - the
    -- trailer is still cutting inside after the tow is back on the exit road, and that cut is this
    -- turn's doing; whatever happens on the plain straights before and after is not.
    local started, ended = false, false
    local edges = {}          -- body-edge points to probe the road surface at
    local probeStep2 = (AutoDrive.FLYOVER_JUNCTION_SWEPT_PROBE_STEP or 1.0) ^ 2
    local probeX, probeZ = nil, nil   -- the tow's rear axle at the last set of edge probes
    local lineMargin = AutoDrive.FLYOVER_JUNCTION_SWEPT_LINE_MARGIN or 0.3
    local towTrack, trlTrack = {}, {}  -- axle tracks to probe obstacles along (within the window)
    local halfTow, halfTrl = (rig.towWidth or 2.5) / 2, (rig.trailerWidth or 2.5) / 2
    -- Past the exit tie-in B, in the direction of travel out of the connector.
    local function pastB(px, pz)
        return (px - b.x) * (b.x - con[#con - 1].x) + (pz - b.z) * (b.z - con[#con - 1].z) > 0
    end
    local trailerPt = (rig.trailerLength or 0) > 0
    -- Offsets are measured against the part of the route the rig is ACTUALLY ON, found from its
    -- progress along it - not against the nearest segment anywhere. The simulated route is long now
    -- (lane - connector - lane, ~47 m each way) and on a left turn its two legs pass close to each
    -- other near the crossing: nearest-segment picked the OTHER leg and reported nonsense (a tow
    -- "3 m inside", a trailer "2.6 m outside" on a turn that fits).
    local cumP = { 0 }
    for i = 2, #path do
        cumP[i] = cumP[i - 1] + math.sqrt((path[i].x - path[i - 1].x) ^ 2 + (path[i].z - path[i - 1].z) ^ 2)
    end
    local function offsetNear(px, pz, sLo, sHi)
        local best, signed = math.huge, 0
        for k = 1, #path - 1 do
            if cumP[k + 1] >= sLo and cumP[k] <= sHi then
                local a2, b2 = path[k], path[k + 1]
                local dx, dz = b2.x - a2.x, b2.z - a2.z
                local l2 = dx * dx + dz * dz
                if l2 > 1e-9 then
                    local u = math.max(0, math.min(1, ((px - a2.x) * dx + (pz - a2.z) * dz) / l2))
                    local qx, qz = a2.x + u * dx, a2.z + u * dz
                    local d = math.sqrt((px - qx) ^ 2 + (pz - qz) ^ 2)
                    if d < best then
                        best = d
                        signed = (((px - qx) * dz - (pz - qz) * dx) >= 0) and d or -d
                    end
                end
            end
        end
        return signed
    end
    local rigLen = (rig.trailerLength or 0) + math.abs(rig.hitchOffset or 0)
    for _, s in ipairs(sim) do
        local wpi = math.max(1, math.min(#path, s.wp or 1))
        local sTow = cumP[wpi] - math.sqrt((s.sx - path[wpi].x) ^ 2 + (s.sz - path[wpi].z) ^ 2)
        -- Starts a look-ahead distance BEFORE tie-in A: that is where the driver begins steering for
        -- the curve (so where the entry cut-in begins), and it does not depend on the tow ever
        -- entering the wedge between the tie-ins, which a hard shortcut can skip entirely.
        if not started then
            local tx, tz = con[2].x - a.x, con[2].z - a.z
            local tl = math.sqrt(tx * tx + tz * tz)
            if tl > 1e-6 and ((s.x - a.x) * tx + (s.z - a.z) * tz) / tl > -(rig.lookAhead or 6) then
                started = true
            end
        end
        if started and not ended then
            -- Cut-in is measured against the WHOLE simulated route (lane - connector - lane), not
            -- only while the axle sits in the wedge between the two tie-ins: on a tight turn the
            -- trailer shortcuts the corner so hard that it goes from "not yet past A" straight to
            -- "already past B" and never enters that wedge - every tight right turn reported 0.00 m.
            if trailerPt then
                local o = offsetNear(s.ax, s.az, sTow - rigLen - 10, sTow + 2)
                local inside = leftTurn and o or -o
                if inside > trailerIn then trailerIn = inside end
                if -inside > trailerOut then trailerOut = -inside end
            end
            -- The event ends when the LAST body - the trailer axle, or the tow's rear axle when
            -- there is no trailer - is past the exit tie-in. Closing it when the tow left the
            -- connector cut short right-turn quadrants before the trailer (9 m behind) had even
            -- entered: every right turn measured "0.00 m inside" and went unprobed.
            if trailerPt then
                if pastB(s.ax, s.az) and #trlTrack > 5 then ended = true end
            elseif pastB(s.x, s.z) and #towTrack > 5 then
                ended = true
            end
            do
                local ot = offsetNear(s.x, s.z, sTow - 8, sTow + 4)
                local insideT = leftTurn and ot or -ot
                if insideT > towIn then towIn = insideT end
            end
            if not ended then
                towTrack[#towTrack + 1] = { x = s.x, z = s.z }
                trlTrack[#trlTrack + 1] = { x = s.ax, z = s.az }
                -- Body edges: rear and front axle of the tow, and the trailer axle, each +-half width
                -- along the body's LEFT vector (cos h, -sin h) - all of them, once per probe step of
                -- the tow's travel. Per METRE, not per simulation step: the gate judges the share of
                -- probes off the road, and per step a slow corner got more of the probes than a fast
                -- one (j74's 5894 -> 9857 changed radius over it when the twin learned to slow
                -- down). The per-step version also kept every 18th point of sets of six, so it only
                -- ever probed the tow's rear-left corner - never the trailer, never the right side.
                -- Each edge also records whether it is ON THE LINE's own footprint - no further from
                -- the route than its body's half-width plus a margin, where it would be if the rig
                -- drove the lanes and the connector exactly. Only ground the TURN adds is the gate's
                -- to judge: the lanes are the existing road, not this turn's doing, and the
                -- connector's own strip is the corridor check's job. j59's 5279 -> 5241 was refused
                -- for its lane, which runs along the verge: 79 of 192 probes off the road, every one
                -- on the right, at half a body from the line, on a 2-3 point link the rig tracked
                -- to 0.01 m.
                if probeX == nil or (s.x - probeX) ^ 2 + (s.z - probeZ) ^ 2 >= probeStep2 then
                    probeX, probeZ = s.x, s.z
                    local lx, lz = math.cos(s.heading), -math.sin(s.heading)
                    local fx, fz = math.sin(s.heading), math.cos(s.heading)
                    local frx, frz = s.x + fx * rig.wheelbase, s.z + fz * rig.wheelbase
                    local tlx, tlz = math.cos(s.trailerHeading), -math.sin(s.trailerHeading)
                    local function edge(px, pz, half, sLo, sHi)
                        local d = math.abs(offsetNear(px, pz, sLo, sHi))
                        edges[#edges + 1] = { x = px, z = pz, onLine = d <= half + lineMargin }
                    end
                    edge(s.x + lx * halfTow, s.z + lz * halfTow, halfTow, sTow - 8, sTow + 4)
                    edge(s.x - lx * halfTow, s.z - lz * halfTow, halfTow, sTow - 8, sTow + 4)
                    edge(frx + lx * halfTow, frz + lz * halfTow, halfTow, sTow - 4, sTow + rig.wheelbase + 4)
                    edge(frx - lx * halfTow, frz - lz * halfTow, halfTow, sTow - 4, sTow + rig.wheelbase + 4)
                    if (rig.trailerLength or 0) > 0 then
                        edge(s.ax + tlx * halfTrl, s.az + tlz * halfTrl, halfTrl, sTow - rigLen - 10, sTow + 2)
                        edge(s.ax - tlx * halfTrl, s.az - tlz * halfTrl, halfTrl, sTow - rigLen - 10, sTow + 2)
                    end
                end
            end
        end
    end
    -- Thin the full tracks for drawing: every 4th step is ~0.1-0.3 m apart at the speeds involved.
    local tow, trailer = {}, {}
    for k = 1, #sim, 4 do
        local s = sim[k]
        tow[#tow + 1] = { x = s.x, z = s.z }
        trailer[#trailer + 1] = { x = s.ax, z = s.az }
    end
    -- Thin the obstacle tracks the same way: a probe every ~0.5-1 m of travel is plenty for an
    -- overlap test. (The edges are already spaced by distance, above.)
    local function thin(pts, every)
        local out = {}
        for k = 1, #pts, every do out[#out + 1] = pts[k] end
        if #pts > 0 and (#pts - 1) % every ~= 0 then out[#out + 1] = pts[#pts] end
        return out
    end
    return { tow = tow, trailer = trailer, trailerIn = trailerIn, towIn = towIn, trailerOut = trailerOut,
             leftTurn = leftTurn, edges = edges, towTrack = thin(towTrack, 6), trlTrack = thin(trlTrack, 6) }
end

--- Do the design rig's BODY EDGES leave the road during the turn? Same tolerance rule as the
--- connector's corridor check (one stray sample, or 15%, whichever is larger), applied to where
--- the tow and the trailer would actually be rather than to the waypoint line.
function ADFlyoverEditor:junctionSweptOffRoad(sw)
    local off, total = 0, 0
    for _, p in ipairs(sw.edges or {}) do
        -- An edge on the line's own footprint is the lane's or the corridor's business, not this
        -- turn's (see junctionSweptPredict): it is left out altogether, so the share is "of the
        -- ground this turn adds, how much is off the road". Counting those edges as on the road
        -- instead diluted real excursions away: j74's 9857 -> 3156, trailer 6 m inside, had 73 of
        -- its 167 own probes off the road (44%) and passed at 73 of 564.
        if not p.onLine then
            total = total + 1
            if not isRoadAt(p.x, p.z) then off = off + 1 end
        end
    end
    if total == 0 then return false, 0, 0 end
    local tolerance = math.max(1, math.ceil(total * 0.15))
    return off > tolerance, off, total
end

--- Static obstacles under the rig's predicted bodies during the turn: the tow's track at the tow's
--- width, the trailer's at the trailer's.
function ADFlyoverEditor:junctionSweptHits(sw, rig)
    local hits = self:junctionObstacleHitsAlong(sw.towTrack or {}, (rig.towWidth or 2.5) / 2)
    if (rig.trailerLength or 0) > 0 then
        hits = hits + self:junctionObstacleHitsAlong(sw.trlTrack or {}, (rig.trailerWidth or 2.5) / 2)
    end
    return hits
end

--- Build one movement's connector from the REAL track geometry (entry approach -> exit approach).
--- Two earlier versions each got half of it: a straight-line fillet respected the turn radius but put
--- its tangent points on straight extensions of the tracks (off a curved road, or floating in the gap
--- where a stem dead-ends short of the crossbar); an on-track Hermite stayed on the road but had no
--- radius control. This does both:
---   1. meeting region = the closest node pair between the two chains; the two LOCAL travel directions
---      there give the turn angle delta and the ideal corner V (where the local tangent lines cross);
---   2. the tie-in distance is the fillet's t = turnR*tan(delta/2), measured from the CORNER - so a stem
---      that stops short of the crossbar is not over-trimmed, and one that overshoots is trimmed back;
---   3. each tie-in is placed by walking that distance along the REAL chain (guaranteed on the road,
---      with the road's true local tangent), and the two are joined by a biarc - tangent-continuous at
---      both ends by construction. For a clean crossing the biarc IS the radius-turnR fillet arc; on a
---      curved or gapped site it flexes to stay on the road, and reports its smallest radius so a turn
---      tighter than the setting can be flagged instead of laid.
--- Returns { ax,ay,az, bx,by,bz, points, minRadius } or (nil, reason) when the tracks genuinely cannot
--- be joined into ONE turn. `reason` is "far" for the plausibility gate below, or nil for every other
--- failure (degenerate/opposed tangents; not a shallow angle - see the note on `delta`). Used by BOTH
--- preview and placement, so what is drawn is what is laid.
function ADFlyoverEditor:junctionTrackConnector(fromAp, toAp, cx, cz, radius, turnR)
    local chainA, deadEndA = self:junctionChain(fromAp, cx, cz, radius)
    local chainB, deadEndB = self:junctionChain(toAp, cx, cz, radius)
    -- A ONE-node chain is a stem whose only in-scope node is its tip (trimmed back to, or just inside,
    -- the scope circle) - seen on two-way stems at a T, where every turn through the stem was refused
    -- as "no joinable curve". The geometry below only needs the chain for a DIRECTION and a point to
    -- walk back from, and the approach's bearing already gives the direction (an entry walks
    -- downstream, an exit upstream - the same convention junctionChain starts its walk with). So
    -- extend a lone node with a virtual second one a few metres along that bearing, for GEOMETRY ONLY:
    -- placement re-walks the real chain itself (junctionTieIn) and never sees this point.
    local function withVirtual(chain, ap)
        if #chain >= 2 then return chain end
        local cb = ap.chainBearing or ap.bearing
        local wdx, wdz = math.sin(cb), math.cos(cb)
        if ap.dir ~= "in" then wdx, wdz = -wdx, -wdz end
        local p = chain[1]
        return { p, { x = p.x + wdx * 4, y = p.y, z = p.z + wdz * 4, id = p.id, virtual = true } }
    end
    if #chainA < 1 or #chainB < 1 then
        roadNote(string.format("chain:%d_%d", fromAp.wp.id, toAp.wp.id),
            "junction - entry id=%d -> exit id=%d: no lane chain at all (entry %d, exit %d) - refused.",
            fromAp.wp.id, toAp.wp.id, #chainA, #chainB)
        return nil, "chain"
    end
    chainA, chainB = withVirtual(chainA, fromAp), withVirtual(chainB, toAp)

    -- Meeting region: the closest node between the two chains (dense ~4 m nodes make node-to-node a good
    -- proxy for the true closest approach).
    local iA, iB, bestd = 1, 1, math.huge
    -- The meeting is looked for INSIDE THE SEARCH CIRCLE (+ tolerance) first: which crossing this is,
    -- is exactly what the circle is for. The chains run ~47 m out each way and on through the
    -- junction, and two such lanes can come closer to each other somewhere else entirely (two lanes of
    -- one road running side by side up the street) than they do at the crossing the user pointed at -
    -- the tangents there are near-parallel, the projected corner lands 100 m away, and the pair is
    -- thrown out as "never come close". Only if neither chain has a node in the circle does the
    -- search fall back to the whole chains.
    local own = self.junctionOwn
    local function inCircle(n)
        return own == nil or ((n.x - own.cx) ^ 2 + (n.z - own.cz) ^ 2 <= own.r2)
    end
    for pass = 1, 2 do
        for a = 1, #chainA do
            for b = 1, #chainB do
                -- Virtual direction nodes (see withVirtual) never host the meeting: a tie-in walked
                -- back from one could land ON it, i.e. 4 m into thin air past the real stem tip.
                if not chainA[a].virtual and not chainB[b].virtual
                    and (pass == 2 or (inCircle(chainA[a]) and inCircle(chainB[b]))) then
                    local d = (chainA[a].x - chainB[b].x) ^ 2 + (chainA[a].z - chainB[b].z) ^ 2
                    if d < bestd then bestd, iA, iB = d, a, b end
                end
            end
        end
        if bestd < math.huge then break end
    end

    -- Local travel directions at the meeting: A toward the interior (lower->higher index), B out toward
    -- its boundary (the negated chain direction).
    local uAx, uAz = junctionSegDir(chainA, iA)
    local sbx, sbz = junctionSegDir(chainB, iB)
    local uBx, uBz = -sbx, -sbz
    local pA, pB = chainA[iA], chainB[iB]
    -- NO angle floor here: this network's own survey put the MEDIAN junction angle at 10 deg, and a
    -- shallow merge below that is a completely ordinary new connection to make, not a degenerate one.
    -- An earlier version dropped anything under 5 deg as "nothing to turn" - which silently ate real
    -- shallow merges (they were not counted as tight/off-road either, so nothing said why they were
    -- missing). The biarc below already reduces to a straight join in the limit as delta -> 0 (its
    -- parallel-tangent branch), so there is nothing to gate: let it solve.
    local delta = math.acos(math.max(-1, math.min(1, uAx * uBx + uAz * uBz)))
    local t = turnR * math.tan(delta / 2)

    -- The corner V where the two local tangent lines cross is used to measure how far each meeting
    -- node sits from it, signed along travel: sA = corner is this far ahead of A's node (a stem
    -- trimmed back short of the crossbar has a large positive sA), sB = B's node is this far past the
    -- corner. Also computed here, and used for the plausibility gate right below.
    local sA, sB = 0, 0
    local det = uBx * uAz - uAx * uBz
    if math.abs(det) > 1e-6 then
        local s = (uBx * (pB.z - pA.z) - uBz * (pB.x - pA.x)) / det
        local Vx, Vz = pA.x + s * uAx, pA.z + s * uAz
        sA = (Vx - pA.x) * uAx + (Vz - pA.z) * uAz
        sB = (pB.x - Vx) * uBx + (pB.z - Vz) * uBz
    end

    -- Plausibility gate: if the two tracks are not the same crossing, do not connect them - a wide
    -- scope catching two separate nearby junctions was pairing every entry with every exit regardless
    -- of distance, drawing connectors straight through the middle of the whole site instead of
    -- hugging one corner.
    --
    -- "Far apart" is NOT the same test as "far from the closest existing node": a stem trimmed back
    -- short of the true crossing (walkBack now extrapolates past it to reach the tie-in) makes the
    -- raw node-to-node distance look exactly like an unrelated, genuinely distant crossing would -
    -- both are "far" by that measure, but only one is real. What tells them apart is the CORNER: two
    -- tracks converging on one nearby point (sA, sB both small - or negative, meaning the stem already
    -- reaches past it) are the same crossing, however short they were trimmed; two tracks that would
    -- only meet an implausible distance away (or a projected corner outside the scope circle
    -- entirely) are not, however close their nearest surviving nodes happen to sit. That is checked
    -- when the corner is well-defined (the tangents actually cross); parallel/near-parallel tangents
    -- have no such corner, so those fall back to the original closest-node test - tracks that never
    -- converge at all should not be connected regardless of trimming.
    -- `junctionExtendTrim` (card toggle "trim/extend", default true) governs both this gate and the
    -- walk below: off, a trimmed stem is never projected past where it actually ends, so the corner
    -- test would be meaningless (the tie-in cannot reach the corner anyway) - fall back to the
    -- original closest-node test in that case too.
    local extend = self.junctionExtendTrim ~= false
    if not extend then
        local meetCap = math.max(turnR * 3, 15)   -- the turn's own scale, not the search radius
        if bestd > meetCap * meetCap then return nil, "far" end
    elseif math.abs(det) > 1e-6 then
        local farCap = math.max(turnR * 6, 20)    -- the turn's own scale, not the search radius
        if sA > farCap or sB > farCap then return nil, "far" end
    else
        -- Parallel/near-parallel tangents (delta ~ 0) - the MOST common case, a straight-through
        -- continuation, and the corner test above does not apply (there is no corner). Colinearity
        -- IS the meeting signal here: two tracks lined up end to end are obviously the same road,
        -- however far apart their trimmed ends sit - and that gap is already bounded by both ends
        -- being inside the scope circle, so no extra distance cap is needed. What DOES matter is
        -- whether they are actually on the same line: gate on the perpendicular offset from B to A's
        -- line instead of the raw point distance - small offset is the same road; a real one is a
        -- genuinely different, merely parallel one (an adjacent lane a few lanes over, say).
        local perpDist = math.abs((pB.x - pA.x) * uAz - (pB.z - pA.z) * uAx)
        local perpCap = math.max(turnR, 6)
        if perpDist > perpCap then return nil, "far" end
    end

    -- Tie-ins: t back from the corner, walked along the real chains (a non-positive walk stays at the
    -- meeting node - e.g. a dead-end whose gap to the crossbar already exceeds t).
    -- Extension past the chain's end is only meaningful when the chain ends at a REAL dead end (a
    -- trimmed stem). A chain that merely ran out at the scope circle is a road that keeps going -
    -- projecting a tie-in past that boundary plants a spike node beside the real road (seen with a
    -- turn radius comparable to the scope radius). There the walk clamps at the boundary instead.
    local pax, pay, paz, tadx, tadz = junctionWalkBack(chainA, iA, t - sA, extend and deadEndA)
    local pbx, pby, pbz, tbdx, tbdz = junctionWalkBack(chainB, iB, t - sB, extend and deadEndB)
    -- A TWO-WAY ROAD STAYS TWO-WAY RIGHT UP TO THE MOUTH (docs/junction-tool/06-one-click-build.md,
    -- "Two-way roads"). Where a lane is two-way and ends at this junction, every turn into or out of it
    -- starts or ends at ONE point on it, instead of each at its own tie-in. A truck leaving the
    -- junction then checks the whole two-way road ahead from there, and waits off the road.
    -- The point is the turn-radius setting back from the road's end, not the end itself: the end sits
    -- at the other road's edge, where a turn has no room left to curve (tying turns at the very end
    -- refused 7 more of them across the registry, "tight"). The same distance for every turn of the
    -- road puts them all on the same spot, and the placement then ties them all to one point there.
    if AutoDrive.FLYOVER_JUNCTION_TWO_WAY_AT_MOUTH ~= false then
        local back = self.junctionTurnRadius or 12
        local function twoWayMouth(chain, deadEnd)
            if not deadEnd or #chain < 2 then return nil end
            local tip, before = chain[#chain], chain[#chain - 1]
            if tip.virtual or before.virtual then return nil end
            if not (table.contains(tip.out or {}, before.id) and table.contains(before.out or {}, tip.id)) then
                return nil
            end
            -- Walk back from the end along the chain, as far as the chain stays two-way.
            local left = back
            for i = #chain, 2, -1 do
                local a, b = chain[i], chain[i - 1]
                if b.virtual or not (table.contains(a.out or {}, b.id) and table.contains(b.out or {}, a.id)) then
                    break
                end
                local dx, dz = a.x - b.x, a.z - b.z
                local seg = math.sqrt(dx * dx + dz * dz)
                if seg > 1e-6 then
                    if seg >= left then
                        local f = left / seg
                        return a.x - dx * f, (a.y or 0) - ((a.y or 0) - (b.y or 0)) * f, a.z - dz * f, dx / seg, dz / seg
                    end
                    left = left - seg
                end
            end
            -- The two-way stretch is shorter than that: its far end, then.
            return nil
        end
        -- Both chains run from the edge of the work region in towards the junction, so the direction
        -- along the chain is the way in for A, and the reverse of the way out for B.
        local mx, my, mz, mdx, mdz = twoWayMouth(chainA, deadEndA)
        if mx ~= nil then pax, pay, paz, tadx, tadz = mx, my, mz, mdx, mdz end
        mx, my, mz, mdx, mdz = twoWayMouth(chainB, deadEndB)
        if mx ~= nil then pbx, pby, pbz, tbdx, tbdz = mx, my, mz, mdx, mdz end
    end
    -- A leaves along its chain direction (toward the interior); B is arrived at heading out (negated).
    -- BOTH curve engines solve and the SHORTER path wins. This is not indecision - it is the guard
    -- against Dubins' degenerate configuration: two poses on the SAME tangent circle, which is
    -- exactly where fillet tie-ins sit on a clean crossing, make ADDubins parameterize the quarter
    -- turn as a 450-degree loop (measured: 94 m where 19 m is right, on the same circle). The biarc
    -- IS the optimal answer there and wins on length automatically; where Dubins genuinely helps
    -- (offset poses, S-bends, hooks) it is shorter and wins instead. No tuned threshold to go stale.
    local function pathLen(c)
        if c == nil then return math.huge end
        local len, px, pz = 0, pax, paz
        for _, p in ipairs(c.points) do
            len = len + math.sqrt((p.x - px) ^ 2 + (p.z - pz) ^ 2)
            px, pz = p.x, p.z
        end
        return len + math.sqrt((pbx - px) ^ 2 + (pbz - pz) ^ 2)
    end
    local bia = junctionBiarc(pax, paz, tadx, tadz, pbx, pbz, -tbdx, -tbdz, pay, pby)
    local dub = nil
    if self.junctionUseDubins ~= false then
        dub = junctionDubins(pax, paz, tadx, tadz, pbx, pbz, -tbdx, -tbdz, turnR, pay, pby)
    end
    local bi = bia
    if dub ~= nil and pathLen(dub) < pathLen(bia) - 0.1 then bi = dub end
    -- LEFT TURNS THROUGH THE CENTRE (docs/junction-tool/06-one-click-build.md, opposite left turns;
    -- the route check found why). A left turn is laid as two curves meeting at the junction's centre,
    -- arriving there along the line halfway between its way in and its way out. Every left turn then
    -- crosses the others at that one shared point, 90 degrees apart on a square junction - more than
    -- AutoDrive's 80, so it can never hop from one left turn to another and drive round in a ring (the
    -- U-turns the route check found). It also makes opposite left turns go one at a time.
    -- Only for a left turn of roughly 90 degrees (55-125); anything else keeps its plain curve, and so
    -- does a left turn whose centre does not lie ahead of its way in and behind its way out.
    local lc = self.junctionLeftCentre
    if lc ~= nil and bi ~= nil then
        local ux, uz = tadx, tadz                   -- heading on the way in
        local vx, vz = -tbdx, -tbdz                 -- heading on the way out
        local turnCross = ux * vz - uz * vx          -- negative: a left turn (x east, z south)
        local turnAng = math.deg(math.acos(math.max(-1, math.min(1, ux * vx + uz * vz))))
        if turnCross < 0 and turnAng >= 55 and turnAng <= 125 then
            local hx, hz = ux + vx, uz + vz
            local hn = math.sqrt(hx * hx + hz * hz)
            local ahead = (lc.x - pax) * ux + (lc.z - paz) * uz
            local behind = (pbx - lc.x) * vx + (pbz - lc.z) * vz
            if hn > 1e-6 and ahead > 1 and behind > 1 then
                hx, hz = hx / hn, hz / hn
                local cy = (pay + pby) / 2
                local in1 = junctionBiarc(pax, paz, ux, uz, lc.x, lc.z, hx, hz, pay, cy)
                local in2 = junctionBiarc(lc.x, lc.z, hx, hz, pbx, pbz, vx, vz, cy, pby)
                if in1 ~= nil and in2 ~= nil then
                    local pts = {}
                    for _, p in ipairs(in1.points) do pts[#pts + 1] = p end
                    pts[#pts + 1] = { x = lc.x, y = cy, z = lc.z, centre = true }
                    for _, p in ipairs(in2.points) do pts[#pts + 1] = p end
                    bi = { points = pts, minRadius = math.min(in1.minRadius, in2.minRadius), throughCentre = true }
                end
            end
        end
    end
    if bi == nil then
        roadNote(string.format("nofit:%d_%d", fromAp.wp.id, toAp.wp.id),
            "junction - entry id=%d -> exit id=%d: neither curve engine fit (delta %.0f deg, t %.1f, sA %.1f, sB %.1f, tie-ins %.1f m apart) - refused.",
            fromAp.wp.id, toAp.wp.id, math.deg(delta), t, sA, sB, math.sqrt((pbx - pax) ^ 2 + (pbz - paz) ^ 2))
        return nil, "nofit"
    end
    return { ax = pax, ay = pay, az = paz, bx = pbx, by = pby, bz = pbz,
        points = bi.points, minRadius = bi.minRadius, t = t, meetDist = math.sqrt(bestd),
        throughCentre = bi.throughCentre }
end

--- How many of a connector's corridor samples leave the road surface, and how many were taken. Every
--- curve point is probed at its centre and half a corridor width to each side of the local heading
--- (tractor width plus a trailer allowance - see FLYOVER_JUNCTION_CORRIDOR). The two tie-ins are
--- probed at the centre only: they sit on the existing track, whose edge situation is not this turn's
--- doing.
function ADFlyoverEditor:junctionCorridorOffRoad(con)
    local half = (self.junctionCorridor or AutoDrive.FLYOVER_JUNCTION_CORRIDOR or 4.0) / 2
    local pts = { { x = con.ax, z = con.az } }
    for _, p in ipairs(con.points) do pts[#pts + 1] = p end
    pts[#pts + 1] = { x = con.bx, z = con.bz }
    local off, total = 0, 0
    for i = 1, #pts do
        local p = pts[i]
        total = total + 1
        if not isRoadAt(p.x, p.z) then off = off + 1 end
        if i > 1 and i < #pts then
            local a, b = pts[i - 1], pts[i + 1]
            local dx, dz = b.x - a.x, b.z - a.z
            local l = math.sqrt(dx * dx + dz * dz)
            if l > 1e-6 then
                local nx, nz = -dz / l, dx / l
                total = total + 2
                if not isRoadAt(p.x + nx * half, p.z + nz * half) then off = off + 1 end
                if not isRoadAt(p.x - nx * half, p.z - nz * half) then off = off + 1 end
            end
        end
    end
    return off, total
end

--- Solve one turn at the largest radius that both holds the radius bound and keeps the corridor on
--- the road: the setting first, then stepping down 1 m at a time to the turn-radius floor. Inside
--- turns at a sharp corner therefore come out tighter than outside ones, as real intersections are
--- laid out, without the global setting being tuned per site. Returns connector, radius used, nil on
--- success; on failure the last connector tried, the floor, and a reason ("tight" / "offroad" /
--- "nocurve" / "far") so the preview can still show what was refused and why.
-- Obstacle probe for junction connectors, using the SAME physics query AutoDrive's own pathfinder
-- uses for its cells (overlapBox returning a synchronous shape count; see PathFinderModule ~1221).
-- The mask is STATIC things a laid route must never pass through - trees, buildings, static objects
-- (fences, poles, signs are static objects or buildings) - and deliberately NOT vehicles/traffic:
-- something driving past while you place is not a reason to refuse a road. The box floats 0.6 m off
-- the terrain (pathfinder ignores the lowest 0.5 m the same way) so curbs and ground clutter do not
-- count, and reaches ~2.8 m up - trailer height.
local junctionObstacleMask = nil
-- The overlap callback collects WHAT it hit (shape name, split-shape flag, rigid body type) so a
-- refusal can be traced to an actual object in the log rather than a count. A tree's canopy over
-- a road is the suspected false positive; the names will say.
local JunctionOverlapProbe = { hits = {} }
function JunctionOverlapProbe.cb(self, transformId)
    if transformId ~= nil and transformId ~= 0 and transformId ~= g_currentMission.terrainRootNode then
        -- The mask now includes DYNAMIC objects (knock-over signs and props are dynamic bodies), so
        -- the things that are dynamic but NOT part of the road's furniture have to be dropped here:
        -- vehicles and implements (parked or passing), bales, pallets. Anything the mission maps to
        -- an object with wheels, a root vehicle, or bale/pallet traits is ignored.
        local obj = g_currentMission.nodeToObject ~= nil and g_currentMission.nodeToObject[transformId] or nil
        if obj ~= nil and (obj.rootVehicle ~= nil or obj.spec_wheels ~= nil or obj.getRootVehicle ~= nil
            or obj.isRoundbale ~= nil or obj.baleDiameter ~= nil or obj.spec_pallet ~= nil) then
            return true
        end
        local ok, desc = pcall(function()
            local name = getName(transformId) or "?"
            local split = (getHasClassId ~= nil and ClassIds ~= nil and ClassIds.SHAPE ~= nil
                and getSplitType ~= nil and getSplitType(transformId) ~= 0) and " tree(split)" or ""
            local rb = (getRigidBodyType ~= nil) and tostring(getRigidBodyType(transformId)) or "?"
            local mask = (getCollisionFilterGroup ~= nil) and tostring(getCollisionFilterGroup(transformId)) or "?"
            return string.format("%s%s rb=%s group=%s", name, split, rb, mask)
        end)
        self.hits[#self.hits + 1] = ok and desc or ("? (" .. tostring(desc) .. ")")
    end
    return true
end

--- Number of corridor boxes along `con` that overlap a static obstacle. Boxes are laid segment by
--- segment along the curve (half corridor width wide, segment-long), rotated to the local heading.
function ADFlyoverEditor:junctionObstacleHits(con)
    local halfW = (self.junctionClearance or AutoDrive.FLYOVER_JUNCTION_CLEARANCE or 5.0) / 2
    local pts = { { x = con.ax, z = con.az } }
    for _, p in ipairs(con.points) do pts[#pts + 1] = p end
    pts[#pts + 1] = { x = con.bx, z = con.bz }
    return self:junctionObstacleHitsAlong(pts, halfW)
end

--- The probe itself, along any polyline at any half-width: boxes segment by segment, rotated to the
--- local heading. Shared by the connector corridor and the swept-path body tracks.
function ADFlyoverEditor:junctionObstacleHitsAlong(pts, halfW)
    if overlapBox == nil or g_currentMission == nil or g_currentMission.terrainRootNode == nil then
        return 0
    end
    if junctionObstacleMask == nil then
        -- AutoDrive's OWN object-sensor mask (Sensors/CollSensorSplit.lua maskObjects), minus
        -- TERRAIN_DELTA (a flat probe box on a slope would hit the terrain it stands on). The first
        -- mask was static + tree + building only: a trailer clipped something the gate had judged
        -- clear, with the prediction within a metre of the recorded track - i.e. the object was
        -- simply not in the mask. Map furniture is very often left in the DEFAULT group, and
        -- knock-over signs are DYNAMIC bodies; both are what AutoDrive's sensors stop for.
        junctionObstacleMask = (CollisionFlag.DEFAULT or 0) + CollisionFlag.STATIC_OBJECT
            + (CollisionFlag.DYNAMIC_OBJECT or 0) + CollisionFlag.TREE + CollisionFlag.BUILDING
    end
    local hits = 0
    for i = 2, #pts do
        local a, b = pts[i - 1], pts[i]
        local dx, dz = b.x - a.x, b.z - a.z
        local l = math.sqrt(dx * dx + dz * dz)
        if l > 1e-3 then
            local mx, mz = (a.x + b.x) * 0.5, (a.z + b.z) * 0.5
            local gy = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, mx, 1, mz) or 0
            local ry = math.atan2(dx, dz)
            JunctionOverlapProbe.hits = {}
            local ok, shapes = pcall(overlapBox, mx, gy + 0.6 + 1.1, mz, 0, ry, 0,
                halfW, 1.1, l * 0.5, "cb", JunctionOverlapProbe, junctionObstacleMask, true, true, true, true)
            -- Proof-of-life notes, once each: a probe that errors would otherwise be a silent no-op
            -- behind this pcall, indistinguishable from "no obstacles anywhere".
            if not ok then
                roadNote("obsProbeErr", "obstacle probe FAILED: %s - obstacle check is inactive.", tostring(shapes))
            elseif type(shapes) ~= "number" then
                roadNote("obsProbeOdd", "obstacle probe returned %s (expected a count) - obstacle check is inactive.", type(shapes))
            else
                roadNote("obsProbeOk", "obstacle probe active (mask %d).", junctionObstacleMask)
                -- Count what SURVIVED the callback's filter (vehicles, bales, pallets dropped), not
                -- the raw shape count, which includes them.
                shapes = #JunctionOverlapProbe.hits
                if shapes > 0 then
                    hits = hits + 1
                    roadNote("obsFirstHit", "obstacle probe FIRST HIT at %.1f, %.1f (%d shape(s)).", mx, mz, shapes)
                    -- Name every distinct object hit, once each, with where.
                    for _, desc in ipairs(JunctionOverlapProbe.hits) do
                        -- Keyed by name AND place (4 m grid): "col"/"collision" are generic shape
                        -- names, and keying on the name alone logged the first one on the map and
                        -- then stayed silent at every other site.
                        roadNote(string.format("obsHit:%s:%d:%d", desc, math.floor(mx / 4), math.floor(mz / 4)),
                            "obstacle probe hit %s at %.1f, %.1f (box half-width %.2f m).", desc, mx, mz, halfW)
                    end
                end
            end
        end
    end
    return hits
end

--- Is this connector's corridor off the road ENOUGH to refuse it? A single stray sample - one edge
--- probe clipping a narrow paved apron at a dirt/pavement seam, or a texture-boundary sliver - should
--- not kill an otherwise good turn; a corridor that is mostly off-road should. Tolerates up to 1 sample
--- or 15% of the samples taken, whichever is larger.
function ADFlyoverEditor:junctionCorridorTooOffRoad(con)
    local off, total = self:junctionCorridorOffRoad(con)
    local tolerance = math.max(1, math.ceil(total * 0.15))
    return off > tolerance
end

--- `junctionCheckSurface` (card toggle, default true) skips the road-surface raycast entirely - the
--- turn is still radius-bound but never refused/shrunk for leaving the road. For a map whose surface
--- reads wrong (see isRoadAt's logged classifications), or just to place fast on a site you already
--- know is clear, without waiting on a raycast per candidate radius per curve point.
--- The sweep-wide reshape: a copy of connector `con` with its interior points pushed `d` metres
--- toward the OUTSIDE of the turn, perpendicular to the local heading. The push tapers over the first
--- and last fifth of the curve so the tie-ins stay exactly on their tracks and the curve leaves and
--- rejoins them smoothly. An outward offset only ever increases the radius, so minRadius stands as a
--- conservative bound.
local function junctionSweepWide(con, d, leftTurn)
    local pts = { { x = con.ax, y = con.ay, z = con.az } }
    for _, p in ipairs(con.points) do pts[#pts + 1] = p end
    pts[#pts + 1] = { x = con.bx, y = con.by, z = con.bz }
    local cum, total = { 0 }, 0
    for i = 2, #pts do
        total = total + math.sqrt((pts[i].x - pts[i - 1].x) ^ 2 + (pts[i].z - pts[i - 1].z) ^ 2)
        cum[i] = total
    end
    if total < 1e-3 then return nil end
    -- A sideways push needs LENGTH to blend in. The first version tapered over a fixed fifth of
    -- the curve: on a ~16 m connector a 2 m sweep was taken up in ~3 m, i.e. 30-degree kinks at
    -- both ends (recorded on the first swept turn that was driven). The blend now runs over at
    -- least 4 m per metre of sweep at each end, eased with a cosine, and a connector too short to
    -- carry the sweep at all (the two blends would overlap) is not swept - the radius search
    -- steps down instead.
    local blend = math.max(0.2, (4 * d) / total)
    if blend > 0.5 then return nil end
    local out = {}
    for i = 2, #pts - 1 do
        local a, b = pts[i - 1], pts[i + 1]
        local dx, dz = b.x - a.x, b.z - a.z
        local l = math.sqrt(dx * dx + dz * dz)
        local p = pts[i]
        if l > 1e-6 then
            -- forward = (dx,dz)/l ; LEFT = (fz, -fx) in this file's convention (forward = (sin h,
            -- cos h), left = (cos h, -sin h)). Outside of a left turn is the RIGHT, and vice versa.
            local lx, lz = dz / l, -dx / l
            local ox, oz = lx, lz
            if leftTurn then ox, oz = -lx, -lz end
            local u = cum[i] / total
            local e = math.min(1, u / blend, (1 - u) / blend)
            local w = 0.5 - 0.5 * math.cos(math.pi * e)
            out[#out + 1] = { x = p.x + ox * d * w, y = p.y, z = p.z + oz * d * w }
        else
            out[#out + 1] = { x = p.x, y = p.y, z = p.z }
        end
    end
    return { ax = con.ax, ay = con.ay, az = con.az, bx = con.bx, by = con.by, bz = con.bz,
        points = out, minRadius = con.minRadius, t = con.t, meetDist = con.meetDist, sweep = d }
end

--- The KICKOUT (docs/swept-path-spec.md §6, "Kickout shape"): the sweep-wide reshape in the form that
--- actually works - it starts EARLY on the entry lane and ends LATE on the exit lane, and it is
--- asymmetric (the return is longer than the setup, because the trailer is still cutting inside a
--- rig-length after the tow has left the curve). Offline it recovers ~3x the trailer clearance per
--- metre of push that an inside-the-curve blend does, with no kinks.
---
--- Construction: the composite route  lane(A' -> A) + connector + lane(B -> B')  is offset toward the
--- OUTSIDE of the turn by `d`, eased in with a cosine over the entry stretch, held through the curve,
--- eased out over the exit stretch. The lane stretches follow the lanes' real shape (a straight
--- S-bend would cut across a curved approach), resampled at 2 m so the ease is smooth. The ease
--- length is bounded below by  pi * sqrt(d * turnR / 2)  - the length at which a cosine lane-change
--- of `d` peaks at exactly the turn radius - so the kickout never bends tighter than the turn itself.
---
--- It lives INSIDE the scope circle by design: the new tie-ins A' and B' must sit on the lane chains
--- within the scope, so the junction stays one self-contained site for approach detection, the
--- already-connected test and rebuild. A cramped scope shortens the kickout, and below the ease
--- bound refuses it (returns nil, "scope") - the fix is a bigger scope, which the log says. A side
--- whose lane DEAD-ENDS inside the scope is not kicked out either (its tie-in trims the stem, and
--- an early tie-in would trim away the other turns' tie-ins): returns nil, "deadend".
function ADFlyoverEditor:junctionKickout(fromAp, toAp, con, d, leftTurn, rig, cx, cz, radius, turnR)
    local chainA, deadEndA = self:junctionChain(fromAp, cx, cz, radius)
    local chainB, deadEndB = self:junctionChain(toAp, cx, cz, radius)
    if deadEndA or deadEndB then return nil, "deadend" end
    local early = (rig.lookAhead or 8) + 2
    local late = (rig.lookAhead or 8) + (rig.trailerLength or 0)
    local minBlend = math.pi * math.sqrt(d * turnR / 2)
    early, late = math.max(early, minBlend), math.max(late, minBlend)

    -- Travel-ordered lane points: entry = boundary ... A ; exit = B ... boundary.
    local entry = {}
    for k = 1, math.min(#chainA, junctionChainIndexNear(chainA, con.ax, con.az)) do
        local n = chainA[k]
        local dx, dz = junctionSegDir(chainA, k)
        if (con.ax - n.x) * dx + (con.az - n.z) * dz > 0.3 then
            entry[#entry + 1] = { x = n.x, y = n.y or 0, z = n.z }
        end
    end
    entry[#entry + 1] = { x = con.ax, y = con.ay or 0, z = con.az }
    local exit = { { x = con.bx, y = con.by or 0, z = con.bz } }
    for k = math.min(#chainB, junctionChainIndexNear(chainB, con.bx, con.bz)), 1, -1 do
        local n = chainB[k]
        local dx, dz = junctionSegDir(chainB, k)
        if (n.x - con.bx) * -dx + (n.z - con.bz) * -dz > 0.3 then
            exit[#exit + 1] = { x = n.x, y = n.y or 0, z = n.z }
        end
    end

    -- Take `want` metres off one end of a polyline (fromEnd: the LAST `want` metres, else the first),
    -- resampled at ~2 m, in travel order. Returns the points and the length actually available.
    local function stretch(poly, want, fromEnd)
        local src = poly
        if fromEnd then
            src = {}
            for i = #poly, 1, -1 do src[#src + 1] = poly[i] end
        end
        local cum = { 0 }
        for i = 2, #src do
            cum[i] = cum[i - 1] + math.sqrt((src[i].x - src[i - 1].x) ^ 2 + (src[i].z - src[i - 1].z) ^ 2)
        end
        local avail = math.min(want, cum[#src])
        local function at(s)
            for i = 2, #src do
                if cum[i] >= s - 1e-9 then
                    local l = cum[i] - cum[i - 1]
                    local f = (l > 1e-9) and (s - cum[i - 1]) / l or 0
                    local a, b = src[i - 1], src[i]
                    return { x = a.x + (b.x - a.x) * f, y = a.y + (b.y - a.y) * f, z = a.z + (b.z - a.z) * f }
                end
            end
            local e = src[#src]
            return { x = e.x, y = e.y, z = e.z }
        end
        local out, s = {}, 0
        while s < avail - 0.5 do
            out[#out + 1] = at(s)
            s = s + 2
        end
        out[#out + 1] = at(avail)
        if fromEnd then
            local rev = {}
            for i = #out, 1, -1 do rev[#rev + 1] = out[i] end
            out = rev
        end
        return out, avail
    end
    local entryPart, earlyGot = stretch(entry, early, true)     -- A' ... A
    local exitPart, lateGot = stretch(exit, late, false)        -- B ... B'
    if earlyGot < minBlend - 1e-6 or lateGot < minBlend - 1e-6 then
        return nil, "scope", earlyGot, lateGot, minBlend
    end

    -- Composite route and its arc-length marks.
    local P = {}
    for _, p in ipairs(entryPart) do P[#P + 1] = p end                 -- ends with A
    for _, p in ipairs(con.points) do P[#P + 1] = { x = p.x, y = p.y or 0, z = p.z } end
    for _, p in ipairs(exitPart) do P[#P + 1] = p end                  -- starts with B
    local iA, iB = #entryPart, #entryPart + #con.points + 1
    local cum = { 0 }
    for i = 2, #P do cum[i] = cum[i - 1] + math.sqrt((P[i].x - P[i - 1].x) ^ 2 + (P[i].z - P[i - 1].z) ^ 2) end
    local sA, sB, total = cum[iA], cum[iB], cum[#P]
    if sA < 1e-3 or total - sB < 1e-3 then return nil, "scope", earlyGot, lateGot, minBlend end

    local pts = {}
    for i = 2, #P - 1 do
        local s = cum[i]
        local w
        if s < sA then w = 0.5 - 0.5 * math.cos(math.pi * s / sA)
        elseif s > sB then w = 0.5 - 0.5 * math.cos(math.pi * (total - s) / (total - sB))
        else w = 1 end
        local a, b = P[i - 1], P[i + 1]
        local dx, dz = b.x - a.x, b.z - a.z
        local l = math.sqrt(dx * dx + dz * dz)
        local ox, oz = 0, 0
        if l > 1e-6 then
            local lx, lz = dz / l, -dx / l          -- LEFT of travel (see junctionSweepWide)
            ox, oz = lx, lz
            if leftTurn then ox, oz = -lx, -lz end  -- outside of a left turn is the right
        end
        pts[#pts + 1] = { x = P[i].x + ox * d * w, y = P[i].y, z = P[i].z + oz * d * w }
    end
    return { ax = P[1].x, ay = P[1].y, az = P[1].z, bx = P[#P].x, by = P[#P].y, bz = P[#P].z,
        points = pts, minRadius = con.minRadius, t = con.t, meetDist = con.meetDist,
        sweep = d, kickEarly = earlyGot, kickLate = lateGot }
end

function ADFlyoverEditor:junctionSolveMovement(fromAp, toAp, cx, cz, radius, turnR, rig)
    local floor = AutoDrive.FLYOVER_JUNCTION_TURN_MIN or 4
    local checkSurface = self.junctionCheckSurface ~= false
    local checkObstacles = self.junctionCheckObstacles ~= false
    local last, lastReason = nil, nil
    -- The design vehicle's own floor (docs/swept-path-spec.md §6, gate 1): a connector tighter than
    -- its full-lock radius is one the driver would understeer straight through, whatever the setting
    -- says. Candidates below it are not even tried.
    local rigFloor = (rig ~= nil and rig.minTurnRadius) or 0
    local r = turnR
    while r >= floor - 1e-6 do
        local con, whyNil = self:junctionTrackConnector(fromAp, toAp, cx, cz, radius, r)
        if con == nil then
            -- "far" does not depend on the turn radius candidate - stepping r down cannot bring two
            -- tracks closer together, so stop instead of retrying it at every floor step.
            if whyNil == "far" then return nil, r, "far" end
            if last == nil then return nil, r, "nocurve" end
            return last, r + 1, lastReason
        end
        if con.minRadius < math.max(r * 0.7, rigFloor) then
            last, lastReason = con, "tight"
        elseif checkSurface and self:junctionCorridorTooOffRoad(con) then
            last, lastReason = con, "offroad"
        elseif checkObstacles and self:junctionObstacleHits(con) > 0 then
            -- A static obstacle in the corridor: a smaller radius swings a different line, so the
            -- same shrink search doubles as first-order avoidance; nothing clear down to the floor
            -- is a verbose red refusal, never a connector through a tree.
            last, lastReason = con, "blocked"
        else
            -- Swept-path gate (spec §6, gates 2-3), only with a design rig (locked site, toggle on):
            -- drive the rig through this candidate and probe the road and the obstacles under where
            -- its bodies actually go. The prediction rides on the connector so the preview draws it
            -- without a second simulation.
            local sw = nil
            if rig ~= nil and SweptSim ~= nil then
                local ok, res = pcall(function() return self:junctionSweptPredict(fromAp, toAp, con, cx, cz, radius, rig) end)
                if ok then sw = res else roadNote("sweptErr", "swept-path prediction failed: %s", tostring(res)) end
                con.swept = sw
            end
            local function sweptVerdict(s)
                if s == nil then return nil end
                if checkSurface and self:junctionSweptOffRoad(s) then return "trailerRoad" end
                if checkObstacles and self:junctionSweptHits(s, rig) > 0 then return "trailerHit" end
                return nil
            end
            local verdict = sweptVerdict(sw)
            if verdict == nil then
                return con, r, nil
            end
            -- SWEEP WIDE before giving up on this radius: push the curve outward in steps and
            -- re-judge. A wider line at the SAME radius beats a tighter radius - the rig cuts in
            -- from wherever the line is, so moving the line out moves the bodies back onto the road
            -- and away from whatever stands on the inside. Each shifted line must itself stay on the
            -- road (corridor) and clear of obstacles - that is the outer-edge bound.
            local accepted = nil
            if sw ~= nil then
                local d = AutoDrive.FLYOVER_JUNCTION_SWEEP_STEP or 1.0
                while d <= (AutoDrive.FLYOVER_JUNCTION_SWEEP_MAX or 3.0) + 1e-6 do
                    -- The early/late KICKOUT first; the inside-the-curve blend only when the
                    -- kickout cannot fit (cramped scope, or a dead-end stem) - it recovers about a
                    -- third as much, but it is better than refusing.
                    local wide, why, gotE, gotL, need = self:junctionKickout(fromAp, toAp, con, d, sw.leftTurn, rig, cx, cz, radius, r)
                    if wide == nil then
                        if why == "scope" then
                            roadNote(string.format("kickScope:%d_%d", fromAp.wp.id, toAp.wp.id),
                                "junction - entry id=%d -> exit id=%d: not enough lane for an early/late kickout (%.0f m of lane before / %.0f m after the curve inside the work region, %.0f m needed for a %.0f m kickout) - using the inside-the-curve blend instead.",
                                fromAp.wp.id, toAp.wp.id, gotE or 0, gotL or 0, need or 0, d)
                        end
                        wide = junctionSweepWide(con, d, sw.leftTurn)
                    end
                    if wide == nil then break end
                    local lineOk = not (checkSurface and self:junctionCorridorTooOffRoad(wide))
                        and not (checkObstacles and self:junctionObstacleHits(wide) > 0)
                    if lineOk then
                        local ok, res = pcall(function() return self:junctionSweptPredict(fromAp, toAp, wide, cx, cz, radius, rig) end)
                        if ok and res ~= nil then
                            wide.swept = res
                            if sweptVerdict(res) == nil then accepted = wide; break end
                        end
                    end
                    d = d + (AutoDrive.FLYOVER_JUNCTION_SWEEP_STEP or 1.0)
                end
            end
            if accepted ~= nil then
                return accepted, r, nil
            end
            last, lastReason = con, verdict
        end
        r = r - 1
        if r < rigFloor - 1e-6 and r >= floor - 1e-6 then
            -- Nothing below the rig's floor can pass gate 1; report the last real attempt.
            break
        end
    end
    return last, math.max(floor, r + 1), lastReason
end

--- Place every NEW turn in the current preview: for each, lay OUR connector points between the entry
--- and exit lane nodes via junctionLayChain (deterministic links only; priority inherited from the
--- joined road), all under one undo snapshot. Existing turns and U-turns were already filtered out of
--- the matrix; radius/corridor refusals happened in the solve.
--- The lane chain from an approach's boundary node toward the intersection interior (out-edges for an
--- entry, incoming for an exit), boundary node first, staying within the scope. Also whether that lane
--- DEAD-ENDS inside the scope (no travel continuation) rather than passing through.
function ADFlyoverEditor:junctionChain(ap, cx, cz, radius, fresh)
    -- Chains are long now (the work region, not the search circle) and the solve asks for the same
    -- one for every candidate radius of every turn, so they are cached for the life of one preview
    -- solve (cleared at the top of updateJunctionPreview). PLACEMENT passes fresh = true: it splices
    -- tie nodes into the lanes as it goes, so every walk there must see the graph as it is now.
    local cache = self.junctionChainCache
    if not fresh and cache ~= nil and cache[ap] ~= nil then
        return cache[ap][1], cache[ap][2]
    end
    local chain, deadEnd = self:junctionChainWalk(ap, cx, cz, radius)
    if not fresh and cache ~= nil then cache[ap] = { chain, deadEnd } end
    return chain, deadEnd
end

function ADFlyoverEditor:junctionChainWalk(ap, cx, cz, radius)
    local useOut = (ap.dir == "in")
    local r2 = radius * radius
    local chain = { ap.wp }
    local node, cameFrom = ap.wp, nil
    -- The walk follows BEARING CONTINUITY: at a fork (a tie node whose neighbours include both the
    -- road's continuation and an old connector's first point), it takes whichever neighbour bends
    -- LEAST from the current walking direction - the road runs on, a connector departs at an angle.
    -- Taking the first listed neighbour instead could veer the "road chain" down a connector, which
    -- poisons everything downstream (meeting point, tangents, tie-ins). Initial direction: an entry
    -- is walked downstream (its travel bearing); an exit chain is walked UPSTREAM, so opposite.
    -- The chain starts at the approach's ANCHOR (its node at the edge of the work region), whose own
    -- travel bearing is chainBearing; ap.bearing stays the bearing where the search circle cut the
    -- track - near the junction - which is what the turn-angle decisions want.
    local cb = ap.chainBearing or ap.bearing
    local wdx, wdz = math.sin(cb), math.cos(cb)
    if not useOut then wdx, wdz = -wdx, -wdz end
    -- Iteration bound scales with the region: the tool's own laid curves are ~1 m apart, so a lane
    -- crossing a 60 m work region can be a couple of hundred nodes.
    -- CLEAR MODE ONLY: build mode keeps the walk it has always had - its tie-in and meeting-point
    -- geometry was tuned against it.
    local lookAhead = (self.junctionMode == "clear")
    -- A SIDE ROAD IS HELD TO A TIGHTER TEST. A lane with no opposite-direction lane on its own
    -- heading (taken far out, at the anchors) has no road to carry on along, so anything it could
    -- walk onto past a fork is a turn - even the 30 degree one at a skewed T, which under the
    -- general 35 was taken for road, marked never-clearable, and left the side road joined.
    local turnLimit = math.rad(35)
    if lookAhead then
        local mineB, partner = ap.chainBearing or ap.bearing, false
        for _, o in ipairs(self.junctionWalkApproaches or {}) do
            if o ~= ap and o.dir ~= ap.dir
                and junctionAngDiff(mineB, o.chainBearing or o.bearing) <= math.rad(20) then
                partner = true break
            end
        end
        if not partner then turnLimit = math.rad(15) end
    end
    local endedAtFork = false
    -- THE WAY BACK IN IS ALREADY KNOWN. The anchor was reached by following this lane outward from
    -- where the circle cut it, and a run long enough (it grows with the design rig's trailer) goes
    -- past the next junction up the road - round its connector, where there is only one way on, and
    -- out along another road. Walking back by "straightest on" then sails past that connector and
    -- never returns: the lane the circle cut was claimed by nobody and was cleared as wiring (a T
    -- lost one whole lane of its main road that way). So where the run's own next step is on
    -- offer it is taken - but only as a PREFERENCE among ways on the look-ahead has not called a
    -- turn, because when the circle cuts a connector the run begins ON that connector, and
    -- retracing it blindly would walk the lane straight back onto it.
    local prefer = {}
    if lookAhead and ap.runPath ~= nil and ap.runPath[#ap.runPath] == ap.wp then
        for i = #ap.runPath, 2, -1 do prefer[ap.runPath[i]] = ap.runPath[i - 1] end
    end
    for _ = 1, math.max(64, math.ceil(radius) * 4) do
        local list = useOut and (node.out or {}) or (node.incoming or {})
        local nextId, bestDot = nil, -math.huge
        -- WHERE THE ROAD ENDS AND THE WIRING BEGINS. At a fork, each way on is followed to the next
        -- thing it joins, and one that gets there turned more than 35 degrees from the lane's
        -- heading is a TURN, not the road - it is never walked as road. If EVERY way on is a turn,
        -- the lane's road ends at this node. That is the normal state of a built T's stem: the tool
        -- consumed the stem's road past its tie-in, so the only ways on from the tie node ARE the
        -- two turn connectors - and the walk, having to go somewhere, used to pick one and mark it
        -- road, which put it beyond the reach of every clear and left the stem's lanes ending on
        -- connector points the tidy could make nothing of.
        --
        -- Only at forks (a plain bend has one way on and is followed however sharp it is), and only
        -- near the junction: further out than this a fork belongs to something else - a field
        -- entrance, the next junction's kickout - and the lane must not be cut short there on the
        -- strength of a bend in the road beyond it.
        local turnsAway = nil
        if lookAhead and #chain > 1 and (node.x - cx) ^ 2 + (node.z - cz) ^ 2 <= 35 * 35 then
            local nWays, nTurns = 0, 0
            local verdict = {}
            for _, nid in pairs(list) do
                if nid ~= cameFrom and verdict[nid] == nil then
                    local nx = ADGraphManager:getWayPointById(nid)
                    if nx ~= nil then
                        nWays = nWays + 1
                        verdict[nid] = junctionBranchTurn(node, nx, useOut, wdx, wdz, 60) > turnLimit
                        if verdict[nid] then nTurns = nTurns + 1 end
                    end
                end
            end
            if nWays >= 2 then
                if nTurns == nWays then
                    endedAtFork = true
                    break
                end
                turnsAway = verdict
            end
        end
        -- ...AND WITHIN THAT BAND, THE WAY THAT TURNS LESS OVER ITS LENGTH. "Lower id is the road"
        -- was the whole tie-break, and it is only true where the tool laid wiring onto an old road.
        -- Where the map's own junction pieces fork (53 by the registry: both ways the scan laid),
        -- ids say nothing - there it sent the lane east, 7 degrees off and turning 11 over its
        -- length, past the south-east way 3 degrees off and turning 5, and the side road became the
        -- main road. A kickout still loses: it leaves tangentially but turns away along its length.
        -- The id decides only when the two turn within 2 degrees of each other. Clear mode only.
        local farTurn, bestNx = {}, nil
        local function turnOf(nid, nx)
            if farTurn[nid] == nil then farTurn[nid] = junctionBranchTurn(node, nx, useOut, wdx, wdz, 60) end
            return farTurn[nid]
        end
        for _, nid in pairs(list) do
            if nid ~= cameFrom and not (turnsAway ~= nil and turnsAway[nid]) then
                local nx = ADGraphManager:getWayPointById(nid)
                if nx ~= nil and (nx.x - cx) ^ 2 + (nx.z - cz) ^ 2 <= r2 then
                    local dx, dz = nx.x - node.x, nx.z - node.z
                    local l = math.sqrt(dx * dx + dz * dz)
                    if l > 1e-6 then
                        local dot = (dx / l) * wdx + (dz / l) * wdz
                        -- Fork tie-break: a KICKOUT leaves its lane almost tangentially (that is the
                        -- point of it), so at its tie node the lane's continuation and the kickout's
                        -- first point can be within a degree or two of each other - and on a gently
                        -- curving lane the kickout can even be the straighter. Waypoint ids are
                        -- handed out in creation order and deletion compacts them without reordering,
                        -- so the OLDER node (lower id) is the road and the newer one the wiring laid
                        -- onto it: within a small margin, the lower id wins.
                        -- The band is 0.15 (about 30 degrees at small angles): wide enough that a
                        -- connector carrying STRAIGHT on where the lane itself bends a little at the
                        -- tie node still loses to the lane; narrow enough that a real fork of two
                        -- old roads, one clearly straighter, is still decided by bearing.
                        local take = false
                        if nextId == nil or dot > bestDot + 0.15 then
                            take = true
                        elseif dot > bestDot - 0.15 then
                            if lookAhead and bestNx ~= nil then
                                local a, b = turnOf(nid, nx), turnOf(nextId, bestNx)
                                if math.abs(a - b) >= math.rad(2) then take = a < b else take = nid < nextId end
                            else
                                take = nid < nextId
                            end
                        end
                        if take then
                            bestDot, nextId, bestNx = (nextId == nil) and dot or math.max(dot, bestDot), nid, nx
                        end
                    end
                end
            end
        end
        -- A lane does not turn through 70 degrees at one node. Where the only way on does, this
        -- track has ENDED against another road (a stem meeting its crossbar with a direct link) and
        -- walking on would follow that other road - merging two lanes into one lane group and
        -- putting the meeting point, tangents and tie-ins on the wrong track.
        local want = prefer[node]
        if want ~= nil and want.id ~= nil and want.id ~= cameFrom and table.contains(list, want.id)
            and ADGraphManager:getWayPointById(want.id) == want
            and not (turnsAway ~= nil and turnsAway[want.id])
            and (want.x - cx) ^ 2 + (want.z - cz) ^ 2 <= r2 then
            nextId, bestDot = want.id, 1
        end
        if nextId == nil or (#chain > 1 and bestDot < 0.3) then break end
        cameFrom = node.id
        local nxt = ADGraphManager:getWayPointById(nextId)
        local dx, dz = nxt.x - node.x, nxt.z - node.z
        local l = math.sqrt(dx * dx + dz * dz)
        if l > 1e-6 then wdx, wdz = dx / l, dz / l end
        node = nxt
        chain[#chain + 1] = node
    end
    local last = chain[#chain]
    local travelList = useOut and (last.out or {}) or (last.incoming or {})
    local continues = false
    for _, nid in pairs(travelList) do
        if nid ~= cameFrom then continues = true; break end
    end
    -- A lane the look-ahead ended has nowhere to go AS ROAD, whatever wiring still hangs off it.
    if endedAtFork then continues = false end
    return chain, (not continues)
end

--- Create the tie-in node at the tangent point (Tx,Tz) on an approach's track and splice it in. A
--- through-road keeps both sides (insert). A dead-end keeps only the outer side and returns the stub
--- past the tie-in for the caller to consume (deleted LAST, since removeWayPoint renumbers ids). The
--- new node inherits the track's priority flags. Returns the node, its priority flags, the stub, and
--- whether the LOCAL track at the tie-in is itself two-way - the caller uses this (both ends must
--- agree) to decide whether the new connector should be dual too, instead of always one-way.
function ADFlyoverEditor:junctionTieIn(ap, Tx, Tz, cx, cz, radius)
    local chain, deadEnd = self:junctionChain(ap, cx, cz, radius, true)
    if #chain < 2 then
        -- Only the boundary node here; tie at it. Its own edge (to whatever it still connects to)
        -- tells us if this stub of track is two-way.
        local wp = ap.wp
        local nbrId = (ap.dir == "in") and (wp.incoming or {})[1] or (wp.out or {})[1]
        local dual = false
        if nbrId ~= nil then
            local nbr = ADGraphManager:getWayPointById(nbrId)
            if nbr ~= nil then
                -- Explicit if/else, not `cond and A or B`: that idiom falls through to B whenever A
                -- is false, and A false is the NORMAL one-way case (see segDual below).
                if ap.dir == "in" then
                    dual = table.contains(wp.out or {}, nbrId)
                else
                    dual = table.contains(nbr.out or {}, wp.id)
                end
            end
        end
        return wp, (wp.flags or AutoDrive.FLAG_NONE), {}, dual
    end
    local bestSeg, bestFrac, bestd = 1, 0, math.huge
    for i = 1, #chain - 1 do
        local a, b = chain[i], chain[i + 1]
        local dx, dz = b.x - a.x, b.z - a.z
        local len2 = dx * dx + dz * dz
        local f = (len2 > 1e-6) and math.max(0, math.min(1, ((Tx - a.x) * dx + (Tz - a.z) * dz) / len2)) or 0
        local px, pz = a.x + f * dx, a.z + f * dz
        local d = (px - Tx) ^ 2 + (pz - Tz) ^ 2
        if d < bestd then bestd, bestSeg, bestFrac = d, i, f end
    end
    local outer, inner = chain[bestSeg], chain[bestSeg + 1]
    local trackFlags = outer.flags or AutoDrive.FLAG_NONE
    -- Whether the immediate outer<->inner segment is two-way: does the link OPPOSITE the travel
    -- direction exist too? An explicit if/else, NOT `cond and A or B` - that idiom evaluates B
    -- whenever A is false, and here A false IS the normal one-way case, so it fell through to
    -- testing the forward link that always exists. Result: segDual was TRUE for every entry-side
    -- splice on every one-way road, and every entry tie node got spliced in two-way - the "blue"
    -- links the invariant tripwire kept catching.
    local segDual
    if ap.dir == "in" then
        segDual = table.contains(inner.out or {}, outer.id)   -- forward is outer->inner
    else
        segDual = table.contains(outer.out or {}, inner.id)   -- forward is inner->outer
    end

    -- If the tie-in lands ON an existing lane node (within 0.35 m), reuse that node rather than stacking
    -- a new one on top of it - the survey showed near-coincident points already clutter real junctions.
    -- A dead-end then consumes only what lies PAST the reused node (deleting those also drops its
    -- inward edge, so it becomes the new terminus with nothing extra to do).
    local hitIdx = (bestFrac < 0.5) and bestSeg or (bestSeg + 1)
    local hit = chain[hitIdx]
    if (hit.x - Tx) ^ 2 + (hit.z - Tz) ^ 2 < 0.35 ^ 2 then
        local stubs = {}
        if deadEnd then
            for i = hitIdx + 1, #chain do
                local w = chain[i]
                if #(w.out or {}) + #(w.incoming or {}) > 2 then break end
                stubs[#stubs + 1] = w
            end
        end
        return hit, (hit.flags or AutoDrive.FLAG_NONE), stubs, segDual
    end

    -- Decide the stub to consume BEFORE mutating (so degree checks see the original graph). Stop at
    -- anything that is not a plain lane node (degree > 2 = a junction / shared point), so we never
    -- eat into the rest of the network.
    local stubs = {}
    if deadEnd then
        for i = bestSeg + 1, #chain do
            local w = chain[i]
            if #(w.out or {}) + #(w.incoming or {}) > 2 then break end
            stubs[#stubs + 1] = w
        end
    end

    local ny = (outer.y or 0) + ((inner.y or 0) - (outer.y or 0)) * bestFrac
    local N = ADFlyoverRecordWayPoint(Tx, ny, Tz, false, false, false, 0, trackFlags, false)
    jxNoteAdded(N)
    if N == nil then return ap.wp, trackFlags, {}, segDual end

    if ap.dir == "in" then
        junctionDisconnect(outer, inner)
        junctionConnect(outer, N, segDual)
        if not deadEnd then junctionConnect(N, inner, segDual) end
    else
        junctionDisconnect(inner, outer)
        junctionConnect(N, outer, segDual)
        if not deadEnd then junctionConnect(inner, N, segDual) end
    end
    return N, trackFlags, stubs, segDual
end

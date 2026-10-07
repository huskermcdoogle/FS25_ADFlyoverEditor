-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua
-- loads it after FlyoverEditor.lua, in the old file's order.
-- MODSPLIT: HELPERS FROM THE FILES LOADED BEFORE THIS ONE (tools/modsplit/split.py writes this block)
for _, name in ipairs({ "JX_TWIN_LEAD", "heightAlongChain", "junctionAngDiff", "junctionConnect", "junctionDisconnect", "jxByPlace", "jxInSite", "jxLanesCross", "jxMayDelete", "jxNote", "jxNoteAdded", "jxNoteMoved", "jxRemove", "jxState", "jxWasCutByUs", "tryCall" }) do
    if ADFlyoverEditor.shared == nil or ADFlyoverEditor.shared[name] == nil then
        Logging.error("[FlyoverEditor]: JxRebuild.lua needs %s, which no file loaded before it shares", name)
    end
end
local JX_TWIN_LEAD = ADFlyoverEditor.shared.JX_TWIN_LEAD
local heightAlongChain = ADFlyoverEditor.shared.heightAlongChain
local junctionAngDiff = ADFlyoverEditor.shared.junctionAngDiff
local junctionConnect = ADFlyoverEditor.shared.junctionConnect
local junctionDisconnect = ADFlyoverEditor.shared.junctionDisconnect
local jxByPlace = ADFlyoverEditor.shared.jxByPlace
local jxInSite = ADFlyoverEditor.shared.jxInSite
local jxLanesCross = ADFlyoverEditor.shared.jxLanesCross
local jxMayDelete = ADFlyoverEditor.shared.jxMayDelete
local jxNote = ADFlyoverEditor.shared.jxNote
local jxNoteAdded = ADFlyoverEditor.shared.jxNoteAdded
local jxNoteMoved = ADFlyoverEditor.shared.jxNoteMoved
local jxRemove = ADFlyoverEditor.shared.jxRemove
local jxState = ADFlyoverEditor.shared.jxState
local jxWasCutByUs = ADFlyoverEditor.shared.jxWasCutByUs
local tryCall = ADFlyoverEditor.shared.tryCall
-- MODSPLIT: end of the helpers

--- Re-space each approach over the last stretch leading to the junction.
---
--- THE SMOOTH TOOL'S REBUILD, run over each stretch: corners smoothed, points re-spaced BY CURVATURE
--- - the maximum spacing on the straights, closer together through a bend - then one relaxing pass.
--- The same three calls the smooth tool makes in its max-spacing mode, so an approach comes out
--- exactly as it would if that tool had been dragged along it by hand.
---
--- It replaced a flat re-spacing at one fixed step, which evened the straights nicely and wrecked
--- the bends: a laid corner of 1-2 m points 25 m from one junction came back as 5 m chords, up to
--- 0.7 m off the line it had been given. How closely points need to sit depends on how hard the
--- road is turning, and a single number cannot know that.
---
--- Some nodes are never moved or removed, and the respacing works in the runs between them:
---   * the lane END, which the tidy has just put on the box edge;
---   * any FORK - something else joins the lane there, and moving it would bend that something;
---   * a node a MAP MARKER points at;
---   * the outer end of the stretch, so the lane beyond it is untouched;
---   * anything an earlier lane already respaced (two approaches can share a tail).
--- Existing nodes are MOVED where the count allows, so ids survive wherever they can; only the
--- surplus is deleted and only the shortfall created. A run whose links are not uniform (one-way
--- for part of it, two-way for the rest) is left exactly as it is.
function ADFlyoverEditor:junctionRespaceApproaches(jp)
    local LEN = AutoDrive.FLYOVER_JUNCTION_RESPACE_LEN or 50
    local STEP = AutoDrive.FLYOVER_JUNCTION_RESPACE_STEP or 5
    if LEN <= 0 or STEP <= 0 then return 0, 0, 0 end

    local function live(w)
        return w ~= nil and w.id ~= nil and w.id >= 0 and ADGraphManager:getWayPointById(w.id) == w
    end
    local function neighbours(w)
        local seen, n = {}, 0
        for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
            for _, id in pairs(lst) do
                if not seen[id] then seen[id] = true n = n + 1 end
            end
        end
        return n
    end
    local function gap(a, b) return math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2) end

    local marker = {}
    if ADGraphManager.getMapMarkers ~= nil then
        for _, m in pairs(ADGraphManager:getMapMarkers() or {}) do
            if m ~= nil and m.id ~= nil then
                local w = ADGraphManager:getWayPointById(m.id)
                if w ~= nil then marker[w] = true end
            end
        end
    end

    local moved, removed, created = 0, 0, 0
    local done = {}

    -- One run: fixed node A, interior nodes, fixed node B - all consecutive on the lane.
    local function respaceRun(nodes)
        local A, B = nodes[1], nodes[#nodes]
        local interior = {}
        for i = 2, #nodes - 1 do interior[#interior + 1] = nodes[i] end
        local L = 0
        for i = 2, #nodes do L = L + gap(nodes[i - 1], nodes[i]) end
        if L < 0.5 then return end
        -- The run has to be linked the same way all along, or it is not a plain stretch of lane.
        local f0, r0 = nil, nil
        for i = 2, #nodes do
            local u, v = nodes[i - 1], nodes[i]
            local f = table.contains(u.out or {}, v.id)
            local r = table.contains(v.out or {}, u.id)
            if f0 == nil then f0, r0 = f, r elseif f ~= f0 or r ~= r0 then return end
        end
        if not f0 and not r0 then return end
        for _, w in ipairs(interior) do
            if neighbours(w) ~= 2 or marker[w] then return end
        end
        local function link(u, v)
            if f0 and r0 then junctionConnect(u, v, true)
            elseif f0 then junctionConnect(u, v, false)
            else junctionConnect(v, u, false) end
        end

        -- Where the points belong: the smooth tool's rebuild of this stretch. Two points make a
        -- straight line with nothing to smooth, and that is simply divided.
        local pts = {}
        for i, w in ipairs(nodes) do pts[i] = { x = w.x, y = w.y or 0, z = w.z } end
        local final = nil
        if #pts >= 3 and ADOffsetGeometry ~= nil and ADOffsetGeometry.resampleOpenChainByCurvature ~= nil then
            local minSpacing = math.max(AutoDrive.FIELD_LOOP_ADAPTIVE_MIN_SPACING or 1, STEP * 0.25)
            local smoothed = ADOffsetGeometry.smoothOpenChain(pts, 2,
                AutoDrive.FIELD_LOOP_MAX_WAYPOINT_TURN_DEG or 5, 180)
            local resampled = ADOffsetGeometry.resampleOpenChainByCurvature(smoothed, minSpacing, STEP,
                AutoDrive.FIELD_LOOP_ADAPTIVE_TOLERANCE or 0.01)
            final = ADOffsetGeometry.relaxOpenChain(resampled, 1, {})
        end
        if final == nil or #final < 2 then
            local nSeg = math.max(1, math.floor(L / STEP + 0.5))
            final = { pts[1] }
            for j = 1, nSeg - 1 do
                local t = j / nSeg
                final[#final + 1] = { x = A.x + (B.x - A.x) * t, z = A.z + (B.z - A.z) * t }
            end
            final[#final + 1] = pts[#pts]
        end
        local targets = {}
        for j = 2, #final - 1 do
            local q = final[j]
            -- The rebuild is 2D. Height comes off the ORIGINAL stretch, so a run on a ramp or a
            -- bridge stays on it; where the terrain can be asked, it is, the same way the smooth
            -- tool asks.
            local y = heightAlongChain(pts, q.x, q.z) or A.y or 0
            if g_currentMission ~= nil and g_currentMission.terrainRootNode ~= nil then
                local ok, ry = pcall(function() return self:resolveHeightAt(q.x, q.z, y) end)
                if ok and ry ~= nil then y = ry end
            end
            targets[#targets + 1] = { x = q.x, y = y, z = q.z }
        end
        local want = #targets
        -- Already as the rebuild would leave it? Then leave it: no churn for nothing.
        if #interior == want then
            local worst = 0
            for j = 1, want do
                local d = math.sqrt((interior[j].x - targets[j].x) ^ 2 + (interior[j].z - targets[j].z) ^ 2)
                if d > worst then worst = d end
            end
            if worst <= 0.3 then return end
        end
        local flags = (interior[1] or A).flags or AutoDrive.FLAG_NONE

        -- WHOLE RUN OR NONE OF IT - CHECKED BEFORE A SINGLE POINT MOVES.
        --
        -- A rebuild moves the points it keeps and removes the ones it does not need. Removing is not
        -- its decision to make: jxRemove refuses anything outside this junction's own arms, and the
        -- surplus at the far end of a long run sits exactly where that bound runs out.
        --
        -- This check existed already, but it sat INSIDE the surplus branch, after the moves. So it
        -- did its job - refused the deletions, refused the bridge - on a run whose points had
        -- already been moved, which is the one outcome it was written to prevent. A point slid down
        -- to 0.42 m from the neighbour it was meant to replace, and that neighbour then stayed: two
        -- points on top of each other 48 m from the junction, which is what "lots of short dense
        -- points" looked like on screen.
        --
        -- Nothing is touched until the whole run is known to be ours. A run half-rebuilt is worse
        -- than a run left at its old spacing.
        if #interior > want then
            for j = want + 1, #interior do
                if live(interior[j]) and not jxMayDelete(interior[j].x, interior[j].z) then return end
                -- nor a point kept for another part's turn (jxTwinKeep): jxRemove would refuse it too
                if jxState.jxTwinKeep ~= nil and jxState.jxTwinKeep[interior[j]] then return end
            end
        end

        -- Move what can be moved, so ids survive wherever they can.
        local keepN = math.min(#interior, want)
        for j = 1, keepN do
            local w, t = interior[j], targets[j]
            ADGraphManager:moveWayPoint(w.id, t.x, t.y, t.z, w.flags, false)
            jxNoteMoved(w)
            moved = moved + 1
        end
        local last = (keepN > 0) and interior[keepN] or A
        if #interior > want then
            -- Surplus: bridge over it first, then take it out. Objects, not ids - every removal
            -- renumbers the ids above it.
            link(last, B)
            for j = #interior, want + 1, -1 do
                local w = interior[j]
                if live(w) and jxRemove(w, "junction respace surplus") then
                    removed = removed + 1
                end
            end
        elseif #interior < want then
            -- Shortfall: open the last link and chain the new points into it.
            junctionDisconnect(last, B)
            local prev = last
            for j = keepN + 1, want do
                local t = targets[j]
                local made = ADFlyoverRecordWayPoint(t.x, t.y, t.z, false, false, false, 0, flags, false,
                    ADFlyoverEditor.fieldOf(interior[1] or A))
                jxNoteAdded(made)
                if made == nil then break end
                link(prev, made)
                prev = made
                created = created + 1
            end
            link(prev, B)
        end
    end

    local STEP0 = STEP
    for _, lane in ipairs(jp._laneSeqs or {}) do
        -- A lane may bring its own maximum spacing (read off the span itself); otherwise the default.
        STEP = lane.step or STEP0
        local seq = lane.seq
        local n = #seq
        while n > 0 and not live(seq[n]) do n = n - 1 end
        if n >= 3 then
            -- SMOOTH BACK TO THE NEXT JUNCTION, AND NOT ONE POINT PAST IT. The walk used to run a
            -- flat 50 m regardless of what it passed through. Where the next junction is nearer than
            -- that - 24 m away at one pair on the test map - it resampled straight through the
            -- neighbour and out the other side, moving its points and bridging links across it: the
            -- road far from the junction visibly changing, and clearing one of the pair wiring up the
            -- other. A fork is where this road stops being this junction's approach, so the walk
            -- stops there.
            local i0, acc = n, 0
            while i0 > 1 and acc < (lane.len or LEN) and live(seq[i0 - 1])
                and neighbours(seq[i0 - 1]) < 3 do
                acc = acc + gap(seq[i0], seq[i0 - 1])
                i0 = i0 - 1
            end
            local a = i0
            for b = i0 + 1, n do
                local w = seq[b]
                -- WHERE THIS JUNCTION'S REACH RUNS OUT IS A RUN BOUNDARY, exactly like a fork.
                --
                -- A run is broken at every point that must not move: the far end, a fork, anything
                -- already handled. The edge of the junction's own arms belongs on that list. Without
                -- it a run would start at the box and end 50 m away, and since the rebuild is all or
                -- nothing it was thrown away whole - so the points it was entitled to tidy, the ones
                -- a few metres from the box, were left exactly as the old junction had them: pairs
                -- 1 to 2 m apart on a road otherwise spaced at 5.
                --
                -- Clipped here instead, the near part is a run of its own and is rebuilt properly,
                -- and the far part is simply not this junction's to touch. Neither abandoned nor
                -- half-done.
                local fixed = (b == n) or neighbours(w) >= 3 or marker[w] or done[w]
                    or not jxMayDelete(w.x, w.z)
                if fixed then
                    -- A run is only worth touching if none of it was handled already.
                    local fresh = not (done[seq[a]] and done[w])
                    if fresh and b - a >= 1 then
                        local nodes = {}
                        for i = a, b do nodes[#nodes + 1] = seq[i] end
                        local ok = true
                        for _, q in ipairs(nodes) do if not live(q) then ok = false break end end
                        if ok then
                            -- For the check after a clear, and nothing else: which stretch this
                            -- rebuild works on and how far along the lane from its end, so the check
                            -- can hold the respacing to its own reach. Read only by the check.
                            if jxState.jxJournal ~= nil then
                                local along = 0
                                for i = a, n - 1 do along = along + gap(seq[i], seq[i + 1]) end
                                local pts = {}
                                for i, q in ipairs(nodes) do pts[i] = { x = q.x, z = q.z } end
                                jxState.jxRespaceRun = { pts = pts, along = along, firstGap = gap(seq[a], seq[a + 1]),
                                                 cap = lane.len or LEN }
                            end
                            jxState.jxInRespace = true
                            tryCall("junction respace run", respaceRun, nodes)
                            jxState.jxInRespace = false
                            jxState.jxRespaceRun = nil
                        end
                    end
                    a = b
                end
            end
            for i = i0, n do done[seq[i]] = true end
        end
    end
    return moved, removed, created
end

--- THE LANE-END TIDY, BY PATHS. Nothing is constructed.
---
--- A through road already HAS a line across its junction: the path it ran on. So each through path
--- is smoothed whole with the smooth tool's rebuild - by now its old tie-in nodes are plain points, so
--- nothing is pinned and what they left in it irons out - and then, when through paths are being
--- cleared, it is CUT where it enters and leaves the box: a point put exactly on each edge, and
--- what lies between removed. A side-road lane has no path across (building the junction consumed
--- it), so it is smoothed and then carried on its own heading, read from its clean stretch, to the
--- main road's offset line. No centres, no widths, no run-ins laid onto lane ends.
---
--- The box still comes from the road centrelines (the dry run works it out); it only says where to cut.
function ADFlyoverEditor:junctionTidyByPaths(jp)
    local box = jp._box
    local routes = jp.pathRoutes
    if box == nil or routes == nil then return nil end
    local leave = self.junctionLeaveThrough ~= false
    local STEP = AutoDrive.FLYOVER_JUNCTION_RESPACE_STEP or 5

    -- THE ROAD BETWEEN TWO PARTS STAYS (split junctions, the user's rule 2 of 2026-10-03). With through
    -- roads off, each part's clear cuts the main road at its box - and where two parts are close, one
    -- part's box can reach past the half-way point to the other (26n's box is centred 6.4 m towards
    -- 26s, which is 12 m away). Clearing the second part then took the whole road between the two,
    -- up to where the first part's clear had cut it (at 20, 20s's lanes north ended at 20n's cut). So
    -- with a split saved, the road is cut and the box swept only on this part's side of the half-way
    -- line to each other part: what lies nearer another part is that part's, and once both parts are
    -- cleared the road between them is left as a piece of main road for the builder to join to (the
    -- check says it is left on purpose). Only the cut, the box sweep and the respacing of the legs
    -- read this, and the side roads: one cut on another part's side is that part's road, and is not
    -- carried to this box. This part's own turns go whole, wherever they lie. A junction kept whole,
    -- or not decided, is one junction and is cut at its box as before.
    -- AutoDrive.FLYOVER_JUNCTION_PART_ROAD = false turns this off, for the harness only.
    local hereP, otherP = nil, {}
    if not leave and jp.junctionPart ~= nil and jp.junctionNumber ~= nil and AutoDrive.FLYOVER_JUNCTION_PART_ROAD ~= false then
        local okE, f = pcall(self.junctionEntryOf, self, jp.junctionNumber)
        if okE and f ~= nil and f.decision == "split" and f.parts ~= nil then
            hereP = jp.junctionPart
            for _, q in ipairs(f.parts) do
                if q ~= hereP then otherP[#otherP + 1] = q end
            end
        end
    end
    -- On this part's side of every half-way line (always, where no split is saved).
    local function ownHalf(x, z)
        if hereP == nil then return true end
        local dh = (x - hereP.x) ^ 2 + (z - hereP.z) ^ 2
        for _, q in ipairs(otherP) do
            if (x - q.x) ^ 2 + (z - q.z) ^ 2 < dh then return false end
        end
        return true
    end

    -- A SIDE LANE THAT IS A THROUGH ROAD'S OWN LANE IS NOT CARRIED TO THE BOX. Where a lane splits
    -- just outside the circle the lanes are picked from, the circle cuts both branches: two entries,
    -- each followed back out along the one lane they share. The two are folded into one only when
    -- that walk happens to stop on the same point, and the points are a few metres apart, so it is
    -- down to the spacing. Where they are not folded, one is paired into the through road and the
    -- other is left over as a "side road" whose lane comes in to where it is cut along that through
    -- road. Carried to the box like a side road, it laid a new lane end off the
    -- through road: at 39se, cleared with through roads kept after 39, the main road's lane in from
    -- the west forked into a 5 m dead end 12 m from 39se's middle (the clear of 39 had left 39se's
    -- right turn leaving the main road there, so it read as 39se's own tie point). The side-road
    -- list still holds it, for the junction's type (which reads that list and is not changed here);
    -- only the tidy leaves it out. AutoDrive.FLYOVER_JUNCTION_SIDE_DUPES = false puts it back, for
    -- the harness only (README).
    local sideLanes = {}
    do
        local onRoute = {}
        for r, nodes in ipairs(routes.through or {}) do
            local set = {}
            for _, n in ipairs(nodes) do set[n] = true end
            onRoute[r] = set
        end
        for _, sl in ipairs(routes.side or {}) do
            local nodes = sl.nodes or {}
            -- From the lane's far end in to where it is cut - its tie node, or with none, its
            -- point nearest the middle. Past that a side lane may run on round a turn and down a
            -- through road, which says nothing.
            local upto = nil
            for i, n in ipairs(nodes) do
                if n == sl.cutNode then upto = i break end
            end
            if upto == nil then
                local bd = math.huge
                for i, n in ipairs(nodes) do
                    local d = (n.x - box.centre.x) ^ 2 + (n.z - box.centre.z) ^ 2
                    if d < bd then bd, upto = d, i end
                end
            end
            -- The lane comes in to where it is cut along a through road: that point and the one before
            -- it are both that road's. A side road's own lane comes in to its tie node along the side
            -- road. Not every point out to the lane's far end: the two walks out stop on different
            -- points, so the far end can lie a point or two past where the through road's own list
            -- begins (3 on the session network, turn radius 2: a 19 m copy of the main road's lane
            -- laid beside it, ending in a dead end).
            local dup = false
            if upto ~= nil and upto >= 2 and AutoDrive.FLYOVER_JUNCTION_SIDE_DUPES ~= false then
                for _, set in ipairs(onRoute) do
                    if set[nodes[upto]] and set[nodes[upto - 1]] then dup = true break end
                end
            end
            if dup then
                Logging.info("[FlyoverEditor]: junction - the lane read as a side road from %.1f, %.1f comes in along a through road to %.1f, %.1f - that road's own lane twice; not carried to the box.",
                    nodes[1].x, nodes[1].z, nodes[upto].x, nodes[upto].z)
            elseif upto ~= nil and not ownHalf(nodes[upto].x, nodes[upto].z) then
                -- the road between two parts, cut on the other part's side (the road between stays)
                Logging.info("[FlyoverEditor]: junction - the side road ending at %.1f, %.1f lies nearer another part of this junction than this one - that part's road; not carried to this box.",
                    nodes[upto].x, nodes[upto].z)
            else
                sideLanes[#sideLanes + 1] = sl
            end
        end
    end

    local function live(w) return w ~= nil and w.id ~= nil and ADGraphManager:getWayPointById(w.id) == w end
    local function distLine(line, x, z)
        local best = math.huge
        for k = 2, #line do
            local ax, az = line[k - 1].x, line[k - 1].z
            local vx, vz = line[k].x - ax, line[k].z - az
            local L2 = vx * vx + vz * vz
            if L2 > 1e-9 then
                local t = math.max(0, math.min(1, ((x - ax) * vx + (z - az) * vz) / L2))
                local d = (x - (ax + vx * t)) ^ 2 + (z - (az + vz * t)) ^ 2
                if d < best then best = d end
            end
        end
        return math.sqrt(best)
    end
    local reach2 = (math.max(box.a.offset, box.b.offset) * 1.5 + 2) ^ 2
    local function inBox(x, z)
        if (x - box.centre.x) ^ 2 + (z - box.centre.z) ^ 2 > reach2 then return false end
        return distLine(box.a.centre, x, z) <= box.a.offset and distLine(box.b.centre, x, z) <= box.b.offset
    end
    -- In the claim of the road a side lane MEETS: whichever of the two it is not running along.
    local function inOther(x, z, hx, hz)
        local function along(r)
            local c = r.centre
            local bi, bd = 1, math.huge
            for k = 1, #c do
                local d = (c[k].x - box.centre.x) ^ 2 + (c[k].z - box.centre.z) ^ 2
                if d < bd then bd, bi = d, k end
            end
            local a, b = c[math.max(1, bi - 2)], c[math.min(#c, bi + 2)]
            local vx, vz = b.x - a.x, b.z - a.z
            local l = math.sqrt(vx * vx + vz * vz)
            if l < 1e-6 then return 0 end
            return math.abs((vx / l) * hx + (vz / l) * hz)
        end
        local other = (along(box.a) < along(box.b)) and box.a or box.b
        if (x - box.centre.x) ^ 2 + (z - box.centre.z) ^ 2 > 40 * 40 then return false end
        return distLine(other.centre, x, z) <= other.offset
    end
    local function dualOf(a, b)
        return table.contains(a.out or {}, b.id) and table.contains(b.out or {}, a.id)
    end

    -- Smooth a whole lane with the respacing (the smooth tool's rebuild), then hand back the lane as
    -- it now is: walked from its first node along travel links, hugging the old polyline.
    --
    -- `lastStep` is the spacing the LAST lane smoothed was rebuilt at - read off that lane's own
    -- points, not a constant - and the legs cut at the box edge are rebuilt at the same spacing so a
    -- road comes back looking like itself. It has to be declared HERE, above the function that
    -- writes it: declared below, `lastStep = own` inside smoothLane bound to a global instead, the
    -- local stayed nil for the whole clear, and every leg was respaced at the default spacing.
    local n0 = nil
    local lastStep = nil
    local function smoothLane(nodes, useOut)
        -- ONLY AS FAR AS THE FIRST FORK. Smoothing deletes and re-creates the points between the
        -- nodes it pins, and over 50 m of road that reaches into whatever else is tied in along the
        -- way - which is how a clear came to break a neighbouring junction's connection. A fork is
        -- where something else joins, so the fairing stops there; it is also pinned, so where a fork
        -- sits right against the box (nothing would be smoothed at all) the span carries on past it
        -- to a MINIMUM of 15 m and the fork itself still never moves.
        local live0 = {}
        for _, n in ipairs(nodes) do if live(n) then live0[#live0 + 1] = n end end
        if #live0 < 3 then return live0 end
        local function isFork(w)
            local seen, d = {}, 0
            for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
                for _, id in pairs(lst) do if not seen[id] then seen[id] = true d = d + 1 end end
            end
            return d >= 3
        end
        local mid, md = 1, math.huge
        for i, n in ipairs(live0) do
            local d = (n.x - box.centre.x) ^ 2 + (n.z - box.centre.z) ^ 2
            if d < md then md, mid = d, i end
        end
        local function reach(from, step)
            local i, run = from, 0
            while true do
                local j = i + step
                if j < 1 or j > #live0 then return i end
                run = run + math.sqrt((live0[j].x - live0[i].x) ^ 2 + (live0[j].z - live0[i].z) ^ 2)
                i = j
                if run >= 50 then return i end
                if isFork(live0[i]) and run >= 15 then return i end
            end
        end
        local lo, hi = reach(mid, -1), reach(mid, 1)
        local seq = {}
        for i = lo, hi do seq[#seq + 1] = live0[i] end
        if #seq < 3 then return seq end
        -- A MAIN ROAD THAT TURNS THE CORNER IS LEFT ALONE. Smoothing the whole path redraws the bend
        -- out to 50 m either side, and at a corner that bend is the road itself, not old wiring - at
        -- 24 (by the registry) the corner was respaced out to 37 m. The turn is read across the
        -- middle, 8 m either side; beyond 45 degrees the path is returned untouched.
        do
            local function along(from, step)
                local i, run = from, 0
                while i + step >= 1 and i + step <= #live0 and run < 8 do
                    run = run + math.sqrt((live0[i + step].x - live0[i].x) ^ 2 + (live0[i + step].z - live0[i].z) ^ 2)
                    i = i + step
                end
                return live0[i]
            end
            local a, m, b = along(mid, -1), live0[mid], along(mid, 1)
            if a ~= m and b ~= m then
                local turn = junctionAngDiff(math.atan2(m.x - a.x, m.z - a.z), math.atan2(b.x - m.x, b.z - m.z))
                if turn > math.rad(45) then
                    ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - the main road turns %.0f degrees here; its corner is left as it is.", math.deg(turn))
                    return seq
                end
            end
        end
        local old = {}
        for i, n in ipairs(seq) do old[i] = { x = n.x, z = n.z } end
        local first, last = seq[1], seq[#seq]
        -- THE MAXIMUM SPACING IS THE SPAN'S OWN. A road recorded at 13 m and one laid at 5 m should
        -- each come back looking like themselves, so the rebuild's max spacing is read off the span:
        -- the upper-quartile gap between its points as they were (the straights set it; the dense
        -- bits of old wiring do not drag it down), kept within sane bounds.
        local gaps = {}
        for i = 2, #seq do
            gaps[#gaps + 1] = math.sqrt((seq[i].x - seq[i - 1].x) ^ 2 + (seq[i].z - seq[i - 1].z) ^ 2)
        end
        table.sort(gaps)
        local own = gaps[math.max(1, math.ceil(#gaps * 0.75))] or STEP
        own = math.max(4, math.min(15, own))
        lastStep = own
        jp._laneSeqs = { { seq = seq, useOut = useOut, len = 1e9, step = own } }
        tryCall("junction smooth path", function() self:junctionRespaceApproaches(jp) end)
        n0 = #seq
        local out, node, came = { first }, first, nil
        for _ = 1, 600 do
            if node == last then break end
            local list = useOut and (node.out or {}) or (node.incoming or {})
            local best, bd = nil, math.huge
            for _, id in pairs(list) do
                local nx = ADGraphManager:getWayPointById(id)
                if nx ~= nil and nx ~= came then
                    local d = distLine(old, nx.x, nx.z)
                    if d < bd then bd, best = d, nx end
                end
            end
            if best == nil or bd > 3 then break end
            came, node = node, best
            out[#out + 1] = node
        end
        return out
    end

    local made, cutN, removed = 0, 0, 0
    local ends = {}
    local keep = {}

    -- Put a point at (x, z) between a and b (a before b along `fwd` travel), and return it.
    local function splitAt(a, b, x, z, fwdAB)
        local dual = dualOf(a, b)
        local y = (a.y or 0) + ((b.y or 0) - (a.y or 0)) * 0.5
        local n = ADFlyoverRecordWayPoint(x, y, z, false, false, false, 0, a.flags or AutoDrive.FLAG_NONE, false,
            ADFlyoverEditor.fieldOf(a))
        jxNoteAdded(n)
        if n == nil then return nil end
        junctionDisconnect(a, b)
        if fwdAB then junctionConnect(a, n, dual) junctionConnect(n, b, dual)
        else junctionConnect(n, a, dual) junctionConnect(b, n, dual) end
        made = made + 1
        return n
    end

    local afterCut = {}
    -- THE ROAD ANOTHER PART'S TURN NEEDS (split junctions, the user's rule 1 of 2026-10-03): points of
    -- a through lane inside the box that are kept although the through road is cut, because another
    -- part's turn leaves or joins the lane there (jp._twin, junctionTwinTurns). Treated as lying
    -- outside the box by the cut, the box sweep and the respacing of the legs.
    local spareSet = {}
    local twinAt = (jp._twin ~= nil and jp._twin.attach) or {}
    -- THROUGH PATHS
    -- Points per metre of a run of positions.
    local function density(list)
        if #list < 2 then return nil end
        local L = 0
        for i = 2, #list do L = L + math.sqrt((list[i].x - list[i - 1].x) ^ 2 + (list[i].z - list[i - 1].z) ^ 2) end
        if L < 1 then return nil end
        return (#list - 1) / L
    end
    -- The longest gap between two points of a run of positions: the sparsest the road ever was.
    local function longest(list)
        local m = nil
        for i = 2, #list do
            local g = math.sqrt((list[i].x - list[i - 1].x) ^ 2 + (list[i].z - list[i - 1].z) ^ 2)
            if m == nil or g > m then m = g end
        end
        return m
    end
    local function segCrosses(a, b)
        local vx, vz = b.x - a.x, b.z - a.z
        local len = math.sqrt(vx * vx + vz * vz)
        for k = 1, math.floor(len / 0.5) do
            local t = k * 0.5 / len
            if inBox(a.x + vx * t, a.z + vz * t) then return true end
        end
        return false
    end
    for _, nodes in ipairs(routes.through or {}) do
        -- THE ORIGINAL DENSITY OF EACH LEG, read before anything moves: the path's own points on the
        -- way in to the box and on the way out of it, within 50 m.
        local before, after, passed = {}, {}, false
        local prevN = nil
        for _, n in ipairs(nodes) do
            if live(n) and (n.x - box.centre.x) ^ 2 + (n.z - box.centre.z) ^ 2 <= 50 * 50 then
                local inside = inBox(n.x, n.z)
                if not passed and (inside or (prevN ~= nil and segCrosses(prevN, n))) then passed = true end
                if not inside then
                    if passed then after[#after + 1] = { x = n.x, z = n.z }
                    else before[#before + 1] = { x = n.x, z = n.z } end
                end
                prevN = n
            end
        end
        local densIn, densOut = density(before), density(after)
        local gapIn, gapOut = longest(before), longest(after)
        local lane = smoothLane(nodes, true)
        for _, n in ipairs(lane) do keep[n] = true end
        -- ANOTHER PART'S TURN LEAVES OR JOINS THIS LANE INSIDE THE BOX: the clear stops short of it.
        -- With through roads off the lane is cut at the box, and everything of it inside goes - and
        -- with it the point the other part's turn leaves the lane at (at 39, 39se's right turn lost
        -- its first point and was left fed by nothing; at 26 and 20 the same). So the lane is kept
        -- from that point on out of the box, on the side away from this part's middle (the side the
        -- other part lies), and on this part's side for JX_TWIN_LEAD metres more, never past the
        -- lane's point nearest the middle: the lane is cut there instead of at the box edge, and this
        -- part's stub on that side is that much longer. Where the turn leaves a lane running out
        -- towards the other part, the stub starts that far before it; where it joins (or leaves) a
        -- lane coming in from the other part, the stub ends that far after it. The point itself is
        -- never the stub's end: a turn leaving the lane's very first point is a turn nothing can be
        -- driven onto (20n, before this rule). With through roads kept the lane is not cut at all.
        if not leave and #lane >= 2 and next(twinAt) ~= nil then
            -- This part's middle: where the user saved it (the box can sit off it - 26n's box is
            -- centred 6 m towards 26s), and the lane's point nearest it.
            local here = (jp.junctionPart ~= nil and jp.junctionPart.x ~= nil) and jp.junctionPart or box.centre
            local im, imd = 1, math.huge
            for i, n in ipairs(lane) do
                local d = (n.x - here.x) ^ 2 + (n.z - here.z) ^ 2
                if d < imd then imd, im = d, i end
            end
            local function gapAt(i, j) return math.sqrt((lane[j].x - lane[i].x) ^ 2 + (lane[j].z - lane[i].z) ^ 2) end
            -- The way along the lane away from this part's middle: the side the lane is kept on.
            local function towards(i) return (i > im) and 1 or -1 end
            -- Where this clear cuts: inside the box, on this part's side of the half-way lines.
            local function cutsAt(x, z) return inBox(x, z) and ownHalf(x, z) end
            -- There, or short of it by less than JX_TWIN_LEAD along the lane towards this part's
            -- middle: the cut falls on, or just before, the point the turn leaves (20n: 0.3 m outside
            -- the box, so the cut made it the lane's very first point).
            local function near(i)
                if cutsAt(lane[i].x, lane[i].z) then return true end
                local step = towards(i)
                local acc, j = 0, i
                while acc < JX_TWIN_LEAD do
                    local nj = j - step
                    if lane[nj] == nil then return false end
                    local L = gapAt(j, nj)
                    if acc + L > JX_TWIN_LEAD and L > 0 then
                        local t = (JX_TWIN_LEAD - acc) / L
                        return cutsAt(lane[j].x + (lane[nj].x - lane[j].x) * t, lane[j].z + (lane[nj].z - lane[j].z) * t)
                    end
                    if cutsAt(lane[nj].x, lane[nj].z) then return true end
                    if nj == im then return false end
                    acc = acc + L
                    j = nj
                end
                return false
            end
            local found = {}
            for i, n in ipairs(lane) do
                if twinAt[n] and live(n) and i ~= im and near(i) then found[#found + 1] = i end
            end
            -- Last first: a point laid into the lane list shifts every index after it.
            for fi = #found, 1, -1 do
                local i = found[fi]
                local F = lane[i]
                local step = towards(i)     -- out of the box, away from this part's middle
                -- the other part's side: F on out to the first point outside the box
                local k = i
                while k >= 1 and k <= #lane do
                    spareSet[lane[k]] = true
                    if not inBox(lane[k].x, lane[k].z) then break end
                    k = k + step
                end
                -- This part's side: JX_TWIN_LEAD metres back towards the middle, never as far as the
                -- lane's point nearest the middle. Whole links while they fit (1 m over is allowed);
                -- the rest by a point laid on the next link, never under 0.6 m from either of its ends
                -- (the clean-up folds two points 0.3 m apart into one).
                local acc, j = 0, i
                while acc < JX_TWIN_LEAD do
                    local nj = j - step
                    local o = lane[nj]
                    if o == nil or not live(o) then break end
                    local L = gapAt(j, nj)
                    if nj ~= im and acc + L <= JX_TWIN_LEAD + 1 then
                        acc = acc + L
                        j = nj
                        spareSet[lane[j]] = true
                    else
                        local want = math.min(JX_TWIN_LEAD - acc, L - 0.6)
                        local P = lane[j]
                        local a, b = o, P
                        if step < 0 then a, b = P, o end
                        if want >= 0.6 and table.contains(a.out or {}, b.id) then
                            local ux, uz = (o.x - P.x) / L, (o.z - P.z) / L
                            local S = splitAt(a, b, P.x + ux * want, P.z + uz * want, true)
                            if S ~= nil then
                                keep[S], spareSet[S] = true, true
                                if step > 0 then
                                    table.insert(lane, j, S)
                                else
                                    table.insert(lane, j + 1, S)
                                    im = im + 1
                                end
                                acc = acc + want
                            end
                        end
                        break
                    end
                end
                Logging.info("[FlyoverEditor]: junction - another part's turn leaves or joins the lane at %.1f, %.1f, in or beside this box: the lane is kept from there on away from this part's middle, and for %.1f m towards it; it is cut there instead of at the box edge.",
                    F.x, F.z, acc)
            end
            if jxState.jxTwinKeep ~= nil then
                for n in pairs(spareSet) do jxState.jxTwinKeep[n] = true end
            end
        end
        -- Inside the box for the cut: not a point kept for another part's turn (spareSet).
        local function cutIn(n) return inBox(n.x, n.z) and not spareSet[n] and ownHalf(n.x, n.z) end
        if not leave and #lane >= 2 then
            -- where it enters and leaves the box, to a quarter metre
            local i = 1
            while i < #lane do
                local a, b = lane[i], lane[i + 1]
                local ina, inb = cutIn(a), cutIn(b)
                if ina ~= inb and (spareSet[a] or spareSet[b]) and inBox(a.x, a.z) and inBox(b.x, b.z) then
                    -- Where the kept stretch for another part's turn begins or ends inside the box:
                    -- cut right there, at the point kept.
                    if table.contains(a.out or {}, b.id) then
                        ends[#ends + 1] = ina and b or a
                        junctionDisconnect(a, b)
                        cutN = cutN + 1
                    end
                elseif ina ~= inb then
                    local lo, hi = 0, 1
                    for _ = 1, 12 do
                        local t = (lo + hi) * 0.5
                        local x, z = a.x + (b.x - a.x) * t, a.z + (b.z - a.z) * t
                        if (inBox(x, z) and ownHalf(x, z)) == ina then lo = t else hi = t end
                    end
                    local t = ina and hi or lo   -- the point just OUTSIDE the box
                    local x, z = a.x + (b.x - a.x) * t, a.z + (b.z - a.z) * t
                    local outside = ina and b or a
                    if (outside.x - x) ^ 2 + (outside.z - z) ^ 2 > 0.75 ^ 2 then
                        local n = splitAt(a, b, x, z, true)
                        if n ~= nil then
                            keep[n] = true
                            table.insert(lane, i + 1, n)
                            ends[#ends + 1] = n
                            -- n sits outside; the inside neighbour is cut off from it
                            if ina then junctionDisconnect(a, n) else junctionDisconnect(n, b) end
                            cutN = cutN + 1
                            i = i + 1
                        end
                    else
                        ends[#ends + 1] = outside
                        junctionDisconnect(a, b)
                        cutN = cutN + 1
                    end
                elseif not ina and not inb and not spareSet[a] and not spareSet[b]
                    and not inBox(a.x, a.z) and not inBox(b.x, b.z) then
                    -- a long link can cross the box with both ends outside it
                    local vx, vz = b.x - a.x, b.z - a.z
                    local len = math.sqrt(vx * vx + vz * vz)
                    local t0, t1 = nil, nil
                    for k = 1, math.floor(len / 0.25) do
                        local t = (k * 0.25) / len
                        if inBox(a.x + vx * t, a.z + vz * t) and ownHalf(a.x + vx * t, a.z + vz * t) then
                            if t0 == nil then t0 = t end
                            t1 = t
                        end
                    end
                    if t0 ~= nil then
                        local n1 = splitAt(a, b, a.x + vx * math.max(0, t0 - 0.25 / len), a.z + vz * math.max(0, t0 - 0.25 / len), true)
                        if n1 ~= nil then
                            local n2 = splitAt(n1, b, a.x + vx * math.min(1, t1 + 0.25 / len), a.z + vz * math.min(1, t1 + 0.25 / len), true)
                            if n2 ~= nil then
                                junctionDisconnect(n1, n2)
                                keep[n1], keep[n2] = true, true
                                ends[#ends + 1] = n1
                                ends[#ends + 1] = n2
                                table.insert(lane, i + 1, n1)
                                table.insert(lane, i + 2, n2)
                                cutN = cutN + 1
                                i = i + 2
                            end
                        end
                    end
                end
                i = i + 1
            end
        end

        -- AND EACH APPROACH REBUILT AT THE DENSITY IT HAD - WHETHER THE THROUGH PATHS WERE CUT OR
        -- LEFT. This decides the spacing on the run into the junction, and it used to sit inside the
        -- "not leave" branch above purely because it was written alongside the trimming. It does not
        -- depend on the trimming: it splits the lane where it meets the box and rebuilds each side
        -- at the density that side had before anything moved, which is as true of a lane left whole
        -- as of one cut in two.
        --
        -- Left where it was, a clear with through paths kept never restored the density of a through
        -- approach at all - those roads came back with whatever spacing the old junction's connector
        -- hookups had left them, which is the pairs a metre or two apart still sitting a few metres
        -- off the box after everything else had been tidied.
        if #lane >= 2 then
            local half, nHalves = {}, 0
            for _, n in ipairs(lane) do
                if live(n) and (not inBox(n.x, n.z) or spareSet[n] or not ownHalf(n.x, n.z)) then
                    half[#half + 1] = n
                elseif #half > 0 then
                    -- the entry side: runs outer end -> box, the way the lane is travelled
                    afterCut[#afterCut + 1] = { seq = half, useOut = true, step = lastStep, len = 1e9, dens = densIn, maxGap = gapIn }
                    nHalves = nHalves + 1
                    half = {}
                end
            end
            if #half > 0 and nHalves > 0 then
                -- the exit side: box -> outer end as travelled, so reversed to end on the box too
                local rev = {}
                for k = #half, 1, -1 do rev[#rev + 1] = half[k] end
                afterCut[#afterCut + 1] = { seq = rev, useOut = false, step = lastStep, len = 1e9, dens = densOut, maxGap = gapOut }
            end
        end
    end

    local function cleanPair(sl, lane)
        local near, far, ni = nil, nil, nil
        if sl.cutNode ~= nil then
            for i, n in ipairs(lane) do if n == sl.cutNode then ni = i break end end
            -- The tie node was spliced in by the build and can sit a little off the lane; the
            -- point BEFORE it is original road, so the lane ends there and is laid fresh from it.
            if ni ~= nil and ni >= 3 then ni = ni - 1 end
            if ni ~= nil and ni >= 2 then
                near = lane[ni]
                for j = ni - 1, 1, -1 do
                    local m = lane[j]
                    -- A SHORT baseline, 8 m. The tie node is already out of it (that was what
                    -- tilted a short baseline before), and on a road that bends steadily all the
                    -- way in, a long chord points where the road WAS: 25 m read the heading
                    -- 10 degrees behind the road's heading at its end, and the carry drifted off.
                    if (m.x - near.x) ^ 2 + (m.z - near.z) ^ 2 >= 8 * 8 then far = m break end
                end
                if far == nil then far = lane[1] end
                if far == near then near, far, ni = nil, nil, nil end
            else
                ni = nil
            end
        end
        for i = #lane, 1, -1 do
            if near ~= nil then break end
            local n = lane[i]
            if (n.x - box.centre.x) ^ 2 + (n.z - box.centre.z) ^ 2 >= 22 * 22 then
                near, ni = n, i
                for j = i - 1, 1, -1 do
                    local m = lane[j]
                    if (m.x - n.x) ^ 2 + (m.z - n.z) ^ 2 >= 15 * 15 then far = m break end
                end
                break
            end
        end
        return near, far, ni
    end

    -- ONE HEADING PER ROAD, NOT ONE PER LANE. Each side lane used to be carried to the box on a
    -- heading read off its own last few metres, and two lanes of one road never read quite the same:
    -- a degree apart is 30 cm over the carry, so the pair converged or spread on the way in, and
    -- where both leaned the same way the whole branch drifted off its road. The lanes of one road are
    -- parallel by definition, so the road gets ONE heading - the mean of its lanes' inward headings,
    -- every lane's list running outer end first whichever way it is driven - and each lane is carried
    -- on that from its own clean node. Parallel by construction: the width at the clean nodes is the
    -- width at the box.
    local sharedHeading = {}
    do
        local reads = {}
        for _, sl in ipairs(sideLanes) do
            local lane = {}
            for _, n in ipairs(sl.nodes) do if live(n) then lane[#lane + 1] = n end end
            if #lane >= 2 then
                local near, far = cleanPair(sl, lane)
                if near ~= nil and far ~= nil then
                    local hx, hz = near.x - far.x, near.z - far.z
                    local hl = math.sqrt(hx * hx + hz * hz)
                    if hl > 0.5 then reads[#reads + 1] = { sl = sl, hx = hx / hl, hz = hz / hl, x = near.x, z = near.z, near = near, lane = lane } end
                end
            end
        end
        local used = {}
        for i, r in ipairs(reads) do
            if not used[i] then
                local grp, sx, sz = { r }, r.hx, r.hz
                used[i] = true
                for j = i + 1, #reads do
                    local q = reads[j]
                    -- same road: heading within 20 degrees, and no more than a road's width apart sideways
                    if not used[j] and (q.hx * r.hx + q.hz * r.hz) >= math.cos(math.rad(20)) then
                        local side = math.abs((q.x - r.x) * -r.hz + (q.z - r.z) * r.hx)
                        if side <= 12 then
                            used[j] = true
                            grp[#grp + 1] = q
                            sx, sz = sx + q.hx, sz + q.hz
                        end
                    end
                end
                local l = math.sqrt(sx * sx + sz * sz)
                if #grp >= 2 and l > 0 then
                    -- THE HEADING OF THE LANE CUT NEAREST THE JUNCTION, NOT THE MEAN. Headings read at
                    -- different stations on a bend are not the same quantity: one lane read 106
                    -- degrees 11 m out, its partner 98 degrees 30 m back where the road still
                    -- pointed that way, and their mean - 102 - was wrong for both. Both lanes were
                    -- carried 4 degrees off and arrived 1.2 m to one side of their box. The mean
                    -- is kept only where the lanes were read at about the same place.
                    local gx, gz = sx / l, sz / l
                    local nearG, nearD, farD = nil, math.huge, 0
                    for _, g in ipairs(grp) do
                        local d = math.sqrt((g.near.x - box.centre.x) ^ 2 + (g.near.z - box.centre.z) ^ 2)
                        if d < nearD then nearD, nearG = d, g end
                        if d > farD then farD = d end
                    end
                    if nearG ~= nil and farD - nearD > 5 then gx, gz = nearG.hx, nearG.hz end
                    for _, g in ipairs(grp) do sharedHeading[g.sl] = { hx = gx, hz = gz } end
                    -- THE LANES OF ONE ROAD ARE CUT AT THE SAME PLACE. Each lane finds its own clean
                    -- node, and on a bend they disagree wildly: one lane of a side road had a plain
                    -- tie node 11 m out while the search for where its partner's swing began ran back
                    -- up the curve to 30 m - eight points of road dug up and re-laid as an arc beside
                    -- a lane left almost untouched, and the pair 0.6 m wider at the box than up the
                    -- road. The lane cut NEAREST the junction is the evidence that the road is clean
                    -- from there, so its station is every lane's station.
                    local nearest = math.huge
                    for _, g in ipairs(grp) do
                        local d = math.sqrt((g.near.x - box.centre.x) ^ 2 + (g.near.z - box.centre.z) ^ 2)
                        if d < nearest then nearest = d end
                    end
                    local grpState = { width = nil }
                    for _, g in ipairs(grp) do
                        local sh = sharedHeading[g.sl]
                        sh.station = math.sqrt((g.near.x - box.centre.x) ^ 2 + (g.near.z - box.centre.z) ^ 2)
                        sh.nearest, sh.group = nearest, grpState
                    end
                end
                -- AND THE ROAD'S OWN WIDTH, FROM WHERE IT STILL HAS IT. The node before a tie node is
                -- already on the flare - the lanes spread for their turns before the connectors
                -- leave them - so a carry that is merely parallel preserves the flare all the way
                -- to the box: 4.2 m apart at the clean nodes of a road that is 4.0 m wide. The width
                -- is read well back up the branch (the middle of the readings, as for the box),
                -- and each lane's carry runs along the centreline offset by half of it. The clean
                -- node is eased onto that line, a few decimetres at most.
                if #grp == 2 and l > 0 then
                    local A, B = grp[1], grp[2]
                    local hx, hz = sx / l, sz / l
                    local reads2 = {}
                    for _, p in ipairs(A.lane) do
                        local db = (p.x - box.centre.x) ^ 2 + (p.z - box.centre.z) ^ 2
                        if db >= 14 * 14 and db <= 40 * 40 then
                            local best = math.huge
                            for k = 1, #B.lane - 1 do
                                local u, v = B.lane[k], B.lane[k + 1]
                                local dx, dz = v.x - u.x, v.z - u.z
                                local L = dx * dx + dz * dz
                                local t = (L > 0) and math.max(0, math.min(1, ((p.x - u.x) * dx + (p.z - u.z) * dz) / L)) or 0
                                local d = math.sqrt((u.x + dx * t - p.x) ^ 2 + (u.z + dz * t - p.z) ^ 2)
                                if d < best then best = d end
                            end
                            if best < 12 then reads2[#reads2 + 1] = best end
                        end
                    end
                    if #reads2 >= 2 then
                        table.sort(reads2)
                        local w = reads2[math.floor((#reads2 + 1) / 2)]
                        local mx, mz = (A.near.x + B.near.x) / 2, (A.near.z + B.near.z) / 2
                        local px, pz = -hz, hx
                        for _, g in ipairs(grp) do
                            local lat = (g.near.x - mx) * px + (g.near.z - mz) * pz
                            local want = (lat >= 0 and 1 or -1) * w / 2
                            local delta = want - lat
                            if math.abs(delta) <= 0.6 then
                                sharedHeading[g.sl].dx, sharedHeading[g.sl].dz = px * delta, pz * delta
                            end
                        end
                    end
                end
            end
        end
    end

    -- SIDE-ROAD LANES - the lane cut nearest the junction first: it is the clean one, and its
    -- finished line is what its partner is laid beside.
    local sideOrder = {}
    for _, sl in ipairs(sideLanes) do sideOrder[#sideOrder + 1] = sl end
    table.sort(sideOrder, function(p, q)
        local a1 = sharedHeading[p] and sharedHeading[p].station or math.huge
        local b1 = sharedHeading[q] and sharedHeading[q].station or math.huge
        return a1 < b1
    end)
    -- A TWO-WAY SIDE ROAD IS ONE CHAIN OF POINTS, BUT IT IS LISTED ONCE PER DIRECTION. At 02 and 65
    -- both lists named the same points; the first was carried to the box with fresh points, and its
    -- smoothing moved the old points out along the road. The second list then pointed at those moved
    -- points, read the outermost as its clean end 24 m out, and laid a second chain to the box from
    -- there - the road split into two dead ends with a teal dot at the split. So a lane whose partner
    -- (an earlier lane sharing at least two of its two-way links) has already been carried to the box
    -- is left alone: that carried chain is the road. A partner that was not carried changes nothing.
    local partnerOf, carried = {}, {}
    do
        local seenBy = {}
        for _, sl in ipairs(sideOrder) do
            local cnt = {}
            for k = 1, #sl.nodes - 1 do
                local a, b = sl.nodes[k], sl.nodes[k + 1]
                local o = seenBy[a]
                if o ~= nil and o == seenBy[b] and live(a) and live(b) and dualOf(a, b) then cnt[o] = (cnt[o] or 0) + 1 end
            end
            for _, o in ipairs(sideOrder) do
                if (cnt[o] or 0) >= 2 then partnerOf[sl] = o break end
            end
            for _, n in ipairs(sl.nodes) do
                if seenBy[n] == nil then seenBy[n] = sl end
            end
        end
    end
    for _, sl in ipairs(sideOrder) do
      if not (partnerOf[sl] ~= nil and carried[partnerOf[sl]]) then
        -- TRIM AND CARRY FIRST, SMOOTH LAST. Smoothing a lane that still has the first swing of an old
        -- kickout on its end bakes that swing into the lane; the clean line has to be read off the
        -- lane as it was recorded, and the off-line nodes gone, before anything is smoothed.
        local lane = {}
        for _, n in ipairs(sl.nodes) do if live(n) then lane[#lane + 1] = n end end
        if #lane >= 2 then
            -- its own heading, from its clean stretch: the last node 22 m or more from the box (an old
            -- kickout can begin 16-20 m out) and one at least 15 m behind it, so one node's wobble
            -- cannot set the heading
            local near, far, ni = cleanPair(sl, lane)
            if near ~= nil and far ~= nil then
                local hx, hz = near.x - far.x, near.z - far.z
                local hl = math.sqrt(hx * hx + hz * hz)
                hx, hz = hx / hl, hz / hl
                if AutoDrive.FLYOVER_JUNCTION_TRIM_DEBUG then
                    Logging.info("[FlyoverEditor]: CARRY lane of %d: own heading %.1f deg, shared %s, clean node #%d (%.1f, %.1f) %.1f m from box, tip %.1f m",
                        #lane, math.deg(math.atan2(hx, hz)),
                        sharedHeading[sl] and string.format("%.1f deg", math.deg(math.atan2(sharedHeading[sl].hx, sharedHeading[sl].hz))) or "none",
                        ni, near.x, near.z, math.sqrt((near.x - box.centre.x) ^ 2 + (near.z - box.centre.z) ^ 2),
                        math.sqrt((lane[#lane].x - box.centre.x) ^ 2 + (lane[#lane].z - box.centre.z) ^ 2))
                end
                if sharedHeading[sl] ~= nil and AutoDrive.FLYOVER_JUNCTION_SHARED_HEADING ~= false then
                    hx, hz = sharedHeading[sl].hx, sharedHeading[sl].hz
                    local sh = sharedHeading[sl]
                    if sh.dx ~= nil and live(near) then
                        tryCall("junction ease clean node", function()
                            ADGraphManager:moveWayPoint(near.id, near.x + sh.dx, near.y, near.z + sh.dz, near.flags, false)
                            jxNoteMoved(near)
                        end)
                    end
                end
                -- A CHORD POINTS WHERE THE ROAD WAS HALFWAY ALONG IT, NOT WHERE IT IS POINTING AT THE
                -- END. On a side road that curves into its junction that is a large error - eleven
                -- metres of chord came in 19 degrees off the road's real heading at the tie node, and
                -- since this heading sets the road's claim band, the whole box rotated with it and
                -- sat up the road from where the two roads actually meet.
                --
                -- The correction is exact for an arc and needs no fit: turn the chord on by HALF the
                -- angle the road turns across it, which is read straight off the lane's own points.
                -- A straight road turns zero and is unaffected.
                do
                    local turn, pv = 0, nil
                    local started = false
                    for j = 1, ni do
                        local m = lane[j]
                        if m == far then started = true end
                        if started and pv ~= nil then
                            local a = math.atan2(m.x - pv.x, m.z - pv.z)
                            if pv.prevAng ~= nil then
                                local d = a - pv.prevAng
                                while d > math.pi do d = d - 2 * math.pi end
                                while d < -math.pi do d = d + 2 * math.pi end
                                turn = turn + d
                            end
                            m.prevAng = a
                        end
                        if started then pv = m end
                    end
                    for j = 1, ni do lane[j].prevAng = nil end
                    -- AND HERE IT IS NOT APPLIED. laneArc's chord spans ten metres of a bending
                    -- road, where the gap between chord and tangent is real and worth correcting.
                    -- This one is read over a short span at the lane's own clean end, where the two
                    -- have barely diverged - correcting it only over-rotates. Measured: it pushed
                    -- the two tracks of one side road from 1.20 m apart within their claim band to
                    -- 1.75 m, and changed nothing whatever at the junction next door. The turn is
                    -- still worked out above because it is what says whether there is anything to
                    -- correct; acting on it here is what was wrong.
                    -- ...AND NOW IT IS APPLIED AGAIN. What over-rotated was each lane correcting its
                    -- OWN heading, so the pair splayed. Both lanes now take the heading of the lane
                    -- cut nearest the junction, and on a road that keeps bending in, that chord
                    -- lags the road by a few degrees over the last 11 m - both lanes arrived 1.2 m
                    -- to one side of their box. Corrected, they arrive within 0.3 m; at junctions
                    -- that were already right it costs 0.15 m at most.
                    if AutoDrive.FLYOVER_JUNCTION_CARRY_TANGENT == false then turn = 0 end
                    local half = turn * 0.5
                    local cs, sn = math.cos(half), math.sin(half)
                    hx, hz = hx * cs - hz * sn, hx * sn + hz * cs
                end
                -- THE ROAD'S OWN CURVE, from the clean stretch. A side road that bends gently on its
                -- way in came back STRAIGHT over its last 22 m when it was carried on a heading alone,
                -- which left it pointing off its road. Curvature is read from three clean points - the
                -- clean node, the baseline node, and one as far behind that again - and the carry is
                -- an arc of that curvature, leaving the clean node on the arc's own tangent. A road
                -- that is straight reads as (nearly) zero and is carried straight, as before.
                local kCurve = 0
                -- THE ROAD'S OWN BEND, BUT ONLY WHERE THE CARRY IS LONG ENOUGH TO NEED IT. A short
                -- carry is straight to within a few centimetres whatever the road does, and bending
                -- it on a curvature read from three points made every short one worse. A long one -
                -- 20 m at a skew T, whose tie nodes sit far back - leaves a bending road altogether
                -- if it is laid straight. There the bend is read from the WHOLE clean stretch: the
                -- heading change between its first and last segments over the length between them,
                -- which one wobbling node cannot swing the way it swings a three-point circle.
                do
                    local carryLen = math.sqrt((near.x - box.centre.x) ^ 2 + (near.z - box.centre.z) ^ 2)
                    local MODE = AutoDrive.FLYOVER_JUNCTION_CARRY_CURVE
                    if MODE ~= false and carryLen >= (AutoDrive.FLYOVER_JUNCTION_CARRY_CURVE_MIN or 15) then
                        -- segments of the clean stretch, walking back from the clean node up to 45 m
                        local segs, acc = {}, 0
                        for j = ni, 2, -1 do
                            local p, q = lane[j - 1], lane[j]
                            local L = math.sqrt((q.x - p.x) ^ 2 + (q.z - p.z) ^ 2)
                            if L > 0.5 then
                                segs[#segs + 1] = { ang = math.atan2(q.x - p.x, q.z - p.z), mid = acc + L / 2, len = L }
                            end
                            acc = acc + L
                            if acc >= 45 then break end
                        end
                        if #segs >= 3 then
                            local first, last = segs[#segs], segs[1]   -- farthest back, nearest the node
                            local d = last.ang - first.ang
                            while d > math.pi do d = d - 2 * math.pi end
                            while d < -math.pi do d = d + 2 * math.pi end
                            local span = first.mid - last.mid
                            if span > 8 then
                                kCurve = math.max(-1 / 40, math.min(1 / 40, d / span))
                                -- leave the clean node on the arc's own tangent: the last segment's
                                -- heading, turned on by the half segment between its middle and the node
                                local t = last.ang + kCurve * last.len * 0.5
                                if AutoDrive.FLYOVER_JUNCTION_TRIM_DEBUG then
                                    Logging.info("[FlyoverEditor]: CURVE carry %.0f m: turn %.1f deg over %.0f m -> radius %.0f m; heading %.1f -> %.1f deg",
                                        carryLen, math.deg(d), span, kCurve ~= 0 and math.abs(1 / kCurve) or 0,
                                        math.deg(math.atan2(hx, hz)), math.deg(t))
                                end
                                hx, hz = math.sin(t), math.cos(t)
                            end
                        end
                    end
                end
                -- points along the carry, every quarter metre from the clean node
                local arc = { { x = near.x, z = near.z } }
                do
                    local px, pz, ax2, az2 = near.x, near.z, hx, hz
                    for _ = 1, 320 do
                        local dth = kCurve * 0.25
                        local cs, sn = math.cos(dth), math.sin(dth)
                        ax2, az2 = ax2 * cs - az2 * sn, ax2 * sn + az2 * cs
                        px, pz = px + ax2 * 0.25, pz + az2 * 0.25
                        arc[#arc + 1] = { x = px, z = pz }
                    end
                end
                -- A LANE CUT FAR BACK IS LAID BESIDE ITS PARTNER, NOT ON A GUESS. On a bend the two
                -- lanes of a road find very different clean nodes - one a plain tie node 11 m out,
                -- the other 30 m back, because its last 20 m already carry the old kickout's swing.
                -- Carrying that one 30 m on a heading or a fitted arc is a guess at a road whose
                -- true line is lying right beside it: the partner, already finished. So it is laid
                -- as that line moved sideways by the road's own width - parallel by construction,
                -- round whatever bend the road makes.
                do
                    local sh = sharedHeading[sl]
                    local gs = sh and sh.group or nil
                    if gs ~= nil and gs.refLine ~= nil and sh.station > (sh.nearest or 0) + 5
                        and AutoDrive.FLYOVER_JUNCTION_SHARED_HEADING ~= false then
                        local ref = gs.refLine
                        -- WHERE THIS LANE'S SWEEP BEGINS IS WHERE IT STOPS RUNNING PARALLEL TO ITS
                        -- PARTNER. Reading it off the lane's own turning fails on a road whose
                        -- curve changes - it put the start 30 m out, and a second attempt 48 m.
                        -- Two lanes of one road keep their distance whatever the road does, so the
                        -- lane is clean for as long as its distance to the partner's line holds,
                        -- and the clean node is the last point where it still does.
                        local function toRef(px, pz)
                            local best = math.huge
                            for i = 1, #ref - 1 do
                                local u, v = ref[i], ref[i + 1]
                                local dx, dz = v.x - u.x, v.z - u.z
                                local L = dx * dx + dz * dz
                                local t = (L > 0) and math.max(0, math.min(1, ((px - u.x) * dx + (pz - u.z) * dz) / L)) or 0
                                local d = math.sqrt((u.x + dx * t - px) ^ 2 + (u.z + dz * t - pz) ^ 2)
                                if d < best then best = d end
                            end
                            return best
                        end
                        local ws = {}
                        for i = 1, ni do ws[#ws + 1] = toRef(lane[i].x, lane[i].z) end
                        if #ws >= 2 then
                            local sorted = {}
                            for _, v in ipairs(ws) do sorted[#sorted + 1] = v end
                            table.sort(sorted)
                            local w0 = sorted[math.floor((#sorted + 1) / 2)]
                            local lastPar = ni
                            for i = ni + 1, #lane do
                                local dv = toRef(lane[i].x, lane[i].z) - w0
                                if AutoDrive.FLYOVER_JUNCTION_TRIM_DEBUG then
                                    Logging.info("[FlyoverEditor]: PARALLEL #%d (%.1f, %.1f): %.2f m from partner, road width %.2f -> off by %+.2f",
                                        i, lane[i].x, lane[i].z, dv + w0, w0, dv)
                                end
                                if math.abs(dv) <= 0.4 then lastPar = i else break end
                            end
                            if lastPar > ni then
                                ni, near = lastPar, lane[lastPar]
                                arc = { { x = near.x, z = near.z } }
                            end
                        end
                        -- which side of the partner this lane lies on, and how far, read where this
                        -- lane is still clean
                        local bi, bd = 1, math.huge
                        for i = 1, #ref do
                            local d = (ref[i].x - near.x) ^ 2 + (ref[i].z - near.z) ^ 2
                            if d < bd then bd, bi = d, i end
                        end
                        local i2 = math.min(#ref, bi + 1)
                        local i1 = math.max(1, i2 - 1)
                        local tx, tz = ref[i2].x - ref[i1].x, ref[i2].z - ref[i1].z
                        local tl = math.sqrt(tx * tx + tz * tz)
                        if tl > 0.01 then
                            tx, tz = tx / tl, tz / tl
                            local lat = (near.x - ref[bi].x) * -tz + (near.z - ref[bi].z) * tx
                            local off = {}
                            for i = bi, #ref do
                                local j2 = math.min(#ref, i + 1)
                                local j1 = math.max(1, j2 - 1)
                                local ux, uz = ref[j2].x - ref[j1].x, ref[j2].z - ref[j1].z
                                local ul = math.sqrt(ux * ux + uz * uz)
                                if ul > 0.01 then
                                    ux, uz = ux / ul, uz / ul
                                    off[#off + 1] = { x = ref[i].x + -uz * lat, z = ref[i].z + ux * lat }
                                end
                            end
                            if #off >= 2 then
                                -- resampled every quarter metre, and run on straight past the end
                                local fine = { { x = near.x, z = near.z } }
                                for i = 1, #off do
                                    local p = fine[#fine]
                                    local dx, dz = off[i].x - p.x, off[i].z - p.z
                                    local L = math.sqrt(dx * dx + dz * dz)
                                    local n = math.floor(L / 0.25)
                                    for k = 1, n do fine[#fine + 1] = { x = p.x + dx * k / n, z = p.z + dz * k / n } end
                                end
                                local p, q = fine[#fine - 1] or fine[#fine], fine[#fine]
                                local ex, ez = q.x - p.x, q.z - p.z
                                local el = math.sqrt(ex * ex + ez * ez)
                                if el > 0.001 then
                                    ex, ez = ex / el, ez / el
                                    for k = 1, 120 do fine[#fine + 1] = { x = q.x + ex * 0.25 * k, z = q.z + ez * 0.25 * k } end
                                end
                                arc = fine
                            end
                        end
                    end
                end
                -- NOTHING PAST THE CLEAN NODE SURVIVES. Keeping the nodes that still sat "on the line"
                -- (to 0.4 m) kept the first degrees of the old kickout with them: each was within
                -- tolerance, together they leaned the lane's end the way the turn used to go. The
                -- last 16 m is laid fresh along the clean heading instead.
                local lastOn = ni
                -- THE LANE'S LIST DOES NOT ALWAYS END AT THE JUNCTION. With through paths kept, the
                -- walk that builds it carries on past the connector and away down the main road -
                -- one lane came back 32 nodes long with its "tip" 69 m beyond the box - and "nothing
                -- past the clean node survives" then took the connector, which is right, and went on
                -- to take the parent road the user had asked to keep: 13 points out to 34 m, in game,
                -- at a junction 12 m across. What lies past the clean node is this lane's only as far
                -- as its connector runs, and a connector ends where it JOINS something: at the first
                -- fork, or the first point of a protected through route. From there on it is another
                -- road, and is dropped from this lane's list altogether so nothing below touches it.
                do
                    local prot = jp.protectedOf or {}
                    local stop = nil
                    for i = ni + 1, #lane do
                        local n = lane[i]
                        local seen, d = {}, 0
                        for _, lst in ipairs({ n.out or {}, n.incoming or {} }) do
                            for _, id in pairs(lst) do
                                if not seen[id] then seen[id] = true d = d + 1 end
                            end
                        end
                        if d >= 3 or prot[n] then stop = i break end
                    end
                    if stop ~= nil then
                        for i = #lane, stop, -1 do lane[i] = nil end
                    end
                    -- AND A LANE ENDS AT THE JUNCTION. By the time this runs the clear has usually cut
                    -- the connector's far link, so there is no fork left to stop at, and the list
                    -- carries straight on down the road the connector used to join: in from the
                    -- west, round the connector, and away to the south for 40 m, every point of it
                    -- plain two-link road. So the list is cut at its own closest approach to the
                    -- middle of the box. Up to there it is coming IN, and is this lane's; past there
                    -- it is going OUT, and is some other road's. No distance is involved - only
                    -- which way the lane is heading.
                    local kBest, dBest = nil, math.huge
                    for i = ni, #lane do
                        local d = (lane[i].x - box.centre.x) ^ 2 + (lane[i].z - box.centre.z) ^ 2
                        if d < dBest then dBest, kBest = d, i end
                    end
                    if kBest ~= nil and kBest < #lane then
                        for i = #lane, kBest + 1, -1 do lane[i] = nil end
                    end
                end
                -- PAST A TIE NODE THE LANE IS STILL THE LANE. A tie node is a fork ON the lane: the
                -- connector peels off there and the lane itself runs on to the junction. Those
                -- onward points are the only record of what the road does over its last stretch,
                -- and at a skew T - tie nodes 22 m out - throwing them away replaced 20 m of road
                -- with a straight guess that sat a metre off it. They are kept, and the carry runs
                -- from the lane's own end. (With NO tie node there is no telling lane from
                -- connector, and the old rule stands.)
                -- ...PROVIDED IT RUNS STRAIGHT ON. Where the side road ENDS at the junction, what lies
                -- past its tie node is not lane at all but one of its connectors, swinging away for
                -- its turn - and keeping that left a stub of old connector hanging beside the fresh
                -- lane end. A lane that continues holds its heading; a connector does not. The turn
                -- from the clean node to the tip is added up, and only a run that stays within a few
                -- degrees of straight is kept.
                local straightOn = false
                if sl.cutNode ~= nil and #lane > ni + 1 then
                    local cum, prevAng, worst = 0, nil, 0
                    for i = ni + 1, #lane do
                        local a = math.atan2(lane[i].x - lane[i - 1].x, lane[i].z - lane[i - 1].z)
                        if prevAng ~= nil then
                            local d = a - prevAng
                            while d > math.pi do d = d - 2 * math.pi end
                            while d < -math.pi do d = d + 2 * math.pi end
                            cum = cum + d
                            if math.abs(cum) > worst then worst = math.abs(cum) end
                        end
                        prevAng = a
                    end
                    -- and against the clean heading itself, so a lane that leaves at an angle from
                    -- the very first step does not pass for having no turn between its own steps
                    local a0 = math.atan2(lane[ni + 1].x - lane[ni].x, lane[ni + 1].z - lane[ni].z)
                    local d0 = a0 - math.atan2(hx, hz)
                    while d0 > math.pi do d0 = d0 - 2 * math.pi end
                    while d0 < -math.pi do d0 = d0 + 2 * math.pi end
                    straightOn = (worst <= math.rad(10)) and (math.abs(d0) <= math.rad(10))
                end
                if AutoDrive.FLYOVER_JUNCTION_KEEP_PAST_TIE ~= false and straightOn then
                    lastOn = #lane
                    near = lane[#lane]
                    arc = { { x = near.x, z = near.z } }
                    local px2, pz2 = near.x, near.z
                    for _ = 1, 320 do
                        px2, pz2 = px2 + hx * 0.25, pz2 + hz * 0.25
                        arc[#arc + 1] = { x = px2, z = pz2 }
                    end
                end
                if AutoDrive.FLYOVER_JUNCTION_TRIM_DEBUG and #lane - ni > 4 then
                    for i = 1, #lane do
                        local n = lane[i]
                        local seen, d = {}, 0
                        for _, lst in ipairs({ n.out or {}, n.incoming or {} }) do
                            for _, id in pairs(lst) do if not seen[id] then seen[id] = true d = d + 1 end end
                        end
                        Logging.info("[FlyoverEditor]: LANE #%02d id=%d (%.1f, %.1f) %.0f m from box, deg %d%s%s",
                            i, n.id, n.x, n.z, math.sqrt((n.x - box.centre.x) ^ 2 + (n.z - box.centre.z) ^ 2), d,
                            (jp.protectedOf or {})[n] and " PROTECTED" or "", i == ni and "  <-- clean node" or "")
                    end
                end
                if AutoDrive.FLYOVER_JUNCTION_TRIM_DEBUG then
                    local tipD = math.sqrt((lane[#lane].x - box.centre.x) ^ 2 + (lane[#lane].z - box.centre.z) ^ 2)
                    local nearD = math.sqrt((near.x - box.centre.x) ^ 2 + (near.z - box.centre.z) ^ 2)
                    Logging.info("[FlyoverEditor]: SIDETRIM lane of %d: %s, clean node #%d at %.0f m, tip at %.0f m, keeping to #%d -> removing %d",
                        #lane, sl.cutNode ~= nil and "TIE NODE path" or "fallback path",
                        ni, nearD, tipD, lastOn, #lane - lastOn)
                end
                -- A POINT THE TRIM MAY NOT DELETE IS WHERE THE LANE ENDS. The trim below asks to
                -- remove every point past the clean node, but one lying outside what this clear may
                -- delete is refused and stays. At 58 the trim went on as if it had gone and laid the
                -- fresh lane from the clean node further back, beside the point that stayed: the lane
                -- split there into two dead ends. So the refused point nearest the junction is kept
                -- as the lane's end, only what lies beyond it is trimmed, and the carry runs on
                -- straight from it along the lane's heading.
                do
                    local hold = nil
                    for i = #lane, lastOn + 1, -1 do
                        if live(lane[i]) and not jxMayDelete(lane[i].x, lane[i].z) then hold = i break end
                    end
                    if hold ~= nil then
                        lastOn, near = hold, lane[hold]
                        arc = { { x = near.x, z = near.z } }
                        local px2, pz2 = near.x, near.z
                        for _ = 1, 320 do
                            px2, pz2 = px2 + hx * 0.25, pz2 + hz * 0.25
                            arc[#arc + 1] = { x = px2, z = pz2 }
                        end
                    end
                end
                for i = #lane, lastOn + 1, -1 do
                    local n = lane[i]
                    if live(n) then
                        jxRemove(n.id, "junction side trim")
                        removed = removed + 1
                    end
                    lane[i] = nil
                end
                -- carry on along the heading to the main road's offset line
                local tip = lane[#lane]
                local hit, s0 = nil, 0
                for k = 2, #arc do
                    if inOther(arc[k].x, arc[k].z, hx, hz) then hit = (k - 2) * 0.25 break end
                end
                if hit ~= nil and hit > 0.5 then
                    carried[sl] = true
                    local back = lane[#lane - 1]
                    -- TWO-WAY OR ONE-WAY IS READ OFF THE ROAD AS IT IS NOW: from the point the tip is
                    -- joined to on the lane's side, not from the point before it in this lane's list.
                    -- The list was read before the clear began, and a two-way road is one chain listed
                    -- once for each way, so its other listing may have been re-laid since. At 24 (in
                    -- game, cleared after 16 had been cleared and undone) the west road's first listing
                    -- was respaced 15 to 28 m out, two new points went in between this list's last two,
                    -- those two were no longer joined at all, and the two-way road was read as one-way:
                    -- its new end came back one way only, the wrong way for traffic leaving.
                    local onLane = nil
                    if back ~= nil then
                        if live(back) and (table.contains(back.out or {}, tip.id) or table.contains(tip.out or {}, back.id)) then
                            onLane = back
                        else
                            -- the tip's own neighbour nearest where `back` stood: the lane as it runs now
                            local bd = math.huge
                            for _, lst in ipairs({ tip.out or {}, tip.incoming or {} }) do
                                for _, id in ipairs(lst) do
                                    local t = ADGraphManager:getWayPointById(id)
                                    if t ~= nil and t ~= tip then
                                        local d = (t.x - back.x) ^ 2 + (t.z - back.z) ^ 2
                                        if d < bd then bd, onLane = d, t end
                                    end
                                end
                            end
                        end
                    end
                    local dual = false
                    if onLane ~= nil then dual = dualOf(onLane, tip) end
                    local n = math.max(1, math.floor(hit / STEP + 0.5))
                    local prev = tip
                    for k = 1, n do
                        local q = arc[math.min(#arc, math.floor((hit * k / n) / 0.25 + 0.5) + 1)]
                        local made1 = ADFlyoverRecordWayPoint(q.x, tip.y or 0, q.z,
                            false, false, false, 0, tip.flags or AutoDrive.FLAG_NONE, false, ADFlyoverEditor.fieldOf(tip))
                        jxNoteAdded(made1)
                        if made1 == nil then break end
                        if sl.useOut then junctionConnect(prev, made1, dual) else junctionConnect(made1, prev, dual) end
                        prev = made1
                        lane[#lane + 1] = made1
                        made = made + 1
                    end
                end
                ends[#ends + 1] = lane[#lane]
                do
                    local sh = sharedHeading[sl]
                    if sh ~= nil and sh.group ~= nil and sh.group.refLine == nil then
                        local ref = {}
                        for _, n2 in ipairs(lane) do ref[#ref + 1] = { x = n2.x, z = n2.z } end
                        sh.group.refLine = ref
                    end
                end
            end
            lane = smoothLane(lane, sl.useOut)
        end
        for _, n in ipairs(lane) do keep[n] = true end
      end
    end

    -- WHAT IS LEFT INSIDE THE BOX is junction, not road: everything there that is not a kept path.
    local theirs = jp.foreignWiring or {}
    local doomed = {}
    for _, n in pairs(ADGraphManager:getWayPoints()) do
        if n ~= nil and n.id ~= nil and inBox(n.x, n.z) and not theirs[n] and not (leave and keep[n])
            and not spareSet[n] and ownHalf(n.x, n.z) then
            doomed[#doomed + 1] = n.id
        end
    end
    table.sort(doomed, function(a, b) return a > b end)
    for _, id in ipairs(doomed) do
        jxRemove(id, "junction box sweep")
        removed = removed + 1
    end

    -- SPURS - after the box is emptied, because a connector only becomes a dead end once its
    -- middle is gone. What is left of a connector hangs off a kept lane near the junction and goes nowhere:
    -- step off each kept node onto anything that is not kept, follow it while it stays a plain
    -- chain, and if it dead-ends within 30 m it was wiring.
    do
        local function nbs(w)
            local seen, list = {}, {}
            for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
                for _, id in pairs(lst) do
                    if not seen[id] then
                        seen[id] = true
                        local o = ADGraphManager:getWayPointById(id)
                        if o ~= nil then list[#list + 1] = o end
                    end
                end
            end
            return list
        end
        local spur = {}
        for n in pairs(keep) do
            if live(n) and (n.x - box.centre.x) ^ 2 + (n.z - box.centre.z) ^ 2 <= 35 * 35 then
                for _, first in ipairs(nbs(n)) do
                    if not keep[first] and not (jp.foreignWiring or {})[first] then
                        local chain, prev, node, run, dead = { first }, n, first, 0, false
                        for _ = 1, 40 do
                            local onward = {}
                            for _, o in ipairs(nbs(node)) do if o ~= prev then onward[#onward + 1] = o end end
                            if #onward == 0 then dead = true break end
                            if #onward > 1 or keep[onward[1]] then break end
                            run = run + math.sqrt((onward[1].x - node.x) ^ 2 + (onward[1].z - node.z) ^ 2)
                            if run > 60 then break end
                            prev, node = node, onward[1]
                            chain[#chain + 1] = node
                        end
                        if dead then for _, c in ipairs(chain) do spur[c] = true end end
                    end
                end
            end
        end
        local ids = {}
        for c in pairs(spur) do if live(c) then ids[#ids + 1] = c.id end end
        table.sort(ids, function(a, b) return a > b end)
        for _, id in ipairs(ids) do
            jxRemove(id, "junction spur")
            removed = removed + 1
        end
    end

    -- THE FINAL RESPACE, PER LEG, AFTER THE TRIM - and the density check with it. Each leg now runs
    -- from its outer end to the point on the box edge, so this is what decides the spacing leading
    -- into the box: checked here, a leg cannot finish with a short segment in front of its end, and
    -- it comes back with the points-per-metre that leg of the road had before the clear (within
    -- 10 %; the spacing is scaled and the leg rebuilt, up to six times, until it does).
    for _, h in ipairs(afterCut) do
        if #h.seq >= 3 then
            local first, last = h.seq[1], h.seq[#h.seq]
            local old = {}
            for i, n in ipairs(h.seq) do old[i] = { x = n.x, z = n.z } end
            local seq = h.seq
            for _ = 1, 6 do
                jp._laneSeqs = { { seq = seq, useOut = h.useOut, len = 1e9, step = h.step } }
                tryCall("junction smooth leg", function() self:junctionRespaceApproaches(jp) end)
                -- the leg as it now is
                local now, nd, cm = { first }, first, nil
                for _ = 1, 600 do
                    if nd == last then break end
                    local list = h.useOut and (nd.out or {}) or (nd.incoming or {})
                    local best, bd = nil, math.huge
                    for _, id in pairs(list) do
                        local nx = ADGraphManager:getWayPointById(id)
                        if nx ~= nil and nx ~= cm then
                            local d = distLine(old, nx.x, nx.z)
                            if d < bd then bd, best = d, nx end
                        end
                    end
                    if best == nil or bd > 3 then break end
                    cm, nd = nd, best
                    now[#now + 1] = nd
                end
                if nd ~= last or #now < 3 then break end
                seq = now
                for _, n in ipairs(now) do keep[n] = true end
                local dNow = density(now)
                if h.dens == nil or dNow == nil then break end
                local ratio = dNow / h.dens
                if math.abs(ratio - 1) <= 0.10 then break end
                -- NEVER SPARSER THAN THE ROAD EVER WAS. The density is the leg's points per metre,
                -- and part of a leg cannot be rebuilt (its far end, a fork, a point past this
                -- junction's reach), so on a short leg the count barely answers the spacing and the
                -- spacing kept being scaled up. At 39 with through roads off, the north-west road's
                -- leg out towards 39se, spaced 4-7 m before, went to 5, 7.3, 8.5, 10 and 11.6 m and came
                -- back with 8 and 11 m gaps through 39se's middle. Capped at the leg's own longest
                -- gap before the clear; once there, rebuilding again changes nothing, so it stops.
                local stepWas = h.step or STEP
                local stepNew = math.max(3, math.min(25, stepWas * ratio ^ 1.4))
                if h.maxGap ~= nil and stepNew > stepWas then
                    stepNew = math.min(stepNew, math.max(stepWas, h.maxGap))
                end
                if stepNew == stepWas then break end
                h.step = stepNew
            end
        end
    end
    -- LOOSE ENDS. Anything near the junction that is no longer joined to a kept lane - a single
    -- point, or a scrap of a few - is what the sweeps above left of some connector. A small
    -- component with no kept node in it goes.
    do
        local seenC, loose = {}, {}
        for _, n in pairs(ADGraphManager:getWayPoints()) do
            if n ~= nil and n.id ~= nil and not seenC[n] and not keep[n] and not theirs[n]
                and (n.x - box.centre.x) ^ 2 + (n.z - box.centre.z) ^ 2 <= 40 * 40 then
                local comp, stack, small = {}, { n }, true
                seenC[n] = true
                while #stack > 0 do
                    local w = table.remove(stack)
                    comp[#comp + 1] = w
                    if keep[w] or #comp > 8 then small = false break end
                    for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
                        for _, id in pairs(lst) do
                            local o = ADGraphManager:getWayPointById(id)
                            if o ~= nil and keep[o] then small = false end
                            if o ~= nil and not seenC[o] then seenC[o] = true stack[#stack + 1] = o end
                        end
                    end
                    if not small then break end
                end
                -- ...AND ONLY IF THIS CLEAR IS WHY IT IS LOOSE. Two ways a scrap can be none of our
                -- business: it already held a loose end when we began - the finished lane end of the
                -- junction next door - or this clear cut nothing in it at all, and it simply came
                -- adrift when something else went. Both were taken; at a close pair the second click
                -- ate three points of the first junction's road, 31 m away. A scrap is this clear's
                -- leftover only if this clear severed one of its points.
                if small and jxState.jxWasLoose ~= nil then
                    for _, w in ipairs(comp) do
                        if jxState.jxWasLoose[w] then small = false break end
                    end
                end
                if small then
                    local ours = false
                    for _, w in ipairs(comp) do
                        if jxWasCutByUs(w) then ours = true break end
                    end
                    if not ours then small = false end
                end
                if small then for _, w in ipairs(comp) do loose[#loose + 1] = w.id end end
            end
        end
        table.sort(loose, function(a, b) return a > b end)
        for _, id in ipairs(loose) do
            jxRemove(id, "junction loose end")
            removed = removed + 1
        end
    end
    jp._laneNodes = keep
    jp._laneSeqs = {}
    jp._boxCentre = box.centre
    -- The stretches of road kept for another part's turn, as they lie now, for the check
    -- (jxCheckTwin): a drive over them onto that turn is the turn being driven, not a join missed.
    if jp._twin ~= nil then
        local spans = {}
        for n in jxByPlace(spareSet) do
            if live(n) then spans[#spans + 1] = { x = n.x, z = n.z } end
        end
        jp._twin.spans = spans
    end
    return #ends, made, removed, cutN
end

--- Unwire one point from itself. True when there was something to undo. The single implementation:
--- the integrity sweep calls it for the junction it is working on, and the network-wide pass calls
--- it for everything - written twice, it would have been tuned once.
local function jxUnwireSelf(w, apply)
    if w == nil or w.id == nil then return false, nil end
    local selfIn = w.incoming ~= nil and table.contains(w.incoming, w.id)
    local selfOut = w.out ~= nil and table.contains(w.out, w.id)
    if not selfIn and not selfOut then return false, nil end
    if apply ~= false then
        if selfIn then jxNote("in-", w, w) end
        if selfOut then jxNote("out-", w, w) end
        table.removeValue(w.incoming, w.id)
        table.removeValue(w.out, w.id)
    end
    return true, (selfIn and selfOut) and "both ways" or (selfIn and "incoming" or "outgoing")
end

--- UNWIRE EVERY POINT THAT IS WIRED TO ITSELF, ACROSS THE WHOLE NETWORK.
---
--- The integrity sweep only ever looks at the junction being cleared, so the self-wired points
--- scattered elsewhere are never reached by it. This is the one-shot pass for those.
---
--- Deliberately the ONLY thing it repairs. Coincident points and shared-node crossings are left
--- exactly where they are: at a fifth of a metre apart two points may simply be a tight bend, and
--- what looks like debris is mostly the network doing its job. A self-link is different in kind -
--- no road leaves a point and arrives back at that same point without going anywhere, so there is
--- no case in which it means something, and removing it cannot change a route. Nothing can be
--- driven differently afterwards; the only difference is that AutoDrive stops counting a road that
--- was never there.
---
--- `apply` false (the default) changes nothing and only reports.
function ADFlyoverEditor:repairSelfLinks(apply)
    local found, fixed = {}, 0
    for _, w in pairs(ADGraphManager:getWayPoints()) do
        if w ~= nil and w.id ~= nil then
            local hit, how = jxUnwireSelf(w, apply == true)
            if hit then
                found[#found + 1] = string.format("%.1f, %.1f (%s)", w.x, w.z, how)
                if apply then fixed = fixed + 1 end
            end
        end
    end
    for _, where in ipairs(found) do
        Logging.info("[FlyoverEditor]: self-wired point at %s", where)
    end
    if apply and fixed > 0 then
        ADGraphManager:markChanges()
    end
    return #found, fixed
end

--- NETWORK INTEGRITY SWEEP. Three faults a rebuild can leave behind, none of which show on screen
--- until something drives into one:
---
---   DANGLING  - a short chain wired at one end only. The tidy lays a lane end, a later pass takes
---               the node it was anchored to, and what is left starts from nothing. Measured across
---               the map, the clear leaves one at four sites in eight. Repaired by joining the loose
---               end back to the nearest point of road that leads the right way; removed when there
---               is nothing sensible to join it to.
---   DOUBLES   - two points in the same place. Harmless to look at, but a route through one of them
---               misses whatever hangs off the other, so the links are folded onto one point and the
---               spare is taken out.
---   REVERSALS - a point whose road arrives one way and leaves back along it. Always a fault, but
---               never one worth guessing a fix for, so these are REPORTED and left alone.
---
--- Confined to `reach` metres of (cx, cz). `dry` reports and changes nothing. Returns the counts and
--- a list of descriptions, so the same pass can back a cleanup tool as well as the end of a clear.
function ADFlyoverEditor:networkIntegritySweep(cx, cz, reach, dry)
    local rep = { doubles = 0, repaired = 0, removed = 0, reversals = 0, unjoined = 0, selfLinks = 0, notes = {} }
    if cx == nil or cz == nil then return rep end
    reach = reach or 45
    local r2 = reach * reach
    local function note(fmt, ...)
        if #rep.notes < 40 then rep.notes[#rep.notes + 1] = string.format(fmt, ...) end
    end
    local function near(w)
        return w ~= nil and w.id ~= nil and (w.x - cx) ^ 2 + (w.z - cz) ^ 2 <= r2
    end
    local function byId(id) return ADGraphManager:getWayPointById(id) end
    local function degree(w)
        local s, n = {}, 0
        for _, i in ipairs(w.out or {}) do s[i] = true end
        for _, i in ipairs(w.incoming or {}) do s[i] = true end
        for _ in pairs(s) do n = n + 1 end
        return n
    end
    -- Removals renumber every id above the one taken, so the doomed are held as OBJECTS and taken
    -- highest id first, which leaves the ids below them - and so the rest of the list - still valid.
    local doomed, doomedSet = {}, {}
    local function kill(w)
        if w ~= nil and not doomedSet[w] then
            doomedSet[w] = true
            doomed[#doomed + 1] = w
        end
    end

    -- ONLY THIS JUNCTION. A radius takes in whatever happens to be within it, and a junction that
    -- has ALREADY been cleared looks, from here, exactly like damage: its branches were cut from the
    -- road on purpose and now lead nowhere. Cleaning one of a close pair over a flat radius tied the
    -- other one's branches straight back to the road - clear the right hand junction, then the left,
    -- and the right one is joined up again. So the same bound the deletions use applies here: what
    -- belongs to the junction in hand, and nothing beyond its arms.
    local site = {}
    for _, w in pairs(ADGraphManager:getWayPoints()) do
        if near(w) and jxInSite(w.x, w.z) then site[#site + 1] = w end
    end

    -- SELF-REFERENCES. A point listing itself among its own incoming or outgoing links. There is no
    -- reading of the graph in which that means anything - no road leaves a point and arrives back at
    -- the same point without going anywhere - so it is simply removed, with no judgement to make and
    -- nothing to weigh up.
    --
    -- It is not harmless. AutoDrive counts stored incoming to decide what is a merge, so a point
    -- with one real road in and itself makes two, and 3.0.1.2 paints it as a right-of-way centre:
    -- a junction drawn on the map where no two roads meet. One at (-927.39, -39.60) had the user
    -- hunting a connection that was never there; 19 points across that network do it, in the saved
    -- network BEFORE a clear as much as after, so this is old damage rather than anything a clear
    -- does. Counted with the doubles, since it is the same kind of fault: the graph disagreeing with
    -- itself about what is wired to what.
    for _, w in ipairs(site) do
        local hit = jxUnwireSelf(w, not dry)
        if hit then
            rep.selfLinks = (rep.selfLinks or 0) + 1
            note("a point at (%.1f, %.1f) is wired to itself - nothing drives that, and AutoDrive counts it as a road arriving", w.x, w.z)
        end
    end

    -- DOUBLES. Everything wired to the spare is re-wired to the keeper first, so folding the two
    -- together cannot lose a link.
    local SAME = 0.3
    for i = 1, #site do
        local a = site[i]
        if not doomedSet[a] then
            for j = i + 1, #site do
                local b = site[j]
                -- Never a point of a kept through road with a point of another way that it is not
                -- wired to: see jxKeptRoad. At 30 a turn's point 0.13 m from a kept lane's point
                -- was folded into it, and the turn's link on into the other road was kept with it.
                -- A true double of a lane point is wired to it or to its neighbours, and still folds.
                local twoRoads = false
                if jxState.jxKeptRoad ~= nil and (jxState.jxKeptRoad[a] ~= nil or jxState.jxKeptRoad[b] ~= nil)
                    and jxState.jxKeptRoad[a] ~= jxState.jxKeptRoad[b] then
                    local nbA = {}
                    for _, id in ipairs(a.out or {}) do nbA[id] = true end
                    for _, id in ipairs(a.incoming or {}) do nbA[id] = true end
                    twoRoads = not nbA[b.id]
                    for _, id in ipairs(b.out or {}) do if nbA[id] or id == a.id then twoRoads = false end end
                    for _, id in ipairs(b.incoming or {}) do if nbA[id] or id == a.id then twoRoads = false end end
                end
                -- TWO LANES CROSSING ARE NOT A DOUBLE, kept road or not. Where two lanes cross, a point
                -- of each can lie a few cm apart: at 39 two turns crossed 0.23 m apart, and the
                -- respacing slid a lane's point to 0.16 m from a point of 39se's turn. Folded, they make
                -- one point that both lanes run through - two movements that were never there (a
                -- lane into the other road), and a point that reads as a fork and moved 39's middle
                -- 3.4 m. A true double runs the same way as its twin, or is a lane end lying on a
                -- lane, or is wired to it or to a neighbour of it; two points that each carry a lane
                -- straight through, unrelated, on lines 30 degrees or more apart, are a crossing.
                if not twoRoads and not doomedSet[b] and (a.x - b.x) ^ 2 + (a.z - b.z) ^ 2 <= SAME * SAME
                    and jxLanesCross(a, b) then
                    twoRoads = true
                end
                if not doomedSet[b] and not twoRoads and (a.x - b.x) ^ 2 + (a.z - b.z) ^ 2 <= SAME * SAME then
                    rep.doubles = rep.doubles + 1
                    note("two points in the same place at (%.1f, %.1f)", b.x, b.z)
                    if not dry then
                        local outs, ins = {}, {}
                        for _, id in ipairs(b.out or {}) do outs[#outs + 1] = id end
                        for _, id in ipairs(b.incoming or {}) do ins[#ins + 1] = id end
                        -- TWO WAYS ABOUT TO MEET ARE NOT A DOUBLE. Where two turns run into the
                        -- same lane their last points can lie under 0.3 m apart; folding them gave
                        -- the keeper a link straight to the meeting point as well as its own one
                        -- through the next point - a lane splitting and joining itself again 2 m
                        -- on, and a teal dot where it rejoined (02). A link the keeper already
                        -- makes in two steps adds no route, so it is not added - unless the point
                        -- in the middle of those two steps is itself folded away in this sweep.
                        local function inTwo(p, q, useOut)
                            for _, mid in ipairs(useOut and (p.out or {}) or (p.incoming or {})) do
                                local m = byId(mid)
                                if m ~= nil and m ~= q and m ~= b and not doomedSet[m] then
                                    for _, tid in ipairs(useOut and (m.out or {}) or (m.incoming or {})) do
                                        if tid == q.id then return true end
                                    end
                                end
                            end
                            return false
                        end
                        for _, id in ipairs(outs) do
                            local t = byId(id)
                            if t ~= nil and t ~= a and t ~= b and not inTwo(a, t, true) then junctionConnect(a, t, false) end
                        end
                        for _, id in ipairs(ins) do
                            local f = byId(id)
                            if f ~= nil and f ~= a and f ~= b and not inTwo(a, f, false) then junctionConnect(f, a, false) end
                        end
                        junctionDisconnect(a, b)
                        kill(b)
                    end
                end
            end
        end
    end

    -- DANGLING. Walked from the loose end along the single way it has, for as long as the points it
    -- passes are plain road (two links or fewer). A chain that reaches a fork really is attached at
    -- its far end, which is what makes it a dangling tail rather than an ordinary dead-end lane; one
    -- that simply peters out is left to the stranded sweep that follows.
    local MAXLEN, MAXN, JOIN = 25, 14, 6
    for _, w in ipairs(site) do
        if not doomedSet[w] and degree(w) > 0 then
            local nout, nin = #(w.out or {}), #(w.incoming or {})
            local headless = (nin == 0 and nout > 0)
            local tailless = (nout == 0 and nin > 0)
            if headless or tailless then
                local chain, seen, len, cur = { w }, { [w] = true }, 0, w
                -- Attached at the far end unless it PETERS OUT. Requiring the walk to reach a fork
                -- was wrong: a lane end runs on into ordinary road, never meeting one, so every real
                -- case was walked past and called clean. Running out of chain to follow is the only
                -- thing that means the whole thing is free-floating - and that is the stranded
                -- sweep's job, not this one.
                local anchored = true
                while #chain < MAXN and len < MAXLEN do
                    local list = headless and (cur.out or {}) or (cur.incoming or {})
                    if #list ~= 1 then
                        anchored = (#list > 1)
                        break
                    end
                    local nxt = byId(list[1])
                    if nxt == nil or seen[nxt] then
                        anchored = (nxt ~= nil)
                        break
                    end
                    if degree(nxt) >= 3 then break end
                    len = len + math.sqrt((nxt.x - cur.x) ^ 2 + (nxt.z - cur.z) ^ 2)
                    chain[#chain + 1] = nxt
                    seen[nxt] = true
                    cur = nxt
                end
                if anchored then
                    -- The way the chain is already pointing, so it is not tied to something behind it.
                    local hx, hz = 0, 0
                    if #chain >= 2 then
                        hx, hz = chain[1].x - chain[2].x, chain[1].z - chain[2].z
                        local m = math.sqrt(hx * hx + hz * hz)
                        if m > 0 then hx, hz = hx / m, hz / m end
                    end
                    local best, bestD = nil, JOIN * JOIN
                    for _, t in ipairs(site) do
                        if not seen[t] and not doomedSet[t] and degree(t) > 0 then
                            local dx, dz = t.x - w.x, t.z - w.z
                            local d = dx * dx + dz * dz
                            if d > 0.01 and d < bestD then
                                local m = math.sqrt(d)
                                if (hx == 0 and hz == 0)
                                    or ((dx / m) * hx + (dz / m) * hz) >= 0.2 then
                                    bestD, best = d, t
                                end
                            end
                        end
                    end
                    -- NOTHING IS TIED BACK. A chain leading nowhere is not reliably damage: at a
                    -- junction that has already been cleared it is the work - the branches were cut
                    -- from the road on purpose - and there is no way to tell the two apart from the
                    -- shape of the graph, because a cleared junction has no forks left to recognise
                    -- it by. Joining them up put a cleared neighbour back together every time one of
                    -- a close pair was done after the other, six different ways as each route into
                    -- it was closed off. Reported and left alone.
                    -- WHOSE LOOSE END IS THIS? Three cases, and only one of them is damage:
                    --   already loose before this clear began - somebody else's, very likely a
                    --     junction cleared earlier, whose branches were cut from the road on purpose;
                    --   cut by this clear on purpose - that IS the work, and rejoining it undoes it;
                    --   loose because one of our own passes dropped a link - damage, and ours to fix.
                    -- The clear knows all three exactly. Distance never could: a cleared junction
                    -- keeps no forks to be recognised by, and its branches sit well inside any radius
                    -- wide enough to be worth having. Three goes at a radius, three failures.
                    local wasLoose = (jxState.jxWasLoose ~= nil) and jxState.jxWasLoose[w] or false
                    local cutOnPurpose = (jxState.jxCut ~= nil) and jxState.jxCut[w] or false
                    -- A POINT THIS CLEAR LAID ITSELF is a lane end on purpose - the tidy ran the lane
                    -- out to the box edge and stopped it there. It was in neither set, being new, so
                    -- it read as accidental damage and was joined to the nearest road: a side lane
                    -- wired into the through lane inside the box, a connector left by the very pass
                    -- meant to catch them.
                    local laidByUs = (jxState.jxExisted ~= nil) and not jxState.jxExisted[w] or false
                    if laidByUs then cutOnPurpose = true end
                    if wasLoose or cutOnPurpose then
                        rep.unjoined = (rep.unjoined or 0) + 1
                        note("a chain of %d leads nowhere at (%.1f, %.1f) - %s, left alone",
                            #chain, w.x, w.z,
                            wasLoose and "it was already loose before this clear" or "this clear cut it on purpose")
                    elseif best ~= nil then
                        rep.repaired = rep.repaired + 1
                        note("a chain of %d led nowhere at (%.1f, %.1f) - tied back to the road %.1f m away",
                            #chain, w.x, w.z, math.sqrt(bestD))
                        if not dry then
                            if headless then junctionConnect(best, w, false)
                            else junctionConnect(w, best, false) end
                        end
                    else
                        -- NOTHING IS REMOVED HERE. A one-way dead-end lane is indistinguishable from
                        -- a dangling tail by shape alone: both are wired at one end, both walk back
                        -- along their own road without petering out. Taking away what could not be
                        -- tied back nearly doubled the deletions across the map - 399 to 698 - and
                        -- trebled the sites reaching past 60 m, because it was pulling up real
                        -- roads. Repairing a tail is safe; deleting one is not, so an end with
                        -- nothing to join is reported and left exactly where it is.
                        rep.unjoined = (rep.unjoined or 0) + 1
                        note("a chain of %d ends at (%.1f, %.1f) with nothing leading into it, and nothing close enough to tie it to - left alone",
                            #chain, w.x, w.z)
                    end
                end
            end
        end
    end

    -- REVERSALS. Reported only.
    for _, w in ipairs(site) do
        if not doomedSet[w] and #(w.out or {}) == 1 and #(w.incoming or {}) == 1 then
            local f, t = byId(w.incoming[1]), byId(w.out[1])
            if f ~= nil and t ~= nil and f ~= t then
                local ax, az = w.x - f.x, w.z - f.z
                local bx, bz = t.x - w.x, t.z - w.z
                local la, lb = math.sqrt(ax * ax + az * az), math.sqrt(bx * bx + bz * bz)
                if la > 0.05 and lb > 0.05 then
                    local dot = (ax / la) * (bx / lb) + (az / la) * (bz / lb)
                    if dot < -0.866 then
                        rep.reversals = rep.reversals + 1
                        note("the road doubles back on itself at (%.1f, %.1f)", w.x, w.z)
                    end
                end
            end
        end
    end

    if not dry and #doomed > 0 then
        table.sort(doomed, function(a, b) return (a.id or 0) > (b.id or 0) end)
        for _, n in ipairs(doomed) do
            if n.id ~= nil then
                jxRemove(n, "integrity sweep remove")
            end
        end
    end
    return rep
end

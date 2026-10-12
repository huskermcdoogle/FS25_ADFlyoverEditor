-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua
-- loads it after FlyoverEditor.lua, in the old file's order.
-- MODSPLIT: HELPERS FROM THE FILES LOADED BEFORE THIS ONE (tools/modsplit/split.py writes this block)
for _, name in ipairs({ "JX_PART_NEAR", "junctionAngDiff", "junctionBranchTurn", "jxByPlace", "roadNote", "tryCall" }) do
    if ADFlyoverEditor.shared == nil or ADFlyoverEditor.shared[name] == nil then
        Logging.error("[FlyoverEditor]: JxPreview.lua needs %s, which no file loaded before it shares", name)
    end
end
local JX_PART_NEAR = ADFlyoverEditor.shared.JX_PART_NEAR
local junctionAngDiff = ADFlyoverEditor.shared.junctionAngDiff
local junctionBranchTurn = ADFlyoverEditor.shared.junctionBranchTurn
local jxByPlace = ADFlyoverEditor.shared.jxByPlace
local roadNote = ADFlyoverEditor.shared.roadNote
local tryCall = ADFlyoverEditor.shared.tryCall
-- MODSPLIT: end of the helpers

--- How far the build's search circle at (cx, cz) must reach to take in the lane ends the last clear
--- of this junction cut: the circle `R` itself, or 2 m past the furthest such end within JX_GROW_MAX -
--- and how many ends lie out there. Only the ends that clear CUT (self.junctionClearedEnds, written by
--- applyJunctionClear), and only while the clear was of this junction - its middle within JX_PART_NEAR
--- of the build's, or, where the build found no junction of its own and works from the click, within
--- JX_GROW_SAME of the click - and each end is still a lane end where it was left. A build on 20n
--- after a clear of its twin 20s (the selection finds the wired twin once 20s is cleared) took one of
--- 20s's cut ends. Grown to every lane end that
--- pointed at the middle, the circle took in loose track ends that had lain beside 1, 26 and 63
--- before any clear, and laid turns to them (at 1, three AutoDrive could not take). Kept per place,
--- radius, network and clear, as the preview asks every frame.
local JX_GROW_MAX, JX_GROW_SAME = 30, 20
function ADFlyoverEditor:junctionReachEnds(cx, cz, R)
    local rec = self.junctionClearedEnds
    if rec == nil then return R, 0 end
    local same = (self.junctionSite == nil) and JX_GROW_SAME or JX_PART_NEAR
    if (rec.x - cx) ^ 2 + (rec.z - cz) ^ 2 > same * same then return R, 0 end
    local key = string.format("%d_%d_%d_%d_%d_%s", math.floor(cx * 2), math.floor(cz * 2), math.floor(R * 2),
        ADGraphManager:getWayPointsCount(), rec.serial or 0, tostring(self.junctionSite == nil))
    if self._jxReachKey == key then return self._jxReachR, self._jxReachN end
    local want = {}
    for _, e in ipairs(rec.ends or {}) do
        local d2 = (e.x - cx) ^ 2 + (e.z - cz) ^ 2
        if d2 > R * R and d2 <= JX_GROW_MAX * JX_GROW_MAX then want[#want + 1] = e end
    end
    local best, n = R, 0
    if #want > 0 then
        for _, w in pairs(ADGraphManager:getWayPoints()) do
            if w ~= nil and w.id ~= nil then
                for _, e in ipairs(want) do
                    if not e.found and (w.x - e.x) ^ 2 + (w.z - e.z) ^ 2 <= 0.3 * 0.3 then
                        local s, nb = {}, 0
                        for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
                            for _, id in ipairs(lst) do
                                if id ~= w.id and not s[id] then s[id], nb = true, nb + 1 end
                            end
                        end
                        if nb == 1 then
                            e.found = true
                            n = n + 1
                            best = math.max(best, math.sqrt((w.x - cx) ^ 2 + (w.z - cz) ^ 2) + 2)
                        end
                    end
                end
            end
        end
        for _, e in ipairs(want) do e.found = nil end
    end
    self._jxReachKey, self._jxReachR, self._jxReachN = key, best, n
    return best, n
end

function ADFlyoverEditor:updateJunctionPreview()
    -- Armed: the site is locked where it was clicked and the preview stops following the cursor (the
    -- wheel and the turn radius still reshape it). Unarmed: it follows the cursor as a live scout.
    local cx, cz, cy
    if self.junctionArmed ~= nil then
        cx, cz, cy = self.junctionArmed.cx, self.junctionArmed.cz, self.junctionArmed.cy
    else
        if self.cursorX == nil then
            self.junctionPreview, self.junctionPreviewKey = nil, nil
            return
        end
        cx, cz, cy = self.cursorX, self.cursorZ, self.cursorY
    end
    if self.junctionMode == "place" then
        self:updatePlacePreview()
        return
    end
    local clearMode0 = (self.junctionMode == "clear")
    local R = self:junctionRadiusValue()
    local searchR0 = nil
    -- NB: a DIFFERENT name from the scope radius R - shadowing it once made the scope circle render
    -- at the turn radius instead of the search radius.
    local turnR = self.junctionTurnRadius or 12

    -- THE CLICK PICKS THE JUNCTION, AND THEN IT IS DONE WITH.
    --
    -- Everything below used to be measured from wherever the cursor happened to be: the circle that
    -- selects the tracks sat on it, so each click cut every track at a different waypoint and handed
    -- the whole solve a different set of bearings. Five clicks within two and a half metres of one
    -- junction produced five different clears - at one of them the point count swung by fifteen.
    -- That is not a tolerance, it is the tool doing a different job each time it is asked.
    --
    -- So the click is used once, to say WHICH junction is meant, and from there the junction's own
    -- middle is the origin for all of it. Two clicks that pick the same junction now run identical
    -- arithmetic. The scope radius goes with it: it was the other thing the answer moved with, and
    -- clear mode has no use for it - what belongs to a junction is a property of the road, not of a
    -- number on a wheel.
    local clickX, clickZ = cx, cz
    if clearMode0 then
        -- STEP 1: ONE junction, or none. The cursor stops standing for itself the moment it is
        -- pointing at a junction - what belongs to that junction is a property of the road, not of
        -- where inside it the click landed - and where it is pointing at nothing, the clear REFUSES
        -- and says why rather than working on whatever happens to be nearby.
        local site, why = self:junctionSelect(cx, cz)
        -- CLEAR + BUILD WITH NOTHING TO CLEAR (doc 12): a junction already clear - which the
        -- selection may not even see as one any more (a cleared T reads "the nearest junction is 61 m
        -- away") - goes straight to the build: the preview is the build's, which finds its junction
        -- its own way.
        if self.junctionThenBuild and (site == nil or site.virgin) then
            self.junctionMode = "build"
            tryCall("junction clear + build: nothing to clear, the build's preview", function()
                self:updateJunctionPreview()
            end)
            self.junctionMode = "clear"
            if self.junctionPreview ~= nil then self.junctionPreview.nothingToClear = true end
            return
        end
        -- ALREADY CLEAR IS A REFUSAL TOO. A virgin junction - lane ends facing each other, nothing
        -- joining them - has no wiring to take out, and what a second clear finds to remove there is
        -- the lanes' own rebuilt ends. It used to be refused by accident, because the selection
        -- could not see a junction once it had been cleared; now that it can, it says so on purpose.
        if site ~= nil and site.virgin then
            site, why = nil, "this junction is already clear - nothing is wired here (build can start from it)"
        end
        if site == nil then
            self.junctionSite = nil
            self.junctionRefused = why
            self.junctionPreview, self.junctionPreviewKey = nil, nil
            return
        end
        self.junctionSite, self.junctionRefused = site, nil
        cx, cz = site.x, site.z
        R = AutoDrive.FLYOVER_JUNCTION_CLEAR_SCOPE or 14
    else
        -- BUILD MODE TAKES THE SAME FRONT END. The click is resolved to a junction and the solve is
        -- centred on the junction, not on wherever inside it the cursor landed - the same click-
        -- independence the clear has. Where the selection finds nothing build carries on from the
        -- cursor exactly as it always did: it is a construction tool and may have business at a
        -- site that is not a junction yet, so here a refusal is a note on the card, not a stop.
        local site, why = self:junctionSelect(cx, cz)
        if site ~= nil then
            self.junctionSite, self.junctionRefused = site, nil
            cx, cz = site.x, site.z
        else
            self.junctionSite, self.junctionRefused = nil, why
        end
        -- THE CIRCLE REACHES THE CLEARED LANE ENDS (the user, 2026-10-07). A clear cuts a Y's side
        -- lanes far out - 53's south-east lane in ends 22 m from its middle, 36's south-west lane
        -- 16 m - and with the circle at its 15 m a build left such a lane hanging, connected to
        -- nothing. So the circle grows to take in the lane ends the clear of this junction cut.
        -- The middle is still looked for inside the circle as it was set (lockCap, below): grown, the
        -- circle let the build on cleared 67 take a crossing 13 m off as its middle.
        searchR0 = R
        if AutoDrive.FLYOVER_JUNCTION_GROW_TO_ENDS ~= false then
            local grown, nEnds = self:junctionReachEnds(cx, cz, R)
            -- Said once the site is locked: following the cursor it was said 20 times in a second.
            if grown > R and self.junctionArmed ~= nil then
                roadNote(string.format("growEnds:%d:%d:%d", math.floor(cx), math.floor(cz), math.floor(grown)),
                    "junction build - the search circle grows from %.0f to %.0f m to take in %d lane end(s) the clear of this junction cut further out.",
                    R, grown, nEnds)
            end
            if grown > R then R = grown end
        end
    end
    -- The solve raycasts the road surface for every candidate radius of every turn, so it is only
    -- redone when something it depends on changed: the cursor (to half a metre), a setting, or the
    -- graph. Between those the last preview stands.
    local key = string.format("%d_%d_%d_%d_%s_%s_%s_%s_%d", math.floor(cx * 2), math.floor(cz * 2), R, turnR,
        tostring(self.junctionCheckSurface ~= false), tostring(self.junctionExtendTrim ~= false),
        tostring(self.junctionRebuild == true), tostring(self.junctionUseDubins ~= false)
            .. tostring(self.junctionCheckObstacles ~= false)
            .. string.format("_%d_%d", (self.junctionCorridor or 4) * 10, (self.junctionClearance or 5) * 10)
            -- The swept-path prediction runs only on a LOCKED site (see below), so locking must
            -- refresh the preview; and the rigs that must fit (ticked on the card, or newly measured)
            -- change every predicted line.
            .. "_" .. tostring(self.junctionSwept ~= false) .. "_" .. tostring(self.junctionArmed ~= nil)
            .. "_" .. self:junctionRigsKey(),
        ADGraphManager:getWayPointsCount())
    if key == self.junctionPreviewKey and self.junctionPreview ~= nil then
        return
    end
    self.junctionPreviewKey = key
    self.junctionPreview = nil
    self.junctionChainCache = {}
    local R2 = R * R

    -- Scope: waypoints inside the circle. While gathering, also establish the site's ONE structural
    -- fact about two-way-ness: does ANY link touching the scope run in both directions? If it does
    -- not, this site is one-way in, so it must be one-way out - the placement is HARD-gated on this
    -- (see applyJunction): with no two-way track coming in, nothing the tool lays may ever be two-way.
    local inside = {}
    local siteHasTwoWay = false
    local wps = ADGraphManager:getWayPoints()
    for _, wp in pairs(wps) do
        local dx, dz = wp.x - cx, wp.z - cz
        if dx * dx + dz * dz <= R2 then
            inside[wp.id] = wp
        end
    end
    for _, wp in pairs(inside) do
        for _, tid in pairs(wp.out or {}) do
            local t = ADGraphManager:getWayPointById(tid)
            if t ~= nil and table.contains(t.out or {}, wp.id) then
                siteHasTwoWay = true
                break
            end
        end
        if siteHasTwoWay then break end
    end

    -- Raw approaches: every edge the circle cuts (one end inside, one outside). An edge coming INTO the
    -- scope is an entry, one going OUT is an exit; a two-way lane yields both. Anchored at the inside
    -- boundary node; bearing is the direction of travel (atan2(dx, dz), the convention FS bearings use).
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

    -- AN ARM THAT ENDS INSIDE THE CIRCLE IS STILL AN ARM. Approaches were only ever the lanes the
    -- circle CUTS, and between a close pair that misses a whole road: once the neighbour is cleared,
    -- the lanes towards it stop at the neighbour's box, a few metres away and well inside this
    -- junction's circle, so they cross nothing. The junction was then read with an arm missing - a T
    -- as two roads meeting at a corner, its box laid across the wrong pair. A lane END inside the
    -- circle is taken as an approach just as a cut lane is: where travel stops it is an exit, where
    -- travel starts it is an entry.
    if clearMode0 then
        -- A loose end in the junction's own wiring is not an arm. What marks a real lane end is
        -- that it is the OUTER end of a stub of plain road leading INTO the junction: followed
        -- inward it runs as a plain chain for a few metres and arrives at a fork that lies nearer
        -- the middle than the end itself does.
        local function stubInto(wp, dir)
            local prev, cur, run = nil, wp, 0
            for _ = 1, 12 do
                local lst = cur[dir] or {}
                if #lst ~= 1 then return false end
                local nxt = ADGraphManager:getWayPointById(lst[1])
                if nxt == nil or inside[nxt.id] == nil then return false end
                run = run + math.sqrt((nxt.x - cur.x) ^ 2 + (nxt.z - cur.z) ^ 2)
                local s2, d = {}, 0
                for _, l2 in ipairs({ nxt.out or {}, nxt.incoming or {} }) do
                    for _, id in pairs(l2) do if not s2[id] then s2[id] = true d = d + 1 end end
                end
                if d >= 3 then
                    local dEnd = (wp.x - cx) ^ 2 + (wp.z - cz) ^ 2
                    local dFork = (nxt.x - cx) ^ 2 + (nxt.z - cz) ^ 2
                    return run >= 3 and dFork < dEnd
                end
                prev, cur = cur, nxt
            end
            return false
        end
        for _, wp in jxByPlace(inside) do
            local nOut, nIn = #(wp.out or {}), #(wp.incoming or {})
            if nOut == 0 and nIn == 1 and stubInto(wp, "incoming") then
                local p = ADGraphManager:getWayPointById(wp.incoming[1])
                raw[#raw + 1] = { wp = wp, dir = "out", bearing = math.atan2(wp.x - p.x, wp.z - p.z), laneEnd = true }
            elseif nIn == 0 and nOut == 1 and stubInto(wp, "out") then
                local t = ADGraphManager:getWayPointById(wp.out[1])
                raw[#raw + 1] = { wp = wp, dir = "in", bearing = math.atan2(t.x - wp.x, t.z - wp.z), laneEnd = true }
            end
        end
    end

    -- Group the raw approaches: same direction, similar bearing, and close together fold into ONE. This
    -- collapses the near-coincident, stacked one-way nodes the survey found (arms 0.4-0.9 m apart) so a
    -- crossing reads as a handful of approaches instead of a web. First step of "approach grouping".
    --
    -- WHICH LANE END SPEAKS FOR THE GROUP is not whichever the loop met first. A loose copy of a road
    -- lying on top of the real one puts its lane ends a metre from the real ones, same way, same
    -- bearing: at one T the real southbound exit folded into the copy's, the southbound lane had no
    -- exit left to pair with, and the road was read as one through lane plus two "side roads" - a
    -- staggered 4-way. So a lane end on a LOOSE PIECE (a few hundred points at most, joined to
    -- nothing else) gives way to one on the network. Only that: preferring whichever end is more
    -- wired INSIDE the circle instead swapped a Y's plain lane for its own turn wiring and lost a
    -- through route.
    local LOOSE = 200
    local looseCache = {}
    local function onLoosePiece(wp)
        if looseCache[wp] ~= nil then return looseCache[wp] end
        local seen, stack, n = { [wp.id] = true }, { wp }, 0
        while #stack > 0 and n < LOOSE do
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
        looseCache[wp] = (#stack == 0 and n < LOOSE)
        return looseCache[wp]
    end
    -- TWO ROADS SPLITTING APART ARE NOT ONE LANE. The fold is for stacked duplicates - points under
    -- a metre apart on the same line. At a tight Y the two branches' lanes cross the circle 3.5 m
    -- apart and 18 degrees apart, folded into one, and a whole branch vanished (53 by the registry,
    -- read as a straight road with no side road). So both are followed 5 m further out, the way
    -- traffic goes (downstream for an exit, upstream for an entry); more than 5 m apart there, they
    -- are two roads.
    local function outward(wp, dir, want)
        local prev, cur, run = nil, wp, 0
        for _ = 1, 30 do
            local lst = (dir == "out") and (cur.out or {}) or (cur.incoming or {})
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
    local function sameLine(a, b, dir)
        -- 5 m out, not further: a slip lane hugging the road lane 3.5 m apart at 5 m and curving off
        -- to the NEXT junction later (40) is still this road's lane here; 53's branch is 6.8 m clear
        -- by then.
        local fa, fb = outward(a, dir, 5), outward(b, dir, 5)
        return (fa.x - fb.x) ^ 2 + (fa.z - fb.z) ^ 2 <= 5 * 5
    end
    local approaches = {}
    local nIn, nOut = 0, 0
    for _, ap in ipairs(raw) do
        local into = nil
        for _, g in ipairs(approaches) do
            if g.dir == ap.dir and junctionAngDiff(g.bearing, ap.bearing) < math.rad(35)
                and (g.wp.x - ap.wp.x) ^ 2 + (g.wp.z - ap.wp.z) ^ 2 < 36
                and sameLine(g.wp, ap.wp, ap.dir) then
                into = g
                break
            end
        end
        if into ~= nil then
            into.count = into.count + 1
            if onLoosePiece(into.wp) and not onLoosePiece(ap.wp) then
                ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - lane end id=%d lies on a loose piece wired to nothing; id=%d beside it is on the network and speaks for the pair.",
                    into.wp.id, ap.wp.id)
                into.wp, into.bearing = ap.wp, ap.bearing
            elseif onLoosePiece(into.wp) == onLoosePiece(ap.wp) then
                -- OTHERWISE THE LANE THAT RUNS ON AWAY FROM THE JUNCTION SPEAKS FOR THE PAIR, not
                -- whichever the loop met first. The loop takes the circle's points in an order set by
                -- their ids, so the first is down to numbering, and a clear nearby renumbers. At 39,
                -- the main road's lane in from the north-east and a turn of 39se's that joins it 1 m
                -- away fold together. On a fresh network the main road came first. Once 30 had been
                -- cleared the turn came first, the main road was read as coming from the north, and
                -- the clear cut the road from the south. Followed 20 m out, the road lane is still
                -- heading away while the turn has bent off, so the one that ends farther from the
                -- middle is kept; a dead heat goes to the more westerly, then the more northerly.
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
            if ap.dir == "in" then nIn = nIn + 1 else nOut = nOut + 1 end
        end
    end

    -- ---------------------------------------------------------------------------------------------
    -- From here on the WHEEL IS DONE. The search circle has said which tracks take part; everything
    -- that follows - where the tracks meet, where the tool ties into them, kickouts, what is already
    -- connected, what a rebuild clears - works in the fixed WORK REGION and comes out the same
    -- whatever size the circle was. (It used to all run inside the circle: tie-ins clamped at its
    -- edge, a turn radius near the scope radius could not be laid, and a kickout needed the circle
    -- widened to fit - the wheel was quietly an intersection-geometry control.)
    --
    -- Each selected track is RE-ANCHORED: followed away from the junction (an entry upstream, an
    -- exit downstream, bearing-continuous) to the edge of the work region, and that far node becomes
    -- the approach's anchor - the start of its lane chain. The node where the circle cut the track is
    -- kept as selWp (the preview's pillar stands there) and ap.bearing stays the bearing AT the cut,
    -- near the junction, for the turn-angle decisions. Two selections that re-anchor to the same node
    -- are the same lane and fold into one - which is also what absorbs an existing kickout that
    -- happens to cross the circle beside its lane: followed outward it rejoins the lane and lands on
    -- the lane's own anchor.
    -- How far a run is followed OUTWARD from where the circle cut it, as LENGTH ALONG THE RUN: what a
    -- turn can need - a tie-in up to ~1.5 turn radii back from the corner, then the kickout's late
    -- return (look-ahead + trailer length) - plus a margin. Need-based, so it is tens of metres, not
    -- a big blanket region; and it is a length along the track, not a radius from the click.
    local reachRig = (ADFlyoverSweptPath ~= nil and ADFlyoverSweptPath.rig) or (SweptSim ~= nil and SweptSim.EXAMPLE_RIG) or {}
    local runReach = turnR * 1.5 + ((reachRig.lookAhead or 8) + (reachRig.trailerLength or 0)) + 10
    -- The node INDEX the rest of the solve searches in: generous enough to hold every followed run.
    -- Only an index bound - nothing geometric is measured against it.
    local W = math.max(AutoDrive.FLYOVER_JUNCTION_WORK_REACH or 60, R + runReach + 10)
    local W2 = W * W
    local work = {}
    for _, wp in pairs(wps) do
        local dx, dz = wp.x - cx, wp.z - cz
        if dx * dx + dz * dz <= W2 then work[wp.id] = wp end
    end
    local ownR2 = (R + (AutoDrive.FLYOVER_JUNCTION_OWN_TOLERANCE or 5)) ^ 2
    self.junctionOwn = { cx = cx, cz = cz, r2 = ownR2 }
    local function isOwn(wp) return (wp.x - cx) ^ 2 + (wp.z - cz) ^ 2 <= ownR2 end
    -- Does the wiring hanging off `fromId` through `startId` reach the search circle (+ tolerance)?
    -- A bounded flood that may not pass back through `fromId` - so it cannot cheat by running down
    -- our own lane into the circle.
    local function branchIsOurs(startId, fromId)
        local seenB, stackB, n = { [fromId] = true, [startId] = true }, { startId }, 0
        while #stackB > 0 and n < 200 do
            local id = table.remove(stackB)
            local w = work[id]
            n = n + 1
            if w ~= nil then
                if isOwn(w) then return true end
                for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
                    for _, x in pairs(lst) do
                        if not seenB[x] and work[x] ~= nil then
                            seenB[x] = true
                            stackB[#stackB + 1] = x
                        end
                    end
                end
            end
        end
        return false
    end
    do
        local merged, byAnchor = {}, {}
        for _, ap in ipairs(approaches) do
            local useOut = (ap.dir == "out")
            local wdx, wdz = math.sin(ap.bearing), math.cos(ap.bearing)
            if not useOut then wdx, wdz = -wdx, -wdz end
            local node, cameFrom = ap.wp, nil
            local tbx, tbz = math.sin(ap.bearing), math.cos(ap.bearing)   -- travel direction at the anchor
            local run, endedAt = 0, nil
            -- The way the run was followed, cut node first: the lane walk prefers it on the way back.
            local runPath = { ap.wp }
            for _ = 1, 400 do
                local list = useOut and (node.out or {}) or (node.incoming or {})
                local nextId, bestDot = nil, -math.huge
                -- THE LANE'S OWN ROAD CAN END BEFORE THE REACH DOES. Going outward, a node with two
                -- ways on is where this lane is FED from (or splits into) two places - and if each of
                -- them arrives turned more than 35 degrees, they are another junction's turn
                -- connectors and this lane begins right here. Following one of them carried the run
                -- round the neighbour's corner and anchored a 4-way's arm on the crossbar of the T
                -- 37 m down it; the lane walk back from there went straight on along the crossbar,
                -- never reached the 4-way at all, and the arm's real lane - road nobody had claimed -
                -- was cleared as wiring. (The test below for "another junction" asks whether the side
                -- branch can reach the circle, and through a junction everything can.)
                local turnsAway = nil
                if cameFrom ~= nil then
                    local nWays, nTurns, verdict = 0, 0, {}
                    for _, nid in pairs(list) do
                        if nid ~= cameFrom and work[nid] ~= nil and verdict[nid] == nil then
                            nWays = nWays + 1
                            verdict[nid] = junctionBranchTurn(node, work[nid], useOut, wdx, wdz, 60) > math.rad(35)
                            if verdict[nid] then nTurns = nTurns + 1 end
                        end
                    end
                    if nWays >= 2 then
                        if nTurns == nWays then
                            endedAt = "the lane's own road ends here - every way on is another junction's turn"
                            break
                        end
                        turnsAway = verdict
                    end
                end
                for _, nid in pairs(list) do
                    if nid ~= cameFrom and work[nid] ~= nil and not (turnsAway ~= nil and turnsAway[nid]) then
                        local nx = work[nid]
                        local dx, dz = nx.x - node.x, nx.z - node.z
                        local l = math.sqrt(dx * dx + dz * dz)
                        if l > 1e-6 then
                            local dot = (dx / l) * wdx + (dz / l) * wdz
                            if nextId == nil or dot > bestDot + 0.15 or (dot > bestDot - 0.15 and nid < nextId) then
                                bestDot, nextId = math.max(dot, bestDot), nid
                            end
                        end
                    end
                end
                -- Never walk back on ourselves, and never round a sharp corner onto another road.
                if nextId == nil or bestDot < 0.3 then endedAt = "end of track"; break end
                -- A FORK outside the circle: is the side branch this junction's own wiring (an
                -- earlier tie-in or kickout - it reaches the circle) or ANOTHER junction? At another
                -- junction the run ENDS: tying in or kicking out upstream of it would run our wiring
                -- through its crossing - across its conflict points, and into the hands of its
                -- rebuild, which would see our kickout as its own old wiring and delete it.
                if not isOwn(node) then
                    local foreign = false
                    for _, lst in ipairs({ node.out or {}, node.incoming or {} }) do
                        for _, b in pairs(lst) do
                            if b ~= cameFrom and b ~= nextId and work[b] ~= nil and not branchIsOurs(b, node.id) then
                                foreign = true
                            end
                        end
                    end
                    if foreign then endedAt = "another junction"; break end
                end
                local nxt = work[nextId]
                local dx, dz = nxt.x - node.x, nxt.z - node.z
                local l = math.sqrt(dx * dx + dz * dz)
                if l > 1e-6 then
                    wdx, wdz = dx / l, dz / l
                    -- walking an entry goes UPSTREAM, so travel direction is the reverse of the walk
                    if useOut then tbx, tbz = wdx, wdz else tbx, tbz = -wdx, -wdz end
                end
                cameFrom = node.id
                node = nxt
                runPath[#runPath + 1] = node
                run = run + l
                if run >= runReach then break end
            end
            ap.selWp = ap.wp
            ap.wp = node
            ap.runPath = runPath
            ap.chainBearing = math.atan2(tbx, tbz)
            ap.runLength, ap.runEnded = run, endedAt
            local k = ap.dir .. "_" .. node.id
            if byAnchor[k] == nil then
                byAnchor[k] = ap
                merged[#merged + 1] = ap
            else
                byAnchor[k].count = (byAnchor[k].count or 1) + (ap.count or 1)
            end
        end
        -- WHAT IS NOT REALLY AN ARM, SAID OUT LOUD.
        --
        -- Approaches were gathered by looking around the click: anything close enough and pointing
        -- roughly the right way counted. Two kinds of thing get in that way, and both were seen at
        -- one T where the tool read a 4-way that is not there.
        --
        --   NOT WIRED ON AT ALL. A pair of free-floating chains, the remains of a two-lane road
        --   lying 10 to 50 m off and attached to no part of the network, read as an arm on a bearing
        --   one degree from a real one.
        --
        --   THE SAME LANE TWICE. A stub running 13.8 m alongside a lane that runs 167 m, 3.2 m
        --   across and pointing the other way. Nothing about it in isolation is suspicious - 3.2 m
        --   is ordinary lane spacing and the opposite bearing is what a second lane does - so only
        --   the comparison gives it away. Which also makes the test safe: a short spur on its own is
        --   never touched, because there is nothing for it to duplicate.
        --
        -- Nothing is deleted either way. What is not an arm simply stops being counted as one.
        do
            local seed = nil
            for _, ap in ipairs(merged) do
                if ap.wp ~= nil then seed = ap.wp break end
            end
            if seed ~= nil then
                local REACH = 150
                local seen, stack = { [seed] = true }, { seed }
                while #stack > 0 do
                    local w = table.remove(stack)
                    for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
                        for _, id in ipairs(lst) do
                            local t = ADGraphManager:getWayPointById(id)
                            if t ~= nil and not seen[t]
                                and (t.x - seed.x) ^ 2 + (t.z - seed.z) ^ 2 <= REACH * REACH then
                                seen[t] = true
                                stack[#stack + 1] = t
                            end
                        end
                    end
                end

                -- HOW FAR A LANE RUNS ON PAST ITS ANCHOR. AT A FORK, THE WAY STRAIGHT ON. The walk took
                -- the way out that moved it least further from the seed, and at a fork that can be
                -- the side branch: at 39 the north road's northbound lane is anchored on the fork
                -- where a turn to the junction to the north-west leaves it, the walk took that turn
                -- and stopped after 8 m, and the lane - the north road's other lane, running on for
                -- hundreds of metres - was "the same lane twice" beside the southbound one. Left out
                -- of the side roads, it was never brought to the box: cleared, the north road's
                -- northbound lane started 10.9 m from the main road and its southbound twin 2.7 m.
                -- Where more than one way leads further from the seed, the one turning least from
                -- the way the lane came (the run followed out to the anchor, then the walk's own last
                -- step) is taken; one way on is taken as before.
                local function runsFor(ap)
                    local w, prev, run, steps = ap.wp, nil, 0, 0
                    if w == nil then return math.huge end
                    local hx, hz = nil, nil
                    local rp = ap.runPath
                    if rp ~= nil and #rp >= 2 and rp[#rp] == w then
                        local q = rp[#rp - 1]
                        local l = math.sqrt((w.x - q.x) ^ 2 + (w.z - q.z) ^ 2)
                        if l > 1e-6 then hx, hz = (w.x - q.x) / l, (w.z - q.z) / l end
                    end
                    while steps < 40 do
                        local nxt, bd = nil, math.huge
                        local here = (w.x - seed.x) ^ 2 + (w.z - seed.z) ^ 2
                        local ways = {}
                        for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
                            for _, id in ipairs(lst) do
                                local t = ADGraphManager:getWayPointById(id)
                                if t ~= nil and t ~= prev then
                                    local d = (t.x - seed.x) ^ 2 + (t.z - seed.z) ^ 2
                                    if d > here then
                                        ways[#ways + 1] = t
                                        if d < bd then bd, nxt = d, t end
                                    end
                                end
                            end
                        end
                        if #ways >= 2 and hx ~= nil and AutoDrive.FLYOVER_JUNCTION_RUN_STRAIGHT ~= false then
                            local bestDot = -math.huge
                            for _, t in ipairs(ways) do
                                local l = math.sqrt((t.x - w.x) ^ 2 + (t.z - w.z) ^ 2)
                                if l > 1e-6 then
                                    local dot = ((t.x - w.x) * hx + (t.z - w.z) * hz) / l
                                    if dot > bestDot + 1e-9 then bestDot, nxt = dot, t end
                                end
                            end
                        end
                        if nxt == nil then break end
                        do
                            local l = math.sqrt((nxt.x - w.x) ^ 2 + (nxt.z - w.z) ^ 2)
                            if l > 1e-6 then hx, hz = (nxt.x - w.x) / l, (nxt.z - w.z) / l end
                        end
                        run = run + math.sqrt((nxt.x - w.x) ^ 2 + (nxt.z - w.z) ^ 2)
                        prev, w = w, nxt
                        steps = steps + 1
                    end
                    return run
                end

                local ISLAND_POINTS, ISLAND_SPAN = 200, 20
                local shadowed, runs = {}, {}
                local ACROSS, RATIO = 5.0, 3.0
                local minArm = AutoDrive.FLYOVER_JUNCTION_MIN_ARM or 15
                for i, ap in ipairs(merged) do runs[i] = runsFor(ap) end
                for i = 1, #merged do
                    for j = 1, #merged do
                        if i ~= j and not shadowed[i] and not shadowed[j]
                            and merged[i].wp ~= nil and merged[j].wp ~= nil then
                            local sep = math.abs(math.deg((merged[i].bearing or 0) - (merged[j].bearing or 0))) % 360
                            if sep > 180 then sep = 360 - sep end
                            local parallel = (sep <= 20) or (math.abs(sep - 180) <= 20)
                            local dx, dz = math.sin(merged[j].bearing or 0), math.cos(merged[j].bearing or 0)
                            local ex = merged[i].wp.x - merged[j].wp.x
                            local ez = merged[i].wp.z - merged[j].wp.z
                            local across = math.abs(ex * dz - ez * dx)
                            if parallel and across <= ACROSS
                                and runs[i] < minArm and runs[j] > runs[i] * RATIO then
                                shadowed[i] = true
                                Logging.info("[FlyoverEditor]: junction - the branch on bearing %.0f runs %.0f m and lies %.1f m alongside a lane that runs %.0f m - the same lane twice. Not counted as a side road.",
                                    math.deg(merged[i].bearing or 0) % 360, runs[i], across, runs[j])
                            end
                        end
                    end
                end

                local kept = {}
                for k, ap in ipairs(merged) do
                    if shadowed[k] then
                        -- A stub that duplicates a real lane is not a side road. Only the side-road
                        -- list below skips it: the approaches themselves are kept, because other
                        -- passes lean on them and dropping them made the clear worse.
                        ap._debris = true
                    elseif ap.wp == nil or seen[ap.wp] then
                        kept[#kept + 1] = ap
                    else
                        -- UNWIRED IS NOT DEBRIS; SMALL IS. How big is the piece of network this road
                        -- belongs to? A through road whose lanes an earlier clear cut loose at the
                        -- box edge is an island too - 17 to 20 points over 120-220 m on the test
                        -- map, and exactly what this tool is for connecting. Skipping those turned
                        -- two plain crossroads into T's. Nor is short enough: the lane between two
                        -- close junctions, both cleared, is an island of 5-9 points over 32-59 m.
                        -- Across 35 captured clears the only true leftovers were 13-14 m long (3 and
                        -- 6 points, after one junction was cleared twice), so LENGTH decides: under
                        -- ISLAND_SPAN end to end is debris. ISLAND_POINTS only bounds the walk.
                        local pts, x0, x1, z0, z1 = 1, ap.wp.x, ap.wp.x, ap.wp.z, ap.wp.z
                        local got, st = { [ap.wp] = true }, { ap.wp }
                        while #st > 0 and pts < ISLAND_POINTS do
                            local w = table.remove(st)
                            for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
                                for _, id in pairs(lst) do
                                    local t = ADGraphManager:getWayPointById(id)
                                    if t ~= nil and not got[t] then
                                        got[t] = true
                                        pts = pts + 1
                                        st[#st + 1] = t
                                        x0, x1 = math.min(x0, t.x), math.max(x1, t.x)
                                        z0, z1 = math.min(z0, t.z), math.max(z1, t.z)
                                    end
                                end
                            end
                        end
                        local span = math.sqrt((x1 - x0) ^ 2 + (z1 - z0) ^ 2)
                        if span < ISLAND_SPAN then
                            ap._debris = true
                            Logging.info("[FlyoverEditor]: junction - the road on bearing %.0f is a loose piece of %d point(s) over %.0f m, wired to nothing. Not counted as a side road.",
                                math.deg(ap.bearing or 0) % 360, pts, span)
                        else
                            Logging.info("[FlyoverEditor]: junction - the road on bearing %.0f is not wired to this junction, but it is a road (%s point(s) over %.0f m). Counted.",
                                math.deg(ap.bearing or 0) % 360, (pts >= ISLAND_POINTS) and (ISLAND_POINTS .. "+") or tostring(pts), span)
                        end
                    end
                end
                -- WHAT IS ACTED ON, AND WHERE. Dropping approaches outright makes the clear worse
                -- (42 m reach instead of 36 at one T): they carry more than "these are the arms".
                -- But the junction's TYPE reads jp.pathRoutes.side, which is built from every
                -- approach no through route covers - so a stub duplicating a lane became a side
                -- road, and a T read as a staggered 4-way. The same-lane stub is therefore kept out
                -- of the side roads only (ap._debris), and nothing else.
                --
                -- An unwired road is kept out only when its whole piece of network is small (see
                -- ISLAND_POINTS / ISLAND_SPAN above): a loose fragment, not a road awaiting wiring.
                local _ = kept
            end
        end

        approaches = merged
        nIn, nOut = 0, 0
        for _, ap in ipairs(approaches) do
            if ap.dir == "in" then nIn = nIn + 1 else nOut = nOut + 1 end
        end
    end
    -- Downstream code reads `inside` and `R` as "the region the junction lives in": that is now the
    -- work region. The selection circle keeps its own radius for the key, the draw and the card.
    self.junctionWalkApproaches = approaches
    local selectR = R
    inside = work
    R = W

    -- "Already connected" = a directed path from the entry's inside node to the exit's inside node,
    -- staying INSIDE the scope - so a road passing straight through is not re-proposed as a turn onto
    -- itself. Bounded to the (small) inside set, so cheap. Also returns THE path (as node ids, from
    -- entry to exit) - the rebuild option needs to know which nodes carry the old connection.
    local function connectedInside(fromId, toId)
        if fromId == toId then return true, { fromId } end
        -- BREADTH-first (a queue, not a stack): the FIRST path found is then the fewest-hops one.
        -- That matters now that the region is 60 m: the two tracks may also be joined the long way
        -- round - through a neighbouring junction, around a block - and a depth-first search could
        -- return that detour, or return it for a pair this junction does not connect at all.
        local parent = { [fromId] = fromId }
        local queue, head = { fromId }, 1
        while head <= #queue do
            local id = queue[head]
            head = head + 1
            local w = inside[id]
            if w ~= nil then
                for _, tid in pairs(w.out or {}) do
                    if tid == toId then
                        local path = { toId }
                        local cur = id
                        while cur ~= fromId do
                            table.insert(path, 1, cur)
                            cur = parent[cur]
                        end
                        table.insert(path, 1, fromId)
                        -- A connection THROUGH THIS JUNCTION is about as long as anchor -> locked
                        -- point -> anchor. One much longer than that is a detour via somewhere else:
                        -- not this junction's turn, so the turn is still to be laid.
                        local len = 0
                        for i = 2, #path do
                            local a, b = inside[path[i - 1]], inside[path[i]]
                            if a ~= nil and b ~= nil then
                                len = len + math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2)
                            end
                        end
                        -- ...and it has to pass through THIS crossing at all (ownership rule).
                        local touches = false
                        for _, pid in ipairs(path) do
                            local pw = inside[pid]
                            if pw ~= nil and isOwn(pw) then touches = true; break end
                        end
                        if not touches then return false, nil end
                        local f, t = inside[fromId], inside[toId]
                        if f ~= nil and t ~= nil then
                            local via = math.sqrt((f.x - cx) ^ 2 + (f.z - cz) ^ 2) + math.sqrt((t.x - cx) ^ 2 + (t.z - cz) ^ 2)
                            if len > via * 1.5 + 20 then return false, nil end
                        end
                        return true, path
                    end
                    if inside[tid] ~= nil and parent[tid] == nil then
                        parent[tid] = id
                        queue[#queue + 1] = tid
                    end
                end
            end
        end
        return false, nil
    end

    -- The road SKELETON: every node on any approach's own chain - the roads themselves, including
    -- spliced-in tie nodes from earlier placements. The rebuild option deletes an existing turn's old
    -- path nodes, and this set is what protects the roads: only path nodes OFF the skeleton (old
    -- connector interiors) are ever removed. A through-movement's path lies entirely ON the skeleton,
    -- so its "old path" is empty and it is left alone - rebuilding never duplicates a through road.
    -- Clear mode always needs the debris cluster (that IS its job), whatever "existing turns" says.
    local clearMode = (self.junctionMode == "clear")
    local rebuildOn = (self.junctionRebuild == true) or clearMode
    -- Same condition as `logSite` below (declared later, after this runs) - named separately rather
    -- than moved, to touch as little of the tested code above this point as possible.
    local logSite2 = (self.junctionArmed ~= nil)
    -- Skeleton = road nodes; roadLink = the LEGITIMATE links between them (consecutive along an
    -- approach chain, unordered). Rebuild needs both: an old connection between two skeleton nodes
    -- with no interior points (a short direct bridge) has no node to sweep - only the roadLink set
    -- can tell that link apart from the road itself.
    local skeleton, roadLink = {}, {}
    -- A subset of the skeleton: the part of each lane that is unambiguously PARENT ROAD. Kept apart
    -- from the skeleton because the two answer different questions - the skeleton is "is this road
    -- for group detection", which has to reach the crossing, while this is "would clearing this eat
    -- someone's road", which must not.
    local runNode, runNodeOf = {}, {}
    local function linkKey(a, b) return math.min(a, b) .. "_" .. math.max(a, b) end
    -- LANE GROUPS: approaches whose chains share a node are the same physical lane (a through
    -- road's entry and its exit walk the same nodes from opposite ends; a two-way track's four
    -- approaches all do). A turn connector is, by definition, wiring between two DIFFERENT groups -
    -- which is what lets rebuild tell old junction wiring from a siding or a parking bay that hangs
    -- off one lane (see the debris pass below).
    local groupOf, owner = {}, {}
    local function findGroup(i)
        while groupOf[i] ~= i do
            groupOf[i] = groupOf[groupOf[i]]
            i = groupOf[i]
        end
        return i
    end
    -- So: find the crossings in the region (nodes with 3+ distinct neighbours, single-link clustered
    -- at 12 m so one junction's many tie-in forks count once), take the one nearest the lock as the
    -- one being cleared, and assign every node to its nearest crossing. Wiring is cleared only where
    -- the lock's crossing is the nearest one - a Voronoi boundary. A tight pair 20 m apart splits down
    -- the middle; an isolated sprawling junction keeps everything that is closer to it than to
    -- anything else, with no tuning either way.
    local crossings = {}
    do
        -- Scanned at a FIXED reach, deliberately NOT the work region (which is sized from the search
        -- radius). Sizing it from the radius made the tool's answer depend on the circle: at r=20 it
        -- saw 3 crossings, at r=40 it saw 8, so a WIDER search cleared LESS - the extra crossings
        -- carved the locked one's Voronoi cell smaller. Which junctions exist near a point is a fact
        -- about the network, not about how big the user set the circle.
        local CROSSING_SCAN = 70
        local scan2 = CROSSING_SCAN * CROSSING_SCAN
        local cand = {}
        for _, w in pairs(ADGraphManager:getWayPoints()) do
            if w ~= nil and (w.x - cx) ^ 2 + (w.z - cz) ^ 2 <= scan2 then
            local nb, deg = {}, 0
            for _, t in ipairs(w.out or {}) do nb[t] = true end
            for _, f in ipairs(w.incoming or {}) do nb[f] = true end
            for _ in pairs(nb) do deg = deg + 1 end
            if deg >= 3 then cand[#cand + 1] = w end
            end
        end
        local used = {}
        for i, w in ipairs(cand) do
            if not used[i] then
                used[i] = true
                local sx, sz, n = w.x, w.z, 1
                local grew = true
                while grew do
                    grew = false
                    for j, v in ipairs(cand) do
                        if not used[j] then
                            local ax, az = sx / n, sz / n
                            if (v.x - ax) ^ 2 + (v.z - az) ^ 2 <= 144 then
                                used[j] = true
                                sx, sz, n = sx + v.x, sz + v.z, n + 1
                                grew = true
                            end
                        end
                    end
                end
                crossings[#crossings + 1] = { x = sx / n, z = sz / n, n = n }
            end
        end
        -- THE CROSSINGS ARE WHERE THE ROADS MEET, where the roads can say. Fork clusters stand in
        -- for junctions badly: one wide junction makes several, and the cluster a kickout makes
        -- 13 m up a side road was taken for the junction next door - its lane was handed to it and
        -- both connectors joining that lane were spared as "that junction's wiring". With the
        -- road-meeting points as the crossings every fork simply goes to the nearest place roads
        -- actually meet, and a junction's far tie forks are its own without any rule saying so.
        -- A fork cluster survives as a crossing only where no meeting point accounts for it - a
        -- shallow merge, which cuts no corner for the roads-first finder to see.
        if AutoDrive.FLYOVER_JUNCTION_ROADS_FIRST ~= false then
            local byRoads = {}
            for _, c in ipairs(self:junctionCentres() or {}) do
                if (c.x - cx) ^ 2 + (c.z - cz) ^ 2 <= scan2 then
                    byRoads[#byRoads + 1] = { x = c.x, z = c.z, n = c.n }
                end
            end
            -- ...and a junction that has already been cleared still owns its road.
            for _, c in ipairs(self:junctionVirginCentres() or {}) do
                if (c.x - cx) ^ 2 + (c.z - cz) ^ 2 <= scan2 then
                    local dup = false
                    for _, b in ipairs(byRoads) do
                        if (b.x - c.x) ^ 2 + (b.z - c.z) ^ 2 <= 12 * 12 then dup = true break end
                    end
                    if not dup then byRoads[#byRoads + 1] = { x = c.x, z = c.z, n = c.n } end
                end
            end
            if #byRoads > 0 then
                for _, old in ipairs(crossings) do
                    local claimed = false
                    for _, c in ipairs(byRoads) do
                        if (c.x - old.x) ^ 2 + (c.z - old.z) ^ 2 <= 25 * 25 then claimed = true break end
                    end
                    if not claimed then byRoads[#byRoads + 1] = old end
                end
                crossings = byRoads
            end
        end
    end
    -- A BUILD WITH NO SITE KEEPS TO ITS OWN CIRCLE. Where the selection found nothing (build carries
    -- on from the cursor), the nearest crossing could be anywhere in the 70 m scan, and everything
    -- below is measured from it: the build on cleared 36 - the two cut ends of its side road 14.9 m
    -- apart, one more than makes a cleared site - took the junction 52 m up the road as its middle
    -- and built that one's turns. Further out than the search circle, a crossing is not this site,
    -- and the middle falls back to where the circle cut the tracks (tracksCentre, below). The SEARCH
    -- circle (selectR): R is the 60-70 m work region by now.
    local lockedCrossing, bestLockD = nil, math.huge
    local lockCap = math.huge
    if not clearMode and self.junctionSite == nil then lockCap = (searchR0 or selectR) ^ 2 end
    for _, c in ipairs(crossings) do
        local d = (c.x - cx) ^ 2 + (c.z - cz) ^ 2
        if d < bestLockD and d <= lockCap then bestLockD, lockedCrossing = d, c end
    end

    local apIndex = {}
    -- Where a lane's road ENDS, for the lanes that end near here: a side road stops at its junction,
    -- a through road runs on out of the region. Used below to tell a second junction from a
    -- fragment of this one.
    local laneTips, laneTipOf = {}, {}
    for ai, ap in ipairs(approaches) do
        groupOf[ai] = ai
        apIndex[ap] = ai
        local ch = self:junctionChain(ap, cx, cz, R)
        -- SKELETON STOPS AT THE CROSSING. The chain itself runs the whole way and stays complete -
        -- build geometry needs it for tie-ins and for finding where two tracks meet. But only the
        -- part from the anchor up to where this lane comes CLOSEST to the locked point is this lane's
        -- ROAD. Past that closest point the walk is on the far side of the crossing, travelling over
        -- whatever wiring carries traffic across it - and marking that as road makes it skeleton,
        -- which makes it permanently unclearable.
        --
        -- That is what kept the T connected through every clear: the tool's own connectors are laid
        -- tangent-continuous, so the walk ran straight through the middle and out the other side.
        -- A surviving route was traced entirely over nodes 1.7-8 m from the lock, every one of them
        -- marked skeleton by this loop. Stopping at the closest approach is exact - no tolerance to
        -- tune, and a lane that merely bends is unaffected because its closest point is still the
        -- point nearest the junction.
        -- MEASURED FROM THE CROSSING, not from the click. This boundary decides how much of a
        -- lane counts as road, and a connector laid tangent-continuous onto that lane sits right
        -- at it - so when it moved with the cursor, so did the amount of connector swallowed as
        -- road. Four clicks within 6 m of each other, all identifying the same crossing, trimmed
        -- 0, 1, 1 and 4 points: one tidied the tail, the next did not. The crossing is a property
        -- of the network, so the answer is now the same wherever inside the junction you click.
        local ax, az = cx, cz
        if lockedCrossing ~= nil then ax, az = lockedCrossing.x, lockedCrossing.z end
        local closest, bestD2 = #ch, math.huge
        for i, n in ipairs(ch) do
            local d2 = (n.x - ax) ^ 2 + (n.z - az) ^ 2
            if d2 < bestD2 then bestD2, closest = d2, i end
        end
        -- A lane that ENDS near here, as opposed to one that comes through and ends somewhere
        -- else. The arm of a 4-way can be the side road of a T 37 m further on: its lane does end,
        -- within reach, at a fork - but it ends THERE, having passed straight through HERE first,
        -- and calling it "a side road of the other junction" disowned every connector this 4-way
        -- has onto it. A lane ends at the junction where it stops getting any closer to this one:
        -- its tip is its nearest point (give or take how far off-centre a crossing can sit).
        do
            local tipN = ch[#ch]
            if tipN ~= nil and #ch >= 2 and (tipN.x - cx) ^ 2 + (tipN.z - cz) ^ 2 <= 35 * 35 then
                local dTip = math.sqrt((tipN.x - ax) ^ 2 + (tipN.z - az) ^ 2)
                if dTip <= math.sqrt(bestD2) + 6 then
                    laneTips[#laneTips + 1] = tipN
                    laneTipOf[ai] = tipN
                end
            end
        end
        -- NOTE: an earlier version also refused to call anything inside the SEARCH CIRCLE road, to
        -- catch the connector "tails" this rule still leaves behind (the walk steps a little way onto
        -- a connector before reaching its closest point, and those nodes survive a clear). That went
        -- badly: with no road inside the circle the junction's whole interior became a single cluster
        -- that no longer touched two distinguishable lanes, the "joins two lane groups" test failed,
        -- and a junction locked dead-centre cleared NOTHING (30 points sitting 1.5 m from the lock,
        -- all rejected as a siding). Group detection needs the lanes to stay road up to the crossing.
        for i = 1, closest do
            local n = ch[i]
            skeleton[n.id] = true
            if owner[n.id] == nil then
                owner[n.id] = ai
            else
                local a, b = findGroup(ai), findGroup(owner[n.id])
                if a ~= b then groupOf[a] = b end
            end
            if i > 1 then roadLink[linkKey(ch[i - 1].id, n.id)] = true end
        end
        -- THE RUN: from the anchor in to the LAST node that forks before the closest approach. A
        -- plain road node has exactly two distinct neighbours; one with three is a tie node, where
        -- something joins the lane. The walk can only have left the road onto a connector AT a fork,
        -- so everything up to the last one is road it stayed on, and only past that can it be tail.
        -- Structural, so there is no distance to tune and nothing that moves with the search radius.
        --
        -- The first fork is the wrong boundary even though it sounds safer: kickouts are laid to
        -- start early and end late deliberately, so their tie nodes sit 16-29 m out, and stopping
        -- there hands the sweep most of the lane again - the very thing this is here to prevent.
        --
        -- The crossing's extent sweep spares these, which is what stops a clear eating a T's stem.
        -- Whatever it does take past the last fork is wiring or tail, and the lane-end tidy trims the
        -- run back to the gap afterwards.
        local runEnd = 1
        for i = 2, closest do
            local n = ch[i]
            local seen, deg = {}, 0
            for _, lst in ipairs({ n.out or {}, n.incoming or {} }) do
                for _, nid in pairs(lst) do
                    if not seen[nid] then seen[nid] = true deg = deg + 1 end
                end
            end
            if deg >= 3 then runEnd = i end
        end
        if runEnd == 1 then runEnd = closest end
        -- By id for the extent sweep, which runs before anything is deleted; by OBJECT for the
        -- lane-end tidy, which runs after - removeWayPoint renumbers every id above the one it
        -- takes, so an id held across a deletion quietly comes to mean a different node.
        for i = 1, runEnd do
            runNode[ch[i].id] = true
            runNodeOf[ch[i]] = true
        end
    end
    -- The debris sweep reaches a third PAST the scope circle (for old arcs that bulge out), so the
    -- roads in that ring need skeleton protection too - without this, every road node just outside
    -- the circle was reachable-from-the-junction, off-skeleton, and got swept: placements were eating
    -- the roads AROUND the junction. Each approach's road is walked OUTWARD from its boundary node
    -- (an entry upstream, an exit downstream, bearing-continuous) out to the sweep's own reach, and
    -- those nodes and links are marked road exactly like the inside ones.
    if rebuildOn then
        local reach2 = (R * 1.3) ^ 2
        for ai, ap in ipairs(approaches) do
            local useOut = (ap.dir == "out")
            local wdx, wdz = math.sin(ap.bearing), math.cos(ap.bearing)
            if not useOut then wdx, wdz = -wdx, -wdz end
            local node, cameFrom = ap.wp, nil
            for _ = 1, math.ceil(R) do
                local list = useOut and (node.out or {}) or (node.incoming or {})
                local nextId, bestDot = nil, -math.huge
                for _, nid in pairs(list) do
                    if nid ~= cameFrom then
                        local nx = ADGraphManager:getWayPointById(nid)
                        if nx ~= nil and (nx.x - cx) ^ 2 + (nx.z - cz) ^ 2 <= reach2 then
                            local dx, dz = nx.x - node.x, nx.z - node.z
                            local l = math.sqrt(dx * dx + dz * dz)
                            if l > 1e-6 then
                                local dot = (dx / l) * wdx + (dz / l) * wdz
                                if dot > bestDot then bestDot, nextId = dot, nid end
                            end
                        end
                    end
                end
                if nextId == nil then break end
                local nxt = ADGraphManager:getWayPointById(nextId)
                roadLink[linkKey(node.id, nxt.id)] = true
                cameFrom = node.id
                local dx, dz = nxt.x - node.x, nxt.z - node.z
                local l = math.sqrt(dx * dx + dz * dz)
                if l > 1e-6 then wdx, wdz = dx / l, dz / l end
                node = nxt
                skeleton[node.id] = true
            end
        end
    end

    -- Rebuild's DEBRIS set: every inside node that is wired to the junction (reachable from the road
    -- skeleton along inside links, either direction) but is not itself road. Per-movement old-path
    -- deletion missed plenty - duplicate old connectors, connectors of pairs the current matrix
    -- refuses, anything the single BFS path did not happen to run through. The complement of the
    -- skeleton is the honest definition of "old junction wiring": rebuild clears ALL of it and lays
    -- the fresh set. Roads (and anything crossing the scope circle, which becomes an approach and so
    -- skeleton) are untouchable by construction.
    -- WHAT MUST SURVIVE A CLEAR: the nodes carrying a route that currently runs THROUGH this junction.
    --
    -- This replaces classifying each debris cluster by bearing. That approach kept finding new ways to
    -- be wrong, because it asked an indirect question ("do these two lane groups point the same way?")
    -- whose inputs were unstable - first the choice of representative approach for a merged group
    -- (flapped 13 -> 82 -> 79 deg for one connector across near-identical locks), then the composition
    -- of the clusters themselves, which changes after a clear renumbers ids, so a second pass over the
    -- same junction classified differently and deleted the through road it had just spared.
    --
    -- The property actually wanted is connectivity: do not sever a road that currently runs through
    -- here. So ask that directly. For every entry->exit approach pair whose bearings are within 40 deg
    -- of each other (the same straight-on test the U-turn filter uses from the other end, and measured
    -- per MOVEMENT on the approaches' own bearings - no representative to pick, nothing to go stale),
    -- take the route that currently connects them and protect every node on it. A cluster holding any
    -- protected node is through wiring and is spared whole.
    --
    -- Erring: a cluster that mixes a through route with turn wiring is spared ENTIRELY. That leaves
    -- some turn wiring behind, which is the safe direction to be wrong in - leftover connectors can be
    -- cleared by hand, a severed road cannot be un-severed without rebuilding it.
    local protectedNodes = {}
    local protectedOf = {}   -- the same set by object, for anything that runs after a deletion
    if clearMode then
        -- Traced whichever way the toggle is set, because the routes are also what the PARENT ROADS
        -- are read from (see roadLine below). They are only PROTECTED when they are being kept.
        local keepThrough = self.junctionLeaveThrough ~= false
        local nProtected, nRoutes = 0, 0
        -- WHICH LANES RUN THROUGH, AND OVER WHAT.
        --
        -- First by the lanes themselves: an entry whose own walk - bearing-continuous, never taking
        -- a way on that turns away - arrives at an exit's anchor IS that exit's lane, and the walk
        -- is the route. Nothing is measured, so nothing can be measured in the wrong place.
        --
        -- The bearing test below it is the older rule and only decides lanes the walks could not
        -- pair. On its own it compares the two bearings where the SEARCH CIRCLE cuts each track,
        -- and a road that bends just outside a junction is cut inside its bend: one through lane
        -- read 120 degrees there against its own exit's 56, was refused as a through route, and
        -- was matched instead with the side road's exit at 146 - a right turn, 26 degrees "off
        -- straight". That turn connector then counted as the lane's parent road: its line bent the
        -- side road's claim round the corner, and with through paths kept it was protected.
        local routes, paired = {}, {}
        -- A SIDE ROAD DOES NOT GET THE MAIN ROAD'S EXIT. At a skewed T the side road's turn bends
        -- only 30 degrees, so its walk runs on down the main road and reaches the main exit's
        -- anchor just as the main entry's does. It is refused when the two headings, taken far out
        -- at the anchors, differ by more than 20 degrees AND some other free entry lines up with
        -- that exit better. A main road that itself bends has no such rival and keeps its exit.
        local function sameRoad(e, x)
            local mine = junctionAngDiff(e.chainBearing or e.bearing, x.chainBearing or x.bearing)
            if mine <= math.rad(20) then return true end
            for _, e2 in ipairs(approaches) do
                if e2.dir == "in" and e2 ~= e and not paired[e2]
                    and junctionAngDiff(e2.chainBearing or e2.bearing, x.chainBearing or x.bearing) < mine - math.rad(5) then
                    return false
                end
            end
            return true
        end
        for _, e in ipairs(approaches) do
            if e.dir == "in" then
                local ch = self:junctionChain(e, cx, cz, R)
                for _, x in ipairs(approaches) do
                    if x.dir == "out" and x.wp.id ~= e.wp.id and not paired[x] then
                        for i, n in ipairs(ch) do
                            if n == x.wp and sameRoad(e, x) then
                                local path = {}
                                for k = 1, i do path[k] = ch[k].id end
                                routes[#routes + 1] = { e = e, x = x, path = path, ang = 0 }
                                paired[e], paired[x] = true, true
                                break
                            end
                        end
                    end
                end
            end
        end
        -- The same from the exit's side: its walk runs upstream, so the route is that walk reversed.
        for _, x in ipairs(approaches) do
            if x.dir == "out" and not paired[x] then
                local ch = self:junctionChain(x, cx, cz, R)
                for _, e in ipairs(approaches) do
                    if e.dir == "in" and e.wp.id ~= x.wp.id and not paired[e] and not paired[x] then
                        for i, n in ipairs(ch) do
                            if n == e.wp and sameRoad(e, x) then
                                local path = {}
                                for k = i, 1, -1 do path[#path + 1] = ch[k].id end
                                routes[#routes + 1] = { e = e, x = x, path = path, ang = 0 }
                                paired[e], paired[x] = true, true
                                break
                            end
                        end
                    end
                end
            end
        end
        for _, e in ipairs(approaches) do
            if e.dir == "in" and not paired[e] then
                for _, x in ipairs(approaches) do
                    if x.dir == "out" and x.wp.id ~= e.wp.id and not paired[x]
                        and junctionAngDiff(e.bearing, x.bearing) < math.rad(40) then
                        local connected, path = connectedInside(e.wp.id, x.wp.id)
                        if connected and path ~= nil then
                            routes[#routes + 1] = { e = e, x = x, path = path,
                                ang = junctionAngDiff(e.bearing, x.bearing) }
                        end
                    end
                end
            end
        end
        -- THE SAME-ROAD RULE. A route is a THROUGH route only if it joins the two ends of ONE road,
        -- and a road has two ends: each arm of the junction pairs with at most one other arm. Judging
        -- lane against lane by bearing let one arm be "through" to two others at once - where the main
        -- road bends through a T, the side road lines up with the far arm nearly as well as the main
        -- road does, so a right turn counted as a through path, a T read as a Y, and the turn was
        -- protected with through paths on and the wrong links cut with them off. So the ARMS are
        -- paired first - best continuation first, each arm used once - and a lane route only counts
        -- when its two arms are partners.
        if AutoDrive.FLYOVER_JUNCTION_SAME_ROAD ~= false then
            local arms = {}
            local function outward(ap)
                local b = ap.chainBearing or ap.bearing
                if ap.dir == "in" then b = b + math.pi end
                return b
            end
            -- AN ARM IS A PLACE AS WELL AS A HEADING. Lanes were grouped by which way they head at their
            -- anchor, 60 m out - and on an S-bend both ends of the main road can be heading the same
            -- way that far out. At 50 (by the registry) the north-east and south arms both headed east,
            -- were taken for one arm, and the only pairing left was the WEST road with that lump: the
            -- side road became the main road. So lanes share an arm only when they also lie the same
            -- way from the centre.
            local function placeOf(ap) return math.atan2(ap.wp.x - cx, ap.wp.z - cz) end
            local armOf = {}
            -- ONE LANE EACH WAY PER ARM. Two lanes going the same way, not folded together and lying
            -- in different directions from the centre, are two roads (see the fold above) - at 53's tight Y the east and
            -- south-east branches lay within 35 degrees of each other 60 m out and were lumped into
            -- one arm, so the west road could only be paired with the lump. And a lane joins the arm
            -- it matches most closely, not the first that will take it.
            for _, ap in ipairs(approaches) do
                local b, hit, hd = outward(ap), nil, math.huge
                for _, a in ipairs(arms) do
                    local dp = junctionAngDiff(placeOf(ap), a.p)
                    if junctionAngDiff(b, a.b) <= math.rad(35) and dp <= math.rad(35) and dp < hd then
                        -- (a second lane the same way in the same PLACE is the same road's parallel
                        -- lane, just too far apart to have been folded - 30's north-west road)
                        local sameWay = false
                        for _, m in ipairs(a.members or {}) do
                            if m.dir == ap.dir and junctionAngDiff(placeOf(ap), placeOf(m)) > math.rad(10) then
                                sameWay = true
                                break
                            end
                        end
                        if not sameWay then hit, hd = a, dp end
                    end
                end
                if hit == nil then
                    hit = { b = b, p = placeOf(ap), sx = 0, sz = 0 }
                    arms[#arms + 1] = hit
                end
                hit.sx, hit.sz = hit.sx + math.sin(b), hit.sz + math.cos(b)
                hit.b = math.atan2(hit.sx, hit.sz)
                hit.members = hit.members or {}
                hit.members[#hit.members + 1] = ap
                armOf[ap] = hit
            end
            -- PAIRED ON THE LANES' OWN EVIDENCE, NOT ON HOW STRAIGHT THE ARMS LOOK. A main road can
            -- bend 53 degrees through a T while its side road runs nearly dead straight into the far
            -- arm; pairing by straightness there gave the side road the main road's partner and
            -- threw the real through routes away. What says two arms are one road is that lanes RUN
            -- between them - the walks that pair an entry with an exit without ever turning away -
            -- and the more of them, and in both directions, the surer. Straightness only settles a
            -- tie.
            -- A TIE IS SETTLED BY THE TURN AT THE JUNCTION, not by how straight the arms look 60 m
            -- out. A real road passes through; a turn has a kink there. On 50's S-bend (by the
            -- registry) both ends of the main road head the same way 60 m out, so the main road looked
            -- like a U-turn and lost to the side road. Straightness far out is only the last resort.
            local function sharpest(rt)
                -- The turn AT the junction: heading over the ~8 m before the point nearest the centre
                -- against the ~8 m after it. A road's own bend further out is not a turn - at 22 (by
                -- the registry) a hairpin 15 m from the centre made the real road look like the sharp
                -- one when this looked anywhere within 30 m.
                local pts = {}
                for _, id in ipairs(rt.path or {}) do
                    local w = ADGraphManager:getWayPointById(id)
                    if w ~= nil then pts[#pts + 1] = w end
                end
                if #pts < 3 then return 0 end
                local k, kd = 1, math.huge
                for i, w in ipairs(pts) do
                    local d = (w.x - cx) ^ 2 + (w.z - cz) ^ 2
                    if d < kd then kd, k = d, i end
                end
                local function reach(step)
                    local i, run = k, 0
                    while i + step >= 1 and i + step <= #pts and run < 8 do
                        run = run + math.sqrt((pts[i + step].x - pts[i].x) ^ 2 + (pts[i + step].z - pts[i].z) ^ 2)
                        i = i + step
                    end
                    return pts[i]
                end
                local a, b = reach(-1), reach(1)
                local m = pts[k]
                if a == m or b == m then
                    a, b = pts[1], pts[#pts]
                end
                local h1 = math.atan2(m.x - a.x, m.z - a.z)
                local h2 = math.atan2(b.x - m.x, b.z - m.z)
                if a == m or b == m then return 0 end
                return junctionAngDiff(h1, h2)
            end
            local cand = {}
            for i = 1, #arms do
                for j = i + 1, #arms do
                    local walks, other, sharp = 0, 0, math.huge
                    for _, rt in ipairs(routes) do
                        local ae, ax = armOf[rt.e], armOf[rt.x]
                        if (ae == arms[i] and ax == arms[j]) or (ae == arms[j] and ax == arms[i]) then
                            if (rt.ang or 0) == 0 then walks = walks + 1 else other = other + 1 end
                            sharp = math.min(sharp, sharpest(rt))
                        end
                    end
                    if walks + other > 0 then
                        cand[#cand + 1] = { a = arms[i], b = arms[j], score = walks * 10 + other, sharp = sharp,
                            dev = math.abs(math.pi - junctionAngDiff(arms[i].b, arms[j].b)) }
                    end
                end
            end
            -- A SINGLE-LANE ROAD IS NOT THE MAIN ROAD when two two-lane roads meet at the junction:
            -- the main road can turn the corner while a single lane carries straight on (24 and 31
            -- by the registry). An arm is single-lane when all its lane ends sit on one spot and none
            -- stands for several folded lanes.
            local function singleLane(arm)
                local a0 = arm.members[1].selWp or arm.members[1].wp
                for _, ap in ipairs(arm.members) do
                    local w = ap.selWp or ap.wp
                    if (ap.count or 1) > 1 or (w.x - a0.x) ^ 2 + (w.z - a0.z) ^ 2 > 1.5 * 1.5 then return false end
                end
                return true
            end
            local twoLane = 0
            for _, arm in ipairs(arms) do
                arm.single = singleLane(arm)
                if not arm.single then twoLane = twoLane + 1 end
            end
            local anyFull = false
            for _, c in ipairs(cand) do
                c.full = not c.a.single and not c.b.single
                if c.full then anyFull = true end
            end
            -- ...AND THE MAIN ROAD MAY TURN THE CORNER. Candidates above only come from lanes that run
            -- nearly straight through, so a main road turning 90 degrees was never one (24 and 31:
            -- the only straight candidates ran out along the single lane). With exactly two two-lane
            -- arms and no candidate between them, they are the main road, over the lanes that join
            -- them inside the junction.
            if not anyFull and twoLane == 2 then
                local A, B = nil, nil
                for _, arm in ipairs(arms) do
                    if not arm.single then
                        if A == nil then A = arm else B = arm end
                    end
                end
                local added = 0
                for _, e in ipairs(approaches) do
                    if e.dir == "in" and (armOf[e] == A or armOf[e] == B) then
                        local other = (armOf[e] == A) and B or A
                        for _, x in ipairs(approaches) do
                            if x.dir == "out" and armOf[x] == other then
                                local connected, path = connectedInside(e.wp.id, x.wp.id)
                                if connected and path ~= nil then
                                    routes[#routes + 1] = { e = e, x = x, path = path, ang = junctionAngDiff(e.bearing, x.bearing) }
                                    added = added + 1
                                    break
                                end
                            end
                        end
                    end
                end
                if added > 0 then
                    cand[#cand + 1] = { a = A, b = B, score = added, sharp = 0, dev = 0, full = true }
                    anyFull = true
                    ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - a single-lane road carries straight on; the two two-lane roads are the main road, turning the corner (%d lane(s)).", added)
                end
            end
            table.sort(cand, function(p, q)
                if anyFull and twoLane >= 2 and p.full ~= q.full then return p.full end
                if p.score ~= q.score then return p.score > q.score end
                if math.abs(p.sharp - q.sharp) > math.rad(10) then return p.sharp < q.sharp end
                return p.dev < q.dev
            end)
            for _, c in ipairs(cand) do
                if c.a.partner == nil and c.b.partner == nil then c.a.partner, c.b.partner = c.b, c.a end
            end
            if AutoDrive.FLYOVER_JUNCTION_TRIM_DEBUG then
                for i, a in ipairs(arms) do
                    Logging.info("[FlyoverEditor]: ARM %d outward %.0f deg, partner %s", i, math.deg(a.b) % 360,
                        a.partner and string.format("%.0f deg", math.deg(a.partner.b) % 360) or "none")
                end
                for _, rt in ipairs(routes) do
                    Logging.info("[FlyoverEditor]: ROUTE in-arm %.0f -> out-arm %.0f", math.deg(armOf[rt.e].b) % 360, math.deg(armOf[rt.x].b) % 360)
                end
            end
            local kept = {}
            for _, rt in ipairs(routes) do
                local ae, ax = armOf[rt.e], armOf[rt.x]
                if ae ~= nil and ax ~= nil and ae ~= ax and ae.partner == ax then kept[#kept + 1] = rt end
            end
            -- A MAIN-ROAD LANE LEFT WITHOUT A ROUTE GETS ONE. A lane's own walk can take the wrong way
            -- at a shallow fork: at 35 (by the registry) the south-east-bound lane followed the branch
            -- instead of the straight road, that pairing was dropped once the straight road was chosen
            -- as the main road, and the lane was left with no through route - trimmed like a side
            -- road. Once the arms are partnered, an entry with nothing kept is paired with a free exit
            -- on its partner arm, if the two are joined inside the junction.
            local usedE, usedX = {}, {}
            for _, rt in ipairs(kept) do usedE[rt.e], usedX[rt.x] = true, true end
            for _, e in ipairs(approaches) do
                local pa = armOf[e] and armOf[e].partner
                if e.dir == "in" and not usedE[e] and pa ~= nil then
                    for _, x in ipairs(approaches) do
                        if x.dir == "out" and not usedX[x] and armOf[x] == pa and x.wp.id ~= e.wp.id then
                            local connected, path = connectedInside(e.wp.id, x.wp.id)
                            if connected and path ~= nil then
                                kept[#kept + 1] = { e = e, x = x, path = path, ang = junctionAngDiff(e.bearing, x.bearing) }
                                usedE[e], usedX[x] = true, true
                                ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - lane id=%d had no through route after the arms were paired; joined to exit id=%d on the main road's far arm.",
                                    e.wp.id, x.wp.id)
                                break
                            end
                        end
                    end
                end
            end
            -- ...AND SO DOES ONE WHOSE PARTNER ARM HAS NO EXIT AT ALL. At 65 the main road's outbound
            -- lane bends round a loop just outside the junction, so where its end is read it heads
            -- 60 degrees away from its partner lane and became an arm of its own, with no partner.
            -- The lane coming in then had nowhere to go on its partner arm, was left with no through
            -- route, and the clear took its middle out with through roads kept. Its own walk is still
            -- the road: the straightest of its traced routes is kept when the exit is free, on an arm
            -- with no partner, and leaves on the same side of the junction as the partner arm. A
            -- main road with both lanes found never gets here, as its partner arm has an exit.
            for _, e in ipairs(approaches) do
                local pa = armOf[e] and armOf[e].partner
                if e.dir == "in" and not usedE[e] and pa ~= nil then
                    local anyExit = false
                    for _, m in ipairs(pa.members or {}) do
                        if m.dir == "out" then anyExit = true end
                    end
                    if not anyExit then
                        local best = nil
                        for _, rt in ipairs(routes) do
                            local ax = armOf[rt.x]
                            if rt.e == e and not usedX[rt.x] and ax ~= nil and ax.partner == nil
                                and junctionAngDiff(placeOf(rt.x), pa.p) <= math.rad(35)
                                and (best == nil or (rt.ang or 0) < (best.ang or 0)) then
                                best = rt
                            end
                        end
                        if best ~= nil then
                            kept[#kept + 1] = best
                            usedE[e], usedX[best.x] = true, true
                            ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - lane id=%d had no exit on its partner arm; kept its own route to exit id=%d, which bends away on the same side.",
                                e.wp.id, best.x.wp.id)
                        end
                    end
                end
            end
            routes = kept
        end
        -- A LANE FROM THIS PART'S SIDE ROAD TO ANOTHER PART'S IS A CONNECTOR, NOT A THROUGH ROAD.
        -- Where the user has split a junction, two parts can sit on one main road with their side
        -- roads across it from each other, a few metres apart: a staggered crossing. A lane can then
        -- run from one part's side road straight across the main road and on down the other part's
        -- side road, and the arms pairing above reads the two side roads as one road through this
        -- part. At j39 the north road's southbound lane ran on across the main road into the south-
        -- west road, which is 39se's side road; it was kept as j39's through road, and the user, who
        -- cleared j39 with through roads kept, failed it: "a connector, not a through road". So with
        -- a split saved, a route both of whose lanes end near here, one at this part and the other
        -- at another part of the same junction, is dropped from the through roads: its points are
        -- then turn wiring like any other, taken or left by the clear's usual rules. What lies in the
        -- other part's area is left to that part - its cluster joins that part's side road, so it is
        -- that part's wiring (foreignWiring) - and stays wired where it leaves the kept main road, so
        -- the other part's turn off the main road still drives. This part's own lane on the far side
        -- is then a side road, cut at the box like any other. With through roads not kept the main
        -- road is cut at the box, and a turn of the other part's that leaves it inside the box loses
        -- the point it left from, as it did before this rule (at j39, 39se's right turn: the check says
        -- its end, from (12.5, -4.4), as the end of a turn the clear cut). What a part's clear leaves of
        -- the other parts' wiring is not settled yet; this rule only stops the side-to-side lane being
        -- kept as a through road.
        -- Where a lane ends is the crossing its tip is nearest (laneTipOf); that crossing is this
        -- part when it is the locked one, and another part when the saved part nearest it is another
        -- one of this junction's, within JX_PART_NEAR. Only for a split the user saved: a junction kept
        -- whole as one staggered crossroads (30) keeps its side-to-side lanes as through roads, and
        -- an undecided one is treated as whole until the user says otherwise. In both through-road
        -- settings: a connector is not a through road either way, and with through roads off the
        -- tidy would otherwise re-lay the other part's piece as this part's road.
        -- AutoDrive.FLYOVER_JUNCTION_PART_CONNECTORS = false turns this off, for the harness only: it
        -- shows what the clear and its check did before (tools/junction-harness, README).
        if clearMode and lockedCrossing ~= nil and #routes > 0 and AutoDrive.FLYOVER_JUNCTION_PART_CONNECTORS ~= false then
            -- Read under pcall: the numbering reads the savegame's file, and a fault there must not
            -- stop the clear - the rule is then simply not applied, as on a junction not split.
            local herePart, entry = nil, nil
            local okName, _, _, part = pcall(self.junctionNameAt, self, cx, cz, false)
            if okName then herePart = part end
            if herePart ~= nil then
                local okEntry, f = pcall(self.junctionEntryAt, self, cx, cz)
                if okEntry then entry = f end
            end
            if entry ~= nil and entry.decision == "split" and entry.parts ~= nil then
                -- Which part a lane ends at: "here", another saved part, or nil when it runs on (no
                -- tip) or its crossing is no part's.
                local function endsAt(ap)
                    local tip = laneTipOf[apIndex[ap]]
                    if tip == nil then return nil end
                    local c, cd = nil, math.huge
                    for _, k in ipairs(crossings) do
                        local d = (tip.x - k.x) ^ 2 + (tip.z - k.z) ^ 2
                        if d < cd then cd, c = d, k end
                    end
                    if c == nil then return nil end
                    if c == lockedCrossing then return "here" end
                    local p, pd = nil, JX_PART_NEAR * JX_PART_NEAR
                    for _, sp in ipairs(entry.parts) do
                        local d = (c.x - sp.x) ^ 2 + (c.z - sp.z) ^ 2
                        if d < pd then pd, p = d, sp end
                    end
                    if p ~= nil and p ~= herePart then return p end
                    return nil
                end
                local through = {}
                for _, rt in ipairs(routes) do
                    local a, b = endsAt(rt.e), endsAt(rt.x)
                    local other = nil
                    if a == "here" and type(b) == "table" then other = b
                    elseif b == "here" and type(a) == "table" then other = a end
                    if other ~= nil then
                        if logSite2 then
                            roadNote(string.format("clearConnector:%d:%d", rt.e.wp.id, rt.x.wp.id),
                                "junction clear - the lane in at %.1f, %.1f runs across the main road to the side road of j%02d%s (out at %.1f, %.1f): a connector between two parts of a split junction, not a through road here - cleared as turn wiring.",
                                rt.e.wp.x, rt.e.wp.z, entry.n, other.letter or "", rt.x.wp.x, rt.x.wp.z)
                        end
                    else
                        through[#through + 1] = rt
                    end
                end
                routes = through
            end
        end
        self._jxRoutes = routes
        for _, rt in ipairs(routes) do
            local e, x, path, ang = rt.e, rt.x, rt.path, rt.ang
            -- The straightest route each lane takes part in is that lane's road.
            if e.throughAng == nil or ang < e.throughAng then e.throughAng, e.throughPath = ang, path end
            if x.throughAng == nil or ang < x.throughAng then x.throughAng, x.throughPath = ang, path end
            if keepThrough then
                nRoutes = nRoutes + 1
                for _, pid in ipairs(path) do
                    if not protectedNodes[pid] then
                        protectedNodes[pid] = true
                        local pw = inside[pid] or ADGraphManager:getWayPointById(pid)
                        if pw ~= nil then protectedOf[pw] = true end
                        nProtected = nProtected + 1
                    end
                end
            end
        end
        if logSite2 and keepThrough then
            roadNote(string.format("clearProtect:%d:%d", math.floor(cx * 2), math.floor(cz * 2)),
                "junction clear - %d through route(s) run through this site; %d point(s) on them are protected from clearing.",
                nRoutes, nProtected)
        end
        -- THE PARENT ROAD, AS IT ACTUALLY RUNS. A road that goes through the junction is real
        -- geometry right across it, so its line is simply its own through route - positions copied
        -- now, before the clear removes any of it. Nothing is extrapolated: carrying a road across a
        -- junction on a fitted arc put the box in the wrong place wherever the road bends near the
        -- middle, and reading it off the lane's tip picked up old tie-in kinks instead. Only a road
        -- that ENDS here - a T's stem - has no through route, and the tidy carries that one across.
        for _, ap in ipairs(approaches) do
            ap.roadLine = nil
            if ap.throughPath ~= nil then
                local line = {}
                for _, pid in ipairs(ap.throughPath) do
                    local pw = inside[pid] or ADGraphManager:getWayPointById(pid)
                    if pw ~= nil and (pw.x - cx) ^ 2 + (pw.z - cz) ^ 2 <= 60 * 60 then
                        line[#line + 1] = { x = pw.x, z = pw.z }
                    end
                end
                if #line >= 3 then ap.roadLine = line end
            end
            ap.throughAng, ap.throughPath = nil, nil
        end
    end
    -- OWNERSHIP FOR CLEARING is wider than `isOwn` (search circle + 5 m). The tool lays wiring for one
    -- junction out to runReach - a tie-in at ~1.5 turn radii plus a kickout's late tail - which is
    -- routinely 35-40 m from the middle, far outside a 15 m scope circle. Judging that wiring by the
    -- circle meant the tool built connectors it then refused to recognise as its own, and they survived
    -- every clear ("5 point(s) ... nearest 25.1 m ... no node inside the search circle + tolerance").
    -- The tight `isOwn` stays in use for run-following, where it is what stops a run walking into the
    -- junction next door.
    -- OWNERSHIP FOR CLEARING, by NEAREST CROSSING rather than by any radius.
    --
    -- A radius cannot answer "which junction does this wiring belong to". Tried at the lay reach
    -- (45 m) it destroyed the junction 20 m away; tried at the search circle it destroyed it AND broke
    -- group detection; tried at 12 m it was safe but cleared only a fifth of a junction locked dead
    -- centre. Same knob, three wrong answers, because the right question is not "how far" but "closer
    -- to WHICH crossing".
    --
    -- Fallback only if the region somehow holds no crossing at all: the old core radius.
    -- With no wheel, this is no longer the user dialling a clear down: ownership (nearest crossing,
    -- and whose side road the wiring joins) is what keeps a clear off its neighbour, and this only
    -- decides how far out the junction's OWN wiring is followed. Held back to the wheel's old value
    -- it left tails behind that then read as loose points once the box was emptied.
    local clearReach = math.max(12, selectR)
    -- WHERE THE JUNCTION WAS FOUND FROM ITS ROADS, OWNERSHIP IS THE WHOLE TEST. This radius was the
    -- last distance gate on a junction's OWN wiring: a kickout that leaves the through lane 14 m
    -- back belonged to the junction, lay within reach, and was refused for starting 2 m outside a
    -- 12 m circle - with a message telling the user to turn a wheel that clear mode ignores. Whose
    -- wiring it is now comes from where the roads meet, and what may be deleted is bounded arm by
    -- arm at the gate, so the circle has nothing left to decide.
    if clearMode and self.junctionSite ~= nil and self.junctionSite.fromRoads then
        clearReach = math.max(clearReach, runReach)
    end
    local coreR = math.max(8, selectR * 0.6)
    local function crossingOf(wp)
        local best, bestC = math.huge, nil
        for _, c in ipairs(crossings) do
            local d = (wp.x - c.x) ^ 2 + (wp.z - c.z) ^ 2
            if d < best then best, bestC = d, c end
        end
        return bestC
    end
    -- A FRAGMENT OF THIS JUNCTION IS NOT ANOTHER JUNCTION.
    --
    -- Crossings are clusters of fork nodes, and a junction this tool built has forks all over it:
    -- tie nodes 5 m out on the side road, 15 m out on the main road, 25 m out where a kickout ends.
    -- The clustering is deliberately tight so that two junctions 18 m apart stay two - and the
    -- price was that ONE junction regularly came back as two or three. Everything nearer the
    -- "other" crossing was then left to it: at one T the two connectors on its west side were
    -- refused as "nearer another crossing" - which was that junction's own pair of tie nodes 13 m
    -- from its other four.
    --
    -- What makes a crossing a junction in its own right is a road of its own: wiring that joins
    -- these lanes AND runs on out of the region along something that is not one of them. A crossing
    -- whose wiring is all CLOSED - every cluster attached to it begins and ends on this junction's
    -- own lanes - has no such road. It is part of this junction, however far its forks sit from
    -- the rest. (A driveway or a siding beside it does not count against it: that touches one lane
    -- only, is never cleared whoever owns it, and needs no protecting.)
    --
    -- One more thing makes a junction: a road that ENDS at it. Two T's 18 m apart on the same main
    -- road can both fall inside the search circle, and then the neighbour's side road is one of
    -- these lanes too and all its wiring reads as closed. But its side road ends THERE and this
    -- junction's ends HERE, and one junction does not have side roads ending in two places - so
    -- where both crossings have lanes ending at them, they stay two.
    if clearMode and lockedCrossing ~= nil and #crossings > 1 then
        local attached = {}
        local function note(c, open2)
            if c == nil then return end
            local a = attached[c]
            if a == nil then a = { closed = 0, open = 0 } attached[c] = a end
            if open2 then a.open = a.open + 1 else a.closed = a.closed + 1 end
        end
        local reach2 = runReach * runReach
        local seenF = {}
        for id in jxByPlace(skeleton) do
            local w = inside[id] or ADGraphManager:getWayPointById(id)
            if w ~= nil then
                for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
                    for _, startId in pairs(lst) do
                        if not skeleton[startId] and not seenF[startId] and inside[startId] ~= nil then
                            local open, count = false, 0
                            local touched, groups, nGroups = {}, {}, 0
                            local stack = { startId }
                            seenF[startId] = true
                            while #stack > 0 do
                                local cid = table.remove(stack)
                                local cw = inside[cid]
                                count = count + 1
                                if count > 400 then open = true end
                                touched[crossingOf(cw) or false] = true
                                for _, clst in ipairs({ cw.out or {}, cw.incoming or {} }) do
                                    for _, x in pairs(clst) do
                                        if skeleton[x] then
                                            local sw = inside[x] or ADGraphManager:getWayPointById(x)
                                            if sw ~= nil then touched[crossingOf(sw) or false] = true end
                                            local g = owner[x] and findGroup(owner[x]) or nil
                                            if g ~= nil and not groups[g] then groups[g] = true nGroups = nGroups + 1 end
                                        elseif inside[x] == nil then
                                            open = true
                                        elseif (inside[x].x - cx) ^ 2 + (inside[x].z - cz) ^ 2 > reach2 then
                                            open = true
                                        elseif not seenF[x] then
                                            seenF[x] = true
                                            stack[#stack + 1] = x
                                        end
                                    end
                                end
                            end
                            -- Only wiring that joins two of these lanes says anything about whose
                            -- junction this is; a spur off one lane is nobody's.
                            if nGroups >= 2 then
                                for c in pairs(touched) do
                                    if c ~= false then note(c, open) end
                                end
                            end
                        end
                    end
                end
            end
        end
        local endsAt = {}
        for _, t in ipairs(laneTips) do
            local c = crossingOf(t)
            if c ~= nil then endsAt[c] = true end
        end
        local nMerged = 0
        for _, c in ipairs(crossings) do
            local a = attached[c]
            if c ~= lockedCrossing and a ~= nil and a.open == 0 and a.closed > 0
                and not (endsAt[c] and endsAt[lockedCrossing]) then
                c.partOfLocked = true
                nMerged = nMerged + 1
            end
        end
        if nMerged > 0 then
            -- The junction's middle is the middle of ALL its forks, not of whichever handful the
            -- clustering happened to start from.
            local sx, sz, n = lockedCrossing.x * lockedCrossing.n, lockedCrossing.z * lockedCrossing.n, lockedCrossing.n
            for _, c in ipairs(crossings) do
                if c.partOfLocked then sx, sz, n = sx + c.x * c.n, sz + c.z * c.n, n + c.n end
            end
            lockedCrossing.mergedX, lockedCrossing.mergedZ = sx / n, sz / n
            if logSite2 then
                roadNote(string.format("clearMerged:%d:%d", math.floor(cx * 2), math.floor(cz * 2)),
                    "junction clear - %d of the other crossing(s) are this junction's own tie nodes (all their wiring begins and ends on these lanes) and are cleared with it; its middle is %.1f, %.1f.",
                    nMerged, lockedCrossing.mergedX, lockedCrossing.mergedZ)
            end
        end
    end
    local function isOwnForClear(wp)
        if lockedCrossing == nil then
            return (wp.x - cx) ^ 2 + (wp.z - cz) ^ 2 <= coreR * coreR
        end
        local bestC = crossingOf(wp)
        return bestC == lockedCrossing or (bestC ~= nil and bestC.partOfLocked == true)
    end
    -- WHOSE SIDE ROAD IS IT. A lane that ends near here ends AT a junction, and wiring that joins
    -- that lane to anything is that junction's wiring - all of it, wherever its points happen to
    -- lie. Nearest-crossing alone split such a connector down the middle: a neighbour's wide left
    -- turn, tailing off past the halfway mark between two T's 18 m apart, lost its far end to
    -- whichever of the two was cleared first, and the neighbour lost the movement.
    local groupTip = {}
    -- ...and the crossing a "theirs" side road ends at: whose wiring a cluster joining it is
    -- (foreignOwner, below).
    local groupTipAt = {}
    if lockedCrossing ~= nil then
        -- By approach, in their own (fixed) order: two lanes of one group could disagree, and
        -- then the later one decides.
        for ai = 1, #approaches do
            local tipN = laneTipOf[ai]
            local c = tipN and crossingOf(tipN)
            if c ~= nil then
                groupTip[findGroup(ai)] = (c == lockedCrossing or c.partOfLocked == true) and "ours" or "theirs"
                groupTipAt[findGroup(ai)] = c
            end
        end
    end
    -- Another junction's wiring, by object: nothing later in this clear may take it either.
    local foreignWiring = {}
    -- WHOSE it is: the place (x, z) of the crossing the side road it joins ends at - the same place
    -- that made it another junction's. Read by the clear of a part of a split junction, to name the
    -- part a turn it leaves working belongs to (junctionTwinTurns).
    local foreignOwner = {}
    -- A PIECE OF WIRING IS OWNED AS A PIECE, NOT POINT BY POINT. Nearest-crossing alone hands the
    -- last point or two of another junction's turn to this one wherever that turn swings close,
    -- and taking that point cuts the turn off its lane: the rest then goes as a stub. The
    -- crossing points move with every small change to the forks (folding a doubled point beside
    -- a merge moved one 2.3 m), so whether such a point fell on this side was down to luck - at
    -- 39 a turn of 39se's ran 9 points round a loop to the main road, 8 of them nearer 39se, and
    -- the ninth came out nearer 39 once the fold had moved 39se's crossing. So a point is taken
    -- only when at least half of its piece is this junction's. A piece runs along points with no
    -- fork (two neighbours at most), not on a through route or a run, and stops at anything else
    -- (and at 200 points, as the preview runs every frame). Only ever refuses a point the
    -- nearest-crossing rule would take; it never adds one. Asked only of a point that is not on a
    -- through route or a run itself: the walk never enters those, so a piece started from one would
    -- be that point and whatever turn wiring touches it, and the answer kept for that wiring would
    -- then depend on which of its points was asked first. Used by the cluster pass and by the
    -- extent sweep below, each with its own `cache` of answers: the cluster pass asks while
    -- foreignWiring is still being filled, a cluster at a time, so it keeps its answers for one
    -- cluster only, and they are never the sweep's.
    local function plainNb(p)
        local nb, n = {}, 0
        for _, lst in ipairs({ p.out or {}, p.incoming or {} }) do
            for _, id in ipairs(lst) do
                if id ~= p.id and not nb[id] then nb[id] = true n = n + 1 end
            end
        end
        return nb, n
    end
    local function mostlyOurs(w, cache)
        if cache[w] ~= nil then return cache[w] end
        local piece, seenP, stack = {}, { [w] = true }, { w }
        while #stack > 0 do
            local p = table.remove(stack)
            piece[#piece + 1] = p
            local nb, n = plainNb(p)
            if n <= 2 and #piece < 200 then
                for id in jxByPlace(nb) do
                    local q = inside[id] or ADGraphManager:getWayPointById(id)
                    if q ~= nil and not seenP[q] and not protectedNodes[q.id] and not runNode[q.id] then
                        local _, qn = plainNb(q)
                        if qn <= 2 then
                            seenP[q] = true
                            stack[#stack + 1] = q
                        end
                    end
                end
            end
        end
        local ours = 0
        for _, p in ipairs(piece) do
            if not foreignWiring[p] and isOwnForClear(p) then ours = ours + 1 end
        end
        local ok = ours * 2 >= #piece
        for _, p in ipairs(piece) do cache[p] = ok end
        return ok
    end
    if logSite2 and clearMode then
        roadNote(string.format("clearVoronoi:%d:%d", math.floor(cx * 2), math.floor(cz * 2)),
            "junction clear - %d crossing(s) in the region; clearing the one at %.1f, %.1f (wiring nearer another crossing is left to it).",
            #crossings, lockedCrossing and lockedCrossing.x or cx, lockedCrossing and lockedCrossing.z or cz)
    end
    -- The flood stops at the SAME lay reach. Set wider than this (it was runReach + R) it never binds
    -- before the work-region edge, so a cluster that runs off down an unselected road to the next
    -- junction still 'leaks' and is discarded whole - taking with it the part sitting on this crossing
    -- (measured: 28-node cluster, 18 of them within reach, nearest 19.6 m, all left behind). Stopping
    -- at the reach makes that near part its own cluster, which then qualifies and clears.
    -- Flood boundary: stops a runaway walk down a road, nothing more. Ownership is decided by
    -- nearest crossing (isOwnForClear), not by this.
    local reachR2 = runReach * runReach
    local debris, staleLinks = {}, {}
    -- Split of `debris` by clear mode's through/turn test (see below); declared here so it survives
    -- past the `if rebuildOn` block that fills it.
    local turnDebris, throughDebris = {}, {}
    if rebuildOn then
        -- STRUCTURAL, not a radius flood. The work region is a fixed 60 m - big enough to hold a
        -- neighbouring junction, a siding, a yard entrance - so "everything off the road skeleton
        -- within reach" (the old rule, at 1.3x the search circle) would now eat all of those. Old
        -- junction wiring is instead recognised by what it IS: a connected cluster of off-skeleton
        -- nodes that
        --   * touches road nodes of at least TWO different lane groups (it joins one lane to another
        --     - a siding or a bay hangs off a single lane and is left alone), and
        --   * never LEAKS - no node of it links to anything outside the work region, and it is not
        --     so large that it is plainly a road network rather than a handful of connectors
        --     (a neighbouring junction's connector runs on into that junction's other roads, which
        --     carry on out of the region, so its cluster leaks and is left alone).
        -- Direct road-to-road bridges with no interior node are collected as stale links the same
        -- way: only between nodes of two DIFFERENT groups, never along one lane.
        -- THROUGH vs TURN is decided by CONNECTIVITY, not geometry: a cluster is through wiring iff it
        -- carries part of a route that currently runs through this junction (protectedNodes, computed
        -- above). `debris`/`staleLinks` stay the full set (every existing rebuild caller is
        -- unaffected); `turnDebris`/`throughDebris` split it for clear mode alone.
        local seen, staleSeen = {}, {}
        for id in jxByPlace(skeleton) do
            local w = inside[id] or ADGraphManager:getWayPointById(id)
            if w ~= nil then
                local gHere = owner[id] and findGroup(owner[id]) or nil
                for _, nid in pairs(w.out or {}) do
                    if skeleton[nid] and not roadLink[linkKey(id, nid)] and not staleSeen[linkKey(id, nid)] then
                        local gThere = owner[nid] and findGroup(owner[nid]) or nil
                        local o0 = ADGraphManager:getWayPointById(nid)
                        if gHere ~= nil and gThere ~= nil and gHere ~= gThere
                            and (isOwnForClear(w) or (o0 ~= nil and isOwnForClear(o0))) then
                            staleSeen[linkKey(id, nid)] = true
                            local o = ADGraphManager:getWayPointById(nid)
                            if o ~= nil then
                                -- THROUGH = the two approach bearings point the SAME way (both
                                -- "heading west" through a T, say), not opposite - travel direction
                                -- is recorded at both ends (entry: direction INTO the circle; exit:
                                -- direction OUT of it), so a road running straight across shows near-
                                -- identical bearings at its two ends, and a genuine turn a large one.
                                -- A direct bridge both of whose ends carry a protected through route is
                                -- part of that route: severing it is exactly what must not happen.
                                local isThrough = protectedNodes[id] == true and protectedNodes[nid] == true
                                staleLinks[#staleLinks + 1] = { w, o, isThrough = isThrough }
                            end
                        end
                    end
                end
                for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
                    for _, startId in pairs(lst) do
                        if not skeleton[startId] and not seen[startId] and inside[startId] ~= nil then
                            -- Flood this off-skeleton cluster.
                            local cluster, groups, groupRepAi, groupTouchNode, nGroups, leaks, ours = {}, {}, {}, {}, 0, false, false
                            local nearest = math.huge   -- squared until the flood finishes
                            local ranOn = false         -- the flood was stopped at the lay reach: this is not a closed piece of wiring
                            local stack = { startId }
                            seen[startId] = true
                            while #stack > 0 do
                                local cid = table.remove(stack)
                                local cw = inside[cid]
                                cluster[#cluster + 1] = cw
                                local d2 = (cw.x - cx) ^ 2 + (cw.z - cz) ^ 2
                                if d2 < nearest then nearest = d2 end
                                if #cluster > 400 then leaks = true end
                                if isOwnForClear(cw) then ours = true end
                                for _, clst in ipairs({ cw.out or {}, cw.incoming or {} }) do
                                    for _, x in pairs(clst) do
                                        if skeleton[x] then
                                            local g = owner[x] and findGroup(owner[x]) or nil
                                            if g ~= nil and not groups[g] then
                                                groups[g] = true
                                                groupRepAi[g] = owner[x]
                                                groupTouchNode[g] = x
                                                nGroups = nGroups + 1
                                            end
                                        elseif inside[x] == nil then
                                            leaks = true
                                        elseif (inside[x].x - cx) ^ 2 + (inside[x].z - cz) ^ 2 > reachR2 then
                                            ranOn = true
                                            -- BOUNDARY, not a leak. This tool never lays wiring for one
                                            -- junction further out than runReach (tie-in distance plus a
                                            -- kickout's tail), so anything past that is not ours and the
                                            -- flood simply stops - it does not condemn the whole cluster.
                                            -- Rejecting wholesale is what left connectors behind: an
                                            -- unselected road leaving the site is not skeleton, so the
                                            -- flood walked down it to the NEXT junction, and the 28-node
                                            -- cluster that produced was thrown away along with the four
                                            -- of its nodes that were sitting on this crossing.
                                        elseif not seen[x] then
                                            seen[x] = true
                                            stack[#stack + 1] = x
                                        end
                                    end
                                end
                            end
                            -- OURS: some node of the cluster lies in the search circle (+ tolerance). Wiring
                            -- between two of these runs further up the road - where tracks diverge and
                            -- reconverge, or at the junction next door - never enters the circle and is
                            -- not this rebuild's to clear. A cluster that IS ours goes whole, kickout
                            -- tails beyond the circle included.
                            -- THE SEARCH RADIUS NOW BOUNDS THE CLEAR, not just the selection. It used
                            -- to pick which tracks counted as approaches and nothing more: ownership
                            -- then decided what to take across the whole 60 m work region, so a wheel
                            -- set to 10 still cleared wiring 25 m out and turning it down changed
                            -- nothing. A cluster has to REACH the lock to be this site's to clear.
                            nearest = (nearest < math.huge) and math.sqrt(nearest) or -1
                            -- By its ARMS first: wiring onto a side road belongs to the junction that
                            -- side road ends at. Only wiring between lanes that all run THROUGH is left
                            -- to be shared out by nearest crossing.
                            local armOurs, armTheirs = false, false
                            for g in pairs(groups) do
                                if groupTip[g] == "ours" then armOurs = true
                                elseif groupTip[g] == "theirs" then armTheirs = true end
                            end
                            -- ONLY A CLOSED CLUSTER IS TAKEN WHOLE. "Whole" means every node goes however
                            -- far from this crossing it lies, and that is only safe for something that
                            -- begins and ends on these lanes - a connector. A cluster the flood had to be
                            -- STOPPED in is running on down a road: where a lane's run ends at the next
                            -- junction, the lane beyond that point is nobody's chain, and this junction's
                            -- kickout tail, that stretch of lane, the neighbour's connectors and the
                            -- neighbour's side road all flood together into one cluster. Taken whole, a
                            -- T's clear deleted 15 points of the road and junction 25-34 m up from it.
                            -- Shared out node by node instead, each junction keeps what is nearest it.
                            local whole = false
                            if armTheirs and not armOurs then
                                ours = false
                                -- The crossing its "theirs" side road ends at; of two, the first by place.
                                local at = nil
                                for g in pairs(groups) do
                                    local c = (groupTip[g] == "theirs") and groupTipAt[g] or nil
                                    if c ~= nil and (at == nil or c.x < at.x or (c.x == at.x and c.z < at.z)) then
                                        at = c
                                    end
                                end
                                for _, cw in ipairs(cluster) do
                                    foreignWiring[cw] = true
                                    if at ~= nil then foreignOwner[cw] = { x = at.x, z = at.z } end
                                end
                            elseif armOurs and not armTheirs and not ranOn and not leaks then
                                ours, whole = true, true
                            end
                            if logSite2 and not (not leaks and ours and nGroups >= 2 and nearest <= clearReach) then
                                -- A cluster that DID NOT qualify: log why, once per cluster (keyed by its
                                -- first node, which is stable across re-locks at the same spot). This is
                                -- what a "some connections aren't clearing" report needs - the accepted
                                -- ones are visible as red spheres already, the REJECTED ones are not
                                -- visible at all otherwise.
                                local mx, mz, mcount = 0, 0, 0
                                -- Also: how many of this cluster's nodes are INSIDE the circle, and how
                                -- close the nearest one gets. The average position alone is misleading -
                                -- a cluster stretching from THIS junction out to a neighbour averages to
                                -- somewhere in between and reads as "far away", while its near end is
                                -- sitting right on the crossing the user is trying to clear.
                                local nInside = 0
                                for _, cw in ipairs(cluster) do
                                    mx, mz, mcount = mx + cw.x, mz + cw.z, mcount + 1
                                    if isOwnForClear(cw) then nInside = nInside + 1 end
                                end
                                if mcount > 0 then mx, mz = mx / mcount, mz / mcount end
                                local why
                                if leaks then why = "leaks outside the work region (too large, or wired to something the circle did not select)"
                                elseif armTheirs and not armOurs then why = "it joins a side road that ends at another junction - that junction's wiring; lock onto that one instead"
                                elseif not ours then why = "every node of it is nearer another crossing - it belongs to that junction; lock onto that one instead"
                                elseif nGroups < 2 then why = string.format("touches only %d lane group - looks like a siding or a dead stub, not turn wiring", nGroups)
                                elseif nearest > clearReach then why = string.format("nearest point is %.0f m from the lock, outside the %.0f m search radius - turn the wheel up to take it", nearest, clearReach)
                                else why = "rejected" end
                                roadNote(string.format("clearReject:%d", cluster[1] and cluster[1].id or 0),
                                    "junction clear - %d point(s) near %.1f, %.1f (%d of them within lay reach, nearest %.1f m) NOT cleared: %s.",
                                    #cluster, mx, mz, nInside, nearest, why)
                            end
                            if not leaks and ours and nGroups >= 2 and nearest <= clearReach then
                                -- Protection is PER NODE, not per cluster. Sparing a whole cluster the
                                -- moment any part of it carried a through route was too coarse: once
                                -- the junction's interior is treated as one region (skeleton stops at
                                -- the search circle), its turn wiring and its through wiring are
                                -- frequently the SAME connected cluster, and sparing all of it cleared
                                -- almost nothing. Sparing exactly the nodes that carry a through route
                                -- leaves those routes whole and takes the rest.
                                local nProt = 0
                                for _, cw in ipairs(cluster) do
                                    if protectedNodes[cw.id] then nProt = nProt + 1 end
                                end
                                local diagWhy = string.format("%d group(s), %d of its %d point(s) carry a through route (spared individually)",
                                    nGroups, nProt, #cluster)
                                -- Node level: spare what carries a through route, spare what belongs to
                                -- another crossing, clear the rest. A cluster straddling two junctions
                                -- is therefore split between them instead of going wholly to whichever
                                -- was locked first.
                                --
                                -- OWNERSHIP IS NOT NEGOTIABLE. A node nearer another crossing belongs
                                -- to that junction and is never cleared from here, whatever "leave
                                -- through paths" is set to - so it goes in NEITHER list. It used to be
                                -- put in debris and merely kept out of turnDebris, which meant turning
                                -- that toggle off (debris, not turnDebris) deleted the neighbour's
                                -- wiring: the "we killed another junction" failure, back through a
                                -- different door. The toggle governs through ROUTES, not ownership.
                                --
                                -- AND BY THE PIECE (mostlyOurs), as the extent sweep below does. At
                                -- 39se, 30's right-turn slip lane - from 30's north-east road onto the
                                -- road towards 39se - came here inside one of 30's clusters that the
                                -- flood had to stop, so it was shared out point by point. Its last point
                                -- before the merge, 21 m out, lay nearer 39se's crossing than 30's (by
                                -- 0.14 m, once the clean-up had moved that crossing). That one point was
                                -- taken, the turn was cut off its merge, and 15 m of it was left hanging
                                -- off 30's road as a dead end. Seven of its eight points are 30's: it
                                -- is 30's turn, and 30's own clear takes it whole. The same at 20n
                                -- (turn radius 2): the first four points of 20s's left turn onto its
                                -- east road lay nearer 20n's crossing, were taken, and left the other
                                -- five hanging off 20s's road, fed by nothing. A cluster taken whole
                                -- (a closed connector of this junction's own) is not asked.
                                -- A through route's own point is shared out by nearest crossing alone, as
                                -- before: it is not turn wiring (see mostlyOurs).
                                local nTurn, nThrough, pieceOk = 0, 0, {}
                                for _, cw in ipairs(cluster) do
                                    if whole or (isOwnForClear(cw) and (not clearMode or lockedCrossing == nil
                                        or protectedNodes[cw.id] or runNode[cw.id] or mostlyOurs(cw, pieceOk))) then
                                        debris[#debris + 1] = cw
                                        if protectedNodes[cw.id] then
                                            throughDebris[#throughDebris + 1] = cw
                                            nThrough = nThrough + 1
                                        else
                                            turnDebris[#turnDebris + 1] = cw
                                            nTurn = nTurn + 1
                                        end
                                    end
                                end
                                -- Counted from what the loop above took, not from the cluster: at 39se
                                -- this line said 40 of 30's points were cleared when one was taken, and
                                -- the other 39 were left to 30 - which only instrumenting the clear showed.
                                if logSite2 then
                                    local mx, mz, mcount = 0, 0, 0
                                    for _, cw in ipairs(cluster) do mx, mz, mcount = mx + cw.x, mz + cw.z, mcount + 1 end
                                    if mcount > 0 then mx, mz = mx / mcount, mz / mcount end
                                    roadNote(string.format("clearAccept:%.0f:%.0f", mx, mz),
                                        "junction clear - %d point(s) near %.1f, %.1f: %s -> %d cleared, %d spared, %d left to the junction they belong to.",
                                        #cluster, mx, mz, diagWhy, nTurn, nThrough, #cluster - nTurn - nThrough)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- THE THROUGH ROUTE'S OWN LINKS, for "leave through paths" to cut.
    --
    -- Turning that toggle off means no route should survive ACROSS this junction. It used to mean
    -- "delete every node on those routes", which is far more: where two junctions sit close
    -- together the route between them IS the road joining them, so clearing one took out the road
    -- to its neighbour - 5 of the 19 points on it, at a pair 18 m apart.
    --
    -- Cutting the links leaves every node where it is and simply stops traffic crossing. The
    -- lane-end tidy then trims the ends back to the box, so what is left reads as a clean gap
    -- rather than a severed road.
    local throughLinks = {}
    if clearMode and lockedCrossing ~= nil then
        local extent2 = math.max(12, turnR * 1.5) ^ 2
        local seenLink = {}
        for id in jxByPlace(protectedNodes) do
            local w = inside[id] or ADGraphManager:getWayPointById(id)
            if w ~= nil then
                for _, nid in pairs(w.out or {}) do
                    if protectedNodes[nid] and not seenLink[id .. ":" .. nid] then
                        local o = inside[nid] or ADGraphManager:getWayPointById(nid)
                        if o ~= nil then
                            local dw = (w.x - lockedCrossing.x) ^ 2 + (w.z - lockedCrossing.z) ^ 2
                            local doo = (o.x - lockedCrossing.x) ^ 2 + (o.z - lockedCrossing.z) ^ 2
                            if dw <= extent2 or doo <= extent2 then
                                seenLink[id .. ":" .. nid] = true
                                throughLinks[#throughLinks + 1] = { w, o }
                            end
                        end
                    end
                end
            end
        end
    end

    -- THE CROSSING'S OWN WIRING, whatever it is labelled. The cluster pass can only offer up nodes
    -- the lane chains did not already claim as road - and at a junction the chains walk right up to
    -- the crossing, so most of its wiring is claimed and only a handful ever reach the debris set
    -- (measured: 6, at a junction holding ~30 nodes of wiring). Clearing therefore also takes every
    -- node in the LOCKED crossing's Voronoi cell, within the crossing's own extent, that is not
    -- carrying a route through the junction AND IS NOT ON A RUN.
    --
    -- That last condition is what keeps the parent roads. This sweep is a distance rule, and a
    -- distance rule cannot tell a T's stem from a connector: the stem is on no through route (it only
    -- ever connects by turning), so without the run test its road was eaten out to the full extent -
    -- 16 to 29 m of it, measured. Note it is the RUN that is spared and not the whole skeleton:
    -- skeleton reaches past the fork and onto the connector tails, which are exactly what this sweep
    -- is here to take. Sparing all of it leaves turns joined.
    if clearMode and lockedCrossing ~= nil then
        -- BOUNDED BY THE WHEEL AS WELL AS THE TURN RADIUS. Ownership is meant to stop this sweep
        -- at a neighbour, but clearing a junction DESTROYS the degree-3 nodes it was detected by,
        -- so its neighbour can no longer see it and the next clear owns everything up to and past
        -- it. The search radius is the one reach the user controls, so it bounds this too.
        local extentR2 = math.min(math.max(12, turnR * 1.5), clearReach) ^ 2
        local already = {}
        for _, w in ipairs(turnDebris) do already[w.id] = true end
        for _, w in ipairs(throughDebris) do already[w.id] = true end
        -- Owned as a piece, as the cluster pass is too (mostlyOurs, above the cluster pass).
        local pieceOk = {}
        local extra = 0
        for _, w in jxByPlace(work) do
            if not already[w.id] and not protectedNodes[w.id] and not runNode[w.id]
                and not foreignWiring[w]
                and (w.x - lockedCrossing.x) ^ 2 + (w.z - lockedCrossing.z) ^ 2 <= extentR2
                and isOwnForClear(w) and mostlyOurs(w, pieceOk) then
                turnDebris[#turnDebris + 1] = w
                debris[#debris + 1] = w
                extra = extra + 1
            end
        end
        if logSite2 and extra > 0 then
            roadNote(string.format("clearExtent:%d:%d", math.floor(cx * 2), math.floor(cz * 2)),
                "junction clear - %d further point(s) inside the crossing's own extent (%.0f m) and not on a through route.",
                extra, math.sqrt(extentR2))
        end
    end

    -- Movement matrix: each entry -> each exit, dropping U-turns, tagged new vs already connected.
    -- nNew counts only movements that got a BUILDABLE connector - what actually places - so it never
    -- silently disagrees with what right-click lays. Every candidate that drops out gets its own
    -- bucket and, once the site is locked, its own log line with the angle, so nothing goes missing
    -- without a visible reason (see docs/junction-plan.md s5, "failing is a valid result").
    local movements = {}
    local nNew, nExisting, nTight, nOffRoad, nNoCurve, nUTurn, nFar, nRebuild, nBlocked = 0, 0, 0, 0, 0, 0, 0, 0, 0
    local nTrailerRoad, nTrailerHit = 0, 0
    local usedMin, usedMax = nil, nil
    -- The rigs for the swept-path gate (the vehicle set, those ticked on the card): only on a LOCKED
    -- site with the toggle on (a simulation per candidate radius per turn is too much for the scouting
    -- preview that re-solves on every half-metre of cursor travel). Unlocked, or with no rig ticked,
    -- the solve is the line-only one as before.
    local sweptRig = nil
    if self.junctionSwept ~= false and self.junctionArmed ~= nil and SweptSim ~= nil then
        sweptRig = self:junctionDesignRigs()
        if #sweptRig == 0 then sweptRig = nil end
    end
    -- 150 deg turned out to be too tight on a real site - a legitimate sharp hook (a two-way point's
    -- "in" arm doubling back onto a nearby "out" arm) measured 152 deg and was silently dropped before
    -- this function had per-pair logging at all. 170 deg excludes only near-literal reversals; the
    -- radius/corridor solver is what actually gates drivability (visibly, as "tight"/"off road"), so
    -- this filter only needs to catch geometry that is not a turn at all.
    local uTurn = math.rad(170)
    local logSite = (self.junctionArmed ~= nil)
    -- Where every left turn of a BUILD meets the others: where the lanes cross, else the site. Read by
    -- junctionTrackConnector during the solve below, and dropped once the solve is done.
    -- OFF by default (2026-10-02): a first try made the route check WORSE - 27 extra routes became
    -- 41-42 and refused turns 19 became 27-37 across the 75 registry junctions. Forcing truck-sized
    -- curves through one point along a fixed heading bends them into hooks that cross other paths at
    -- shallow angles. Kept behind the switch for the offline geometry work that has to come first.
    if not clearMode and AutoDrive.FLYOVER_JUNCTION_LEFTS_THROUGH_CENTRE == true then
        if lockedCrossing ~= nil and AutoDrive.FLYOVER_JUNCTION_LEFT_CENTRE_AT_LANES == true then
            self.junctionLeftCentre = { x = lockedCrossing.mergedX or lockedCrossing.x,
                z = lockedCrossing.mergedZ or lockedCrossing.z }
        else
            self.junctionLeftCentre = { x = cx, z = cz }
        end
    else
        self.junctionLeftCentre = nil
    end
    for _, e in ipairs(approaches) do
        if e.dir == "in" then
            for _, x in ipairs(approaches) do
                if x.dir == "out" and x.wp.id ~= e.wp.id then
                    local angDiff = junctionAngDiff(e.bearing, x.bearing)
                    if angDiff > uTurn then
                        nUTurn = nUTurn + 1
                        if logSite then
                            roadNote(string.format("uturn:%d_%d", e.wp.id, x.wp.id),
                                "junction - entry id=%d -> exit id=%d skipped as a U-turn (%.0f deg > %.0f deg limit).",
                                e.wp.id, x.wp.id, math.deg(angDiff), math.deg(uTurn))
                        end
                    else
                        local exists, path = connectedInside(e.wp.id, x.wp.id)
                        -- Entry and exit on the SAME lane (their chains share nodes - one lane group)
                        -- is that lane running through: a through movement, there by definition,
                        -- however the path search judged it (a lane that doubles back inside the
                        -- region reads as a "detour"). Without this the solver is asked to join a
                        -- lane to itself and refuses it as "neither curve engine fit (delta 0)".
                        if not exists and apIndex[e] ~= nil and apIndex[x] ~= nil
                            and findGroup(apIndex[e]) == findGroup(apIndex[x]) then
                            exists, path = true, nil
                        end
                        -- Rebuild option: an existing connection whose path runs through nodes OFF
                        -- the road skeleton is an old connector. With rebuild on, that movement is
                        -- re-solved like a new one and its old off-skeleton nodes are queued for
                        -- deletion at place time. A path entirely ON the skeleton is the road itself
                        -- (a through) - nothing to rebuild, left alone.
                        local rebuild, oldPath = false, nil
                        if exists and rebuildOn and path ~= nil then
                            oldPath = {}
                            for _, pid in ipairs(path) do
                                if not skeleton[pid] and inside[pid] ~= nil then
                                    oldPath[#oldPath + 1] = inside[pid]
                                end
                            end
                            rebuild = #oldPath > 0
                        end
                        -- Solve the turn at the largest radius (setting first, stepping down) that both
                        -- holds the radius bound and keeps the vehicle corridor on the road. A turn that
                        -- fails even at the floor is kept with its refusal reason, drawn red, never laid.
                        local con, usedR, refused = nil, nil, nil
                        if not exists or rebuild then
                            -- Clear mode never builds anything - the (expensive, per-radius-candidate,
                            -- swept-simulated) solve would be pure waste on a preview that re-runs on
                            -- every half-metre of cursor travel. debris/staleLinks (clear mode's actual
                            -- output) were already computed above, independent of this loop.
                            if not clearMode then
                                con, usedR, refused = self:junctionSolveMovement(e, x, cx, cz, R, turnR, sweptRig)
                            end
                        end
                        movements[#movements + 1] = { from = e, to = x, exists = exists, connector = con,
                            usedRadius = usedR, refused = refused, rebuild = rebuild, oldPath = oldPath }
                        if rebuild and con ~= nil and refused == nil then
                            nRebuild = nRebuild + 1
                        elseif exists then
                            nExisting = nExisting + 1
                        elseif con ~= nil and refused == nil then
                            nNew = nNew + 1
                        elseif refused == "tight" then
                            nTight = nTight + 1
                            if logSite then
                                roadNote(string.format("tight:%d_%d", e.wp.id, x.wp.id),
                                    "junction - entry id=%d -> exit id=%d tighter than the turn radius (or the rig's full lock) at every radius down to the floor - refused.",
                                    e.wp.id, x.wp.id)
                            end
                        elseif refused == "offroad" then
                            nOffRoad = nOffRoad + 1
                            if logSite then
                                roadNote(string.format("offroad:%d_%d", e.wp.id, x.wp.id),
                                    "junction - entry id=%d -> exit id=%d leaves the road surface at every radius down to the floor - refused.",
                                    e.wp.id, x.wp.id)
                            end
                        elseif refused == "blocked" then
                            nBlocked = nBlocked + 1
                            if logSite then
                                roadNote(string.format("blocked:%d_%d", e.wp.id, x.wp.id),
                                    "junction - entry id=%d -> exit id=%d blocked by a static obstacle at every radius down to the floor - refused.",
                                    e.wp.id, x.wp.id)
                            end
                        elseif refused == "trailerRoad" then
                            nTrailerRoad = nTrailerRoad + 1
                            if logSite then
                                roadNote(string.format("trailerRoad:%d_%d", e.wp.id, x.wp.id),
                                    "junction - entry id=%d -> exit id=%d: the design rig's body leaves the road at every radius (swept-path gate) - refused.",
                                    e.wp.id, x.wp.id)
                            end
                        elseif refused == "trailerHit" then
                            nTrailerHit = nTrailerHit + 1
                            if logSite then
                                roadNote(string.format("trailerHit:%d_%d", e.wp.id, x.wp.id),
                                    "junction - entry id=%d -> exit id=%d: the design rig's body sweeps through a static obstacle at every radius (swept-path gate) - refused.",
                                    e.wp.id, x.wp.id)
                            end
                        elseif refused == "far" then
                            nFar = nFar + 1
                            if logSite then
                                roadNote(string.format("far:%d_%d", e.wp.id, x.wp.id),
                                    "junction - entry id=%d -> exit id=%d never come close to each other (likely two separate crossings in one scope) - skipped.",
                                    e.wp.id, x.wp.id)
                            end
                        else
                            nNoCurve = nNoCurve + 1
                            if logSite then
                                roadNote(string.format("nocurve:%d_%d", e.wp.id, x.wp.id),
                                    "junction - entry id=%d -> exit id=%d has no joinable curve (near-collinear offset tangents).",
                                    e.wp.id, x.wp.id)
                            end
                        end
                        if con ~= nil and refused == nil and usedR ~= nil then
                            usedMin = math.min(usedMin or usedR, usedR)
                            usedMax = math.max(usedMax or usedR, usedR)
                        end
                    end
                end
            end
        end
    end
    if logSite then
        for _, ap in ipairs(approaches) do
            -- Keyed by id AND direction: a two-way point contributes an "in" AND an "out" approach
            -- under the SAME waypoint id, and a key by id alone hid whichever one logged second.
            -- Logged with where the RUN was followed to and why it stopped: a run cut short by another
            -- junction is the usual reason a kickout comes out shortened or a turn steps its radius down.
            roadNote(string.format("approach:%d:%s:%d", ap.wp.id, ap.dir, math.floor(ap.runLength or 0)),
                "junction - %s track cut by the circle at id=%d (bearing %.0f deg), run followed %.0f m outward to id=%d%s.",
                (ap.dir == "in") and "entry" or "exit", (ap.selWp or ap.wp).id, math.deg(ap.bearing),
                ap.runLength or 0, ap.wp.id,
                ap.runEnded and (" - stopped at " .. ap.runEnded) or "")
        end
    end

    -- Redundant-lane pass: two movements with a similar entry bearing AND a similar exit bearing are
    -- the SAME turn attempted from different lanes of the same two roads - a multi-lane road has
    -- several parallel "in" approaches and several parallel "out" ones, and the raw matrix pairs every
    -- lane with every lane, including an inner lane crossing to a far outer lane on the OTHER side of
    -- the intersection. Distance to the scope centre cannot tell those apart (the wrong pairing can sit
    -- just as close as the right one when the lanes themselves are only a few metres apart) - but the
    -- tracks' own closest-approach distance (meetDist, already computed while solving the connector)
    -- can: the CORRECT lane pairing is the one whose tracks actually come closest together. Within each
    -- bearing-matched cluster, keep only that one and refuse the rest as "lane" - visibly, not silently.
    local nLane = 0
    for i = 1, #movements do
        local mi = movements[i]
        if mi.connector ~= nil and mi.refused == nil and not mi.exists then
            for j = i + 1, #movements do
                local mj = movements[j]
                if mj.connector ~= nil and mj.refused == nil and not mj.exists
                    and junctionAngDiff(mi.from.bearing, mj.from.bearing) < math.rad(20)
                    and junctionAngDiff(mi.to.bearing, mj.to.bearing) < math.rad(20) then
                    local loser = (mi.connector.meetDist <= mj.connector.meetDist) and mj or mi
                    loser.refused = "lane"
                    nNew = nNew - 1
                    nLane = nLane + 1
                    if logSite then
                        roadNote(string.format("lane:%d_%d", loser.from.wp.id, loser.to.wp.id),
                            "junction - entry id=%d -> exit id=%d is a redundant lane pairing (a closer match exists for this turn) - skipped.",
                            loser.from.wp.id, loser.to.wp.id)
                    end
                end
            end
        end
    end

    -- Swept-path prediction (docs/swept-path-spec.md §5-6, phase 5 step 1: VISUALISE). On a locked
    -- site only - it is a per-turn simulation and the scouting preview already re-solves on every
    -- half-metre of cursor travel - drive the design rig along each placeable connector with the
    -- stock-driver model and keep the predicted tow and trailer tracks for the preview to draw, plus
    -- the trailer's worst inside cut-in for the card. No gate yet: this is the step where the model's
    -- claims are made visible before anything is allowed to refuse on them.
    local sweptMax, nSweptWide = nil, 0
    local nSweep, sweepMax = 0, nil
    local rigFits = nil
    if self.junctionSwept ~= false and self.junctionArmed ~= nil and SweptSim ~= nil then
        -- Drawn: the rig the solve judged the line by (the failing one, else the first that must fit);
        -- with no rig ticked, the first of the set, so the lines still show.
        local allRigs = self:junctionDesignRigs(true)
        local drawRig = self:junctionDesignRigs()[1] or allRigs[1] or SweptSim.EXAMPLE_RIG
        local halfCorr = (self.junctionCorridor or AutoDrive.FLYOVER_JUNCTION_CORRIDOR or 4.0) / 2
        for _, m in ipairs(movements) do
            -- Refused turns too: their red connector is exactly where seeing the predicted bodies
            -- explains the refusal. The solve already ran the prediction on the connector it kept.
            if m.connector ~= nil and (not m.exists or m.rebuild) then
                local rig = m.connector.sweptRig or drawRig
                local ok, sw = true, m.connector.swept
                if sw == nil then
                    ok, sw = pcall(function() return self:junctionSweptPredict(m.from, m.to, m.connector, cx, cz, R, rig) end)
                end
                if ok and sw ~= nil then
                    m.swept = sw
                    -- Inside trailer EDGE beyond the corridor half-width = the turn the trailer clips.
                    local edge = sw.trailerIn + (rig.trailerWidth or 2.5) / 2
                    sw.wide = edge > halfCorr
                    if sw.wide then nSweptWide = nSweptWide + 1 end
                    sweptMax = math.max(sweptMax or 0, sw.trailerIn)
                    if m.connector.sweep ~= nil and m.refused == nil then
                        nSweep = nSweep + 1
                        sweepMax = math.max(sweepMax or 0, m.connector.sweep)
                        if m.connector.kickEarly ~= nil then
                            Logging.info("[FlyoverEditor]: swept - entry id=%d -> exit id=%d laid with a %.1f m KICKOUT (starts %.0f m before the curve, returns %.0f m after it) so the rig stays on the road / clear.",
                                m.from.wp.id, m.to.wp.id, m.connector.sweep, m.connector.kickEarly, m.connector.kickLate)
                        else
                            Logging.info("[FlyoverEditor]: swept - entry id=%d -> exit id=%d laid %.1f m WIDE inside the curve (no room for a kickout) so the rig stays on the road / clear.",
                                m.from.wp.id, m.to.wp.id, m.connector.sweep)
                        end
                    end
                    Logging.info("[FlyoverEditor]: swept - entry id=%d -> exit id=%d (%s turn): tow cuts %.2f m inside, trailer axle %.2f m inside / %.2f m outside the connector; inside edge %.2f m vs corridor half-width %.1f m -> %s (rig: %s).",
                        m.from.wp.id, m.to.wp.id, sw.leftTurn and "left" or "right", sw.towIn, sw.trailerIn,
                        sw.trailerOut, edge, halfCorr, sw.wide and "PAST CORRIDOR" or "fits", rig.name or "?")
                elseif ok and sw == nil then
                    Logging.info("[FlyoverEditor]: swept - entry id=%d -> exit id=%d: no prediction (geometry unusable for a run-in/run-out).",
                        m.from.wp.id, m.to.wp.id)
                elseif not ok then
                    roadNote("sweptErr", "swept-path prediction failed: %s", tostring(sw))
                end
            end
        end
        -- WHICH RIGS EACH TURN FITS, for the card: every rig of the set, ticked or not, over the turns
        -- this build would lay. A rig the solve already drove through a line is not driven again; a
        -- turn with no usable prediction does not count as a fit.
        local checkSurface = self.junctionCheckSurface ~= false
        local checkObstacles = self.junctionCheckObstacles ~= false
        rigFits = {}
        for _, g in ipairs(allRigs) do
            local fit, total = 0, 0
            for _, m in ipairs(movements) do
                if m.connector ~= nil and m.refused == nil and (not m.exists or m.rebuild) then
                    total = total + 1
                    local s = m.connector.sweptBy and m.connector.sweptBy[g.key] or nil
                    if s == nil then
                        local ok, res = pcall(function() return self:junctionSweptPredict(m.from, m.to, m.connector, cx, cz, R, g) end)
                        if ok then s = res end
                    end
                    if s ~= nil and not (checkSurface and self:junctionSweptOffRoad(s))
                        and not (checkObstacles and self:junctionSweptHits(s, g) > 0) then
                        fit = fit + 1
                    end
                end
            end
            rigFits[g.key] = { fit = fit, total = total }
            if total > 0 then
                Logging.info("[FlyoverEditor]: swept - %s (%s, %s): fits %d of the %d turns this build lays.",
                    tostring(g.short or g.key), tostring(g.name), self:junctionRigOn(g.key) and "must fit" or "not checked", fit, total)
            end
        end
    end

    -- The LANE GROUP each approach ended up in, now the union-find has settled. Two tracks the clear
    -- decided are the same road - the two directions of a carriageway, most often - share a group.
    -- The lane-end tidy groups tracks into roads by this rather than by guessing from headings: a
    -- geometric test could not tell a shallow-angle crossing from a parallel neighbour, and got both
    -- wrong at once, while this is the tool's own answer to the same question, already computed.
    for ai, ap in ipairs(approaches) do ap.laneGroup = findGroup(ai) end

    -- THE CENTRE OF THE TRACKS coming and going, which is what the lane ends get tidied against. The
    -- lock is only wherever the cursor happened to be; this is the middle of the junction itself -
    -- the crossing cluster's centroid, the nodes where tracks actually meet. Failing that (no crossing
    -- found), the mean of the points where the search circle cut each track. Captured HERE, at preview
    -- time, because the clear is about to delete most of the nodes it is measured from.
    local tracksCentre
    if lockedCrossing ~= nil then
        tracksCentre = { x = lockedCrossing.mergedX or lockedCrossing.x, z = lockedCrossing.mergedZ or lockedCrossing.z }
    elseif #approaches > 0 then
        local sx, sz = 0, 0
        for _, ap in ipairs(approaches) do
            local w = ap.selWp or ap.wp
            sx, sz = sx + w.x, sz + w.z
        end
        tracksCentre = { x = sx / #approaches, z = sz / #approaches }
    end

    -- Rough confidence (refined later): a clean crossing has a small, balanced set of approaches.
    local conf = 0
    if #approaches >= 2 then
        local balance = 1 - math.abs(nIn - nOut) / math.max(1, nIn + nOut)
        local tidy = (#approaches <= 8) and 1 or (8 / #approaches)
        conf = math.max(0, math.min(1, 0.5 * balance + 0.5 * tidy))
    end

    self.junctionPreview = {
        radius = selectR, workRadius = R, turnRadius = turnR, cx = cx, cz = cz, cy = cy, armed = (self.junctionArmed ~= nil),
        approaches = approaches, movements = movements,
        nIn = nIn, nOut = nOut, nNew = nNew, nExisting = nExisting, nTight = nTight, nOffRoad = nOffRoad,
        nNoCurve = nNoCurve, nUTurn = nUTurn, nFar = nFar, nLane = nLane, nRebuild = nRebuild, nBlocked = nBlocked,
        debris = debris, staleLinks = staleLinks, siteHasTwoWay = siteHasTwoWay,
        turnDebris = turnDebris, throughDebris = throughDebris, clearMode = clearMode,
        tracksCentre = tracksCentre, runNodes = runNodeOf, throughLinks = throughLinks,
        foreignWiring = foreignWiring, foreignOwner = foreignOwner,
        pathRoutes = (function()
            local out, has = {}, {}
            for _, rt in ipairs(self._jxRoutes or {}) do
                local nodes = {}
                for _, pid in ipairs(rt.path) do
                    local w = ADGraphManager:getWayPointById(pid)
                    if w ~= nil then nodes[#nodes + 1] = w end
                end
                if #nodes >= 3 then out[#out + 1] = nodes end
                has[rt.e], has[rt.x] = true, true
            end
            local side = {}
            for _, ap in ipairs(approaches) do
                if not has[ap] and not ap._debris then
                    local ch = self:junctionChain(ap, cx, cz, R)
                    local nodes = {}
                    for _, n in ipairs(ch) do nodes[#nodes + 1] = n end
                    -- WHERE THE CONNECTOR STARTS, read now while the wiring is still there. The first
                    -- fork on the way in is either a TIE NODE (on the side road: the lane ends there)
                    -- or, where one lane sweeps straight into the main road, the MERGE (on the main
                    -- road). For a merge, walk BACK from it point by point reading the turn at each:
                    -- on the sweep every point turns; the connector starts where two points in a
                    -- row have stopped turning.
                    local cutAt = nil
                    local function deg3(w)
                        local seen, d = {}, 0
                        for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
                            for _, id in pairs(lst) do if not seen[id] then seen[id] = true d = d + 1 end end
                        end
                        return d >= 3
                    end
                    local function turnAt(i)
                        local a, b, c = nodes[i - 1], nodes[i], nodes[i + 1]
                        if a == nil or c == nil then return 0 end
                        local h1 = math.atan2(b.x - a.x, b.z - a.z)
                        local h2 = math.atan2(c.x - b.x, c.z - b.z)
                        local d = h2 - h1
                        while d > math.pi do d = d - 2 * math.pi end
                        while d < -math.pi do d = d + 2 * math.pi end
                        return d
                    end
                    -- THE TIE NODE HAS TO BE ONE OF THIS JUNCTION'S OWN FORKS. It used to be "the first
                    -- fork along the lane within 45 m of the centre" - and the lane is walked from its
                    -- OUTER end inward, so the first fork it meets is the one FARTHEST from this
                    -- junction: at a close pair, the neighbour's tie node, 24 m away and well inside
                    -- 45. The lane was cut there, and everything from there in was dug up - the whole
                    -- run between two junctions, 8 points out to 36 m, in game. Which forks belong to
                    -- this junction is something the selection already knows exactly.
                    -- Whose fork it is comes from the ownership the clear already works out for the
                    -- wiring: each fork goes to its nearest crossing, and a crossing whose wiring all
                    -- begins and ends on these lanes is this junction's own tie node however far out
                    -- it sits. (The selection's fork cluster is too tight for this - real tie nodes
                    -- sit 15-18 m out, beyond it - and testing against the cluster alone left lanes
                    -- with no tie node at all and their old connectors standing.)
                    -- ...AND ITS BRANCH HAS TO BE A CONNECTOR INTO THIS JUNCTION. Ownership goes by the
                    -- nearest crossing, and once a neighbouring junction has been cleared its crossing
                    -- is gone: a fork 31 m up a side road - a field entrance, nothing to do with this
                    -- junction - was then the nearest crossing's, passed as the lane's tie node, and
                    -- everything inward of it was dug up and re-laid on a straight line that missed the
                    -- road. What makes a fork a TIE node is what hangs off it: the branch that leaves
                    -- the lane there is followed, and it must run through the junction.
                    local onLane = {}
                    for _, n in ipairs(nodes) do onLane[n] = true end
                    local function leadsIn(fk)
                        for _, lst in ipairs({ fk.out or {}, fk.incoming or {} }) do
                            for _, id in pairs(lst) do
                                local b = ADGraphManager:getWayPointById(id)
                                if b ~= nil and not onLane[b] then
                                    local prev, cur = fk, b
                                    for _ = 1, 40 do
                                        if (cur.x - cx) ^ 2 + (cur.z - cz) ^ 2 <= R * R then return true end
                                        local nxt, cnt = nil, 0
                                        for _, l2 in ipairs({ cur.out or {}, cur.incoming or {} }) do
                                            for _, id2 in pairs(l2) do
                                                local o = ADGraphManager:getWayPointById(id2)
                                                if o ~= nil and o ~= prev and o ~= cur then
                                                    cnt = cnt + 1
                                                    nxt = nxt or o
                                                end
                                            end
                                        end
                                        if nxt == nil or cnt > 2 then break end
                                        prev, cur = cur, nxt
                                    end
                                end
                            end
                        end
                        return false
                    end
                    local f = nil
                    for i = 2, #nodes do
                        if deg3(nodes[i]) then
                            if clearMode then
                                if isOwnForClear(nodes[i]) and leadsIn(nodes[i]) then f = i break end
                            elseif (nodes[i].x - cx) ^ 2 + (nodes[i].z - cz) ^ 2 <= 45 * 45 then
                                f = i break
                            end
                        end
                    end
                    -- A FORK ON THE FAR SIDE OF THE JUNCTION IS NOT THIS LANE'S TIE NODE. A lane that
                    -- sweeps straight into the through road has no tie fork of its own: the first fork
                    -- on its list is where it MERGES, beyond the middle of the junction. Taking that
                    -- for the tie node and then hunting back up the road for where "the swing" began
                    -- cut the lane 16 to 30 m out and re-laid it - while the very same lane, met
                    -- after the junction next door had already cut it off at the box, was simply
                    -- run to the junction and ended there, which is right, and is what the user
                    -- picked out as the one correct result of six. So that is the rule for all six:
                    -- with no tie fork BEFORE the junction, the lane runs to the junction and ends.
                    if f ~= nil then
                        local k, kd = 1, math.huge
                        for i = 1, #nodes do
                            local d = (nodes[i].x - cx) ^ 2 + (nodes[i].z - cz) ^ 2
                            if d < kd then kd, k = d, i end
                        end
                        if f > k then
                            cutAt = k
                            for i = 2, k do
                                if (nodes[i].x - cx) ^ 2 + (nodes[i].z - cz) ^ 2 <= 4.5 * 4.5 then cutAt = i break end
                            end
                            f = nil
                        end
                    end
                    if f ~= nil then
                        -- TURNING IS MEASURED AGAINST THE ROAD'S OWN STEADY CURVE, NOT AGAINST ZERO. A
                        -- side road that bends all the way in turns a little at every node; counted
                        -- from zero that added up to "has swung" and no node ever read as quiet, so
                        -- the search for where the swing began ran back up the road until it happened
                        -- on a straight bit - 31 m out at one T, and everything inward was dug up and
                        -- re-laid straight across the bend. The road's steady turn per node is the
                        -- middle of its readings; a kickout is what departs from THAT.
                        local base = 0
                        do
                            local ts = {}
                            for i = 2, f - 1 do ts[#ts + 1] = turnAt(i) end
                            if #ts >= 3 then
                                table.sort(ts)
                                base = ts[math.floor((#ts + 1) / 2)]
                            end
                        end
                        local rawTurnAt = turnAt
                        turnAt = function(i) return rawTurnAt(i) - base end
                        -- how far the lane has turned by the time it reaches that fork
                        local total = 0
                        for i = 2, f - 1 do total = total + turnAt(i) end
                        if f == #nodes or math.abs(total) < math.rad(20) then
                            cutAt = f
                        else
                            local quiet = 0
                            for i = f - 1, 2, -1 do
                                if math.abs(turnAt(i)) < math.rad(2.5) then
                                    quiet = quiet + 1
                                    if quiet >= 2 then cutAt = i + 1 break end
                                else
                                    quiet = 0
                                end
                            end
                        end
                    end
                    -- A SIDE LANE OF THIS JUNCTION ENDS AT THIS JUNCTION. The scope circle also cuts
                    -- lanes that are only passing on their way to the junction next door, and one of
                    -- those was being tidied as this junction's own: cut 31 m out, down by the
                    -- neighbour, and carried off towards a box it never reached - a dangling line, a
                    -- lane trimmed far short, and an arm count of seven on a T. Whose lane it is
                    -- comes from the same ownership the wiring uses, asked of the lane's own end.
                    -- Asked at the lane's CLOSEST APPROACH to the junction, not at the end of its list:
                    -- with through paths kept the list runs on round the connector and away down the
                    -- next road, so its last node can be 40 m off and somebody else's while the lane
                    -- is plainly this junction's. Testing the last node dropped such a lane from the
                    -- tidy and left its remains to the loose-end sweep - cut 30 m out, never carried.
                    local mine = true
                    if clearMode and lockedCrossing ~= nil and #nodes >= 1 then
                        local nb, nd = nodes[1], math.huge
                        for _, n in ipairs(nodes) do
                            local d = (n.x - cx) ^ 2 + (n.z - cz) ^ 2
                            if d < nd then nd, nb = d, n end
                        end
                        mine = isOwnForClear(nb)
                    end
                    if AutoDrive.FLYOVER_JUNCTION_TRIM_DEBUG and clearMode then
                        for i = 2, #nodes do
                            if deg3(nodes[i]) then
                                Logging.info("[FlyoverEditor]: FORKONLANE lane of %d: #%d (%.1f, %.1f) %.0f m from centre, own=%s leadsIn=%s",
                                    #nodes, i, nodes[i].x, nodes[i].z, math.sqrt((nodes[i].x - cx) ^ 2 + (nodes[i].z - cz) ^ 2),
                                    tostring(isOwnForClear(nodes[i])), tostring(leadsIn(nodes[i])))
                            end
                        end
                    end
                    if AutoDrive.FLYOVER_JUNCTION_TRIM_DEBUG and f ~= nil then
                        local tot = 0
                        for i = 2, f - 1 do tot = tot + turnAt(i) end
                        Logging.info("[FlyoverEditor]: CUTAT lane of %d: own fork #%d at (%.1f, %.1f), turn before it %.1f deg (relative to the road's curve) -> cut at #%s",
                            #nodes, f, nodes[f].x, nodes[f].z, math.deg(tot), tostring(cutAt))
                    end
                    if #nodes >= 2 and mine then
                        side[#side + 1] = { nodes = nodes, useOut = (ap.dir == "in"), cutNode = cutAt and nodes[cutAt] or nil }
                    end
                end
            end
            return { through = out, side = side }
        end)(),
        protectedOf = protectedOf,
        usedMin = usedMin, usedMax = usedMax, confidence = conf,
        sweptMax = sweptMax, nSweptWide = nSweptWide, nTrailerRoad = nTrailerRoad, nTrailerHit = nTrailerHit,
        nSweep = nSweep, sweepMax = sweepMax, rigFits = rigFits,
    }
    -- WHAT THE BUILD WILL LAY, said on the card before the right-click (doc 12): the pattern (mod or
    -- smooth) where it fits, else why not. Worked out dry, and only on a locked site - the preview
    -- follows the cursor otherwise, and this asks place for a whole plan.
    if not clearMode and self.junctionArmed ~= nil and AutoDrive.FLYOVER_JUNCTION_BUILD_PATTERN ~= false then
        tryCall("junction build: pattern fit for the card", function()
            local site, res, why = self:junctionPatternFit(self.junctionPreview)
            self.junctionPreview.patternFit = (site ~= nil)
                and { ok = true, kind = res.kind, shape = res.shape }
                or { ok = false, why = why }
        end)
    end
    -- Run the lane-end tidy in DRY mode and keep what it says: where each end would land, and the
    -- claim bands it measured against. Drawn below, so the site can be judged on screen before
    -- right-clicking instead of inferred afterwards from a log. It mutates nothing.
    if clearMode then
        tryCall("junction tidy preview", function()
            local ends, bands, swept, roadsOut, boxCentre = self:junctionTidyLaneEnds(self.junctionPreview, true)
            self.junctionPreview.tidyEnds, self.junctionPreview.tidyBands = ends, bands
            self.junctionPreview.boxSweep, self.junctionPreview.tidyRoads = swept, roadsOut
            self.junctionPreview.boxCentre = boxCentre
            -- THE MIDDLE OF A JUNCTION IS WHERE ITS ROADS CROSS, and that is what gets shown. The
            -- selection finds the junction by its forks, and their centroid sits a few metres off
            -- the crossing - 3.3 m at one T, where the lock was visibly not on the intersection.
            -- This is not the old re-aim: nothing is solved again and the selection is not
            -- reconsidered. The crossing only says where the middle of the chosen junction is.
            if boxCentre ~= nil then
                self.junctionPreview.cx, self.junctionPreview.cz = boxCentre.x, boxCentre.z
            end
        end)
        -- Named on the card before anything is applied: which junction this is, and what kind.
        tryCall("junction classify", function()
            self.junctionPreview.junctionType = self:junctionClassify(self.junctionPreview)
        end)
        -- ...and whether it is really more than one junction: display only, a suggestion on the
        -- card. The clear reads none of it.
        tryCall("junction parts", function()
            local parts, why = self:junctionParts(self.junctionPreview)
            self.junctionPreview.junctionParts, self.junctionPreview.junctionPartsWhy = parts, why
        end)
        tryCall("junction number", function()
            self.junctionPreview.junctionNumber = self:junctionNumberAt(cx, cz)
        end)
        tryCall("junction parts note", function()
            self.junctionPreview.junctionPartsNote = self:junctionPartsNote(self.junctionPreview,
                self.junctionPreview.junctionNumber, cx, cz)
        end)
        -- WHICH PART, when the user has split this junction: named from the site the selection
        -- locked (cx, cz), never from the box's middle - at 26 that sits 6 m off, between the two
        -- halves. Worked out once here; the card, the log, the debug capture and the check after
        -- the clear all read jp.junctionName. With it, the parts the card would split it into.
        -- onSite: the selection found a junction here (the clear always has). lockedOnSite: and a
        -- click has locked it - the card's decision buttons need that. Unlocked, the preview follows
        -- the cursor, and the cursor stays where it last pointed in the world while the mouse is on
        -- the panel - so a button would act on whatever junction the mouse last passed over, and a
        -- click on one saves to the savegame at once.
        tryCall("junction name", function()
            local jp = self.junctionPreview
            jp.lockedAt, jp.lockedVirgin, jp.onSite = { x = cx, z = cz }, false, true
            jp.lockedOnSite = (self.junctionArmed ~= nil)
            jp.junctionOffer, jp.junctionOfferWhy = self:junctionSplitOffer(jp, jp.junctionNumber)
            self:junctionNameSite(jp)
        end)
        tryCall("junction situation", function()
            self.junctionPreview.junctionSituation = self:junctionSituation(self.junctionSite)
        end)
    elseif self.junctionPreview ~= nil then
        tryCall("junction situation", function()
            self.junctionPreview.junctionSituation = self:junctionSituation(self.junctionSite)
        end)
        tryCall("junction number", function()
            self.junctionPreview.junctionNumber = self:junctionNumberAt(cx, cz)
        end)
        -- The same suggestion the clear card makes, so build can say when a site is two junctions:
        -- 72 and 73, the two T+Y's the user wants built a half at a time, are both cleared, and a
        -- cleared site is only ever seen in build. The build itself reads none of this, and only a
        -- site the selection locked is read - free placement is not a junction.
        -- THE KIND AND THE PARTS ONLY ON A CLEARED SITE, and from its lane ends alone. The
        -- classifier reads the through routes in pathRoutes, and those come from self._jxRoutes,
        -- which only the clear works out: in build they are whatever the last clear preview left,
        -- another junction's roads as often as not. A cleared site has no through routes anyway. A
        -- WIRED site is not read here: read from where the search circle cuts its tracks, as if they
        -- were lane ends, its turn connectors pass for side roads - at radius 15 that suggested
        -- splitting 12, 52 and 61, plain T's. The clear card reads a wired site from its own routes.
        -- ...AND NOT FROM BUILD'S OWN APPROACHES, which are cut at the wheel's radius: the reading
        -- moved with the wheel (see JUNCTION_CLEARED_READ_R). It is gathered afresh at a fixed
        -- radius round the site, and the preview's own approaches are left alone.
        local st = self.junctionSite
        if st ~= nil then
            local jp = self.junctionPreview
            if st.virgin then
                tryCall("junction classify", function()
                    local rd = self:junctionVirginReading(st)
                    rd.junctionType = self:junctionClassify(rd)
                    jp.junctionType = rd.junctionType
                    local parts, why = self:junctionParts(rd)
                    jp.junctionParts, jp.junctionPartsWhy = parts, why
                end)
            end
            tryCall("junction parts note", function()
                jp.junctionPartsNote = self:junctionPartsNote(jp, jp.junctionNumber, cx, cz)
            end)
        end
        -- The same naming as the clear card's, from where the site was locked - the selection's site,
        -- or the cursor where it found none. Parts are offered only for a site the selection locked:
        -- free placement is not a junction. The decision buttons need a click's lock as well, as on
        -- the clear card.
        tryCall("junction name", function()
            local jp = self.junctionPreview
            jp.lockedAt = { x = cx, z = cz }
            jp.lockedVirgin = (st ~= nil and st.virgin == true)
            jp.onSite = (st ~= nil)
            jp.lockedOnSite = (st ~= nil and self.junctionArmed ~= nil)
            jp.junctionOffer, jp.junctionOfferWhy = nil, nil
            if st ~= nil then
                jp.junctionOffer, jp.junctionOfferWhy = self:junctionSplitOffer(jp, jp.junctionNumber)
            end
            self:junctionNameSite(jp)
        end)
        -- Spelled out, not `a and nil or b`: that idiom falls through to b whenever the middle
        -- value is nil, so it indexed the very site it had just found to be missing - an error on
        -- every frame build mode was pointed at open ground.
        local st = self.junctionSite
        if st ~= nil then
            self.junctionPreview.junctionState = st.virgin and "virgin - ready to build" or "wired"
        else
            self.junctionPreview.junctionState = nil
        end
    end

    -- Skeleton INSIDE the circle: if a run-following walk ever diverts off the road and down a
    -- connector, that connector's nodes are marked road and become permanently unclearable - and it
    -- leaves no rejection line at all, because it is never even considered as debris. Listing them is
    -- how that shows up: a survivor whose id appears here is protected-as-road, not rejected.
    if clearMode and logSite2 then
        local ids, n = {}, 0
        for id in jxByPlace(skeleton) do
            local w = inside[id] or ADGraphManager:getWayPointById(id)
            if w ~= nil and isOwn(w) then
                n = n + 1
                if #ids < 40 then ids[#ids + 1] = tostring(id) end
            end
        end
        roadNote(string.format("clearSkel:%d:%d", math.floor(cx * 2), math.floor(cz * 2)),
            "junction clear - %d road/skeleton point(s) inside the circle (never clearable): %s%s.",
            n, table.concat(ids, " "), (n > #ids) and " ..." or "")
    end
    -- Clear mode's own summary, on every lock: the card shows the same three numbers, but they are
    -- not otherwise in the log, and "check the log" is how this tool gets debugged. Keyed by the
    -- locked point (rounded) so moving the lock prints a fresh line instead of staying silent.
    if clearMode and logSite2 then
        roadNote(string.format("clearSummary:%d:%d", math.floor(cx * 2), math.floor(cz * 2)),
            -- These have to be the numbers for the CURRENT toggle, not always the leave-on pair. They
            -- were the latter, so with through paths set to clear the log read "51 will clear, 29
            -- spared" while the apply took all 80 - the line naming as spared the very points it was
            -- about to delete. That is how a through road died with nothing in the log to show it.
            "junction clear - %d approach(es) found, %d point(s) will clear, %d through-path point(s) spared.",
            #approaches,
            (self.junctionLeaveThrough ~= false) and #turnDebris or #debris,
            (self.junctionLeaveThrough ~= false) and #throughDebris or 0)
    end
end

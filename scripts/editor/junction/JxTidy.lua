-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua
-- loads it after FlyoverEditor.lua, in the old file's order.
-- MODSPLIT: HELPERS FROM THE FILES LOADED BEFORE THIS ONE (tools/modsplit/split.py writes this block)
for _, name in ipairs({ "junctionAngDiff", "junctionConnect", "junctionDisconnect", "jxByPlace", "jxNoteAdded", "jxRemove", "jxWasCutByUs", "roadProbeNoted", "tryCall" }) do
    if ADFlyoverEditor.shared == nil or ADFlyoverEditor.shared[name] == nil then
        Logging.error("[FlyoverEditor]: JxTidy.lua needs %s, which no file loaded before it shares", name)
    end
end
local junctionAngDiff = ADFlyoverEditor.shared.junctionAngDiff
local junctionConnect = ADFlyoverEditor.shared.junctionConnect
local junctionDisconnect = ADFlyoverEditor.shared.junctionDisconnect
local jxByPlace = ADFlyoverEditor.shared.jxByPlace
local jxNoteAdded = ADFlyoverEditor.shared.jxNoteAdded
local jxRemove = ADFlyoverEditor.shared.jxRemove
local jxWasCutByUs = ADFlyoverEditor.shared.jxWasCutByUs
local roadProbeNoted = ADFlyoverEditor.shared.roadProbeNoted
local tryCall = ADFlyoverEditor.shared.tryCall
-- MODSPLIT: end of the helpers

--- Left-click: lock the junction site at the cursor (arm), or move the lock if one is set. From here
--- the preview stays put while the wheel / turn radius reshape it, right-click places it, and a
--- right-click with nothing to place unlocks. Mirrors the pick-then-apply flow of the span tools, so
--- there is always a way out of the tool without laying anything.
function ADFlyoverEditor:junctionClick()
    if self.cursorX == nil then return end
    self.junctionArmed = { cx = self.cursorX, cz = self.cursorZ, cy = self.cursorY }
    self.junctionPreviewKey = nil
    -- A lock is a fresh report: the once-per-key notes start over, so locking the same crossing a
    -- second time (a different circle, a changed setting) logs every track, refusal and kickout
    -- again instead of only what differs from the last time.
    for k in pairs(roadProbeNoted) do roadProbeNoted[k] = nil end
    -- WHICH JUNCTION, BY NAME: "j39se", not "j39", once the user has split 39 - "locked 39" said
    -- the same whichever part was meant. The preview has not run yet, so the selection is asked
    -- here (the same one it will make), and the name is worked out the way the card does. Wrapped:
    -- a name is only a label, and an error working it out must never stop the lock.
    local named = ""
    local nok, nm = tryCall("junction name at the lock", function()
        local px, pz, virgin = self.cursorX, self.cursorZ, false
        local site = self:junctionSelect(px, pz)
        if site ~= nil then
            px, pz, virgin = site.x, site.z, site.virgin == true
        elseif self.junctionMode == "clear" then
            return nil   -- the clear refuses a click on no junction: there is nothing to name
        end
        local name = self:junctionNameAt(px, pz, virgin)
        return name
    end)
    if nok and nm ~= nil then named = string.format(" (%s)", nm) end
    -- The radius is in this line because "I set it to 20" and "the solve behaved like 15" are
    -- otherwise indistinguishable in a log, and that ambiguity cost a whole test cycle.
    ADFlyoverSettings.debugLog("[FlyoverEditor]: junction site locked at %.1f, %.1f%s - %s, turn radius %.0f m, mode %s. Right-click %s.",
        self.cursorX, self.cursorZ, named,
        (self.junctionMode == "clear")
            and string.format("scope %.0f m (fixed: the junction sets it, not the wheel)",
                AutoDrive.FLYOVER_JUNCTION_CLEAR_SCOPE or 14)
            or string.format("search radius %.0f m, wheel = scope", self:junctionRadiusValue()),
        self.junctionTurnRadius or 12,
        (self:junctionAction() == "both") and "clear + build" or (self.junctionMode or "build"),
        (self:junctionAction() == "both") and "clears and builds" or ((self.junctionMode == "clear") and "clears" or "places"))
end

--- Place every NEW turn in the preview (behaviour A): tie in at each track's tangent point (insert on a
--- through-road, trim a dead-end back to it), lay the radius-R arc one-way from entry to exit, priority
--- matched to the joined (exit) road, all under one undo. Dead-end stubs are consumed at the very end.
--- Clear mode's placement: sever this junction's stale direct links and remove its debris cluster -
--- filtered to turns only when "leave through paths" is on - and lay NOTHING. The roads themselves
--- (skeleton) are never touched by construction (see the debris pass in updateJunctionPreview); this
--- only ever removes nodes/links that pass were already the debris test.
--- Tidy the lane ends after a clear: every lane that now DEAD-ENDS at the junction is trimmed back or
--- run forward so it stops FLYOVER_JUNCTION_STUB_GAP from the centre of the tracks, with anything
--- added laid at that lane's own spacing and landing exactly on the gap. A cleared T then reads as
--- three tidy stubs around an even gap instead of three ragged ends at whatever distance the debris
--- happened to reach.
---
--- A lane still running THROUGH the junction does not dead-end, so it is skipped - which is why this
--- needs no switch of its own. With "leave through paths" on, the through road is left exactly as it
--- was; turn it off and it dead-ends too, and is tidied like the stem.
---
--- Only genuine dangling ends are touched: if the walk stops because the lane turns hard into another
--- road that it is still LINKED to, that end still "continues" and is left alone. Trimming there
--- would cut a live connection, not tidy a stub.
--- Returns points trimmed, points added, lanes touched.
--- With `dry` set, changes nothing and instead returns where every end WOULD land, plus the claim
--- bands they are measured against, for the preview to draw. Same code path either way - the preview
--- cannot drift from the apply, which is where most of this feature's confusion came from. In dry
--- mode the walk treats the debris as already gone, because that is the graph the real tidy sees.
function ADFlyoverEditor:junctionTidyLaneEnds(jp, dry)
    local skip, cut = {}, {}
    if dry then
        local leave = self.junctionLeaveThrough ~= false
        -- Exactly what the apply will delete, no more: the turn wiring, plus - with through paths
        -- set to clear - the through route's wiring but NOT its road. Skipping all of debris here
        -- had the preview walking a graph with the road removed, which the apply never produces.
        for _, w in ipairs(jp.turnDebris or {}) do skip[w.id] = true end
        if not leave then
            local keep = jp.runNodes or {}
            for _, w in ipairs(jp.throughDebris or {}) do
                if not keep[w] then skip[w.id] = true end
            end
        end
        -- The apply severs the stale links BEFORE it deletes anything, so a dry run that ignores
        -- them walks over joins that will not be there. Both directions: severing is unconditional.
        for _, pair in ipairs(jp.staleLinks or {}) do
            local a, b = pair[1], pair[2]
            if a ~= nil and b ~= nil and not (leave and pair.isThrough) then
                cut[a.id * 100000 + b.id] = true
                cut[b.id * 100000 + a.id] = true
            end
        end
        -- The through-route cuts too, when that toggle is off. Modelling only the stale links would
        -- leave the preview walking over joins the apply is about to sever.
        if not leave then
            for _, pair in ipairs(jp.throughLinks or {}) do
                local a, b = pair[1], pair[2]
                if a ~= nil and b ~= nil then
                    cut[a.id * 100000 + b.id] = true
                    cut[b.id * 100000 + a.id] = true
                end
            end
        end
    end
    local centre = jp.tracksCentre
    -- The early return has to answer in the SHAPE the caller expects: a dry run is handed two
    -- tables and a real one three counts. Returning counts to a dry caller put a number where the
    -- drawing expected a list, and the preview threw on every frame.
    if centre == nil then
        if dry then return {}, {}, {}, {} end
        return 0, 0, 0
    end
    local gap = AutoDrive.FLYOVER_JUNCTION_STUB_GAP or 4
    local function dist(w) return math.sqrt((w.x - centre.x) ^ 2 + (w.z - centre.z) ^ 2) end
    -- Ids are renumbered by every removal, so a held id can silently come to mean a DIFFERENT node.
    -- Identity is the object; the id is only how the graph is asked for it.
    -- In a dry run "removed" means "in the skip set": nothing is really deleted, so a node this
    -- run has already trimmed has to read as gone or the next lane sharing it behaves differently
    -- from the real thing. Two approaches that share a tail did exactly that - the real run tidied
    -- the tail once and skipped the second lane, the preview tidied it twice and promised an end
    -- that never appeared.
    local function alive(w)
        return w ~= nil and w.id ~= nil and w.id >= 0 and not skip[w.id]
            and ADGraphManager:getWayPointById(w.id) == w
    end
    -- Arc-length sampling along a captured alignment, so the run-in can be re-laid at even spacing
    -- ALONG THE ROAD rather than along a chord across it.
    local function cumulative(pts)
        local cum = { 0 }
        for i = 2, #pts do
            local a, b = pts[i - 1], pts[i]
            cum[i] = cum[i - 1] + math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
        end
        return cum
    end
    local function atArc(pts, cum, s)
        if s <= 0 then return pts[1] end
        if s >= cum[#cum] then return pts[#pts] end
        for i = 2, #pts do
            if cum[i] >= s then
                local a, b = pts[i - 1], pts[i]
                local t = (s - cum[i - 1]) / math.max(1e-6, cum[i] - cum[i - 1])
                return { x = a.x + (b.x - a.x) * t, z = a.z + (b.z - a.z) * t,
                    y = (a.y or 0) + ((b.y or 0) - (a.y or 0)) * t }
            end
        end
        return pts[#pts]
    end
    -- The arc the lane was ALREADY DESCRIBING, as a polyline out of the tip: its heading there, bent
    -- at the curvature measured over the last ~20 m of real road. Following the lane's own captured
    -- geometry instead would be tempting and exact, but past the run's end that geometry IS the
    -- junction wiring - it would run the lane down a connector and onto another road. Twenty metres
    -- is long enough to average out waypoint jitter and short enough to still be the corner the lane
    -- is actually in.
    -- The arc the lane was ALREADY DESCRIBING, as a polyline out of its end.
    --
    -- Curvature is read from THREE POINTS spanning about 10 m, and then read again from triples
    -- further back, so the RATE of change is known too. A road entering a bend is on a transition
    -- spiral - its curvature is still growing - and continuing at whatever it happened to be at the
    -- last node either undershoots the bend or overshoots the straight. Extrapolating the rate
    -- follows the road in; a single triple assumes the curve has already settled.
    --
    -- Following the lane's own captured geometry instead would be exact, but past the end of the
    -- road that geometry IS the junction wiring - it would run the lane down a connector and onto
    -- another road.
    local ARC_SPAN = 10
    local function laneArc(seq, tip, prev, grade, straight)
        local hx, hz = tip.x - prev.x, tip.z - prev.z
        local hl = math.sqrt(hx * hx + hz * hz)
        if hl < 1e-3 then return nil end
        hx, hz = hx / hl, hz / hl

        -- Arc length back from the end, so triples can be taken at real distances rather than at
        -- whatever spacing this lane happens to use.
        local back = { [#seq] = 0 }
        for i = #seq - 1, 1, -1 do
            back[i] = back[i + 1] + math.sqrt((seq[i + 1].x - seq[i].x) ^ 2
                + (seq[i + 1].z - seq[i].z) ^ 2)
        end
        local function atBack(d)
            for i = #seq, 1, -1 do
                if back[i] >= d then return seq[i] end
            end
            return nil
        end
        -- Signed curvature of the circle through three points: twice the triangle's area over the
        -- product of its sides.
        local function triple(d)
            local c, b, a = atBack(d), atBack(d + ARC_SPAN * 0.5), atBack(d + ARC_SPAN)
            if a == nil or b == nil or c == nil then return nil end
            local ax, az = b.x - a.x, b.z - a.z
            local bx, bz = c.x - b.x, c.z - b.z
            local cx2, cz2 = c.x - a.x, c.z - a.z
            local la = math.sqrt(ax * ax + az * az)
            local lb = math.sqrt(bx * bx + bz * bz)
            local lc = math.sqrt(cx2 * cx2 + cz2 * cz2)
            if la < 1e-3 or lb < 1e-3 or lc < 1e-3 then return nil end
            return 2 * (ax * bz - az * bx) / (la * lb * lc)
        end

        local LIMIT = 1 / 12   -- a road does not turn tighter than a 12 m radius on its own
        local k0 = triple(0)
        if k0 == nil then k0 = 0 end
        k0 = math.max(-LIMIT, math.min(LIMIT, k0))
        -- THE CHORD IS NOT THE TANGENT. The heading above is the direction from `prev` to `tip`,
        -- which on a curving road is where the road pointed HALFWAY between them, not where it
        -- points at `tip`. The arc then sets off along a line the road has already turned away
        -- from, and since this line becomes the road's claim band, the box turns with it: at one
        -- T the side road's band came out 19 degrees off and the whole box sat up the road from
        -- where the two roads actually meet.
        --
        -- For an arc the correction is exact and already to hand: turn the chord on by half the
        -- angle the arc covers over it. A straight road has k0 = 0 and is untouched.
        if k0 ~= 0 then
            local half = k0 * hl * 0.5
            local cs, sn = math.cos(half), math.sin(half)
            hx, hz = hx * cs - hz * sn, hx * sn + hz * cs
        end
        -- Carried STRAIGHT when asked: a side road with no through partner keeps its own heading.
        if straight then k0 = 0 end
        -- Is the bend tightening or easing? Read two more triples further back and take the trend
        -- per metre. Only trusted when both agree in sign with the step between them, so noise in a
        -- single reading cannot invent a spiral.
        local rate = 0
        local k1, k2 = triple(ARC_SPAN * 0.5), triple(ARC_SPAN)
        if k1 ~= nil and k2 ~= nil then
            local d1 = (k0 - k1) / (ARC_SPAN * 0.5)
            local d2 = (k1 - k2) / (ARC_SPAN * 0.5)
            if d1 * d2 > 0 and not straight then
                rate = (math.abs(d1) < math.abs(d2)) and d1 or d2
                rate = math.max(-LIMIT / 20, math.min(LIMIT / 20, rate))
            end
        end

        local pts = { { x = tip.x, y = tip.y or 0, z = tip.z } }
        local px, pz, ds = tip.x, tip.z, 0.25
        for i = 1, math.floor(30 / ds) do
            local s = i * ds
            local k = math.max(-LIMIT, math.min(LIMIT, k0 + rate * s))
            local dth = k * ds
            local cs, sn = math.cos(dth), math.sin(dth)
            hx, hz = hx * cs - hz * sn, hx * sn + hz * cs
            px, pz = px + hx * ds, pz + hz * ds
            pts[#pts + 1] = { x = px, y = (tip.y or 0) + grade * s, z = pz }
        end
        return pts
    end

    -- Walk a lane in from its outer anchor on bearing continuity, the same way the chain walk does,
    -- so a fork at an old tie node takes the ROAD on and not some surviving scrap of wiring.
    local gateCentre = nil
    local function walkLane(ap)
        local useOut = (ap.dir == "in")
        local node = ap.wp
        local cb = ap.chainBearing or ap.bearing or 0
        local wdx, wdz = math.sin(cb), math.cos(cb)
        if not useOut then wdx, wdz = -wdx, -wdz end
        local seq, cameFrom = { node }, nil
        for _ = 1, 400 do
            local list = useOut and (node.out or {}) or (node.incoming or {})
            local nextNode, bestDot = nil, -math.huge
            for _, nid in pairs(list) do
                -- `skip` is empty for the real run and holds the debris for a dry one, so the
                -- preview walks the graph the clear is ABOUT to leave rather than the one in front
                -- of it. Without this the walk crosses the junction over nodes that are about to go.
                if nid ~= cameFrom and not skip[nid] and not cut[node.id * 100000 + nid] then
                    local nx = ADGraphManager:getWayPointById(nid)
                    if nx ~= nil then
                        local dx, dz = nx.x - node.x, nx.z - node.z
                        local l = math.sqrt(dx * dx + dz * dz)
                        if l > 1e-6 then
                            local dot = (dx / l) * wdx + (dz / l) * wdz
                            if dot > bestDot then bestDot, nextNode = dot, nx end
                        end
                    end
                end
            end
            if nextNode == nil then break end
            if #seq > 1 and bestDot < 0.3 then break end
            cameFrom = node.id
            local dx, dz = nextNode.x - node.x, nextNode.z - node.z
            local l = math.sqrt(dx * dx + dz * dz)
            if l > 1e-6 then wdx, wdz = dx / l, dz / l end
            node = nextNode
            seq[#seq + 1] = node
        end
        -- DOES THIS LANE STILL RUN THROUGH? Asked structurally: can the walk go anywhere from
        -- here that is not where it came from and not about to be cleared. A lane that runs through
        -- always can; one that now dead-ends at the junction cannot, and that end is what gets
        -- tidied.
        --
        -- This used to be a proxy - "distance to the centre started increasing while within 16 m" -
        -- and on a curving approach it tripped about 10 m out, before the lane ever reached the
        -- junction. Worse, it gave DIFFERENT answers before and after the deletion: the real apply
        -- walked a graph where the lane genuinely ended first, so it never tripped, while the same
        -- code run as a preview rejected 7 of 8 lanes. A structural test cannot drift that way.
        local onward = useOut and (seq[#seq].out or {}) or (seq[#seq].incoming or {})
        local continues = false
        for _, nid in pairs(onward) do
            if nid ~= cameFrom and not skip[nid]
                and not cut[seq[#seq].id * 100000 + nid] then continues = true break end
        end
        -- AND THE END HAS TO BE AT THIS JUNCTION. The walk runs from the far anchor inward and
        -- tidies wherever it stops - but if a NEIGHBOURING junction has already been cleared, the
        -- lane now dead-ends at that neighbour's gap, the walk stops there, and the tidy trims the
        -- neighbour's mouth instead of this one's. Nothing else notices, because a dead end is a
        -- dead end wherever it is.
        local tip = seq[#seq]
        -- Measured from the BOX centre once it is known: the locked centre can sit 12 m to one
        -- side of a skewed junction, which put the far arm's ends 27 m "away" and outside this gate,
        -- so they were never brought in.
        local gc = gateCentre or centre
        local atThis = (tip.x - gc.x) ^ 2 + (tip.z - gc.z) ^ 2 <= 25 * 25
        return { ap = ap, seq = seq, useOut = useOut, cameFrom = cameFrom,
            tidy = (not continues) and #seq >= 2 and atThis,
            reference = continues }
    end

    -- PASS 1: walk every lane and sort them into those still running THROUGH the junction and those
    -- that now dead-end at it. Nothing is changed yet, because the through lanes are the reference
    -- the dead-ends get measured against and it has to be read before anything moves.
    local walked = {}
    for _, ap in ipairs(jp.approaches or {}) do
        if alive(ap.wp) and not skip[ap.wp.id] then walked[#walked + 1] = walkLane(ap) end
    end

    -- WHAT A TAIL STOPS AT: the other lanes' centrelines, each carried ACROSS the junction on its
    -- own arc. The surviving road stops short of the middle, so measuring only to what is left would
    -- have a tail chase the far side's stub and run straight through where the road used to be.
    -- Continuing each road over the gap on the curve it was already describing puts the reference
    -- back where the carriageway actually is.
    -- Each lane's line is fitted to its PARENT ROAD only, then carried on across the junction by the
    -- arc that road was already describing. The run set is the tool's own answer to "which of these
    -- nodes are road" - anchor in to the last fork - so the tie-ins and laid curves past it are
    -- excluded. Fitting the raw walk instead picked up the connectors: with through paths kept, a
    -- lane that runs through does so over the tool's OWN laid curve rather than over road, and that
    -- curve's geometry ended up defining where the road supposedly was.
    local runSet = jp.runNodes or {}
    for _, w in ipairs(walked) do
        if w.ap.roadLine ~= nil then w.line, w.realLine = w.ap.roadLine, true end
    end
    for _, w in ipairs(walked) do
        local road, k = {}, 0
        for i, n in ipairs(w.seq) do
            if runSet[n] then k = i end
        end
        if k < 2 then k = math.min(#w.seq, 2) end
        -- A LANE WITH NO THROUGH PARTNER ENDS AT ITS FIRST FORK NEAR THE JUNCTION. At a skewed T the
        -- side road's turn onto the main road bends only 30 degrees, the walk takes it for road,
        -- and the side road's "line" ran on down the main road - bending its box round the corner.
        -- Its road is what comes BEFORE the wiring starts; from there it is carried straight.
        local straightCarry = (w.line == nil)   -- no through partner: carried on its own heading, preview and apply alike
        if w.line == nil then
            for i = 2, k do
                local n = w.seq[i]
                if (n.x - centre.x) ^ 2 + (n.z - centre.z) ^ 2 <= 25 * 25 then
                    local seen, deg = {}, 0
                    for _, lst in ipairs({ n.out or {}, n.incoming or {} }) do
                        for _, id in pairs(lst) do if not seen[id] then seen[id] = true deg = deg + 1 end end
                    end
                    if deg >= 3 then k = i straightCarry = true break end
                end
            end
        end
        -- Only reached by a road that ENDS at this junction - a through road has its real line
        -- already. It has to be carried across, and it is carried from its CLEAN stretch: the last
        -- few metres of a lane are where old tie-ins and re-laid ends bend things, and reading the
        -- heading off that tip gave one T's stem a band at 162 degrees where the stem runs at 110.
        -- So the line stops 8 m short of the junction and its heading is taken over the ten metres
        -- before that, not over one segment.
        while k > 2 and (w.seq[k].x - centre.x) ^ 2 + (w.seq[k].z - centre.z) ^ 2 < 8 * 8 do
            k = k - 1
        end
        for i = 1, k do
            local n = w.seq[i]
            if (n.x - centre.x) ^ 2 + (n.z - centre.z) ^ 2 <= 35 * 35 then
                road[#road + 1] = { x = n.x, z = n.z }
            end
        end
        if k >= 2 then
            local sub = {}
            for i = 1, k do sub[i] = w.seq[i] end
            local base, run = k - 1, 0
            while base > 1 and run < 10 do
                run = run + math.sqrt((sub[base + 1].x - sub[base].x) ^ 2 + (sub[base + 1].z - sub[base].z) ^ 2)
                if run < 10 then base = base - 1 end
            end
            local arc = laneArc(sub, sub[k], sub[base], 0, straightCarry)
            for i = 2, (arc ~= nil) and #arc or 0 do
                if (arc[i].x - centre.x) ^ 2 + (arc[i].z - centre.z) ^ 2 <= 35 * 35 then
                    road[#road + 1] = { x = arc[i].x, z = arc[i].z }
                end
            end
        end
        if w.line == nil and #road >= 2 then w.line = road end
    end
    -- ONE SET OF ROAD LINES, MEASURED ONCE. The preview reads each lane's line off the junction as
    -- it stands; the apply used to read them again AFTER the clear had deleted half the wiring, and
    -- got different lines - a side road's claim that ran on down the main road because its turn
    -- connector happened to still be there. The box the ends were brought to was then not the box
    -- the preview had drawn. The preview's lines are kept and the apply lays its ends against
    -- exactly those.
    if dry then
        jp._tidyLines = {}
        for _, w in ipairs(walked) do
            jp._tidyLines[w.ap] = { line = w.line, real = w.realLine }
        end
    elseif jp._tidyLines ~= nil then
        for _, w in ipairs(walked) do
            local kept = jp._tidyLines[w.ap]
            if kept ~= nil and kept.line ~= nil then w.line, w.realLine = kept.line, kept.real end
        end
    end


    local function nearestOn(line, px, pz)
        local bx, bz, best = nil, nil, math.huge
        for k = 2, #line do
            local ax, az = line[k - 1].x, line[k - 1].z
            local vx, vz = line[k].x - ax, line[k].z - az
            local L2 = vx * vx + vz * vz
            if L2 > 1e-9 then
                local t = math.max(0, math.min(1, ((px - ax) * vx + (pz - az) * vz) / L2))
                local qx, qz = ax + vx * t, az + vz * t
                local d = (px - qx) ^ 2 + (pz - qz) ^ 2
                if d < best then best, bx, bz = d, qx, qz end
            end
        end
        if bx == nil then return nil, math.huge end
        return { x = bx, z = bz }, math.sqrt(best)
    end
    local function lineDist(line, px, pz)
        local _, d = nearestOn(line, px, pz)
        return d
    end
    local function lineDir(line)
        local a, b = line[1], line[#line]
        local vx, vz = b.x - a.x, b.z - a.z
        local l = math.sqrt(vx * vx + vz * vz)
        if l < 1e-6 then return nil end
        return vx / l, vz / l
    end

    -- THE PARENT ROADS, AND THE BOX THEY MAKE.
    --
    -- A road through a junction is normally a PAIR of parallel tracks, one per direction. Pair them,
    -- measure how far apart they are, and merge them into one line: that merged line is the centre of
    -- the road. The box is then simply that centre offset either side by the distance the tracks were
    -- apart. The road states its own width, so there is no margin to tune and nothing that has to be
    -- told what kind of junction this is.
    --
    -- A road with a single track has no separation to measure, so it takes a fixed offset.
    local SINGLE = AutoDrive.FLYOVER_JUNCTION_TRACK_CLEARANCE or 2.5
    -- Each track is compared AT THE JUNCTION - the point on it nearest the centre of the tracks, and
    -- the way it runs there. Comparing whole lines instead compares them at their outer anchors 45 m
    -- out, where two tracks of one road have long since diverged, and one road comes back as several.
    for _, w in ipairs(walked) do
        if w.line ~= nil and #w.line >= 2 then
            local bi, bd = nil, math.huge
            for k, pt in ipairs(w.line) do
                local d = (pt.x - centre.x) ^ 2 + (pt.z - centre.z) ^ 2
                if d < bd then bd, bi = d, k end
            end
            -- Over about 8 m either side. Three indices either side is 1.5 m on an arc sampled at
            -- 0.25 m and could be 30 m on a recorded road - either way not a heading to trust.
            local function reach(from, step)
                local i, run = from, 0
                while run < 8 do
                    local j = i + step
                    if j < 1 or j > #w.line then break end
                    run = run + math.sqrt((w.line[j].x - w.line[i].x) ^ 2 + (w.line[j].z - w.line[i].z) ^ 2)
                    i = j
                end
                return w.line[i]
            end
            local a, b = reach(bi, -1), reach(bi, 1)
            local vx, vz = b.x - a.x, b.z - a.z
            local l = math.sqrt(vx * vx + vz * vz)
            if l > 1e-6 then
                w.at, w.hx, w.hz = w.line[bi], vx / l, vz / l
            end
        end
    end

    local roads = {}
    for _, w in ipairs(walked) do
        if w.at ~= nil then
            local joined = nil
            for _, r in ipairs(roads) do
                -- Same road: running the same way, or the opposite way, which is the other direction
                -- of the same carriageway. Abreast of each other rather than nose to tail.
                if math.abs(r.hx * w.hx + r.hz * w.hz) > 0.85 then
                    local ox, oz = w.at.x - r.at.x, w.at.z - r.at.z
                    if math.abs(ox * -r.hz + oz * r.hx) < 12
                        and math.abs(ox * r.hx + oz * r.hz) < 12 then
                        joined = r break
                    end
                end
            end
            if joined == nil then
                roads[#roads + 1] = { hx = w.hx, hz = w.hz, at = w.at, real = (w.realLine == true),
                    members = { w.line }, tracks = { w }, lanes = { [w] = true } }
            else
                joined.members[#joined.members + 1] = w.line
                joined.tracks[#joined.tracks + 1] = w
                joined.lanes[w] = true
            end
        end
    end

    -- Merge each road's tracks into one line, and take the offset from HOW FAR APART THEY ARE: the
    -- widest gap across the road. The max and not the mean, because a road entered from both ends
    -- contributes the same track twice and those duplicates sit on top of each other - averaging
    -- them in drags the width towards nothing.
    --
    -- MEASURED ALONG THE ROAD, NOT AT THE JUNCTION. One sample, taken where the track meets the
    -- junction, is taken at the one place a road is not its own width: the lanes are already
    -- pinching together or flaring apart for the turns. Measured out to 25 m, every road on the test
    -- map holds its width to within a few centimetres from 3 m out to 30 m - except where the single
    -- sample landed in a pinch and called a 3.9 m road 3.06 m wide, which is what tilted the box and
    -- pushed the cut off to one side. The same road read 2.50 m one way and 4.23 m the other.
    --
    -- So it is sampled at intervals along the road and the MIDDLE reading is kept. The middle, not
    -- the average: a pinch at one end drags an average, and cannot move the middle.
    local WNEAR, WFAR = 8, 30
    local jctX, jctZ = centre.x, centre.z
    for _, r in ipairs(roads) do
        -- The road's own first track is the spine. Every OTHER track is measured against it, at each
        -- of its vertices that lies between WNEAR and WFAR from the junction - so the reading follows
        -- the road round its bends instead of marching off a straight heading, which on a curving
        -- road walks clean off the track within a few metres.
        local spine = r.members[1]
        local reads = {}
        if spine ~= nil and #r.members >= 2 then
            for _, p in ipairs(spine) do
                -- MEASURED OUT FROM THE MIDDLE OF THE JUNCTION, not from the road's anchor. A road's
                -- line runs THROUGH the junction, so "4 to 25 m from the anchor" also catches the
                -- stretch on the far side of it - and near the middle the lanes converge into their
                -- connectors. Half of one road's 95 readings fell below 2.5 m that way and its width
                -- came out on the single-track floor, giving a box far too narrow for a two-lane road.
                local dj = math.sqrt((p.x - jctX) ^ 2 + (p.z - jctZ) ^ 2)
                if dj >= WNEAR and dj <= WFAR then
                    local widestHere = 0
                    for k = 2, #r.members do
                        local line = r.members[k]
                        local bd = math.huge
                        for i2 = 1, #line - 1 do
                            local a, b = line[i2], line[i2 + 1]
                            local ax, az = b.x - a.x, b.z - a.z
                            local L = ax * ax + az * az
                            local u = (L > 0) and ((p.x - a.x) * ax + (p.z - a.z) * az) / L or 0
                            u = math.max(0, math.min(1, u))
                            local ex, ez = a.x + ax * u - p.x, a.z + az * u - p.z
                            local dd = ex * ex + ez * ez
                            if dd < bd then bd = dd end
                        end
                        bd = math.sqrt(bd)
                        if bd > widestHere then widestHere = bd end
                    end
                    if widestHere > 0 then reads[#reads + 1] = widestHere end
                end
            end
        end
        local widest = 0
        if #reads >= 3 then
            -- HIGH UP THE READINGS, NOT THE MIDDLE OF THEM. A road's line runs both ways from the
            -- junction and the two halves need not be the same road: at one site it is two lanes
            -- 3.8 m apart to the south-east and a pair merging into one - 2.3 m, then 1.4 m - to the
            -- north-west. The middle of all of them came out on the single-track floor and the box
            -- was built far too narrow for the lanes it had to cover. The claim band has to cover
            -- the road where it is WIDEST near the junction, so the reading four fifths of the way
            -- up is taken: a merging half cannot drag it down, and one wide stray cannot lift it.
            table.sort(reads)
            widest = reads[math.max(1, math.floor(#reads * 0.8))]
        else
            for _, t in ipairs(r.tracks) do
                local ox, oz = t.at.x - r.at.x, t.at.z - r.at.z
                local perp = math.abs(ox * -r.hz + oz * r.hx)
                if perp > widest then widest = perp end
            end
        end
        r.offset = math.max(SINGLE, widest)
        if #r.members == 1 then
            r.centre = r.members[1]
        else
            local base, merged = r.members[1], {}
            for _, pt in ipairs(base) do
                local sx, sz, c = pt.x, pt.z, 1
                local votes = {}
                for k = 2, #r.members do
                    local q, d = nearestOn(r.members[k], pt.x, pt.z)
                    -- ONE VOTE PER TRACK. A road entered from both ends hands in the same
                    -- track twice (its entry and its exit walk the same lane), and averaging the
                    -- duplicate in pulled the "centre" half a metre towards that lane - so one
                    -- track of every through road was laid 0.5 m inside its own line and the
                    -- other 0.5 m outside: a sideways kick on the end of each.
                    if q ~= nil and d < 25 then
                        local dup = (d < 0.75)
                        for _, v in ipairs(votes) do
                            if (v.x - q.x) ^ 2 + (v.z - q.z) ^ 2 < 0.75 * 0.75 then dup = true break end
                        end
                        if not dup then
                            votes[#votes + 1] = q
                            sx, sz, c = sx + q.x, sz + q.z, c + 1
                        end
                    end
                end
                merged[#merged + 1] = { x = sx / c, z = sz / c }
            end
            r.centre = (#merged >= 2) and merged or base
        end
    end

    -- THE JUNCTION IS WHERE THE ROADS CROSS, not where the tie nodes happen to cluster.
    --
    -- `centre` is the locked crossing: a centroid of fork nodes. At a 4-way those sit all round the
    -- middle and the centroid is the middle. At a built T they can be just the STEM'S two tie nodes -
    -- and then the "centre" sits at the stem's tip, 10 m short of the road it meets. Everything that
    -- looks for the box from there found nothing: the box-edge search starts from the point nearest
    -- the centre and asks whether it is inside the other road's claim (it was not, by 5 m), the box
    -- sweep reached 10 m from the wrong place, and the stem was never brought up to the road.
    --
    -- The roads are known by now, each as a centre line carried across the junction, so the middle
    -- of the box is simply where two of them that are not parallel cross - the crossing nearest the
    -- locked point, since two roads can meet again further out.
    local boxCentre = centre
    -- The two roads whose crossing IS this junction. Only their claims make its box.
    local boxRoadA, boxRoadB = nil, nil
    do
        local best, bestD = nil, math.huge
        for i = 1, #roads do
            for j = i + 1, #roads do
                local a, b = roads[i], roads[j]
                if a.centre ~= nil and b.centre ~= nil and #a.centre >= 2 and #b.centre >= 2
                    and math.abs(a.hx * b.hx + a.hz * b.hz) <= 0.85 then
                    local cum = cumulative(a.centre)
                    local at = 0
                    while at <= cum[#cum] do
                        local pt = atArc(a.centre, cum, at)
                        local dc = (pt.x - centre.x) ^ 2 + (pt.z - centre.z) ^ 2
                        if dc < bestD and lineDist(b.centre, pt.x, pt.z) <= 0.5 then
                            bestD, best = dc, pt
                            boxRoadA, boxRoadB = a, b
                        end
                        at = at + 0.25
                    end
                end
            end
        end
        if best ~= nil and bestD <= 25 * 25 then boxCentre = { x = best.x, z = best.z } end
        gateCentre = boxCentre
        -- The lanes were walked before the box was known; judge their ends again from its middle.
        for _, w in ipairs(walked) do
            local tip = w.seq[#w.seq]
            if tip ~= nil and not w.reference and #w.seq >= 2 then
                w.tidy = (tip.x - boxCentre.x) ^ 2 + (tip.z - boxCentre.z) ^ 2 <= 25 * 25
            end
        end
    end

    -- Inside the box: within its own road's offset of that road's centre. A lane never measures
    -- against the road it is itself part of.
    local function insideBox(px, pz, self_)
        -- The lane's own road, so a road running alongside it can be told from one it meets.
        local own = nil
        for _, r in ipairs(roads) do if r.lanes[self_] then own = r break end end
        for _, r in ipairs(roads) do
            local parallel = own ~= nil and math.abs(r.hx * own.hx + r.hz * own.hz) > 0.85
            if not r.lanes[self_] and not parallel and lineDist(r.centre, px, pz) <= r.offset then
                return true
            end
        end
        return false
    end

    -- WHERE THE TURN STARTS. Walking a lane in from its anchor, the parent road holds a steady
    -- curvature, or one that changes slowly; a turn leaves it, and its curvature departs sharply.
    -- The index where that departure begins is the start of the turn, and everything from there
    -- inward is junction wiring whatever it happens to be labelled.
    --
    -- This is what finally removes a connector the clear left behind. Identifying wiring node by
    -- node never worked: a connector is laid tangent-continuous onto its lane, so the chain walk runs
    -- straight onto it and marks it road, and from then on it is protected from clearing. Cutting the
    -- lane back past the departure and re-laying the road into the box sidesteps the identification
    -- problem entirely - whatever was inward of the cut is gone, connector or not.
    --
    -- The threshold adapts: a road that is itself curving has a spread of its own, so a departure has
    -- to stand out from THAT rather than from zero, or every bend would read as a turn.
    local function turnStart(seq)
        if #seq < 4 then return #seq end
        local back = { [#seq] = 0 }
        for i = #seq - 1, 1, -1 do
            back[i] = back[i + 1] + math.sqrt((seq[i + 1].x - seq[i].x) ^ 2
                + (seq[i + 1].z - seq[i].z) ^ 2)
        end
        local function atBack(d, from)
            for i = from, 1, -1 do
                if back[i] - back[from] >= d then return seq[i] end
            end
            return nil
        end
        -- Signed curvature at each node, read over about 10 m of lane behind it.
        local k = {}
        for i = 3, #seq do
            local c = seq[i]
            local b = atBack(5, i)
            local a = atBack(10, i)
            if a ~= nil and b ~= nil then
                local ax, az = b.x - a.x, b.z - a.z
                local bx, bz = c.x - b.x, c.z - b.z
                local cx2, cz2 = c.x - a.x, c.z - a.z
                local la = math.sqrt(ax * ax + az * az)
                local lb = math.sqrt(bx * bx + bz * bz)
                local lc = math.sqrt(cx2 * cx2 + cz2 * cz2)
                if la > 1e-3 and lb > 1e-3 and lc > 1e-3 then
                    k[i] = 2 * (ax * bz - az * bx) / (la * lb * lc)
                end
            end
        end
        -- The road's own curvature, taken from the OUTER half of the lane where no junction wiring
        -- can reach. Median and median deviation, so one odd node cannot set the baseline.
        local outer = {}
        for i = 3, #seq do
            if k[i] ~= nil and back[i] > back[1] * 0.5 then outer[#outer + 1] = k[i] end
        end
        if #outer < 3 then return #seq end
        table.sort(outer)
        local kRoad = outer[math.ceil(#outer / 2)]
        local devs = {}
        for _, v in ipairs(outer) do devs[#devs + 1] = math.abs(v - kRoad) end
        table.sort(devs)
        local spread = devs[math.ceil(#devs / 2)]
        local limit = math.max(0.02, spread * 4)
        -- First departure, walking inward. Two nodes in a row must exceed it, so a single noisy
        -- reading cannot cut a lane in half.
        for i = 3, #seq - 1 do
            if k[i] ~= nil and k[i + 1] ~= nil
                and math.abs(k[i] - kRoad) > limit and math.abs(k[i + 1] - kRoad) > limit then
                return math.max(2, i - 1)
            end
        end
        return #seq
    end

    -- THE BOX INTERIOR IS JUNCTION, NOT ROAD - whatever the walk called it.
    --
    -- Inside the box nothing is parent road by definition: the box is where the roads' own offset
    -- lines cross, and what lies within it is the junction's wiring - through paths, tie nodes,
    -- connector tails. The chain walk cannot be trusted to say so. A connector is laid
    -- tangent-continuous, so the walk runs straight onto it and marks it road, and at a built 4-way
    -- that put dozens of laid nodes on the never-clearable list and left the interior behind as
    -- fragments whenever through paths were cleared. Asking WHERE a node is instead of what the walk
    -- thought of it needs no such judgement.
    --
    -- Through paths kept: everything in the box goes EXCEPT the kept routes. Through paths cleared:
    -- everything in the box goes. Either way the lanes are then walked again, because they end
    -- somewhere else now, and the per-road pass below brings each end to the box edge.
    --
    -- Bounded to the box that contains this junction's centre. Two of these roads may well cross
    -- again further out, or one may cross a road belonging to the junction next door.
    local swept, severed = {}, 0
    if #roads >= 2 then
        local keptThrough = (self.junctionLeaveThrough ~= false) and (jp.protectedOf or {}) or {}
        -- Kept: the through routes being left, and ANOTHER junction's wiring whichever way that
        -- toggle is set. A neighbour's connector can tail off right into this box; it is still the
        -- neighbour's.
        local theirs = jp.foreignWiring or {}
        local kept = setmetatable({}, { __index = function(_, k) return keptThrough[k] or theirs[k] end })
        local maxOff = 0
        for _, r in ipairs(roads) do if r.offset > maxOff then maxOff = r.offset end end
        local reach = maxOff * 1.5 + 2
        local reach2 = reach ^ 2
        -- In the box: inside the claims of two roads that are not parallel, near the box's middle.
        local function inBox(x, z)
            if (x - boxCentre.x) ^ 2 + (z - boxCentre.z) ^ 2 > reach2 then return false end
            -- THIS junction's box is the overlap of the two roads that cross HERE. Where a second
            -- side road joins 18 m along, its claim crosses the main road's too and makes a second
            -- box - the neighbour's - and sweeping that as well cut the main road at both T's; the
            -- stretch left between them was then a short dead stub, and the stub sweep took it.
            if boxRoadA ~= nil then
                return lineDist(boxRoadA.centre, x, z) <= boxRoadA.offset
                    and lineDist(boxRoadB.centre, x, z) <= boxRoadB.offset
            end
            local first = nil
            for _, r in ipairs(roads) do
                if lineDist(r.centre, x, z) <= r.offset then
                    if first == nil then
                        first = r
                    elseif math.abs(first.hx * r.hx + first.hz * r.hz) <= 0.85 then
                        return true
                    end
                end
            end
            return false
        end
        local sweptSet = {}
        for _, n in pairs(ADGraphManager:getWayPoints()) do
            if n ~= nil and n.id ~= nil and not skip[n.id] and not kept[n] and inBox(n.x, n.z) then
                swept[#swept + 1] = n
                sweptSet[n] = true
            end
        end
        -- AND THE LINKS THAT CROSS IT. A box is only 7-10 m across and a road's nodes can be 13 m
        -- apart, so a lane can run clean through the box without a single node inside it: nothing
        -- to sweep, and the junction stayed joined. That is how a T cleared with through paths off
        -- kept its through road running, and how a connector's long last segment survived a clear.
        -- A link whose line passes through the box is junction wiring exactly as a node in it is.
        -- Kept through routes are spared link by link, the same way their nodes are.
        local crossing = {}
        local far2 = (reach + 30) ^ 2
        for _, n in pairs(ADGraphManager:getWayPoints()) do
            if n ~= nil and n.id ~= nil and not skip[n.id] and not sweptSet[n]
                and (n.x - boxCentre.x) ^ 2 + (n.z - boxCentre.z) ^ 2 <= far2 then
                for _, oid in pairs(n.out or {}) do
                    local o = ADGraphManager:getWayPointById(oid)
                    if o ~= nil and not skip[oid] and not sweptSet[o] and not (kept[n] and kept[o])
                        and not cut[n.id * 100000 + oid] then
                        local vx, vz = o.x - n.x, o.z - n.z
                        local len = math.sqrt(vx * vx + vz * vz)
                        local steps = math.floor(len / 0.5)
                        for k = 1, steps - 1 do
                            local t = k / steps
                            if inBox(n.x + vx * t, n.z + vz * t) then
                                crossing[#crossing + 1] = { n, o }
                                break
                            end
                        end
                    end
                end
            end
        end
        for _, pr in ipairs(crossing) do
            if dry then
                cut[pr[1].id * 100000 + pr[2].id] = true
                cut[pr[2].id * 100000 + pr[1].id] = true
            else
                junctionDisconnect(pr[1], pr[2])
            end
            severed = severed + 1
        end
        if #swept > 0 or severed > 0 then
            if dry then
                for _, n in ipairs(swept) do skip[n.id] = true end
            else
                local ids = {}
                for _, n in ipairs(swept) do if alive(n) then ids[#ids + 1] = n.id end end
                -- Highest id first: every removal renumbers the ids above it.
                table.sort(ids, function(a, b) return a > b end)
                for _, id in ipairs(ids) do
                    jxRemove(id, "junction box sweep")
                end
            end
            for _, w in ipairs(walked) do
                if alive(w.ap.wp) and not skip[w.ap.wp.id] then
                    local nw = walkLane(w.ap)
                    w.seq, w.cameFrom, w.tidy, w.reference = nw.seq, nw.cameFrom, nw.tidy, nw.reference
                else
                    w.tidy = false
                end
            end
        end
    end

    -- THE EDGE OF *THIS* JUNCTION'S BOX along a path, as an arc length - or nil if the path never
    -- enters it.
    --
    -- Found from the INSIDE OUT: go to where the path comes closest to the junction, confirm that
    -- point lies inside another road's claim, then walk back out along the path until it does not.
    -- The scan used to run from the far end inward and stop at the FIRST claim it met. A lane is
    -- walked from 45 m out, and if there is another junction within that distance the first claim
    -- it meets belongs to THAT junction - so the lane was trimmed back to clear a box 24 m away,
    -- and the ends at this junction were left stranded 11 to 16 m out. Same root as the tidy
    -- "trimming stuff at another intersection": a first-match scan has no idea which junction it
    -- is looking at.
    local function boxEdgeAlong(sample, total, inside)
        local sC, dC, sx = nil, math.huge, 0
        while sx <= total do
            local pt = sample(sx)
            local d = (pt.x - boxCentre.x) ^ 2 + (pt.z - boxCentre.z) ^ 2
            if d < dC then dC, sC = d, sx end
            sx = sx + 0.25
        end
        if sC == nil then return nil end
        local pc = sample(sC)
        if not inside(pc.x, pc.z) then return nil end
        while sC >= 0.25 do
            local pt = sample(sC - 0.25)
            if not inside(pt.x, pt.z) then break end
            sC = sC - 0.25
        end
        return sC
    end

    -- PASS 2: TIDY PER ROAD, NOT PER LANE.
    --
    -- "The tracks stay parallel to the parent road" is a constraint BETWEEN the two tracks of a
    -- road, and a per-lane loop has nowhere to express it. Each track got its own walk, its own
    -- fitted arc and its own run-in, so they drifted apart over the few metres they were laid
    -- across: a road running at a constant 3.9 m opened to 6.4 m at the junction mouth, which puts
    -- the tracks off the road surface. Every attempt to fix that from inside the per-lane loop was
    -- one track reaching sideways for information about its partner, and each one broke something
    -- else - 8.9 m one way, a 0.6 m pinch the other.
    --
    -- So a road is tidied as one object. Its centre and width are read from the pair OUT WHERE IT IS
    -- CLEAN - far enough that the junction's old wiring has not splayed them - the centre is carried
    -- in to the box once, and both tracks are laid along it at half that width. Parallel by
    -- construction, and the width is an input rather than an outcome.
    local CLEAN_AT = 15

    -- Which other road's claim this one stops at.
    -- A ROAD RUNNING ALONGSIDE IS NOT A ROAD YOU STOP AT. Two roads a few degrees apart that were
    -- not merged into one still overlap each other's claims further out from the junction, and the
    -- scan took that overlap for the box edge - 25 m up the road - and trimmed the lane back to it.
    -- The same parallel test that decides whether two tracks are ONE road decides this: if it is
    -- parallel enough that it could have been my own carriageway, it is not my crossing. Anything
    -- meeting at a real angle, however shallow, still counts.
    local function insideOther(px, pz, self_)
        for _, rr in ipairs(roads) do
            if rr ~= self_ and math.abs(rr.hx * self_.hx + rr.hz * self_.hz) <= 0.85
                and lineDist(rr.centre, px, pz) <= rr.offset then
                return true
            end
        end
        return false
    end
    -- A point on a track's surviving nodes at a given distance from the junction.
    local function onTrackAt(w, d)
        local best, bd = nil, math.huge
        for _, n in ipairs(w.seq) do
            local e = math.abs(math.sqrt((n.x - boxCentre.x) ^ 2 + (n.z - boxCentre.z) ^ 2) - d)
            if e < bd then bd, best = e, n end
        end
        -- From the BOX centre, and tolerant of a sparse road: a lane with 13 m between its points
        -- has nothing within 5 m of any given ring, and a road that could not be measured was
        -- silently skipped - its ends left wherever the clear dropped them.
        return (bd < 9) and best or nil
    end
    -- The local direction of a polyline at index k, and the left normal.
    local function dirAtIndex(line, k)
        local a = line[math.max(1, k - 1)]
        local b = line[math.min(#line, k + 1)]
        local vx, vz = b.x - a.x, b.z - a.z
        local l = math.sqrt(vx * vx + vz * vz)
        if l < 1e-6 then return nil end
        return vx / l, vz / l
    end

    local ends = dry and {} or nil
    local handled = {}
    local trimmed, added, lanes = 0, 0, 0
    -- WHAT HAPPENED TO EACH LANE, SAID OUT LOUD. A lane whose path never meets the box was skipped
    -- in silence: no trim, no extension, no mention - so a road left stopping fifteen metres short
    -- looked exactly like a road the tool had decided to leave. One lane at j33 ended 18.5 m from
    -- the middle while its partner reached 5.1 m, and nothing in the log said which pass had
    -- declined it or why. Every lane now reports its outcome, and the capture picks these up with
    -- everything else, so the game answers the question without the offline harness in the loop.
    local laneReport = {}
    -- A ROAD THROUGH A JUNCTION ARRIVES FROM BOTH ENDS, and each end is tidied on its own.
    --
    -- Everything below measures along one centreline, running in from one end of the road. Tracks
    -- arriving from the FAR end sit past the box on that measure, so they read as having overshot it
    -- by the width of the whole junction - 14 to 16 m at a 4-way - and were trimmed AWAY from the
    -- junction instead of being brought to their own edge of the box. Half the ends at any junction
    -- cleared with through paths off finished 9-11 m out because of it. A lane's walk always runs
    -- anchor-inward whichever way it is driven, so its last segment points at the junction, and two
    -- lanes on the same side of it point the same way.
    local units = {}
    for _, r in ipairs(roads) do
        local bySide = {}
        for _, w in ipairs(walked) do
            if r.lanes[w] and w.tidy and alive(w.seq[#w.seq]) and #w.seq >= 2 then
                local a, b = w.seq[#w.seq - 1], w.seq[#w.seq]
                local hx, hz = b.x - a.x, b.z - a.z
                local placed = false
                for _, sd in ipairs(bySide) do
                    if sd.hx * hx + sd.hz * hz > 0 then
                        sd.list[#sd.list + 1] = w
                        placed = true
                        break
                    end
                end
                if not placed then bySide[#bySide + 1] = { hx = hx, hz = hz, list = { w } } end
            end
        end
        for _, sd in ipairs(bySide) do
            units[#units + 1] = { r = r, todo = sd.list, hx = sd.hx, hz = sd.hz }
        end
    end
    for _, u in ipairs(units) do
        local r, todo = u.r, u.todo
        if #todo > 0 then
            -- Pair the road up and measure it where it is clean.
            local A = todo[1]
            local a0 = onTrackAt(A, CLEAN_AT)
            local B, width = nil, nil
            if a0 ~= nil then
                for _, w in ipairs(walked) do
                    local sameSide = false
                    if #w.seq >= 2 then
                        local pa, pb = w.seq[#w.seq - 1], w.seq[#w.seq]
                        sameSide = (u.hx * (pb.x - pa.x) + u.hz * (pb.z - pa.z)) > 0
                    end
                    if r.lanes[w] and w ~= A and sameSide then
                        -- PERPENDICULAR to the other track, not point to point. Two nodes that each
                        -- sit 15 m from the junction can be well offset ALONG the road, and the
                        -- straight line between them then overstates the gap - one road running at
                        -- 3.9 m measured 7.6 m that way, and the tracks were held that far apart.
                        local bl = {}
                        for _, n in ipairs(w.seq) do bl[#bl + 1] = { x = n.x, z = n.z } end
                        local _, g = nearestOn(bl, a0.x, a0.z)
                        if g ~= nil and g > 1.0 and g < 12 and (width == nil or g < width) then
                            B, width = w, g
                        end
                    end
                end
            end

            -- The road's centre: the midline of the pair, built from their own nodes, then carried
            -- on across the junction by the curve it was already describing.
            local full, fc = nil, nil
            if B ~= nil and r.real and r.centre ~= nil and #r.centre >= 3 then
                -- A THROUGH ROAD'S TRACKS FOLLOW ITS REAL CENTRE. The merged through routes already
                -- run right across the junction, so there is nothing to extrapolate: orient that line
                -- the way this side of the road approaches, and the tracks are laid parallel to the
                -- parent road because they are offsets of the parent road.
                local c1, cN = r.centre[1], r.centre[#r.centre]
                local fwd = ((cN.x - c1.x) * u.hx + (cN.z - c1.z) * u.hz) >= 0
                local raw = {}
                for i = 1, #r.centre do
                    local q = r.centre[fwd and i or (#r.centre + 1 - i)]
                    raw[#raw + 1] = { x = q.x, z = q.z }
                end
                -- Resampled every quarter metre. The real centre only has points where the road has
                -- nodes - anything from 1 to 13 m apart - and everything downstream finds the box
                -- edge by stepping along this line, so at node spacing the "first point inside the
                -- box" landed up to a whole segment past the edge: every end at a 4-way overshot by
                -- about 2 m.
                local rc = cumulative(raw)
                full = {}
                local at = 0
                while at <= rc[#rc] do
                    local q = atArc(raw, rc, at)
                    full[#full + 1] = { x = q.x, z = q.z }
                    at = at + 0.25
                end
                fc = cumulative(full)
            elseif B ~= nil then
                local bl = {}
                for _, n in ipairs(B.seq) do bl[#bl + 1] = { x = n.x, z = n.z } end
                local mid = {}
                for _, n in ipairs(A.seq) do
                    local q = nearestOn(bl, n.x, n.z)
                    if q ~= nil then
                        mid[#mid + 1] = { x = (n.x + q.x) * 0.5, y = n.y or 0, z = (n.z + q.z) * 0.5 }
                    end
                end
                if #mid >= 3 then
                    -- A side road's centre is carried across from its CLEAN stretch and STRAIGHT: the
                    -- last 18 m of its lanes is where old kickouts swing out, and a midline built
                    -- through them bent the whole run-in the way the turn used to go.
                    while #mid > 3 and (mid[#mid].x - boxCentre.x) ^ 2 + (mid[#mid].z - boxCentre.z) ^ 2 < 18 * 18 do
                        mid[#mid] = nil
                    end
                    local mb, mrun = #mid - 1, 0
                    while mb > 1 and mrun < 10 do
                        mrun = mrun + math.sqrt((mid[mb + 1].x - mid[mb].x) ^ 2 + (mid[mb + 1].z - mid[mb].z) ^ 2)
                        if mrun < 10 then mb = mb - 1 end
                    end
                    local ext = laneArc(mid, mid[#mid], mid[mb], 0, true)
                    full = {}
                    for _, q in ipairs(mid) do full[#full + 1] = q end
                    for i = 2, (ext ~= nil) and #ext or 0 do full[#full + 1] = ext[i] end
                    fc = cumulative(full)
                end
            end

            if full ~= nil then
                -- Where the road's centre meets the box. One answer for the whole road, so both
                -- tracks stop abreast instead of each finding its own boundary.
                local target = boxEdgeAlong(
                    function(at) return atArc(full, fc, at) end, fc[#fc],
                    function(x, z) return insideOther(x, z, r) end)

                -- Sanity: the pair must straddle the centre. Both tracks on one side means the
                -- midline is not where the road actually is, and laying them on it would collapse
                -- them together - measured 0.0 m apart at one T, with 17 points of road trimmed
                -- away chasing a boundary that was never in the right place.
                local straddles = true
                if target ~= nil and width ~= nil and #todo >= 2 then
                    local seenSign = nil
                    for _, w in ipairs(todo) do
                        local tip = w.seq[#w.seq]
                        local q = nearestOn(full, tip.x, tip.z)
                        local bi, bd = 1, math.huge
                        for k, ptc in ipairs(full) do
                            local d = (ptc.x - (q and q.x or tip.x)) ^ 2
                                + (ptc.z - (q and q.z or tip.z)) ^ 2
                            if d < bd then bd, bi = d, k end
                        end
                        local ux, uz = dirAtIndex(full, bi)
                        if ux == nil then straddles = false break end
                        local sg = (((tip.x - full[bi].x) * -uz + (tip.z - full[bi].z) * ux) >= 0)
                            and 1 or -1
                        if seenSign == nil then seenSign = sg
                        elseif sg ~= seenSign then seenSign = 0 end
                    end
                    if seenSign ~= 0 then straddles = false end
                end
                if target ~= nil and width ~= nil and straddles then
                    for _, w in ipairs(todo) do
                        handled[w] = true
                        local seq, useOut = w.seq, w.useOut
                        -- Which side of the centre this track runs, and how far along it the track
                        -- currently ends.
                        local tip = seq[#seq]
                        local q = nearestOn(full, tip.x, tip.z)
                        local bi, bd = 1, math.huge
                        for k, ptc in ipairs(full) do
                            local d = (ptc.x - (q and q.x or tip.x)) ^ 2 + (ptc.z - (q and q.z or tip.z)) ^ 2
                            if d < bd then bd, bi = d, k end
                        end
                        local ux, uz = dirAtIndex(full, bi)
                        if ux ~= nil then
                            local sgn = (((tip.x - full[bi].x) * -uz + (tip.z - full[bi].z) * ux) >= 0)
                                and 1 or -1
                            local side = sgn * width * 0.5
                            -- A TRACK THAT IS NOT ON ITS OFFSET LINE IS NOT DRAGGED ONTO IT. The run-in
                            -- is laid along the road's centre offset by half its width, which assumes
                            -- the track already sits there. Beside a hairpin it does not: the lane
                            -- comes out of the bend a couple of metres off that line, and a run-in
                            -- only 3 m long then had to cross the whole gap - a 60 degree hook on the
                            -- end of the lane. Where the end is more than a metre off, the run-in is
                            -- laid through the END instead: still an offset of the parent road, so
                            -- still parallel to it and still stopping on the box edge, just on the
                            -- line the track is actually on.
                            local lat = (tip.x - full[bi].x) * -uz + (tip.z - full[bi].z) * ux
                            -- Only when the lane is STEADY there. The end can also be a tie node an old kickout
                            -- left a little off the lane, and taking that one node's word moved a straight road's
                            -- run-in sideways instead - a hook the other way. The node before it has to sit on the
                            -- same line, to half a metre.
                            local lat2 = nil
                            if #seq >= 2 then
                                local pn = seq[#seq - 1]
                                local q2 = nearestOn(full, pn.x, pn.z)
                                if q2 ~= nil then lat2 = (pn.x - q2.x) * -uz + (pn.z - q2.z) * ux end
                            end
                            if math.abs(lat - side) > 1.0 and lat2 ~= nil and math.abs(lat2 - lat) <= 0.5 then side = lat end
                            -- A side road's centre is only a construction (there is no real road line
                            -- across the junction to offset from), so its tracks are never moved onto
                            -- it: each is carried in along ITS OWN line, read two nodes back from the
                            -- end so an old kickout's first swing does not set it.
                            if not r.real and #seq >= 3 then
                                local pn = onTrackAt(w, 18) or seq[#seq - 2]
                                local q3 = nearestOn(full, pn.x, pn.z)
                                if q3 ~= nil then side = (pn.x - q3.x) * -uz + (pn.z - q3.z) * ux end
                            end
                            -- This track's own line: the centre, offset to its side.
                            local off = {}
                            for k = 1, #full do
                                local vx, vz = dirAtIndex(full, k)
                                if vx ~= nil then
                                    off[#off + 1] = { x = full[k].x + -vz * side, y = full[k].y,
                                        z = full[k].z + vx * side, s = fc[k] }
                                end
                            end
                            -- A THROUGH LANE IS ITS OWN ORIGINAL THROUGH PATH, TRIMMED TO THE BOX. The path
                            -- this lane ran on before the clear is real geometry right across the
                            -- junction, so nothing needs constructing: no centre to find, no width to
                            -- measure, no offset to lay - which is where the half-metre kicks, the
                            -- wrong widths and the wiggles all came from. The lane is brought to the
                            -- box ALONG THAT PATH, and the respacing that follows is the smooth tool's
                            -- rebuild, which irons out what old tie-ins left in it.
                            if w.realLine and w.line ~= nil and #w.line >= 3 then
                                local own = {}
                                local a1, aN = w.line[1], w.line[#w.line]
                                local anchor = seq[1]
                                local fwd = ((a1.x - anchor.x) ^ 2 + (a1.z - anchor.z) ^ 2)
                                    <= ((aN.x - anchor.x) ^ 2 + (aN.z - anchor.z) ^ 2)
                                for i = 1, #w.line do
                                    local q = w.line[fwd and i or (#w.line + 1 - i)]
                                    own[#own + 1] = { x = q.x, z = q.z }
                                end
                                local oc = cumulative(own)
                                local fine, at = {}, 0
                                while at <= oc[#oc] do
                                    local q = atArc(own, oc, at)
                                    fine[#fine + 1] = { x = q.x, y = tip.y, z = q.z, s = at }
                                    at = at + 0.25
                                end
                                if #fine >= 3 then off = fine end
                            end
                            -- A SIDE-ROAD LANE FOLLOWS ITS OWN LINE, the same principle. There is no through
                            -- path to follow - building the junction consumed it - but the lane itself
                            -- is still there further back, clean: its line is read between 30 m and
                            -- 18 m out, behind where any kickout began, and carried straight to the box.
                            -- Not paired with its partner, not moved onto a centre: every attempt to
                            -- construct one bent the lane's end towards it.
                            if not r.real then
                                -- The last node still 16 m or more from the box, and one at least 8 m
                                -- behind it: by the lane's own nodes, however sparse they are.
                                local far, near = nil, nil
                                for i = #seq, 1, -1 do
                                    local n = seq[i]
                                    if (n.x - boxCentre.x) ^ 2 + (n.z - boxCentre.z) ^ 2 >= 16 * 16 then
                                        near = n
                                        for j = i - 1, 1, -1 do
                                            local m = seq[j]
                                            if (m.x - n.x) ^ 2 + (m.z - n.z) ^ 2 >= 8 * 8 then far = m break end
                                        end
                                        break
                                    end
                                end
                                if far ~= nil and near ~= nil and far ~= near then
                                    local hx2, hz2 = near.x - far.x, near.z - far.z
                                    local hl = math.sqrt(hx2 * hx2 + hz2 * hz2)
                                    if hl > 1 then
                                        hx2, hz2 = hx2 / hl, hz2 / hl
                                        local ray = {}
                                        for i = 0, 200 do
                                            local d = i * 0.25
                                            ray[#ray + 1] = { x = near.x + hx2 * d, y = near.y or tip.y,
                                                z = near.z + hz2 * d, s = d }
                                        end
                                        off = ray
                                    end
                                end
                            end
                            if #off >= 3 then
                                -- EACH TRACK STOPS ON THE BOX EDGE ITSELF, not at a point shared
                                -- with its partner. The box edge is an offset of the PARENT road, so
                                -- ends that each land on it line up parallel to the parent road by
                                -- construction. One stopping point for the whole road - measured
                                -- along the stem's own centre - cut the pair off square to the
                                -- STEM instead, which is skewed at any junction that does not meet
                                -- at a right angle. The tracks still run parallel to their road's
                                -- centre at its width; only where each one ends is its own.
                                local target = target
                                do
                                    -- Same inside-out search, over this track's own offset line.
                                    local kC, dC = nil, math.huge
                                    for k, o in ipairs(off) do
                                        local d = (o.x - boxCentre.x) ^ 2 + (o.z - boxCentre.z) ^ 2
                                        if d < dC then dC, kC = d, k end
                                    end
                                    if kC ~= nil and insideOther(off[kC].x, off[kC].z, r) then
                                        while kC > 1 and insideOther(off[kC - 1].x, off[kC - 1].z, r) do
                                            kC = kC - 1
                                        end
                                        target = off[kC].s
                                    end
                                end
                                -- Spacing: the lane's own, from the segments it already has.
                                local sum, cnt = 0, 0
                                for i = math.max(2, #seq - 5), #seq do
                                    local a, b = seq[i - 1], seq[i]
                                    sum = sum + math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
                                    cnt = cnt + 1
                                end
                                local spacing = math.max(1.5, math.min(12,
                                    (cnt > 0 and sum > 0) and (sum / cnt) or 4))

                                -- How far along the road each surviving node sits, so "past the
                                -- box" is judged on the road's own measure rather than on a
                                -- straight-line distance that a bend would distort.
                                local function along(n)
                                    local best, bs = math.huge, 0
                                    for _, o in ipairs(off) do
                                        local d = (o.x - n.x) ^ 2 + (o.z - n.z) ^ 2
                                        if d < best then best, bs = d, o.s end
                                    end
                                    return bs
                                end
                                local touched = false
                                local budget = AutoDrive.FLYOVER_JUNCTION_TRIM_BUDGET or 8
                                -- Old kickouts start well back from the junction; taking their remains off a
                                -- lane end is allowed further than an ordinary trim.
                                local strayBudget = 20
                                -- How far a node sits OFF this track's own line.
                                local function astray(n)
                                    local best = math.huge
                                    for _, q in ipairs(off) do
                                        local d = (q.x - n.x) ^ 2 + (q.z - n.z) ^ 2
                                        if d < best then best = d end
                                    end
                                    return math.sqrt(best)
                                end
                                while #seq > 2 and (along(seq[#seq]) > target + 0.5
                                    -- ...or the lane's last nodes have already LEFT its line: the first
                                    -- few metres of an old kickout, still on the lane's end, swinging
                                    -- out for a turn that no longer exists. Running in from there put
                                    -- a sideways step in the lane. Same budget as any other trim.
                                    or (strayBudget > 0 and astray(seq[#seq]) > 0.5)) do
                                    local back = seq[#seq - 1]
                                    local step = math.sqrt((seq[#seq].x - back.x) ^ 2
                                        + (seq[#seq].z - back.z) ^ 2)
                                    local overBox = along(seq[#seq]) > target + 0.5
                                    if not overBox then
                                        if step > strayBudget then break end
                                        strayBudget = strayBudget - step
                                    elseif step > budget then break end
                                    if overBox then budget = budget - step end
                                    local doomed = seq[#seq]
                                    if not alive(doomed) then break end
                                    if dry then
                                        skip[doomed.id] = true
                                        seq[#seq] = nil
                                    else
                                        if not jxRemove(doomed, "junction tidy trim") then break end
                                        seq[#seq] = nil
                                        trimmed = trimmed + 1
                                    end
                                    touched = true
                                end

                                local from = along(seq[#seq])
                                local travel = target - from
                                if dry then
                                    -- Where it will ACTUALLY finish, which is the target only if the
                                    -- trim could reach it. Where the budget ran out first the end
                                    -- stays where the trim left it, and reporting the target instead
                                    -- had the preview promising ends 3.8 m from where they landed.
                                    local landed = nil
                                    if travel > 0.5 then
                                        for _, o in ipairs(off) do
                                            if o.s >= target then landed = o break end
                                        end
                                    else
                                        local tipNow = seq[#seq]
                                        landed = { x = tipNow.x, y = tipNow.y or 0, z = tipNow.z }
                                    end
                                    if landed ~= nil then
                                        ends[#ends + 1] = { x = landed.x, y = landed.y or 0,
                                            z = landed.z, dir = w.ap.dir, moved = math.abs(travel) }
                                    end
                                elseif travel > 0.5 then
                                    local last, back = seq[#seq], seq[#seq - 1]
                                    local segDual = (alive(last) and back ~= nil and alive(back)
                                        and table.contains(last.out or {}, back.id)
                                        and table.contains(back.out or {}, last.id)) or false
                                    local n = math.min(12, math.max(1,
                                        math.floor(travel / spacing + 0.5)))
                                    for i = 1, n do
                                        local want = from + (travel / n) * i
                                        local pt = off[#off]
                                        for _, o in ipairs(off) do
                                            if o.s >= want then pt = o break end
                                        end
                                        local made
                                        if not tryCall("junction tidy extend", function()
                                            made = ADFlyoverRecordWayPoint(pt.x, pt.y or last.y or 0,
                                                pt.z, false, false, false, 0,
                                                last.flags or AutoDrive.FLAG_NONE, false, ADFlyoverEditor.fieldOf(last))
                                            jxNoteAdded(made)
                                        end) or made == nil then break end
                                        if useOut then junctionConnect(seq[#seq], made, segDual)
                                        else junctionConnect(made, seq[#seq], segDual) end
                                        seq[#seq + 1] = made
                                        added, touched = added + 1, true
                                    end
                                end
                                if touched and not dry then lanes = lanes + 1 end
                            end
                        end
                    end
                end
            end
        end
    end


    -- FALLBACK: lanes the per-road pass could not take.
    --
    -- Holding two tracks parallel needs a road that IS a clean pair - one found at about 15 m out,
    -- straddling its own centre. A lone track, a two-way road carried on a single track, or a pair
    -- whose midline cannot be trusted has nothing to hold a width against, and forcing it collapsed
    -- both tracks onto one side. Those lanes keep the older treatment: each runs in on the curve it
    -- was already describing. It does not hold the road's width, but it does not invent one either.
    for _, w in ipairs(walked) do
        local ap, seq, useOut = w.ap, w.seq, w.useOut
        if w.tidy and not handled[w] and alive(seq[#seq]) then
            -- "Normal spacing" is the lane's OWN spacing, read off the segments it already has, not
            -- a constant: a hand-recorded road at 8 m and a laid curve at 1.5 m each keep their look.
            local sum, cnt = 0, 0
            for i = math.max(2, #seq - 5), #seq do
                local a, b = seq[i - 1], seq[i]
                sum = sum + math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
                cnt = cnt + 1
            end
            local spacing = math.max(1.5, math.min(12, (cnt > 0 and sum > 0) and (sum / cnt) or 4))

            -- The path: the road that is there, then the arc carrying it on across the junction.
            local tip, prev = seq[#seq], seq[#seq - 1]
            local vx, vz = tip.x - prev.x, tip.z - prev.z
            local segLen = math.sqrt(vx * vx + vz * vz)
            local grade = (segLen > 1e-3)
                and math.max(-0.15, math.min(0.15, ((tip.y or 0) - (prev.y or 0)) / segLen)) or 0
            local path = {}
            for _, n in ipairs(seq) do path[#path + 1] = { x = n.x, y = n.y or 0, z = n.z } end
            local arc = (segLen > 1e-3) and laneArc(seq, tip, prev, grade) or nil
            for i = 2, (arc ~= nil) and #arc or 0 do path[#path + 1] = arc[i] end
            local cum = cumulative(path)

            -- CUT BACK PAST THE TURN before anything else, so whatever the clear left of a
            -- connector goes with it. The box then decides where the rebuilt road stops.
            local ts = turnStart(seq)
            -- Capped like every other cut here. This one counts a curvature departure as the start
            -- of a turn and takes everything inward of it, and where that reading is wrong it takes
            -- the lane instead: 61 points at one site, 77 across another clear. A tidy trims a tail.
            local budget = AutoDrive.FLYOVER_JUNCTION_TRIM_BUDGET or 8
            while #seq > 2 and #seq > ts do
                local back = seq[#seq - 1]
                local step = math.sqrt((seq[#seq].x - back.x) ^ 2 + (seq[#seq].z - back.z) ^ 2)
                if step > budget then break end
                budget = budget - step
                local doomed = seq[#seq]
                if not alive(doomed) then break end
                if dry then
                    skip[doomed.id] = true
                    seq[#seq] = nil
                else
                    if not jxRemove(doomed, "junction tidy cut") then break end
                    seq[#seq] = nil
                    trimmed = trimmed + 1
                end
            end
            -- The cut never goes below two nodes, so the lane always keeps a direction.
            tip, prev = seq[#seq], seq[#seq - 1]
            vx, vz = tip.x - prev.x, tip.z - prev.z
            segLen = math.sqrt(vx * vx + vz * vz)
            grade = (segLen > 1e-3)
                and math.max(-0.15, math.min(0.15, ((tip.y or 0) - (prev.y or 0)) / segLen)) or 0
            path = {}
            for _, n in ipairs(seq) do path[#path + 1] = { x = n.x, y = n.y or 0, z = n.z } end
            arc = (segLen > 1e-3) and laneArc(seq, tip, prev, grade) or nil
            for i = 2, (arc ~= nil) and #arc or 0 do path[#path + 1] = arc[i] end
            cum = cumulative(path)

            -- Where that path first enters the box. Scanned from 30 m back, so a lane already poking
            -- into the junction is caught too - its entry point is behind its current end.
            local atNode = cum[#seq]
            local target = boxEdgeAlong(
                function(at) return atArc(path, cum, at) end, cum[#cum],
                function(x, z) return insideBox(x, z, w) end)

            if target ~= nil and dry then
                -- Walk the same trim the apply will, so the preview is bounded by the same budget.
                -- Reporting the target outright had it promising ends 3.8 m from where they landed,
                -- on lanes whose trim ran out of budget before it got there.
                local n, spend = #seq, AutoDrive.FLYOVER_JUNCTION_TRIM_BUDGET or 8
                while n > 2 and cum[n] > target + 0.5 do
                    local step = math.sqrt((seq[n].x - seq[n - 1].x) ^ 2
                        + (seq[n].z - seq[n - 1].z) ^ 2)
                    if step > spend then break end
                    spend = spend - step
                    skip[seq[n].id] = true
                    n = n - 1
                end
                local pt
                if cum[n] <= target + 0.5 then
                    pt = atArc(path, cum, target)
                else
                    pt = { x = seq[n].x, y = seq[n].y or 0, z = seq[n].z }
                end
                ends[#ends + 1] = { x = pt.x, y = pt.y or 0, z = pt.z, dir = ap.dir,
                    moved = math.abs(target - atNode) }
            elseif target ~= nil then
                local touched = false
                -- Drop whatever is past the boundary. Never below two nodes - a lane with one left
                -- has no direction and nothing could tie into it - and never more than a handful.
                --
                -- A TIDY TRIMS A TAIL; IT DOES NOT DIG UP A ROAD. Uncapped, this reached 77 points
                -- in one clear across five lanes, and 61 at another site: fifteen nodes of road per
                -- lane, chasing a boundary that was in the wrong place. Past a handful the answer
                -- is wrong, and stopping leaves a ragged end, which is recoverable. Carrying on is
                -- not. The per-road path above carries the same cap for the same reason.
                local budget = AutoDrive.FLYOVER_JUNCTION_TRIM_BUDGET or 8
                while #seq > 2 and cum[#seq] > target + 0.5 do
                    local back = seq[#seq - 1]
                    local step = math.sqrt((seq[#seq].x - back.x) ^ 2 + (seq[#seq].z - back.z) ^ 2)
                    if step > budget then break end
                    budget = budget - step
                    local doomed = seq[#seq]
                    if not alive(doomed) then break end
                    if not jxRemove(doomed, "junction tidy trim") then break end
                    seq[#seq] = nil
                    trimmed, touched = trimmed + 1, true
                end
                -- Then run up to it, in even steps that land exactly on the boundary.
                local travel = target - cum[#seq]
                if travel > 0.5 then
                    -- Read two-wayness off the segment that is STILL THERE: the trim above may have
                    -- taken the node this was originally measured against.
                    local last, back = seq[#seq], seq[#seq - 1]
                    local segDual = (alive(last) and back ~= nil and alive(back)
                        and table.contains(last.out or {}, back.id)
                        and table.contains(back.out or {}, last.id)) or false
                    local n = math.min(12, math.max(1, math.floor(travel / spacing + 0.5)))
                    for i = 1, n do
                        local pt = atArc(path, cum, cum[#seq] + (travel / n) * i)
                        local made
                        if not tryCall("junction tidy extend", function()
                            made = ADFlyoverRecordWayPoint(pt.x, pt.y or 0, pt.z, false, false,
                                false, 0, last.flags or AutoDrive.FLAG_NONE, false, ADFlyoverEditor.fieldOf(last))
                            jxNoteAdded(made)
                        end) or made == nil then break end
                        if useOut then junctionConnect(seq[#seq], made, segDual)
                        else junctionConnect(made, seq[#seq], segDual) end
                        seq[#seq + 1] = made
                        added, touched = added + 1, true
                    end
                end
                if touched then lanes = lanes + 1 end
                if centre ~= nil then
                    local tip = seq[#seq]
                    laneReport[#laneReport + 1] = string.format(
                        "%s lane on bearing %3.0f: %d trimmed, %d added, now ends %.1f m from the middle",
                        tostring(ap.dir), math.deg(math.atan2(tip.x - centre.x, -(tip.z - centre.z))) % 360,
                        trimmed, added, math.sqrt((tip.x - centre.x) ^ 2 + (tip.z - centre.z) ^ 2))
                end
            elseif centre ~= nil and seq ~= nil and #seq > 0 then
                -- target is nil: this lane's path never crosses the box edge, so there is nothing to
                -- trim back to and nothing to run out to. Left exactly as it is - which is the right
                -- thing to do and the wrong thing to do quietly.
                local tip = seq[#seq]
                laneReport[#laneReport + 1] = string.format(
                    "%s lane on bearing %3.0f: LEFT ALONE - its path does not reach the box edge; nearest point is %.1f m from the middle",
                    tostring(ap.dir), math.deg(math.atan2(tip.x - centre.x, -(tip.z - centre.z))) % 360,
                    math.sqrt((tip.x - centre.x) ^ 2 + (tip.z - centre.z) ^ 2))
            end
        end
    end
    for _, line in ipairs(laneReport) do
        Logging.info("[FlyoverEditor]: junction - %s", line)
    end

    if dry then
        local roadsOut = {}
        -- THE BOX, FOR THE PREVIEW: each road's two offset lines, over the stretch near the junction.
        -- These are the lines the ends are brought to, so what is drawn is what was measured against.
        local bands = {}
        for _, r in ipairs(roads) do
            local line = {}
            for _, q in ipairs(r.centre or {}) do line[#line + 1] = { x = q.x, z = q.z } end
            roadsOut[#roadsOut + 1] = { centre = line, offset = r.offset, tracks = #r.members }
            for _, side in ipairs({ 1, -1 }) do
                local prev = nil
                for k = 1, #line do
                    local vx, vz = dirAtIndex(line, k)
                    local q = line[k]
                    if vx ~= nil and (q.x - boxCentre.x) ^ 2 + (q.z - boxCentre.z) ^ 2 <= 30 * 30 then
                        local pt = { x = q.x + -vz * r.offset * side, z = q.z + vx * r.offset * side }
                        if prev ~= nil and ((pt.x - prev.x) ^ 2 + (pt.z - prev.z) ^ 2) >= 1 then
                            bands[#bands + 1] = { ax = prev.x, az = prev.z, bx = pt.x, bz = pt.z }
                            prev = pt
                        elseif prev == nil then
                            prev = pt
                        end
                    else
                        prev = nil
                    end
                end
            end
        end
        if boxRoadA ~= nil then
            jp._box = { centre = boxCentre,
                a = { centre = boxRoadA.centre, offset = boxRoadA.offset, tracks = boxRoadA.tracks },
                b = { centre = boxRoadB.centre, offset = boxRoadB.offset, tracks = boxRoadB.tracks } }
        else
            jp._box = nil
        end
        return ends, bands, swept, roadsOut, boxCentre
    end
    -- What the lanes finally run over, for the stub sweep that follows: it must never mistake a lane
    -- for a spur, and these walks are the tool's best answer to which is which.
    local laneNodes = {}
    for _, w in ipairs(walked) do
        for _, n in ipairs(w.seq or {}) do laneNodes[n] = true end
    end
    jp._laneNodes = laneNodes
    -- And the lanes themselves, anchor to end, for the respacing that follows.
    -- A lane that was TIDIED ends at the junction, and its approach is the stretch up to that end.
    -- A lane that still RUNS THROUGH was not touched by the tidy, but its approach wants evening out
    -- just the same: for that one the approach is the stretch up to where it passes closest to the
    -- junction. The entry side and the exit side of a through road each stop at that point, so
    -- between them the road is respaced right across the junction, and the node nearest the middle
    -- is the one fixed point they share. A road that merely passes nearby is not this junction's.
    local laneSeqs = {}
    for _, w in ipairs(walked) do
        if w.seq ~= nil and #w.seq >= 3 then
            if w.tidy then
                laneSeqs[#laneSeqs + 1] = { seq = w.seq, useOut = w.useOut }
            else
                local iC, dC = nil, math.huge
                for i, n in ipairs(w.seq) do
                    local d = (n.x - centre.x) ^ 2 + (n.z - centre.z) ^ 2
                    if d < dC then dC, iC = d, i end
                end
                -- ...unless the road turns the corner here: then the bend is the road, and it is left
                -- as it is (see junctionTidyByPaths - 24 by the registry).
                local corner = false
                if iC ~= nil then
                    local function along(step)
                        local i, run = iC, 0
                        while i + step >= 1 and i + step <= #w.seq and run < 8 do
                            run = run + math.sqrt((w.seq[i + step].x - w.seq[i].x) ^ 2 + (w.seq[i + step].z - w.seq[i].z) ^ 2)
                            i = i + step
                        end
                        return w.seq[i]
                    end
                    local a, m, b = along(-1), w.seq[iC], along(1)
                    if a ~= m and b ~= m then
                        corner = junctionAngDiff(math.atan2(m.x - a.x, m.z - a.z), math.atan2(b.x - m.x, b.z - m.z)) > math.rad(45)
                    end
                end
                if iC ~= nil and iC >= 3 and dC <= 12 * 12 and not corner then
                    local sub = {}
                    for i = 1, iC do sub[i] = w.seq[i] end
                    laneSeqs[#laneSeqs + 1] = { seq = sub, useOut = w.useOut }
                end
            end
        end
    end
    jp._laneSeqs = laneSeqs
    jp._boxCentre = boxCentre
    return trimmed, added, lanes, #swept, severed
end

--- Remove the STUBS a clear leaves hanging off the lanes: the remains of connectors that the
--- chain walk marked as road and so could never clear.
---
--- A connector is laid tangent-continuous onto its lane, so the walk runs straight from road onto
--- connector without ever bending sharply enough to notice, and marks the whole thing skeleton.
--- Skeleton is road, road is never cleared, and the tail sits there through every clear after. Four
--- attempts to spot it while walking the lane all failed for the same reason: from ON the lane it
--- looks exactly like the lane.
---
--- It is obvious from beside the lane though. Whatever is left of a connector is a SHORT SPUR that
--- leaves a lane near the junction and stops - it joins nothing, because the clear already took the
--- far end. So: step off each surviving lane node onto any neighbour the lane does not use, follow
--- it, and if it dies within a few metres without reaching anything, it was wiring.
---
--- A real siding is a spur too, which is why this only looks close to the junction and only takes
--- ones that are genuinely short and genuinely dead.
function ADFlyoverEditor:junctionClearStubs(jp)
    local centre = jp.tracksCentre
    if centre == nil then return 0 end
    local REACH = 25      -- only near the junction; a spur further out is someone else's business
    local MAX_NODES = 10  -- longer than any connector remnant, shorter than a real road
    local MAX_LEN = 18

    -- Everything the lanes themselves run over: never a stub, however it looks from the side. The
    -- tidy's bearing-continuity walks are used where they exist; the crude walk below is only a
    -- fallback, because at a fork it takes the first neighbour listed and can wander off the lane.
    local onLane = {}
    local fromTidy = type(jp._laneNodes) == "table" and next(jp._laneNodes) ~= nil
    if fromTidy then
        for n in pairs(jp._laneNodes) do onLane[n] = true end
    end
    for _, ap in ipairs(fromTidy and {} or (jp.approaches or {})) do
        local w, guard = ap.wp, 0
        local useOut = (ap.dir == "in")
        local cameFrom = nil
        while w ~= nil and guard < 400 do
            guard = guard + 1
            onLane[w] = true
            local list = useOut and (w.out or {}) or (w.incoming or {})
            local nextW = nil
            for _, nid in pairs(list) do
                if nid ~= cameFrom then
                    local nx = ADGraphManager:getWayPointById(nid)
                    if nx ~= nil and not onLane[nx] then nextW = nx break end
                end
            end
            cameFrom = w.id
            w = nextW
        end
    end

    local doomed, seen = {}, {}
    for node in jxByPlace(onLane) do
        if (node.x - centre.x) ^ 2 + (node.z - centre.z) ^ 2 <= REACH * REACH then
            for _, lst in ipairs({ node.out or {}, node.incoming or {} }) do
                for _, nid in pairs(lst) do
                    local first = ADGraphManager:getWayPointById(nid)
                    if first ~= nil and not onLane[first] and not seen[first] then
                        -- Follow this branch. It is a stub only if it ENDS without rejoining
                        -- anything, and does so soon.
                        local chain, walk, prev, len, dead = {}, first, node, 0, false
                        for _ = 1, MAX_NODES do
                            seen[walk] = true
                            chain[#chain + 1] = walk
                            local nxt = nil
                            for _, l2 in ipairs({ walk.out or {}, walk.incoming or {} }) do
                                for _, n2 in pairs(l2) do
                                    local cand = ADGraphManager:getWayPointById(n2)
                                    if cand ~= nil and cand ~= prev and cand ~= walk then
                                        if onLane[cand] then nxt = "rejoins" break end
                                        nxt = cand
                                    end
                                end
                                if nxt == "rejoins" then break end
                            end
                            if nxt == "rejoins" then dead = false break end
                            if nxt == nil then dead = true break end
                            len = len + math.sqrt((nxt.x - walk.x) ^ 2 + (nxt.z - walk.z) ^ 2)
                            if len > MAX_LEN then break end
                            prev, walk = walk, nxt
                        end
                        -- And it has to LOOK LAID. A parking spur or a siding is a short dead
                        -- branch near a junction too, and deleting one of those is not a tidy-up.
                        -- The tool lays its curves at about 1.5 m between points; recorded roads
                        -- run 4 to 13 m. A spur whose points average more than 3 m apart was driven,
                        -- not laid, and is left alone whatever else it looks like.
                        local laid = false
                        if dead and #chain > 0 then
                            local span = math.sqrt((chain[1].x - node.x) ^ 2 + (chain[1].z - node.z) ^ 2)
                            for k = 2, #chain do
                                span = span + math.sqrt((chain[k].x - chain[k - 1].x) ^ 2
                                    + (chain[k].z - chain[k - 1].z) ^ 2)
                            end
                            laid = (span / #chain) <= 3.0
                            -- ...UNLESS THIS CLEAR CUT ITS FAR END. Then it is not a spur that was
                            -- driven but the first point of a turn whose rest the clear has just
                            -- taken: at 36, read as two roads that never cross (no box), a turn laid
                            -- at 3-4 m lost all but its first point, and that point was left as a
                            -- 4 m dead end off its lane. Before, the clean-up had folded two lanes
                            -- crossing in 36's middle into one point, and that "fork" gave 36 a box.
                            -- Only a remnant: a point or three and at most 10 m, not a driven spur up
                            -- to MAX_LEN long that happens to end where this clear cut. 36's was one
                            -- point, 4 m; 53's two, 8-9 m (its turn's start, left with a teal dot).
                            if not laid and #chain <= 3 and span <= 10 and jxWasCutByUs(chain[#chain]) then laid = true end
                        end
                        if dead and laid then
                            for _, c in ipairs(chain) do doomed[#doomed + 1] = c end
                        end
                    end
                end
            end
        end
    end

    if #doomed == 0 then return 0 end
    local ids = {}
    for _, w in ipairs(doomed) do
        if w.id ~= nil and w.id >= 0 then ids[#ids + 1] = w.id end
    end
    -- Highest id first: every removal renumbers the ids above it.
    table.sort(ids, function(a, b) return a > b end)
    local gone = 0
    for _, id in ipairs(ids) do
        if jxRemove(id, "junction clear stub") then gone = gone + 1 end
    end
    return gone
end

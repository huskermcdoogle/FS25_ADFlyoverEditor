-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua
-- loads it after FlyoverEditor.lua, in the old file's order.
-- MODSPLIT: HELPERS FROM THE FILES LOADED BEFORE THIS ONE (tools/modsplit/split.py writes this block)
for _, name in ipairs({ "tryCall" }) do
    if ADFlyoverEditor.shared == nil or ADFlyoverEditor.shared[name] == nil then
        Logging.error("[FlyoverEditor]: JxCore.lua needs %s, which no file loaded before it shares", name)
    end
end
local tryCall = ADFlyoverEditor.shared.tryCall
-- MODSPLIT: end of the helpers

-- ---------------------------------------------------------------------------------------------
-- Junction tool - V1: one-click intersection generator. Scope -> approaches -> movement matrix ->
-- track-tangent connectors, previewed live and committed on right-click. The wheel sizes the scope
-- circle, the primary disambiguation lever. See docs/junction-plan.md.
-- ---------------------------------------------------------------------------------------------

--- Smallest angle between two bearings, radians, 0..pi.
local function junctionAngDiff(a, b)
    local d = math.abs(a - b) % (2 * math.pi)
    if d > math.pi then d = 2 * math.pi - d end
    return d
end

-- Unit direction of a chain around index idx (lower index -> higher index).
--- Index i of the chain segment (chain[i] -> chain[i+1]) that point (px,pz) lies on: the nearest
--- segment by true distance. Splitting a lane at a tie-in has to be done THIS way, by position
--- along the chain - not by testing each node with a dot product against its local direction. A
--- chain is long now and carries on through the junction and round whatever bends the road has on
--- the far side; out there a node can pass a "the tie-in is ahead of me" dot test again purely by
--- the way the road happens to point, and the assembled route then jumps to the far side and back.
local function junctionChainIndexNear(chain, px, pz)
    local bestI, bestD = 1, math.huge
    for i = 1, #chain - 1 do
        local a, b = chain[i], chain[i + 1]
        local dx, dz = b.x - a.x, b.z - a.z
        local l2 = dx * dx + dz * dz
        local u = (l2 > 1e-9) and math.max(0, math.min(1, ((px - a.x) * dx + (pz - a.z) * dz) / l2)) or 0
        local d = (a.x + u * dx - px) ^ 2 + (a.z + u * dz - pz) ^ 2
        if d < bestD then bestD, bestI = d, i end
    end
    return bestI
end

local function junctionSegDir(chain, idx)
    local a = chain[math.max(1, idx - 1)]
    local b = chain[math.min(#chain, idx + 1)]
    local dx, dz = b.x - a.x, b.z - a.z
    local l = math.max(1e-6, math.sqrt(dx * dx + dz * dz))
    return dx / l, dz / l
end

--- Walk from chain[startIdx] toward index 1 (the boundary) by arc length `dist`, staying ON the chain
--- for as long as there IS chain. Returns the point (x,y,z) and the unit direction (lower->higher
--- index) of the segment it lands on. dist <= 0 returns chain[startIdx] itself.
--- Running OUT of chain before covering `dist` EXTRAPOLATES past the boundary node along its own
--- final segment direction, rather than clamping there - a stem trimmed back short of where the turn
--- geometry needs its tie-in still gets one at the geometrically correct point, in line with the
--- track, instead of a wrong one dragged in to wherever the trim happened to stop.
--- `allowExtend` (card toggle "trim/extend", default true) governs what happens when `dist` runs out
--- of chain: true extrapolates past the boundary node (see above); false clamps there, the original
--- behaviour, for when a stem SHOULD be left exactly where it ends rather than projected further.
local function junctionWalkBack(chain, startIdx, dist, allowExtend)
    if dist <= 0 or startIdx <= 1 then
        local p = chain[startIdx]
        local dx, dz = junctionSegDir(chain, startIdx)
        return p.x, p.y or 0, p.z, dx, dz
    end
    local remaining, i = dist, startIdx
    while i > 1 and remaining > 0 do
        local a, b = chain[i - 1], chain[i]
        local seglen = math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
        if seglen >= remaining and seglen > 1e-6 then
            local f = (seglen - remaining) / seglen
            return a.x + (b.x - a.x) * f, (a.y or 0) + ((b.y or 0) - (a.y or 0)) * f, a.z + (b.z - a.z) * f,
                (b.x - a.x) / seglen, (b.z - a.z) / seglen
        end
        remaining = remaining - seglen
        i = i - 1
    end
    local a = chain[1]
    local dx, dz = junctionSegDir(chain, 1)
    if not allowExtend then
        remaining = 0
    end
    return a.x - dx * remaining, a.y or 0, a.z - dz * remaining, dx, dz
end

--- Sample the circular arc that leaves P with unit tangent T and passes through Q. Appends points to
--- `out` from just past P up to and INCLUDING Q, and returns the arc's radius (math.huge when P->Q is
--- already straight along T). Point spacing is by a fixed sagitta, so a tight arc gets denser points
--- and a gentle one fewer - every arc stays equally smooth.
-- Max chord deviation from the true curve (sagitta): the waypoint tolerance of every laid arc.
-- Tightened 0.12 -> 0.05 (field feedback: curves read as chunky at small radii).
local JUNCTION_SAG = 0.05
local function junctionArcTo(out, px, pz, tx, tz, qx, qz, y0, y1)
    local dx, dz = qx - px, qz - pz
    local d2 = dx * dx + dz * dz
    local cross = tx * dz - tz * dx                    -- signed perpendicular reach of Q from T
    if d2 < 1e-6 then return math.huge end
    if math.abs(cross) < 1e-4 * math.sqrt(d2) then     -- straight: one chord
        out[#out + 1] = { x = qx, y = y1, z = qz }
        return math.huge
    end
    local nx, nz = -tz, tx                             -- left normal of T
    if cross < 0 then nx, nz = tz, -tx end             -- centre is on the side Q lies on
    local r = d2 / (2 * math.abs(cross))
    local cx, cz = px + r * nx, pz + r * nz
    local a0 = math.atan2(pz - cz, px - cx)
    local a1 = math.atan2(qz - cz, qx - cx)
    local da = math.atan2(math.sin(a1 - a0), math.cos(a1 - a0))
    local dth = 2 * math.acos(math.max(-1, math.min(1, 1 - JUNCTION_SAG / r)))
    local steps = math.max(2, math.ceil(math.abs(da) / math.max(dth, 1e-3)))
    for i = 1, steps do
        local u = i / steps
        local th = a0 + da * u
        out[#out + 1] = { x = cx + r * math.cos(th), y = y0 + (y1 - y0) * u, z = cz + r * math.sin(th) }
    end
    return r
end

--- Biarc from (P0, tangent T0) to (P1, tangent T1): two circular arcs meeting tangent-continuously at
--- a joint J, the classic equal-handle construction. Given the tie-in POINTS (on the real tracks) and
--- their LOCAL tangents, this is the smooth curve that honours both exactly; for a clean crossing with
--- tie-ins at t = R*tan(delta/2) it degenerates to the single radius-R fillet arc. Returns the
--- interior points (excluding P0 and P1) and the SMALLER of the two radii - the number to hold against
--- the turn-radius setting. nil when the tangents cannot be joined (they point away from each other).
local function junctionBiarc(p0x, p0z, t0x, t0z, p1x, p1z, t1x, t1z, y0, y1)
    local vx, vz = p1x - p0x, p1z - p0z
    local vv = vx * vx + vz * vz
    if vv < 1e-6 then return nil end
    local tt = t0x * t1x + t0z * t1z
    local vt = vx * (t0x + t1x) + vz * (t0z + t1z)
    local denom = 2 * (1 - tt)
    local alpha
    if math.abs(denom) < 1e-6 then                     -- parallel tangents
        local vt1 = vx * t1x + vz * t1z
        if math.abs(vt1) < 1e-6 then return nil end
        alpha = vv / (4 * vt1)
    else
        alpha = (-vt + math.sqrt(math.max(0, vt * vt + denom * vv))) / denom
    end
    if alpha <= 1e-4 then return nil end
    local jx = (p0x + alpha * t0x + p1x - alpha * t1x) / 2
    local jz = (p0z + alpha * t0z + p1z - alpha * t1z) / 2
    local ym = (y0 + y1) / 2
    local pts = {}
    local r1 = junctionArcTo(pts, p0x, p0z, t0x, t0z, jx, jz, y0, ym)
    -- Second arc, built backwards from P1 (tangent -T1) to J so it arrives along T1, then reversed.
    local back = {}
    local r2 = junctionArcTo(back, p1x, p1z, -t1x, -t1z, jx, jz, y1, ym)
    pts[#pts] = nil                                    -- drop J once; the back list (reversed) starts on it
    for i = #back, 1, -1 do pts[#pts + 1] = back[i] end
    -- Neither P0 nor P1 is in the list (junctionArcTo excludes its start point) - they are the tie-ins.
    return { points = pts, minRadius = math.min(r1, r2), jx = jx, jz = jz }
end

--- A SET WALKED IN THE SAME ORDER EVERY TIME: by place on the map. pairs() over a set keyed by
--- point id comes back in an order set by the ids, and one keyed by the points themselves in an
--- order set by where they lie in memory. Every clear renumbers the points above each one it
--- removes, so clearing one junction changed the order at its neighbours - and wherever that order
--- picked a lane, a group's leader or the first of a list, the neighbour's clear came out
--- differently (clearing 30 and then 39 cut 39's road from the south). Keys are points or point
--- ids; each is placed by x, then z, then height, and two points on one spot by id. Any other key
--- (a string) sorts as itself after the points. Use in place of pairs() wherever the order can
--- reach a result; counting, summing and building another set need no order and keep pairs().
local function jxPlaceOf(k, v)
    if type(k) == "table" and k.x ~= nil then return k end
    if type(k) == "number" then
        if type(v) == "table" and v.x ~= nil and v.id == k then return v end
        return ADGraphManager:getWayPointById(k)
    end
    return nil
end
local function jxBeforeInPlace(a, b)
    if a.x ~= b.x then return a.x < b.x end
    if a.z ~= b.z then return a.z < b.z end
    if (a.y or 0) ~= (b.y or 0) then return (a.y or 0) < (b.y or 0) end
    return (a.id or 0) < (b.id or 0)
end
local function jxByPlace(t)
    local keys, at = {}, {}
    for k, v in pairs(t) do
        keys[#keys + 1] = k
        at[k] = jxPlaceOf(k, v) or false
    end
    table.sort(keys, function(a, b)
        local pa, pb = at[a], at[b]
        if pa and pb then
            if pa ~= pb then return jxBeforeInPlace(pa, pb) end
            return tostring(a) < tostring(b)
        end
        if pa then return true end
        if pb then return false end
        if type(a) == type(b) and (type(a) == "string" or type(a) == "number") then return a < b end
        return tostring(a) < tostring(b)
    end)
    -- A key emptied while the walk is under way is skipped, as pairs() would.
    local i = 0
    return function()
        while true do
            i = i + 1
            local k = keys[i]
            if k == nil then return nil end
            if t[k] ~= nil then return k, t[k] end
        end
    end
end

--- TWO LANES CROSSING, AT ONE POINT OR AT TWO. Where two lanes cross, a point of each can lie a few
--- cm from the other's, and folding such a pair (networkIntegritySweep's doubles) makes one point that
--- both lanes run through: two ways in, two ways out. Read as a fork, that point cut a turn in half
--- and moved 39's middle 3.4 m (the game's network had one, 0.23 m apart, folded before the session).
---
--- jxCrossingPairs(w): for a point with exactly two ways in and two ways out (none of them both), where
--- each way in carries straight on (30 degrees or less) to its own way out and the swapped pairing
--- would turn hard (45 or more), the way out for each way in, keyed by point. Otherwise nil: a real
--- fork, or a point too bent to say.
local function jxStraightTurn(a, w, b)
    local d = math.atan2(b.x - w.x, b.z - w.z) - math.atan2(w.x - a.x, w.z - a.z)
    while d > math.pi do d = d - 2 * math.pi end
    while d < -math.pi do d = d + 2 * math.pi end
    return math.abs(d)
end
local function jxCrossingPairs(w)
    if w == nil then return nil end
    local ins, outs, isIn = {}, {}, {}
    for _, id in ipairs(w.incoming or {}) do
        local v = ADGraphManager:getWayPointById(id)
        if v ~= nil and v ~= w and not isIn[v] then isIn[v] = true ins[#ins + 1] = v end
    end
    for _, id in ipairs(w.out or {}) do
        local v = ADGraphManager:getWayPointById(id)
        if v ~= nil and v ~= w then
            if isIn[v] then return nil end
            if outs[1] ~= v and outs[2] ~= v then outs[#outs + 1] = v end
        end
    end
    if #ins ~= 2 or #outs ~= 2 then return nil end
    local s11, s22 = jxStraightTurn(ins[1], w, outs[1]), jxStraightTurn(ins[2], w, outs[2])
    local s12, s21 = jxStraightTurn(ins[1], w, outs[2]), jxStraightTurn(ins[2], w, outs[1])
    local STRAIGHT, HARD = math.rad(30), math.rad(45)
    if math.max(s11, s22) <= STRAIGHT and math.min(s12, s21) >= HARD then
        return { [ins[1]] = outs[1], [ins[2]] = outs[2] }
    elseif math.max(s12, s21) <= STRAIGHT and math.min(s11, s22) >= HARD then
        return { [ins[1]] = outs[2], [ins[2]] = outs[1] }
    end
    return nil
end
--- jxLanesCross(a, b): a and b each carry one lane straight through (one way in, one way out, 30
--- degrees or less), are not wired to each other or to a shared neighbour, and their lanes lie on
--- lines 30 degrees or more apart - two lanes crossing, not one point laid twice. A lane end lying on a
--- lane, or a lane laid twice along itself, is not this, and still folds.
local function jxLanesCross(a, b)
    local function pass(w)
        local i, o = w.incoming or {}, w.out or {}
        if #i ~= 1 or #o ~= 1 or i[1] == o[1] then return nil end
        local p, q = ADGraphManager:getWayPointById(i[1]), ADGraphManager:getWayPointById(o[1])
        if p == nil or q == nil or jxStraightTurn(p, w, q) > math.rad(30) then return nil end
        return p, q
    end
    local pa, qa = pass(a)
    local pb, qb = pass(b)
    if pa == nil or pb == nil then return false end
    if pa == b or qa == b or pb == a or qb == a or pa == pb or qa == qb or pa == qb or qa == pb then
        return false
    end
    local d = math.atan2(qa.x - pa.x, qa.z - pa.z) - math.atan2(qb.x - pb.x, qb.z - pb.z)
    d = math.abs(d) % math.pi
    if d > math.pi / 2 then d = math.pi - d end
    return d >= math.rad(30)
end

--- How far a way on from a fork has TURNED by the time it next meets something, in radians.
---
--- The branch is followed from `first`, straightest way on at each node, until it reaches the next
--- FORK (a node with three or more distinct neighbours), a dead end, or `reach` metres; the heading
--- it arrives on is compared with the heading (hx, hz) the lane had coming into the fork.
---
--- A lane's own road arrives at the next tie node still going the lane's way. A turn connector
--- arrives at ITS next tie node - where it joins the other road - going that road's way: turned by
--- the whole angle of the turn, however gently it set off. That matters because the tool lays its
--- connectors tangent-continuous and starts its kickouts early, so AT the fork a connector and the
--- road cannot be told apart by bearing; where they next join something, they cannot be confused.
--- Stopping at the next fork also keeps the verdict LOCAL: a road that carries on to a T and then
--- has to turn is not judged by what happens at the T.
local function junctionBranchTurn(from, first, useOut, hx, hz, reach)
    local function degree(w)
        local seen, n = {}, 0
        for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
            for _, id in pairs(lst) do
                if not seen[id] then seen[id] = true n = n + 1 end
            end
        end
        return n
    end
    local prev, node = from, first
    local dx, dz = first.x - from.x, first.z - from.z
    local run = math.sqrt(dx * dx + dz * dz)
    if run < 1e-6 then return 0 end
    local tx, tz = dx / run, dz / run
    for _ = 1, 200 do
        if run >= reach or degree(node) >= 3 then break end
        local list = useOut and (node.out or {}) or (node.incoming or {})
        local best, bestDot = nil, -math.huge
        for _, nid in pairs(list) do
            if nid ~= prev.id then
                local nx = ADGraphManager:getWayPointById(nid)
                if nx ~= nil then
                    local ex, ez = nx.x - node.x, nx.z - node.z
                    local el = math.sqrt(ex * ex + ez * ez)
                    if el > 1e-6 then
                        local dot = (ex / el) * tx + (ez / el) * tz
                        if dot > bestDot then bestDot, best = dot, nx end
                    end
                end
            end
        end
        if best == nil then break end
        local ex, ez = best.x - node.x, best.z - node.z
        local el = math.sqrt(ex * ex + ez * ez)
        tx, tz = ex / el, ez / el
        run = run + el
        prev, node = node, best
    end
    return math.acos(math.max(-1, math.min(1, tx * hx + tz * hz)))
end

-- Deterministic link primitives - NOT toggles. AutoDrive's toggleConnectionBetween flips state (its
-- remove branch fires on an OR of two list checks and its insert never checks for duplicates), so
-- anything built on it can leave a link in a state nobody asked for when an operation re-enters the
-- same pair - a repeat placement over the same spot, an undo/redo interleave. That is the class of
-- bug that minted two-way ("blue") links on one-way roads. These two are idempotent and explicit:
-- calling them twice is the same as calling them once, and the resulting state is exactly what the
-- arguments say, regardless of what was there before.
-- WHERE THE JUNCTION ENDS, IN ONE PLACE. Every deletion a clear makes goes through jxRemove, and
-- jxRemove is the only thing that decides whether a point belongs to the junction being worked on.
--
-- Before this there were fourteen places that removed a waypoint, at three different stages, each
-- with its own idea of how far the junction reached - which is why the reach came out at 12, 45, 50
-- or 75 m depending which one was asked, and why a clear at one site took thirty points out to 73 m.
--
-- The bound is not a radius. A junction is not round: its arms reach different distances, and a
-- circle big enough for the longest one swallows the neighbours of the shortest. So each ARM is
-- allowed out to its own first fork - that is where the next junction starts, and nothing past it
-- was ever this junction's to take - with a cap for an arm that runs on across the map, and a core
-- around the middle that is always allowed so the box itself is never gated.
local jxBound, jxBlocked, jxTook, jxFarthest = nil, 0, 0, 0
local jxWired = 0
-- THE JUNCTION TOOL'S STATE THAT IS ASSIGNED AGAIN AFTER ITS DECLARATION (docs/editor-modules-spec.md,
-- phase 1). These were file-level locals. Once the editor is split into modules, a file can't assign
-- another file's local, and an alias would keep the old value, so each is a field of this one table,
-- under its old name.
local jxState = {}
jxState.jxWhy = {}   -- per reason: how many taken, and the farthest of them
-- WAS IT ALREADY LOOSE, AND DID WE CUT IT ON PURPOSE. Two things the clear knows exactly, and
-- between them they say which loose ends are its business. No distance can answer this: a junction
-- cleared earlier keeps no forks to be recognised by, and its branches sit well inside any radius
-- wide enough to be useful.
jxState.jxWasLoose, jxState.jxCut, jxState.jxExisted = nil, nil, nil
local jxForeignForks   -- defined below, used by jxBegin
-- WHICH KEPT THROUGH ROAD EACH POINT IS ON, while a clear with through roads kept is running (nil
-- otherwise): point -> the number of its road in the preview's through routes. The integrity sweep
-- folds two points closer than 0.3 m into one, and where two kept roads cross that fold joins them:
-- at 16 the crossing points of the two roads already lay 0.06-0.26 m apart, at 30 the respacing
-- drew two of them to 0.28 m - and each fold let a lane in on one road drive out on the other.
-- The user's default is that kept roads pass through each other without sharing a point.
jxState.jxKeptRoad = nil
-- HOW FAR PAST THE BOUND A TURN TAKEN WHOLE MAY REACH: every point of it outside the bound must lie
-- within this many metres of one of its own points inside. A turn is taken whole so that its ends
-- go with it (36: ends 13-15 m out, a few metres past the bound), but taking it whole skips the
-- bound's own limits, so this keeps a long piece from running on out along a road unchecked. The
-- check after a clear uses the same figure, so it still reports a piece that reached further.
local JX_WHOLE_PIECE_REACH = 8
-- ANOTHER PART'S TURN, LEFT WORKING (split junctions; the user's rules of 2026-10-03, doc 04, "Split
-- junctions: clearing one part"). While the clear of a part of a split the user saved is running:
-- every point of another part's turn that lies in this part's area, the points where it leaves and
-- joins the road, and the stretch of that road kept for it (junctionTwinTurns, junctionTidyByPaths). The
-- one remover, jxRemove, refuses them, as the bound refuses a point outside the junction; nil
-- otherwise. jxTwinHeld counts what it refused.
jxState.jxTwinKeep, jxState.jxTwinHeld = nil, 0
-- How far before another part's turn the cut lane starts again (or after it, ends): enough road for
-- a vehicle to be on the lane before it turns off. Metres; less where this part's middle is nearer.
local JX_TWIN_LEAD = 5
local function jxKeptRoadsOf(jp, leave)
    if not leave or jp == nil or jp.pathRoutes == nil then return nil end
    local m = {}
    for i, nodes in ipairs(jp.pathRoutes.through or {}) do
        for _, n in ipairs(nodes) do
            if m[n] == nil then m[n] = i end
        end
    end
    return m
end

-- THE CLEAR'S OWN RECORD OF WHAT IT CHANGED, one entry per edit, in the order it made them. The
-- check that runs after a clear compares the network before and after, and every difference has to
-- be one of these: a change nobody recorded is a change no stage meant to make. Comparing alone
-- could only say THAT something changed; the record says which stage did it, so a stage that
-- reaches too far can be named. Only ever written to while a clear is running (jxJournal is nil
-- otherwise), and only ever read by the check - nothing in the clear decides anything from it.
-- Entries: op = "add" / "remove" / "move" / "out+" / "out-" / "in+" / "in-", a = the point, b =
-- the other end of a link, stage = which part of the clear, x/y/z = where the point stood when the
-- entry was made: where it was laid, where it was removed from, or - for a move - where it stands
-- AFTER the move (the check replays the moves in order, so each one is measured from the last).
jxState.jxJournal, jxState.jxStage = nil, nil
-- True while the respacing is rebuilding a run, whichever stage called it: the respacing has a reach
-- of its own (FLYOVER_JUNCTION_RESPACE_LEN), and the tidy calls it too, to smooth a through road.
jxState.jxInRespace = false
-- The stretch the respacing is rebuilding at the moment: where its points stood, and how far along
-- its lane from the lane's end it starts. Lets the check tell a stretch running out of the junction
-- (allowed: it ends on the first point past the edge) from one lying wholly outside it (not).
jxState.jxRespaceRun = nil

local function jxNote(op, a, b, why)
    if jxState.jxJournal == nil or a == nil then return end
    jxState.jxJournal[#jxState.jxJournal + 1] = { op = op, a = a, b = b, stage = jxState.jxStage or "?", why = why,
        respace = jxState.jxInRespace, run = jxState.jxRespaceRun, x = a.x, y = a.y, z = a.z }
end

--- A point the clear has just laid. Nil-safe, so it can follow any creation call unguarded.
--- The points the current BUILD has created, as a set of point tables (ids shift when stubs are
--- removed, tables do not). Nil outside a build. Filled here so every way a build adds a point -
--- laying a turn, splicing a tie-in, sharing a crossing - is counted without each having to remember.
jxState.jxBuildNew = nil
--- Every link that existed when the current build started, as oldLinks[from][to] = true on point
--- tables. A build can lay a turn straight between two existing points, so "has a new end" is not
--- the same as "is new". Nil outside a build.
local jxBuildOldLinks = nil

--- The one point every left turn of the current build runs through (see junctionTrackConnector's
--- left turns through the centre). Made by the first left turn laid, reused by the rest.
jxState.jxCentreNode = nil
--- What each point the current build laid is part of, for the harness's route study: "L90" / "R90"
--- (a left or right turn of that many degrees), "tie" (a tie-in spliced into a lane), "x" (a shared
--- crossing). jxLayLabel is the label of the turn being laid at the moment. Report only.
jxState.jxNodeLabel, jxState.jxLayLabel = nil, nil
--- The same for each LINK the build laid, jxLinkLabel[from][to] = label: a link spliced at a crossing keeps
--- the label of the link it was cut from, so the study can tell which turn a driver is on. Report only.
jxState.jxLinkLabel = nil
jxState.jxLaySeq = 0   -- numbers each turn of a build, so two turns of the same shape are told apart

local function jxBuildBegin()
    jxState.jxBuildNew, jxBuildOldLinks = {}, {}
    jxState.jxCentreNode = nil
    jxState.jxNodeLabel, jxState.jxLayLabel, jxState.jxLinkLabel = {}, nil, {}
    jxState.jxLaySeq = 0
    for _, a in pairs(ADGraphManager:getWayPoints()) do
        if a ~= nil and a.id ~= nil and #(a.out or {}) > 0 then
            local s = {}
            for _, bid in ipairs(a.out) do
                local b = ADGraphManager:getWayPointById(bid)
                if b ~= nil then s[b] = true end
            end
            jxBuildOldLinks[a] = s
        end
    end
end

local function jxBuildEnd()
    jxState.jxBuildNew, jxBuildOldLinks, jxState.jxCentreNode = nil, nil, nil
    jxState.jxNodeLabel, jxState.jxLayLabel, jxState.jxLinkLabel = nil, nil, nil
end

--- "L90" / "R45" for a connector: which way it turns and by how much, from its first and last legs.
local function jxTurnLabel(c)
    local pts = c.points or {}
    if #pts == 0 then return "S" end
    local ux, uz = pts[1].x - c.ax, pts[1].z - c.az
    local vx, vz = c.bx - pts[#pts].x, c.bz - pts[#pts].z
    local nu, nv = math.sqrt(ux * ux + uz * uz), math.sqrt(vx * vx + vz * vz)
    if nu < 1e-6 or nv < 1e-6 then return "S" end
    local ang = math.deg(math.acos(math.max(-1, math.min(1, (ux * vx + uz * vz) / (nu * nv)))))
    if ang < 20 then return "S" end
    return string.format("%s%.0f", ((ux * vz - uz * vx) < 0) and "L" or "R", ang)
end

local function jxIsNewLink(a, b)
    if jxBuildOldLinks == nil then return false end
    local s = jxBuildOldLinks[a]
    return s == nil or s[b] ~= true
end

local function jxNoteAdded(w)
    if w ~= nil then jxNote("add", w) end
    if w ~= nil and jxState.jxBuildNew ~= nil then jxState.jxBuildNew[w] = true end
    if w ~= nil and jxState.jxNodeLabel ~= nil and jxState.jxNodeLabel[w] == nil then jxState.jxNodeLabel[w] = jxState.jxLayLabel or "tie" end
end

--- A point the clear has just moved, recorded where it now stands.
local function jxNoteMoved(w)
    if w ~= nil then jxNote("move", w) end
end

--- A clear runs start to finish inside one call, so a record still open when the next frame starts
--- belongs to a clear that stopped with an error before it could close it (applyJunction calls the
--- clear unguarded). Closed from the editor's update, so the edits of whatever tool comes next are
--- not piled into it until the next clear resets it. Memory only: nothing reads the record outside
--- a clear's own check.
function ADFlyoverEditor:junctionCheckRecordOff()
    if jxState.jxJournal ~= nil then
        jxState.jxJournal, jxState.jxStage, jxState.jxInRespace, jxState.jxRespaceRun = nil, nil, false, nil
    end
end

--- The whole network as it stands: where every point is and what it is linked to, held by the
--- points themselves, because every removal reissues the ids above it. The whole network and not a
--- circle round the site, so a change made anywhere is seen. Only the check after a clear reads it.
local function jxSnapshot()
    local snap = {}
    for _, w in pairs(ADGraphManager:getWayPoints()) do
        if w ~= nil and w.id ~= nil then
            local out, inn = {}, {}
            for _, id in ipairs(w.out or {}) do
                local t = ADGraphManager:getWayPointById(id)
                if t ~= nil then out[#out + 1] = t end
            end
            for _, id in ipairs(w.incoming or {}) do
                local t = ADGraphManager:getWayPointById(id)
                if t ~= nil then inn[#inn + 1] = t end
            end
            snap[w] = { x = w.x, y = w.y, z = w.z, out = out, inn = inn }
        end
    end
    return snap
end

--- The through roads the clear found, as lines on the map, read before any of them is cut or
--- respaced, with the points each one starts and ends at.
local function jxRouteLines(jp)
    local lines = {}
    local through = (jp ~= nil and jp.pathRoutes ~= nil) and jp.pathRoutes.through or nil
    for _, nodes in ipairs(through or {}) do
        local pts = {}
        for _, n in ipairs(nodes) do pts[#pts + 1] = { x = n.x, z = n.z } end
        if #pts >= 2 then lines[#lines + 1] = { pts = pts, first = nodes[1], last = nodes[#nodes] } end
    end
    return lines
end

--- AUTODRIVE'S OWN RIGHT-OF-WAY RULE, the teal dot: a point two or more roads lead into and at least
--- one leads out of, less three shapes that only change road type. Copied from AutoDrive 3.0.1.2
--- (Specialization.lua, getWayPointsInRange). It found 24 links our own counts had called cleared.
local function jxRightOfWayLists(out, inc)
    if #out < 1 or #inc < 2 then return false end
    local singleIn, singleOut, dual = 0, 0, 0
    for _, i in pairs(inc) do
        if table.contains(out, i) then dual = dual + 1 else singleIn = singleIn + 1 end
    end
    for _, o in pairs(out) do
        if not table.contains(inc, o) then singleOut = singleOut + 1 end
    end
    if dual == 1 and singleIn == 1 and singleOut == 0 then return false end
    if dual == 1 and singleIn == 0 and singleOut == 1 then return false end
    if dual == 2 and singleIn == 0 and singleOut == 0 then return false end
    return true
end

local function jxRightOfWay(w)
    return jxRightOfWayLists(w.out or {}, w.incoming or {})
end

--- One-ended: something leads in and nothing out, or the other way about.
local function jxLoose(w)
    local nOut, nIn = #(w.out or {}), #(w.incoming or {})
    return (nOut == 0) ~= (nIn == 0)
end

--- Mark a point as having been cut FROM something on purpose. Rejoining it would undo the work.
local function jxMarkCut(w)
    if jxState.jxCut ~= nil and w ~= nil then jxState.jxCut[w] = true end
end

--- Begin a clear: nothing may be deleted outside `site` until jxEnd.
local function jxBegin(site)
    jxBound, jxBlocked, jxTook, jxFarthest, jxWired = site, 0, 0, 0, 0
    jxState.jxTwinKeep, jxState.jxTwinHeld = nil, 0
    jxState.jxWhy = {}
    jxForeignForks(site)
    -- Everything already hanging loose before this clear touched anything. Whatever left these ends
    -- this way - a clear done an hour ago, a route half drawn by hand - it was not us, so it is not
    -- ours to put back.
    jxState.jxWasLoose, jxState.jxCut, jxState.jxExisted = {}, {}, {}
    for _, w in pairs(ADGraphManager:getWayPoints()) do
        if w ~= nil then
            jxState.jxExisted[w] = true
            if jxLoose(w) then jxState.jxWasLoose[w] = true end
        end
    end
end

--- End a clear, and say how much was held back. Anything blocked is worth knowing about: it is
--- either the bound doing its job, or the bound being wrong, and both want looking at.
--- Returns what was held back, what was actually taken, and how far out the farthest one was.
--- COUNTED HERE BECAUSE NOWHERE ELSE CAN COUNT IT. Comparing the graph before and against after
--- cannot: asking whether an id still points at the same node counts survivors as deleted, because
--- every removal renumbers the ids above it; and asking whether anything still stands in a node's
--- old place counts points the respacing MOVED. Both were tried, and both put the reach of a clear
--- at 75 m where the truth is a couple of dozen points inside the junction. This is the one place a
--- deletion happens, so it is the one place the number is real.
local function jxEnd()
    local held, took, far = jxBlocked, jxTook, jxFarthest
    jxBound, jxBlocked, jxTook, jxFarthest = nil, 0, 0, 0
    jxState.jxTwinKeep = nil
    return held, took, far
end

--- Does (x, z) belong to `site`? The bound itself, for any site: the check after a clear asks it of
--- the site that was cleared, after jxEnd has let go of jxBound.
local function jxSiteHas(site, x, z)
    -- No site means this is not a bounded clear (build mode, the console, a tool that never had a
    -- site). Unbounded, exactly as before - this gate only ever tightens a clear.
    if site == nil or site.roads == nil or #site.roads == 0 then return true end
    local dx, dz = x - site.x, z - site.z
    local d2 = dx * dx + dz * dz
    local core = AutoDrive.FLYOVER_JUNCTION_CLEAR_SCOPE or 12
    if d2 <= core * core then return true end
    local d = math.sqrt(d2)
    -- The arm this point lies along, and how far that arm runs before the next junction.
    local b = math.deg(math.atan2(dx, dz)) % 360
    local best, bestSep = nil, math.huge
    for _, r in ipairs(site.roads) do
        local rb = math.deg(r.bearing) % 360
        local s = math.abs(b - rb) % 360
        if s > 180 then s = 360 - s end
        if s < bestSep then bestSep, best = s, r end
    end
    -- Nowhere near any arm of this junction: not ours.
    if best == nil or bestSep > 60 then return false end
    -- WHERE THE ARM RAN INTO ANOTHER JUNCTION, STOP SHORT OF IT. The walk reports the distance TO
    -- that fork, and a margin on top of it reaches past the fork and into the junction beyond - which
    -- is how clearing one of a close pair took the other one's points while reporting that it had
    -- held nothing back. The margin is only for an arm that ran out of walk without meeting
    -- anything: there a road's far lane really does sit off the arm's bearing and wants the room.
    local lim = best.len or 0
    if best.fork then lim = math.max(0, lim - 2) else lim = lim + 4 end
    return d <= lim
end

local function jxMayDelete(x, z) return jxSiteHas(jxBound, x, z) end

--- Does this point belong to the junction being worked on? The same question the deletions ask,
--- asked by anything else that must not wander into the junction next door.
local function jxInSite(x, z) return jxMayDelete(x, z) end

--- Did THIS clear cut this point off from something? The gate marks every point it severs on
--- purpose, so anything else lying loose nearby was already like that when the clear began.
local function jxWasCutByUs(w)
    return jxState.jxCut ~= nil and w ~= nil and jxState.jxCut[w] == true
end

--- The one way a clear removes a waypoint. Takes an id or the node itself; the node is safer, since
--- every removal renumbers the ids above it. `whole` is for a piece of turn wiring the caller has
--- already found reaches into the junction and ends at the lane forks: it is taken whole, even the
--- part lying past the bound (see the removal of turn wiring in applyJunctionClear).
local function jxRemove(which, why, whole)
    local w = which
    if type(w) ~= "table" then w = ADGraphManager:getWayPointById(which) end
    if w == nil or w.id == nil then return false end
    if not whole and not jxMayDelete(w.x, w.z) then
        jxBlocked = jxBlocked + 1
        return false
    end
    -- Another part's turn left working, and the road it needs (jxTwinKeep): never, whole or not.
    if jxState.jxTwinKeep ~= nil and jxState.jxTwinKeep[w] then
        jxState.jxTwinHeld = jxState.jxTwinHeld + 1
        return false
    end
    local site = jxBound
    if site ~= nil then
        local d = math.sqrt((w.x - site.x) ^ 2 + (w.z - site.z) ^ 2)
        if d > jxFarthest then jxFarthest = d end
        local e = jxState.jxWhy[why or "?"] or { n = 0, far = 0 }
        e.n = e.n + 1
        if d > e.far then e.far = d end
        jxState.jxWhy[why or "?"] = e
    end
    jxTook = jxTook + 1
    -- Whatever this point was joined to is now an end, and on purpose.
    for _, id in ipairs(w.out or {}) do jxMarkCut(ADGraphManager:getWayPointById(id)) end
    for _, id in ipairs(w.incoming or {}) do jxMarkCut(ADGraphManager:getWayPointById(id)) end
    jxNote("remove", w, nil, why)
    return tryCall(why or "junction remove", function()
        ADGraphManager:removeWayPoint(w.id, false)
    end) == true
end

--- NO CLEAR MAY WIRE UP A JUNCTION THAT IS NOT THE ONE IT WAS ASKED TO WORK ON. Several stages make
--- links - a chain being tied back to the road, two doubled points being folded together, a lane end
--- run out to the box, the respacing bridging over what it removes - and NONE of them can tell a
--- deliberate cut from damage. At a junction already cleared, every severed branch looks like
--- something to join up, so clearing one of a close pair put the other one back together. Fixing
--- those stages one at a time fixed nothing: there was always another one.
---
--- So link-making is gated in one place, exactly as deleting is. During a clear, no link may be made
--- at a point belonging to ANOTHER junction - that junction's wiring is not this one's business.
local jxForeign = nil
--- Were these two already joined, by a run of plain road? Then a link between them is a BRIDGE -
--- what the respacing lays over the points it is about to take out - and adds nothing that was not
--- there before.
local function jxAlreadyJoined(a, b)
    for _, dir in ipairs({ "out", "incoming" }) do
        local cur, seen = a, { [a] = true }
        for _ = 1, 16 do
            local nxt = nil
            for _, id in ipairs(cur[dir] or {}) do
                local w = ADGraphManager:getWayPointById(id)
                if w == b then return true end
                if w ~= nil and not seen[w] and nxt == nil then nxt = w end
            end
            if nxt == nil then break end
            seen[nxt] = true
            cur = nxt
        end
    end
    return false
end

local function jxMayLink(a, b)
    if true then return true end   -- gate retired: it cut lanes in half two different ways
    if jxBound == nil or jxForeign == nil then return true end
    -- A BRIDGE IS NOT NEW WIRING. This gate exists to stop a clear joining something ONTO a
    -- neighbouring junction, and it was also refusing the respacing's bridges where a lane runs up
    -- to the neighbour's tie node: the bridge was refused, the points it was to replace were taken
    -- out regardless, and the lane between two junctions was left cut in half - in game, the road
    -- between a pair of junctions, severed one node short of the second.
    if jxAlreadyJoined(a, b) then return true end
    -- Tight on purpose. This has to catch a link being made ONTO a neighbouring junction's own
    -- points, not every link that passes near one: at a site whose neighbours sit close by, a
    -- generous radius refused the lane links the clear itself needed and left ten links running
    -- across its box.
    local R = AutoDrive.FLYOVER_JUNCTION_LINK_GATE_R or 3
    for _, f in ipairs(jxForeign) do
        if (f.x - a.x) ^ 2 + (f.z - a.z) ^ 2 <= R * R
            or (f.x - b.x) ^ 2 + (f.z - b.z) ^ 2 <= R * R then
            jxWired = (jxWired or 0) + 1
            return false
        end
    end
    return true
end

--- The fork points near this site that are NOT its own: the junctions next door. Worked out once per
--- clear, from the site's own fork list, so it does not depend on how the survey happens to group
--- them - it numbers a close pair as one, which is exactly the case this has to tell apart.
function jxForeignForks(site)
    jxForeign = {}
    if AutoDrive.FLYOVER_JUNCTION_LINK_GATE == false then jxForeign = nil return end
    if site == nil or site.forks == nil then return end
    local mine = {}
    for _, f in ipairs(site.forks) do mine[f] = true end
    for _, w in pairs(ADGraphManager:getWayPoints()) do
        if w ~= nil and not mine[w] and (w.x - site.x) ^ 2 + (w.z - site.z) ^ 2 <= 80 * 80 then
            local nb, deg = {}, 0
            for _, t in ipairs(w.out or {}) do nb[t] = true end
            for _, fid in ipairs(w.incoming or {}) do nb[fid] = true end
            for _ in pairs(nb) do deg = deg + 1 end
            -- far enough from this junction's middle that it cannot be one of its own tie points
            if deg >= 3 and (w.x - site.x) ^ 2 + (w.z - site.z) ^ 2 > 13 * 13 then
                jxForeign[#jxForeign + 1] = { x = w.x, z = w.z }
            end
        end
    end
end

local function junctionConnect(a, b, dual)
    if a ~= nil and b ~= nil and not jxMayLink(a, b) then return end
    if a == nil or b == nil or a.id == b.id then return end
    if not table.contains(a.out, b.id) then table.insert(a.out, b.id) jxNote("out+", a, b) end
    if not table.contains(b.incoming, a.id) then table.insert(b.incoming, a.id) jxNote("in+", b, a) end
    if jxState.jxLinkLabel ~= nil and jxState.jxLayLabel ~= nil and jxState.jxLayLabel ~= "x" then
        jxState.jxLinkLabel[a] = jxState.jxLinkLabel[a] or {}
        jxState.jxLinkLabel[a][b] = jxState.jxLayLabel
        if dual then
            jxState.jxLinkLabel[b] = jxState.jxLinkLabel[b] or {}
            jxState.jxLinkLabel[b][a] = jxState.jxLayLabel
        end
    end
    if dual then
        if not table.contains(b.out, a.id) then table.insert(b.out, a.id) jxNote("out+", b, a) end
        if not table.contains(a.incoming, b.id) then table.insert(a.incoming, b.id) jxNote("in+", a, b) end
    end
end

-- Remove every connection between a and b, both directions, unconditionally.
local function junctionDisconnect(a, b)
    if a == nil or b == nil then return end
    jxMarkCut(a)
    jxMarkCut(b)
    -- Recorded only where there was something to remove, so the record says what changed.
    if jxState.jxJournal ~= nil then
        if table.contains(a.out, b.id) then jxNote("out-", a, b) end
        if table.contains(b.incoming, a.id) then jxNote("in-", b, a) end
        if table.contains(b.out, a.id) then jxNote("out-", b, a) end
        if table.contains(a.incoming, b.id) then jxNote("in-", a, b) end
    end
    table.removeValue(a.out, b.id)
    table.removeValue(b.incoming, a.id)
    table.removeValue(b.out, a.id)
    table.removeValue(a.incoming, b.id)
    if jxState.jxLinkLabel ~= nil then
        if jxState.jxLinkLabel[a] ~= nil then jxState.jxLinkLabel[a][b] = nil end
        if jxState.jxLinkLabel[b] ~= nil then jxState.jxLinkLabel[b][a] = nil end
    end
end

--- The connector curve via AutoDrive's own ADDubins solver (scripts/Utils/Dubins.lua): the shortest
--- curvature-bounded path between two POSES - position + heading at each tie-in - with the minimum
--- turn radius guaranteed by construction. Where the biarc is pinned to bending directly between its
--- two tangents, Dubins solves over the whole pose space (LSL/RSR/LSR/RSL/RLR/LRL), so it can swing
--- OUT across the corridor before curving back - the wide, road-using shape sketched for the inside
--- corner - and it never produces a radius below the bound. Dubins convention here (matching
--- ADDubins.createWayPoints): plane X = world x, plane Y = -world z, theta = atan2(-dz, dx).
--- Returns { points (interior, ~1.5 m), minRadius, length } or nil (solver missing/failed, or the
--- path is an implausible loop - the caller falls back to the biarc).
local function junctionDubins(pax, paz, tAx, tAz, pbx, pbz, tBx, tBz, turnR, y0, y1)
    if ADDubins == nil or ADDubins.new == nil then return nil end
    local ok, result = pcall(function()
        local d = ADDubins:new()
        local q0 = { pax, -paz, math.atan2(-tAz, tAx) }
        local q1 = { pbx, -pbz, math.atan2(-tBz, tBx) }
        -- A FRESH path table: ADDubins.DubinsPath is a shared global template that other callers
        -- (the pathfinder) mutate in place.
        local path = { qi = {}, param = {}, rho = 0, type = 0 }
        if d:dubins_shortest_path(path, q0, q1, turnR) ~= ADDubins.EDUBOK then return nil end
        local len = d:dubins_path_length(path)
        if len == nil or len <= 0 then return nil end
        -- An awkward pose pair can make the shortest Dubins path a huge loop-around; the biarc is
        -- the better answer there. Plausibility: no longer than the direct run plus a few turns.
        local dist = math.sqrt((pbx - pax) ^ 2 + (pbz - paz) ^ 2)
        if len > dist * 2.5 + turnR * 7 then return nil end
        -- Sample step from the SAME sagitta tolerance the biarc uses: the chord whose deviation from
        -- a radius-turnR arc is JUNCTION_SAG - denser on tight radii, never chunky, bounded sane.
        local step = 2 * math.sqrt(math.max(0.01, 2 * turnR * JUNCTION_SAG - JUNCTION_SAG * JUNCTION_SAG))
        step = math.max(0.75, math.min(2.0, step))
        local pts, q, x = {}, {}, step
        while x < len - 0.25 do
            d:dubins_path_sample(path, x, q)
            pts[#pts + 1] = { x = q[1], y = y0 + (y1 - y0) * (x / len), z = -q[2] }
            x = x + step
        end
        return { points = pts, minRadius = turnR, length = len }
    end)
    if not ok then return nil end
    return result
end

-- Lay the connector chain NA -> points -> NB OURSELVES, one deterministic link at a time. This used
-- to be ADGraphManager:createSplineConnection, which wires every link through toggleConnectionBetween
-- - a state FLIP, not a set - so on a graph whose link lists carry any toggle-era corruption
-- (duplicates, one-sided entries) it could remove where it meant to add and double where it meant to
-- single. With this, EVERY link the junction tool creates goes through junctionConnect above, whose
-- result is exactly what its arguments say. Interior points carry `flags` from creation (no
-- after-the-fact re-flag pass over an id range). Returns true when the whole chain laid.
local function junctionLayChain(NA, points, NB, dual, flags)
    local prev = NA
    for _, p in ipairs(points) do
        local wp
        -- A left turn's centre point is the SAME point for every left turn of this build: that one
        -- shared point is what makes AutoDrive take left turns one at a time, and the 90 degrees
        -- between their headings there is what stops it hopping from one to another.
        if p.centre and jxState.jxCentreNode ~= nil and jxState.jxCentreNode.id ~= nil
            and ADGraphManager:getWayPointById(jxState.jxCentreNode.id) == jxState.jxCentreNode then
            wp = jxState.jxCentreNode
        else
            -- ON THE SURFACE. A turn's heights run in a straight line from one lane end to the other,
            -- and on a crowned or sloping junction that line floats over the road or sinks into it
            -- ("not on the ground", the user's 2026-10-07 test). Each point takes the surface the
            -- ground tool would give it (the one nearest that line, so a deck stays a deck), never
            -- more than 2 m from it; offline, without the real ground, the line's height stands.
            local y = p.y
            if y ~= nil and ADFlyoverEditor.groundTargetAt ~= nil then
                local ok, s = pcall(ADFlyoverEditor.groundTargetAt, ADFlyoverEditor, p.x, y, p.z, y, true)
                if ok and type(s) == "number" and math.abs(s - y) <= 2 then y = s end
            end
            wp = ADFlyoverRecordWayPoint(p.x, y, p.z, false, false, false, 0,
                flags or AutoDrive.FLAG_NONE, false)
            jxNoteAdded(wp)
            if wp == nil then return false end
            if p.centre and jxState.jxBuildNew ~= nil then jxState.jxCentreNode = wp end
        end
        junctionConnect(prev, wp, dual)
        prev = wp
    end
    junctionConnect(prev, NB, dual)
    return true
end

-- MODSPLIT: SHARED WITH THE FILES LOADED AFTER THIS ONE (tools/modsplit/split.py writes this block)
ADFlyoverEditor.shared.JX_TWIN_LEAD = JX_TWIN_LEAD
ADFlyoverEditor.shared.JX_WHOLE_PIECE_REACH = JX_WHOLE_PIECE_REACH
ADFlyoverEditor.shared.junctionAngDiff = junctionAngDiff
ADFlyoverEditor.shared.junctionBiarc = junctionBiarc
ADFlyoverEditor.shared.junctionBranchTurn = junctionBranchTurn
ADFlyoverEditor.shared.junctionChainIndexNear = junctionChainIndexNear
ADFlyoverEditor.shared.junctionConnect = junctionConnect
ADFlyoverEditor.shared.junctionDisconnect = junctionDisconnect
ADFlyoverEditor.shared.junctionDubins = junctionDubins
ADFlyoverEditor.shared.junctionLayChain = junctionLayChain
ADFlyoverEditor.shared.junctionSegDir = junctionSegDir
ADFlyoverEditor.shared.junctionWalkBack = junctionWalkBack
ADFlyoverEditor.shared.jxBeforeInPlace = jxBeforeInPlace
ADFlyoverEditor.shared.jxBegin = jxBegin
ADFlyoverEditor.shared.jxBuildBegin = jxBuildBegin
ADFlyoverEditor.shared.jxBuildEnd = jxBuildEnd
ADFlyoverEditor.shared.jxByPlace = jxByPlace
ADFlyoverEditor.shared.jxCrossingPairs = jxCrossingPairs
ADFlyoverEditor.shared.jxEnd = jxEnd
ADFlyoverEditor.shared.jxInSite = jxInSite
ADFlyoverEditor.shared.jxIsNewLink = jxIsNewLink
ADFlyoverEditor.shared.jxKeptRoadsOf = jxKeptRoadsOf
ADFlyoverEditor.shared.jxLanesCross = jxLanesCross
ADFlyoverEditor.shared.jxMayDelete = jxMayDelete
ADFlyoverEditor.shared.jxNote = jxNote
ADFlyoverEditor.shared.jxNoteAdded = jxNoteAdded
ADFlyoverEditor.shared.jxNoteMoved = jxNoteMoved
ADFlyoverEditor.shared.jxRemove = jxRemove
ADFlyoverEditor.shared.jxRightOfWay = jxRightOfWay
ADFlyoverEditor.shared.jxRightOfWayLists = jxRightOfWayLists
ADFlyoverEditor.shared.jxRouteLines = jxRouteLines
ADFlyoverEditor.shared.jxSiteHas = jxSiteHas
ADFlyoverEditor.shared.jxSnapshot = jxSnapshot
ADFlyoverEditor.shared.jxState = jxState
ADFlyoverEditor.shared.jxTurnLabel = jxTurnLabel
ADFlyoverEditor.shared.jxWasCutByUs = jxWasCutByUs
-- MODSPLIT: end of the shared block

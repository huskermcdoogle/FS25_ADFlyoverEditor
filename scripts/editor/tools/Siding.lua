-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua
-- loads it after FlyoverEditor.lua, in the old file's order.
-- MODSPLIT: HELPERS FROM THE FILES LOADED BEFORE THIS ONE (tools/modsplit/split.py writes this block)
for _, name in ipairs({ "LINK_LISTS", "clearSplineState", "linkList" }) do
    if ADFlyoverEditor.shared == nil or ADFlyoverEditor.shared[name] == nil then
        Logging.error("[FlyoverEditor]: Siding.lua needs %s, which no file loaded before it shares", name)
    end
end
local LINK_LISTS = ADFlyoverEditor.shared.LINK_LISTS
local clearSplineState = ADFlyoverEditor.shared.clearSplineState
local linkList = ADFlyoverEditor.shared.linkList
-- MODSPLIT: end of the helpers

-- ---------------------------------------------------------------------------------------------
-- Divide - respace a span into a chosen number of evenly spaced points.
--
-- Two clicks pick the span, the wheel sets how many points go between the ends, right-click
-- applies. The wheel is the whole point of the tool: the right count is something you judge by
-- looking at it, not a number you know in advance, so it is worth being able to dial it up and
-- down and watch the result.
--
-- Spacing is by arc length along the existing path, so the divided run follows the same route -
-- this respaces a span, it does not straighten or smooth it. Use the smooth tool for that.
-- ---------------------------------------------------------------------------------------------

AutoDrive.FLYOVER_DIVIDE_MAX = 200

--- Straighten a span: drop the waypoints that are only noise, keep the ones that are a real bend.
---
--- The tolerance is what separates the two, and the preview is what makes it choosable - dial the
--- wheel and watch a bend survive or flatten. The point COUNT is preserved: the span keeps as many
--- waypoints as it had, respread evenly along the simplified shape, so straightening never leaves a
--- three-point run that has to be divided back out afterwards.
--- Span select for parallel and siding. Identical to straighten's; only the commit differs.
-- ---------------------------------------------------------------------------------------------
-- Siding
--
-- A siding has a shape you want repeatedly rather than one dialled in each time, so its offset and
-- length are persistent settings and the click just says WHERE. The click is the CENTRE, because
-- you point at the place a vehicle needs to pull over, not at where the taper should begin.
--
-- Four positions along the main line, not two:
--
--     ...A########B===========C########D...        A..B and C..D are the merges
--          \                      /               B..C is the parallel section
--           \____________________/
--
-- Only A and D need to be real waypoints - they are where the splines attach - and they almost
-- never land on an existing one, so the main line gets a waypoint inserted at each. That is the
-- divide this needs and the span-selected version did not.
-- ---------------------------------------------------------------------------------------------

--- The two ends of the run through `seedId`, or nil when it does not have exactly two.
--- collectRunBetweenJunctions returns a SET, so the ends have to be found rather than indexed:
--- they are the members with only one neighbour still inside the run. Neighbours are counted
--- uniquely, because a two-way connection appears in both `out` and `incoming`.
function ADFlyoverEditor:runEnds(seedId)
    local run, count = self:collectRunBetweenJunctions(seedId)
    if run == nil or count == nil or count < 2 then
        -- Almost always because the waypoint clicked IS a junction: the run stops at junctions, so
        -- seeding on one collects little or nothing. Worth saying, rather than reporting it as an
        -- unspecified failure to order the run - which is what sent this to the log four times.
        return nil, nil, 0, string.format(
            "id=%s gives a run of %s waypoint(s) - it is probably a junction itself. Click somewhere "
            .. "along a run instead.", tostring(seedId), tostring(count or 0))
    end
    local ends = {}
    for id in pairs(run) do
        local wp = ADGraphManager:getWayPointById(id)
        if wp ~= nil then
            local seen, inside = {}, 0
            for _, listName in ipairs(LINK_LISTS) do
                for _, other in pairs(linkList(wp, listName) or {}) do
                    if run[other] and not seen[other] then
                        seen[other] = true
                        inside = inside + 1
                    end
                end
            end
            if inside <= 1 then
                ends[#ends + 1] = id
            end
        end
    end
    if #ends ~= 2 then
        return nil, nil, #ends, string.format(
            "the run through id=%s has %d clear end(s), not 2 - it branches or closes on itself.",
            tostring(seedId), #ends)
    end
    return ends[1], ends[2], 2, nil
end

--- The run through `seedId` as an ordered point list, with cumulative distance and the seed's index.
--- Order a collected run by WALKING it from `startId`, staying inside the set.
---
--- This deliberately does not use a path finder. Once a siding has been laid on a loop, the loop
--- carries two junctions, so the run between them is bounded correctly - but the path finder is
--- free to take the OTHER way round, through the siding, and hand back a seven-waypoint shortcut
--- that never touches the waypoint that was clicked. Walking the set cannot do that: every step is
--- a neighbour already inside the run, so the result is the run itself, in order.
---
--- Returns nil when the walk does not cover the whole set, which means the run branches.
local function walkRunFrom(run, count, startId)
    local ordered = { startId }
    local visited = { [startId] = true }
    local previous, current = nil, startId

    while true do
        local wp = ADGraphManager:getWayPointById(current)
        if wp == nil then
            break
        end
        local nextId = nil
        for _, listName in ipairs(LINK_LISTS) do
            for _, other in pairs(linkList(wp, listName) or {}) do
                if run[other] and other ~= previous and not visited[other] then
                    nextId = other
                    break
                end
            end
            if nextId ~= nil then
                break
            end
        end
        if nextId == nil then
            break
        end
        visited[nextId] = true
        ordered[#ordered + 1] = nextId
        previous, current = current, nextId
    end

    if count ~= nil and #ordered < count then
        return nil
    end
    return ordered
end

--- A closed run has no ends, so it is cut opposite the seed: walk it right round, then rotate so
--- the seed sits mid-chain. A field loop is exactly where a siding belongs - a passing place on the
--- loop - so this is the common case, not an oddity. Cutting opposite the click leaves the most
--- room either side of it for the merge tapers.
local function orderClosedRun(run, count, seedId)
    local ordered = walkRunFrom(run, count, seedId)
    local n = ordered ~= nil and #ordered or 0
    if n < 3 then
        return ordered
    end
    local half = math.floor(n / 2)
    local rotated = {}
    for i = n - half + 1, n do rotated[#rotated + 1] = ordered[i] end
    for i = 1, n - half do rotated[#rotated + 1] = ordered[i] end
    return rotated
end

function ADFlyoverEditor:orderedRunThrough(seedId)
    local a, b, found, why = self:runEnds(seedId)

    local run, count = self:collectRunBetweenJunctions(seedId)
    if run == nil or count == nil or count < 2 then
        return nil, nil, nil, why or string.format(
            "id=%s gives a run of %s waypoint(s).", tostring(seedId), tostring(count or 0))
    end

    local ids
    if a == nil and found == 0 then
        -- No ends at all: a closed loop, not a failure. Cut it opposite the seed and carry on.
        ids = count >= 3 and orderClosedRun(run, count, seedId) or nil
        if ids ~= nil and #ids >= 3 then
            ADFlyoverSettings.debugLog("[FlyoverEditor]: that run is a closed loop of %d waypoint(s); using it "
                .. "cut opposite id=%s.", #ids, tostring(seedId))
        else
            return nil, nil, nil, why
        end
    elseif a == nil then
        return nil, nil, nil, why
    else
        ids = walkRunFrom(run, count, a)
        if ids == nil then
            return nil, nil, nil, string.format(
                "the run through id=%s branches - walking it from id=%s did not reach all %d "
                .. "waypoint(s). Pick a run that does not fork.",
                tostring(seedId), tostring(a), count)
        end
    end
    if #ids < 2 then
        return nil, nil, nil, string.format(
            "the run through id=%s ordered to %d waypoint(s).", tostring(seedId), #ids)
    end

    local pts, seedIndex = {}, nil
    for i, id in ipairs(ids) do
        local wp = ADGraphManager:getWayPointById(id)
        if wp == nil then
            return nil, nil, nil, string.format("waypoint id=%s vanished while ordering the run.", tostring(id))
        end
        pts[i] = { x = wp.x, y = wp.y, z = wp.z, id = id }
        if id == seedId then
            seedIndex = i
        end
    end
    if seedIndex == nil then
        return nil, nil, nil, string.format(
            "the path between the run's ends (%d waypoints) does not pass through id=%s - the run "
            .. "loops, so there is more than one way round it.", #ids, tostring(seedId))
    end

    local cumulative = { 0 }
    for i = 2, #pts do
        cumulative[i] = cumulative[i - 1]
            + MathUtil.vector2Length(pts[i].x - pts[i - 1].x, pts[i].z - pts[i - 1].z)
    end
    return pts, cumulative, seedIndex, nil
end

--- Position at `distance` along the ordered run, plus the segment it falls in.
local function pointAtDistance(pts, cumulative, distance)
    if distance <= 0 then
        return { x = pts[1].x, y = pts[1].y, z = pts[1].z }, 1, 0
    end
    local total = cumulative[#pts]
    if distance >= total then
        return { x = pts[#pts].x, y = pts[#pts].y, z = pts[#pts].z }, #pts - 1, 1
    end
    for i = 2, #pts do
        if cumulative[i] >= distance then
            local segLen = cumulative[i] - cumulative[i - 1]
            local t = segLen > 0 and (distance - cumulative[i - 1]) / segLen or 0
            return {
                x = pts[i - 1].x + (pts[i].x - pts[i - 1].x) * t,
                y = (pts[i - 1].y or 0) + ((pts[i].y or 0) - (pts[i - 1].y or 0)) * t,
                z = pts[i - 1].z + (pts[i].z - pts[i - 1].z) * t,
            }, i - 1, t
        end
    end
    return { x = pts[#pts].x, y = pts[#pts].y, z = pts[#pts].z }, #pts - 1, 1
end

--- The stretch of the run between two distances, with its ends interpolated exactly.
local function subChainByDistance(pts, cumulative, from, to)
    local out = {}
    local head = pointAtDistance(pts, cumulative, from)
    out[1] = head
    for i = 1, #pts do
        if cumulative[i] > from and cumulative[i] < to then
            out[#out + 1] = { x = pts[i].x, y = pts[i].y, z = pts[i].z }
        end
    end
    out[#out + 1] = pointAtDistance(pts, cumulative, to)
    return out
end

--- Everything the preview and the commit both need, so they cannot disagree about the shape.
function ADFlyoverEditor:sidingPlan()
    if self.sidingAnchorId == nil then
        return nil, nil
    end
    local pts, cumulative, seedIndex, why = self:orderedRunThrough(self.sidingAnchorId)
    if pts == nil then
        return nil, why or "could not order the run through that waypoint."
    end

    local offset = ADFlyoverSettings.get("sidingOffset") or 5
    local length = ADFlyoverSettings.get("sidingLength") or 30
    local merge = offset * AutoDrive.FLYOVER_SIDING_MERGE_RATIO
    local needed = length + 2 * merge
    local total = cumulative[#pts]
    if total < needed then
        return nil, string.format(
            "this run is %.0fm long; a %.0fm siding at %.1fm offset needs %.0fm including its merges.",
            total, length, offset, needed)
    end

    -- Centre the siding on the click, then slide it along if it would run off either end.
    local centre = cumulative[seedIndex]
    centre = math.max(needed / 2, math.min(total - needed / 2, centre))

    local aDistance = centre - needed / 2
    local dDistance = centre + needed / 2
    local parallel = subChainByDistance(pts, cumulative, aDistance + merge, dDistance - merge)

    local side = self.offsetSide or 1
    local track, err = ADOffsetGeometry.offsetOpenChain(parallel, offset * side)
    if track == nil then
        return nil, err
    end

    return {
        points = pts,
        cumulative = cumulative,
        aDistance = aDistance,
        dDistance = dDistance,
        track = track,
        offset = offset,
        length = length,
        merge = merge,
        side = side,
    }
end

--- Insert a waypoint partway along an existing connection, keeping the connection intact through it.
function ADFlyoverEditor:insertOnSegment(aId, bId, position, dual, flags)
    local a = ADGraphManager:getWayPointById(aId)
    local b = ADGraphManager:getWayPointById(bId)
    if a == nil or b == nil then
        return nil
    end
    -- Sever first, or the new point runs alongside the original connection rather than replacing it.
    local severed = false
    if table.contains(a.out, b.id) then
        ADGraphManager:toggleConnectionBetween(a, b, false, false, false)
        severed = true
    end
    if table.contains(b.out, a.id) then
        ADGraphManager:toggleConnectionBetween(b, a, false, false, false)
        severed = true
    end
    if not severed then
        -- These two are not actually connected any more, so inserting between them would fork the
        -- line rather than split it. Refusing is right: silently forking is the bug this guards.
        Logging.warning("[FlyoverEditor]: id=%s and id=%s are no longer connected, so nothing was "
            .. "inserted between them.", tostring(aId), tostring(bId))
        return nil
    end
    local y = self:resolveHeightAt(position.x, position.z, position.y)
    local wp = ADFlyoverRecordWayPoint(position.x, y, position.z, true, dual, false, aId, flags, false)
    local newId = (wp ~= nil and wp.id) or ADGraphManager:getWayPointsCount()
    local newNode = ADGraphManager:getWayPointById(newId)
    local bNode = ADGraphManager:getWayPointById(bId)
    if newNode ~= nil and bNode ~= nil then
        ADGraphManager:toggleConnectionBetween(newNode, bNode, false, dual, false)
    end
    return newId
end

--- A waypoint at `distance` along the run: the existing one when it is close enough, otherwise a
--- new one inserted into the connection there.
function ADFlyoverEditor:waypointAtDistance(pts, cumulative, distance, dual, flags)
    local position, segment, t = pointAtDistance(pts, cumulative, distance)
    if t <= 0.02 then
        return pts[segment].id
    end
    if t >= 0.98 then
        return pts[segment + 1].id
    end
    return self:insertOnSegment(pts[segment].id, pts[segment + 1].id, position, dual, flags)
end

function ADFlyoverEditor:sidingClick()
    if self.hoverId == nil then
        return
    end
    self.sidingAnchorId = self.hoverId
    self.sidingPreview = nil
    local seedPts = self:orderedRunThrough(self.sidingAnchorId)
    if seedPts ~= nil then
        self:pickSideFromCursor(seedPts)
    end
    local plan, err = self:sidingPlan()
    if plan == nil then
        Logging.warning("[FlyoverEditor]: %s", tostring(err))
        return
    end
    ADFlyoverSettings.debugLog("[FlyoverEditor]: siding centred on id=%s - %.0fm long, %.1fm to the %s, merging "
        .. "over %.0fm at each end. Wheel changes the length, right-click applies.",
        tostring(self.sidingAnchorId), plan.length, plan.offset,
        self:sideName(), plan.merge)
end

function ADFlyoverEditor:updateSidingPreview()
    if self.sidingAnchorId == nil then
        self.sidingPreview, self.sidingBlockedBy = nil, nil
        return
    end
    local plan, err = self:sidingPlan()
    self.sidingPreview = plan ~= nil and plan.track or nil
    self.sidingBlockedBy = err
end

function ADFlyoverEditor:commitSiding()
    local plan, err = self:sidingPlan()
    if plan == nil then
        Logging.warning("[FlyoverEditor]: %s", tostring(err))
        self:cancelSiding()
        return
    end

    local first = ADGraphManager:getWayPointById(plan.points[1].id)
    local second = ADGraphManager:getWayPointById(plan.points[2].id)
    local dual = ADGraphManager:isDualRoad(first, second)
    local flags = second.flags or AutoDrive.FLAG_NONE

    ADEditorHistory:snapshot("siding")

    -- Insert the far attachment, then RE-DERIVE the run before inserting the near one.
    --
    -- Doing both from the same snapshot is wrong whenever they land on the same segment, which a
    -- sparse run makes easy - a 30m siding with 8m merges spans 46m, so one long segment is enough.
    -- The first insertion severs a->b and leaves a->new->b; the second then looks for a->b, does not
    -- find it, severs nothing, and adds a SECOND path between the same two waypoints. That is the
    -- double connection.
    --
    -- Re-deriving is safe and cheap: inserting a waypoint on the line adds a vertex without moving
    -- anything, so every distance along the run is unchanged and aDistance still means what it did.
    local dId = self:waypointAtDistance(plan.points, plan.cumulative, plan.dDistance, dual, flags)
    if dId == nil then
        Logging.error("[FlyoverEditor]: could not place the siding's far attachment point.")
        self:cancelSiding()
        return
    end

    local freshPoints, freshCumulative = self:orderedRunThrough(self.sidingAnchorId)
    if freshPoints == nil then
        Logging.error("[FlyoverEditor]: lost the run after inserting the far attachment point.")
        self:cancelSiding()
        return
    end

    local aId = self:waypointAtDistance(freshPoints, freshCumulative, plan.aDistance, dual, flags)
    if aId == nil or dId == nil then
        Logging.error("[FlyoverEditor]: could not place the siding's attachment points.")
        self:cancelSiding()
        return
    end

    local firstNewId, lastNewId = self:createRunFrom(plan.track, dual, flags)
    if firstNewId == nil or lastNewId == nil then
        Logging.error("[FlyoverEditor]: the siding track could not be created.")
        self:cancelSiding()
        return
    end

    self:splineConnectIds(aId, firstNewId, dual, flags)
    self:splineConnectIds(lastNewId, dId, dual, flags)

    ADFlyoverSettings.debugLog("[FlyoverEditor]: laid a %.0fm siding %.1fm to the %s with %.0fm merges, %d track "
        .. "waypoint(s), attached at id=%s and id=%s.",
        plan.length, plan.offset, self:sideName(), plan.merge,
        #plan.track, tostring(aId), tostring(dId))

    self.sidingAnchorId, self.sidingPreview = nil, nil
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
end

function ADFlyoverEditor:cancelSiding()
    if self.sidingAnchorId ~= nil then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: cancelled the siding.")
    end
    self.sidingAnchorId, self.sidingPreview, self.sidingBlockedBy = nil, nil, nil
end

function ADFlyoverEditor:offsetClick()
    self:spanPickClick({
        getFrom = function() return self.offsetFromId end,
        getTo = function() return self.offsetToId end,
        setEnds = function(a, b)
            self.offsetFromId, self.offsetToId = a, b
            self.offsetPreview, self.offsetCache = nil, nil
        end,
        onSpan = function(a, b, span)
            -- The side follows where the cursor is when the span is completed, whichever gesture made it.
            local seedPts = self:offsetSpanPoints()
            if seedPts ~= nil then
                self:pickSideFromCursor(seedPts)
            end
            ADFlyoverSettings.debugLog("[FlyoverEditor]: span of %d waypoint(s). Wheel sets the offset (%.1fm); the side "
                .. "follows the cursor. Right-click applies.", #span, self.offsetDistance)
            -- The actual route, not just its length. runPathBetween is a path FINDER: asked to get from a
            -- siding back to the main line it can leave along one merge taper and return along the other,
            -- which is a legitimate shortest path and a span that doubles back. Printing the ids is what
            -- tells that apart from a wrong offset without another screenshot to guess from.
            local ids = {}
            for i, id in ipairs(span) do
                ids[i] = tostring(id)
            end
            ADFlyoverSettings.debugLog("[FlyoverEditor]: span route: %s", table.concat(ids, " -> "))
        end,
    })
end

--- Where a chain turns back on itself, or nil when it does not.
---
--- "Alongside" is defined relative to the direction of travel, so one side - left, say - lands on
--- opposite sides of the world before and after a reversal. The offset track appears to leap across
--- the line it was following, which is exactly what a doubled-back span produces.
local function reversalIn(pts)
    for i = 2, #pts - 1 do
        local ax, az = pts[i].x - pts[i - 1].x, pts[i].z - pts[i - 1].z
        local bx, bz = pts[i + 1].x - pts[i].x, pts[i + 1].z - pts[i].z
        local la = MathUtil.vector2Length(ax, az)
        local lb = MathUtil.vector2Length(bx, bz)
        if la > 0.01 and lb > 0.01 then
            -- cos of the turn between consecutive segments: -1 is an about-turn, +1 straight on.
            local cosTurn = (ax * bx + az * bz) / (la * lb)
            if cosTurn < -0.86 then  -- sharper than about 150 degrees
                return pts[i].id or i
            end
        end
    end
    return nil
end

--- A route from `fromId` to `toId` that never turns back on itself.
---
--- runPathBetween is a path FINDER, and its answer is the shortest way through the graph. Where the
--- line carries a siding, the shortest way between two points on the main line can leave along one
--- merge taper and return along the other: fewer waypoints than staying on the line, and a route
--- that doubles back through the intersections. Correct as a path, useless as something to run a
--- track beside.
---
--- So this walks the graph instead, and at every junction takes the neighbour that best CONTINUES
--- the current heading, refusing any step that turns back. That is what "keep going straight on
--- through the intersection" means as an instruction to a graph, and it is what picks the main line
--- over the taper without needing to know which is which.
function ADFlyoverEditor:straightRouteBetween(fromId, toId)
    local first = ADGraphManager:getWayPointById(fromId)
    local target = ADGraphManager:getWayPointById(toId)
    if first == nil or target == nil then
        return nil
    end

    local route = { fromId }
    local visited = { [fromId] = true }
    local current = first
    -- No heading yet on the first step: aim at the destination, so the walk sets off the right way
    -- out of a junction rather than down whichever neighbour happens to be listed first.
    local hx, hz = target.x - first.x, target.z - first.z
    local hl = MathUtil.vector2Length(hx, hz)
    if hl < 0.01 then
        return nil
    end
    hx, hz = hx / hl, hz / hl

    for _ = 1, 4096 do
        local seen, best, bestScore = {}, nil, nil
        for _, listName in ipairs(LINK_LISTS) do
            for _, otherId in pairs(linkList(current, listName) or {}) do
                if not seen[otherId] and not visited[otherId] then
                    seen[otherId] = true
                    local wp = ADGraphManager:getWayPointById(otherId)
                    if wp ~= nil then
                        local dx, dz = wp.x - current.x, wp.z - current.z
                        local d = MathUtil.vector2Length(dx, dz)
                        if d > 0.01 then
                            -- How well this step continues the heading. Reaching the destination
                            -- wins outright, so a final short hop is never passed over for a
                            -- straighter step going somewhere else.
                            local score = (dx / d) * hx + (dz / d) * hz
                            if otherId == toId then
                                score = math.huge
                            end
                            if score > -0.86 and (bestScore == nil or score > bestScore) then
                                best, bestScore = otherId, score
                            end
                        end
                    end
                end
            end
        end
        if best == nil then
            return nil  -- ran into a dead end without reaching the far point
        end

        route[#route + 1] = best
        visited[best] = true
        if best == toId then
            return route
        end

        local wp = ADGraphManager:getWayPointById(best)
        local dx, dz = wp.x - current.x, wp.z - current.z
        local d = MathUtil.vector2Length(dx, dz)
        hx, hz = dx / d, dz / d
        current = wp
    end
    return nil
end

--- The route between two ids, honouring a run that has already been resolved by walking.
---
--- Every span tool goes through here rather than calling runPathBetween directly. Whole-run scope
--- resolves the route ONCE, by walking the collected run, and that decision has to survive: asking
--- the path finder again between the same two ends sends the answer down whichever branch is
--- shortest, which on a line carrying a siding is never the siding.
function ADFlyoverEditor:spanBetween(fromId, toId)
    local stored = self.spanIds
    if stored ~= nil and stored[1] == fromId and stored[#stored] == toId then
        return stored
    end
    return self:runPathBetween(fromId, toId)
end

--- Resolve the whole run through `seedId` in one click: its two ends, and the route between them.
---
--- Shared by every tool that works on a span, so "whole run" means the same thing everywhere and
--- picks the branch that was clicked in each of them. Returns nil when the run does not have two
--- clear ends - a junction, or a closed loop - and the caller falls back to asking for two clicks.
function ADFlyoverEditor:resolveWholeRun(seedId)
    local run, count = self:collectRunBetweenJunctions(seedId)
    if run == nil or count == nil or count < 2 then
        return nil
    end

    local ends = {}
    for id in pairs(run) do
        local wp = ADGraphManager:getWayPointById(id)
        if wp ~= nil then
            local seen, inside = {}, 0
            for _, listName in ipairs(LINK_LISTS) do
                for _, other in pairs(linkList(wp, listName) or {}) do
                    if run[other] and not seen[other] then
                        seen[other] = true
                        inside = inside + 1
                    end
                end
            end
            if inside <= 1 then
                ends[#ends + 1] = id
            end
        end
    end
    if #ends ~= 2 then
        return nil
    end

    -- Reach one further at each end, onto the junction itself: the run is what lies BETWEEN
    -- junctions, so its own ends stop a segment short of them.
    local function reachToJunction(endId)
        local wp = ADGraphManager:getWayPointById(endId)
        if wp == nil then
            return endId
        end
        local seen, outside, found = {}, 0, nil
        for _, listName in ipairs(LINK_LISTS) do
            for _, other in pairs(linkList(wp, listName) or {}) do
                if not run[other] and not seen[other] then
                    seen[other] = true
                    outside = outside + 1
                    found = other
                end
            end
        end
        return outside == 1 and found or endId
    end

    local fromId, toId = reachToJunction(ends[1]), reachToJunction(ends[2])
    -- Both ends reach the SAME junction: the run is a loop that leaves a junction and comes back to it
    -- (captured 2026-09-24: "the whole run: 66 waypoint(s), id=12458 to id=12458"). A span from a point to
    -- itself is not a span - Straighten collapsed it and the others went all the way around it - so it is
    -- refused like a closed loop, and the caller asks for two clicks on the part wanted instead.
    if fromId == toId then
        return nil
    end
    local ordered = walkRunFrom(run, count, ends[1])
    if ordered == nil then
        return nil
    end

    local ids = { fromId }
    for _, id in ipairs(ordered) do
        ids[#ids + 1] = id
    end
    if toId ~= ends[2] then
        ids[#ids + 1] = toId
    end
    return fromId, toId, ids
end

--- Points of the selected span, and the span itself.
function ADFlyoverEditor:offsetSpanPoints()
    if self.offsetFromId == nil or self.offsetToId == nil then
        return nil, nil
    end
    -- Whole-run scope has already decided the route by walking the collected run, and that decision
    -- has to survive: re-deriving it here would put the path finder back in charge and send a
    -- siding's offset down the main line.
    local span = self.spanIds or self:runPathBetween(self.offsetFromId, self.offsetToId)

    -- Only when the shortest path doubles back. On a plain span the path finder is right and
    -- cheaper, so it keeps the job; the straight walk is the answer to intersections specifically.
    if span ~= nil and #span >= 3 then
        local check = {}
        for i, id in ipairs(span) do
            local wp = ADGraphManager:getWayPointById(id)
            check[i] = wp ~= nil and { x = wp.x, z = wp.z, id = id } or nil
        end
        if #check == #span and reversalIn(check) ~= nil then
            local straight = self:straightRouteBetween(self.offsetFromId, self.offsetToId)
            if straight ~= nil and #straight >= 2 then
                ADFlyoverSettings.debugLog("[FlyoverEditor]: the shortest path doubled back through an "
                    .. "intersection; took the straight run instead (%d waypoint(s), was %d).",
                    #straight, #span)
                span = straight
            end
        end
    end

    if span == nil or #span < 2 then
        return nil, span
    end
    local pts = {}
    for _, id in ipairs(span) do
        local wp = ADGraphManager:getWayPointById(id)
        if wp ~= nil then
            pts[#pts + 1] = { x = wp.x, y = wp.y, z = wp.z }
        end
    end
    if #pts < 2 then
        return nil, span
    end
    return pts, span
end

--- Which side of the span the cursor is on: +1 left of travel, -1 right.
---
--- The side deliberately does NOT come from click order. Picking the far end first would otherwise
--- mirror the whole result, which is invisible until it is too late and impossible to reason about.
--- Taking it from the cursor makes it obvious instead: point at the side you want and the preview
--- is there, whichever end you happened to click first.
function ADFlyoverEditor:offsetSideFromCursor(pts)
    local cx, cz = self.cursorX, self.cursorZ
    if cx == nil or cz == nil then
        return 1
    end

    local bestIndex, bestDistance = 1, math.huge
    for i = 1, #pts - 1 do
        local a, b = pts[i], pts[i + 1]
        local dx, dz = b.x - a.x, b.z - a.z
        local lengthSquared = dx * dx + dz * dz
        local t = 0
        if lengthSquared > 1e-9 then
            t = math.max(0, math.min(1, ((cx - a.x) * dx + (cz - a.z) * dz) / lengthSquared))
        end
        local d = MathUtil.vector2Length(cx - (a.x + t * dx), cz - (a.z + t * dz))
        if d < bestDistance then
            bestIndex, bestDistance = i, d
        end
    end

    local a, b = pts[bestIndex], pts[bestIndex + 1]
    local cross = (b.x - a.x) * (cz - a.z) - (b.z - a.z) * (cx - a.x)
    return cross >= 0 and 1 or -1, a, b
end

function ADFlyoverEditor:updateOffsetPreview()
    local pts = self:offsetSpanPoints()
    if pts == nil or self.offsetDistance < 0.1 then
        self.offsetPreview, self.offsetBlockedBy, self.offsetCache = nil, nil, nil
        return
    end

    local signed = self.offsetDistance * (self.offsetSide or 1)

    -- The offset is O(n^2) in the fold removal, and this runs every frame while a preview is up.
    -- On a long run that is thousands of segment-pair tests per frame for a result that only
    -- changes when the span, the distance or the side does - so only recompute when one of them has.
    local key = string.format("%s:%s:%.2f:%d:%d",
        tostring(self.offsetFromId), tostring(self.offsetToId), signed, #pts, self.offsetScope)
    if self.offsetCache ~= nil and self.offsetCache.key == key then
        self.offsetPreview, self.offsetBlockedBy = self.offsetCache.points, self.offsetCache.err
        return
    end

    local offset, err = ADOffsetGeometry.offsetOpenChain(pts, signed)
    self.offsetPreview, self.offsetBlockedBy = offset, err
    self.offsetSignedDistance = signed
    self.offsetCache = { key = key, points = offset, err = err }
end

--- Lay a chain of new waypoints down, joined in order. Returns the first and last new ids.
---
--- `dual` may be a boolean for the whole chain, or a function(index) returning the mode for the
--- connection arriving at point `index`. A span is not necessarily uniform - a route can run one-way
--- along a stretch and two-way around a bend - and sampling it once turned every mixed span into a
--- track that was entirely one thing or entirely the other, silently.
function ADFlyoverEditor:createRunFrom(points, dual, flags)
    local perSegment = type(dual) == "function"
    local firstId, previousId = nil, nil
    for index, p in ipairs(points) do
        -- The ground tool's targeting, with the source point's height as the expected line - not
        -- resolveHeightAt. That one leaves anything more than half a metre above the terrain alone,
        -- assuming a bridge, and an offset track lands beside its source on ground that may be well
        -- below it: down an embankment the new points kept the source's height and hung in the air.
        -- Nearest surface to the source height drops them onto the slope, and still keeps a track
        -- that stays over a bridge deck on the deck.
        local sourceY = p.y or AutoDrive:getTerrainHeightAtWorldPos(p.x, p.z)
        local y = self:groundTargetAt(p.x, sourceY, p.z, sourceY, true)
            or self:resolveHeightAt(p.x, p.z, p.y)
        local segmentDual = perSegment and dual(index) or dual
        local wp = ADFlyoverRecordWayPoint(p.x, y, p.z, previousId ~= nil, segmentDual, false,
            previousId or 0, flags, false)
        previousId = (wp ~= nil and wp.id) or ADGraphManager:getWayPointsCount()
        firstId = firstId or previousId
    end
    return firstId, previousId
end

--- Ask the SOURCE span which mode applies at a point on the offset track.
---
--- The two chains are not the same length - offsetting the inside of a bend drops points that fold,
--- so a fifteen-point span can become an eight-point track - and there is no index that maps one to
--- the other. Nearest source segment by midpoint is the honest way across: the offset point came
--- from somewhere along the original, and that is the segment whose direction it should inherit.
function ADFlyoverEditor:sourceDualAt(span, x, z)
    local best, bestDistance = nil, math.huge
    for i = 1, #span - 1 do
        local a = ADGraphManager:getWayPointById(span[i])
        local b = ADGraphManager:getWayPointById(span[i + 1])
        if a ~= nil and b ~= nil then
            local mx, mz = (a.x + b.x) * 0.5, (a.z + b.z) * 0.5
            local d = MathUtil.vector2Length(x - mx, z - mz)
            if d < bestDistance then
                best, bestDistance = ADGraphManager:isDualRoad(a, b), d
            end
        end
    end
    return best
end

--- A spline between two existing waypoints, falling back to a straight connection when the mod
--- declines to interpolate - which it does for short or already-connected pairs, and which is an
--- ordinary outcome rather than a failure.
function ADFlyoverEditor:splineConnectIds(startId, endId, dual, flags)
    local a = ADGraphManager:getWayPointById(startId)
    local b = ADGraphManager:getWayPointById(endId)
    if a == nil or b == nil then
        return false
    end
    if type(AutoDrive.splineInterpolationUserCurvature) ~= "number" then
        AutoDrive.splineInterpolationUserCurvature = AutoDrive.FLYOVER_DEFAULT_CURVATURE
    end

    local built = pcall(function() self:buildSplineInterpolation(a, b) end)
    local interpolation = AutoDrive.splineInterpolation
    if not built or interpolation == nil or not interpolation.valid
        or interpolation.waypoints == nil or #interpolation.waypoints <= 2 then
        ADGraphManager:toggleConnectionBetween(a, b, false, dual, false)
        clearSplineState()
        return true
    end

    local middle = {}
    for i, wp in ipairs(interpolation.waypoints) do
        if i ~= 1 and i < #interpolation.waypoints then
            middle[#middle + 1] = { x = wp.x, y = wp.y, z = wp.z }
        end
    end
    ADGraphManager:createSplineConnection(startId, middle, endId, dual, false)
    if flags ~= nil and flags ~= AutoDrive.FLAG_NONE then
        local total = ADGraphManager:getWayPointsCount()
        for id = total - #middle + 1, total do
            ADGraphManager:setWayPointFlags(id, flags, false)
        end
    end
    -- Built here, so cleared here. This is a one-shot connection, not a live preview: it borrows
    -- AutoDrive's interpolation state to shape the curve and is finished with it immediately.
    --
    -- Leaving it set costs the camera zoom. AutoDrive:handleSplineCurvature suppresses zooming for
    -- as long as an interpolation is valid, so a stale one silently owns the mouse wheel from then
    -- on - and it does not show up while a tool that claims the wheel itself is selected, only
    -- afterwards, which is a long way from the siding that actually caused it.
    clearSplineState()
    return true
end

--- Commit for both parallel and siding.
---
--- Direction: the new run mirrors the source. A two-way span gives a two-way track, because
--- "opposite" means nothing there. A one-way span gives a track running the OTHER way, which is the
--- point of laying one - a return lane rather than a second lane going the same way - and it is
--- done simply by laying the points down back to front.
---
--- Siding additionally splines both ends into the span it came from, giving a genuine alternative
--- route: from one end you can take the main line or the siding, rejoining at the other. No
--- dividing is needed, because the attachment points are the span's own endpoints, which already
--- exist - that is what selecting a span rather than a length buys.
ADFlyoverEditor.PARALLEL_FLOW_NAMES = { "same way", "opposite" }

function ADFlyoverEditor:cycleParallelFlow()
    self.parallelFlow = (self.parallelFlow % #self.PARALLEL_FLOW_NAMES) + 1
    ADFlyoverSettings.debugLog("[FlyoverEditor]: a parallel track beside a one-way road runs %s.",
        self.PARALLEL_FLOW_NAMES[self.parallelFlow])
end

function ADFlyoverEditor:commitOffset()
    ADFlyoverSettings.debugLog("[FlyoverEditor]: commit %s: from=%s to=%s anchor=%s preview=%s",
        self.tool == self.TOOL.SIDING and "siding" or "parallel",
        tostring(self.offsetFromId), tostring(self.offsetToId), tostring(self.sidingAnchorId),
        self.offsetPreview ~= nil and tostring(#self.offsetPreview) or "nil")
    local pts, span = self:offsetSpanPoints()
    local newPoints = self.offsetPreview
    if pts == nil or span == nil or newPoints == nil or #newPoints < 2 then
        if self.offsetBlockedBy ~= nil then
            Logging.warning("[FlyoverEditor]: %s", self.offsetBlockedBy)
        end
        self:cancelOffset()
        return
    end

    local first = ADGraphManager:getWayPointById(span[1])
    local second = ADGraphManager:getWayPointById(span[2])
    local dual = ADGraphManager:isDualRoad(first, second)
    local flags = second.flags or AutoDrive.FLAG_NONE
    local siding = self.tool == self.TOOL.SIDING

    -- Survey the WHOLE span, not just its first pair. A route is not necessarily uniform: it can
    -- run one-way along a stretch and two-way around a bend, and sampling one segment turned every
    -- such span into a track that was entirely one thing - silently, with the log confidently
    -- reporting the mode it had guessed.
    local dualCount, oneWayCount = 0, 0
    for i = 1, #span - 1 do
        local a = ADGraphManager:getWayPointById(span[i])
        local b = ADGraphManager:getWayPointById(span[i + 1])
        if a ~= nil and b ~= nil then
            if ADGraphManager:isDualRoad(a, b) then
                dualCount = dualCount + 1
            else
                oneWayCount = oneWayCount + 1
            end
        end
    end
    local mixed = dualCount > 0 and oneWayCount > 0

    -- Whether to lay the track back to front is necessarily a decision for the whole run - a chain
    -- has one direction. Any one-way part is what settles it: those want a return lane, and the
    -- two-way parts are indifferent, so following the one-way parts costs the two-way ones nothing.
    -- Only when asked: a parallel track beside a one-way road used to be laid back to front every time
    -- (a return lane), which is a surprise as a default. parallelFlow chooses; same way is the default.
    local layReversed = oneWayCount > 0 and self.parallelFlow == 2

    local laying = newPoints
    if layReversed and not siding then
        local flipped = {}
        for i = #newPoints, 1, -1 do
            flipped[#flipped + 1] = newPoints[i]
        end
        laying = flipped
    end

    ADEditorHistory:snapshot(siding and "siding" or "parallel track")
    -- Each connection takes the mode of the source segment nearest to it. On a uniform span that is
    -- the same answer everywhere, so nothing changes there; on a mixed one the track now inherits
    -- the pattern instead of flattening it.
    local layingDual = dual
    if mixed and not siding then
        layingDual = function(index)
            local p = laying[index]
            local at = p ~= nil and self:sourceDualAt(span, p.x, p.z) or nil
            if at == nil then
                return dual
            end
            return at
        end
    end
    local firstNewId, lastNewId = self:createRunFrom(laying, layingDual, flags)

    if siding and firstNewId ~= nil and lastNewId ~= nil then
        self:splineConnectIds(span[1], firstNewId, dual, flags)
        self:splineConnectIds(lastNewId, span[#span], dual, flags)
    end

    ADFlyoverSettings.debugLog("[FlyoverEditor]: laid a %s of %d waypoint(s) %.1fm to the %s%s.",
        siding and "siding" or "parallel track", #laying, self.offsetDistance,
        self:sideName(),
        siding and ", splined in at both ends"
            or (mixed and string.format(", mixed (%d two-way, %d one-way segment(s)), running %s",
                    dualCount, oneWayCount, layReversed and "opposite" or "the same way")
                or (dual and ", two-way" or (layReversed and ", running opposite" or ", running the same way"))))

    self.offsetFromId, self.offsetToId, self.offsetPreview, self.offsetCache = nil, nil, nil, nil
    self.spanIds = nil
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
end

function ADFlyoverEditor:cancelOffset()
    if self.offsetFromId ~= nil or self.offsetToId ~= nil then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: cancelled the span.")
    end
    self.offsetFromId, self.offsetToId, self.offsetPreview, self.offsetCache = nil, nil, nil, nil
    self.spanIds = nil
end

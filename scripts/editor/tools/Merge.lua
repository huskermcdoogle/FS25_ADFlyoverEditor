-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua
-- loads it after FlyoverEditor.lua, in the old file's order.
-- MODSPLIT: HELPERS FROM THE FILES LOADED BEFORE THIS ONE (tools/modsplit/split.py writes this block)
for _, name in ipairs({ "LINK_LISTS", "addLink", "linkList" }) do
    if ADFlyoverEditor.shared == nil or ADFlyoverEditor.shared[name] == nil then
        Logging.error("[FlyoverEditor]: Merge.lua needs %s, which no file loaded before it shares", name)
    end
end
local LINK_LISTS = ADFlyoverEditor.shared.LINK_LISTS
local addLink = ADFlyoverEditor.shared.addLink
local linkList = ADFlyoverEditor.shared.linkList
-- MODSPLIT: end of the helpers

-- ---------------------------------------------------------------------------------------------
-- Merge two tracks, chosen by clicking one waypoint on each.
--
-- This replaces an earlier version that swept a radius around the cursor and guessed which pairs
-- belonged together. That guessing was the whole problem: it could not tell two lanes of a road
-- from a run hairpinning back past itself, so it needed a graph-distance heuristic to avoid
-- destroying turnarounds, and it still gave no way to say WHICH two tracks were meant.
--
-- Naming the two tracks removes the ambiguity at the source. Each click seeds a walk along its own
-- run, and only pairs with one point from each run are considered - so a run can never be merged
-- into itself, whatever its shape.
-- ---------------------------------------------------------------------------------------------

--- Walk outward from a seed along its run, stopping at junctions. A junction is a waypoint with
--- more than two distinct neighbours: the run genuinely branches there, and continuing through it
--- would drag an unrelated route into the merge.
--- `blocked` marks waypoints the walk must not enter. Used to wall off the span being merged, so
--- collecting the OTHER track cannot run through the point where the two join and come back along
--- the span itself.
function ADFlyoverEditor:collectRun(seedId, maxNodes, blocked)
    maxNodes = maxNodes or AutoDrive.FLYOVER_MERGE_MAX_RUN
    blocked = blocked or {}

    local run = { [seedId] = true }
    local count = 1
    local junctions = 0
    local frontier = { seedId }

    while #frontier > 0 and count < maxNodes do
        local nextFrontier = {}
        for _, id in ipairs(frontier) do
            local wp = ADGraphManager:getWayPointById(id)
            if wp ~= nil then
                local neighbours = {}
                for _, listName in ipairs(LINK_LISTS) do
                    for _, other in pairs(linkList(wp, listName) or {}) do
                        if not table.contains(neighbours, other) then
                            table.insert(neighbours, other)
                        end
                    end
                end

                -- Walk through ordinary points and through the seed itself, but stop at a junction
                -- reached from elsewhere - that is where this run ends and another begins.
                if #neighbours <= 2 or id == seedId then
                    for _, other in ipairs(neighbours) do
                        if not run[other] and not blocked[other] then
                            run[other] = true
                            count = count + 1
                            table.insert(nextFrontier, other)
                        end
                    end
                else
                    junctions = junctions + 1
                end
            end
        end
        frontier = nextFrontier
    end

    return run, count, junctions
end

--- Shortest path between two waypoints along their run, ignoring link direction. Direction has to
--- be ignored: the span is being pointed at on screen, and whether the two clicks happen to go with
--- or against the one-way arrows is not something the user should have to think about.
function ADFlyoverEditor:runPathBetween(startId, endId, maxNodes)
    maxNodes = maxNodes or AutoDrive.FLYOVER_MERGE_MAX_RUN

    local cameFrom = { [startId] = false }
    local frontier = { startId }
    local visited = 1
    local found = startId == endId

    while #frontier > 0 and not found and visited < maxNodes do
        local nextFrontier = {}
        for _, id in ipairs(frontier) do
            local wp = ADGraphManager:getWayPointById(id)
            if wp ~= nil then
                for _, listName in ipairs(LINK_LISTS) do
                    for _, other in pairs(linkList(wp, listName) or {}) do
                        if cameFrom[other] == nil then
                            cameFrom[other] = id
                            visited = visited + 1
                            if other == endId then
                                found = true
                                break
                            end
                            table.insert(nextFrontier, other)
                        end
                    end
                    if found then break end
                end
            end
            if found then break end
        end
        frontier = nextFrontier
    end

    if not found then
        return nil
    end

    local path, id = {}, endId
    while id do
        table.insert(path, 1, id)
        id = cameFrom[id]
    end
    return path
end

--- Work out what a merge would take, and remember it so draw() can show it.
---
--- Where two tracks converge and separate again the overlapping stretch is genuinely hard to see:
--- the two lines are within a metre of each other, drawn on top of each other, and the point where
--- they diverge past the merge distance is invisible. Guessing where to put the span clicks is
--- what makes the tool fiddly, and guessing wrong is what makes it fail. Showing the answer before
--- committing turns that guess into something you can see.
---
--- Recomputed only when the span or the hovered waypoint changes, not every frame.
function ADFlyoverEditor:updateMergePreview()
    if self.mergeFromId == nil then
        self.mergePreviewSpan, self.mergePreviewOther, self.mergePreviewQueryId = nil, nil, nil
        return
    end

    -- The far end of the span is whichever is settled: the locked second click, else whatever is
    -- hovered, so the corridor is visible while still choosing it.
    local endId = self.mergeToId or self.hoverId
    if endId == nil or endId == self.mergeFromId then
        self.mergePreviewSpan, self.mergePreviewOther = nil, nil
        return
    end

    local queryId = tostring(self.mergeFromId) .. ":" .. tostring(endId) .. ":" .. tostring(self.mergeToId ~= nil and self.hoverId or "")
    if queryId == self.mergePreviewQueryId then
        return
    end
    self.mergePreviewQueryId = queryId

    local span = self:spanBetween(self.mergeFromId, endId)
    self.mergePreviewSpan = span
    self.mergePreviewOther = nil
    self.mergeNear = nil
    if span == nil then
        return
    end

    local inSpan = {}
    for _, id in ipairs(span) do
        inSpan[id] = true
    end

    local mergeDistance = ADFlyoverSettings.get("flyoverMergeDistance") or AutoDrive.FLYOVER_MERGE_DISTANCE
    local nearSpan = {}
    local wayPoints = ADGraphManager:getWayPoints()
    for i = 1, #wayPoints do
        local wp = wayPoints[i]
        if not inSpan[wp.id] and self:distanceToTrack(wp.x, wp.z, span) <= mergeDistance then
            nearSpan[wp.id] = true
        end
    end

    if self.mergeToId ~= nil then
        self.mergeNear = nearSpan
    end

    -- Once the span is locked, narrow the preview to the track under the cursor, which is what the
    -- confirming click will actually pick.
    if self.mergeToId ~= nil and self.hoverId ~= nil and nearSpan[self.hoverId] then
        self.mergePreviewOther = self:connectedWithin(self.hoverId, nearSpan)
    else
        self.mergePreviewOther = nearSpan
    end
end

function ADFlyoverEditor:mergeClick()
    if self.hoverId == nil then
        return
    end

    -- Span picked and the click lands on a track running alongside it: that is the confirm - merge now.
    if self.mergeToId ~= nil and self.mergeNear ~= nil and self.mergeNear[self.hoverId] then
        local fromId, toId = self.mergeFromId, self.mergeToId
        self.mergeFromId, self.mergeToId = nil, nil
        self:mergeTracks(fromId, toId, self.hoverId)
        self.spanIds, self.mergeNear, self.mergePreviewQueryId = nil, nil, nil
        return
    end

    -- Otherwise it is the shared span pick: click / second click = span, double-click = whole run,
    -- another click replaces the nearer end.
    self:spanPickClick({
        getFrom = function() return self.mergeFromId end,
        getTo = function() return self.mergeToId end,
        setEnds = function(a, b)
            self.mergeFromId, self.mergeToId = a, b
            self.mergePreviewSpan, self.mergePreviewOther, self.mergePreviewQueryId = nil, nil, nil
        end,
    })
end

--- Right-click with a span picked and exactly ONE track running alongside it: merge with that, no
--- third click needed. Returns true when it merged.
function ADFlyoverEditor:mergeWithOnlyCandidate()
    if self.mergeFromId == nil or self.mergeToId == nil or self.mergeNear == nil then
        return false
    end
    local seed = nil
    for id in pairs(self.mergeNear) do
        seed = id
        break
    end
    if seed == nil then
        return false
    end
    local group = self:connectedWithin(seed, self.mergeNear)
    for id in pairs(self.mergeNear) do
        if not group[id] then
            return false   -- more than one candidate track: the player has to click the one they mean
        end
    end
    local fromId, toId = self.mergeFromId, self.mergeToId
    self.mergeFromId, self.mergeToId = nil, nil
    self:mergeTracks(fromId, toId, seed)
    self.spanIds, self.mergeNear, self.mergePreviewQueryId = nil, nil, nil
    return true
end

--- Merge a span of one track with the stretch of another track running alongside it.
---
--- The other track is found GEOMETRICALLY - every waypoint outside the span that lies within the
--- merge distance of it - rather than by walking outward from the third click. Walking was too
--- fragile on a real network: the span is itself a shortest path, and where two lanes interconnect
--- it can consume the very neighbours the walk needs, leaving it stranded on the seed with nothing
--- to measure. Proximity to the span is also simply a better definition of "the track running
--- alongside this one" than "whatever is reachable from here".
---
--- The third click still matters: it says WHICH nearby track is meant, and nothing is merged
--- unless it is one of the waypoints found.
---
--- Separation is measured perpendicularly, from each waypoint to the other track as a polyline,
--- not from waypoint to waypoint. Two separately recorded tracks do not have their points aligned,
--- so a nearest-waypoint measure reads several metres where the lanes are less than one apart.
function ADFlyoverEditor:mergeTracks(spanStartId, spanEndId, seedB)
    local span = self:spanBetween(spanStartId, spanEndId)
    if span == nil then
        Logging.warning("[FlyoverEditor]: lost the span between id=%s and id=%s.",
            tostring(spanStartId), tostring(spanEndId))
        return
    end

    local inSpan = {}
    for _, id in ipairs(span) do
        inSpan[id] = true
    end

    if inSpan[seedB] then
        Logging.warning("[FlyoverEditor]: id=%s is part of the span itself; the third click goes on the OTHER track.",
            tostring(seedB))
        return
    end

    local mergeDistance = ADFlyoverSettings.get("flyoverMergeDistance") or AutoDrive.FLYOVER_MERGE_DISTANCE

    -- Everything running alongside the span, whatever it is connected to.
    local nearSpan, nearCount = {}, 0
    local nearestOutside = math.huge
    local wayPoints = ADGraphManager:getWayPoints()
    for i = 1, #wayPoints do
        local wp = wayPoints[i]
        if not inSpan[wp.id] then
            local dist = self:distanceToTrack(wp.x, wp.z, span)
            if dist <= mergeDistance then
                nearSpan[wp.id] = true
                nearCount = nearCount + 1
            elseif dist < nearestOutside then
                nearestOutside = dist
            end
        end
    end

    if not nearSpan[seedB] then
        local seed = ADGraphManager:getWayPointById(seedB)
        local seedDist = seed ~= nil and self:distanceToTrack(seed.x, seed.z, span) or nil
        Logging.warning("[FlyoverEditor]: the waypoint clicked for the other track is %s from the span, further than the %.1fm merge distance. Raise Flyover: Merge Distance, or click a point that actually runs alongside the span.",
            seedDist ~= nil and string.format("%.2fm", seedDist) or "an unknown distance",
            mergeDistance)
        return
    end

    -- Keep only the piece connected to the third click, so a different track that happens to pass
    -- close by somewhere else along the span is not swept in as well.
    local divergence = ADFlyoverSettings.get("flyoverMergeDivergence") or AutoDrive.FLYOVER_MERGE_DIVERGENCE
    local runB, bridged = self:connectedWithin(seedB, nearSpan, divergence)

    -- Order the other track by how far along the SPAN each of its waypoints sits, not by walking
    -- its own connections. The walk cannot cross the gap where the tracks diverged - that is the
    -- whole reason the divergence tolerance exists - so ordering that way returned only the piece
    -- on one side of the gap and the merge stopped there regardless of the tolerance.
    local orderedB = {}
    local alongOf = {}
    for id in pairs(runB) do
        local wp = ADGraphManager:getWayPointById(id)
        if wp ~= nil then
            local _, _, _, along = self:distanceToTrack(wp.x, wp.z, span)
            alongOf[id] = along
            table.insert(orderedB, id)
        end
    end
    table.sort(orderedB, function(a, b) return alongOf[a] < alongOf[b] end)
    local countB = 0
    for _ in pairs(runB) do
        countB = countB + 1
    end

    if #orderedB < 2 then
        Logging.warning("[FlyoverEditor]: only %d waypoint(s) of the other track run within %.1fm of the span - not enough to merge. %d waypoint(s) were near the span in total.",
            #orderedB, mergeDistance, nearCount)
        return
    end

    -- Which span waypoints run close alongside it, and where their centre line is.
    local aInside, aTarget = {}, {}
    local nearestMiss = math.huge
    for _, idA in ipairs(span) do
        local a = ADGraphManager:getWayPointById(idA)
        if a ~= nil then
            local dist, cx, cz = self:distanceToTrack(a.x, a.z, orderedB)
            if dist <= mergeDistance then
                table.insert(aInside, idA)
                aTarget[idA] = { x = (a.x + cx) / 2, z = (a.z + cz) / 2 }
            elseif dist < nearestMiss then
                nearestMiss = dist
            end
        end
    end

    if #aInside == 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: no part of the %d-waypoint span runs within %.1fm of the other track. Closest they come is %s.",
            #span, mergeDistance,
            nearestMiss < math.huge and string.format("%.2fm", nearestMiss) or "not measurable")
        return
    end

    local bInside, inB = {}, {}
    for _, idB in ipairs(orderedB) do
        table.insert(bInside, idB)
        inB[idB] = true
    end

    ADEditorHistory:snapshot("merge tracks")
    self:absorbTrack(span, aInside, aTarget, bInside, inB)

    ADFlyoverSettings.debugLog("[FlyoverEditor]: merged %d of %d span waypoint(s) with %d from the other track, within %.1fm.",
        #aInside, #span, #bInside, mergeDistance)
    if nearestMiss < math.huge then
        ADFlyoverSettings.debugLog("[AD]   the rest of the span stays separate; nearest it came was %.2fm.", nearestMiss)
    end
    if bridged > 0 then
        ADFlyoverSettings.debugLog("[AD]   crossed %d waypoint(s) where the tracks pulled apart, within the %.0fm divergence tolerance, and picked the track up again on the far side.",
            bridged, divergence)
    end
    if countB < nearCount then
        ADFlyoverSettings.debugLog("[AD]   %d other waypoint(s) were also near the span but not connected to the one clicked, and were left alone.",
            nearCount - countB)
    end
end

--- The waypoints reachable from seedId, staying near the span but tolerating gaps where the two
--- tracks pull apart.
---
--- Requiring every step to be inside the corridor was the clumsiness: real tracks converge and
--- diverge along their length - round an obstacle, past a gateway, through a yard - and the first
--- place they part company by more than the merge distance ended the walk. What should have been
--- one merge became several, each needing its own span picked by hand.
---
--- The walk may now leave the corridor and carry on, as long as it gets back inside within
--- `tolerance` metres of travel. Points outside the corridor are traversed but never returned:
--- where the tracks genuinely separate they stay separate, which is the point. Only the reachable
--- near-span waypoints come back.
function ADFlyoverEditor:connectedWithin(seedId, allowed, tolerance)
    tolerance = tolerance or 0

    -- debt = how far this walk has travelled since it was last inside the corridor.
    local debt = { [seedId] = 0 }
    local found = { [seedId] = allowed[seedId] == true }
    local frontier = { seedId }
    local bridged = 0

    while #frontier > 0 do
        local nextFrontier = {}
        for _, id in ipairs(frontier) do
            local wp = ADGraphManager:getWayPointById(id)
            if wp ~= nil then
                for _, listName in ipairs(LINK_LISTS) do
                    for _, other in pairs(linkList(wp, listName) or {}) do
                        local ow = ADGraphManager:getWayPointById(other)
                        if ow ~= nil then
                            local step = MathUtil.vector2Length(ow.x - wp.x, ow.z - wp.z)
                            local newDebt
                            if allowed[other] then
                                newDebt = 0
                            else
                                newDebt = debt[id] + step
                            end

                            if newDebt <= tolerance and (debt[other] == nil or newDebt < debt[other]) then
                                if debt[other] == nil and not allowed[other] then
                                    bridged = bridged + 1
                                end
                                debt[other] = newDebt
                                if allowed[other] then
                                    found[other] = true
                                end
                                table.insert(nextFrontier, other)
                            end
                        end
                    end
                end
            end
        end
        frontier = nextFrontier
    end

    return found, bridged
end

--- Move the span onto the centre line, pull the other track's connections onto it, make the merged
--- stretch two-way, and delete what was absorbed.
function ADFlyoverEditor:absorbTrack(span, aInside, aTarget, bInside, inB)
    -- Reposition first, so "nearest surviving waypoint" below is measured against where the merged
    -- lane actually ends up rather than where it used to be.
    for _, idA in ipairs(aInside) do
        local a = ADGraphManager:getWayPointById(idA)
        local target = aTarget[idA]
        if a ~= nil and target ~= nil then
            local oldY = a.y
            a.x, a.z = target.x, target.z
            -- The same height rule as Move and Draw, following "snap to": terrain drops it on the ground,
            -- surface keeps it on a bridge or ramp deck it was already on.
            a.y = self:resolveHeightAt(a.x, a.z, oldY)
        end
    end

    local function nearestSurviving(x, z)
        local bestId, bestSq = nil, math.huge
        for _, idA in ipairs(aInside) do
            local a = ADGraphManager:getWayPointById(idA)
            if a ~= nil then
                local dx, dz = a.x - x, a.z - z
                local d = dx * dx + dz * dz
                if d < bestSq then
                    bestId, bestSq = idA, d
                end
            end
        end
        return bestId
    end

    local function addLink(fromId, toId)
        if fromId == nil or toId == nil or fromId == toId then
            return
        end
        local from = ADGraphManager:getWayPointById(fromId)
        local to = ADGraphManager:getWayPointById(toId)
        if from == nil or to == nil then
            return
        end
        if not table.contains(from.out, toId) then
            table.insert(from.out, toId)
        end
        if not table.contains(to.incoming, fromId) then
            table.insert(to.incoming, fromId)
        end
    end

    -- Anything outside the absorbed stretch that pointed into it has to be re-attached, or the
    -- routes either side of the merge are severed. Direction is preserved on both sides.
    for _, idB in ipairs(bInside) do
        local b = ADGraphManager:getWayPointById(idB)
        if b ~= nil then
            local anchor = nearestSurviving(b.x, b.z)
            for _, other in pairs(b.out or {}) do
                if not inB[other] then
                    addLink(anchor, other)
                end
            end
            for _, other in pairs(b.incoming or {}) do
                if not inB[other] then
                    addLink(other, anchor)
                end
            end
        end
    end

    -- The absorbed track carried the opposite direction of travel. Deleting it would leave the
    -- merged stretch one-way, which is the whole thing this tool exists to fix, so the reverse
    -- links are added explicitly along the span.
    local insideSet = {}
    for _, idA in ipairs(aInside) do
        insideSet[idA] = true
    end
    for i = 1, #span - 1 do
        local a, b = span[i], span[i + 1]
        if insideSet[a] and insideSet[b] then
            addLink(a, b)
            addLink(b, a)
        end
    end

    -- Strip every reference to the doomed waypoints before deleting any of them, then delete
    -- highest id first: removal renumbers everything above it.
    local wayPoints = ADGraphManager:getWayPoints()
    for i = 1, #wayPoints do
        local wp = wayPoints[i]
        for _, listName in ipairs({ "out", "incoming" }) do
            local cleaned = {}
            for _, id in pairs(wp[listName] or {}) do
                if not inB[id] and id ~= wp.id and not table.contains(cleaned, id) then
                    table.insert(cleaned, id)
                end
            end
            wp[listName] = cleaned
        end
    end

    local doomed = {}
    for _, id in ipairs(bInside) do
        table.insert(doomed, id)
    end
    table.sort(doomed, function(x, y) return x > y end)
    for _, id in ipairs(doomed) do
        ADGraphManager:removeWayPoint(id, false)
    end

    self:invalidateIdReferences()
    ADGraphManager:markChanges()
end

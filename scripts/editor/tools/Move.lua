-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua
-- loads it after FlyoverEditor.lua, in the old file's order.
-- MODSPLIT: HELPERS FROM THE FILES LOADED BEFORE THIS ONE (tools/modsplit/split.py writes this block)
for _, name in ipairs({ "LINK_LISTS", "disconnectExternal", "isJunction", "linkList" }) do
    if ADFlyoverEditor.shared == nil or ADFlyoverEditor.shared[name] == nil then
        Logging.error("[FlyoverEditor]: Move.lua needs %s, which no file loaded before it shares", name)
    end
end
local LINK_LISTS = ADFlyoverEditor.shared.LINK_LISTS
local disconnectExternal = ADFlyoverEditor.shared.disconnectExternal
local isJunction = ADFlyoverEditor.shared.isJunction
local linkList = ADFlyoverEditor.shared.linkList
-- MODSPLIT: end of the helpers

-- ---------------------------------------------------------------------------------------------
-- Move, with distance-weighted falloff on the neighbours.
-- ---------------------------------------------------------------------------------------------

--- How far each waypoint is from the seed ALONG THE TRACK, out to maxDistance.
---
--- Distance along the track, not straight-line distance. Where a track loops back past itself, the
--- other limb can be a metre away in space while being a hundred metres away along the route -
--- a straight-line falloff drags it along with the grabbed point and tears the loop apart. Walking
--- the connections makes that impossible: the far limb is only reached by travelling the whole way
--- round, so it falls outside the radius on its own.
---
--- The walk includes a junction (as a distance reference - see gatherDragNeighbours, which drops it
--- from the actual follower list) but never continues PAST one: past a junction the points belong
--- to another route, and dragging those is never what moving this one means.
function ADFlyoverEditor:collectAlongTrack(seedId, maxDistance)
    local distance = { [seedId] = 0 }
    local frontier = { seedId }

    while #frontier > 0 do
        local nextFrontier = {}
        for _, id in ipairs(frontier) do
            local wp = ADGraphManager:getWayPointById(id)
            if wp ~= nil then
                local neighbours = {}
                for _, listName in ipairs(LINK_LISTS) do
                    for _, other in pairs(linkList(wp, listName) or {}) do
                        if other ~= id and not table.contains(neighbours, other) then
                            table.insert(neighbours, other)
                        end
                    end
                end

                if #neighbours <= 2 or id == seedId then
                    for _, other in ipairs(neighbours) do
                        local ow = ADGraphManager:getWayPointById(other)
                        if ow ~= nil then
                            local step = MathUtil.vector2Length(ow.x - wp.x, ow.z - wp.z)
                            local d = distance[id] + step
                            -- Keep the shortest route to each point, so a track that closes into a
                            -- loop is measured the short way round rather than by whichever
                            -- direction happened to arrive first.
                            if d <= maxDistance and (distance[other] == nil or d < distance[other]) then
                                distance[other] = d
                                table.insert(nextFrontier, other)
                            end
                        end
                    end
                end
            end
        end
        frontier = nextFrontier
    end

    return distance
end

function ADFlyoverEditor:beginDrag(id)
    local wp = ADGraphManager:getWayPointById(id)
    if wp == nil then
        return
    end

    -- A new drag supersedes any pending retroactive-copy chance from the previous one - moveCopyOn
    -- itself is left alone, since toggling it on BEFORE this drag (then dragging) is exactly how
    -- copy is meant to apply to a fresh move.
    self.lastMoveRecord = nil

    ADEditorHistory:snapshot("move waypoint")

    self.dragId = id
    self.dragStartX, self.dragStartZ = wp.x, wp.z

    -- Precompute which neighbours move and by how much. Same raised-cosine weighting the field
    -- loop generator uses for tree detours: weight 1 at the grabbed point falling smoothly to 0 at
    -- the falloff distance, with zero gradient at both ends, so the run stays smooth instead of
    -- developing a kink where the influence stops.
    self:gatherDragNeighbours()

    -- Copy already on when the grab starts (reported 2026-09-21): the original should never
    -- visibly move at all in that case - you are dragging a fresh copy OUT of it from the first
    -- frame, not moving the real thing and having it snap back later. Same freeze
    -- toggleMoveCopy uses when copy comes on mid-drag instead - see updateDrag/finishDrag.
    self.dragFrozenCopy = self.moveCopyOn
    if self.moveOffsetChainIds ~= nil then
        self.moveOffsetFrozen = self.moveCopyOn and true or false
    end

    -- Rotate pivot, fixed for the whole drag (see the state table comment for why it has to be
    -- the START position, not tracked live).
    self.moveRotateAngle = 0
    if self.moveRotatePivotMode == "centroid" then
        local sumX, sumZ, n = self.dragStartX, self.dragStartZ, 1
        for _, nb in ipairs(self.dragNeighbours or {}) do
            sumX, sumZ, n = sumX + nb.x, sumZ + nb.z, n + 1
        end
        self.moveRotatePivotX, self.moveRotatePivotZ = sumX / n, sumZ / n
    else
        self.moveRotatePivotX, self.moveRotatePivotZ = self.dragStartX, self.dragStartZ
    end

    local mode = (self.selectionCount > 0 and self.selection[id]) and "selection"
        or self.MOVE_SELECT_NAMES[self.moveSelectMode]
    if self.moveOffsetChainIds ~= nil then
        -- An offset carries its chain separately from dragNeighbours; report that, not "0 following".
        ADFlyoverSettings.debugLog("[FlyoverEditor]: grabbed waypoint id=%s to OFFSET a chain of %d waypoint(s) (copy %s, disconnect %s).",
            tostring(id), #self.moveOffsetChainIds, self.moveCopyOn and "on" or "off", self.moveBreakOn and "on" or "off")
    else
        ADFlyoverSettings.debugLog("[FlyoverEditor]: grabbed waypoint id=%s (%s, %d waypoint(s) following).",
            tostring(id), mode, #self.dragNeighbours)
    end
end

--- Work out which waypoints follow the grab, and how strongly.
---
--- Records each follower's CURRENT position, which the drag then offsets from. It therefore has to
--- be called with everything sitting where it started - see refreshActiveDrag, which restores
--- before re-gathering, or the recorded origins would be positions the drag had already moved.
---
--- Three sources, checked in order:
---   1. A pre-built selection (self.selection - ctrl-click, box, later circle/freehand) wins, but
---      only when the grabbed point is actually IN it - grabbing some unrelated point elsewhere
---      moves just that point instead of hijacking the click with a stale leftover selection.
---      Always rigid: there is no single along-track "centre" a scattered set could taper from.
---   2. Run mode carries the whole run the grab belongs to. Falloff (on: taper to the run's own
---      two ends: off: rigid) - never a fixed radius, because the run's own ends already are the
---      natural falloff-to-zero points.
---   3. Point mode (the default): today's along-track falloff from a single grab, unchanged.
function ADFlyoverEditor:gatherDragNeighbours()
    self.dragNeighbours = {}
    if self.dragId == nil then
        return
    end

    if self.selectionCount > 0 and self.selection[self.dragId] then
        -- A selection that happens to be one connected run IS a span: with falloff on, it tapers to its own
        -- two ends exactly like a picked span, instead of always moving rigidly.
        local chain = self:selectionChain()
        if chain ~= nil and #chain >= 3 and self.moveFalloffOn then
            local set = {}
            for _, id in ipairs(chain) do set[id] = true end
            -- The falloff value is the reach along the selection from the grabbed point (0 = taper to its ends).
            self:gatherChainFollowers(chain[1], chain[#chain], set, false, nil)
            return
        end
        for id in pairs(self.selection) do
            if id ~= self.dragId then
                local wp = ADGraphManager:getWayPointById(id)
                if wp ~= nil then
                    table.insert(self.dragNeighbours, { id = id, x = wp.x, z = wp.z, weight = 1 })
                end
            end
        end
        return
    end

    if self.moveSelectMode == self.MOVE_SELECT.RUN then
        local fromId, toId, ids = self:resolveWholeRun(self.dragId)
        if fromId == nil then
            Logging.warning("[FlyoverEditor]: no clear run through id=%s to move as a run - it is "
                .. "a junction, or the run closes on itself.", tostring(self.dragId))
            return
        end
        -- resolveWholeRun's third return is an ORDERED ARRAY (#ids, ipairs - see
        -- claimWholeRunClick/self.spanIds, which rely on exactly that shape for Smooth/Divide/
        -- Ground/Straighten/Offset), not a membership set. gatherChainFollowers/gatherOffsetChain/
        -- orderRunDistances all need id-keyed membership (run[other]) - converted here, at THIS
        -- call site, the same way Span already converts runPathBetween's own array into
        -- moveSpanIds, rather than changing resolveWholeRun's established contract.
        local run = {}
        for _, id in ipairs(ids) do
            run[id] = true
        end

        -- excludeJunctionEnds = true: resolveWholeRun deliberately extends a run's own ends onto
        -- whatever junction sits beyond them (reachToJunction), which is incidental to picking
        -- Run - you clicked a point mid-run, not the junction - unlike Span, where the two ends
        -- are exactly whatever the user directly clicked.
        if self.moveOffsetOn then
            self:gatherOffsetChain(fromId, toId, run, true)
            return
        end
        self:gatherChainFollowers(fromId, toId, run, true, self:moveReach())
        return
    end

    if self.moveSelectMode == self.MOVE_SELECT.SPAN then
        if self.moveSpanIds == nil or not self.moveSpanIds[self.dragId] then
            return
        end
        -- excludeJunctionEnds = false: a span's ends are exactly what the user clicked - if that
        -- happens to be a junction, it was explicit, the same as clicking one directly in Point.
        if self.moveOffsetOn then
            self:gatherOffsetChain(self.moveSpanFromId, self.moveSpanToId, self.moveSpanIds, false)
            return
        end
        self:gatherChainFollowers(self.moveSpanFromId, self.moveSpanToId, self.moveSpanIds, false, self:moveReach())
        return
    end

    local radius = self.moveFalloffOn and self.falloffRadius or 0
    if radius <= 0 then
        return
    end

    -- A junction the radius happens to reach is a distance REFERENCE (collectAlongTrack keeps it
    -- in the map so the walk stops there correctly), not a follower - incidental reach was never
    -- an explicit pick, same reasoning as Run/Span's excludeJunctionEnds (see isJunction).
    local alongTrack = self:collectAlongTrack(self.dragId, radius)
    for otherId, d in pairs(alongTrack) do
        if otherId ~= self.dragId and not isJunction(otherId) then
            local other = ADGraphManager:getWayPointById(otherId)
            if other ~= nil then
                table.insert(self.dragNeighbours, {
                    id = otherId,
                    x = other.x,
                    z = other.z,
                    weight = 0.5 * (1 + math.cos(math.pi * d / radius))
                })
            end
        end
    end
end

--- Order a simple run (resolveWholeRun guarantees at most 2 in-run connections per member, so it
--- is a plain chain, not a branching graph) from `fromId` outward, giving each member's distance
--- travelled to get there, AND the walk order itself (offset's gatherOffsetChain needs the order,
--- falloff's gatherChainFollowers only ever needed the distances). Walked fresh rather than
--- trusting `run`'s pairs() order, which is address order and has nothing to do with the run's
--- actual shape - see node-keyed-pairs-is-nondeterministic in project memory.
function ADFlyoverEditor:orderRunDistances(run, fromId)
    local dist = { [fromId] = 0 }
    local orderedIds = { fromId }
    local prevId, currentId = nil, fromId
    while true do
        local wp = ADGraphManager:getWayPointById(currentId)
        if wp == nil then break end
        local nextId = nil
        for _, listName in ipairs(LINK_LISTS) do
            for _, other in pairs(linkList(wp, listName) or {}) do
                if run[other] and other ~= prevId and other ~= currentId then
                    nextId = other
                end
            end
        end
        if nextId == nil then break end
        local nwp = ADGraphManager:getWayPointById(nextId)
        if nwp == nil then break end
        dist[nextId] = dist[currentId] + MathUtil.vector2Length(nwp.x - wp.x, nwp.z - wp.z)
        table.insert(orderedIds, nextId)
        prevId, currentId = currentId, nextId
    end
    return dist, orderedIds
end

--- Run and Span's shared followers: every other member of a simple chain (a whole run, or a picked
--- span) the grab belongs to, from one end (fromId) to the other (toId).
---
--- With falloff off, every member moves exactly as far as the grab - the whole chain as one rigid
--- piece. With falloff on, each member tapers to 0 at whichever of the chain's own two ends it sits
--- towards, using ITS side's own distance to that end as the falloff reach - not a shared radius,
--- since a run's ends are structural and a span's ends are what the user just picked, either way
--- not a separate distance to dial in on top.
--- Offset's own chain setup, in place of gatherChainFollowers - it does not use the weighted
--- follower/dragNeighbours mechanism at all (dragNeighbours is left empty; updateDrag special-cases
--- offset before it ever reaches the normal per-follower loop). Captures the ORDERED chain, ids and
--- points both in walk order, ONCE at grab time - this is moveOffsetBase, and it stays fixed for
--- the whole adjust session (drag AND the wheel/typed-entry phase after release) so repeated
--- offsetOpenChain calls all measure from the same original shape rather than compounding onto
--- whatever the previous adjustment already produced.
---
--- moveOffsetMovable flags which chain positions are actually allowed to move (excludes a genuine
--- junction at either end - see isJunction) - kept the SAME LENGTH/ORDER as moveOffsetBase/
--- moveOffsetChainIds rather than dropped from them, because offsetOpenChain still needs the
--- junction's real position to compute the curve's end geometry correctly; only the WRITE-BACK in
--- applyMoveOffset skips it (Run's own case; Span's explicitly-clicked ends are never junction-
--- extended here in the first place, so this never excludes anything a user directly picked).
function ADFlyoverEditor:gatherOffsetChain(fromId, toId, run, excludeJunctionEnds)
    local _, orderedIds = self:orderRunDistances(run, fromId)
    if orderedIds[#orderedIds] ~= toId then
        Logging.warning("[FlyoverEditor]: could not walk the chain from id=%s to id=%s to offset it.",
            tostring(fromId), tostring(toId))
        return
    end

    local points = {}
    local movable = {}
    for _, id in ipairs(orderedIds) do
        local wp = ADGraphManager:getWayPointById(id)
        if wp == nil then
            return
        end
        table.insert(points, { x = wp.x, y = wp.y, z = wp.z })
        movable[id] = not (excludeJunctionEnds and isJunction(id))
    end

    self.moveOffsetChainIds = orderedIds
    self.moveOffsetBase = points
    self.moveOffsetMovable = movable
    self.moveOffsetDistance = 0
end

--- Signed perpendicular distance from the cursor to the chain's nearest segment - same nearest-
--- segment-then-cross-product shape as offsetSideFromCursor (PARALLEL's own side picker), but
--- returning the actual magnitude too, not just the sign, since offset here is cursor-DRIVEN
--- (dynamic slide) rather than a typed magnitude with only its side read from the cursor.
local function offsetDistanceFromCursor(cx, cz, pts)
    if cx == nil or cz == nil or pts == nil or #pts < 2 then
        return nil
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
    return cross >= 0 and bestDistance or -bestDistance
end

--- Re-slide the chain from its fixed base to the current moveOffsetDistance. The one place both
--- the live cursor-drag and the wheel/typed-entry phase end up writing through - offsetOpenChain
--- takes the base and a signed distance and returns one point per input point, in the same order,
--- which is what keeps this an in-place SLIDE (existing ids, existing connections) rather than
--- PARALLEL's own use of the same function to grow a brand new track.
function ADFlyoverEditor:applyMoveOffset()
    if self.moveOffsetChainIds == nil or self.moveOffsetBase == nil then
        return
    end

    local track, err = ADOffsetGeometry.offsetOpenChain(self.moveOffsetBase, self.moveOffsetDistance)
    if track == nil then
        Logging.warning("[FlyoverEditor]: could not offset - %s", tostring(err))
        return
    end

    -- Optional taper (item requested 2026-09-21): offsetOpenChain itself only knows how to slide
    -- everything the same signed distance - blending is done here instead, by mixing each point
    -- BACK toward its own pre-offset position the closer it sits to either end of the chain, same
    -- cosine shape Point/Run's own falloff already use. nil weights (falloff off) skips the blend
    -- entirely, so the plain rigid slide costs nothing extra.
    local weights = nil
    if self.moveOffsetFalloffOn and self.moveOffsetFalloffRadius > 0 then
        weights = {}
        local base = self.moveOffsetBase
        local n = #base
        local along = { 0 }
        for i = 2, n do
            local a, b = base[i - 1], base[i]
            along[i] = along[i - 1] + MathUtil.vector2Length(b.x - a.x, b.z - a.z)
        end
        local total = along[n]
        for i = 1, n do
            local distToNearEnd = math.min(along[i], total - along[i])
            if distToNearEnd >= self.moveOffsetFalloffRadius then
                weights[i] = 1
            else
                local t = distToNearEnd / self.moveOffsetFalloffRadius
                weights[i] = 0.5 * (1 - math.cos(math.pi * t))
            end
        end
    end

    -- Where each point of the chain goes. With copy on, the ORIGINAL chain stays put (frozen, the same
    -- rule as a plain move: copy on from the start = you slide a new copy out of it; copy turned on part
    -- way = the original drops straight back into place) and these positions are only drawn as a preview,
    -- then become the copy on commit.
    local targets = {}
    for i, id in ipairs(self.moveOffsetChainIds) do
        local p = track[i]
        if p ~= nil and (self.moveOffsetMovable == nil or self.moveOffsetMovable[id]) then
            local tx, tz = p.x, p.z
            if weights ~= nil then
                local base = self.moveOffsetBase[i]
                local w = weights[i]
                tx, tz = base.x + (p.x - base.x) * w, base.z + (p.z - base.z) * w
            end
            targets[i] = { x = tx, z = tz }
            if not self.moveOffsetFrozen then
                self:moveTo(id, tx, tz)
            end
        end
    end
    self.moveOffsetTargets = targets
end

--- Copy turned on or off while an offset is live (during the drag or while it waits for its right-click):
--- on puts the original chain straight back where it started and leaves only the preview moving; off
--- lets the original follow the offset again.
function ADFlyoverEditor:setMoveOffsetFrozen(frozen)
    if self.moveOffsetChainIds == nil then
        return
    end
    self.moveOffsetFrozen = frozen and true or false
    if self.moveOffsetFrozen then
        for i, id in ipairs(self.moveOffsetChainIds) do
            local base = self.moveOffsetBase ~= nil and self.moveOffsetBase[i] or nil
            if base ~= nil and (self.moveOffsetMovable == nil or self.moveOffsetMovable[id]) then
                self:moveTo(id, base.x, base.z)
            end
        end
    end
    self:applyMoveOffset()
end

--- Set the offset distance directly - the wheel/typed-entry path, usable both mid-drag (where it
--- is immediately overwritten by the next frame's cursor-driven update - the user's own call: drag
--- drives it live, wheel only takes over once the button is up) and after release, while the chain
--- is still awaiting its right-click commit.
function ADFlyoverEditor:setMoveOffsetDistance(value)
    if self.moveOffsetChainIds == nil then
        return
    end
    self.moveOffsetDistance = math.max(-AutoDrive.FLYOVER_OFFSET_MAX, math.min(AutoDrive.FLYOVER_OFFSET_MAX, value))
    self:applyMoveOffset()
end

--- Right-click commit for a pending offset (dragId already nil - see onLeftRelease/stopCurrentAction).
--- Re-grounds the chain at its final positions with the accurate raycast, same reasoning finishDrag
--- already gives for every other move: the last live-preview frame is not necessarily where the
--- distance was actually left.
function ADFlyoverEditor:commitMoveOffset()
    local moved = 0
    for _, id in ipairs(self.moveOffsetChainIds or {}) do
        if self.moveOffsetMovable == nil or self.moveOffsetMovable[id] then
            local wp = ADGraphManager:getWayPointById(id)
            if wp ~= nil then
                self:regroundTo(id, wp.x, wp.z, wp.y)
                moved = moved + 1
            end
        end
    end
    ADFlyoverSettings.debugLog("[FlyoverEditor]: offset %.1fm applied to %d waypoint(s).",
        self.moveOffsetDistance, moved)

    -- Copy and disconnect apply to an offset exactly as to a plain move. This used to stop here, so an
    -- offset with copy on just slid the original and never left a copy behind. Same record shape as
    -- finishDrag: each moved point with where it started.
    local members = {}
    local frozen = self.moveOffsetFrozen
    for i, id in ipairs(self.moveOffsetChainIds or {}) do
        local base = self.moveOffsetBase ~= nil and self.moveOffsetBase[i] or nil
        if base ~= nil and (self.moveOffsetMovable == nil or self.moveOffsetMovable[id]) then
            local m = { id = id, originalX = base.x, originalZ = base.z }
            -- Frozen: the original never moved, so where the copy goes comes from the preview.
            local t = frozen and self.moveOffsetTargets ~= nil and self.moveOffsetTargets[i] or nil
            if t ~= nil then
                m.finalX, m.finalZ = t.x, t.z
            end
            members[#members + 1] = m
        end
    end
    self.moveOffsetChainIds, self.moveOffsetBase, self.moveOffsetMovable, self.moveOffsetDistance = nil, nil, nil, 0
    self.moveOffsetFrozen, self.moveOffsetTargets = false, nil

    if #members > 0 then
        if self.moveCopyOn then
            self:applyMoveAsCopy({ members = members })
            self.moveCopyOn = false
            self.moveBreakOn = false
            self.lastMoveRecord = nil
        else
            self.lastMoveRecord = { members = members }
            if self.moveBreakOn then
                local movedSet = {}
                for _, m in ipairs(members) do movedSet[m.id] = true end
                disconnectExternal(movedSet)
                ADFlyoverSettings.debugLog("[FlyoverEditor]: disconnected the %d offset waypoint(s) from their outside connections.",
                    #members)
            end
        end
    end
    ADGraphManager:markChanges()
end

--- Abandon a pending offset without committing - the waypoints stay wherever the last live
--- adjustment left them (this mirrors every other move: the position write already happened
--- frame-by-frame, same as a normal drag, not a separate preview overlay - see gatherOffsetChain).
--- Undo (Q, snapshotted at the original beginDrag) is what actually reverts the positions; this
--- just stops treating the chain as still adjustable.
function ADFlyoverEditor:cancelMoveOffset()
    self.moveOffsetChainIds, self.moveOffsetBase, self.moveOffsetMovable, self.moveOffsetDistance = nil, nil, nil, 0
    self.moveOffsetFrozen, self.moveOffsetTargets = false, nil
end

-- excludeJunctionEnds: true from Run (its ends are incidentally extended onto whatever junction
-- sits beyond them - see isJunction), false from Span (its ends are exactly what the user clicked,
-- explicit either way). dist[fromId]/dist[toId] stay valid taper REFERENCE points either way -
-- only membership in the moved set is filtered, not the distance math a taper measures against.
function ADFlyoverEditor:gatherChainFollowers(fromId, toId, run, excludeJunctionEnds, maxReach)
    if not self.moveFalloffOn then
        for id in pairs(run) do
            if id ~= self.dragId and not (excludeJunctionEnds and isJunction(id)) then
                local wp = ADGraphManager:getWayPointById(id)
                if wp ~= nil then
                    table.insert(self.dragNeighbours, { id = id, x = wp.x, z = wp.z, weight = 1 })
                end
            end
        end
        return
    end

    local dist = self:orderRunDistances(run, fromId)
    local grabDist, total = dist[self.dragId], dist[toId]

    if grabDist == nil or total == nil then
        return
    end

    for id in pairs(run) do
        if id ~= self.dragId and not (excludeJunctionEnds and isJunction(id)) then
            local wp = ADGraphManager:getWayPointById(id)
            local d = dist[id]
            if wp ~= nil and d ~= nil then
                local side = d - grabDist
                local reach = side >= 0 and (total - grabDist) or grabDist
                -- A set reach (the falloff value, for a run-shaped selection) tapers sooner than the ends.
                if maxReach ~= nil and maxReach > 0 then
                    reach = math.min(reach, maxReach)
                end
                local weight = 1
                if reach > 1e-6 then
                    local t = math.min(math.abs(side) / reach, 1)
                    weight = 0.5 * (1 + math.cos(math.pi * t))
                elseif side ~= 0 then
                    weight = 0
                end
                table.insert(self.dragNeighbours, { id = id, x = wp.x, z = wp.z, weight = weight })
            end
        end
    end
end

--- Re-run the follower gather live, mid-drag, when the mode or falloff toggle changes underneath
--- an active grab. Cannot simply re-gather in place: the followers have already been displaced by
--- the drag so far, so their current positions are not the origins the new set should measure
--- from - everything is put back first (the grabbed point too, since a run/along-track distance is
--- measured through its position), then the new set is gathered and the drag re-applied.
function ADFlyoverEditor:refreshActiveDrag()
    if self.dragId == nil then
        return
    end

    for _, n in ipairs(self.dragNeighbours or {}) do
        self:moveTo(n.id, n.x, n.z)
    end
    if self.dragStartX ~= nil then
        self:moveTo(self.dragId, self.dragStartX, self.dragStartZ)
    end

    self:gatherDragNeighbours()
    self:updateDrag()
end

--- Change the falloff, live during a drag if one is in progress.
---
--- Mid-drag this cannot simply re-gather: the followers have already been displaced, so their
--- current positions are not the origins the new set should measure from, and re-gathering over the
--- top would compound the offsets every time the wheel moved. Everything is put back first - the
--- grabbed point included, since the run's shape through it decides the along-track distances -
--- then the new set is gathered and the drag re-applied.
function ADFlyoverEditor:setFalloffRadius(value)
    value = math.max(0, math.min(AutoDrive.FLYOVER_FALLOFF_MAX, value))
    if value == self.falloffRadius then
        return
    end

    if self.dragId == nil then
        self.falloffRadius = value
        ADFlyoverSettings.debugLog("[FlyoverEditor]: falloff %.1fm along the track.", value)
        return
    end

    self.falloffRadius = value
    self:refreshActiveDrag()

    ADFlyoverSettings.debugLog("[FlyoverEditor]: falloff %.1fm along the track, %d waypoint(s) following.",
        value, #self.dragNeighbours)
end

function ADFlyoverEditor:updateDrag()
    if self.cursorX == nil or self.dragStartX == nil then
        return
    end

    -- Offset: the cursor drives the signed distance directly (dynamic slide), not a delta applied
    -- to a per-follower weight - see gatherOffsetChain/applyMoveOffset. Only while still actively
    -- held; once released the wheel/typed-entry phase takes over (setMoveOffsetDistance), and this
    -- function stops being called at all until the next grab.
    if self.moveOffsetChainIds ~= nil then
        local d = offsetDistanceFromCursor(self.cursorX, self.cursorZ, self.moveOffsetBase)
        if d ~= nil then
            self.moveOffsetDistance = math.max(-AutoDrive.FLYOVER_OFFSET_MAX,
                math.min(AutoDrive.FLYOVER_OFFSET_MAX, d))
            self:applyMoveOffset()
        end
        return
    end

    -- Frozen copy (copy was on before or during this drag - see beginDrag/toggleMoveCopy): the
    -- real waypoint(s) stay exactly where they started, full stop. finishDrag still computes
    -- where the clone belongs from dragStartX/Z and the cursor directly, so nothing here needs to
    -- track that separately - it just has nothing left to do each frame.
    if self.dragFrozenCopy then
        return
    end

    local deltaX = self.cursorX - self.dragStartX
    local deltaZ = self.cursorZ - self.dragStartZ

    -- The grabbed point goes where the cursor is pointing, height included - that is what puts it
    -- on a ramp rather than on the ground below it. Followers keep to whatever surface they are
    -- already on.
    self:moveTo(self.dragId, self.cursorX, self.cursorZ, nil, self.cursorY)

    -- Rotate (R+wheel - see applyWheelToActiveTool) composes with the translate above: each
    -- follower's ORIGINAL offset from the fixed pivot is rotated by the accumulated angle first,
    -- THEN the drag's delta is added on top - so the whole rotated shape rides along with the
    -- drag exactly the way the plain (unrotated) shape already does. moveRotateAngle stays 0
    -- unless R+wheel was actually used this drag, so cos=1/sin=0 makes this an identity transform
    -- (no different from the old plain add) whenever rotation is not in play.
    local cosA, sinA = math.cos(self.moveRotateAngle), math.sin(self.moveRotateAngle)
    local pivotX, pivotZ = self.moveRotatePivotX or self.dragStartX, self.moveRotatePivotZ or self.dragStartZ
    for _, n in ipairs(self.dragNeighbours or {}) do
        local ox, oz = n.x - pivotX, n.z - pivotZ
        local rx = pivotX + ox * cosA - oz * sinA
        local rz = pivotZ + ox * sinA + oz * cosA
        self:moveTo(n.id, rx + deltaX * n.weight, rz + deltaZ * n.weight)
    end
end

--- Move one waypoint in the horizontal plane, re-resolving its height from the terrain. Heights
--- must be re-resolved rather than carried along: a point dragged across a slope would otherwise
--- keep the elevation it had where the drag started and end up buried or floating.
--- Height at x,z interpolated along an existing chain of points.
---
--- Resampling a span has to take its heights from the span it came from, not from one end of it.
--- Every preview passed the FIRST point's height as the reference to
--- AutoDrive:getTerrainHeightAtWorldPos, whose ray starts at reference+3 and reaches only 5m down -
--- so anywhere on a slope the far end sat outside that window, the ray found nothing, and the
--- function handed back its own start height. The result was a row of preview dots all at the
--- elevation of the point the span started from.
---
--- Interpolating along the original chain is also what keeps a span that runs onto a ramp or a
--- bridge at the right height, since those points already carry it.
local function heightAlongChain(pts, x, z)
    local bestDistSq, bestY = math.huge, nil

    for i = 1, #pts - 1 do
        local a, b = pts[i], pts[i + 1]
        local dx, dz = b.x - a.x, b.z - a.z
        local lenSq = dx * dx + dz * dz

        local t = 0
        if lenSq > 1e-9 then
            t = ((x - a.x) * dx + (z - a.z) * dz) / lenSq
            t = math.max(0, math.min(1, t))
        end

        local cx, cz = a.x + dx * t, a.z + dz * t
        local ex, ez = x - cx, z - cz
        local distSq = ex * ex + ez * ez

        if distSq < bestDistSq then
            bestDistSq = distSq
            bestY = (a.y or 0) + ((b.y or a.y or 0) - (a.y or 0)) * t
        end
    end

    return bestY or (pts[1] ~= nil and pts[1].y or nil)
end

--- Height for a waypoint at x,z.
---
--- Measured in game on a building ramp:
---     cursor reports 121.13   plain terrain 120.37
---     ray from cursor 120.37  ray from 30m up 150.37
---
--- Three things follow. The CURSOR can see the ramp - it reads a metre above the terrain there,
--- and exactly terrain height on open ground. AutoDrive:getTerrainHeightAtWorldPos CANNOT: its
--- raycast uses CollisionFlag.DEFAULT + ROAD + TERRAIN, which does not pick up the building, so it
--- returned the terrain even when told to start from the cursor's height. And starting the ray
--- higher is useless because it only casts 5m - from 30m up it hit nothing and handed back its own
--- start height.
---
--- So the cursor's height is used directly rather than being fed to a raycast that discards it.
--- `explicitY` is that value, passed for the point being placed or dragged, which is the only one
--- actually under the cursor.
---
--- For everything else - the followers in a proportional move - there is no cursor reading. A point
--- already sitting well above the terrain is on a structure the raycast cannot see, so re-grounding
--- it would drop it through the ramp it is standing on; those keep the height they have. Points at
--- terrain level are re-grounded normally.
function ADFlyoverEditor:resolveHeightAt(x, z, referenceY, explicitY)
    local terrainY = nil
    if g_currentMission ~= nil and g_currentMission.terrainRootNode ~= nil then
        terrainY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 1, z)
    end

    if self.snapToTerrain then
        return terrainY or AutoDrive:getTerrainHeightAtWorldPos(x, z)
    end

    if explicitY ~= nil then
        return explicitY
    end

    if referenceY ~= nil and terrainY ~= nil
        and (referenceY - terrainY) > AutoDrive.FLYOVER_STRUCTURE_HEIGHT then
        -- On a structure. Nothing available here can see it, so leave the height alone.
        return referenceY
    end

    return AutoDrive:getTerrainHeightAtWorldPos(x, z, referenceY)
end

--- Re-ground a moved point using the ground tool's surface resolver rather than the cursor's raw
--- pick. The top-down cursor sees foliage - it lands a point in a tree canopy metres off the ground -
--- while groundTargetAt uses the DEFAULT+ROAD+TERRAIN mask, so it takes the nearest REAL surface to
--- the reference height: the ground under an overhang, or a ramp/bridge the point genuinely sits on.
--- spanLineOnly = true keeps it off the ground tool's "top surface" toggle; snap-to-terrain still
--- wins inside groundTargetAt.
function ADFlyoverEditor:regroundTo(id, x, z, ref)
    local wp = ADGraphManager:getWayPointById(id)
    if wp == nil then
        return
    end
    local r = ref or wp.y
    local y = self:groundTargetAt(x, r, z, r, true) or wp.y
    ADGraphManager:moveWayPoint(id, x, y, z, wp.flags, false)
end

--- Move one waypoint in the horizontal plane and put it back on the surface.
---
--- `referenceY` says which surface: the cursor's own pick height for the waypoint being dragged,
--- and each follower's current height for the rest, so a run partly on a ramp stays on the ramp
--- instead of half of it falling to the ground.
function ADFlyoverEditor:moveTo(id, x, z, referenceY, explicitY)
    local wp = ADGraphManager:getWayPointById(id)
    if wp == nil then
        return
    end
    local y = self:resolveHeightAt(x, z, referenceY or wp.y, explicitY)
    ADGraphManager:moveWayPoint(id, x, y, z, wp.flags, false)
end

function ADFlyoverEditor:finishDrag()
    if self.dragId == nil then
        return
    end
    -- Remember what was just carried, so the tool card can step clear of where it LANDED. The drag
    -- state is cleared below, and until now nothing recorded the dropped points at all.
    local moved = { self.dragId }
    for _, n in ipairs(self.dragNeighbours or {}) do
        if #moved < 400 then moved[#moved + 1] = n.id end
    end
    self.lastMovedIds = moved
    self.moveDropCount = (self.moveDropCount or 0) + 1

    -- Offset: releasing the mouse does NOT commit here - see gatherOffsetChain/commitMoveOffset.
    -- Only the "actively held, cursor is driving the distance" bookkeeping ends; the chain itself
    -- stays live for the wheel/typed-entry phase until a right-click commits it
    -- (stopCurrentAction).
    if self.moveOffsetChainIds ~= nil then
        self.dragId, self.dragStartX, self.dragStartZ, self.dragNeighbours, self.dragFrozenCopy = nil, nil, nil, nil, false
        return
    end

    -- Built BEFORE anything below moves further, from the pre-drag positions already tracked
    -- (dragStartX/Z for the grab, each follower's own recorded origin) - independent of whether
    -- copy is actually used this time, so a PLAIN move can still be turned into a copy afterward
    -- (see toggleMoveCopy).
    --
    -- finalX/finalZ, only when frozen (dragFrozenCopy): the real waypoint never moved this drag
    -- (updateDrag skipped it - see there), so its own x/z cannot say where the drag would have
    -- ended. Computed here with the exact same formula updateDrag would have applied every frame,
    -- so it matches what a non-frozen drag's actual final position already is. Left nil otherwise
    -- - the non-frozen path already has the true, re-grounded final position on the real waypoint
    -- by the time applyMoveAsCopy reads it below, which is more accurate than recomputing it.
    local members
    if self.dragFrozenCopy then
        local deltaX, deltaZ = self.cursorX - self.dragStartX, self.cursorZ - self.dragStartZ
        members = { { id = self.dragId, originalX = self.dragStartX, originalZ = self.dragStartZ,
            finalX = self.cursorX, finalZ = self.cursorZ } }
        for _, n in ipairs(self.dragNeighbours or {}) do
            table.insert(members, { id = n.id, originalX = n.x, originalZ = n.z,
                finalX = n.x + deltaX * n.weight, finalZ = n.z + deltaZ * n.weight })
        end
    else
        members = { { id = self.dragId, originalX = self.dragStartX, originalZ = self.dragStartZ } }
        for _, n in ipairs(self.dragNeighbours or {}) do
            table.insert(members, { id = n.id, originalX = n.x, originalZ = n.z })
        end
    end

    -- Re-ground everything that moved, at its final position and with the accurate raycast. During
    -- the drag the height only has to look right while the point is in flight; where it comes to
    -- rest is what actually matters, and the last frame of a drag is not necessarily where the
    -- button was released.
    local dropped = ADGraphManager:getWayPointById(self.dragId)
    if dropped ~= nil then
        -- Report every height source at the drop point. Whether the cursor can even see a ramp is
        -- the open question: GuiTopDownCursor may pick against the terrain only, in which case
        -- referencing it cannot help and the height has to come from somewhere else.
        local beforeY = dropped.y
        local terrainY = (g_currentMission ~= nil and g_currentMission.terrainRootNode ~= nil)
            and getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, dropped.x, 1, dropped.z) or nil
        local fromCursor = self.cursorY ~= nil
            and AutoDrive:getTerrainHeightAtWorldPos(dropped.x, dropped.z, self.cursorY) or nil
        local fromAbove = terrainY ~= nil
            and AutoDrive:getTerrainHeightAtWorldPos(dropped.x, dropped.z, terrainY + 30) or nil

        self:regroundTo(self.dragId, dropped.x, dropped.z, dropped.y)

        ADFlyoverSettings.debugLog("[FlyoverEditor]: heights at the drop point - cursor reports %s, plain terrain %s, ray from cursor %s, ray from 30m up %s, was %.2f, set to %.2f.",
            self.cursorY ~= nil and string.format("%.2f", self.cursorY) or "nil",
            terrainY ~= nil and string.format("%.2f", terrainY) or "nil",
            fromCursor ~= nil and string.format("%.2f", fromCursor) or "nil",
            fromAbove ~= nil and string.format("%.2f", fromAbove) or "nil",
            beforeY, dropped.y)
    end
    for _, n in ipairs(self.dragNeighbours or {}) do
        local wp = ADGraphManager:getWayPointById(n.id)
        if wp ~= nil then
            self:regroundTo(n.id, wp.x, wp.z, wp.y)
        end
    end

    local moved = 1 + #(self.dragNeighbours or {})
    ADFlyoverSettings.debugLog("[FlyoverEditor]: moved %d waypoint(s) ending at id=%s, re-grounded at the drop point.",
        moved, tostring(self.dragId))
    self.dragId, self.dragStartX, self.dragStartZ, self.dragNeighbours, self.dragFrozenCopy = nil, nil, nil, nil, false

    -- Copy already toggled on before release: convert this move into a copy right now, and there
    -- is nothing left to retroactively convert later. Otherwise stash the record - a plain move,
    -- but one toggleMoveCopy can still turn into a copy afterward.
    if self.moveCopyOn then
        self:applyMoveAsCopy({ members = members })
        self.moveCopyOn = false
        self.moveBreakOn = false
        self.lastMoveRecord = nil
    else
        self.lastMoveRecord = { members = members }

        -- Standalone disconnect (copy off, break on): sever this moved set's OUTSIDE connections
        -- right here rather than via applyMoveAsCopy's clone-then-delete-original route, which only
        -- runs when copy is also on. No clone, no id churn - just moved and cut loose.
        if self.moveBreakOn then
            local movedSet = {}
            for _, m in ipairs(members) do
                movedSet[m.id] = true
            end
            disconnectExternal(movedSet)
            ADFlyoverSettings.debugLog("[FlyoverEditor]: disconnected %d waypoint(s) from their outside connections.",
                #members)
        end

        -- Only the plain-move path - applyMoveAsCopy runs its own auto-hookup on the CLONE's ids,
        -- not these originals (a copy's whole point is starting disconnected; hookup still applies
        -- to it, just against its own new ids, not the source's).
        local ids = {}
        for _, m in ipairs(members) do
            table.insert(ids, m.id)
        end
        self:autoHookupEndpoints(ids)
    end

    ADGraphManager:markChanges()
end

-- MODSPLIT: SHARED WITH THE FILES LOADED AFTER THIS ONE (tools/modsplit/split.py writes this block)
ADFlyoverEditor.shared.heightAlongChain = heightAlongChain
-- MODSPLIT: end of the shared block

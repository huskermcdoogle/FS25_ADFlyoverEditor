-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua
-- loads it after FlyoverEditor.lua, in the old file's order.
-- MODSPLIT: HELPERS FROM THE FILES LOADED BEFORE THIS ONE (tools/modsplit/split.py writes this block)
for _, name in ipairs({ "LINK_LISTS", "heightAlongChain", "linkList" }) do
    if ADFlyoverEditor.shared == nil or ADFlyoverEditor.shared[name] == nil then
        Logging.error("[FlyoverEditor]: Smooth.lua needs %s, which no file loaded before it shares", name)
    end
end
local LINK_LISTS = ADFlyoverEditor.shared.LINK_LISTS
local heightAlongChain = ADFlyoverEditor.shared.heightAlongChain
local linkList = ADFlyoverEditor.shared.linkList
-- MODSPLIT: end of the helpers

-- ---------------------------------------------------------------------------------------------
-- Smooth / normalise a span between two waypoints.
-- ---------------------------------------------------------------------------------------------

ADFlyoverEditor.SMOOTH_MODE = { RELAX = 1, REBUILD = 2 }
ADFlyoverEditor.SMOOTH_MODE_NAMES = { "relax (move points)", "rebuild (respace)" }
AutoDrive.FLYOVER_SMOOTH_MAX = 30
-- Rebuild respaces, so the number worth having on the wheel there is the spacing, not a strength.
AutoDrive.FLYOVER_SPACING_MIN = 1.0
AutoDrive.FLYOVER_SPACING_MAX = 25.0
AutoDrive.FLYOVER_SPACING_STEP = 0.5
-- How close a waypoint must be to a remembered position to be considered the same one. Anchors do
-- not move during a rebuild, so this only has to absorb floating point noise.
AutoDrive.FLYOVER_ANCHOR_TOLERANCE = 0.05
-- How long after the previous right-click before another one puts the tool away, in milliseconds.
-- Only has to separate a deliberate second press from an accidental double-click - a double-click
-- is typically under 250ms - so it wants to be as short as will do that. A second felt like the
-- tool was ignoring the press.
AutoDrive.FLYOVER_TOOL_EXIT_DELAY = 350

function ADFlyoverEditor:cycleSmoothMode()
    self.smoothMode = (self.smoothMode % #self.SMOOTH_MODE_NAMES) + 1
    self.smoothPreview = nil
    ADFlyoverSettings.debugLog("[FlyoverEditor]: smooth mode -> %s.", self.SMOOTH_MODE_NAMES[self.smoothMode])
end

function ADFlyoverEditor:smoothClick()
    self:spanPickClick({
        getFrom = function() return self.smoothFromId end,
        getTo = function() return self.smoothToId end,
        setEnds = function(a, b)
            self.smoothFromId, self.smoothToId = a, b
            self.smoothPreview, self.smoothPinned = nil, nil
        end,
        onSpan = function(a, b)
            ADFlyoverSettings.debugLog("[FlyoverEditor]: smoothing id=%s..id=%s in %s mode. Wheel sets %s, right-click applies.",
                tostring(a), tostring(b), self.SMOOTH_MODE_NAMES[self.smoothMode],
                self.smoothMode == self.SMOOTH_MODE.REBUILD and "max spacing" or "strength")
        end,
    })
end

function ADFlyoverEditor:cancelSmooth()
    self.spanIds = nil
    if self.smoothFromId ~= nil or self.smoothToId ~= nil then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: smooth cancelled.")
    end
    self.smoothFromId, self.smoothToId = nil, nil
    self.smoothPreview, self.smoothPinned, self.smoothBlockedBy = nil, nil, nil
end

--- Work out what the span would look like, without changing anything.
---
--- Relax mode MOVES the existing waypoints and never adds or removes any, which is what makes it
--- safe on a real network: no connection is broken and no map marker is lost, so nothing has to be
--- refused. Junctions inside the span are pinned - moving one would drag the routes that meet
--- there - and so are both ends unless asked otherwise.
---
--- Rebuild mode is the old behaviour: delete the interior and lay down a respaced chain. It is
--- more powerful and less safe, and it still has to refuse a span containing a junction or marker.
function ADFlyoverEditor:updateSmoothPreview()
    if self.smoothFromId == nil or self.smoothToId == nil then
        self.smoothPreview = nil
        return
    end

    -- runPathBetween, NOT ADGraphManager:pathFromTo. pathFromTo is AutoDrive's route finder: it
    -- respects one-way, can route the long way round, and its result need not even begin at the
    -- waypoint that was clicked. That is what produced the nonsense refusal "id=8506 connects to
    -- id=8505 outside the span" when 8505 was the span's own start point.
    local ids = self:spanBetween(self.smoothFromId, self.smoothToId)
    if ids == nil or #ids < 3 then
        self.smoothPreview = nil
        self.smoothBlockedBy = nil
        return
    end

    local pts = {}
    for i = 1, #ids do
        local wp = ADGraphManager:getWayPointById(ids[i])
        if wp == nil then
            self.smoothPreview = nil
            return
        end
        pts[i] = { x = wp.x, y = wp.y, z = wp.z }
    end

    if self.smoothMode == self.SMOOTH_MODE.RELAX then
        local inSpan = {}
        for _, id in ipairs(ids) do
            inSpan[id] = true
        end

        -- Pin anything that must not move: junctions, and the ends unless included.
        local pinned = {}
        for i = 2, #ids - 1 do
            local wp = ADGraphManager:getWayPointById(ids[i])
            if wp ~= nil then
                for _, listName in ipairs(LINK_LISTS) do
                    for _, other in pairs(linkList(wp, listName) or {}) do
                        if not inSpan[other] then
                            pinned[i] = true
                        end
                    end
                end
            end
        end

        self.smoothPinned = pinned
        self.smoothPreview = ADOffsetGeometry.relaxOpenChain(pts, self.smoothStrength, pinned)
        self.smoothPreviewIds = ids
    else
        -- Spacing comes from the wheel. The minimum tracks it rather than being fixed, so that
        -- asking for coarse spacing does not still leave dense points through the corners - the
        -- whole run gets coarser, which is what dialling it up is asking for.
        local maxSpacing = self.smoothSpacing
        local minSpacing = math.max(AutoDrive.FIELD_LOOP_ADAPTIVE_MIN_SPACING, maxSpacing * 0.25)

        local smoothed = ADOffsetGeometry.smoothOpenChain(pts, 2, AutoDrive.FIELD_LOOP_MAX_WAYPOINT_TURN_DEG, 180)
        local resampled = ADOffsetGeometry.resampleOpenChainByCurvature(smoothed,
            minSpacing, maxSpacing, AutoDrive.FIELD_LOOP_ADAPTIVE_TOLERANCE)
        -- relaxOpenChain, not smoothOpenChain, for the tidying pass. smoothOpenChain REFINES -
        -- it inserts a midpoint after every eligible point - which immediately halves the spacing
        -- that was just asked for. Requesting 15m produced 2.2m average for exactly that reason.
        -- relax tucks the points without adding any, so the requested spacing survives.
        local finalPts = ADOffsetGeometry.relaxOpenChain(resampled, 1, {})

        -- Give every point a height. smoothOpenChain and resampleOpenChainByCurvature are 2D and
        -- return {x, z} only, so without this the preview had no y at all and was drawn at ground
        -- zero - a hundred-odd metres under the terrain, i.e. invisible. Relax mode never showed
        -- the problem because relaxOpenChain carries y through.
        for i = 1, #finalPts do
            finalPts[i].y = self:resolveHeightAt(finalPts[i].x, finalPts[i].z,
                heightAlongChain(pts, finalPts[i].x, finalPts[i].z))
        end

        self.smoothPreview = finalPts
        self.smoothPreviewIds = ids
        self.smoothPinned = nil
    end

    -- Rebuild deletes and replaces the interior, so it cannot cross a junction or a marker. Work
    -- that out now, while previewing, so the panel can say why - rather than leaving right-click
    -- to do nothing visible and explain itself only in the log.
    -- Rebuild splits at junctions rather than refusing, so nothing blocks it any more.
    self.smoothBlockedBy = nil
end

--- What would stop a span being deleted and rebuilt, as a short reason, or nil if nothing does.
function ADFlyoverEditor:findSpanBlocker(ids)
    local inChain = {}
    for _, id in ipairs(ids) do
        inChain[id] = true
    end
    for i = 2, #ids - 1 do
        local id = ids[i]
        local wp = ADGraphManager:getWayPointById(id)
        if wp ~= nil then
            for _, listName in ipairs(LINK_LISTS) do
                for _, other in pairs(linkList(wp, listName) or {}) do
                    if not inChain[other] then
                        -- Name the other end too. "junction at id N" alone is not checkable
                        -- against what is on screen; the id it connects to is what makes it
                        -- possible to see whether the junction is real. Note that the span comes
                        -- from a SHORTEST path, so a shortcut link can make the path skip a
                        -- waypoint, and the skipped one then looks like an outside connection.
                        return string.format("id %d connects to id %d outside the span", id, other)
                    end
                end
            end
            if ADGraphManager:getMapMarkerByWayPointId(id) ~= nil then
                return string.format("map marker at id %d", id)
            end
        end
    end
    return nil
end

function ADFlyoverEditor:commitSmooth()
    local ids = self.smoothPreviewIds
    local newPoints = self.smoothPreview
    if ids == nil or newPoints == nil or #ids < 3 then
        self:cancelSmooth()
        return
    end

    if self.smoothMode == self.SMOOTH_MODE.RELAX then
        ADEditorHistory:snapshot("relax span")
        local moved = 0
        for i = 2, #ids - 1 do
            if not (self.smoothPinned or {})[i] then
                local p = newPoints[i]
                if p ~= nil then
                    self:moveTo(ids[i], p.x, p.z)
                    moved = moved + 1
                end
            end
        end
        ADFlyoverSettings.debugLog("[FlyoverEditor]: relaxed %d of %d waypoint(s) at strength %d; %d pinned (junctions or ends).",
            moved, #ids, self.smoothStrength, #ids - moved)
        ADGraphManager:markChanges()
        self.smoothFromId, self.smoothToId = nil, nil
        self.smoothPreview, self.smoothPinned = nil, nil
        self:invalidateIdReferences()
        return
    end

    ADEditorHistory:snapshot("rebuild span")
    self:rebuildSpanInPieces(ids)
    self.smoothFromId, self.smoothToId = nil, nil
    self.smoothPreview, self.smoothPinned = nil, nil
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
end

--- Rebuild a span, splitting it at any junction or marker rather than refusing the whole thing.
---
--- Rebuild deletes and re-creates the interior, so it genuinely cannot pass through a waypoint that
--- something else is attached to - a junction onto another route, or a map marker. It used to
--- refuse the entire span for that reason, which on a well-connected network meant it could almost
--- never be applied: every span of any length crosses something.
---
--- Splitting is the way out. Each junction-free piece between two anchors is rebuilt on its own and
--- the anchors themselves are left untouched, so the routes meeting there survive.
---
--- Ids renumber on every delete (GraphManager.lua:288), so the anchors are located by POSITION
--- before anything is touched and re-found by position between pieces. Carrying ids across the
--- rebuilds would mean each piece corrupting the addresses of the ones after it.
--- The positions of everything in a span that must survive a rebuild: the two ends, plus any
--- interior waypoint another route or a map marker is attached to.
---
--- Returned as POSITIONS, not ids. Ids renumber on every delete (GraphManager.lua:288), so a piece
--- being rebuilt would corrupt the addresses of every piece after it. Positions do not move.
---
--- These are the waypoints AutoDrive itself draws as right-of-way centres - Specialization.lua:1674
--- flags a point with `#out >= 1 and #incoming >= 2`, excluding plain single-to-dual, dual-to-single
--- and straight-dual transitions. In the editor they are the pale blue spheres.
function ADFlyoverEditor:collectSpanAnchors(ids)
    local inChain = {}
    for _, id in ipairs(ids) do
        inChain[id] = true
    end

    local positions, interiorAnchors = {}, 0
    local function record(id)
        local wp = ADGraphManager:getWayPointById(id)
        if wp ~= nil then
            table.insert(positions, { x = wp.x, z = wp.z })
        end
    end

    record(ids[1])
    for i = 2, #ids - 1 do
        local id = ids[i]
        local wp = ADGraphManager:getWayPointById(id)
        local isAnchor = false
        if wp ~= nil then
            for _, listName in ipairs(LINK_LISTS) do
                for _, other in pairs(linkList(wp, listName) or {}) do
                    if not inChain[other] then
                        isAnchor = true
                    end
                end
            end
            if ADGraphManager:getMapMarkerByWayPointId(id) ~= nil then
                isAnchor = true
            end
        end
        if isAnchor then
            record(id)
            interiorAnchors = interiorAnchors + 1
        end
    end
    record(ids[#ids])

    return positions, interiorAnchors
end

function ADFlyoverEditor:rebuildSpanInPieces(ids)
    local anchorPositions, junctions = self:collectSpanAnchors(ids)

    local maxSpacing = self.smoothSpacing
    local minSpacing = math.max(AutoDrive.FIELD_LOOP_ADAPTIVE_MIN_SPACING, maxSpacing * 0.25)

    local piecesDone, before, after = 0, 0, 0

    -- Backwards, so a piece being rebuilt cannot renumber the anchors of a piece not yet reached.
    for i = #anchorPositions - 1, 1, -1 do
        local startId = self:findWayPointAt(anchorPositions[i])
        local endId = self:findWayPointAt(anchorPositions[i + 1])
        if startId ~= nil and endId ~= nil and startId ~= endId then
            local piece = self:runPathBetween(startId, endId)
            if piece ~= nil and #piece > 2 then
                local pts = {}
                for j = 1, #piece do
                    local wp = ADGraphManager:getWayPointById(piece[j])
                    if wp ~= nil then
                        pts[#pts + 1] = { x = wp.x, y = wp.y, z = wp.z }
                    end
                end

                local smoothed = ADOffsetGeometry.smoothOpenChain(pts, 2, AutoDrive.FIELD_LOOP_MAX_WAYPOINT_TURN_DEG, 180)
                local resampled = ADOffsetGeometry.resampleOpenChainByCurvature(smoothed,
                    minSpacing, maxSpacing, AutoDrive.FIELD_LOOP_ADAPTIVE_TOLERANCE)
                local finalPts = ADOffsetGeometry.relaxOpenChain(resampled, 1, {})

                for j = 1, #finalPts do
                    finalPts[j].y = self:resolveHeightAt(finalPts[j].x, finalPts[j].z,
                        heightAlongChain(pts, finalPts[j].x, finalPts[j].z))
                end

                local a = ADGraphManager:getWayPointById(piece[1])
                local b = ADGraphManager:getWayPointById(piece[2])
                local dual = ADGraphManager:isDualRoad(a, b)
                local flags = b.flags or AutoDrive.FLAG_NONE

                before = before + #piece
                after = after + #finalPts
                if self:replaceChainInterior(piece, finalPts, dual, flags) then
                    piecesDone = piecesDone + 1
                end
            end
        end
    end

    if piecesDone == 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: nothing to rebuild - the span is all anchors, or too short between them.")
        return
    end

    ADFlyoverSettings.debugLog("[FlyoverEditor]: rebuilt %d piece(s) at %.1fm max spacing: %d point(s) -> %d, %d junction/marker anchor(s) kept in place.",
        piecesDone, maxSpacing, before, after, junctions)
end

--- Divide a span, splitting it at anchors the same way rebuild does.
---
--- The requested count is shared out between the pieces in proportion to their length, so asking
--- for N points across a span that happens to cross an intersection still gives roughly N points
--- overall and even spacing throughout - rather than refusing, which is what it did before.
--- The pieces of a span BETWEEN its anchors (its ends, junction-joined points and map markers), each as
--- the span's OWN route - the stretch of `ids` between two anchors - not a fresh shortest path.
---
--- Where two anchors are joined by more than one route (a siding beside the main line, a loop, a junction
--- cluster at a run's end), a path search takes the shorter one, and the tool then rebuilt a DIFFERENT
--- track from the one that was picked and previewed: Divide split the wrong route, Straighten replaced
--- junction points. Pieces are remembered as POSITIONS, because ids renumber as each piece is replaced,
--- and looked up again (exact match, a few centimetres) when their turn comes - back to front, so pieces
--- not yet reached are untouched. Returns anchorPositions, interiorAnchorCount, pieceFor(i) -> ids | nil.
function ADFlyoverEditor:ownRoutePieces(ids)
    local anchorPositions, anchors = self:collectSpanAnchors(ids)

    local piecePositions = {}
    local slicesOk = true
    do
        local anchorIndex, from = {}, 1
        for a = 1, #anchorPositions do
            local pos, found = anchorPositions[a], nil
            for k = from, #ids do
                local wp = ADGraphManager:getWayPointById(ids[k])
                if wp ~= nil and math.abs(wp.x - pos.x) < 0.03 and math.abs(wp.z - pos.z) < 0.03 then
                    found = k
                    break
                end
            end
            if found == nil then
                slicesOk = false
                break
            end
            anchorIndex[a], from = found, found
        end
        if slicesOk then
            for a = 1, #anchorPositions - 1 do
                local list = {}
                for k = anchorIndex[a], anchorIndex[a + 1] do
                    local wp = ADGraphManager:getWayPointById(ids[k])
                    if wp ~= nil then
                        list[#list + 1] = { x = wp.x, z = wp.z }
                    end
                end
                piecePositions[a] = list
            end
        end
    end

    local function pieceFor(i)
        if slicesOk and piecePositions[i] ~= nil then
            local out = {}
            for _, pos in ipairs(piecePositions[i]) do
                local id = self:findWayPointExact(pos)
                if id == nil then
                    out = nil
                    break
                end
                out[#out + 1] = id
            end
            if out ~= nil and #out >= 2 then
                return out, true
            end
        end
        -- Could not follow the span's own route: fall back to the path between the anchors.
        local startId = self:findWayPointAt(anchorPositions[i])
        local endId = self:findWayPointAt(anchorPositions[i + 1])
        if startId ~= nil and endId ~= nil and startId ~= endId then
            return self:runPathBetween(startId, endId), false
        end
        return nil, false
    end

    return anchorPositions, anchors, pieceFor
end

function ADFlyoverEditor:divideSpanInPieces(ids, totalCount)
    local anchorPositions, anchors, pieceFor = self:ownRoutePieces(ids)

    -- Measure every piece first, so the count can be shared out by length.
    local pieces, totalLength = {}, 0
    for i = 1, #anchorPositions - 1 do
        local piece = pieceFor(i)

        local length = 0
        if piece ~= nil then
            for j = 2, #piece do
                local a = ADGraphManager:getWayPointById(piece[j - 1])
                local b = ADGraphManager:getWayPointById(piece[j])
                if a ~= nil and b ~= nil then
                    length = length + MathUtil.vector2Length(b.x - a.x, b.z - a.z)
                end
            end
        end

        pieces[i] = { length = length }
        totalLength = totalLength + length
    end

    if totalLength <= 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: nothing to divide.")
        return
    end

    local placed, done = 0, 0

    -- Back to front, so a piece cannot renumber the anchors of one not yet reached.
    for i = #anchorPositions - 1, 1, -1 do
        local share = math.floor(totalCount * (pieces[i].length / totalLength) + 0.5)

        local piece = pieceFor(i)
        if piece ~= nil and #piece >= 2 then
            local newPoints = self:evenlySpacedAlong(piece, share)
            if newPoints ~= nil and self:replaceChainInterior(piece, newPoints, self:spanStyle(piece)) then
                placed = placed + share
                done = done + 1
            end
        end
    end

    ADFlyoverSettings.debugLog("[FlyoverEditor]: divided %d piece(s) into %d point(s) total, %d intersection anchor(s) kept in place.",
        done, placed, anchors)
end

--- Whether a span is dual, and what flags it carries, taken from its first connection.
function ADFlyoverEditor:spanStyle(ids)
    local a = ADGraphManager:getWayPointById(ids[1])
    local b = ADGraphManager:getWayPointById(ids[2])
    if a == nil or b == nil then
        return false, AutoDrive.FLAG_NONE
    end
    return ADGraphManager:isDualRoad(a, b), b.flags or AutoDrive.FLAG_NONE
end

--- `count` points spread evenly by arc length between the two ends of a span, ends included.
function ADFlyoverEditor:evenlySpacedAlong(ids, count)
    local pts = {}
    for _, id in ipairs(ids) do
        local wp = ADGraphManager:getWayPointById(id)
        if wp ~= nil then
            pts[#pts + 1] = { x = wp.x, y = wp.y, z = wp.z }
        end
    end
    if #pts < 2 then
        return nil
    end

    local cumulative = { 0 }
    for i = 2, #pts do
        cumulative[i] = cumulative[i - 1] + MathUtil.vector2Length(pts[i].x - pts[i - 1].x, pts[i].z - pts[i - 1].z)
    end
    local total = cumulative[#pts]
    if total <= 0 then
        return nil
    end

    local function pointAt(distance)
        for i = 2, #pts do
            if cumulative[i] >= distance then
                local segLen = cumulative[i] - cumulative[i - 1]
                local f = segLen > 0 and (distance - cumulative[i - 1]) / segLen or 0
                return {
                    x = pts[i - 1].x + (pts[i].x - pts[i - 1].x) * f,
                    z = pts[i - 1].z + (pts[i].z - pts[i - 1].z) * f
                }
            end
        end
        return { x = pts[#pts].x, z = pts[#pts].z }
    end

    local result = { { x = pts[1].x, y = pts[1].y, z = pts[1].z } }
    for i = 1, count do
        local p = pointAt(total * i / (count + 1))
        p.y = self:resolveHeightAt(p.x, p.z, heightAlongChain(pts, p.x, p.z))
        result[#result + 1] = p
    end
    result[#result + 1] = { x = pts[#pts].x, y = pts[#pts].y, z = pts[#pts].z }
    return result
end

--- The waypoint at a remembered position, or nil. Used to re-find anchors after a rebuild has
--- renumbered everything around them.
--- The waypoint sitting exactly at `pos` (within a few centimetres), or nil. Unlike findWayPointAt this
--- never snaps to a NEIGHBOUR: on a siding or a parallel lane, the nearest waypoint within the anchor
--- tolerance can belong to the other lane.
function ADFlyoverEditor:findWayPointExact(pos)
    local wayPoints = ADGraphManager:getWayPoints()
    for i = 1, #wayPoints do
        local wp = wayPoints[i]
        if math.abs(wp.x - pos.x) < 0.03 and math.abs(wp.z - pos.z) < 0.03 then
            return wp.id
        end
    end
    return nil
end

function ADFlyoverEditor:findWayPointAt(pos)
    local best, bestSq = nil, AutoDrive.FLYOVER_ANCHOR_TOLERANCE * AutoDrive.FLYOVER_ANCHOR_TOLERANCE
    local wayPoints = ADGraphManager:getWayPoints()
    for i = 1, #wayPoints do
        local wp = wayPoints[i]
        local dx, dz = wp.x - pos.x, wp.z - pos.z
        local d = dx * dx + dz * dz
        if d < bestSq then
            best, bestSq = wp.id, d
        end
    end
    return best
end

--- Delete the interior of a chain and lay down newPoints in its place, keeping the two endpoints
--- where they are so the span stays attached to the rest of the network.
--- Which way the span's first connection actually runs. runPathBetween returns a traversal order,
--- which is not necessarily the direction the connection was drawn in - and rebuilding always lays
--- connections in that order, so a span traversed against its own direction came back reversed.
local function spanRunsForward(chainIds)
    local a = ADGraphManager:getWayPointById(chainIds[1])
    local b = ADGraphManager:getWayPointById(chainIds[2])
    if a == nil or b == nil then
        return true
    end
    if table.contains(a.out, b.id) then
        return true -- forward, or dual, in which case either answer rebuilds correctly
    end
    if table.contains(b.out, a.id) then
        return false -- one-way, against the traversal
    end
    return true
end

--- Drop any direct connection between the two ends, in either direction.
local function severEnds(aId, bId)
    local a = ADGraphManager:getWayPointById(aId)
    local b = ADGraphManager:getWayPointById(bId)
    if a == nil or b == nil then
        return
    end
    if table.contains(a.out, b.id) then
        ADGraphManager:toggleConnectionBetween(a, b, false, false, false)
    end
    if table.contains(b.out, a.id) then
        ADGraphManager:toggleConnectionBetween(b, a, false, false, false)
    end
end

function ADFlyoverEditor:replaceChainInterior(chainIds, newPoints, dual, flags)
    -- Every caller (smooth, divide, straighten) takes `flags` from the span's second point, so the
    -- field number goes with them from the same point: a stretch of AutoDrive's field loop, rebuilt,
    -- is still that field's loop. Read before anything is removed.
    local fieldID = ADFlyoverEditor.fieldOf(ADGraphManager:getWayPointById(chainIds[2]))
    -- Rebuild in the direction the span actually ran, not the direction it happened to be walked
    -- in. Reversing both arrays together keeps newPoints aligned with chainIds.
    if not spanRunsForward(chainIds) then
        local rc, rp = {}, {}
        for i = #chainIds, 1, -1 do rc[#rc + 1] = chainIds[i] end
        for i = #newPoints, 1, -1 do rp[#rp + 1] = newPoints[i] end
        chainIds, newPoints = rc, rp
    end

    local startId, endId = chainIds[1], chainIds[#chainIds]

    local doomed = {}
    for i = 2, #chainIds - 1 do
        table.insert(doomed, chainIds[i])
    end
    table.sort(doomed, function(a, b) return a > b end)

    for _, id in ipairs(doomed) do
        ADGraphManager:removeWayPoint(id, false)
    end

    -- Every removal renumbers the ids above it, so the endpoints have almost certainly moved.
    -- Their new ids are their old ones less the number of deleted points that sat below them:
    -- exact, and cheaper than trying to find them again by position.
    local function shifted(id)
        local shift = 0
        for _, deletedId in ipairs(doomed) do
            if deletedId < id then
                shift = shift + 1
            end
        end
        return id - shift
    end
    local newStartId, newEndId = shifted(startId), shifted(endId)

    -- A span with no interior has nothing to delete, so its ends are still directly connected - and
    -- the rebuild below would then add a SECOND path between them, leaving the original connection
    -- running alongside the new subdivided one. That is the fork reported as "divide connects the
    -- ends". Sever it first, so the new chain REPLACES the connection instead of joining it.
    if #chainIds == 2 then
        severEnds(newStartId, newEndId)
    end

    -- newPoints carries both endpoints; only the interior gets created.
    local previousId = newStartId
    for i = 2, #newPoints - 1 do
        local p = newPoints[i]
        local y = AutoDrive:getTerrainHeightAtWorldPos(p.x, p.z)
        local wp = ADFlyoverRecordWayPoint(p.x, y, p.z, true, dual, false, previousId, flags, false, fieldID)
        -- New waypoints are appended, so their ids sit above everything already there and nothing
        -- shifts underneath us for the rest of this loop.
        previousId = (wp ~= nil and wp.id) or ADGraphManager:getWayPointsCount()
    end

    local tail = ADGraphManager:getWayPointById(previousId)
    local endNode = ADGraphManager:getWayPointById(newEndId)
    if tail == nil or endNode == nil then
        Logging.error("[FlyoverEditor]: lost the span endpoints while rebuilding (tail=%s end=%s).",
            tostring(previousId), tostring(newEndId))
        return false
    end
    ADGraphManager:toggleConnectionBetween(tail, endNode, false, dual, false)
    return true
end

--[[
ADOffsetGeometry - polygon offsetting, corner rounding and curvature-aware resampling, used by the
field-loop generator and by the flyover editor's smooth/divide tools.

MIT, like the rest of this mod. Written from the published algorithms below rather than from any
existing implementation of them:

  * Polygon offsetting is the standard edge-shift construction: move every edge along its inward
    normal by the offset distance, then take each new vertex as the intersection of consecutive
    shifted edge lines. Sharp corners are guarded by the usual miter limit - past MITER_LIMIT times
    the offset distance the miter is replaced by a bevel, because the miter of a nearly-doubled-back
    corner runs off toward infinity. Features narrower than twice the offset cannot survive an
    offset at all, so a validity pass discards vertices that ended up on the wrong side of the
    source boundary, and a loop pass removes the folds that remain.
  * Smoothing is Taubin's shrinkage-free pair (G. Taubin, "Curve and Surface Smoothing Without
    Shrinkage", ICCV 1995): one Laplacian step with a positive weight followed by one with a
    slightly larger negative weight. Repeated plain Laplacian smoothing collapses a closed shape
    toward its centroid; the negative second step is what holds the low frequencies in place while
    still killing the high ones.
  * Refinement before smoothing inserts edge midpoints - plain corner-cutting subdivision
    (Chaikin, 1974).
  * Adaptive spacing uses the sagitta relation: a chord of length s across a circle of radius r
    departs from the arc by about s^2/(8r), so holding that departure at `tolerance` means a
    spacing of sqrt(8 * r * tolerance). Local radius at a vertex is the circumradius of it and its
    two neighbours, R = abc/(4K).
  * The cross-track error of a turn is r * (sec(dA/2) - 1): an arc of radius r laid through a
    corner of turn angle dA misses the corner itself by that much, which is the physically
    meaningful "can a vehicle with this turning radius actually follow this vertex" test.

Point tags this module sets, which callers rely on:
    point.isCorner    - tagTightCorners: this vertex is too tight for the given turning radius
    point.dA          - tagTightCorners: signed turn angle at the vertex, radians
    point.isCornerArc - roundPreservedCorners, on the arc points it generates. smoothSpline leaves
                        those alone, and FieldLoopGenerator carries the tag through its tree passes.

Conventions: points are flat {x=, z=} tables, y carried through where present. Rings are closed and
must NOT repeat the first point. A positive shoelace area means counter-clockwise in (x, z), and
insetDistance > 0 means inward (shrink), matching this codebase's existing sign convention.
]]

ADOffsetGeometry = {}

local EPS = 1e-9
local PARALLEL_EPS = 1e-12

-- Past this multiple of the offset distance a corner's miter is bevelled instead. 6 lets a corner
-- as sharp as about 19 degrees still come to a point, which covers any real field corner, while
-- still catching the doubled-back geometry of a narrow inlet.
local MITER_LIMIT = 6

-- A turn this sharp is not a corner, it is the path reversing onto itself - see removeCusps.
local CUSP_ANGLE_DEG = 179

-- Taubin's lambda/mu pair. mu is chosen so that 1/lambda + 1/mu sits just above zero (the
-- pass-band condition in the paper), which is what makes the smoothing shrinkage-free.
local TAUBIN_LAMBDA = 0.55
local TAUBIN_MU = -0.582

-- How far a too-tight vertex is pulled toward the midpoint of its neighbours per relaxation pass.
local TIGHT_RELAX_WEIGHT = 0.5

-- ---------------------------------------------------------------------------------------------
-- Small vector and angle helpers
-- ---------------------------------------------------------------------------------------------

local function distanceBetween(a, b)
    return MathUtil.vector2Length(b.x - a.x, b.z - a.z)
end

local function copyPoint(p)
    return { x = p.x, z = p.z, y = p.y, isCornerArc = p.isCornerArc }
end

local function copyPoints(points)
    local out = {}
    for i = 1, #points do
        out[i] = copyPoint(points[i])
    end
    return out
end

--- Wrap an angle into (-pi, pi].
local function normaliseAngle(a)
    while a > math.pi do a = a - 2 * math.pi end
    while a <= -math.pi do a = a + 2 * math.pi end
    return a
end

local function headingBetween(a, b)
    return math.atan2(b.z - a.z, b.x - a.x)
end

--- Signed turn angle at `cur`, positive left, in (-pi, pi].
local function turnAngle(prev, cur, nxt)
    return normaliseAngle(headingBetween(cur, nxt) - headingBetween(prev, cur))
end

--- How far an arc of the given radius laid through a corner of turn `dA` misses the corner by.
--- A straight-through vertex (dA = 0) gives 0; a full reversal gives infinity.
local function cornerCrossTrackError(dA, radius)
    local half = math.abs(dA) * 0.5
    if half >= math.pi * 0.5 - 1e-6 then
        return math.huge
    end
    return radius * (1 / math.cos(half) - 1)
end

--- Circumradius of the triangle prev-cur-nxt, i.e. the radius of the circle through all three.
--- Collinear points give infinity, which is the right answer: a straight run has no curvature.
local function localRadius(prev, cur, nxt)
    local a = distanceBetween(prev, cur)
    local b = distanceBetween(cur, nxt)
    local c = distanceBetween(prev, nxt)
    -- twice the triangle area, via the cross product of two of its edges
    local doubleArea = math.abs((cur.x - prev.x) * (nxt.z - prev.z) - (cur.z - prev.z) * (nxt.x - prev.x))
    if doubleArea < 1e-9 then
        return math.huge
    end
    return (a * b * c) / (2 * doubleArea)
end

-- Smallest spacing any resample is allowed to work at. A spacing of zero steps nowhere, so a
-- resample loop would emit points forever without advancing - not a hang but an out-of-memory
-- crash, and from a draw path at that. The callers own these numbers (a companion mod keeps its
-- own settings rather than AutoDrive's), so an empty numeric field arriving as 0 has to be
-- survivable rather than trusted.
local MIN_USABLE_SPACING = 0.05
local MIN_USABLE_TOLERANCE = 1e-6

--- Coerce a caller's spacing band into one that can actually be walked: numbers, both positive,
--- and max no smaller than min.
local function sanitiseSpacingBand(minSpacing, maxSpacing)
    local lo = tonumber(minSpacing) or 0
    local hi = tonumber(maxSpacing) or 0
    if lo ~= lo then lo = 0 end -- NaN
    if hi ~= hi then hi = 0 end
    lo = math.max(lo, MIN_USABLE_SPACING)
    hi = math.max(hi, lo)
    return lo, hi
end

local function sanitiseTolerance(tolerance)
    local t = tonumber(tolerance) or 0
    if t ~= t then
        t = 0
    end
    return math.max(t, MIN_USABLE_TOLERANCE)
end

--- Sagitta-derived point spacing for the curvature at this vertex, clamped to the caller's band.
local function spacingForCurvature(prev, cur, nxt, minSpacing, maxSpacing, tolerance)
    local radius = localRadius(prev, cur, nxt)
    if radius == math.huge then
        return maxSpacing
    end
    local spacing = math.sqrt(8 * radius * tolerance)
    if spacing ~= spacing then -- NaN from a degenerate radius or tolerance
        return maxSpacing
    end
    return math.max(minSpacing, math.min(maxSpacing, spacing))
end

local function ringNeighbours(ring, i)
    local n = #ring
    return ring[((i - 2) % n) + 1], ring[i], ring[(i % n) + 1]
end

local function dropDuplicates(points, tolerance)
    local out = {}
    for i = 1, #points do
        local p = points[i]
        local last = out[#out]
        if last == nil or distanceBetween(last, p) > tolerance then
            out[#out + 1] = p
        end
    end
    -- the ring closes, so the last point must not coincide with the first either
    while #out > 1 and distanceBetween(out[1], out[#out]) <= tolerance do
        table.remove(out)
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- Corner classification
-- ---------------------------------------------------------------------------------------------

--- Tag every vertex a vehicle of `turningRadius` could not follow within `maxCrossTrackError`.
--- Mutates the ring in place, setting .dA and .isCorner on each point, and returns it.
function ADOffsetGeometry.tagTightCorners(ring, turningRadius, maxCrossTrackError)
    for i = 1, #ring do
        local prev, cur, nxt = ringNeighbours(ring, i)
        local dA = turnAngle(prev, cur, nxt)
        cur.dA = dA
        cur.isCorner = cornerCrossTrackError(dA, turningRadius) > maxCrossTrackError
    end
    return ring
end

-- ---------------------------------------------------------------------------------------------
-- Polygon offsetting
-- ---------------------------------------------------------------------------------------------

--- Shift every edge along its inward normal, returning the shifted edges as lines in
--- point + unit-direction form. `windingSign` is +1 for a counter-clockwise ring, so that the
--- left normal (-uz, ux) points into the polygon.
local function shiftedEdgeLines(ring, offsetDistance, windingSign)
    local n = #ring
    local lines = {}
    for i = 1, n do
        local a, b = ring[i], ring[(i % n) + 1]
        local dx, dz = b.x - a.x, b.z - a.z
        local length = MathUtil.vector2Length(dx, dz)
        if length > EPS then
            local ux, uz = dx / length, dz / length
            local nx, nz = -uz * windingSign, ux * windingSign
            lines[#lines + 1] = {
                px = a.x + nx * offsetDistance,
                pz = a.z + nz * offsetDistance,
                ux = ux,
                uz = uz,
                nx = nx,
                nz = nz,
                corner = b, -- the source vertex this edge shares with the next one
            }
        end
    end
    return lines
end

--- Intersection of two lines in point + direction form, or nil when they are (near) parallel.
local function intersectLines(first, second)
    local denominator = first.ux * second.uz - first.uz * second.ux
    if math.abs(denominator) < PARALLEL_EPS then
        return nil
    end
    local t = ((second.px - first.px) * second.uz - (second.pz - first.pz) * second.ux) / denominator
    return { x = first.px + t * first.ux, z = first.pz + t * first.uz }
end

--- One offset vertex per pair of consecutive shifted edges. A corner whose miter would land
--- further than MITER_LIMIT * distance from the source vertex is bevelled instead - two points,
--- one perpendicular foot on each shifted edge. That is what stops a nearly-doubled-back corner
--- (the tip of a narrow inlet, say) from throwing its vertex hundreds of metres off the field.
local function offsetVertices(lines, offsetDistance)
    local count = #lines
    local out = {}
    local miterCap = math.abs(offsetDistance) * MITER_LIMIT
    for i = 1, count do
        local current = lines[i]
        local following = lines[(i % count) + 1]
        local corner = current.corner
        local mitered = intersectLines(current, following)
        if mitered ~= nil and distanceBetween(mitered, corner) <= miterCap then
            out[#out + 1] = mitered
        else
            out[#out + 1] = { x = corner.x + current.nx * offsetDistance, z = corner.z + current.nz * offsetDistance }
            out[#out + 1] = { x = corner.x + following.nx * offsetDistance, z = corner.z + following.nz * offsetDistance }
        end
    end
    return out
end

local function isPointInsideRing(p, ring)
    local n = #ring
    local inside = false
    for i = 1, n do
        local a, b = ring[i], ring[(i % n) + 1]
        if (a.z > p.z) ~= (b.z > p.z) then
            local crossingX = a.x + (p.z - a.z) / (b.z - a.z) * (b.x - a.x)
            if p.x < crossingX then
                inside = not inside
            end
        end
    end
    return inside
end

local function distanceToSegment(p, a, b)
    local dx, dz = b.x - a.x, b.z - a.z
    local lengthSquared = dx * dx + dz * dz
    if lengthSquared < 1e-12 then
        return distanceBetween(p, a)
    end
    local t = ((p.x - a.x) * dx + (p.z - a.z) * dz) / lengthSquared
    t = math.max(0, math.min(1, t))
    return MathUtil.vector2Length(p.x - (a.x + t * dx), p.z - (a.z + t * dz))
end

local function distanceToRing(p, ring)
    local n = #ring
    local best = math.huge
    for i = 1, n do
        local d = distanceToSegment(p, ring[i], ring[(i % n) + 1])
        if d < best then
            best = d
        end
    end
    return best
end

--- Throw away offset vertices that the shift turned inside out. Every legitimate vertex of an
--- inward offset lies inside the source polygon and at least the offset distance from its
--- boundary; anything failing either test belongs to a feature narrower than twice the offset,
--- which an offset of that size is supposed to close up entirely.
local function dropInvertedVertices(candidates, source, offsetDistance, wantInside)
    local minimumClearance = math.abs(offsetDistance) * 0.9
    local kept = {}
    for i = 1, #candidates do
        local p = candidates[i]
        if distanceToRing(p, source) >= minimumClearance and isPointInsideRing(p, source) == wantInside then
            kept[#kept + 1] = p
        end
    end
    return kept
end

--- Crossing point of two segments, excluding shared endpoints, or nil.
local function properIntersection(p1, p2, p3, p4)
    local d1x, d1z = p2.x - p1.x, p2.z - p1.z
    local d2x, d2z = p4.x - p3.x, p4.z - p3.z
    local denominator = d1x * d2z - d1z * d2x
    if math.abs(denominator) < PARALLEL_EPS then
        return nil
    end
    local s = ((p3.x - p1.x) * d2z - (p3.z - p1.z) * d2x) / denominator
    local t = ((p3.x - p1.x) * d1z - (p3.z - p1.z) * d1x) / denominator
    if s > EPS and s < 1 - EPS and t > EPS and t < 1 - EPS then
        return { x = p1.x + s * d1x, z = p1.z + s * d1z }
    end
    return nil
end

--- Cut self-intersection folds out of a closed ring. Where edge i crosses edge j the ring has
--- folded over itself, splitting it into two loops joined at the crossing; the larger-area loop is
--- the real boundary and the other is the fold, so keep the larger and drop the rest. Repeats
--- until no crossings remain.
local function removeSelfIntersections(ring)
    for _ = 1, 64 do
        local n = #ring
        if n < 4 then
            return ring
        end
        local repaired = nil
        for i = 1, n do
            local a1, a2 = ring[i], ring[(i % n) + 1]
            for j = i + 2, n do
                if not (i == 1 and j == n) then
                    local b1, b2 = ring[j], ring[(j % n) + 1]
                    local hit = properIntersection(a1, a2, b1, b2)
                    if hit ~= nil then
                        local outer, inner = {}, { hit }
                        for k = 1, i do outer[#outer + 1] = ring[k] end
                        outer[#outer + 1] = hit
                        for k = j + 1, n do outer[#outer + 1] = ring[k] end
                        for k = i + 1, j do inner[#inner + 1] = ring[k] end
                        local outerArea = math.abs(ADPolygonUtils.getSignedArea(outer))
                        local innerArea = math.abs(ADPolygonUtils.getSignedArea(inner))
                        repaired = (outerArea >= innerArea) and outer or inner
                        break
                    end
                end
            end
            if repaired ~= nil then
                break
            end
        end
        if repaired == nil then
            return ring
        end
        ring = repaired
    end
    return ring
end

--- Remove cusps - vertices where the path reverses onto itself instead of turning.
---
--- Two shifted edges that meet at a very shallow angle (the two walls of a narrow inlet, say) can
--- miter past each other and leave a fold that lies along a single straight line. A fold like that
--- crosses nothing, so the self-intersection pass never sees it, but it does leave a vertex whose
--- turn is very nearly a full reversal. Take the worst such vertex out and re-measure, because
--- removing one end of a fold changes the turn at the other.
local function removeCusps(ring)
    for _ = 1, 64 do
        local n = #ring
        if n < 4 then
            return ring
        end
        local worstTurn, worstAt = 0, nil
        for i = 1, n do
            local prev, cur, nxt = ringNeighbours(ring, i)
            if distanceBetween(prev, cur) > EPS and distanceBetween(cur, nxt) > EPS then
                local turn = math.abs(math.deg(turnAngle(prev, cur, nxt)))
                if turn > worstTurn then
                    worstTurn, worstAt = turn, i
                end
            end
        end
        if worstAt == nil or worstTurn < CUSP_ANGLE_DEG then
            return ring
        end
        table.remove(ring, worstAt)
    end
    return ring
end

--- Alternate the two repair passes until the ring stops changing: removing a fold can expose a
--- crossing and closing a crossing can leave a fold.
local function cleanOffsetRing(ring)
    for _ = 1, 8 do
        local before = #ring
        ring = removeCusps(ring)
        ring = removeSelfIntersections(ring)
        if #ring == before then
            return ring
        end
    end
    return ring
end

--- Offset a closed ring inward (positive distance) or outward (negative).
---@param ring table array of {x=,z=} points, ordered, closed, first point not repeated
---@param insetDistance number positive = inward (shrink), negative = outward (grow)
---@param turningRadius number meters, used to classify which vertices count as real corners
---@param maxCrossTrackError number meters, the corner-classification threshold
---@return table|nil offsetRing, string|nil errorMessage
function ADOffsetGeometry.generateOffset(ring, insetDistance, turningRadius, maxCrossTrackError)
    if #ring < 3 then
        return nil, "Polygon has fewer than 3 vertices."
    end
    if math.abs(insetDistance) < 1e-6 then
        return ring, nil
    end

    local sourceArea = ADPolygonUtils.getSignedArea(ring)
    if math.abs(sourceArea) < 1e-6 then
        return nil, "Polygon has zero area."
    end
    local windingSign = sourceArea > 0 and 1 or -1

    -- Corner classification is a documented side effect of this call. The offset itself no longer
    -- needs the tags - intersecting shifted edges reproduces a sharp corner exactly, so corners
    -- are preserved by construction rather than by being protected from a stepwise collapse.
    ADOffsetGeometry.tagTightCorners(ring, turningRadius, maxCrossTrackError)

    local lines = shiftedEdgeLines(ring, insetDistance, windingSign)
    if #lines < 3 then
        return nil, "Polygon has fewer than 3 usable edges."
    end

    local candidates = dropDuplicates(offsetVertices(lines, insetDistance), 1e-6)
    candidates = dropInvertedVertices(candidates, ring, insetDistance, insetDistance > 0)
    if #candidates < 3 then
        return nil, "Offset collapsed the polygon to fewer than 3 vertices."
    end

    local result = cleanOffsetRing(candidates)
    if #result < 3 then
        return nil, "Offset collapsed the polygon to fewer than 3 vertices."
    end

    local resultArea = ADPolygonUtils.getSignedArea(result)
    if math.abs(resultArea) < 1e-6 or (resultArea > 0) ~= (sourceArea > 0) then
        return nil, "Offset turned the polygon inside out - the margin is too large for this field."
    end

    return result, nil
end

-- ---------------------------------------------------------------------------------------------
-- Corner rounding
-- ---------------------------------------------------------------------------------------------

--- Approximate arc length of a quadratic Bezier: the mean of its control polygon and its chord is
--- within a fraction of a percent over the shallow turns a boundary corner produces.
local function quadraticBezierLength(from, control, to)
    local polygon = distanceBetween(from, control) + distanceBetween(control, to)
    local chord = distanceBetween(from, to)
    return (polygon + chord) * 0.5
end

--- Replace every vertex still too tight for `turningRadius` with a curve the vehicle can follow.
--- The tangent points sit turningRadius * tan(|dA|/2) back along each adjacent edge - the standard
--- distance from a corner to where a circle of that radius touches it - capped at 45% of the edge
--- so two neighbouring corners can never eat into each other. The curve between them is a
--- quadratic Bezier controlled by the original sharp vertex, sampled about every
--- `arcPointSpacing` metres, and its points are tagged isCornerArc so later smoothing leaves the
--- deliberately-built geometry alone.
function ADOffsetGeometry.roundPreservedCorners(ring, turningRadius, maxCrossTrackError, arcPointSpacing)
    local n = #ring
    if n < 3 then
        return copyPoints(ring)
    end
    arcPointSpacing = arcPointSpacing or 1.0

    ADOffsetGeometry.tagTightCorners(ring, turningRadius, maxCrossTrackError)

    local out = {}
    for i = 1, n do
        local prev, cur, nxt = ringNeighbours(ring, i)
        local entryLength = distanceBetween(prev, cur)
        local exitLength = distanceBetween(cur, nxt)
        local halfTurn = math.abs(cur.dA or 0) * 0.5
        local tangent = 0
        if cur.isCorner and entryLength > EPS and exitLength > EPS then
            tangent = turningRadius * math.tan(math.min(halfTurn, math.rad(85)))
            tangent = math.min(tangent, entryLength * 0.45, exitLength * 0.45)
        end

        if tangent < 1e-3 then
            out[#out + 1] = copyPoint(cur)
        else
            local entry = {
                x = cur.x - (cur.x - prev.x) / entryLength * tangent,
                z = cur.z - (cur.z - prev.z) / entryLength * tangent,
            }
            local exit = {
                x = cur.x + (nxt.x - cur.x) / exitLength * tangent,
                z = cur.z + (nxt.z - cur.z) / exitLength * tangent,
            }
            local steps = math.max(2, math.ceil(quadraticBezierLength(entry, cur, exit) / arcPointSpacing))
            for step = 0, steps do
                local t = step / steps
                local mt = 1 - t
                out[#out + 1] = {
                    x = mt * mt * entry.x + 2 * mt * t * cur.x + t * t * exit.x,
                    z = mt * mt * entry.z + 2 * mt * t * cur.z + t * t * exit.z,
                    isCornerArc = true,
                }
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- Smoothing - closed rings
-- ---------------------------------------------------------------------------------------------

--- One Laplacian step over a closed ring: every eligible vertex moves `weight` of the way toward
--- the midpoint of its neighbours. Positions are read from the input and written to a copy, so the
--- result does not depend on the order vertices are visited.
local function laplacianRingPass(points, weight, isEligible)
    local n = #points
    local out = copyPoints(points)
    for i = 1, n do
        if isEligible(points, i) then
            local prev, cur, nxt = ringNeighbours(points, i)
            local midX = (prev.x + nxt.x) * 0.5
            local midZ = (prev.z + nxt.z) * 0.5
            out[i].x = cur.x + weight * (midX - cur.x)
            out[i].z = cur.z + weight * (midZ - cur.z)
        end
    end
    return out
end

local function taubinRingPass(points, isEligible)
    return laplacianRingPass(laplacianRingPass(points, TAUBIN_LAMBDA, isEligible), TAUBIN_MU, isEligible)
end

--- Insert the midpoint after every eligible vertex of a closed ring.
local function refineRing(points, isEligible)
    local n = #points
    local out = {}
    for i = 1, n do
        local cur = points[i]
        local nxt = points[(i % n) + 1]
        out[#out + 1] = copyPoint(cur)
        if isEligible(points, i) then
            out[#out + 1] = { x = (cur.x + nxt.x) * 0.5, z = (cur.z + nxt.z) * 0.5 }
        end
    end
    return out
end

--- Round off the medium bends that make a driven path feel jumpy, leaving both the straights and
--- any deliberately-built corner arc alone. `order` refine-and-smooth passes; only vertices whose
--- turn falls strictly between minAngleDeg and maxAngleDeg are touched.
function ADOffsetGeometry.smoothSpline(ring, order, minAngleDeg, maxAngleDeg)
    order = order or 2
    minAngleDeg = minAngleDeg or 2
    maxAngleDeg = maxAngleDeg or 180

    local function isEligible(points, i)
        local p = points[i]
        if p.isCornerArc then
            return false
        end
        local prev, cur, nxt = ringNeighbours(points, i)
        if distanceBetween(prev, cur) < EPS or distanceBetween(cur, nxt) < EPS then
            return false
        end
        local turn = math.abs(math.deg(turnAngle(prev, cur, nxt)))
        return turn > minAngleDeg and turn < maxAngleDeg
    end

    local current = copyPoints(ring)
    for _ = 1, order do
        if #current < 4 then
            break
        end
        current = refineRing(current, isEligible)
        current = taubinRingPass(current, isEligible)
    end
    return current
end

--- Pull any vertex too tight for `turningRadius` toward the midpoint of its neighbours, which is
--- what lowers the local turn and so raises the local radius. Never adds or removes points.
---
--- isPositionAllowed(x, z, prev, nxt) may veto a candidate position; the point then simply keeps
--- the one it had. That is how the tree pass stops smoothing from undoing its own clearance work,
--- and it gets the neighbours too so it can test the spans the move creates rather than just the
--- point. Corner arcs need no special casing: an arc built at turningRadius already passes the
--- cross-track test and so is never selected.
---@return table smoothedRing, number movedCount
function ADOffsetGeometry.smoothTightVertices(ring, turningRadius, maxCrossTrackError, iterations, isPositionAllowed)
    iterations = iterations or 1
    local points = copyPoints(ring)
    local n = #points
    if n < 3 then
        return points, 0
    end

    local movedCount = 0
    for _ = 1, iterations do
        local movedThisPass = false
        for i = 1, n do
            local prev, cur, nxt = ringNeighbours(points, i)
            if cornerCrossTrackError(turnAngle(prev, cur, nxt), turningRadius) > maxCrossTrackError then
                local candidateX = cur.x + TIGHT_RELAX_WEIGHT * ((prev.x + nxt.x) * 0.5 - cur.x)
                local candidateZ = cur.z + TIGHT_RELAX_WEIGHT * ((prev.z + nxt.z) * 0.5 - cur.z)
                if isPositionAllowed == nil or isPositionAllowed(candidateX, candidateZ, prev, nxt) then
                    cur.x, cur.z = candidateX, candidateZ
                    movedCount = movedCount + 1
                    movedThisPass = true
                end
            end
        end
        if not movedThisPass then
            break
        end
    end
    return points, movedCount
end

-- ---------------------------------------------------------------------------------------------
-- Spacing - closed rings
-- ---------------------------------------------------------------------------------------------

--- Drop any point closer than minEdgeLength to the one before it, including across the closing
--- edge. Each geometry stage can leave near-duplicates where it joins the next - a corner arc's
--- last point landing almost on the following boundary vertex - and in game those show up as
--- waypoint poles stacked on top of each other. Keep minEdgeLength below the corner arc spacing so
--- this only removes genuine duplicates.
function ADOffsetGeometry.ensureMinimumEdgeLength(ring, minEdgeLength)
    local n = #ring
    if n < 3 then
        return copyPoints(ring)
    end
    local out = { copyPoint(ring[1]) }
    for i = 2, n do
        if distanceBetween(out[#out], ring[i]) >= minEdgeLength then
            out[#out + 1] = copyPoint(ring[i])
        end
    end
    while #out > 3 and distanceBetween(out[1], out[#out]) < minEdgeLength do
        table.remove(out)
    end
    return out
end

--- Split any edge longer than maxSpacing into equal sub-segments no longer than it. Needed before
--- thinToAdaptiveSpacing, which can only remove points: a field boundary taken straight from the
--- game's polygon can have a single 260m edge with nothing in between for the thinning pass to
--- work with.
function ADOffsetGeometry.densifyLongEdges(ring, maxSpacing)
    local n = #ring
    if n < 2 or maxSpacing == nil or maxSpacing <= 0 then
        return copyPoints(ring)
    end
    local out = {}
    for i = 1, n do
        local a, b = ring[i], ring[(i % n) + 1]
        out[#out + 1] = copyPoint(a)
        local length = distanceBetween(a, b)
        if length > maxSpacing then
            local steps = math.ceil(length / maxSpacing)
            for step = 1, steps - 1 do
                local t = step / steps
                out[#out + 1] = { x = a.x + (b.x - a.x) * t, z = a.z + (b.z - a.z) * t }
            end
        end
    end
    return out
end

--- Thin a dense ring so point density follows curvature: tight turns keep their points, straight
--- runs shed theirs. Target spacing at each vertex is the sagitta spacing for the local radius,
--- clamped to [minSpacing, maxSpacing]. Vertices turning more than protectAngleDeg, and any corner
--- arc point, are never dropped - their density was decided deliberately by an earlier pass. Runs
--- to a fixed point rather than a single forward sweep.
function ADOffsetGeometry.thinToAdaptiveSpacing(ring, minSpacing, maxSpacing, tolerance, protectAngleDeg)
    local current = copyPoints(ring)
    protectAngleDeg = protectAngleDeg or 20
    minSpacing, maxSpacing = sanitiseSpacingBand(minSpacing, maxSpacing)
    tolerance = sanitiseTolerance(tolerance)

    for _ = 1, 8 do
        local n = #current
        if n < 4 then
            break
        end
        local kept = {}
        local lastKept = nil
        for i = 1, n do
            local prev, cur, nxt = ringNeighbours(current, i)
            local turn = math.abs(math.deg(turnAngle(prev, cur, nxt)))
            local protected = cur.isCornerArc == true or turn > protectAngleDeg
            local target = spacingForCurvature(prev, cur, nxt, minSpacing, maxSpacing, tolerance)
            if lastKept == nil or protected or distanceBetween(lastKept, cur) >= target then
                kept[#kept + 1] = cur
                lastKept = cur
            end
        end
        if #kept < 4 or #kept == #current then
            current = kept
            break
        end
        current = kept
    end
    return current
end

-- ---------------------------------------------------------------------------------------------
-- Open chains
--
-- The editor smooths spans, not loops. A span fed to the closed-ring passes above would be treated
-- as joined end to end: a phantom corner at both ends and a midpoint inserted across the gap. The
-- open versions never wrap, and never move either endpoint - those are where the span joins the
-- rest of the network, so moving one would tear the connection away from whatever it lined up with.
-- ---------------------------------------------------------------------------------------------

--- Turn angle in degrees at an interior point of an open chain. Endpoints have no defined turn, so
--- they report 0 and are never eligible for anything.
local function openTurnDeg(points, i)
    if i <= 1 or i >= #points then
        return 0
    end
    local prev, cur, nxt = points[i - 1], points[i], points[i + 1]
    if distanceBetween(prev, cur) < 1e-6 or distanceBetween(cur, nxt) < 1e-6 then
        return 0
    end
    return math.abs(math.deg(turnAngle(prev, cur, nxt)))
end

--- One Laplacian step over an open chain. Only points `isMovable` says may move do.
local function laplacianChainPass(points, weight, isMovable)
    local out = copyPoints(points)
    for i = 2, #points - 1 do
        if isMovable(i) then
            local prev, cur, nxt = points[i - 1], points[i], points[i + 1]
            out[i].x = cur.x + weight * ((prev.x + nxt.x) * 0.5 - cur.x)
            out[i].z = cur.z + weight * ((prev.z + nxt.z) * 0.5 - cur.z)
        end
    end
    return out
end

local function taubinChainPass(points, isMovable)
    return laplacianChainPass(laplacianChainPass(points, TAUBIN_LAMBDA, isMovable), TAUBIN_MU, isMovable)
end

--- Open-chain refine-and-smooth: insert a midpoint after each eligible interior point, then run a
--- Taubin pass. Both endpoints are left exactly where they were.
function ADOffsetGeometry.smoothOpenChain(points, order, minAngleDeg, maxAngleDeg)
    order = order or 2
    minAngleDeg = minAngleDeg or 2
    maxAngleDeg = maxAngleDeg or 180

    local current = copyPoints(points)
    for _ = 1, order do
        if #current < 4 then
            break
        end

        local function eligible(pts, i)
            local turn = openTurnDeg(pts, i)
            return turn > minAngleDeg and turn < maxAngleDeg
        end

        local refined = {}
        for i = 1, #current do
            refined[#refined + 1] = copyPoint(current[i])
            if i < #current and eligible(current, i) then
                local cur, nxt = current[i], current[i + 1]
                refined[#refined + 1] = { x = (cur.x + nxt.x) * 0.5, z = (cur.z + nxt.z) * 0.5 }
            end
        end

        local movable = {}
        for i = 1, #refined do
            movable[i] = eligible(refined, i)
        end
        current = taubinChainPass(refined, function(i) return movable[i] end)
    end
    return current
end

--- Re-space an open chain so density follows curvature. Unlike thinToAdaptiveSpacing this can add
--- points as well as drop them, which is what normalising a span's spacing needs: a stretch that is
--- too coarse through a corner cannot be fixed by thinning. Both endpoints are emitted exactly, and
--- y is interpolated along the run where the source has it.
function ADOffsetGeometry.resampleOpenChainByCurvature(points, minSpacing, maxSpacing, tolerance)
    local n = #points
    if n < 3 then
        return copyPoints(points)
    end
    minSpacing, maxSpacing = sanitiseSpacingBand(minSpacing, maxSpacing)
    tolerance = sanitiseTolerance(tolerance)

    local target = {}
    target[1] = maxSpacing
    target[n] = maxSpacing
    for i = 2, n - 1 do
        target[i] = spacingForCurvature(points[i - 1], points[i], points[i + 1], minSpacing, maxSpacing, tolerance)
    end

    local segmentLength = {}
    for i = 1, n - 1 do
        segmentLength[i] = distanceBetween(points[i], points[i + 1])
    end

    local out = { copyPoint(points[1]) }
    local segment, along = 1, 0

    while true do
        -- take the spacing from whichever end of the current segment is nearer
        local step = target[segment]
        if segmentLength[segment] > EPS and along > segmentLength[segment] * 0.5 then
            step = target[segment + 1]
        end

        local walkSegment, walkAlong, remaining = segment, along, step
        while walkSegment <= n - 1 and remaining > segmentLength[walkSegment] - walkAlong do
            remaining = remaining - (segmentLength[walkSegment] - walkAlong)
            walkAlong = 0
            walkSegment = walkSegment + 1
        end
        if walkSegment > n - 1 then
            break
        end

        -- Sanitising the band should make a zero step impossible, but this loop only terminates by
        -- advancing, so verify it actually did rather than trust that. Anything non-advancing -
        -- a NaN that slipped through, a run of zero-length segments - stops here instead of
        -- emitting points until the process runs out of memory.
        local previousSegment, previousAlong = segment, along
        segment, along = walkSegment, walkAlong + remaining
        if segment == previousSegment and along <= previousAlong + 1e-9 then
            break
        end

        local tail = segmentLength[segment] - along
        for k = segment + 1, n - 1 do
            tail = tail + segmentLength[k]
        end
        if tail < minSpacing * 0.5 then
            break
        end

        local a, b = points[segment], points[segment + 1]
        local fraction = segmentLength[segment] > EPS and (along / segmentLength[segment]) or 0
        local p = {
            x = a.x + (b.x - a.x) * fraction,
            z = a.z + (b.z - a.z) * fraction,
        }
        if a.y ~= nil and b.y ~= nil then
            p.y = a.y + (b.y - a.y) * fraction
        end
        out[#out + 1] = p
    end

    out[#out + 1] = copyPoint(points[n])
    return out
end

--- Relax an open chain in place: move the points, never add or remove any.
---
--- Preserving the point count is what makes this safe on a real network. A rebuild-based smooth has
--- to delete the interior and lay down new points, so it must refuse any span containing a junction
--- or a map marker - which on a real network is most spans. Moving existing points breaks no
--- connections and loses no markers, so nothing has to be refused; the caller pins whatever must
--- not move via `pinned`, a set of indices. Endpoints never move regardless.
---
--- Each iteration is a Taubin pair rather than a plain Laplacian pass, so more iterations means
--- smoother rather than shorter - strength stays predictable instead of dragging the run toward a
--- straight line a little further every pass.
function ADOffsetGeometry.relaxOpenChain(points, iterations, pinned)
    iterations = iterations or 1
    pinned = pinned or {}
    local current = copyPoints(points)
    if #current < 3 then
        return current
    end
    local function isMovable(i)
        return not pinned[i]
    end
    for _ = 1, iterations do
        current = taubinChainPass(current, isMovable)
    end
    return current
end

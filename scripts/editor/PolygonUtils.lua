--[[
ADPolygonUtils - generic 2D polygon math over {x=, z=} point arrays.
No dependency on AutoDrive/vehicle/graph state - pure functions for basic polygon cleanup
(closing-vertex dedup, signed area, RDP simplification) used ahead of ADOffsetGeometry's
offset/corner-rounding/adaptive-spacing pipeline.
]]

ADPolygonUtils = {}

local function dist2D(a, b)
    return MathUtil.vector2Length(a.x - b.x, a.z - b.z)
end

--- Drops a duplicated closing vertex (last point coincides with the first) if present.
function ADPolygonUtils.stripDuplicateClosingVertex(points)
    if points == nil or #points < 2 then
        return points
    end

    if dist2D(points[1], points[#points]) < 0.05 then
        local cleaned = {}
        for i = 1, #points - 1 do
            cleaned[i] = points[i]
        end
        return cleaned
    end

    return points
end

--- Shoelace formula. Sign indicates winding order (consistent within this module, not asserted
--- to match any particular engine convention).
function ADPolygonUtils.getSignedArea(points)
    local n = #points
    if n < 3 then
        return 0
    end

    local area = 0
    for i = 1, n do
        local p1 = points[i]
        local p2 = points[(i % n) + 1]
        area = area + (p1.x * p2.z - p2.x * p1.z)
    end

    return area * 0.5
end

local function perpendicularDistance(point, lineStart, lineEnd)
    local dx = lineEnd.x - lineStart.x
    local dz = lineEnd.z - lineStart.z
    local lineLen = MathUtil.vector2Length(dx, dz)

    if lineLen < 1e-6 then
        return dist2D(point, lineStart)
    end

    local numerator = math.abs(dx * (lineStart.z - point.z) - (lineStart.x - point.x) * dz)
    return numerator / lineLen
end

-- Standard recursive RDP over an open chain (chain[1] and chain[#chain] are fixed endpoints).
local function rdpOpenChain(chain, epsilon)
    local n = #chain
    if n < 3 then
        return chain
    end

    local maxDist = -1
    local maxIndex = 1
    for i = 2, n - 1 do
        local d = perpendicularDistance(chain[i], chain[1], chain[n])
        if d > maxDist then
            maxDist = d
            maxIndex = i
        end
    end

    if maxDist > epsilon then
        local left = {}
        for i = 1, maxIndex do
            left[#left + 1] = chain[i]
        end
        local right = {}
        for i = maxIndex, n do
            right[#right + 1] = chain[i]
        end

        local leftSimplified = rdpOpenChain(left, epsilon)
        local rightSimplified = rdpOpenChain(right, epsilon)

        local result = {}
        for i = 1, #leftSimplified - 1 do
            result[#result + 1] = leftSimplified[i]
        end
        for i = 1, #rightSimplified do
            result[#result + 1] = rightSimplified[i]
        end
        return result
    else
        return { chain[1], chain[n] }
    end
end

-- Builds the forward, wrap-around sub-chain of a closed ring from fromIndex to toIndex inclusive.
local function ringSlice(points, fromIndex, toIndex)
    local n = #points
    local slice = {}
    local i = fromIndex
    while true do
        slice[#slice + 1] = points[i]
        if i == toIndex then
            break
        end
        i = (i % n) + 1
    end
    return slice
end

--- Ramer-Douglas-Peucker simplification adapted for a closed ring: splits the ring into two
--- open chains at its two most-distant points, simplifies each independently, then recombines.
--- Removes near-duplicate/collinear vertices that would otherwise make insetPolygon unstable.
function ADPolygonUtils.simplifyClosedPolygonRDP(points, epsilon)
    epsilon = epsilon or 0.5
    local n = #points
    if n < 4 then
        return points
    end

    local bestDist = -1
    local bestI, bestJ = 1, 2
    for i = 1, n do
        for j = i + 1, n do
            local d = dist2D(points[i], points[j])
            if d > bestDist then
                bestDist = d
                bestI, bestJ = i, j
            end
        end
    end

    local chainA = ringSlice(points, bestI, bestJ)
    local chainB = ringSlice(points, bestJ, bestI)

    local simplifiedA = rdpOpenChain(chainA, epsilon)
    local simplifiedB = rdpOpenChain(chainB, epsilon)

    local result = {}
    for i = 1, #simplifiedA - 1 do
        result[#result + 1] = simplifiedA[i]
    end
    for i = 1, #simplifiedB - 1 do
        result[#result + 1] = simplifiedB[i]
    end

    if #result < 3 then
        return points
    end

    return result
end


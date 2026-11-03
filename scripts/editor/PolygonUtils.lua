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

--- Ramer-Douglas-Peucker over an open chain, exposed for the straighten tool.
---
--- Keeps the point of greatest perpendicular deviation whenever that deviation exceeds `epsilon`,
--- and discards everything within tolerance. That is exactly "flatten the noise but keep a genuine
--- bend": a span that is mostly straight with one real deviation collapses to its endpoints plus
--- that deviation, by construction rather than by any special case. Raise epsilon past the bend's
--- own depth and it flattens too, which is the natural way to say "straighten that as well".
function ADPolygonUtils.simplifyOpenChainRDP(points, epsilon)
    if points == nil or #points < 3 or epsilon == nil or epsilon <= 0 then
        return points
    end
    return rdpOpenChain(points, epsilon)
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


--- Field outlines with islands cut into them. A mapper leaves a pylon or a tree patch out of a field
--- by running the field's one outline ring in along a thin slit, around the patch, and back out right
--- beside where it went in. A loop that follows that ring drives the slit and rings the patch (issue 31).
---
--- Where the ring passes within `width` of itself, it splits there into two rings. The part that is an
--- island goes round the other way (the field stays on the same side of the line, so a patch inside it
--- is walked the opposite way round) - that part is dropped, slit and all. A part thinner than half of
--- `width` on average (a slit left on its own, a needle) is dropped too. A narrow neck of real field is
--- neither, so it stays. Returns the ring and the number of islands and slivers left out; the input
--- comes back untouched when nothing was left out.
function ADPolygonUtils.removeSlitIslands(points, width)
    width = width or 3
    local n0 = #points
    if n0 < 6 then
        return points, 0, 0
    end
    -- Even spacing first, so a slit whose two sides have their points at different places still has
    -- a pair of points close together across it.
    local step = width / 2
    local ring = {}
    for i = 1, n0 do
        local a, b = points[i], points[(i % n0) + 1]
        local d = dist2D(a, b)
        local parts = math.max(1, math.ceil(d / step))
        for k = 0, parts - 1 do
            local t = k / parts
            ring[#ring + 1] = { x = a.x + (b.x - a.x) * t, z = a.z + (b.z - a.z) * t }
        end
    end

    local islands, slivers = 0, 0
    for _ = 1, 500 do
        local n = #ring
        if n < 6 then
            break
        end
        -- Running sums: the cross terms and the path length from point 1, so any part's area and length
        -- cost nothing.
        local cross, len = { 0 }, { 0 }
        for k = 2, n do
            local a, b = ring[k - 1], ring[k]
            cross[k] = cross[k - 1] + (a.x * b.z - b.x * a.z)
            len[k] = len[k - 1] + dist2D(a, b)
        end
        local last, first = ring[n], ring[1]
        local total = (cross[n] + (last.x * first.z - first.x * last.z)) * 0.5
        local totalLen = len[n] + dist2D(last, first)
        local sign = total >= 0 and 1 or -1

        local grid = {}
        for k = 1, n do
            local key = math.floor(ring[k].x / width) .. "," .. math.floor(ring[k].z / width)
            local cellList = grid[key]
            if cellList == nil then
                cellList = {}
                grid[key] = cellList
            end
            cellList[#cellList + 1] = k
        end

        local best = nil
        local function consider(i, j, area, path, inner)
            if math.abs(area) >= math.abs(total) * 0.5 or path < 1e-6 then
                return
            end
            local isIsland = area * sign < 0
            local isSliver = 2 * math.abs(area) / path < width / 2
            if (isIsland or isSliver) and (best == nil or path > best.path) then
                best = { i = i, j = j, path = path, inner = inner,
                    island = isIsland and math.abs(area) > width * width }
            end
        end
        for i = 1, n do
            local p = ring[i]
            local cx, cz = math.floor(p.x / width), math.floor(p.z / width)
            for dx = -1, 1 do
                for dz = -1, 1 do
                    local cellList = grid[(cx + dx) .. "," .. (cz + dz)]
                    if cellList ~= nil then
                        for _, j in ipairs(cellList) do
                            local q = ring[j]
                            if j > i and dist2D(p, q) < width then
                                local innerLen = len[j] - len[i]
                                local outerLen = totalLen - innerLen
                                -- Two points just along the line from each other are not a pinch.
                                if innerLen > 4 * width and outerLen > 4 * width then
                                    local areaA = (cross[j] - cross[i] + (q.x * p.z - p.x * q.z)) * 0.5
                                    consider(i, j, areaA, innerLen, true)
                                    consider(i, j, total - areaA, outerLen, false)
                                end
                            end
                        end
                    end
                end
            end
        end
        if best == nil then
            break
        end
        local nextRing = {}
        if best.inner then
            -- drop i+1 .. j, the ring goes straight from point i on to point j+1
            for k = 1, best.i do nextRing[#nextRing + 1] = ring[k] end
            for k = best.j + 1, n do nextRing[#nextRing + 1] = ring[k] end
        else
            for k = best.i, best.j do nextRing[#nextRing + 1] = ring[k] end
        end
        ring = nextRing
        if best.island then
            islands = islands + 1
        else
            slivers = slivers + 1
        end
    end

    if islands + slivers == 0 then
        return points, 0, 0
    end
    return ring, islands, slivers
end

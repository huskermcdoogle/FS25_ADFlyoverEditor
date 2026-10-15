--[[
ADSplinePath - the multi-point spline's curve, with no AutoDrive spline code behind it.

The curve passes through every clicked point. Each stretch between two points is a cubic Hermite
piece; the heading at an inner point is the bisector of the two chords meeting there, and each
piece's handles are as long as the chord itself, which bends like a circle arc rather than
overshooting when the points are unevenly spaced. An end with a given heading (a spline snapped
onto a road) leaves or arrives along it; a free end heads straight along its end chord.

Pure 2D maths on {x=, z=} tables (y is carried along linearly, as a height hint only), so it runs
offline as well as in game.
]]

ADSplinePath = {}

-- Samples per piece of the dense curve. Plenty for a smooth line and the length walk.
ADSplinePath.SAMPLES = 32

local function unit(dx, dz)
    local len = math.sqrt(dx * dx + dz * dz)
    if len < 1e-6 then
        return 0, 0, 0
    end
    return dx / len, dz / len, len
end

--- Heading (unit x, z) of the curve at every point. startDir / endDir are optional {x=, z=} unit
--- vectors that pin the two ends.
function ADSplinePath.headings(points, startDir, endDir)
    local n = #points
    local dirs = {}
    for i = 2, n - 1 do
        local ax, az = unit(points[i].x - points[i - 1].x, points[i].z - points[i - 1].z)
        local bx, bz = unit(points[i + 1].x - points[i].x, points[i + 1].z - points[i].z)
        local hx, hz, len = unit(ax + bx, az + bz)
        if len == 0 then
            hx, hz = bx, bz   -- a hairpin straight back: carry on along the next chord
        end
        dirs[i] = { x = hx, z = hz }
    end

    -- Free ends head straight along the end chord. Mirroring the neighbour's heading (a parabola's
    -- end) is the textbook choice, but it bows the first and last stretch out to one side of the
    -- line between the points - the curve wanders where the player drew a straight lead-in.
    local function freeEnd(fromIdx, toIdx)
        local cx, cz = unit(points[toIdx].x - points[fromIdx].x, points[toIdx].z - points[fromIdx].z)
        return { x = cx, z = cz }
    end

    if startDir ~= nil then
        dirs[1] = { x = startDir.x, z = startDir.z }
    else
        dirs[1] = freeEnd(1, 2)
    end
    if endDir ~= nil then
        dirs[n] = { x = endDir.x, z = endDir.z }
    else
        dirs[n] = freeEnd(n - 1, n)
    end
    return dirs
end

--- The dense curve: a list of { x, z, y, seg } where seg is the piece (1 = between points 1 and 2).
--- Needs at least two points.
function ADSplinePath.build(points, startDir, endDir)
    local n = #points
    if n < 2 then
        return {}
    end
    local dirs = ADSplinePath.headings(points, startDir, endDir)
    local out = { { x = points[1].x, z = points[1].z, y = points[1].y, seg = 1 } }
    local S = ADSplinePath.SAMPLES
    for i = 1, n - 1 do
        local p0, p1 = points[i], points[i + 1]
        local _, _, L = unit(p1.x - p0.x, p1.z - p0.z)
        local m0x, m0z = dirs[i].x * L, dirs[i].z * L
        local m1x, m1z = dirs[i + 1].x * L, dirs[i + 1].z * L
        for k = 1, S do
            local t = k / S
            local t2, t3 = t * t, t * t * t
            local h00 = 2 * t3 - 3 * t2 + 1
            local h10 = t3 - 2 * t2 + t
            local h01 = -2 * t3 + 3 * t2
            local h11 = t3 - t2
            out[#out + 1] = {
                x = h00 * p0.x + h10 * m0x + h01 * p1.x + h11 * m1x,
                z = h00 * p0.z + h10 * m0z + h01 * p1.z + h11 * m1z,
                y = (p0.y ~= nil and p1.y ~= nil) and (p0.y + (p1.y - p0.y) * t) or (p0.y or p1.y),
                seg = i,
            }
        end
    end
    return out
end

--- Even spacing along the dense curve. Returns the INNER points only (the two ends are laid
--- separately), as close to `spacing` apart as a whole number of steps allows.
function ADSplinePath.resample(curve, spacing)
    if #curve < 2 then
        return {}
    end
    local total = 0
    local acc = { 0 }
    for i = 2, #curve do
        local dx, dz = curve[i].x - curve[i - 1].x, curve[i].z - curve[i - 1].z
        total = total + math.sqrt(dx * dx + dz * dz)
        acc[i] = total
    end
    local steps = math.max(1, math.floor(total / math.max(0.5, spacing) + 0.5))
    local stepLen = total / steps
    local out = {}
    local j = 2
    for k = 1, steps - 1 do
        local target = k * stepLen
        while j < #curve and acc[j] < target do
            j = j + 1
        end
        local a, b = curve[j - 1], curve[j]
        local span = acc[j] - acc[j - 1]
        local f = span > 1e-9 and (target - acc[j - 1]) / span or 0
        out[#out + 1] = {
            x = a.x + (b.x - a.x) * f,
            z = a.z + (b.z - a.z) * f,
            y = (a.y ~= nil and b.y ~= nil) and (a.y + (b.y - a.y) * f) or (a.y or b.y),
        }
    end
    return out, total
end

--- Which piece of the curve passes closest to (x, z), how close, and the closest point on it
--- (x, z, y). nil when the curve is empty.
function ADSplinePath.nearestPiece(curve, x, z)
    local bestSeg, bestD2, bx, bz, by = nil, math.huge, nil, nil, nil
    for i = 2, #curve do
        local a, b = curve[i - 1], curve[i]
        local vx, vz = b.x - a.x, b.z - a.z
        local len2 = vx * vx + vz * vz
        local t = len2 > 1e-9 and ((x - a.x) * vx + (z - a.z) * vz) / len2 or 0
        t = math.max(0, math.min(1, t))
        local cx, cz = a.x + vx * t, a.z + vz * t
        local d2 = (cx - x) * (cx - x) + (cz - z) * (cz - z)
        if d2 < bestD2 then
            bestSeg, bestD2, bx, bz = b.seg, d2, cx, cz
            by = (a.y ~= nil and b.y ~= nil) and (a.y + (b.y - a.y) * t) or (a.y or b.y)
        end
    end
    if bestSeg == nil then
        return nil
    end
    return bestSeg, math.sqrt(bestD2), bx, bz, by
end

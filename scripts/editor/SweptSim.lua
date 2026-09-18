--[[
SweptSim - a digital twin of the stock AutoDrive follower (docs/swept-path-spec.md §5).

Pure Lua, no engine calls: it runs identically inside the game (preview prediction) and offline
under lua.exe against recorded runs (calibration). Given a waypoint polyline, a rig and a driver
profile, it drives the rig along the line the way AutoDrive would and returns where every part of it
actually went - the tow's rear axle and steering node, the hitch, the trailer axle - plus the
steering state, so the swept region and the cut-in can be measured instead of guessed.

Coordinates: world x/z, heading `theta` such that forward = (sin theta, cos theta) - the same
bearing convention as the junction tool and AutoDrive's own look-ahead. Left turn = theta increases.

Model, transcribed rather than approximated:
  * target point: ADDrivePathModule:getLookAheadTarget - walk `lookAhead` metres along the polyline
    from the current waypoint, measured from the STEERING NODE.
  * waypoint advance: ADDrivePathModule:isCloseToWaypoint - the current (or next) waypoint is
    reached when the steering node is within `minDistance` of it, or the route bends >= 135 deg.
  * steering: AIVehicleUtil.driveInDirection - bearing to the target sets a demand PROPORTIONAL to
    the bearing angle, saturating at full lock once the target is `steerLimitDeg` off the nose;
    `rotatedTime` slews toward it at aiSteeringSpeed (1.0/s stock), and the wheel angle is
    rotatedTime/maxRotTime of full lock.
  * speed: ADDrivePathModule:getMaxSpeedForAngle over the next 20 points / 20 m, times cornerSpeed,
    and 10 km/h whenever the wheels are past 95% lock (getSpeedLimitBySteeringAngle).
  * tow: kinematic bicycle on the rear axle. Trailer: single-pivot tractrix from the hitch; the
    hitch offset is SIGNED (negative = behind the rear axle, a drawbar) so the drawbar's swing-out
    falls out of the same equation.
]]

SweptSim = {}

local S = SweptSim

--- A driver profile: the stock 3.0.0.8 follower. A future driver (the AutoDrive-fork rewrite) is a
--- second table with the same fields; the model never hardcodes these.
S.STOCK_DRIVER = {
    name = "stock-3.0.0.8",
    steerLimitDeg = 60,        -- bearing at which the demand saturates (DrivePathModule maxAngle)
    steerSlewPerSec = 1.0,     -- rotatedTime units per second (AIJobVehicle aiSteeringSpeed default)
    speedScanPoints = 20,      -- MAXLOOKAHEADPOINTS
    speedScanMetres = 20,      -- LOOKAHEADDISTANCE
    cornerSpeed = 1.0,         -- the cornerSpeed setting
    lockSpeedKmh = 10,         -- getSpeedLimitBySteeringAngle past 95% lock
    accel = 1.2,               -- m/s^2 toward the limit (motor model - calibration item)
    decel = 2.5,
    --- km/h for the sharpest angle ahead: ADDrivePathModule:getMaxSpeedForAngle.
    speedForAngle = function(angle)
        if angle < 5 then return math.huge end
        if angle < 50 then
            return 12 + 48 * (1 - math.max(0, math.min(25, angle - 5)) / 25)
        end
        return 3
    end,
}

--- A rig: the numbers the recorder measures (spec §4). All metres, offsets along the tow body axis
--- from the rear axle, positive forward.
--- minTurnRadius is the rear-axle radius at full lock; it sets the max wheel angle via the wheelbase.
S.EXAMPLE_RIG = {
    name = "Transtar II + trailer",
    wheelbase = 5.82, steerNodeOffset = 0.65, minTurnRadius = 4.3, maxRotTime = 1.05,
    lookAhead = 10.32, minDistance = 3.0,
    hitchOffset = -0.94, trailerLength = 8.39,
    towWidth = 2.5, trailerWidth = 2.5,
}

local function dist2d(ax, az, bx, bz)
    return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2)
end

local function wrapAngle(a)
    while a > math.pi do a = a - 2 * math.pi end
    while a < -math.pi do a = a + 2 * math.pi end
    return a
end

--- AutoDrive.angleBetween: signed degrees from vector a to vector b (as used by the speed scan and
--- the 135-degree advance rule).
local function angleBetween(ax, az, bx, bz)
    local la, lb = math.sqrt(ax * ax + az * az), math.sqrt(bx * bx + bz * bz)
    if la < 1e-9 or lb < 1e-9 then return 0 end
    local dot = (ax * bx + az * bz) / (la * lb)
    dot = math.max(-1, math.min(1, dot))
    local ang = math.deg(math.acos(dot))
    local cross = ax * bz - az * bx
    if cross < 0 then ang = -ang end
    return ang
end

--- ADDrivePathModule:getLookAheadTarget, from steering node (sx, sz) with current index i.
local function lookAheadTarget(path, i, sx, sz, lookAhead)
    local cur = path[i]
    if cur == nil then return sx, sz end
    local remaining = lookAhead - dist2d(sx, sz, cur.x, cur.z)
    local ahead, k = cur, 0
    local segLen = 0
    while remaining > segLen do
        remaining = remaining - segLen
        k = k + 1
        local nxt = path[i + k]
        if nxt == nil then break end
        cur, ahead = ahead, nxt
        segLen = dist2d(cur.x, cur.z, ahead.x, ahead.z)
    end
    local tx, tz = cur.x, cur.z
    if remaining > 0.1 and segLen > 0.1 then
        local l = math.min(remaining, segLen)
        local dx, dz = ahead.x - cur.x, ahead.z - cur.z
        local n = math.sqrt(dx * dx + dz * dz)
        tx, tz = tx + dx / n * l, tz + dz / n * l
    end
    return tx, tz
end

--- ADDrivePathModule:isCloseToWaypoint -> returns the new current index (advances by 1 at a time,
--- the way handleReachedWayPoint does).
local function advanceIndex(path, i, sx, sz, minDistance)
    local cur, nxt = path[i], path[i + 1]
    if cur == nil then return i end
    if dist2d(sx, sz, cur.x, cur.z) < minDistance then return i + 1 end
    if nxt ~= nil then
        if dist2d(sx, sz, nxt.x, nxt.z) < minDistance then return i + 1 end
        local ang = math.abs(angleBetween(nxt.x - cur.x, nxt.z - cur.z, cur.x - sx, cur.z - sz))
        if ang >= 135 then return i + 1 end
    end
    return i
end

--- ADDrivePathModule:getHighestApproachingAngle, from the tow's reference position.
local function highestAngleAhead(path, i, px, pz, driver)
    if i + 2 >= #path then return 0 end
    local cur = path[i]
    local base = dist2d(cur.x, cur.z, px, pz)
    local highest = 0
    for k = 1, driver.speedScanPoints do
        local ahead, mid, ref = path[i + k], path[i + k - 1], path[i + k - 2]
        if ahead == nil or mid == nil or ref == nil then break end
        local ang = math.abs(angleBetween(ahead.x - mid.x, ahead.z - mid.z, mid.x - ref.x, mid.z - ref.z))
        if dist2d(cur.x, cur.z, ahead.x, ahead.z) <= (driver.speedScanMetres - base) then
            if ang < 180 then highest = math.max(highest, ang) end
        else
            break
        end
    end
    return highest
end

--- Drive `rig` along `path` starting from `start` = { x, z, heading, trailerHeading, speed, rot }
--- (rear-axle pose; rot is the initial rotatedTime). Returns a table of steps:
---   { t, x, z, heading, sx, sz, hx, hz, ax, az, trailerHeading, rot, v, wp }
--- with positions of rear axle (x,z), steering node (sx,sz), hitch (hx,hz), trailer axle (ax,az).
--- opts.dt (s, default 0.016), opts.maxTime (s, default 240), opts.speedLimitKmh (the AD setting).
function S.simulate(path, rig, driver, start, opts)
    driver = driver or S.STOCK_DRIVER
    opts = opts or {}
    local dt = opts.dt or 0.016
    local maxT = opts.maxTime or 240
    local vCap = (opts.speedLimitKmh or 40) / 3.6
    local deltaMax = math.atan(rig.wheelbase / rig.minTurnRadius)
    local slewNorm = driver.steerSlewPerSec / (rig.maxRotTime or 1)   -- normalized lock units / s

    local x, z, th = start.x, start.z, start.heading
    local phi = start.trailerHeading or th
    local v = (start.speed or 0) / 3.6
    local s = (start.rot or 0) / (rig.maxRotTime or 1)                -- normalized steering [-1,1]
    local fx, fz = math.sin(th), math.cos(th)
    local hxPrev, hzPrev = x + fx * rig.hitchOffset, z + fz * rig.hitchOffset

    -- Current waypoint: AutoDrive starts on the closest one; from a run-in that is the one ahead.
    local i, bestd = 1, math.huge
    local sx0, sz0 = x + fx * rig.steerNodeOffset, z + fz * rig.steerNodeOffset
    for k, p in ipairs(path) do
        local d = dist2d(sx0, sz0, p.x, p.z)
        local ahead = (p.x - sx0) * fx + (p.z - sz0) * fz
        if ahead > -0.5 and d < bestd then bestd, i = d, k end
    end

    local out = {}
    local t = 0
    while t < maxT and i <= #path do
        fx, fz = math.sin(th), math.cos(th)
        local lx_, lz_ = math.cos(th), -math.sin(th)                  -- vehicle LEFT in world
        local sx, sz = x + fx * rig.steerNodeOffset, z + fz * rig.steerNodeOffset

        i = advanceIndex(path, i, sx, sz, rig.minDistance or 1.8)
        if i > #path then break end

        -- Steering demand from the look-ahead target, AIVehicleUtil-style.
        local tx, tz = lookAheadTarget(path, i, sx, sz, rig.lookAhead)
        local dx, dz = tx - sx, tz - sz
        local n = math.sqrt(dx * dx + dz * dz)
        local sTarget = s
        if n > 1e-3 then
            local lz = (dx * fx + dz * fz) / n
            local lx = (dx * lx_ + dz * lz_) / n
            local ang = math.deg(math.acos(math.max(-1, math.min(1, lz))))
            local mag = math.min(ang / driver.steerLimitDeg, 1)
            sTarget = (lx > 0.00001) and mag or -mag
        end
        if sTarget > s then s = math.min(s + slewNorm * dt, sTarget)
        else s = math.max(s - slewNorm * dt, sTarget) end
        local delta = s * deltaMax

        -- Speed: the sharpest angle ahead, and the full-lock clamp.
        local limit = math.min(vCap, driver.speedForAngle(highestAngleAhead(path, i, x, z, driver)) * driver.cornerSpeed / 3.6)
        if math.abs(s) > 0.95 then limit = math.min(limit, driver.lockSpeedKmh / 3.6) end
        if v < limit then v = math.min(limit, v + driver.accel * dt)
        else v = math.max(limit, v - driver.decel * dt) end

        -- Integrate the tow (rear axle bicycle) ...
        local ds = v * dt
        x, z = x + fx * ds, z + fz * ds
        th = wrapAngle(th + ds * math.tan(delta) / rig.wheelbase)
        -- ... and the trailer from the hitch's motion (tractrix).
        local nfx, nfz = math.sin(th), math.cos(th)
        local hx, hz = x + nfx * rig.hitchOffset, z + nfz * rig.hitchOffset
        local vhx, vhz = hx - hxPrev, hz - hzPrev
        local tlx, tlz = math.cos(phi), -math.sin(phi)               -- trailer LEFT
        phi = wrapAngle(phi + (vhx * tlx + vhz * tlz) / rig.trailerLength)
        hxPrev, hzPrev = hx, hz
        local ax, az = hx - math.sin(phi) * rig.trailerLength, hz - math.cos(phi) * rig.trailerLength

        t = t + dt
        out[#out + 1] = { t = t, x = x, z = z, heading = th, sx = sx, sz = sz, hx = hx, hz = hz,
            ax = ax, az = az, trailerHeading = phi, rot = s * (rig.maxRotTime or 1), v = v * 3.6, wp = i,
            tx = tx, tz = tz }
    end
    return out
end

--- Signed lateral offset of point (px,pz) from the polyline `path` (+ = left of the path's direction),
--- measured against the nearest segment. Used for cut-in metrics.
function S.offsetFromPath(path, px, pz)
    local best, signed = math.huge, 0
    for k = 1, #path - 1 do
        local a, b = path[k], path[k + 1]
        local dx, dz = b.x - a.x, b.z - a.z
        local l2 = dx * dx + dz * dz
        if l2 > 1e-9 then
            local u = math.max(0, math.min(1, ((px - a.x) * dx + (pz - a.z) * dz) / l2))
            local qx, qz = a.x + u * dx, a.z + u * dz
            local d = dist2d(px, pz, qx, qz)
            if d < best then
                best = d
                -- left of direction (dx,dz) is (dz, -dx)... using the same convention as the sim:
                -- left = (cos th, -sin th) with forward (sin th, cos th) = (dx, dz)/l -> left = (dz, -dx)/l
                local side = (px - qx) * dz - (pz - qz) * dx
                signed = (side >= 0) and d or -d
            end
        end
    end
    return signed
end

--- Convenience: the extreme offsets over a track. Returns maxLeft (>= 0), maxRight (>= 0).
function S.extremes(path, points, xk, zk)
    local maxL, maxR = 0, 0
    for _, p in ipairs(points) do
        local o = S.offsetFromPath(path, p[xk], p[zk])
        if o > maxL then maxL = o end
        if -o > maxR then maxR = -o end
    end
    return maxL, maxR
end

return S

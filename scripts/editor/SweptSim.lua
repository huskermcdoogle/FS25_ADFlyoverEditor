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
  * speed: ADDrivePathModule:getMaxSpeedForAngle over the next 20 points, within the scan distance
    getCurrentLookAheadDistance gives for the rig's mass and speed, times cornerSpeed, and 10 km/h
    whenever the wheels are past 95% lock (getSpeedLimitBySteeringAngle). Recomputed every 4 frames.
  * tow: kinematic bicycle on the rear axle. Trailer: single-pivot tractrix from the hitch; the
    hitch offset is SIGNED (negative = behind the rear axle, a drawbar) so the drawbar's swing-out
    falls out of the same equation.
]]

SweptSim = {}

local S = SweptSim

--- A driver profile: the stock follower, read from AutoDrive 3.0.1.2. Everything used here is the
--- same in 3.0.0.8 - DrivePathModule differs between the two only in debug-print guards. A future
--- driver (the AutoDrive-fork rewrite) is a second table with the same fields; the model never
--- hardcodes these.
S.STOCK_DRIVER = {
    name = "stock-3.0.1.2",
    steerLimitDeg = 60,        -- bearing at which the demand saturates (DrivePathModule maxAngle)
    steerSlewPerSec = 1.0,     -- rotatedTime units per second (AIJobVehicle aiSteeringSpeed default)
    speedScanPoints = 20,      -- MAXLOOKAHEADPOINTS
    -- How far the bend scan reaches. Not a fixed 20 m: LOOKAHEADDISTANCE (20) is only the base that
    -- getCurrentLookAheadDistance scales - see scanDistance. The first twin used the bare 20 m and
    -- braked late: a corner of 45-degree bends, capped at 12 km/h, was driven at ~27 km/h. Setting
    -- speedScanMetres pins the window instead (tools/xt-study/curves.lua brackets with 20/50/100 m).
    speedScanMetres = nil,
    capEverySec = 4 / 60,      -- the caps are recomputed every PERF_FRAMES_HIGH (4) frames, at 60 fps
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
    --- metres the bend scan reaches: ADDrivePathModule:getCurrentLookAheadDistance. totalMassT is the
    --- rig's getTotalMass(false) - tow, trailer and load, in tonnes. Below 10 km/h the mass factor
    --- drops to the speed factor, so a crawling rig sees only 8-20 m whatever it weighs.
    scanDistance = function(totalMassT, speedKmh)
        local massFactor = math.max(1, math.min(3, (totalMassT + 20) / 30))
        local speedFactor = math.max(0.25, math.min(4, (speedKmh + 10) / 20))
        if speedFactor <= 1 then massFactor = math.min(speedFactor, massFactor) end
        return math.min(20 * massFactor * speedFactor, 150)
    end,
}

--- A rig: the numbers the recorder measures (spec §4). All metres, offsets along the tow body axis
--- from the rear axle, positive forward.
--- minTurnRadius is the rear-axle radius at full lock; it sets the max wheel angle via the wheelbase.
--- The preset below is the Transtar II + SKS 30/1050 semi as CAPTURED in game (FlyoverSweptRig).
--- Two corrections from the first hand-copied version, both found by the capture: the hitch is a
--- FIFTH WHEEL 0.93 m AHEAD of the rear axle (it was entered as a drawbar, -0.94 - the whole of the
--- "tyre slip" over-prediction attributed to that in the spec's first calibration note was actually
--- that sign), and the trailer's pivot is the centroid of its axle group (7.08 m), not its rearmost
--- axle (8.39 m). Full lock is the CLEAN measurement from looptest.xml (15 s held hard over, nothing
--- to hit): a least-squares circle fit over the sustained-lock samples gives R = 6.26 m for the rear
--- axle, matching vehicle.maxTurningRadius (6.1 m) within 0.15 m - see captureRig for why that field
--- is now trusted over any wheel-angle formula. maxRotTime is the largest rotatedTime this vehicle was
--- actually seen to reach (1.18, from the same recording) - not a normalized +-1, so it is read as
--- whatever the game's own units are and used as-is, never divided by anything.
--- totalMass (tonnes) is the semi LOADED - the slowest it will take a bend, so the most it cuts in:
--- Transtar 4.3 t + trailer 6.9 t + 59.4 m3 of wheat at 0.78 t/m3 (46.3 t), from the game's own
--- vehicle and fill-type files. It is also what a rig with no measured mass is given.
S.EXAMPLE_RIG = {
    name = "Transtar II + SKS 30/1050 (preset)",
    wheelbase = 5.84, steerNodeOffset = 0.66, minTurnRadius = 6.26, maxRotTime = 1.18,
    lookAhead = 10.32, minDistance = 5.9,
    hitchOffset = 0.93, trailerLength = 7.08,
    towWidth = 2.7, trailerWidth = 2.6,
    totalMass = 57.5,
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

--- ADDrivePathModule:getHighestApproachingAngle, from the tow's reference position, scanning at
--- most `maxPoints` points within `scanMetres` (straight-line, from the current waypoint).
local function highestAngleAhead(path, i, px, pz, scanMetres, maxPoints)
    if i + 2 >= #path then return 0 end
    local cur = path[i]
    local base = dist2d(cur.x, cur.z, px, pz)
    local highest = 0
    for k = 1, maxPoints do
        local ahead, mid, ref = path[i + k], path[i + k - 1], path[i + k - 2]
        if ahead == nil or mid == nil or ref == nil then break end
        local ang = math.abs(angleBetween(ahead.x - mid.x, ahead.z - mid.z, mid.x - ref.x, mid.z - ref.z))
        if dist2d(cur.x, cur.z, ahead.x, ahead.z) <= (scanMetres - base) then
            if ang < 180 then highest = math.max(highest, ang) end
        else
            break
        end
    end
    return highest
end

--- Drive `rig` along `path` starting from `start` = { x, z, heading, trailerHeading, speed, rot }
--- (rear-axle pose; rot is the initial rotatedTime). Returns a table of steps:
---   { t, x, z, heading, sx, sz, hx, hz, ax, az, trailerHeading, rot, v, wp, tx, tz, cap, scan }
--- with positions of rear axle (x,z), steering node (sx,sz), hitch (hx,hz), trailer axle (ax,az),
--- the look-ahead target (tx,tz), the speed cap in force (km/h) and the bend scan's reach (m).
--- opts.dt (s, default 0.016), opts.maxTime (s, default 240), opts.speedLimitKmh (the AD setting),
--- opts.routeEnds (the path's last point is AutoDrive's destination, so it slows to arrive - for
--- replaying a recorded run; off for a junction preview, whose run-out is not a real route end).
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
    local capLimit, capDue, scan = vCap, 0, 0
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
            -- rig.steerLimitDeg overrides the driver's generic 60 deg when the CAPTURED vehicle's own
            -- maxRotation is known - exactly the per-vehicle override DrivePathModule itself applies
            -- (maxAngle = 60 unless vehicle.maxRotation says otherwise). Falls back to the driver's
            -- figure for a rig with no capture (the baked-in preset, an older saved rig).
            local mag = math.min(ang / (rig.steerLimitDeg or driver.steerLimitDeg), 1)
            sTarget = (lx > 0.00001) and mag or -mag
        end
        if sTarget > s then s = math.min(s + slewNorm * dt, sTarget)
        else s = math.max(s - slewNorm * dt, sTarget) end
        local delta = s * deltaMax

        -- Speed: the sharpest angle ahead and the full-lock clamp, recomputed every capEverySec and
        -- held in between. followWaypoints itself puts the plain speed setting back on the other
        -- three frames, but the cap holds in the game anyway: clean90.xml, first corner, braked
        -- 21.7 -> 10.3 km/h at ~5 m/s2 and then held 10.3-10.7 against the 10 km/h lock cap. The
        -- same corner shows no sign of AutoDrive's 6 km/h braking dead band (MAX_SPEED_DEVIATION):
        -- the game's own limiter (WheelsUtil.updateWheelsPhysics) brakes on ANY overspeed, so the
        -- dead band is not modelled.
        if t >= capDue then
            capDue = t + (driver.capEverySec or 0)
            scan = driver.speedScanMetres or driver.scanDistance(rig.totalMass or S.EXAMPLE_RIG.totalMass, v * 3.6)
            local ang = highestAngleAhead(path, i, x, z, scan, driver.speedScanPoints)
            capLimit = math.min(vCap, driver.speedForAngle(ang) * driver.cornerSpeed / 3.6)
            -- Arriving (opts.routeEnds): once the last point is within 40 points and nearer along the
            -- line than the scan reaches, the limit is held between min(8, 2 + metres left) and
            -- max(8, 2 + metres left) km/h (followWaypoints, getDistanceToLastWaypoint(40)).
            if opts.routeEnds and i + 40 >= #path then
                local left = 0
                for k = i + 1, math.min(#path, i + 39) do
                    left = left + dist2d(path[k - 1].x, path[k - 1].z, path[k].x, path[k].z)
                end
                if left < scan then
                    capLimit = math.max(math.min(8, 2 + left) / 3.6, math.min(capLimit, math.max(8, 2 + left) / 3.6))
                end
            end
            if math.abs(s) > 0.95 then capLimit = math.min(capLimit, driver.lockSpeedKmh / 3.6) end
        end
        local limit = capLimit
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
            tx = tx, tz = tz, cap = capLimit * 3.6, scan = scan }
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

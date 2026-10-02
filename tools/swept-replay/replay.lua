-- Replay a swept-path recording through SweptSim and compare SPEED with what the truck really did.
--
--   lua replay.lua <SweptSim.lua> <recording.xml> [speed setting km/h] [variant ...]
--
-- The recording (FlyoverSweptRecord / FlyoverSweptSave) stores, every 0.25 m, the current
-- waypoint's position. Their sequence IS the line AutoDrive was following, so the line is rebuilt
-- from it - no saved network needed. The run is cut at every stop (AutoDrive waiting), each piece
-- is driven by the twin from the recorded pose and speed, and the twin's speed is read back at the
-- same distance along the line as each recorded sample.
--
-- Recorded speed is measured from the rear axle's travel over time, not the stored v (that is the
-- game's smoothed getLastSpeed, which lags by ~1 km/h when braking).
--
-- Variants (any mix), to test a model change without editing SweptSim:
--   scan=N      fixed N m bend scan (20 = the first twin)       mass=T     rig mass, tonnes
--   decel=A     braking, m/s2                                   accel=A    m/s2
--   slew=N      steering, rotatedTime units per second          steerlimit=D  the rig's maxRotation, deg
-- The rig is SweptSim.EXAMPLE_RIG (the Transtar II + SKS 30/1050 the recordings were made with).
local SIM, REC, SETTING = arg[1], arg[2], tonumber(arg[3] or 40)
dofile(SIM)
local S = SweptSim

local driver, rig = {}, {}
for k, v in pairs(S.STOCK_DRIVER) do driver[k] = v end
for k, v in pairs(S.EXAMPLE_RIG) do rig[k] = v end
local label = {}
for i = 4, #arg do
    local k, v = arg[i]:match("^(%w+)=(%S+)$")
    v = tonumber(v)
    if k == "scan" then driver.speedScanMetres = v
    elseif k == "mass" then rig.totalMass = v
    elseif k == "decel" then driver.decel = v
    elseif k == "accel" then driver.accel = v
    elseif k == "slew" then driver.steerSlewPerSec = v
    elseif k == "steerlimit" then rig.steerLimitDeg = v
    else error("unknown variant " .. tostring(arg[i])) end
    label[#label + 1] = arg[i]
end

-- ------------------------------------------------------------------------------ the recording
local f = assert(io.open(REC))
local txt = f:read("*a")
f:close()
local function vec(attrs, key)
    local list = {}
    for n in (attrs:match(key .. '="([^"]*)"') or ""):gmatch("%S+") do list[#list + 1] = tonumber(n) end
    return unpack(list)
end
local rec = {}
for body in txt:gmatch("<s (.-)</s>") do
    local attrs = body:match("^(.-)>")
    local s = { t = tonumber(attrs:match('t="([^"]+)"')) / 1000, v = tonumber(attrs:match('v="([^"]+)"')),
                rot = tonumber(attrs:match('rot="([^"]+)"')) or 0, wp = tonumber(attrs:match('wp="([^"]+)"')) }
    s.rx, _, s.rz = vec(attrs, "rear")
    s.fx, _, s.fz = vec(attrs, "front")
    s.wx, s.wz = vec(attrs, "wpAt")
    local tr = body:match("<trailer (.-)/>")
    if tr ~= nil then
        s.hx, _, s.hz = vec(tr, "hitch")
        s.ax, _, s.az = vec(tr, "axle")
    end
    rec[#rec + 1] = s
end
assert(#rec > 10, "no samples in " .. REC)
assert(rec[1].wx ~= nil, REC .. " has no waypoint positions (recorded before the recorder stored wpAt) - cannot rebuild the line")

-- The followed line: each new current waypoint, in order.
local path = {}
for k, s in ipairs(rec) do
    local last = path[#path]
    if s.wx ~= nil and (last == nil or last.id ~= s.wp or math.abs(last.x - s.wx) > 0.01) then
        path[#path + 1] = { id = s.wp, x = s.wx, z = s.wz }
    end
    s.pi = #path
end
-- The first current waypoint is already AHEAD of the truck: extend the line 30 m back along its own
-- first segment (straight, so it adds no bend for the speed rule to see), or every early sample
-- measures as "at the first point".
do
    local a, b = path[1], path[2]
    local hx, hz = b.x - a.x, b.z - a.z
    local l = math.sqrt(hx * hx + hz * hz)
    table.insert(path, 1, { id = -1, x = a.x - hx / l * 30, z = a.z - hz / l * 30 })
    for _, s in ipairs(rec) do s.pi = s.pi + 1 end
end

-- Distance along the line of a point, searching segments from `from` onward (runs only go forward).
local cum = { 0 }
for k = 2, #path do cum[k] = cum[k - 1] + math.sqrt((path[k].x - path[k - 1].x) ^ 2 + (path[k].z - path[k - 1].z) ^ 2) end
local function progress(px, pz, lo, hi)
    local best, bs, bk = math.huge, 0, lo
    for k = math.max(1, lo), math.min(#path - 1, hi) do
        local a, b = path[k], path[k + 1]
        local dx, dz = b.x - a.x, b.z - a.z
        local l2 = dx * dx + dz * dz
        if l2 > 1e-9 then
            local u = math.max(0, math.min(1, ((px - a.x) * dx + (pz - a.z) * dz) / l2))
            local d = (px - a.x - u * dx) ^ 2 + (pz - a.z - u * dz) ^ 2
            if d < best then best, bs, bk = d, cum[k] + u * math.sqrt(l2), k end
        end
    end
    return bs, bk
end

-- Signed sideways offset (+ = left of the line) against segment k and its neighbours: local, because
-- a lap passes the same ground twice and the nearest segment anywhere can be the other pass.
local function offsetAt(px, pz, k)
    local best, signed = math.huge, 0
    for j = math.max(1, k - 2), math.min(#path - 1, k + 2) do
        local a, b = path[j], path[j + 1]
        local dx, dz = b.x - a.x, b.z - a.z
        local l2 = dx * dx + dz * dz
        if l2 > 1e-9 then
            local u = math.max(0, math.min(1, ((px - a.x) * dx + (pz - a.z) * dz) / l2))
            local qx, qz = a.x + u * dx, a.z + u * dz
            local d = math.sqrt((px - qx) ^ 2 + (pz - qz) ^ 2)
            if d < best then best, signed = d, (((px - qx) * dz - (pz - qz) * dx) >= 0) and d or -d end
        end
    end
    return signed
end

-- True speed: rear-axle travel over +-4 samples (~2 m).
for k, s in ipairs(rec) do
    local a, b = rec[math.max(1, k - 4)], rec[math.min(#rec, k + 4)]
    local d, dt = 0, b.t - a.t
    for j = math.max(1, k - 4) + 1, math.min(#rec, k + 4) do
        d = d + math.sqrt((rec[j].rx - rec[j - 1].rx) ^ 2 + (rec[j].rz - rec[j - 1].rz) ^ 2)
    end
    s.vt = dt > 0 and d / dt * 3.6 or s.v
end

-- ------------------------------------------------------------------------- drive each piece
-- Pieces: between stops. A piece starts once the truck is rolling (true speed > 3 km/h).
local pieces, cur = {}, nil
for k, s in ipairs(rec) do
    if s.vt > 3 and s.v > 1 then
        if cur == nil then cur = { from = k } ; pieces[#pieces + 1] = cur end
        cur.to = k
    else
        cur = nil
    end
end

local out = {}
local function emit(fmt, ...) out[#out + 1] = string.format(fmt, ...) end
emit("%s | %s | twin %s%s | speed setting %d km/h | rig mass %.1f t", REC:match("[^/\\]+$"), rig.name, driver.name,
    #label > 0 and (" [" .. table.concat(label, " ") .. "]") or "", SETTING, rig.totalMass or -1)
local allErr, allN = 0, 0
for _, pc in ipairs(pieces) do
    if pc.to - pc.from >= 40 then
        local s0 = rec[pc.from]
        -- The piece's own line, ending where AutoDrive stopped: that was its destination, and it
        -- slows to arrive (routeEnds below).
        local first = math.max(1, s0.pi - 2)
        local last = rec[pc.to].pi
        local sub = {}
        for k = first, last do sub[#sub + 1] = { x = path[k].x, z = path[k].z } end
        local heading = math.atan2(s0.fx - s0.rx, s0.fz - s0.rz)
        local trailerHeading = (s0.hx ~= nil) and math.atan2(s0.hx - s0.ax, s0.hz - s0.az) or heading
        local sim = S.simulate(sub, rig, driver,
            { x = s0.rx, z = s0.rz, heading = heading, trailerHeading = trailerHeading, speed = s0.vt, rot = s0.rot },
            { dt = 0.016, maxTime = 600, speedLimitKmh = SETTING, routeEnds = (pc.to < #rec) })
        -- Sim progress along the SAME full line.
        local lo = first
        for _, st in ipairs(sim) do
            st.p, lo = progress(st.x, st.z, lo, lo + 6)
            st.off = offsetAt(st.x, st.z, lo)
        end
        local function simAt(p)
            -- first step at or past progress p (sim progress is monotone enough at 16 ms steps)
            for j = 1, #sim do if sim[j].p >= p then return sim[j] end end
            return nil
        end
        -- Corners: stretches where the recorded wheels are turned (|rot| > 0.3).
        emit("piece samples %d-%d (%.0f m)", pc.from, pc.to, (pc.to - pc.from) * 0.25)
        local lo2 = first
        local inC, c = false, nil
        local sumErr, n = 0, 0
        for k = pc.from, pc.to do
            local s = rec[k]
            local p
            p, lo2 = progress(s.rx, s.rz, lo2, lo2 + 6)
            local st = simAt(p)
            if st ~= nil then
                sumErr, n = sumErr + math.abs(st.v - s.vt), n + 1
                local turned = math.abs(s.rot) > 0.3
                if turned and not inC then
                    -- Turn sense from the wheels: rotatedTime > 0 is a left turn, and left is +.
                    c = { k0 = k, recMin = math.huge, simMin = math.huge, recRot = 0, simCap = math.huge,
                          side = s.rot > 0 and 1 or -1, recIn = 0, recOut = 0, simIn = 0, simOut = 0 }
                    inC = true
                end
                if inC then
                    c.k1 = k
                    c.recMin = math.min(c.recMin, s.vt)
                    c.simMin = math.min(c.simMin, st.v)
                    c.simCap = math.min(c.simCap, st.cap or math.huge)
                    c.recRot = math.max(c.recRot, math.abs(s.rot))
                    local ro, so = offsetAt(s.rx, s.rz, lo2) * c.side, st.off * c.side
                    c.recIn, c.recOut = math.max(c.recIn, ro), math.max(c.recOut, -ro)
                    c.simIn, c.simOut = math.max(c.simIn, so), math.max(c.simOut, -so)
                end
                if inC and (not turned or k == pc.to) then
                    inC = false
                    if c.k1 - c.k0 >= 8 then
                        emit("  corner %4d-%4d %s | slowest km/h: rec %5.1f twin %5.1f (cap %s) | rear axle in/out m: rec %.2f/%.2f twin %.2f/%.2f | peak rot %.2f%s",
                            c.k0, c.k1, c.side > 0 and "L" or "R", c.recMin, c.simMin,
                            c.simCap < 1e9 and string.format("%4.1f", c.simCap) or "   -",
                            c.recIn, c.recOut, c.simIn, c.simOut, c.recRot, c.recRot > 0.746 and " LOCK" or "")
                    end
                end
            end
        end
        if n > 0 then
            emit("  mean |twin - recorded| speed over the piece: %.1f km/h (%d samples)", sumErr / n, n)
            allErr, allN = allErr + sumErr, allN + n
        end
    end
end
if allN > 0 then emit("ALL: mean |twin - recorded| speed %.2f km/h over %d samples", allErr / allN, allN) end
print(table.concat(out, "\n"))

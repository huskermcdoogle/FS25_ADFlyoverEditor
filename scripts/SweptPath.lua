--[[
Swept-path recorder - phase 1 of docs/swept-path-spec.md.

While an AutoDrive-driven vehicle moves, log where its parts ACTUALLY go: the steering node, the
front and rear axle centres, each hitch point and each trailer's axle centre - plus what the driver
was looking at (the current waypoint, the look-ahead target) and what it did with the wheels
(`rotatedTime`, the game's steering state). This is the ground truth the prediction model in the
spec is calibrated against; without it every clearance number is a guess.

It is deliberately dumb: no model, no judgement. Record, save, draw.

Console:
  FlyoverSweptRecord        toggle recording of the controlled vehicle (auto-arms: records whenever
                            AutoDrive is driving it, pauses when it is not)
  FlyoverSweptSave [name]   write the current run to modSettings/FS25_ADFlyoverEditor/swept/<name>.xml
  FlyoverSweptLoad name     load a saved run as the overlay
  FlyoverSweptShow          toggle the world overlay
  FlyoverSweptClear         discard the current run

Sampling is distance-gated (every SAMPLE_DIST metres of steering-node travel) rather than per frame,
so a stopped vehicle does not pile up samples and a run stays a few thousand rows.
]]

ADFlyoverSweptPath = {}

local R = ADFlyoverSweptPath

R.MOD_NAME = "ADFlyoverEditor"
R.FOLDER = "modSettings/FS25_ADFlyoverEditor/swept/"
R.SAMPLE_DIST = 0.25    -- metres of steering-node travel between samples
R.MAX_SAMPLES = 20000   -- ~5 km at SAMPLE_DIST; a safety cap, not a target
R.DRAW_RADIUS = 250     -- metres from the viewpoint within which the overlay is drawn
R.LIFT = 0.45           -- metres above the sampled ground height for the overlay lines

R.armed = false         -- FlyoverSweptRecord toggled on
R.recording = false     -- armed AND AutoDrive is currently driving the vehicle
R.show = true
R.samples = {}
R.vehicleName = nil
R.lookAhead = nil
R.lastX, R.lastZ = nil, nil
R.runStart = nil

-- Overlay colours: one per track so a screenshot reads without a legend.
R.COLOURS = {
    steer = { 1.0, 1.0, 1.0 },  -- steering node: white
    front = { 0.9, 0.9, 0.3 },  -- front axle: yellow
    rear  = { 1.0, 0.55, 0.1 }, -- rear axle: orange
    hitch = { 1.0, 0.3, 0.8 },  -- hitch point: magenta
    axle  = { 0.2, 0.85, 1.0 }, -- trailer axle(s): cyan
    look  = { 0.3, 1.0, 0.3 },  -- look-ahead target: green
}

local function log(fmt, ...)
    Logging.info("[%s] swept: " .. fmt, R.MOD_NAME, ...)
end

-- Forward declaration: captureCurrentRig (above the definition, in the geometry section) calls this.
-- A `local function` is only visible to code compiled AFTER it, so without this the call resolved
-- to a nil global - FlyoverSweptRig failed with "attempt to call a nil value".
local controlledVehicle

-- ---------------------------------------------------------------------------------------------
-- Vehicle geometry
-- ---------------------------------------------------------------------------------------------

--- World position of the centre of a vehicle's front-most and rear-most axle. Wheels are grouped by
--- their z in the root frame (rounded to 0.2 m, so a slightly staggered bogie still reads as one
--- axle); the group with the greatest z is the front, the least the rear. Returns nil when the
--- vehicle has no wheels the game exposes.
local function axleCentres(vehicle)
    local spec = vehicle.spec_wheels
    if spec == nil or spec.wheels == nil or #spec.wheels == 0 then
        return nil, nil, nil
    end
    local root = vehicle.components[1].node
    local groups = {}
    -- Also the centroid of ALL wheels: for a tandem/tridem trailer the kinematic pivot is between
    -- the axles, not on the rearmost one, and the rearmost group over-states the offtracking (first
    -- calibration: every corner over-predicted by 0.4-0.85 m against the rearmost axle).
    local allN, allX, allY, allZ = 0, 0, 0, 0
    for _, wheel in ipairs(spec.wheels) do
        local node = wheel.node or wheel.repr
        local phys = wheel.physics or {}
        if node ~= nil then
            local px, py, pz = phys.positionX or 0, phys.positionY or 0, phys.positionZ or 0
            local wx, wy, wz = localToWorld(node, px, py, pz)
            local _, _, lz = localToLocal(node, root, px, py, pz)
            local key = math.floor(lz / 0.2 + 0.5)
            local g = groups[key]
            if g == nil then
                g = { n = 0, x = 0, y = 0, z = 0, lz = lz }
                groups[key] = g
            end
            g.n, g.x, g.y, g.z = g.n + 1, g.x + wx, g.y + wy, g.z + wz
            allN, allX, allY, allZ = allN + 1, allX + wx, allY + wy, allZ + wz
        end
    end
    local front, rear
    for _, g in pairs(groups) do
        if front == nil or g.lz > front.lz then front = g end
        if rear == nil or g.lz < rear.lz then rear = g end
    end
    local function centre(g)
        if g == nil then return nil end
        return { x = g.x / g.n, y = g.y / g.n, z = g.z / g.n, lz = g.lz }
    end
    local all = allN > 0 and { x = allX / allN, y = allY / allN, z = allZ / allN } or nil
    return centre(front), centre(rear), all
end

--- Measure the design-vehicle parameters (spec §4) off a real, entered rig instead of typing them:
--- tow wheelbase, steering-node and hitch offsets from the rear axle (signed along the body axis),
--- trailer hitch->wheel-centroid length, widths, full-lock radius, the driver's look-ahead and
--- waypoint-reach distance. Returns a SweptSim rig table, or nil and a reason.
function R.captureRig(vehicle)
    if vehicle == nil or vehicle.components == nil then return nil, "no vehicle" end
    local root = vehicle.components[1].node
    local front, rear = axleCentres(vehicle)
    if front == nil or rear == nil then return nil, "vehicle exposes no wheels" end
    local steerNode = (vehicle.getAISteeringNode ~= nil and vehicle:getAISteeringNode()) or root
    local _, _, steerLz = localToLocal(steerNode, root, 0, 0, 0)
    local rig = {
        name = vehicle.getName and vehicle:getName() or "vehicle",
        wheelbase = math.max(0.5, front.lz - rear.lz),
        steerNodeOffset = steerLz - rear.lz,
        towWidth = (vehicle.size and vehicle.size.width) or 2.5,
        maxRotTime = math.max(0.1, math.abs(vehicle.maxRotTime or 1)),
        minTurnRadius = vehicle.maxTurningRadius or 6.0,
        lookAhead = 4, minDistance = 1.8,
        hitchOffset = 0, trailerLength = 0, trailerWidth = 0,
        -- Tonnes, tow + trailer + load, as AutoDrive's bend scan reads it (getTotalMass(false)).
        -- Whatever is on board NOW: capture loaded for the slowest, most cutting-in line.
        totalMass = vehicle.getTotalMass ~= nil and vehicle:getTotalMass(false) or nil,
    }
    -- FULL LOCK: vehicle.maxTurningRadius is PRIMARY, not a fallback - this took two wrong turns to
    -- reach. First try read wheel.physics.rotMax (45 deg -> 5.8 m); when that number didn't move,
    -- second try read vehicle.maxRotation instead (the field DrivePathModule itself uses for the
    -- steering-angle limit) - also 45 deg -> 5.8 m, the SAME wrong number by a different door. A
    -- CLEAN recording settled it: looptest.xml, 15 s of the Transtar held hard over with nothing to
    -- hit (the earlier 4.3-5.0 m "calibration" had been a stall against an obstacle, not a real
    -- measurement). A least-squares circle fit over the sustained-lock samples (rotatedTime >= 1.15,
    -- 66 points, mean fit residual 4 cm) gives R = 6.26 m for the rear axle - converging there as the
    -- window is tightened toward peak lock (6.67 -> 6.59 -> 6.51 -> 6.44 -> 6.26). maxTurningRadius
    -- was 6.1 m: within 0.15 m of a clean driven circle, while both wheel-angle formulas undershot by
    -- ~0.4 m in the same direction for a reason not yet understood (Ackermann geometry is the leading
    -- guess). Two independently-wrong geometric derivations against one field that matches driven
    -- reality is reason enough to trust the field. The wheel-angle estimate is kept as a fallback for
    -- a vehicle with no maxTurningRadius set at all.
    rig.nominalTurnRadius = vehicle.maxTurningRadius
    if vehicle.maxTurningRadius ~= nil and vehicle.maxTurningRadius > 0 then
        rig.minTurnRadius = vehicle.maxTurningRadius
    elseif vehicle.maxRotation ~= nil and vehicle.maxRotation > 0 then
        local deg = (vehicle.maxRotation > 2 * math.pi) and vehicle.maxRotation or math.deg(vehicle.maxRotation)
        local delta = math.min(math.rad(deg), math.rad(75))
        rig.minTurnRadius = rig.wheelbase / math.tan(delta)
        rig.maxWheelAngleDeg = math.deg(delta)
    end
    if vehicle.maxRotation ~= nil and vehicle.maxRotation > 0 then
        local deg = (vehicle.maxRotation > 2 * math.pi) and vehicle.maxRotation or math.deg(vehicle.maxRotation)
        rig.steerLimitDeg = math.min(deg, 75)
    end
    local AD = ADFlyoverArming and ADFlyoverArming.autoDrive
    if AD ~= nil then
        if AD.getMinLookaheadByVehicleType then rig.lookAhead = AD.getMinLookaheadByVehicleType(vehicle) end
        if AD.defineMinDistanceByVehicleType then rig.minDistance = AD.defineMinDistanceByVehicleType(vehicle) end
    end
    -- First wheeled implement = the trailer. Hitch offset is measured in the TOW's root frame so it
    -- carries its sign (negative = behind the rear axle, a drawbar).
    local spec = vehicle.spec_attacherJoints
    if spec ~= nil and spec.attachedImplements ~= nil then
        for _, imp in ipairs(spec.attachedImplements) do
            local obj = imp.object
            local joint = spec.attacherJoints and spec.attacherJoints[imp.jointDescIndex]
            if obj ~= nil and joint ~= nil and joint.jointTransform ~= nil then
                local _, trRear, trAll = axleCentres(obj)
                if trRear ~= nil then
                    local _, _, hitchLz = localToLocal(joint.jointTransform, root, 0, 0, 0)
                    local hx, _, hz = getWorldTranslation(joint.jointTransform)
                    local piv = trAll or trRear
                    rig.hitchOffset = hitchLz - rear.lz
                    rig.trailerLength = math.sqrt((piv.x - hx) ^ 2 + (piv.z - hz) ^ 2)
                    rig.trailerWidth = (obj.size and obj.size.width) or 2.5
                    rig.name = rig.name .. " + " .. (obj.getName and obj:getName() or "trailer")
                    break
                end
            end
        end
    end
    return rig
end

function R.describeRig(rig)
    if rig == nil then return "no rig captured (FlyoverSweptRig with a vehicle entered)" end
    return string.format("%s: wheelbase %.2f, steer node %+.2f, full-lock R %.1f (wheels %.0f deg; game's nominal %s), look-ahead %.1f, reach %.1f, hitch %+.2f (%s), trailer %.2f (w %.1f/%.1f), mass %s",
        rig.name, rig.wheelbase, rig.steerNodeOffset, rig.minTurnRadius, rig.maxWheelAngleDeg or 0,
        rig.nominalTurnRadius and string.format("%.1f", rig.nominalTurnRadius) or "n/a",
        rig.lookAhead, rig.minDistance, rig.hitchOffset,
        (rig.hitchOffset or 0) >= 0 and "fifth wheel, ahead of the rear axle" or "drawbar, behind the rear axle",
        rig.trailerLength, rig.towWidth or 0, rig.trailerWidth or 0,
        rig.totalMass and string.format("%.1f t", rig.totalMass) or "n/a")
end

--- Console: capture the entered vehicle as the design rig the junction preview simulates with.
function R.captureCurrentRig()
    local v = controlledVehicle()
    if v == nil then
        -- Fall back to any entered vehicle even without AutoDrive state.
        local AD = ADFlyoverArming and ADFlyoverArming.autoDrive
        v = AD and AD.getControlledVehicle and AD.getControlledVehicle() or nil
    end
    local rig, why = R.captureRig(v)
    if rig == nil then return "could not capture: " .. tostring(why) end
    R.rig = rig
    log("design rig captured - %s", R.describeRig(rig))
    if ADFlyoverEditor ~= nil then ADFlyoverEditor.junctionPreviewKey = nil end
    return "captured " .. R.describeRig(rig)
end

--- Walk the attached implements: for each, the world position of the tow side's hitch node and the
--- implement's rear axle centre. Recurses so a dolly + trailer records as two entries; the model does
--- not use the second in V1 but the data costs nothing.
local function collectTrailers(vehicle, out, depth)
    depth = depth or 0
    local spec = vehicle.spec_attacherJoints
    if spec == nil or spec.attachedImplements == nil or depth > 3 then
        return
    end
    for _, imp in ipairs(spec.attachedImplements) do
        local obj = imp.object
        local joint = spec.attacherJoints and spec.attacherJoints[imp.jointDescIndex]
        if obj ~= nil and joint ~= nil and joint.jointTransform ~= nil then
            local hx, hy, hz = getWorldTranslation(joint.jointTransform)
            local _, rear, all = axleCentres(obj)
            -- Only things with wheels are trailers for this purpose: a mounted implement has no
            -- axle to offtrack, and would only add a hitch with nothing behind it.
            if rear ~= nil then
                out[#out + 1] = { hx = hx, hy = hy, hz = hz, ax = rear.x, ay = rear.y, az = rear.z,
                                  cx = all.x, cy = all.y, cz = all.z,
                                  name = obj.getName and obj:getName() or "?" }
            end
            collectTrailers(obj, out, depth + 1)
        end
    end
end

controlledVehicle = function()
    local AD = ADFlyoverArming and ADFlyoverArming.autoDrive
    if AD == nil or AD.getControlledVehicle == nil then
        return nil
    end
    local v = AD.getControlledVehicle()
    if v ~= nil and v.ad ~= nil and v.ad.stateModule ~= nil then
        return v
    end
    return nil
end

local function isDriving(vehicle)
    local sm = vehicle.ad.stateModule
    return sm.isActive ~= nil and sm:isActive()
end

-- ---------------------------------------------------------------------------------------------
-- Recording
-- ---------------------------------------------------------------------------------------------

local function takeSample(vehicle, now)
    local sx, sy, sz
    if vehicle.getAISteeringNode ~= nil and vehicle:getAISteeringNode() ~= nil then
        sx, sy, sz = getWorldTranslation(vehicle:getAISteeringNode())
    else
        sx, sy, sz = getWorldTranslation(vehicle.components[1].node)
    end

    if R.lastX ~= nil then
        local dx, dz = sx - R.lastX, sz - R.lastZ
        if (dx * dx + dz * dz) < (R.SAMPLE_DIST * R.SAMPLE_DIST) then
            return
        end
    end
    R.lastX, R.lastZ = sx, sz

    local front, rear = axleCentres(vehicle)
    local trailers = {}
    collectTrailers(vehicle, trailers, 0)

    local dpm = vehicle.ad.drivePathModule
    local wp = dpm and dpm.getCurrentWayPoint and dpm:getCurrentWayPoint()
    local speed = vehicle.getLastSpeed and vehicle:getLastSpeed() or 0

    local s = {
        t = now - (R.runStart or now),
        v = speed,
        sx = sx, sy = sy, sz = sz,
        fx = front and front.x, fy = front and front.y, fz = front and front.z,
        rx = rear and rear.x, ry = rear and rear.y, rz = rear and rear.z,
        -- The id AND the position: ids are renumbered by every waypoint deletion (removeWayPoint
        -- compacts them), so an id alone stops meaning anything the moment the network is edited -
        -- which, with the junction tool, is between one drive and the next.
        wp = wp and wp.id, wpx = wp and wp.x, wpz = wp and wp.z,
        tx = dpm and dpm.targetX, tz = dpm and dpm.targetZ,
        rot = vehicle.rotatedTime,
        trailers = trailers,
    }
    if R.lookAhead == nil and dpm ~= nil then
        R.lookAhead = dpm.min_lookAhead
    end
    R.samples[#R.samples + 1] = s
    if #R.samples >= R.MAX_SAMPLES then
        R.armed = false
        R.recording = false
        log("run reached %d samples - recording stopped. Save it or clear it.", R.MAX_SAMPLES)
    end
end

function R.update(dt)
    if not R.armed then
        return
    end
    local vehicle = controlledVehicle()
    local driving = vehicle ~= nil and isDriving(vehicle)
    if driving ~= R.recording then
        R.recording = driving
        if driving then
            R.vehicleName = vehicle.getName and vehicle:getName() or "vehicle"
            if R.runStart == nil then
                R.runStart = g_time or 0
            end
            R.lastX, R.lastZ = nil, nil
            log("recording %s (%d samples so far)", R.vehicleName, #R.samples)
        else
            log("paused - AutoDrive stopped (%d samples)", #R.samples)
        end
    end
    if driving then
        takeSample(vehicle, g_time or 0)
    end
end

-- ---------------------------------------------------------------------------------------------
-- Overlay
-- ---------------------------------------------------------------------------------------------

local function viewpoint()
    if ADFlyoverEditor ~= nil and ADFlyoverEditor.active and ADFlyoverEditor.cursorX ~= nil then
        return ADFlyoverEditor.cursorX, ADFlyoverEditor.cursorZ
    end
    local v = controlledVehicle()
    if v ~= nil then
        local x, _, z = getWorldTranslation(v.components[1].node)
        return x, z
    end
    return nil
end

local function line(ax, ay, az, bx, by, bz, lw, c)
    if ax == nil or bx == nil then return end
    ADDrawingManager:addLineTask(ax, ay + R.LIFT, az, bx, by + R.LIFT, bz, lw, c[1], c[2], c[3])
end

function R.draw()
    if not R.show or #R.samples < 2 or ADDrawingManager == nil then
        return
    end
    local vx, vz = viewpoint()
    if vx == nil then
        return
    end
    local lw = (ADFlyoverTheme ~= nil and ADFlyoverTheme.lineWeight) or 2
    local r2 = R.DRAW_RADIUS * R.DRAW_RADIUS
    local C = R.COLOURS
    local prev = nil
    for i = 1, #R.samples do
        local s = R.samples[i]
        local dx, dz = s.sx - vx, s.sz - vz
        if (dx * dx + dz * dz) < r2 then
            if prev ~= nil then
                line(prev.sx, prev.sy, prev.sz, s.sx, s.sy, s.sz, lw, C.steer)
                line(prev.fx, prev.fy, prev.fz, s.fx, s.fy, s.fz, lw, C.front)
                line(prev.rx, prev.ry, prev.rz, s.rx, s.ry, s.rz, lw * 1.5, C.rear)
                for k, tr in ipairs(s.trailers) do
                    local pt = prev.trailers[k]
                    if pt ~= nil then
                        line(pt.hx, pt.hy, pt.hz, tr.hx, tr.hy, tr.hz, lw, C.hitch)
                        line(pt.ax, pt.ay, pt.az, tr.ax, tr.ay, tr.az, lw * 1.5, C.axle)
                    end
                end
            end
            prev = s
        else
            prev = nil
        end
    end
    -- The live look-ahead target while recording: a short green stalk where the driver is aiming.
    if R.recording then
        local s = R.samples[#R.samples]
        if s.tx ~= nil then
            ADDrawingManager:addLineTask(s.tx, s.sy + R.LIFT, s.tz, s.tx, s.sy + R.LIFT + 2.5, s.tz,
                lw, C.look[1], C.look[2], C.look[3])
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Save / load
-- ---------------------------------------------------------------------------------------------

local function runPath(name)
    if getUserProfileAppPath == nil then return nil end
    name = tostring(name or ""):gsub("[^%w%-_]", "")
    if name == "" then
        name = "run-" .. tostring(os and os.time and os.time() or #R.samples)
    end
    return getUserProfileAppPath() .. R.FOLDER .. name .. ".xml", name
end

function R.save(name)
    local path, cleanName = runPath(name)
    if path == nil then
        return "no profile path"
    end
    if #R.samples == 0 then
        return "nothing recorded"
    end
    local ok, err = pcall(function()
        createFolder(getUserProfileAppPath() .. "modSettings/")
        createFolder(getUserProfileAppPath() .. "modSettings/FS25_ADFlyoverEditor/")
        createFolder(getUserProfileAppPath() .. R.FOLDER)
        local xml = createXMLFile("ADFlyoverSwept", path, "sweptPath")
        setXMLString(xml, "sweptPath#vehicle", tostring(R.vehicleName or "?"))
        setXMLFloat(xml, "sweptPath#lookAhead", R.lookAhead or -1)
        setXMLFloat(xml, "sweptPath#sampleDist", R.SAMPLE_DIST)
        setXMLString(xml, "sweptPath#build", tostring(ADFlyoverPrelude and ADFlyoverPrelude.BUILD or "?"))
        setXMLInt(xml, "sweptPath#count", #R.samples)
        for i, s in ipairs(R.samples) do
            local k = string.format("sweptPath.s(%d)", i - 1)
            setXMLFloat(xml, k .. "#t", s.t)
            setXMLFloat(xml, k .. "#v", s.v)
            setXMLString(xml, k .. "#steer", string.format("%.3f %.3f %.3f", s.sx, s.sy, s.sz))
            if s.fx then setXMLString(xml, k .. "#front", string.format("%.3f %.3f %.3f", s.fx, s.fy, s.fz)) end
            if s.rx then setXMLString(xml, k .. "#rear", string.format("%.3f %.3f %.3f", s.rx, s.ry, s.rz)) end
            if s.wp then setXMLInt(xml, k .. "#wp", s.wp) end
            if s.wpx then setXMLString(xml, k .. "#wpAt", string.format("%.3f %.3f", s.wpx, s.wpz)) end
            if s.tx then setXMLString(xml, k .. "#look", string.format("%.3f %.3f", s.tx, s.tz)) end
            if s.rot then setXMLFloat(xml, k .. "#rot", s.rot) end
            for j, tr in ipairs(s.trailers) do
                local tk = string.format("%s.trailer(%d)", k, j - 1)
                setXMLString(xml, tk .. "#hitch", string.format("%.3f %.3f %.3f", tr.hx, tr.hy, tr.hz))
                setXMLString(xml, tk .. "#axle", string.format("%.3f %.3f %.3f", tr.ax, tr.ay, tr.az))
                if tr.cx then setXMLString(xml, tk .. "#wheels", string.format("%.3f %.3f %.3f", tr.cx, tr.cy, tr.cz)) end
            end
        end
        saveXMLFile(xml)
        delete(xml)
    end)
    if not ok then
        return "save failed: " .. tostring(err)
    end
    log("saved %d samples to %s", #R.samples, path)
    return string.format("saved %d samples as %s", #R.samples, cleanName)
end

local function vec3(str)
    if str == nil then return nil end
    local x, y, z = str:match("([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+)")
    return tonumber(x), tonumber(y), tonumber(z)
end

function R.load(name)
    local path = runPath(name)
    if path == nil or not fileExists(path) then
        return "no such run: " .. tostring(name)
    end
    local samples, meta = {}, {}
    local ok, err = pcall(function()
        local xml = loadXMLFile("ADFlyoverSwept", path)
        meta.vehicle = getXMLString(xml, "sweptPath#vehicle")
        meta.lookAhead = getXMLFloat(xml, "sweptPath#lookAhead")
        local i = 0
        while true do
            local k = string.format("sweptPath.s(%d)", i)
            if not hasXMLProperty(xml, k) then break end
            local s = { trailers = {} }
            s.t = getXMLFloat(xml, k .. "#t") or 0
            s.v = getXMLFloat(xml, k .. "#v") or 0
            s.sx, s.sy, s.sz = vec3(getXMLString(xml, k .. "#steer"))
            s.fx, s.fy, s.fz = vec3(getXMLString(xml, k .. "#front"))
            s.rx, s.ry, s.rz = vec3(getXMLString(xml, k .. "#rear"))
            s.wp = getXMLInt(xml, k .. "#wp")
            local at = getXMLString(xml, k .. "#wpAt")
            if at then
                local ax, az = at:match("([%-%d%.]+) ([%-%d%.]+)")
                s.wpx, s.wpz = tonumber(ax), tonumber(az)
            end
            local look = getXMLString(xml, k .. "#look")
            if look then
                local tx, tz = look:match("([%-%d%.]+) ([%-%d%.]+)")
                s.tx, s.tz = tonumber(tx), tonumber(tz)
            end
            s.rot = getXMLFloat(xml, k .. "#rot")
            local j = 0
            while true do
                local tk = string.format("%s.trailer(%d)", k, j)
                if not hasXMLProperty(xml, tk) then break end
                local tr = {}
                tr.hx, tr.hy, tr.hz = vec3(getXMLString(xml, tk .. "#hitch"))
                tr.ax, tr.ay, tr.az = vec3(getXMLString(xml, tk .. "#axle"))
                tr.cx, tr.cy, tr.cz = vec3(getXMLString(xml, tk .. "#wheels"))
                s.trailers[#s.trailers + 1] = tr
                j = j + 1
            end
            if s.sx ~= nil then
                samples[#samples + 1] = s
            end
            i = i + 1
        end
        delete(xml)
    end)
    if not ok then
        return "load failed: " .. tostring(err)
    end
    R.armed, R.recording = false, false
    R.samples = samples
    R.vehicleName = meta.vehicle
    R.lookAhead = meta.lookAhead
    R.runStart = nil
    R.show = true
    return string.format("loaded %d samples (%s, look-ahead %.1f m)", #samples,
        tostring(meta.vehicle), meta.lookAhead or -1)
end

-- ---------------------------------------------------------------------------------------------
-- Console entry points
-- ---------------------------------------------------------------------------------------------

function R.toggleRecord()
    R.armed = not R.armed
    if R.armed then
        R.show = true
        return "recording armed - drives of the controlled vehicle under AutoDrive are recorded (" ..
            #R.samples .. " samples held)"
    end
    R.recording = false
    return "recording off (" .. #R.samples .. " samples held - FlyoverSweptSave to keep them)"
end

function R.toggleShow()
    R.show = not R.show
    return "overlay " .. (R.show and "on" or "off")
end

function R.clear()
    local n = #R.samples
    R.samples = {}
    R.runStart = nil
    R.lastX, R.lastZ = nil, nil
    R.lookAhead = nil
    return "cleared " .. n .. " samples"
end

function R.describe()
    return string.format("swept: armed=%s recording=%s show=%s samples=%d vehicle=%s lookAhead=%s",
        tostring(R.armed), tostring(R.recording), tostring(R.show), #R.samples,
        tostring(R.vehicleName), tostring(R.lookAhead))
end

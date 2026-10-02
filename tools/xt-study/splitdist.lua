-- How far before the junction must a two-way road split, so a truck coming in can stop before the
-- mouth when another truck holds the junction? Drives SweptSim's captured truck+semi in along a
-- two-way road, through the split, onto the one-way lane in, and towards its turn. AutoDrive's own
-- "who waits" check (CollisionDetectionModule:detectAdTrafficOnRoute, 3.0.1.2) is replayed on the
-- twin's track. A blocking truck is assumed to sit at the first shared point C the whole time.
-- Usage: lua splitdist.lua <repo scripts/editor dir>
local SRC = arg[1]
dofile(SRC .. "/SweptSim.lua")
local S = SweptSim
local rig = S.EXAMPLE_RIG

local FRONT = rig.wheelbase + 1.2 - rig.steerNodeOffset    -- front bumper ahead of the steering node
local ROAD_STEP = 5                                         -- the clear respaces approaches to 5 m
local function thetaFor(v) return 5 + 25 * (60 - v) / 48 end

-- Path along +x: two-way road, split S at x = -D, one-way lane in at spacing s to the mouth J at x = 0,
-- then a turn of radius R (left or right) whose last two pieces carry the speed bend for vAim.
-- C (the first shared point) sits c metres into the turn (c = 0: the guard at the mouth).
local function buildPath(D, s, R, turn, vAim, c)
  local p, idx = {}, {}
  for x = -200, -D - 0.01, ROAD_STEP do p[#p + 1] = { x = x, z = 0 } end
  idx.S = #p + 1
  p[#p + 1] = { x = -D, z = 0 }
  local n = math.max(1, math.floor(D / s + 0.5))
  for i = 1, n do p[#p + 1] = { x = -D + D * i / n, z = 0 } end
  idx.J = #p
  -- the turn: arc tangent to +x at J; right turn bends toward +z (heading +x, right is +z here)
  local dir = (turn == "right") and 1 or -1
  local cx, cz = 0, dir * R
  local th = math.rad(thetaFor(vAim))
  local smooth = math.pi / 2 - 2 * th
  local angles = {}
  local nS = math.max(1, math.ceil(smooth * R / 2))
  for i = 1, nS do angles[#angles + 1] = smooth * i / nS end
  angles[#angles + 1] = smooth + th
  angles[#angles + 1] = smooth + 2 * th
  -- insert C at arc length c; SPARSE drops the turn's points between the mouth and C, so C is the
  -- first point after the mouth (fewer points between the stopping place and the shared point)
  if c > 0 then
    local ac = c / R
    if SPARSE then
      local kept = {}
      for _, a in ipairs(angles) do if a > ac then kept[#kept + 1] = a end end
      angles = kept
    end
    table.insert(angles, 1, ac)
    table.sort(angles)
  end
  for _, a in ipairs(angles) do
    p[#p + 1] = { x = cx + R * math.sin(a), z = cz - dir * R * math.cos(a), a = a }
    if c > 0 and math.abs(a - c / R) < 1e-9 then idx.C = #p end
  end
  if c == 0 then idx.C = idx.J end
  local ex, ez = p[#p].x, p[#p].z
  for d = 3, 60, 3 do p[#p + 1] = { x = ex, z = ez + dir * d } end
  return p, idx
end

local function run(D, s, R, turn, vAim, c, scan, decel, extraKmh)
  local path, idx = buildPath(D, s, R, turn, vAim, c)
  local driver = {}
  for k, v in pairs(S.STOCK_DRIVER) do driver[k] = v end
  driver.speedScanMetres = (scan ~= "own") and scan or nil
  local st = S.simulate(path, rig, driver, { x = path[1].x, z = 0, heading = math.pi / 2, speed = 40 },
    { speedLimitKmh = 40, dt = 1 / 60, maxTime = 120 })
  for k, step in ipairs(st) do
    if k % 20 == 0 then
      local i = step.wp
      local onDual = (i - 1 >= 1) and (i <= idx.S)            -- link (i-1 -> i) lies on the two-way road
      if not onDual and idx.C >= i + 1 and idx.C <= i + 4 then
        local v = step.v + (extraKmh or 0)
        local ms = v / 3.6
        local stopAt = step.sx + ms * ms / (2 * decel)         -- steering node, along +x (straight in)
        return { detX = step.sx, v = v, front = stopAt + FRONT }
      end
      if step.sx > 0 then break end
    end
  end
  return nil
end

print(string.format("truck front is %.1f m ahead of its steering node; mouth at x = 0; minus = stops before the mouth", FRONT))
for _, case in ipairs({ { "right", 10, 20, 0, "narrow: guard at the mouth" }, { "left", 12, 23, 0, "narrow: guard at the mouth" },
                        { "right", 10, 20, 4, "wide: first shared point 4 m into the turn" },
                        { "right", 10, 20, 4, "wide, no turn points before the shared point", true } }) do
  local turn, R, vAim, c, label = case[1], case[2], case[3], case[4], case[5]
  SPARSE = case[6]
  for _, scan in ipairs({ "own" }) do
    print(string.format("\n== %s turn R=%d aiming %d km/h, %s, bend scan %s", turn, R, vAim, label, (scan == "own") and "the twin's own" or (scan .. " m")))
    print("  split  spacing |  speed when it sees C | front stops at (brake 2.0 / 3.0 / 4.0 m/s2)   | +6 km/h, brake 3.0")
    for _, s in ipairs({ 2, 3, 4, 5 }) do
      for _, D in ipairs({ 5, 10, 15, 20, 25, 30, 40 }) do
        local r2 = run(D, s, R, turn, vAim, c, scan, 2.0)
        local r3 = run(D, s, R, turn, vAim, c, scan, 3.0)
        local r4 = run(D, s, R, turn, vAim, c, scan, 4.0)
        local rf = run(D, s, R, turn, vAim, c, scan, 3.0, 6)
        if r3 then
          print(string.format("  %3d m   %d m    |  %4.1f km/h at %6.1f m  |  %6.1f   %6.1f   %6.1f                    | %6.1f",
            D, s, r3.v, r3.detX, r2.front, r3.front, r4.front, rf.front))
        else
          print(string.format("  %3d m   %d m    |  never saw C", D, s))
        end
      end
    end
  end
end

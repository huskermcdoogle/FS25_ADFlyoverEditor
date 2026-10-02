-- How wide must the side road's mouth be for two trucks? A truck turns INTO the side road (onto the
-- lane going out) while another truck waits on the lane coming in, its front a few metres short of the
-- mouth. Drives SweptSim's captured truck+semi through the turn and measures the closest its body gets
-- to the waiting truck, and how far west its swept path reaches.
-- Frame: x east, z south. Main road lanes at z = +-3, paved edge at z = 6 (the mouth). Side road runs
-- south; lane going out at x = -g/2, lane coming in at x = +g/2. Right-hand traffic.
-- Usage: lua twowidth.lua <repo scripts/editor dir>
dofile(arg[1] .. "/SweptSim.lua")
local S = SweptSim
local rig = S.EXAMPLE_RIG
local driver = {}
for k, v in pairs(S.STOCK_DRIVER) do driver[k] = v end
local MOUTH, TRUCK_LEN, TRAILER_REAR = 6, 18, 2.0     -- waiting rig length; trailer body past its axle

local function arcPath(turn, g, R)
  local p = {}
  local hx = -g / 2
  local cx, cz, a0, a1, z0
  if turn == "right" then        -- eastbound on z = 3, heading +x, turning south onto x = hx
    z0 = 3; cx, cz = hx - R, z0 + R; a0, a1 = -math.pi / 2, 0
    for x = cx - 45, cx - 0.5, 3 do p[#p + 1] = { x = x, z = z0 } end
  else                           -- westbound on z = -3, heading -x, turning south onto x = hx
    z0 = -3; cx, cz = hx + R, z0 + R; a0, a1 = -math.pi / 2, -math.pi
    for x = cx + 45, cx + 0.5, -3 do p[#p + 1] = { x = x, z = z0 } end
  end
  local n = math.max(2, math.ceil(math.pi / 2 * R / 2))
  for i = 0, n do local a = a0 + (a1 - a0) * i / n; p[#p + 1] = { x = cx + R * math.cos(a), z = cz + R * math.sin(a) } end
  for d = 3, 70, 3 do p[#p + 1] = { x = hx, z = cz + d } end
  return p
end

-- Outline points of the moving rig at one step (tow body and trailer body edges, every 0.5 m).
local function outline(s)
  local pts = {}
  local function box(bx, bz, hd, back, front, half)
    local fx, fz = math.sin(hd), math.cos(hd)
    local lx, lz = math.cos(hd), -math.sin(hd)
    for d = -back, front, 0.5 do
      for _, w in ipairs({ -half, half }) do pts[#pts + 1] = { bx + fx * d + lx * w, bz + fz * d + lz * w } end
    end
  end
  box(s.x, s.z, s.heading, 1.0, rig.wheelbase + 1.2, rig.towWidth / 2)
  local tl = rig.trailerLength
  box(s.ax, s.az, s.trailerHeading, TRAILER_REAR, tl + 0.5, rig.trailerWidth / 2)
  return pts
end

local function run(turn, g, R, short)
  local path = arcPath(turn, g, R)
  local h0 = math.atan2(path[2].x - path[1].x, path[2].z - path[1].z)
  local st = S.simulate(path, rig, driver, { x = path[1].x, z = path[1].z, heading = h0, speed = 25 }, { speedLimitKmh = 40, dt = 1 / 60 })
  -- waiting truck on the lane coming in: x in [g/2 - 1.35, g/2 + 1.35], z from MOUTH+short southwards
  local wx0, wx1 = g / 2 - rig.towWidth / 2, g / 2 + rig.towWidth / 2
  local wz0, wz1 = MOUTH + short, MOUTH + short + TRUCK_LEN
  local gap, west, at = math.huge, math.huge, nil
  for k = 1, #st, 3 do
    for _, q in ipairs(outline(st[k])) do
      local x, z = q[1], q[2]
      local dx = math.max(wx0 - x, 0, x - wx1)
      local dz = math.max(wz0 - z, 0, z - wz1)
      local d = math.sqrt(dx * dx + dz * dz)
      if x >= wx0 and x <= wx1 and z >= wz0 and z <= wz1 then d = -math.min(x - wx0, wx1 - x, z - wz0, wz1 - z) end
      if d < gap then gap, at = d, z end
      if z > MOUTH + 10 and z < MOUTH + 30 then west = math.min(west, x) end
    end
  end
  return gap, west, wx1, at
end

print("closest the turning rig gets to the waiting truck (minus = they touch), and the paved width the two need")
for _, short in ipairs({ 8, 3 }) do
  for _, c in ipairs({ { "right", 8 }, { "right", 10 }, { "right", 12 }, { "left", 10 }, { "left", 12 }, { "left", 15 } }) do
    print(string.format("\n== %s turn into the side road, R=%d m, waiting truck's front %d m short of the mouth", c[1], c[2], short))
    print("  lane gap | closest | side-road paving needed, 10-30 m past the mouth")
    for _, g in ipairs({ 3, 4, 5, 6, 6.5, 7, 8 }) do
      local gap, west, east, at = run(c[1], g, c[2], short)
      print(string.format("   %4.1f m  | %5.2f m at %4.1f m past the mouth | %5.1f m", g, gap, at - MOUTH, east - west))
    end
  end
end

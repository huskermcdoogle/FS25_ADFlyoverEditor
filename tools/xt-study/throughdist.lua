-- One-way approaches: where does a truck stop when AutoDrive's "who waits" check finds another truck
-- at a shared point C ahead? Straight one-way lane along +x, C at x = 0 (a crossing or merge point).
-- The check (CollisionDetectionModule:detectAdTrafficOnRoute, 3.0.1.2) runs every 20 frames on the
-- twin's track: it sees C once C is among the truck's next 5 points and is not the first of them.
-- Through trucks do not slow for the junction, so they are tested at road speeds.
-- Usage: lua throughdist.lua <repo scripts/editor dir>
local SRC = arg[1]
dofile(SRC .. "/SweptSim.lua")
local S = SweptSim
local rig = S.EXAMPLE_RIG
local FRONT = rig.wheelbase + 1.2 - rig.steerNodeOffset

-- Lane at spacing s up to C, with k extra points spread over the last 15 m before C (tie-ins and other
-- shared points of the junction), then on past C.
local function buildPath(s, k)
  local p = {}
  local xs = {}
  local x = 0
  while x > -250 do x = x - s; xs[#xs + 1] = x end
  for i = 1, k do xs[#xs + 1] = -15 * i / (k + 1) end
  table.sort(xs)
  local clean = {}
  for _, v in ipairs(xs) do
    if #clean == 0 or v - clean[#clean] > 0.5 then clean[#clean + 1] = v end
  end
  for _, v in ipairs(clean) do p[#p + 1] = { x = v, z = 0 } end
  p[#p + 1] = { x = 0, z = 0 }
  local idxC = #p
  for d = s, 80, s do p[#p + 1] = { x = d, z = 0 } end
  return p, idxC
end

local function run(s, k, vKmh, decel)
  local path, idxC = buildPath(s, k)
  local st = S.simulate(path, rig, S.STOCK_DRIVER, { x = path[1].x, z = 0, heading = math.pi / 2, speed = vKmh },
    { speedLimitKmh = vKmh, dt = 1 / 60, maxTime = 120 })
  for n, step in ipairs(st) do
    if n % 20 == 0 then
      local i = step.wp
      if idxC >= i + 1 and idxC <= i + 4 then
        local ms = step.v / 3.6
        return step.sx + ms * ms / (2 * decel) + FRONT, step.sx
      end
      if step.sx > 0 then break end
    end
  end
  return nil
end

print(string.format("front bumper stop position relative to the shared point C (minus = short of it); front is %.1f m ahead of the steering node", FRONT))
for _, v in ipairs({ 20, 25, 30, 40, 50 }) do
  print(string.format("\n== %d km/h", v))
  print("  spacing  extra pts | sees C at | front stops (brake 2 / 3 / 4 m/s2)")
  for _, s in ipairs({ 3, 5, 8, 10 }) do
    for _, k in ipairs({ 0, 2, 4 }) do
      local f2 = run(s, k, v, 2.0)
      local f3, det = run(s, k, v, 3.0)
      local f4 = run(s, k, v, 4.0)
      print(string.format("   %2d m      %d      | %6.1f m  |  %6.1f  %6.1f  %6.1f", s, k, det, f2, f3, f4))
    end
  end
end

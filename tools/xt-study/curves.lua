-- Real truck-sized curves vs the mod's sharp corners: drive SweptSim's captured truck+semi through a
-- right and a left turn of a 4-way crossing and measure where the wheels go against the ROADS.
-- Usage: lua curves.lua <repo scripts/editor dir> <out dir>
--
-- Road model: two straight roads crossing at right angles, centre lines on x = 0 and z = 0. Lanes sit
-- L/2 either side of the centre line (L = the mod's "size"), so each road is 2L wide (edges at +-L).
-- Corners are SQUARE, so "off road" means "how much corner rounding this turn needs".
-- Right-hand traffic. Approach: eastbound (+x) on z = +L/2. Right turn exits south on x = -L/2,
-- left turn exits north on x = +L/2.
local SRC, OUT = arg[1], arg[2]
dofile(SRC .. "/SweptSim.lua")
local S = SweptSim
local rig, drv = S.EXAMPLE_RIG, S.STOCK_DRIVER

local LEAD, STEP, ARCSTEP = 45, 3, 2

local function straight(p, x0, z0, dx, dz, from, to, step)
  for d = from, to, step do p[#p+1] = { x = x0 + dx * d, z = z0 + dz * d } end
end

-- Mod layout at size L (piece coordinates, the same frame as the road model).
local function modPath(turn, L)
  local p = {}
  straight(p, -1.5 * L, 0.5 * L, 1, 0, -LEAD, -STEP, STEP)
  local seq
  if turn == "right" then seq = { {-1.5,.5},{-.75,.5},{-.5,.75},{-.5,1.5} }
  else seq = { {-1.5,.5},{-.75,.5},{-.5,.5},{0,0},{.5,-.5},{.5,-.75},{.5,-1.5} } end
  for _, n in ipairs(seq) do p[#p+1] = { x = n[1] * L, z = n[2] * L } end
  local e = seq[#seq]
  local dz = (turn == "right") and 1 or -1
  straight(p, e[1] * L, e[2] * L, 0, dz, STEP, LEAD, STEP)
  return p
end

-- Our builder's way: a radius-R arc tangent to both lanes, laid one-way, points about 2 m apart.
local function arcPath(turn, L, R)
  local p = {}
  local h = L / 2
  if turn == "right" then
    -- tangent to z = +h (heading +x) and x = -h (heading +z); centre at (-h - R, h + R)
    local cx, cz = -h - R, h + R
    straight(p, cx, h, 1, 0, -LEAD, -ARCSTEP, STEP)
    local n = math.max(2, math.ceil((math.pi / 2 * R) / ARCSTEP))
    for i = 0, n do
      local a = -math.pi / 2 + (math.pi / 2) * i / n          -- from north of the centre round to east
      p[#p+1] = { x = cx + R * math.cos(a), z = cz + R * math.sin(a) }
    end
    straight(p, -h, cz, 0, 1, STEP, LEAD, STEP)
  else
    -- tangent to z = +h (heading +x) and x = +h (heading -z); centre at (h - R, h - R)
    local cx, cz = h - R, h - R
    straight(p, cx, h, 1, 0, -LEAD, -ARCSTEP, STEP)
    local n = math.max(2, math.ceil((math.pi / 2 * R) / ARCSTEP))
    for i = 0, n do
      local a = math.pi / 2 - (math.pi / 2) * i / n            -- from +z (south of centre) round to +x
      p[#p+1] = { x = cx + R * math.cos(a), z = cz + R * math.sin(a) }
    end
    straight(p, h, cz, 0, -1, STEP, LEAD, STEP)
  end
  return p
end

-- Wheel/corner points of the rig at one step.
local function corners(s)
  local pts = {}
  local fx, fz = math.sin(s.heading), math.cos(s.heading)
  local lx, lz = math.cos(s.heading), -math.sin(s.heading)
  local tw, trw = rig.towWidth / 2, rig.trailerWidth / 2
  local function add(bx, bz, ox, oz, w) pts[#pts+1] = { bx + ox * w, bz + oz * w }; pts[#pts+1] = { bx - ox * w, bz - oz * w } end
  add(s.x, s.z, lx, lz, tw)                                                      -- tow rear wheels
  add(s.x + fx * (rig.wheelbase + 1.2), s.z + fz * (rig.wheelbase + 1.2), lx, lz, tw) -- tow front corners
  local tfx, tfz = math.sin(s.trailerHeading), math.cos(s.trailerHeading)
  local tlx, tlz = math.cos(s.trailerHeading), -math.sin(s.trailerHeading)
  add(s.ax, s.az, tlx, tlz, trw)                                                 -- trailer wheels
  add(s.hx + tfx * 1.0, s.hz + tfz * 1.0, tlx, tlz, trw)                         -- trailer front corners
  return pts
end

local function measure(st, turn, L, pointsOf)
  pointsOf = pointsOf or corners
  local off, wrong, vmin = 0, 0, 99
  for _, s in ipairs(st) do
    if math.abs(s.x) < 40 and math.abs(s.z) < 40 then
      vmin = math.min(vmin, s.v)
      for _, q in ipairs(pointsOf(s)) do
        local x, z = q[1], q[2]
        local inMain, inSide = math.abs(z) <= L, math.abs(x) <= L
        if not inMain and not inSide then
          -- outside both roads: distance to the nearer road
          off = math.max(off, math.min(math.abs(z) - L, math.abs(x) - L))
        elseif inMain and not inSide and x < 0 then
          wrong = math.max(wrong, -z)                 -- eastbound approach: belongs on z > 0
        elseif inSide and not inMain then
          if turn == "right" and z > 0 then wrong = math.max(wrong, x) end     -- southbound: x < 0
          if turn == "left" and z < 0 then wrong = math.max(wrong, -x) end     -- northbound: x > 0
        end
      end
    end
  end
  return off, wrong, vmin
end

-- The laid line on its own: sample it every 0.25 m and score it like a zero-width vehicle.
local function lineScore(path, turn, L)
  local fake = {}
  for k = 1, #path - 1 do
    local a, b = path[k], path[k + 1]
    local n = math.max(1, math.ceil(math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2) / 0.25))
    for i = 0, n - 1 do
      local t = i / n
      local x, z = a.x + (b.x - a.x) * t, a.z + (b.z - a.z) * t
      fake[#fake + 1] = { x = x, z = z, v = 99 }
    end
  end
  local off, wrong = measure(fake, turn, L, function(s) return { { s.x, s.z } } end)
  return off, wrong
end

-- How far the truck and trailer stray from the line (axle centres), within 30 m of the centre.
local function tracking(st, path)
  local tOut, tIn, trIn = 0, 0, 0
  for _, s in ipairs(st) do
    if math.abs(s.x) < 30 and math.abs(s.z) < 30 then
      local o = S.offsetFromPath(path, s.x, s.z)
      local oa = S.offsetFromPath(path, s.ax, s.az)
      tOut, tIn = math.max(tOut, o), math.max(tIn, -o)
      trIn = math.max(trIn, math.abs(oa))
    end
  end
  return tOut, tIn, trIn
end

local rows, panels = {}, {}
local function run(label, path, turn, L, keep)
  local h0 = math.atan2(path[2].x - path[1].x, path[2].z - path[1].z)
  local st = S.simulate(path, rig, drv, { x = path[1].x, z = path[1].z, heading = h0, speed = 30 }, { speedLimitKmh = 40 })
  local off, wrong, vmin = measure(st, turn, L)
  local lOff, lWrong = lineScore(path, turn, L)
  local a, b, trl = tracking(st, path)
  -- offsets are + left: for a right turn the outside is left, for a left turn the outside is right
  local out, inn = a, b
  if turn == "left" then out, inn = b, a end
  rows[#rows+1] = string.format("%-5s L=%dm  %-11s | line: off %4.1f wrong %4.1f | truck off line: out %3.1f in %3.1f, trailer %3.1f | wheels: off road %4.1f into oncoming %4.1f | slowest %4.1f",
    turn, L, label, lOff, lWrong, out, inn, trl, off, wrong, vmin)
  if keep then
    local W, R, sc = 560, 26, 560 / 52
    local function P(x, z) return string.format("%.1f,%.1f", (x + R) * sc, (z + R) * sc) end
    local g = { string.format('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" font-family="sans-serif">', W, W + 20, W, W + 20),
      '<rect width="100%" height="100%" fill="#fff"/>' }
    -- roads
    g[#g+1] = string.format('<rect x="0" y="%.1f" width="%d" height="%.1f" fill="#e5e7eb"/>', (R - L) * sc, W, 2 * L * sc)
    g[#g+1] = string.format('<rect x="%.1f" y="0" width="%.1f" height="%d" fill="#e5e7eb"/>', (R - L) * sc, 2 * L * sc, W)
    g[#g+1] = string.format('<line x1="0" y1="%.1f" x2="%d" y2="%.1f" stroke="#facc15" stroke-width="1.5" stroke-dasharray="8 6"/>', R * sc, W, R * sc)
    g[#g+1] = string.format('<line x1="%.1f" y1="0" x2="%.1f" y2="%d" stroke="#facc15" stroke-width="1.5" stroke-dasharray="8 6"/>', R * sc, R * sc, W)
    local pp = {}
    for _, q in ipairs(path) do if math.abs(q.x) < R and math.abs(q.z) < R then pp[#pp+1] = P(q.x, q.z) end end
    g[#g+1] = string.format('<polyline points="%s" fill="none" stroke="#2563eb" stroke-width="2" stroke-dasharray="5 3"/>', table.concat(pp, " "))
    local function track(fn, col)
      local a, b = {}, {}
      for k = 1, #st, 5 do
        local s = st[k]
        local x1, z1, x2, z2 = fn(s)
        if math.abs(x1) < R and math.abs(z1) < R then a[#a+1] = P(x1, z1) end
        if math.abs(x2) < R and math.abs(z2) < R then b[#b+1] = P(x2, z2) end
      end
      for _, t in ipairs({ a, b }) do
        if #t > 1 then g[#g+1] = string.format('<polyline points="%s" fill="none" stroke="%s" stroke-width="1.6"/>', table.concat(t, " "), col) end
      end
    end
    track(function(s)
      local c = corners(s); return c[3][1], c[3][2], c[4][1], c[4][2] end, "#16a34a")   -- truck front corners
    track(function(s)
      local c = corners(s); return c[5][1], c[5][2], c[6][1], c[6][2] end, "#dc2626")   -- trailer wheels
    g[#g+1] = string.format('<text x="6" y="%d" font-size="13">%s turn, lanes %d m apart: %s</text>', W + 15, turn, L, label)
    g[#g+1] = '</svg>'
    panels[#panels+1] = { name = string.format("curve-%s-L%d-%s.svg", turn, L, label:gsub("[^%w]+", "")), svg = table.concat(g, "\n") }
  end
end

for _, L in ipairs({ 3, 4, 6 }) do
  for _, turn in ipairs({ "right", "left" }) do
    run("mod corner", modPath(turn, L), turn, L, L == 6)
    for _, R in ipairs({ 8, 10, 12, 15, 20 }) do
      run(string.format("arc R=%d", R), arcPath(turn, L, R), turn, L, L == 6 and R == 12)
    end
  end
end

-- Point spacing on the arc: AutoDrive slows by the bend between neighbouring links, so wider spacing
-- on the same curve means a bigger bend per point and a slower turn. Our builder controls spacing.
rows[#rows+1] = "-- spacing on a 12 m arc, lanes 6 m apart --"
for _, step in ipairs({ 1, 2, 3, 4, 5, 6 }) do
  ARCSTEP = step
  for _, turn in ipairs({ "right", "left" }) do
    run(string.format("R=12 every %dm", step), arcPath(turn, 6, 12), turn, 6, false)
  end
end
ARCSTEP = 2

-- Target speed by ONE deliberate sharpest bend: the curve's points all stay on the arc, the last two
-- pieces each turn by theta (so the point between them bends by theta), the rest are short and gentle.
-- AutoDrive only counts bends still AHEAD, so the sharp one sits at the end to hold the speed all the
-- way round.
local function thetaFor(v) return 5 + 25 * (60 - v) / 48 end

local function speedArcPath(turn, L, R, v)
  local th = math.rad(thetaFor(v))
  local p = {}
  local h = L / 2
  local cx, cz, a0, dir, ex, ez, edx, edz
  if turn == "right" then cx, cz, a0, dir = -h - R, h + R, -math.pi / 2, 1; ex, ez, edx, edz = -h, h + R, 0, 1
  else cx, cz, a0, dir = h - R, h - R, math.pi / 2, -1; ex, ez, edx, edz = h, h - R, 0, -1 end
  straight(p, cx, h, 1, 0, -LEAD, -ARCSTEP, STEP)
  local smooth = math.pi / 2 - 2 * th
  local nS = math.max(1, math.ceil(smooth * R / ARCSTEP))
  local angles = {}
  for i = 0, nS do angles[#angles + 1] = smooth * i / nS end
  angles[#angles + 1] = smooth + th
  angles[#angles + 1] = smooth + 2 * th
  for _, a in ipairs(angles) do
    local ang = a0 + dir * a
    p[#p + 1] = { x = cx + R * math.cos(ang), z = cz + R * math.sin(ang) }
  end
  straight(p, ex, ez, edx, edz, STEP, LEAD, STEP)
  return p
end

-- The twin scans a fixed 20 m for bends (AutoDrive 3.0.0.8). 3.0.1.2 scans 20 m x mass factor (1-3) x
-- speed factor ((km/h + 10) / 20), and never more than 20 points. Bracket it with fixed windows.
local baseDriver = drv
for _, win in ipairs({ 20, 50, 100 }) do
  drv = {}
  for k, v in pairs(baseDriver) do drv[k] = v end
  drv.speedScanMetres = win
  rows[#rows+1] = string.format("-- target speed by one sharpest bend at the end, lanes 6 m apart, bend scan %d m --", win)
  for _, c in ipairs({ { "right", 8, 20 }, { "right", 10, 20 }, { "right", 12, 20 },
                       { "left", 10, 22 }, { "left", 12, 23 }, { "left", 15, 25 } }) do
    run(string.format("R=%d aim %d", c[2], c[3]), speedArcPath(c[1], 6, c[2], c[3]), c[1], 6, false)
  end
  run("R=12 even 2m", arcPath("right", 6, 12), "right", 6, false)
  run("mod corner", modPath("right", 6), "right", 6, false)
end
drv = baseDriver

print(table.concat(rows, "\n"))
local f = io.open(OUT .. "/curves_results.txt", "w"); f:write(table.concat(rows, "\n"), "\n"); f:close()
for _, p in ipairs(panels) do
  f = io.open(OUT .. "/" .. p.name, "w"); f:write(p.svg); f:close()
end

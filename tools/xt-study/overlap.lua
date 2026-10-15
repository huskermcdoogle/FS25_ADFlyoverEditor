-- Two junctions close together on a narrow two-way track: the stretch between their mouths becomes two
-- one-way lanes joined at a guard point at each mouth (and optionally at middle guards). Two trucks
-- enter from opposite ends at once, or a little apart. AutoDrive's "who waits" check
-- (CollisionDetectionModule:detectAdTrafficOnRoute, 3.0.1.2) is replayed for both every 20 frames:
-- a truck waits if one of its next points 2-5 is a shared point within 4 points of the other truck,
-- reached from a different point, and the other is not already waiting. The track is one truck wide,
-- so the two meet if their fronts pass each other.
-- The road is straight, so motion is straight-line with SweptSim's captured truck: steering node ahead
-- of the rear axle, front bumper 6.4 m ahead of it, waypoint advance at minDistance.
-- Usage: lua overlap.lua <repo scripts/editor dir>
dofile(arg[1] .. "/SweptSim.lua")
local rig = SweptSim.EXAMPLE_RIG
local FRONT = rig.wheelbase + 1.2 - rig.steerNodeOffset
local MIND = rig.minDistance
local REAR = rig.steerNodeOffset + rig.hitchOffset * 0 + rig.trailerLength + 2.0 + 1.0  -- tail of the trailer behind the steering node, about 10.7 m
local DT, CHECK = 1 / 60, 20

-- Points along x for one truck's route. Shared ids are the guards: "GA" at 0, "GB" at D, middle
-- guards "M1".. evenly spaced. Each truck's own lane points get their own ids.
local function route(dir, D, s, nMid)
  local guards = { { x = 0, id = "GA" }, { x = D, id = "GB" } }
  for k = 1, nMid do guards[#guards + 1] = { x = D * k / (nMid + 1), id = "M" .. k } end
  local xs = {}
  for x = -60, 0, s do xs[#xs + 1] = { x = x, id = dir .. "in" .. x } end
  local n = math.max(1, math.floor(D / s + 0.5))
  -- TWOWAY: the stretch stays one two-way line, so both trucks share its points
  for i = 1, n - 1 do xs[#xs + 1] = { x = D * i / n, id = (TWOWAY and "T" or dir .. "lane") .. i } end
  for _, g in ipairs(guards) do xs[#xs + 1] = g end
  for x = D + s, D + 60, s do xs[#xs + 1] = { x = x, id = dir .. "out" .. x } end
  table.sort(xs, function(a, b) return a.x < b.x end)
  local pts = {}
  for _, q in ipairs(xs) do
    if #pts == 0 or q.x - pts[#pts].x > 0.4 or q.id:sub(1, 1) == "G" or q.id:sub(1, 1) == "M" then
      if #pts > 0 and math.abs(q.x - pts[#pts].x) <= 0.4 then pts[#pts] = q else pts[#pts + 1] = q end
    end
  end
  if dir == "W" then   -- truck from the B end drives the other way: mirror and reverse
    local r = {}
    for i = #pts, 1, -1 do r[#r + 1] = { x = pts[i].x, id = pts[i].id:gsub("^E", "W") } end
    for _, q in ipairs(r) do if q.id:sub(1, 1) == "E" then q.id = "W" .. q.id:sub(2) end end
    pts = r
  end
  return pts
end

-- In the TWOWAY layout a link is two-way when both of its ends are on the stretch (guards included).
local function onStretch(id) return id == "GA" or id == "GB" or id:sub(1, 1) == "T" end
local function dualLink(a, b) return TWOWAY and a ~= nil and b ~= nil and onStretch(a.id) and onStretch(b.id) end

local function current(tr)
  -- advance while the steering node is within MIND of the current point (one point per frame)
  local p = tr.pts[tr.i]
  if p and math.abs(p.x - tr.pos) * 1 < MIND or (p and (p.x - tr.pos) * tr.sign < 0) then tr.i = tr.i + 1 end
end

local function simulate(D, s, nMid, delay, vKmh, decel)
  local E = { pts = route("E", D, s, nMid), sign = 1, pos = -40, v = vKmh / 3.6, wait = false, start = 0 }
  local W = { pts = route("W", D, s, nMid), sign = -1, pos = D + 40, v = vKmh / 3.6, wait = false, start = delay }
  E.i, W.i = 1, 1
  for _, tr in ipairs({ E, W }) do
    while tr.pts[tr.i] and (tr.pts[tr.i].x - tr.pos) * tr.sign < MIND do tr.i = tr.i + 1 end
  end
  local t, frame = 0, 0
  while t < 40 do
    frame = frame + 1
    t = t + DT
    if frame % CHECK == 0 then
      for _, pair in ipairs({ { E, W }, { W, E } }) do
        local me, other = pair[1], pair[2]
        me.wait = false
        -- AutoDrive skips the check while the truck is on a two-way link, and otherwise looks at its
        -- next 5 points plus every further point while the links stay two-way.
        local onDual = dualLink(me.pts[me.i - 1], me.pts[me.i])
        local reach = 4
        while dualLink(me.pts[me.i + reach], me.pts[me.i + reach + 1]) do reach = reach + 1 end
        if t >= me.start and not onDual then
          for j = 1, reach do
            local a, prev = me.pts[me.i + j], me.pts[me.i + j - 1]
            if a and prev then
              for k = -4, 4 do
                local o, oprev = other.pts[other.i + k], other.pts[other.i + k - 1]
                if o and oprev and o.id == a.id and oprev.id ~= prev.id and not other.wait and t >= other.start then
                  me.wait = true
                end
              end
            end
          end
        end
      end
    end
    for _, tr in ipairs({ E, W }) do
      if t >= tr.start then
        if tr.wait then tr.v = math.max(0, tr.v - decel * DT) else tr.v = math.min(vKmh / 3.6, tr.v + 1.2 * DT) end
        tr.pos = tr.pos + tr.sign * tr.v * DT
        current(tr)
      end
    end
    if TRACE and frame % CHECK == 0 then
      print(string.format("t=%5.2f  E at %6.1f %4.1f km/h next %-8s wait %-5s | W at %6.1f %4.1f km/h next %-8s wait %s",
        t, E.pos, E.v * 3.6, E.pts[E.i] and E.pts[E.i].id or "-", tostring(E.wait),
        W.pos, W.v * 3.6, W.pts[W.i] and W.pts[W.i].id or "-", tostring(W.wait)))
    end
    -- Bodies on the narrow stretch [0, D] only: before its entry guard a truck is still on its own road,
    -- after its exit guard it has turned off into the next junction.
    local eLo, eHi = math.max(0, E.pos - REAR), math.min(D, E.pos + FRONT)
    local wLo, wHi = math.max(0, W.pos - FRONT), math.min(D, W.pos + REAR)
    if eHi > eLo and wHi > wLo and eHi > wLo and wHi > eLo then
      -- HEAD: both cabs are on the stretch, facing each other. TAIL: one cab noses into the other's
      -- trailer as it leaves.
      local eCab = E.pos + FRONT > 0 and E.pos + FRONT < D + FRONT and E.pos < D
      local wCab = W.pos - FRONT < D and W.pos - FRONT > -FRONT and W.pos > 0
      if eCab and wCab then return "HEAD", eHi - wLo end
      return "TAIL", eHi - wLo
    end
    if E.pos > D + 25 and W.pos < -25 then return "ok", 0 end
    if E.pos > D + 25 or W.pos < -25 then
      -- one is through; the other may still be waiting: that is fine
      return "ok", 0
    end
  end
  return "stuck", 0
end

if os.getenv("ONE") then
  TRACE = true
  local D, s, nMid, delay = os.getenv("ONE"):match("(%S+) (%S+) (%S+) (%S+)")
  local ids = {}
  for _, p in ipairs(route("E", tonumber(D), tonumber(s), tonumber(nMid))) do
    if p.x > -25 and p.x < tonumber(D) + 25 then ids[#ids + 1] = p.id .. "@" .. string.format("%.0f", p.x) end
  end
  print(table.concat(ids, " "))
  print(simulate(tonumber(D), tonumber(s), tonumber(nMid), tonumber(delay), 20, 3.0))
  return
end
print("Two trucks enter a narrow guarded stretch from opposite ends. MEET = they meet head-on on it.")
print("Each row: how many of 25 start offsets (-6 s .. +6 s) end in a meeting.")
for _, layout in ipairs({ "guarded one-way lanes", "left two-way" }) do
TWOWAY = (layout == "left two-way")
for _, v in ipairs({ 20, 25 }) do
  for _, decel in ipairs({ 3.0 }) do
    print(string.format("\n== %s, %d km/h, brake %.0f m/s2", layout, v, decel))
    print("  stretch | points every | middle guards | head-on / tail clip / stuck, of 25")
    for _, D in ipairs({ 10, 15, 20, 25, 30, 40 }) do
      for _, s in ipairs({ 4, 5 }) do
        for _, nMid in ipairs({ 0, 1 }) do
          local n = { HEAD = 0, TAIL = 0, stuck = 0, ok = 0 }
          for k = -12, 12 do
            local r = simulate(D, s, nMid, k * 0.5, v, decel)
            n[r] = n[r] + 1
          end
          print(string.format("   %3d m  |     %d m      |       %d       |  %2d  /  %2d  /  %2d", D, s, nMid, n.HEAD, n.TAIL, n.stuck))
        end
      end
    end
  end
end
end

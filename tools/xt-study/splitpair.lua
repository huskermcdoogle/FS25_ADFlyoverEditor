-- One junction on a narrow two-way track. Truck X arrives along the track; truck Y leaves the
-- junction onto it. Two layouts for the last D metres before the mouth:
--   "split": two one-way lanes joined at the split S and at the guard J at the mouth (doc 06's narrow
--            version);
--   "two-way": the track stays one two-way line right up to the mouth J (today's builder).
-- AutoDrive's "who waits" check (3.0.1.2) is replayed for both trucks every 20 frames: it is skipped on
-- a two-way link; otherwise it covers the next 5 points plus every further point while the links stay
-- two-way; a truck waits if one of those points (not the first) is within 4 points of the other truck,
-- reached from a different point, and the other is not already waiting.
-- The track is one truck wide, so the trucks meet if their bodies overlap anywhere on it (x < 0).
-- Straight-line motion with SweptSim's captured truck numbers.
-- Usage: lua splitpair.lua <repo scripts/editor dir>
dofile(arg[1] .. "/SweptSim.lua")
local rig = SweptSim.EXAMPLE_RIG
local FRONT = rig.wheelbase + 1.2 - rig.steerNodeOffset
local REAR = rig.steerNodeOffset + rig.trailerLength + 3.0
local MIND, DT, CHECK = rig.minDistance, 1 / 60, 20

-- Points shared by both trucks: the two-way track (ids "R", two-way), S, J, and in the two-way layout
-- the stretch S..J ("T", two-way). Own points: X's lane in, Y's lane out, each truck's junction turn.
local function build(layout, D, s)
  local track = {}
  for x = -150, -D - 0.5, 5 do track[#track + 1] = { x = x, id = "R" .. x, dual = true } end
  local stretch = {}
  local n = math.max(1, math.floor(D / s + 0.5))
  for i = 1, n - 1 do stretch[#stretch + 1] = -D + D * i / n end
  local X, Y = {}, {}
  for _, p in ipairs(track) do X[#X + 1] = p end
  X[#X + 1] = { x = -D, id = "S", dual = true }
  for i, x in ipairs(stretch) do
    X[#X + 1] = { x = x, id = (layout == "two-way") and ("T" .. i) or ("Xin" .. i), dual = (layout == "two-way") }
  end
  X[#X + 1] = { x = 0, id = "J", dual = (layout == "two-way") }
  for d = 3, 60, 3 do X[#X + 1] = { x = d, id = "Xturn" .. d } end
  for d = 60, 3, -3 do Y[#Y + 1] = { x = d, id = "Yturn" .. d } end
  Y[#Y + 1] = { x = 0, id = "J", dual = (layout == "two-way") }
  for i = #stretch, 1, -1 do
    Y[#Y + 1] = { x = stretch[i], id = (layout == "two-way") and ("T" .. i) or ("Yout" .. i), dual = (layout == "two-way") }
  end
  Y[#Y + 1] = { x = -D, id = "S", dual = true }
  for i = #track, 1, -1 do Y[#Y + 1] = track[i] end
  return X, Y
end

-- A link is two-way when both ends are two-way points (the track, S, and the stretch in "two-way").
local function dual(a, b) return a ~= nil and b ~= nil and a.dual and b.dual end

local function simulate(layout, D, s, delay, vKmh, decel)
  local Xp, Yp = build(layout, D, s)
  local X = { pts = Xp, sign = 1, pos = -100, v = vKmh / 3.6, start = 0 }
  local Y = { pts = Yp, sign = -1, pos = 45, v = vKmh / 3.6, start = delay }
  for _, tr in ipairs({ X, Y }) do
    tr.i, tr.wait = 1, false
    while tr.pts[tr.i] and (tr.pts[tr.i].x - tr.pos) * tr.sign < MIND do tr.i = tr.i + 1 end
  end
  local t, frame = 0, 0
  while t < 60 do
    frame, t = frame + 1, t + DT
    if frame % CHECK == 0 then
      for _, pair in ipairs({ { X, Y }, { Y, X } }) do
        local me, other = pair[1], pair[2]
        me.wait = false
        local reach = 4
        while dual(me.pts[me.i + reach], me.pts[me.i + reach + 1]) do reach = reach + 1 end
        if t >= me.start and t >= other.start and not dual(me.pts[me.i - 1], me.pts[me.i]) then
          for j = 1, reach do
            local a, prev = me.pts[me.i + j], me.pts[me.i + j - 1]
            for k = -4, 4 do
              local o, oprev = other.pts[other.i + k], other.pts[other.i + k - 1]
              if a and prev and o and oprev and o.id == a.id and oprev.id ~= prev.id and not other.wait then me.wait = true end
            end
          end
        end
      end
    end
    for _, tr in ipairs({ X, Y }) do
      if t >= tr.start then
        if tr.wait then tr.v = math.max(0, tr.v - decel * DT) else tr.v = math.min(vKmh / 3.6, tr.v + 1.2 * DT) end
        tr.pos = tr.pos + tr.sign * tr.v * DT
        local p = tr.pts[tr.i]
        if p and (math.abs(p.x - tr.pos) < MIND or (p.x - tr.pos) * tr.sign < 0) then tr.i = tr.i + 1 end
      end
    end
    -- bodies on the track (x < 0); past the mouth a truck is in the junction, off the track
    local xLo, xHi = X.pos - REAR, math.min(0, X.pos + FRONT)
    local yLo, yHi = Y.pos - FRONT, math.min(0, Y.pos + REAR)
    if t >= Y.start and xHi > xLo and yHi > yLo and xHi > yLo and yHi > xLo then return "MEET" end
    if X.pos > 30 or Y.pos < -120 then return "ok" end
  end
  return "stuck"
end

print("One junction on a narrow two-way track: a truck arriving and a truck leaving. Meetings on the track, of 41 start offsets (-10 s .. +10 s).")
for _, v in ipairs({ 20, 25 }) do
  print(string.format("\n== %d km/h, brake 3 m/s2", v))
  print("  last stretch | points every | split (guarded lanes) | two-way to the mouth")
  for _, D in ipairs({ 10, 15, 20, 25, 30 }) do
    for _, s in ipairs({ 4, 5 }) do
      local c = {}
      for _, layout in ipairs({ "split", "two-way" }) do
        local m, st = 0, 0
        for k = -20, 20 do
          local r = simulate(layout, D, s, k * 0.5, v, 3.0)
          if r == "MEET" then m = m + 1 elseif r == "stuck" then st = st + 1 end
        end
        c[#c + 1] = string.format("%2d meet, %2d stuck", m, st)
      end
      print(string.format("     %3d m    |     %d m      |   %s   |   %s", D, s, c[1], c[2]))
    end
  end
end

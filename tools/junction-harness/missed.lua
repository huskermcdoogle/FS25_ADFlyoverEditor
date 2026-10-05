-- EVERY TURN OF A PART, MISSED ON PURPOSE, ONE AT A TIME: lock X Z, group the clear's turn wiring into
-- connected pieces (in a fixed order, by place), keep piece K (the clear refuses its points, as the bound
-- refuses a point outside the junction), clear, and print what the check says of each join and teal dot
-- that runs over the kept piece. PIECES=1 only prints how many pieces there are. Run by regmissed.sh;
-- env: LEAVE=1|0 (through roads kept or not), TR (turn radius), META (a drop's meta.txt), GAMERIG=1 and
-- GAMEFLAGS=1 (the game's rig and checks), PATH_OUT=1 (each join's drive, kept points marked K).
LOG_ECHO = false
local H = dofile("harness.lua")
if os.getenv("META") and os.getenv("META") ~= "" then dofile("adoptmeta.lua")(os.getenv("META")) end
AutoDrive.FLYOVER_DEBUG_CAPTURE = false
if os.getenv("GAMERIG") == "1" then ADFlyoverSweptPath = { rig = { lookAhead = 10.32, trailerLength = 7.08 } } end
local E = ADFlyoverEditor
local jp = H.lock(tonumber(arg[1]), tonumber(arg[2]), { mode = "clear", radius = 12,
    turnRadius = tonumber(os.getenv("TR") or "12"), leaveThrough = (os.getenv("LEAVE") == "1") })
if jp == nil then print("REFUSED " .. tostring(E.junctionRefused)) return end
if os.getenv("GAMEFLAGS") == "1" then E.junctionCheckSurface, E.junctionCheckObstacles, E.junctionSwept = true, true, true end
local isT = {}
for _, w in ipairs(jp.turnDebris or {}) do isT[w] = true end
local pieces, seen = {}, {}
local order = {}
for _, w in ipairs(jp.turnDebris or {}) do order[#order + 1] = w end
table.sort(order, function(a, b) if a.x ~= b.x then return a.x < b.x end return a.z < b.z end)
for _, w in ipairs(order) do
  if not seen[w] then
    local piece, st = {}, { w }
    seen[w] = true
    while #st > 0 do
      local c = table.remove(st)
      piece[#piece + 1] = c
      for _, lst in ipairs({ c.out or {}, c.incoming or {} }) do
        for _, id in ipairs(lst) do
          local o = ADGraphManager:getWayPointById(id)
          if o ~= nil and isT[o] and not seen[o] then seen[o] = true st[#st + 1] = o end
        end
      end
    end
    if #piece >= 2 then pieces[#pieces + 1] = piece end
  end
end
if os.getenv("PIECES") == "1" then print("PIECES " .. #pieces) return end
local K = tonumber(os.getenv("K") or "1")
local piece = pieces[K]
if piece == nil then print("NONE") return end
local keep = {}
for _, w in ipairs(piece) do keep[#keep + 1] = { w.x, w.z } end
local function kept(w)
  for _, k in ipairs(keep) do
    if math.abs(w.x - k[1]) < 0.01 and math.abs(w.z - k[2]) < 0.01 then return true end
  end
  return false
end
do
  local i = 1
  while true do
    local name, fn = debug.getupvalue(E.applyJunctionClear, i)
    if name == nil then error("no jxRemove") end
    if name == "jxRemove" then
      -- Both functions are also held in a global: Lua 5.1's debug.setupvalue sets the upvalue with no
      -- garbage-collector write barrier, so a closure reachable only through it can be collected while
      -- still in use. With nothing else holding them, a run segfaulted part-way through the clear,
      -- depending only on when the collector ran (39, through roads off, K=3).
      MISSED_KEEP = { fn = fn }
      MISSED_KEEP.hook = function(which, why, whole)
        local w = which
        if type(w) ~= "table" then w = ADGraphManager:getWayPointById(which) end
        if w ~= nil and kept(w) then return false end
        return fn(which, why, whole)
      end
      debug.setupvalue(E.applyJunctionClear, i, MISSED_KEEP.hook)
      break
    end
    i = i + 1
  end
end
local cx, cz = 0, 0
for _, k in ipairs(keep) do cx, cz = cx + k[1], cz + k[2] end
cx, cz = cx / #keep, cz / #keep
E.junctionLastCheck = nil
local ok, err = pcall(H.apply)
if not ok then print("CLEAR STOPPED " .. tostring(err)) return end
local r = E.junctionLastCheck
local said = {}
for _, j in ipairs((r and r.joins) or {}) do
  local on = false
  for _, p in ipairs(j.path or {}) do if kept(p) then on = true break end end
  if on then
    local whose = ""
    if j.part ~= nil then whose = "=" .. tostring(j.part.name) end
    if j.twin ~= nil then whose = "=" .. tostring(j.twin.name) end
    said[#said + 1] = string.format("join %s->%s at (%.1f,%.1f) %s%s", tostring(j.from), tostring(j.to), j.x, j.z, j.why, whose)
    if os.getenv("PATH_OUT") == "1" then local t = {} for _, p in ipairs(j.path) do t[#t+1] = string.format("(%.2f,%.2f)%s", p.x, p.z, kept(p) and "K" or "") end print("PATH " .. table.concat(t, " ")) end
  end
end
-- Where no join runs over the kept piece (it no longer leads anywhere, or nothing leads into it), what
-- the check said of it instead: a leftover or spur line at one of its points, or naming one; or a teal
-- dot on one of its points, on a point linked to one, or naming one as where a cut turn's end starts
-- ("said as dot:<reason>" - a dot read as another part's says dot:part, and is not a report of a miss;
-- nor is one read as another part's turn, left by the clear: dot:twin, dot:twinwait, dot:twinstuck).
local other = {}
if #said == 0 then
  for _, it in ipairs((r and r.issues) or {}) do
    if it.kind == "leftover" or it.kind == "spur" then
      local hit = kept(it)
      for a, b in tostring(it.text):gmatch("%((%-?[%d.]+), (%-?[%d.]+)%)") do
        for _, k in ipairs(keep) do
          if math.abs(tonumber(a) - k[1]) <= 0.06 and math.abs(tonumber(b) - k[2]) <= 0.06 then hit = true end
        end
      end
      if hit then other[#other + 1] = string.format("said as %s at (%.1f,%.1f)", it.kind, it.x, it.z) end
    end
  end
  local nextTo = {}
  for _, w in ipairs(ADGraphManager:getWayPoints()) do
    if w ~= nil and kept(w) then
      for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
        for _, id in ipairs(lst) do
          local t = ADGraphManager:getWayPointById(id)
          if t ~= nil then nextTo[#nextTo + 1] = t end
        end
      end
    end
  end
  for _, d in ipairs((r and r.dots) or {}) do
    local hit = kept(d) or (d.fx ~= nil and kept({ x = d.fx, z = d.fz }))
    for _, t in ipairs(nextTo) do
      if math.abs(t.x - d.x) < 0.01 and math.abs(t.z - d.z) < 0.01 then hit = true end
    end
    if hit then other[#other + 1] = string.format("said as dot:%s at (%.1f,%.1f)", tostring(d.why), d.x, d.z) end
  end
end
local verdict = "no join over it"
if #said > 0 then verdict = table.concat(said, "; ")
elseif #other > 0 then verdict = "no join over it; " .. table.concat(other, "; ") end
print(string.format("PIECE %d of %d, %d point(s) round (%.1f, %.1f): %s", K, #pieces, #piece, cx, cz, verdict))

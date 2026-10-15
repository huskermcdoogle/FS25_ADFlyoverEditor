-- THE SHAPE OF A JUNCTION'S WIRED TURNS: for one junction, every connector the clear would take as
-- turn wiring (through roads kept), as a chain from the lane it leaves to the lane it joins, with its
-- heading change, its length and the radius those imply. The user's idea (2026-10-05): a Y merge shows
-- in its connectors - long, gentle, joining nearly tangentially - where a T's turns bend sharply.
--   lua conn_shape.lua X Z
-- Prints one line per connector: CONN <turn deg> <length m> <radius m> <from x,z> <to x,z> <kind>
-- kind: "turn" when one end is on the side road and the other on the main road (each end followed
-- 12 m out along its lane, then matched to the nearest of the classifier's own arms); "same-road" otherwise - a
-- piece that leaves a road and rejoins the same road (40's duplicate beside the eastbound lane, 4
-- degrees) says nothing about how the side road meets the main road.
local H = dofile("harness.lua")
local x, z = tonumber(arg[1]), tonumber(arg[2])
local jp = H.lock(x, z, { mode = "clear", radius = 12, leaveThrough = true })
if jp == nil then print("REFUSED") return end
local wire = {}
for _, w in ipairs(jp.turnDebris or {}) do wire[w.id] = true end
local function wp(id) return ADGraphManager:getWayPointById(id) end
local function ins(w)
    local r = {}
    for _, id in ipairs(w.incoming or {}) do r[#r + 1] = id end
    table.sort(r)
    return r
end
local c = jp._branchCentre or jp.tracksCentre or { x = x, z = z }
local function sep(a, b) local d = math.abs(a - b) % 360 if d > 180 then d = 360 - d end return d end
local function bearingOf(p) return math.deg(math.atan2(p.x - c.x, p.z - c.z)) % 360 end
-- The arms, as the classifier read them: its main-road arms and each side road it read.
local arms = {}
for _, m in ipairs(jp._mainArms or {}) do arms[#arms + 1] = { b = m, main = true } end
for _, s in pairs(jp._sideRead or {}) do if s.bearing then arms[#arms + 1] = { b = s.bearing, main = false } end end
-- Which road an end is on: walk out along its own lane (upstream from where the connector leaves,
-- downstream from where it joins) until 12 m from the centre, the way the classifier reads an arm,
-- and take the nearest arm there. A bearing read a metre from the centre is mostly noise.
local function onMain(p, upstream)
    local cur, seen = p, { [p.id] = true }
    for _ = 1, 60 do
        if (cur.x - c.x) ^ 2 + (cur.z - c.z) ^ 2 >= 12 * 12 then break end
        local nxt
        local lst = {}
        for _, id in ipairs((upstream and cur.incoming or cur.out) or {}) do lst[#lst + 1] = id end
        table.sort(lst)
        for _, id in ipairs(lst) do
            if not wire[id] and not seen[id] then nxt = wp(id) break end
        end
        if nxt == nil then break end
        seen[nxt.id] = true
        cur = nxt
    end
    local b, best, isMain = bearingOf(cur), math.huge, true
    for _, a in ipairs(arms) do
        local d = sep(b, a.b)
        if d < best then best, isMain = d, a.main end
    end
    return isMain
end
local function heading(a, b) return math.atan2(b.x - a.x, b.z - a.z) end
local function wrap(d) while d > math.pi do d = d - 2 * math.pi end while d < -math.pi do d = d + 2 * math.pi end return d end
-- Chains start at a wired point fed from a point that is not wiring (the fork on the lane it leaves).
local starts = {}
for id in pairs(wire) do
    local w = wp(id)
    for _, pid in ipairs(ins(w)) do
        if not wire[pid] then starts[#starts + 1] = { from = pid, first = id } end
    end
end
table.sort(starts, function(a, b) return a.first < b.first or (a.first == b.first and a.from < b.from) end)
for _, s in ipairs(starts) do
    local path = { wp(s.from), wp(s.first) }
    local seen = { [s.first] = true }
    local cur = wp(s.first)
    local ended = false
    for _ = 1, 200 do
        local nxt = nil
        local outs = {}
        for _, oid in ipairs(cur.out or {}) do outs[#outs + 1] = oid end
        table.sort(outs)
        for _, oid in ipairs(outs) do
            if wire[oid] and not seen[oid] then nxt = oid break end
        end
        if nxt == nil then
            -- leave the wiring: the lane point it joins
            for _, oid in ipairs(outs) do if not wire[oid] then path[#path + 1] = wp(oid) ended = true break end end
            break
        end
        seen[nxt] = true
        cur = wp(nxt)
        path[#path + 1] = cur
    end
    if ended and #path >= 3 then
        -- the turn a driver makes: from the lane's own direction arriving where the connector leaves
        -- to the lane's direction past where it joins - the corners at both ends included (67's
        -- connectors leave the main lane at a right angle, then run straight: 4 degrees of bend
        -- inside them, 90 in all)
        local ext = {}
        local function laneStep(w, upstream)
            local lst = {}
            for _, id in ipairs((upstream and w.incoming or w.out) or {}) do lst[#lst + 1] = id end
            table.sort(lst)
            for _, id in ipairs(lst) do if not wire[id] then return wp(id) end end
            return nil
        end
        local before, after = laneStep(path[1], true), laneStep(path[#path], false)
        if before ~= nil then ext[#ext + 1] = before end
        for _, w in ipairs(path) do ext[#ext + 1] = w end
        if after ~= nil then ext[#ext + 1] = after end
        local turn, len = 0, 0
        for i = 2, #ext - 1 do
            turn = turn + wrap(heading(ext[i], ext[i + 1]) - heading(ext[i - 1], ext[i]))
        end
        for i = 2, #path do len = len + math.sqrt((path[i].x - path[i - 1].x) ^ 2 + (path[i].z - path[i - 1].z) ^ 2) end
        local deg = math.abs(math.deg(turn))
        local radius = deg > 1 and len / math.rad(deg) or 9999
        local kind = (onMain(path[1], true) ~= onMain(path[#path], false)) and "turn" or "same-road"
        print(string.format("CONN %.1f %.1f %.1f %.1f,%.1f %.1f,%.1f %s", deg, len, radius,
            path[1].x, path[1].z, path[#path].x, path[#path].z, kind))
    end
end

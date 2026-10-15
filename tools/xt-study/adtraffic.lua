-- AUTODRIVE TRAFFIC, OFFLINE: several trucks driving their routes through a small network, with
-- AutoDrive 3.0.1.4's two traffic rules replayed as its code has them, to see where they meet.
--
--   1. "Who waits" (Modules/CollisionDetectionModule.lua detectAdTrafficOnRoute, lines 88-195),
--      for every truck on the same frame, every 20 frames, in a fixed order:
--        - skipped altogether while the link being driven (point before -> current target) is two-way
--          (isDualRoad: each end in the other's incoming list); the truck's traffic note is cleared
--          first, so it counts as "not waiting" for everyone else;
--        - otherwise its points from the current target on: the next 5, and on while the links stay
--          two-way (testDual or idToCheck < 5);
--        - it waits if another truck, within 4 points either side of that truck's current target,
--          has one of those points, reached from a different point before it (the "Y"; never the
--          first point, which has no point before it in the list), and that truck is not waiting;
--        - the note holds until the next check.
--   2. The bumper box (Sensors/VirtualSensors.lua getBoxShape; CollisionDetectionModule detectObstacle):
--      a box ahead of the front, speed(km/h) * 15.5 / 40 long, 2..50 m, the truck's width: any
--      vehicle in it stops the truck. Approximated along the truck's own path ahead.
--
-- Trucks move along their routes' polylines at a set speed (accel 1.2 m/s2, brake 3 m/s2), the body
-- following the path behind the steering point; a point is reached at the rig's minDistance. MEET:
-- two bodies overlap. STUCK: every truck still out is stopped for 15 s. ok: every truck got through.
-- Usage: local T = dofile("adtraffic.lua"); see farmtrack.lua.
local T = {}

-- NETWORK ----------------------------------------------------------------------------------------
function T.network() return { pts = {}, order = {} } end
function T.point(net, id, x, z)
    local p = net.pts[id]
    if p == nil then
        p = { id = id, x = x, z = z, out = {}, incoming = {} }
        net.pts[id] = p
        net.order[#net.order + 1] = id
    end
    return p
end
local function has(t, v) for _, x in ipairs(t) do if x == v then return true end end return false end
function T.link(net, a, b)
    local A, B = net.pts[a], net.pts[b]
    if not has(A.out, b) then A.out[#A.out + 1] = b end
    if not has(B.incoming, a) then B.incoming[#B.incoming + 1] = a end
end
function T.dual(net, a, b) T.link(net, a, b) T.link(net, b, a) end
-- A polyline of points (list of {id, x, z}) linked one way, or both ways.
function T.lane(net, pts, twoWay)
    for i, p in ipairs(pts) do
        T.point(net, p[1], p[2], p[3])
        if i > 1 then
            if twoWay then T.dual(net, pts[i - 1][1], p[1]) else T.link(net, pts[i - 1][1], p[1]) end
        end
    end
end
-- AutoDrive's isDualRoad.
function T.isDual(net, a, b)
    if a == nil or b == nil then return false end
    local A, B = net.pts[a], net.pts[b]
    return A ~= nil and B ~= nil and has(A.incoming, b) and has(B.incoming, a)
end

-- ROUTING (GraphManager prepareWayPoints + PathCalculation): from an incoming link to an outgoing
-- one only where the bend is 80 deg or less; cost = drive time, speed falling with the bend at the
-- start of each link (30 km/h straight ... 4 km/h past 30 deg). Dijkstra over (from, at) states.
local function bendDeg(a, b, c)
    local ux, uz, vx, vz = b.x - a.x, b.z - a.z, c.x - b.x, c.z - b.z
    local lu, lv = math.sqrt(ux * ux + uz * uz), math.sqrt(vx * vx + vz * vz)
    if lu < 1e-9 or lv < 1e-9 then return 0 end
    local d = (ux * vx + uz * vz) / (lu * lv)
    return math.deg(math.acos(math.max(-1, math.min(1, d))))
end
local function linkSpeed(bend)
    if bend < 3 then return 30 elseif bend < 8 then return 27 elseif bend < 12 then return 20
    elseif bend < 15 then return 13 elseif bend < 20 then return 10 elseif bend < 30 then return 7 end
    return 4
end
function T.route(net, from, to)
    local P = net.pts
    local dist, prevOf, done = {}, {}, {}
    local function key(a, b) return a .. ">" .. b end
    local open = {}
    for _, b in ipairs(P[from].out) do
        local k = key(from, b)
        local L = math.sqrt((P[b].x - P[from].x) ^ 2 + (P[b].z - P[from].z) ^ 2)
        dist[k] = L / (30 / 3.6)
        prevOf[k] = nil
        open[#open + 1] = { a = from, b = b }
    end
    while #open > 0 do
        table.sort(open, function(x, y) return dist[key(x.a, x.b)] < dist[key(y.a, y.b)] end)
        local cur = table.remove(open, 1)
        local ck = key(cur.a, cur.b)
        if not done[ck] then
            done[ck] = true
            if cur.b == to then
                local path, k, s = { to }, ck, cur
                while s ~= nil do
                    table.insert(path, 1, s.a)
                    s = prevOf[key(s.a, s.b)]
                end
                return path
            end
            local A, B = P[cur.a], P[cur.b]
            for _, c in ipairs(B.out) do
                local C = P[c]
                local bend = bendDeg(A, B, C)
                -- a link out that is a reverse link (no matching incoming) may be taken at any bend
                local reverse = not has(C.incoming, cur.b)
                if c ~= cur.a and (bend <= 80 or reverse) then
                    local nk = key(cur.b, c)
                    local L = math.sqrt((C.x - B.x) ^ 2 + (C.z - B.z) ^ 2)
                    local nd = dist[ck] + L / (linkSpeed(bend) / 3.6)
                    if dist[nk] == nil or nd < dist[nk] then
                        dist[nk], prevOf[nk] = nd, cur
                        open[#open + 1] = { a = cur.b, b = c }
                    end
                end
            end
        end
    end
    return nil
end

-- TRUCKS -----------------------------------------------------------------------------------------
-- A truck: route (list of ids), rig {front, rear, minDistance, width}, speed km/h, start time and how
-- far before the route's second point it starts (its first point is behind it).
local function polyline(net, ids)
    local pts, cum = {}, { 0 }
    for i, id in ipairs(ids) do
        local p = net.pts[id]
        pts[i] = { x = p.x, z = p.z, id = id }
        if i > 1 then cum[i] = cum[i - 1] + math.sqrt((p.x - pts[i - 1].x) ^ 2 + (p.z - pts[i - 1].z) ^ 2) end
    end
    return pts, cum
end
local function at(tr, s)
    local pts, cum = tr.pts, tr.cum
    if s <= 0 then
        local a, b = pts[1], pts[2]
        local L = cum[2]
        return a.x + (b.x - a.x) * s / L, a.z + (b.z - a.z) * s / L
    end
    local n = #pts
    if s >= cum[n] then
        local a, b = pts[n - 1], pts[n]
        local L = cum[n] - cum[n - 1]
        local e = s - cum[n]
        return b.x + (b.x - a.x) * e / L, b.z + (b.z - a.z) * e / L
    end
    local lo, hi = 1, n
    while hi - lo > 1 do
        local m = math.floor((lo + hi) / 2)
        if cum[m] <= s then lo = m else hi = m end
    end
    local a, b = pts[lo], pts[lo + 1]
    local f = (s - cum[lo]) / (cum[lo + 1] - cum[lo])
    return a.x + (b.x - a.x) * f, a.z + (b.z - a.z) * f
end
local function body(tr, step)
    local out = {}
    local s = tr.s - tr.rig.rear
    while s <= tr.s + tr.rig.front + 1e-6 do
        local x, z = at(tr, s)
        out[#out + 1] = { x = x, z = z }
        s = s + step
    end
    return out
end

-- One run. trucks = { {route=ids, rig=, kmh=, start=, s0=} ... }; opts.order = truck processing order.
-- Returns "ok" | "MEET" | "STUCK", plus detail.
function T.run(net, trucks, opts)
    opts = opts or {}
    local DT, CHECK = 1 / 30, 10        -- 30 frames a second: the check every 10 = AutoDrive's 20 at 60
    local list = {}
    for i, spec in ipairs(trucks) do
        local tr = { n = i, rig = spec.rig, vmax = spec.kmh / 3.6, start = spec.start or 0, wait = nil, bump = false,
            v = spec.kmh / 3.6, done = false, stopped = 0 }
        tr.pts, tr.cum = polyline(net, spec.route)
        tr.ids = spec.route
        tr.s = spec.s0 or 0
        tr.cur = 1
        local function adv()
            while tr.cur <= #tr.pts do
                local x, z = at(tr, tr.s)
                local p = tr.pts[tr.cur]
                if (p.x - x) ^ 2 + (p.z - z) ^ 2 < tr.rig.minDistance ^ 2 or tr.cum[tr.cur] < tr.s then tr.cur = tr.cur + 1 else break end
            end
        end
        tr.adv = adv
        adv()
        list[#list + 1] = tr
    end
    local order = opts.order or {}
    if #order == 0 then for i = 1, #list do order[i] = i end end
    local t, frame = 0, 0
    local width = (opts.width or 2.6)
    local function overlapsAny(tr)
        local A = body(tr, 1.0)
        for _, o in ipairs(list) do
            if o ~= tr and o.started and not o.done then
                for _, p in ipairs(A) do
                    for _, q in ipairs(body(o, 1.0)) do
                        if (p.x - q.x) ^ 2 + (p.z - q.z) ^ 2 < (width + 2) ^ 2 then return true end
                    end
                end
            end
        end
        return false
    end
    while t < (opts.tmax or 120) do
        frame, t = frame + 1, t + DT
        -- A truck cannot appear inside another: its start waits until its spot is clear.
        for _, tr in ipairs(list) do
            if not tr.started and t >= tr.start then
                if overlapsAny(tr) then tr.start = t + DT else tr.started = true end
            end
        end
        -- 1. who waits
        if frame % CHECK == 0 then
            for _, idx in ipairs(order) do
                local me = list[idx]
                if t >= me.start and not me.done then
                    me.wait = nil
                    local ids, cur = me.ids, me.cur
                    local onDual = ids[cur - 1] ~= nil and ids[cur] ~= nil and T.isDual(net, ids[cur - 1], ids[cur])
                    if ids[cur] ~= nil and ids[cur + 1] ~= nil and not onDual then
                        local rp, k = {}, 0
                        while ids[cur + k] ~= nil and ids[cur + k + 1] ~= nil do
                            if T.isDual(net, ids[cur + k], ids[cur + k + 1]) or k < 5 then
                                rp[#rp + 1] = ids[cur + k]
                                k = k + 1
                            else
                                break
                            end
                        end
                        if #rp >= 2 then
                            for _, other in ipairs(list) do
                                if other ~= me and t >= other.start and not other.done then
                                    local onSame, foundY = false, false
                                    local i = -4
                                    while i <= 4 and not foundY do
                                        local oid = other.ids[other.cur + i]
                                        if oid ~= nil then
                                            for j, point in ipairs(rp) do
                                                if point == oid then
                                                    onSame = true
                                                    local oprev = other.ids[other.cur + i - 1]
                                                    if rp[j - 1] ~= nil and oprev ~= nil and rp[j - 1] ~= oprev then
                                                        foundY = true
                                                        break
                                                    end
                                                end
                                            end
                                        end
                                        i = i + 1
                                    end
                                    if onSame and other.wait == nil and foundY then
                                        me.wait = other
                                        break
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        -- 2. the bumper box, and motion
        local bodies = {}
        for _, tr in ipairs(list) do if t >= tr.start and not tr.done then bodies[tr] = body(tr, 1.5) end end
        for _, tr in ipairs(list) do
            if t >= tr.start and not tr.done then
                local L = math.max(2, math.min(50, tr.v * 3.6 * 15.5 / 40))
                tr.bump = false
                local s = tr.s + tr.rig.front
                while s <= tr.s + tr.rig.front + L and not tr.bump do
                    local x, z = at(tr, s)
                    for other, b in pairs(bodies) do
                        if other ~= tr then
                            for _, q in ipairs(b) do
                                if (q.x - x) ^ 2 + (q.z - z) ^ 2 < width * width then tr.bump = true break end
                            end
                        end
                        if tr.bump then break end
                    end
                    s = s + 1.5
                end
                if tr.wait ~= nil or tr.bump then
                    tr.v = math.max(0, tr.v - 3.0 * DT)
                else
                    tr.v = math.min(tr.vmax, tr.v + 1.2 * DT)
                end
                tr.s = tr.s + tr.v * DT
                tr.adv()
                if tr.v < 0.05 then tr.stopped = tr.stopped + DT else tr.stopped = 0 end
                if tr.s - tr.rig.rear > tr.cum[#tr.cum] then tr.done = true end
            end
        end
        -- 3. meetings: two bodies overlapping (centre lines closer than one width less a margin)
        local live = {}
        for _, tr in ipairs(list) do if t >= tr.start and not tr.done then live[#live + 1] = tr end end
        for a = 1, #live do
            for b = a + 1, #live do
                local ax, az = at(live[a], live[a].s)
                local bx, bz = at(live[b], live[b].s)
                local reach = live[a].rig.front + live[a].rig.rear + live[b].rig.front + live[b].rig.rear + width
                if (ax - bx) ^ 2 + (az - bz) ^ 2 <= reach * reach then
                    local A, B = body(live[a], 1.0), body(live[b], 1.0)
                    for _, p in ipairs(A) do
                        for _, q in ipairs(B) do
                            if (p.x - q.x) ^ 2 + (p.z - q.z) ^ 2 < (width - 0.4) ^ 2 then
                                return "MEET", string.format("t=%.1f at %.1f,%.1f trucks %d,%d", t, p.x, p.z, live[a].n, live[b].n)
                            end
                        end
                    end
                end
            end
        end
        -- 4. finished, or everyone left standing
        local allDone, allStopped, anyLive = true, true, false
        for _, tr in ipairs(list) do
            if not tr.done then
                allDone = false
                if t >= tr.start then
                    anyLive = true
                    if tr.stopped < 15 then allStopped = false end
                else
                    allStopped = false
                end
            end
        end
        if allDone then return "ok", string.format("t=%.1f", t) end
        if anyLive and allStopped then return "STUCK", string.format("t=%.1f", t) end
    end
    return "STUCK", "time out"
end

-- A rig's body from SweptSim's numbers: front of the steering point and behind it.
function T.rigFrom(r)
    return { front = r.wheelbase + 1.2 - (r.steerNodeOffset or 0), rear = (r.steerNodeOffset or 0) + (r.trailerLength or 0) + 3.0,
        minDistance = r.minDistance or 4, width = r.width or 2.6 }
end

return T

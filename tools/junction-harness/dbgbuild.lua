-- ONE BUILD, offline: lock a junction in build mode, run the real applyJunction (today's builder) and
-- report what it laid. This is the harness's first way to exercise the build at all; until now
-- everything here ran the clear only.
--   lua dbgbuild.lua X Z [turnRadius]
--   GRAPH=<network .lua>   the exported map (graph_data.lua by default)
--   CLEARFIRST=1           clear the site first (through roads kept), then build on the cleared site
--   ALL=1                  print the whole log of the build
-- Reports, within 40 m of the site:
--   points and links before and after, and how many of the new links are two-way;
--   teal dots (AutoDrive 3.0.1.2's right-of-way centres) before and after;
--   the turns placed and refused, as the build's own log counts them.
-- The last line, COUNTS, is one line for a regression to collect.
LOG_ECHO = false
local H = dofile("harness.lua")
local CX, CZ = tonumber(arg[1]), tonumber(arg[2])
if CX == nil or CZ == nil then
    print("usage: lua dbgbuild.lua X Z [turnRadius]")
    os.exit(1)
end
local TURN = tonumber(arg[3] or "") or 12
local R = 40

local function contains(t, v)
    for _, x in ipairs(t or {}) do if x == v then return true end end
    return false
end

-- The site's state: points, one-way and two-way links, and teal dots (same rule as dbgrow.lua).
local function survey()
    local s = { points = 0, links = 0, dual = 0, teal = 0, ids = {} }
    for _, p in pairs(ADGraphManager:getWayPoints()) do
        if p ~= nil and p.id ~= nil and (p.x - CX) ^ 2 + (p.z - CZ) ^ 2 <= R * R then
            s.points = s.points + 1
            s.ids[p] = true
            for _, o in ipairs(p.out or {}) do
                s.links = s.links + 1
                local q = ADGraphManager:getWayPointById(o)
                if q ~= nil and contains(q.out, p.id) then s.dual = s.dual + 1 end
            end
            local sIn, sOut, dual = 0, 0, 0
            for _, i in pairs(p.incoming or {}) do
                if not contains(p.out, i) then sIn = sIn + 1 else dual = dual + 1 end
            end
            for _, o in pairs(p.out or {}) do
                if not contains(p.incoming, o) then sOut = sOut + 1 end
            end
            if #(p.out or {}) >= 1 and #(p.incoming or {}) >= 2
                and not (dual == 1 and sIn == 1 and sOut == 0)
                and not (dual == 1 and sIn == 0 and sOut == 1)
                and not (dual == 2 and sIn == 0 and sOut == 0) then
                s.teal = s.teal + 1
            end
        end
    end
    s.dual = s.dual / 2   -- each two-way link was counted from both ends
    return s
end

-- Every link with both ends within R, keyed by the two POINT TABLES, not their ids: removing a point
-- renumbers every point after it, so an id key makes old links look new after a build.
local function linkKey(p, q) return tostring(p) .. ">" .. tostring(q) end
local function linkSet()
    local s = {}
    for _, p in pairs(ADGraphManager:getWayPoints()) do
        if p ~= nil and p.id ~= nil and (p.x - CX) ^ 2 + (p.z - CZ) ^ 2 <= R * R then
            for _, o in ipairs(p.out or {}) do
                local q = ADGraphManager:getWayPointById(o)
                if q ~= nil and (q.x - CX) ^ 2 + (q.z - CZ) ^ 2 <= R * R then s[linkKey(p, q)] = { p, q } end
            end
        end
    end
    return s
end

-- RULE: every crossing of two paths is a shared point. Counts pairs of links that cross away from
-- their ends, where at least one of the two is new. A two-way link is counted once.
local function crossingsWithoutPoint(links, newKeys)
    local list = {}
    for k, l in pairs(links) do
        local a, b = l[1], l[2]
        if not links[linkKey(b, a)] or a.id < b.id then list[#list + 1] = { k = k, a = a, b = b } end
    end
    local n = 0
    for i = 1, #list do
        for j = i + 1, #list do
            local L1, L2 = list[i], list[j]
            if (newKeys[L1.k] or newKeys[L2.k]) and L1.a ~= L2.a and L1.a ~= L2.b and L1.b ~= L2.a and L1.b ~= L2.b then
                local ax, az, bx, bz = L1.a.x, L1.a.z, L1.b.x, L1.b.z
                local cx, cz, dx, dz = L2.a.x, L2.a.z, L2.b.x, L2.b.z
                local den = (bx - ax) * (dz - cz) - (bz - az) * (dx - cx)
                if math.abs(den) > 1e-9 then
                    local t = ((cx - ax) * (dz - cz) - (cz - az) * (dx - cx)) / den
                    local u = ((cx - ax) * (bz - az) - (cz - az) * (bx - ax)) / den
                    -- More than 2 m apart in height is a bridge, not a crossing (as the builder judges it).
                    local hy1 = (L1.a.y or 0) + ((L1.b.y or 0) - (L1.a.y or 0)) * t
                    local hy2 = (L2.a.y or 0) + ((L2.b.y or 0) - (L2.a.y or 0)) * u
                    if t > 0.02 and t < 0.98 and u > 0.02 and u < 0.98 and math.abs(hy1 - hy2) <= 2.0 then
                        n = n + 1
                        if os.getenv("SHOWCROSS") == "1" then
                            local px, pz = ax + t * (bx - ax), az + t * (bz - az)
                            print(string.format("  crossing at %.1f, %.1f (%.1f m from the site): %s%s, %s%s | heights %.1f / %.1f",
                                px, pz, math.sqrt((px - CX) ^ 2 + (pz - CZ) ^ 2),
                                L1.a.id .. ">" .. L1.b.id, newKeys[L1.k] and " (new)" or "", L2.a.id .. ">" .. L2.b.id, newKeys[L2.k] and " (new)" or "",
                                (L1.a.y or 0) + ((L1.b.y or 0) - (L1.a.y or 0)) * t, (L2.a.y or 0) + ((L2.b.y or 0) - (L2.a.y or 0)) * u))
                        end
                    end
                end
            end
        end
    end
    return n
end

-- RULE: no U-turns. Follows every route AutoDrive could take into the 30 m circle and out again,
-- under its 80-degree rule (GraphManager.prepareWayPoints), and counts those that use a new link and
-- leave heading back the way they came (more than 150 degrees off the way in).
local function uTurnRoutes(newKeys)
    local IN, OUT = 30, 36
    local function d(p) return math.sqrt((p.x - CX) ^ 2 + (p.z - CZ) ^ 2) end
    local function bend(a, b, c)
        local ux, uz, vx, vz = b.x - a.x, b.z - a.z, c.x - b.x, c.z - b.z
        local nu, nv = math.sqrt(ux * ux + uz * uz), math.sqrt(vx * vx + vz * vz)
        if nu < 1e-6 or nv < 1e-6 then return 0 end
        return math.deg(math.acos(math.max(-1, math.min(1, (ux * vx + uz * vz) / (nu * nv)))))
    end
    local count = 0
    for _, a in pairs(ADGraphManager:getWayPoints()) do
        if a ~= nil and a.id ~= nil and d(a) > IN and d(a) < OUT then
            for _, bid in ipairs(a.out or {}) do
                local b = ADGraphManager:getWayPointById(bid)
                if b ~= nil and d(b) <= IN then
                    local seen, stack = {}, { { a, b, false } }
                    while #stack > 0 do
                        local top = table.remove(stack)
                        local prev, cur, usedNew = top[1], top[2], top[3]
                        local key = prev.id .. ">" .. cur.id
                        if not seen[key] then
                            seen[key] = true
                            for _, nid in ipairs(cur.out or {}) do
                                local nx = ADGraphManager:getWayPointById(nid)
                                if nx ~= nil and nx ~= prev and bend(prev, cur, nx) <= 80 then
                                    local un = usedNew or newKeys[linkKey(cur, nx)] ~= nil
                                    if d(nx) > IN then
                                        if un and bend(a, b, nx) >= 0 then
                                            local ex, ez = nx.x - cur.x, nx.z - cur.z
                                            local ix, iz = b.x - a.x, b.z - a.z
                                            local c = (ex * ix + ez * iz) / math.max(1e-9, math.sqrt((ex * ex + ez * ez) * (ix * ix + iz * iz)))
                                            if c < math.cos(math.rad(150)) then count = count + 1 end
                                        end
                                    elseif d(nx) < OUT then
                                        stack[#stack + 1] = { cur, nx, un }
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return count
end

if os.getenv("CLEARFIRST") == "1" then
    local cjp = H.lock(CX, CZ, { mode = "clear", radius = 12, leaveThrough = true })
    if cjp == nil then
        local why = tostring(ADFlyoverEditor.junctionRefused)
        -- A site with nothing wired is what the build starts from anyway: skip the clear, build on.
        if not why:find("already clear") then
            print("CLEAR REFUSED: " .. why)
            return
        end
        print("already clear - building on it as it is")
    else
        H.apply()
        print("cleared the site first (through roads kept)")
    end
end

local before = survey()
local linksBefore = linkSet()
local jp, lockLog = H.lock(CX, CZ, { mode = "build", radius = 15, turnRadius = TURN })
if jp == nil then
    print("REFUSED: " .. tostring(ADFlyoverEditor.junctionRefused))
    return
end
local moves, newMoves, refused = 0, 0, 0
for _, m in ipairs(jp.movements or {}) do
    moves = moves + 1
    if m.refused ~= nil then refused = refused + 1
    elseif (not m.exists or m.rebuild) and m.connector ~= nil then newMoves = newMoves + 1 end
end
print(string.format("site %.1f, %.1f | kind %s | turn radius %d m | %d movements: %d new to lay, %d refused",
    CX, CZ, tostring(jp.junctionType or (ADFlyoverEditor.junctionSite and ADFlyoverEditor.junctionSite.kind) or "?"),
    TURN, moves, newMoves, refused))

local log = H.build()
local after = survey()
if os.getenv("ALL") == "1" then for _, l in ipairs(log) do print("  " .. l) end end
for _, l in ipairs(log) do
    if l:find("refused") or l:find("nothing new") or l:find("INVARIANT") then print("  " .. l) end
end
local linksAfter = linkSet()
local newKeys = {}
for k in pairs(linksAfter) do if linksBefore[k] == nil then newKeys[k] = true end end
local crossNo = crossingsWithoutPoint(linksAfter, newKeys)
local uturns = uTurnRoutes(newKeys)
print(string.format("points %d -> %d | links %d -> %d | two-way links %d -> %d | teal dots %d -> %d",
    before.points, after.points, before.links, after.links, before.dual, after.dual, before.teal, after.teal))
-- RULE: no two-way TURNS. A two-way link counts when one of its ends is a new point with exactly two
-- neighbours - a point along a new turn. A two-way road split where a turn crosses it is still the
-- road, and is not counted.
local dualTurns = 0
do
    local newPts = {}
    for k in pairs(newKeys) do
        local l = linksAfter[k]
        local a, b = l[1], l[2]
        if contains(b.out, a.id) and a.id < b.id then
            for _, w in ipairs({ a, b }) do
                local nb, n = {}, 0
                for _, id in ipairs(w.out or {}) do if not nb[id] then nb[id] = true n = n + 1 end end
                for _, id in ipairs(w.incoming or {}) do if not nb[id] then nb[id] = true n = n + 1 end end
                local wasThere = false
                for kk in pairs(linksBefore) do
                    local p = linksBefore[kk]
                    if p[1] == w or p[2] == w then wasThere = true break end
                end
                if n == 2 and not wasThere then dualTurns = dualTurns + 1 break end
            end
        end
    end
end
print(string.format("rules: %d two-way turn link(s) | %d crossing(s) without a shared point | %d U-turn route(s) through new links",
    dualTurns, crossNo, uturns))
print(string.format("COUNTS %.1f %.1f moves=%d new=%d refused=%d points=%d links=%d dual=%d teal=%d cross=%d uturn=%d",
    CX, CZ, moves, newMoves, refused, after.points - before.points, after.links - before.links,
    dualTurns, after.teal - before.teal, crossNo, uturns))

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
-- GAMEFLAGS=1: the swept-path check as in game, which needs the truck twin - loaded after the harness,
-- since the harness clears SweptSim.
if os.getenv("GAMEFLAGS") == "1" then dofile("../../scripts/editor/SweptSim.lua") end
-- NOSHARE=1 builds without the shared-crossing step, to see what the rest of the builder does alone.
if os.getenv("NOSHARE") == "1" then AutoDrive.FLYOVER_JUNCTION_SHARE_CROSSINGS = false end
-- SQUARE=1 turns on the S-bend at shallow shared crossings (off in the builder by default).
if os.getenv("SQUARE") == "1" then AutoDrive.FLYOVER_JUNCTION_SQUARE_CROSSINGS = true end
-- SNAP=m: how close a crossing must be to an existing point to run through that point instead.
if os.getenv("SNAP") then AutoDrive.FLYOVER_JUNCTION_SHARE_SNAP = tonumber(os.getenv("SNAP")) end
local CX, CZ = tonumber(arg[1]), tonumber(arg[2])
if CX == nil or CZ == nil then
    print("usage: lua dbgbuild.lua X Z [turnRadius]")
    os.exit(1)
end
local TURN = tonumber(arg[3] or "") or tonumber(os.getenv("TURNR") or "") or 12
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
                    local seen, stack = {}, { { a, b, false, { a, b } } }
                    while #stack > 0 do
                        local top = table.remove(stack)
                        local prev, cur, usedNew, path = top[1], top[2], top[3], top[4]
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
                                            if c < math.cos(math.rad(150)) then
                                                count = count + 1
                                                if os.getenv("SHOWUTURN") == "1" then
                                                    local parts = {}
                                                    for _, w in ipairs(path) do
                                                        local nb = {}
                                                        local dual = contains(w.out, (path[1] or w).id)
                                                        parts[#parts + 1] = string.format("%d(%.0f,%.0f)%s%s", w.id, w.x, w.z,
                                                            (#(w.out or {}) + #(w.incoming or {}) > 2) and "*" or "", newKeys and "" or "")
                                                    end
                                                    parts[#parts + 1] = string.format("%d(%.0f,%.0f)", nx.id, nx.x, nx.z)
                                                    print("  U-turn route: " .. table.concat(parts, " > "))
                                                end
                                            end
                                        end
                                    elseif d(nx) < OUT then
                                        local np = {}
                                        for _, w in ipairs(path) do np[#np + 1] = w end
                                        np[#np + 1] = nx
                                        stack[#stack + 1] = { cur, nx, un, np }
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
-- RULE: never two lines on top of each other, the opposite way (the user, 2026-10-08). Counts new
-- one-way links with a one-way link running back the other way (within 25 degrees of opposite) less
-- than 1 m from the new link's middle. A two-way link is one line, not two, and is not counted; nor
-- are two links with a point in common (they meet there, or one line folds back on itself).
local opposed = 0
do
    -- A reverse link (in a's out but not in b's incoming) is not counted: a reverse track with a
    -- one-way track back out on top of it is allowed, as in parking (the user, 2026-10-09).
    local function oneWay(l)
        return not table.contains(l[2].out or {}, l[1].id) and table.contains(l[2].incoming or {}, l[1].id)
    end
    for k in pairs(newKeys) do
        local L = linksAfter[k]
        if oneWay(L) then
            local a, b = L[1], L[2]
            local mx, mz = (a.x + b.x) / 2, (a.z + b.z) / 2
            local ux, uz = b.x - a.x, b.z - a.z
            local nu = math.sqrt(ux * ux + uz * uz)
            for _, M in pairs(linksAfter) do
                if M ~= L and oneWay(M) and nu > 1e-6 and M[1] ~= a and M[1] ~= b and M[2] ~= a and M[2] ~= b then
                    local c, d = M[1], M[2]
                    local vx, vz = d.x - c.x, d.z - c.z
                    local nv = math.sqrt(vx * vx + vz * vz)
                    if nv > 1e-6 and (ux * vx + uz * vz) / (nu * nv) < -0.9 then
                        local t = math.max(0, math.min(1, ((mx - c.x) * vx + (mz - c.z) * vz) / (nv * nv)))
                        if (c.x + vx * t - mx) ^ 2 + (c.z + vz * t - mz) ^ 2 < 1 then
                            opposed = opposed + 1
                            if os.getenv("SHOWOPPOSED") == "1" then
                                print(string.format("  OPPOSED (%.1f,%.1f)->(%.1f,%.1f) beside (%.1f,%.1f)->(%.1f,%.1f)", a.x, a.z, b.x, b.z, c.x, c.z, d.x, d.z))
                            end
                            break
                        end
                    end
                end
            end
        end
    end
end
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
                -- A point along a two-way TURN has both its links two-way; the new end of a two-way road
                -- where a turn joins it has one two-way link (the road) and one one-way (the turn).
                local bothDual = true
                for _, id in ipairs(w.out or {}) do if not contains(w.incoming, id) then bothDual = false end end
                for _, id in ipairs(w.incoming or {}) do if not contains(w.out, id) then bothDual = false end end
                if n == 2 and not wasThere and bothDual then
                    dualTurns = dualTurns + 1
                    if os.getenv("SHOWDUAL") == "1" then
                        local function nbs(p)
                            local s = {}
                            for _, id in ipairs(p.out or {}) do s[#s + 1] = "out" .. id end
                            for _, id in ipairs(p.incoming or {}) do s[#s + 1] = "in" .. id end
                            return table.concat(s, ",")
                        end
                        print(string.format("  two-way link %d(%.1f,%.1f)[%s] <-> %d(%.1f,%.1f)[%s]",
                            a.id, a.x, a.z, nbs(a), b.id, b.x, b.z, nbs(b)))
                    end
                    break
                end
            end
        end
    end
end
-- RULE: every route AutoDrive could take is one we meant - the BUILDER's own route check.
local rc = ADFlyoverEditor.junctionLastRouteCheck
-- What the build card shows (the record the HUD reads through junctionLastBuildShown).
do
    local shown = ADFlyoverEditor:junctionLastBuildShown()
    if shown ~= nil and shown.card ~= nil then
        print(string.format("card: last build %s", shown.number and string.format("j%02d", shown.number) or "(no number)"))
        for _, line in ipairs(shown.card) do print("card:   " .. line) end
    else
        print("card: (no last build shown)")
    end
end
local extra = rc and #rc.extra or -1
if rc ~= nil then
    for _, e in ipairs(rc.extra) do
        print(string.format("  extra route: lane in at %.1f, %.1f -> lane out at %.1f, %.1f (%s)",
            e.from.x, e.from.z, e.to.x, e.to.z, e.why))
        -- HOPS=1: where along the route AutoDrive switches from one path to another, and between what.
        -- Each link is named by the turn it belongs to (L90, R85, S = straight-ish connector, from the
        -- build's own labels), "road" for a link the build did not lay, and the switch is a point where
        -- that name changes, with the bend there.
        if os.getenv("HOPS") == "1" and e.path then
            local labels = ADFlyoverEditor.junctionLastNodeLabels or {}
            local linkLabels = ADFlyoverEditor.junctionLastLinkLabels or {}
            local function kind(l) return (l == nil) and "road" or l end
            local function linkName(p, q)
                -- The link's own label (it follows the link through every splice) is the true answer.
                local own = (linkLabels[p] or {})[q]
                if own ~= nil then return own end
                local lp, lq = labels[p], labels[q]
                for _, l in ipairs({ lp, lq }) do
                    if l ~= nil and l ~= "x" and l ~= "tie" then return l end
                end
                if lp == nil and lq == nil then return "road" end
                -- both ends are tie-ins or shared crossings: a short joining piece
                return "joint"
            end
            local story, lastName = {}, nil
            for i = 1, #e.path - 1 do
                local name = linkName(e.path[i], e.path[i + 1])
                if name ~= lastName then
                    if lastName ~= nil and i > 1 then
                        local p, w, q = e.path[i - 1], e.path[i], e.path[i + 1]
                        local ux, uz, vx, vz = w.x - p.x, w.z - p.z, q.x - w.x, q.z - w.z
                        local c = (ux * vx + uz * vz) / math.max(1e-9, math.sqrt((ux * ux + uz * uz) * (vx * vx + vz * vz)))
                        local bend = math.deg(math.acos(math.max(-1, math.min(1, c))))
                        story[#story + 1] = string.format("[%s %.0f]", kind(labels[w]), bend)
                        print(string.format("HOP %s -> %s at a %s point, bend %.0f  (%.1f, %.1f)", lastName, name, kind(labels[w]), bend, w.x, w.z))
                    end
                    story[#story + 1] = name
                    lastName = name
                end
            end
            print("    story: " .. table.concat(story, " > "))
        end
        if os.getenv("SHOWPATH") == "1" and e.path then
            -- * marks a point where paths meet or part; the bend into each point is shown after it.
            local parts = {}
            for i, w in ipairs(e.path) do
                local nb, n = {}, 0
                for _, id in ipairs(w.out or {}) do if not nb[id] then nb[id] = true n = n + 1 end end
                for _, id in ipairs(w.incoming or {}) do if not nb[id] then nb[id] = true n = n + 1 end end
                local b = ""
                if i > 1 and i < #e.path then
                    local p, q = e.path[i - 1], e.path[i + 1]
                    local ux, uz, vx, vz = w.x - p.x, w.z - p.z, q.x - w.x, q.z - w.z
                    local c = (ux * vx + uz * vz) / math.max(1e-9, math.sqrt((ux * ux + uz * uz) * (vx * vx + vz * vz)))
                    b = string.format("/%.0f", math.deg(math.acos(math.max(-1, math.min(1, c)))))
                end
                parts[#parts + 1] = string.format("(%.0f,%.0f)%s%s", w.x, w.z, n > 2 and "*" or "", b)
            end
            print("    path: " .. table.concat(parts, " "))
        end
    end
end
-- SHARP BENDS ON OUR TURNS. AutoDrive caps speed at the sharpest bend ahead, point by point
-- (DrivePathModule.getMaxSpeedForAngle): 30 degrees or more -> 12 km/h, 50 or more -> 3 km/h. Counted at
-- every point where a link of one turn leads on into a link of the SAME turn (by the build's link labels).
local kink30, kink50 = 0, 0
-- Short links among the points the build laid: points closer than 0.3 m sit on top of each other in game.
local short = 0
do
    for _, a in pairs(ADGraphManager:getWayPoints()) do
        if (a.x - CX) ^ 2 + (a.z - CZ) ^ 2 <= R * R then
            for _, id in ipairs(a.out or {}) do
                local b = ADGraphManager:getWayPointById(id)
                if b ~= nil and ((ADFlyoverEditor.junctionLastNodeLabels or {})[a] or (ADFlyoverEditor.junctionLastNodeLabels or {})[b])
                    and (b.x - a.x) ^ 2 + (b.z - a.z) ^ 2 < 0.09 and not (contains(b.out, a.id) and a.id > b.id) then
                    short = short + 1
                end
            end
        end
    end
end
do
    local LL = ADFlyoverEditor.junctionLastLinkLabels or {}
    for a, outs in pairs(LL) do
        if type(a) == "table" then
            for N, lab in pairs(outs) do
                for b, lab2 in pairs(LL[N] or {}) do
                    if lab2 == lab and b ~= a and contains(a.out, N.id) and contains(N.out, b.id) then
                        local ux, uz, vx, vz = N.x - a.x, N.z - a.z, b.x - N.x, b.z - N.z
                        local c = (ux * vx + uz * vz) / math.max(1e-9, math.sqrt((ux * ux + uz * uz) * (vx * vx + vz * vz)))
                        local ang = math.deg(math.acos(math.max(-1, math.min(1, c))))
                        if ang < 150 then   -- not a two-way link's way back
                            if ang >= 50 then kink50 = kink50 + 1 elseif ang >= 30 then kink30 = kink30 + 1 end
                            if os.getenv("SHOWKINK") == "1" and ang >= 30 then
                                print(string.format("KINK %s %.0f deg at (%.1f, %.1f)", lab, ang, N.x, N.z))
                            end
                        end
                    end
                end
            end
        end
    end
end
-- SHOWMISSING=1: for each turn the route check could not drive, the bends over 80 degrees that stop it:
-- every point on a laid turn where coming in from one link and going out on the next bends past 80.
if os.getenv("SHOWMISSING") == "1" and rc and rc.missing then
    for _, e in ipairs(rc.missing) do
        print(string.format("MISSING from lane in at %.1f, %.1f to lane out at %.1f, %.1f", e.from.x, e.from.z, e.to.x, e.to.z))
    end
    local LL = ADFlyoverEditor.junctionLastLinkLabels or {}
    for a, outs in pairs(LL) do
        if type(a) == "table" then
            for N, lab in pairs(outs) do
                if contains(a.out, N.id) then
                    -- into the turn: from whatever runs into a; out of it: whatever N leads on to
                    for _, pid in ipairs(a.incoming or {}) do
                        local p = ADGraphManager:getWayPointById(pid)
                        if p ~= nil and p ~= N then
                            local ux, uz, vx, vz = a.x - p.x, a.z - p.z, N.x - a.x, N.z - a.z
                            local c = (ux * vx + uz * vz) / math.max(1e-9, math.sqrt((ux * ux + uz * uz) * (vx * vx + vz * vz)))
                            local ang = math.deg(math.acos(math.max(-1, math.min(1, c))))
                            if ang > 80 and not ((LL[p] or {})[a] ~= nil and (LL[p] or {})[a] ~= lab) then
                                print(string.format("  SHARP %s: %.0f deg at (%.1f, %.1f) coming from (%.1f, %.1f) [%s]", lab, ang, a.x, a.z, p.x, p.z,
                                    tostring((LL[p] or {})[a] or "lane")))
                            end
                        end
                    end
                end
            end
        end
    end
end
-- NODEAT=x,z prints what meets at the point nearest there: every link in and out, its label, and the
-- bend for each in -> out pair a driver could take.
if os.getenv("NODEAT") then
    local nx, nz = os.getenv("NODEAT"):match("(-?[%d.]+),(-?[%d.]+)")
    nx, nz = tonumber(nx), tonumber(nz)
    local best, bd = nil, 1e9
    for _, w in pairs(ADGraphManager:getWayPoints()) do
        local d = (w.x - nx) ^ 2 + (w.z - nz) ^ 2
        if d < bd then best, bd = w, d end
    end
    local LL = ADFlyoverEditor.junctionLastLinkLabels or {}
    local NL = ADFlyoverEditor.junctionLastNodeLabels or {}
    local N = best
    print(string.format("NODE %d at (%.2f, %.2f) label %s", N.id, N.x, N.z, tostring(NL[N])))
    local function lab(a, b) return tostring((LL[a] or {})[b] or "road") end
    for _, id in ipairs(N.incoming or {}) do
        local a = ADGraphManager:getWayPointById(id)
        for _, oid in ipairs(N.out or {}) do
            local b = ADGraphManager:getWayPointById(oid)
            if a ~= b then
                local ux, uz, vx, vz = N.x - a.x, N.z - a.z, b.x - N.x, b.z - N.z
                local c = (ux * vx + uz * vz) / math.max(1e-9, math.sqrt((ux * ux + uz * uz) * (vx * vx + vz * vz)))
                print(string.format("  in %s from (%.2f,%.2f) %.2f m  ->  out %s to (%.2f,%.2f) %.2f m   bend %.0f",
                    lab(a, N), a.x, a.z, math.sqrt(ux * ux + uz * uz), lab(N, b), b.x, b.z, math.sqrt(vx * vx + vz * vz),
                    math.deg(math.acos(math.max(-1, math.min(1, c))))))
            end
        end
    end
end
print(string.format("rules: %d two-way turn link(s) | %d crossing(s) without a shared point | %d extra route(s) of %d | (%d long U-turn guesses)",
    dualTurns, crossNo, extra, rc and rc.routes or 0, uturns))
local sh = ADFlyoverEditor.junctionLastShared or { joined = 0, shallow = 0 }
print(string.format("COUNTS %.1f %.1f moves=%d new=%d refused=%d points=%d links=%d dual=%d teal=%d cross=%d extra=%d routes=%d shared=%d shallow=%d squared=%d kink30=%d kink50=%d short=%d pattern=%s missing=%d opposed=%d why=%s",
    CX, CZ, moves, newMoves, refused, after.points - before.points, after.links - before.links,
    dualTurns, after.teal - before.teal, crossNo, extra, rc and rc.routes or 0, sh.joined, sh.shallow, sh.squared or 0, kink30, kink50, short, ADFlyoverEditor.junctionLastPattern and ADFlyoverEditor.junctionLastPattern.shape or "no", rc and rc.missing and #rc.missing or 0, opposed, (ADFlyoverEditor.junctionLastPatternWhy or "-"):gsub(" ", "_")))

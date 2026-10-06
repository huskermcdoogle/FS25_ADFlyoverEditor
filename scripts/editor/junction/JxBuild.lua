-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua
-- loads it after FlyoverEditor.lua, in the old file's order.
-- MODSPLIT: HELPERS FROM THE FILES LOADED BEFORE THIS ONE (tools/modsplit/split.py writes this block)
for _, name in ipairs({ "junctionConnect", "junctionDisconnect", "junctionLayChain", "jxIsNewLink", "jxNoteAdded", "jxNoteMoved", "jxRemove", "jxState", "tryCall" }) do
    if ADFlyoverEditor.shared == nil or ADFlyoverEditor.shared[name] == nil then
        Logging.error("[FlyoverEditor]: JxBuild.lua needs %s, which no file loaded before it shares", name)
    end
end
local junctionConnect = ADFlyoverEditor.shared.junctionConnect
local junctionDisconnect = ADFlyoverEditor.shared.junctionDisconnect
local junctionLayChain = ADFlyoverEditor.shared.junctionLayChain
local jxIsNewLink = ADFlyoverEditor.shared.jxIsNewLink
local jxNoteAdded = ADFlyoverEditor.shared.jxNoteAdded
local jxNoteMoved = ADFlyoverEditor.shared.jxNoteMoved
local jxRemove = ADFlyoverEditor.shared.jxRemove
local jxState = ADFlyoverEditor.shared.jxState
local tryCall = ADFlyoverEditor.shared.tryCall
-- MODSPLIT: end of the helpers

-- EVERY CROSSING IS A SHARED POINT (docs/junction-tool/06-one-click-build.md, layout rule 1).
-- AutoDrive only makes a driver wait where two routes share a point (CollisionDetectionModule:
-- detectAdTrafficOnRoute matches point ids), so two paths that cross in open space are invisible to
-- it. After a build has laid its turns, every place where one of its new links crosses another link
-- near the junction gets one point that both links run through.
--   * A crossing within SNAP of an existing end of either link reuses that point instead of stacking
--     a new one beside it.
--   * Links more than 2 m apart in height where they cross are left alone: a road over a bridge is
--     not a crossing.
--   * One crossing is resolved at a time and the search starts again, since every splice changes the
--     links around it.
-- Returns how many crossings it joined.
jxState.jxShallowJoins = 0

-- SQUARE UP A SHALLOW CROSSING. AutoDrive refuses to switch paths at a shared point only where the
-- bend is over 80 degrees, so two paths crossing at 55 degrees let a driver hop from one to the other.
-- Here the NEW path (p -> N -> q) gets a small S-bend: one extra point either side of N, up to a metre
-- out, on the line square to the path it crosses. It then meets that path at 90 degrees (a two-way
-- path counts both ways round, so it must sit near 90 from both sides). The line moves well under a
-- metre; road lanes are never bent, since only a path this build laid comes here.
-- sq = { p, N, q, dual = our path two-way, vx, vz = the crossed path's direction, otherDual }
jxState.jxSquaredJoins = 0
-- Points the squaring made or moved this build. They never move (again): a moved point's other link can
-- cross something new, and moving the next one along would walk a chain of moves across the junction.
local jxSquareMade = {}
-- Points the sharing slid onto a crossing this build. They never slide again.
local jxSlid = {}

--- A point this build laid on one of its own paths with nothing else joined to it: one link each way (or
--- a two-way link to each of the same two neighbours). Such a point can move without touching anything
--- but its own path.
local function jxPlainOurs(s)
    if jxState.jxBuildNew == nil or not jxState.jxBuildNew[s] or s == jxState.jxCentreNode or jxSquareMade[s] or jxSlid[s] then return false end
    local nb = {}
    for _, id in ipairs(s.out or {}) do nb[id] = true end
    for _, id in ipairs(s.incoming or {}) do nb[id] = true end
    local n = 0
    for _ in pairs(nb) do n = n + 1 end
    local o, i = #(s.out or {}), #(s.incoming or {})
    return n == 2 and o == i and (o == 1 or o == 2)
end

local function junctionSquareUp(sq)
    local p, N, q = sq.p, sq.N, sq.q
    if p == nil or q == nil or N == nil or p == N or q == N or p == q then return false end
    local ux, uz = q.x - p.x, q.z - p.z
    local nu = math.sqrt(ux * ux + uz * uz)
    local nv = math.sqrt(sq.vx * sq.vx + sq.vz * sq.vz)
    if nu < 1e-6 or nv < 1e-6 then return false end
    ux, uz = ux / nu, uz / nu
    local vx, vz = sq.vx / nv, sq.vz / nv
    local ang = math.deg(math.acos(math.max(-1, math.min(1, ux * vx + uz * vz))))
    -- Nearly parallel paths are left alone: turning ours square across one would zigzag it over the
    -- other again and again.
    if ang < 30 or ang > 150 then return false end
    -- The bends a driver would really take at N, switching between our path and any other link there.
    -- A snap through a point beside the crossing bends our own path, so the crossing angle alone can
    -- say 85 where the switch is 55. 5 degrees of margin on AutoDrive's 80.
    local function bend(a, b, c)
        local x1, z1, x2, z2 = b.x - a.x, b.z - a.z, c.x - b.x, c.z - b.z
        local n1, n2 = math.sqrt(x1 * x1 + z1 * z1), math.sqrt(x2 * x2 + z2 * z2)
        if n1 < 1e-6 or n2 < 1e-6 then return 180 end
        return math.deg(math.acos(math.max(-1, math.min(1, (x1 * x2 + z1 * z2) / (n1 * n2)))))
    end
    local function others(list)
        local t = {}
        for _, id in ipairs(list or {}) do
            local w = ADGraphManager:getWayPointById(id)
            if w ~= nil and w ~= p and w ~= q then t[#t + 1] = w end
        end
        return t
    end
    local ins, outs = others(N.incoming), others(N.out)
    local shallow = false
    for _, o in ipairs(outs) do
        if bend(p, N, o) <= 85 or (sq.dual and bend(q, N, o) <= 85) then shallow = true end
    end
    for _, i in ipairs(ins) do
        if bend(i, N, q) <= 85 or (sq.dual and bend(i, N, p) <= 85) then shallow = true end
    end
    if not shallow then return false end
    -- The crossed path bends a little at N too when it is a curve: square to the average of its way
    -- in and way out, so both switches come out near 90, not one at 81.
    if #ins == 1 and #outs == 1 and ins[1] ~= outs[1] then
        local i, o = ins[1], outs[1]
        local ax, az = N.x - i.x, N.z - i.z
        local bx, bz = o.x - N.x, o.z - N.z
        local na, nb = math.sqrt(ax * ax + az * az), math.sqrt(bx * bx + bz * bz)
        if na > 1e-6 and nb > 1e-6 then
            local mx, mz = ax / na + bx / nb, az / na + bz / nb
            local nm = math.sqrt(mx * mx + mz * mz)
            if nm > 1e-6 then vx, vz = mx / nm, mz / nm end
        end
    end
    -- Square to the crossed path, on the side our path already runs.
    local sx, sz = -vz, vx
    if sx * ux + sz * uz < 0 then sx, sz = -sx, -sz end
    local flags = N.flags or AutoDrive.FLAG_NONE
    if jxState.jxBuildNew[p] then flags = p.flags elseif jxState.jxBuildNew[q] then flags = q.flags end
    local label = nil
    if jxState.jxLinkLabel ~= nil then label = (jxState.jxLinkLabel[p] or {})[N] or (jxState.jxLinkLabel[N] or {})[q] end
    local bent = false
    -- A point of our own path with nothing else joined to it: one link each way (both to the same two
    -- neighbours when the path is two-way). Such a point can simply move.
    local function plain(s)
        if not jxState.jxBuildNew[s] or s == jxState.jxCentreNode or jxSquareMade[s] or jxSquareMade[N] then return false end
        local nb = {}
        for _, id in ipairs(s.out or {}) do nb[id] = true end
        for _, id in ipairs(s.incoming or {}) do nb[id] = true end
        local n = 0
        for _ in pairs(nb) do n = n + 1 end
        return n == 2 and #(s.out or {}) == (sq.dual and 2 or 1) and #(s.incoming or {}) == (sq.dual and 2 or 1)
    end
    local function bendSide(s, sign)
        local ds = math.sqrt((s.x - N.x) ^ 2 + (s.z - N.z) ^ 2)
        local d = math.min(1.0, 0.5 * ds)
        if d < 0.3 then
            -- Too close to put a point between: swing the neighbour itself onto the square line, at
            -- the same distance.
            if ds < 0.1 or not plain(s) then return end
            ADGraphManager:moveWayPoint(s.id, N.x + sign * ds * sx, s.y, N.z + sign * ds * sz, s.flags, false)
            jxNoteMoved(s)
            jxSquareMade[s] = true
            bent = true
            return
        end
        local wp = ADFlyoverRecordWayPoint(N.x + sign * d * sx, N.y + (s.y - N.y) * (d / ds),
            N.z + sign * d * sz, false, false, false, 0, flags or AutoDrive.FLAG_NONE, false)
        jxState.jxLayLabel = label
        jxNoteAdded(wp)
        if wp == nil then jxState.jxLayLabel = nil return end
        jxSquareMade[wp] = true
        if sign < 0 then
            junctionDisconnect(s, N)
            junctionConnect(s, wp, sq.dual)
            junctionConnect(wp, N, sq.dual)
        else
            junctionDisconnect(N, s)
            junctionConnect(N, wp, sq.dual)
            junctionConnect(wp, s, sq.dual)
        end
        jxState.jxLayLabel = nil
        bent = true
    end
    bendSide(p, -1)
    bendSide(q, 1)
    return bent
end

local function junctionShareCrossings(cx, cz, reach)
    if jxState.jxBuildNew == nil then return 0 end
    jxState.jxShallowJoins = 0
    jxState.jxSquaredJoins = 0
    jxSquareMade = {}
    jxSlid = {}
    -- EDGE only keeps out crossings AT a link's end (two links meeting at a point already share it);
    -- a crossing merely near an end is handled by SNAP, through that end.
    local SNAP, EDGE, MAXH = AutoDrive.FLYOVER_JUNCTION_SHARE_SNAP or 0.75, 1e-4, 2.0
    -- Where to look: the junction's own circle, widened to take in every point the build added (a
    -- turn's tie-in can land well up a road), plus a margin for the links running on from there.
    local R2 = (reach + 15) ^ 2
    local minX, maxX, minZ, maxZ = cx, cx, cz, cz
    for w in pairs(jxState.jxBuildNew) do
        if w.x ~= nil then
            minX, maxX = math.min(minX, w.x), math.max(maxX, w.x)
            minZ, maxZ = math.min(minZ, w.z), math.max(maxZ, w.z)
        end
    end
    minX, maxX, minZ, maxZ = minX - 20, maxX + 20, minZ - 20, maxZ + 20
    local function inRegion(w)
        return (w.x - cx) ^ 2 + (w.z - cz) ^ 2 <= R2
            or (w.x >= minX and w.x <= maxX and w.z >= minZ and w.z <= maxZ)
    end
    local function splice(a, b, dual, N)
        local was = jxState.jxLayLabel
        jxState.jxLayLabel = jxState.jxLinkLabel ~= nil and ((jxState.jxLinkLabel[a] or {})[b] or (jxState.jxLinkLabel[b] or {})[a]) or nil
        junctionDisconnect(a, b)
        junctionConnect(a, N, dual)
        junctionConnect(N, b, dual)
        jxState.jxLayLabel = was
    end
    local joined = 0
    -- A pair of links met before is not joined again: in a tangle of points a metre apart, running one
    -- link through an existing point can make new links that cross the same pair again, and the
    -- search would go round in circles. Such a site is left with the crossing, and said so.
    local tried = {}
    local function pairKey(L1, L2)
        return tostring(L1.a) .. tostring(L1.b) .. "|" .. tostring(L2.a) .. tostring(L2.b)
    end
    local settled = false
    for _ = 1, 400 do
        -- Every link with both ends in the region, a two-way link once.
        local links = {}
        for _, a in pairs(ADGraphManager:getWayPoints()) do
            if a ~= nil and a.id ~= nil and inRegion(a) then
                for _, bid in ipairs(a.out or {}) do
                    local b = ADGraphManager:getWayPointById(bid)
                    if b ~= nil and b ~= a and inRegion(b) then
                        local dual = table.contains(b.out or {}, a.id)
                        if not dual or a.id < b.id then
                            links[#links + 1] = { a = a, b = b, dual = dual,
                                new = jxIsNewLink(a, b) or (dual and jxIsNewLink(b, a)) }
                        end
                    end
                end
            end
        end
        -- In a fixed order, so the same network always shares the same crossings first.
        table.sort(links, function(p, q)
            if p.a.x ~= q.a.x then return p.a.x < q.a.x end
            if p.a.z ~= q.a.z then return p.a.z < q.a.z end
            if p.b.x ~= q.b.x then return p.b.x < q.b.x end
            return p.b.z < q.b.z
        end)
        local found = nil
        for i = 1, #links do
            local L1 = links[i]
            if L1.new then
                for j = 1, #links do
                    local L2 = links[j]
                    if j ~= i and L1.a ~= L2.a and L1.a ~= L2.b and L1.b ~= L2.a and L1.b ~= L2.b
                        and not tried[pairKey(L1, L2)] then
                        local ax, az, bx, bz = L1.a.x, L1.a.z, L1.b.x, L1.b.z
                        local qx, qz, rx, rz = L2.a.x, L2.a.z, L2.b.x, L2.b.z
                        local den = (bx - ax) * (rz - qz) - (bz - az) * (rx - qx)
                        if math.abs(den) > 1e-9 then
                            local t = ((qx - ax) * (rz - qz) - (qz - az) * (rx - qx)) / den
                            local u = ((qx - ax) * (bz - az) - (qz - az) * (bx - ax)) / den
                            if t > EDGE and t < 1 - EDGE and u > EDGE and u < 1 - EDGE then
                                local y1 = (L1.a.y or 0) + ((L1.b.y or 0) - (L1.a.y or 0)) * t
                                local y2 = (L2.a.y or 0) + ((L2.b.y or 0) - (L2.a.y or 0)) * u
                                if math.abs(y1 - y2) <= MAXH then
                                    found = { L1 = L1, L2 = L2, x = ax + t * (bx - ax), z = az + t * (bz - az), y = (y1 + y2) / 2 }
                                    break
                                end
                            end
                        end
                    end
                end
            end
            if found ~= nil then break end
        end
        if found == nil then
            settled = true
            break
        end
        local L1, L2 = found.L1, found.L2
        local function near(w) return (w.x - found.x) ^ 2 + (w.z - found.z) ^ 2 <= SNAP * SNAP end
        tried[pairKey(L1, L2)] = true
        -- A crossing at 80 degrees or less lets AutoDrive switch between the two paths here (the route
        -- check then shows what that opens). Counted, so the build log says how many there were.
        do
            local ux, uz = L1.b.x - L1.a.x, L1.b.z - L1.a.z
            local vx, vz = L2.b.x - L2.a.x, L2.b.z - L2.a.z
            local nu, nv = math.sqrt(ux * ux + uz * uz), math.sqrt(vx * vx + vz * vz)
            if nu > 1e-6 and nv > 1e-6 then
                local ang = math.deg(math.acos(math.max(-1, math.min(1, (ux * vx + uz * vz) / (nu * nv)))))
                -- A two-way link runs both ways, so either direction can make the shallow side.
                if ang <= 80 or ((L1.dual or L2.dual) and ang >= 100) then
                    jxState.jxShallowJoins = (jxState.jxShallowJoins or 0) + 1
                end
            end
        end
        -- WHERE THE SHARED POINT GOES. A path run through a point BESIDE the crossing is bent there: a
        -- turn snapped through a point 0.7 m to its side bent 50-88 degrees, and AutoDrive crawls at
        -- 3 km/h past 50 (DrivePathModule.getMaxSpeedForAngle). Road lanes are never bent at all. So:
        --   1. one of OUR points near the crossing, with nothing else joined to it, SLIDES onto the
        --      crossing - the crossing lies on its own link, so our turn keeps its line - and the other
        --      path runs through it;
        --   2. an existing point near the crossing is shared as it stands only where running the other
        --      path through it bends that path 10 degrees or less;
        --   3. otherwise the crossing gets its own point, exactly where the two cross.
        local function dirOf(L) return L.b.x - L.a.x, L.b.z - L.a.z end
        local function bendVia(L, M)
            local x1, z1, x2, z2 = M.x - L.a.x, M.z - L.a.z, L.b.x - M.x, L.b.z - M.z
            local n1, n2 = math.sqrt(x1 * x1 + z1 * z1), math.sqrt(x2 * x2 + z2 * z2)
            if n1 < 1e-6 or n2 < 1e-6 then return 180 end
            return math.deg(math.acos(math.max(-1, math.min(1, (x1 * x2 + z1 * z2) / (n1 * n2)))))
        end
        -- N = the shared point, own = the link N is an end of, through = the link spliced through N.
        local N, own, through = nil, nil, nil
        local ownP, ownQ = nil, nil   -- own path's points either side of N, for squaring it up
        for _, c in ipairs({ { L1.a, L1, L2 }, { L1.b, L1, L2 }, { L2.a, L2, L1 }, { L2.b, L2, L1 } }) do
            local M = c[1]
            if N == nil and c[2].new and near(M) and jxPlainOurs(M) then
                local far = (M == c[2].a) and c[2].b or c[2].a
                local beyond = nil
                for _, id in ipairs(M.out or {}) do
                    local w = ADGraphManager:getWayPointById(id)
                    if w ~= nil and w ~= far then beyond = w end
                end
                for _, id in ipairs(M.incoming or {}) do
                    local w = ADGraphManager:getWayPointById(id)
                    if w ~= nil and w ~= far then beyond = w end
                end
                ADGraphManager:moveWayPoint(M.id, found.x, M.y, found.z, M.flags, false)
                jxNoteMoved(M)
                jxSlid[M] = true
                N, own, through = M, c[2], c[3]
                if M == c[2].b then ownP, ownQ = c[2].a, beyond else ownP, ownQ = beyond, c[2].b end
            end
        end
        if N == nil then
            for _, c in ipairs({ { L2.a, L2, L1 }, { L2.b, L2, L1 }, { L1.a, L1, L2 }, { L1.b, L1, L2 } }) do
                local M = c[1]
                if N == nil and near(M) and bendVia(c[3], M) <= 10 then N, own, through = M, c[2], c[3] end
            end
        end
        local sq = nil
        if N ~= nil then
            splice(through.a, through.b, through.dual, N)
            if through.new then
                local vx, vz = dirOf(own)
                sq = { p = through.a, N = N, q = through.b, dual = through.dual, vx = vx, vz = vz, otherDual = own.dual }
            elseif ownP ~= nil and ownQ ~= nil then
                local vx, vz = dirOf(through)
                sq = { p = ownP, N = N, q = ownQ, dual = own.dual, vx = vx, vz = vz, otherDual = through.dual }
            end
        else
            -- The existing road's flags, so a crossing point on it keeps the road's priority.
            local road = L2.new and L1 or L2
            N = ADFlyoverRecordWayPoint(found.x, found.y, found.z, false, false, false, 0,
                road.a.flags or AutoDrive.FLAG_NONE, false)
            jxState.jxLayLabel = "x"
            jxNoteAdded(N)
            jxState.jxLayLabel = nil
            if N == nil then break end
            splice(L1.a, L1.b, L1.dual, N)
            splice(L2.a, L2.b, L2.dual, N)
            local vx, vz = dirOf(L2)
            sq = { p = L1.a, N = N, q = L1.b, dual = L1.dual, vx = vx, vz = vz, otherDual = L2.dual }
        end
        -- OFF by default: once the shared point slides instead of snapping, it saved 1 extra route of 18 and
        -- put 20 sharp bends (12 or 3 km/h) into our turns (offline, 2026-10-02).
        if sq ~= nil and AutoDrive.FLYOVER_JUNCTION_SQUARE_CROSSINGS == true then
            if junctionSquareUp(sq) then jxState.jxSquaredJoins = jxState.jxSquaredJoins + 1 end
        end
        joined = joined + 1
    end
    if not settled then
        Logging.warning("[FlyoverEditor]: junction - the crossings here did not settle after %d joins (a tangle of points too close together); some may be left without a shared point.",
            joined)
    end
    return joined
end

-- Shared by the fitted pattern and the plain piece (doc 08): lanes near a point, and a point on a lane.
local function jxpLinksNear(px, pz, r)
    local t = {}
    for _, a in pairs(ADGraphManager:getWayPoints()) do
        if a ~= nil and a.id ~= nil and (a.x - px) ^ 2 + (a.z - pz) ^ 2 <= r * r then
            for _, bid in ipairs(a.out or {}) do
                local b = ADGraphManager:getWayPointById(bid)
                if b ~= nil and b ~= a then t[#t + 1] = { a = a, b = b } end
            end
        end
    end
    table.sort(t, function(p, q)
        if p.a.id ~= q.a.id then return p.a.id < q.a.id end
        return p.b.id < q.b.id
    end)
    return t
end
local function jxpUnit(x, z)
    local n = math.sqrt(x * x + z * z)
    if n < 1e-9 then return 0, 0 end
    return x / n, z / n
end

local function jxpGroundY(x, z, fallback)
    local y = nil
    if getTerrainHeightAtWorldPos ~= nil and g_currentMission ~= nil and g_currentMission.terrainRootNode ~= nil then
        local ok, v = pcall(getTerrainHeightAtWorldPos, g_currentMission.terrainRootNode, x, 1, z)
        if ok then y = v end
    end
    -- A junction on a bridge: the ground is far below the road, keep the road's height.
    if y == nil or (fallback ~= nil and math.abs(y - fallback) > 2) then return fallback end
    return y
end

-- A POINT ON A LANE: the lane running in direction (dx, dz) that passes nearest (px, pz). An end
-- of that link within 0.3 m is used as it is; otherwise a point is spliced in. `through` runs the
-- lane through a given point instead (a corner the other lane already has). dry only says whether
-- there is such a lane. A lane may bend a little past the junction: up to 1.5 m off the frame's
-- straight line and 30 degrees off its direction still counts, and the turn ends on the real lane.
local function jxpOnLane(px, pz, dx, dz, through, dry)
    local best, bd, bt = nil, 1.5, 0
    for _, l in ipairs(jxpLinksNear(px, pz, 20)) do
        local sx, sz = l.b.x - l.a.x, l.b.z - l.a.z
        local len2 = sx * sx + sz * sz
        if len2 > 1e-6 then
            local lx, lz = jxpUnit(sx, sz)
            if lx * dx + lz * dz > 0.87 then
                local t = ((px - l.a.x) * sx + (pz - l.a.z) * sz) / len2
                if t >= 0 and t <= 1 then
                    local d = math.abs((px - l.a.x) * lz - (pz - l.a.z) * lx)
                    if d < bd then best, bd, bt = l, d, t end
                end
            end
        end
    end
    if best == nil then return nil end
    if dry then return true end
    local a, b = best.a, best.b
    if through ~= nil then
        if through == a or through == b then return through end
        local dual = table.contains(b.out or {}, a.id)
        junctionDisconnect(a, b)
        junctionConnect(a, through, dual)
        junctionConnect(through, b, dual)
        return through
    end
    local slen = math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
    if bt * slen <= 0.3 then return a end
    if (1 - bt) * slen <= 0.3 then return b end
    local x, z = a.x + bt * (b.x - a.x), a.z + bt * (b.z - a.z)
    local y = (a.y or 0) + bt * ((b.y or 0) - (a.y or 0))
    local N = ADFlyoverRecordWayPoint(x, y, z, false, false, false, 0, a.flags or AutoDrive.FLAG_NONE, false)
    jxNoteAdded(N)
    if N == nil then return nil end
    local dual = table.contains(b.out or {}, a.id)
    junctionDisconnect(a, b)
    junctionConnect(a, N, dual)
    junctionConnect(N, b, dual)
    return N
end

-- THE PATTERN (docs/junction-tool/07-pattern-build.md). Instead of fitting one curve per turn, place the
-- X we studied in the mod (doc 05), fitted to this junction:
--   * the FRAME comes from the kept through lanes: they cross at four inner corners; the middle of those
--     is the centre, their spacing the lane gap L, the lane directions the axes;
--   * "exact" lays the mod's own shape: a shared point at each inner corner, a short 45-degree cut for
--     each right turn, and every left turn through one centre point on two-way spokes;
--   * "smooth" lays the same pattern with curves: rights of 1.5 L hugging each corner, lefts of 1.71 L,
--     the size at which all four pass exactly through the one centre point.
-- Sizes come from the lane gap for now (decided 2026-10-02). Version 1 is a square X on one-way lanes;
-- anything else returns nil with the reason, and the caller builds turn by turn as before.
-- Mod frame: +x along one through lane; +z is +x turned a quarter to the right (FS25 x east, z south), so
-- with right-hand traffic the +x lane runs at z = +0.5 L. Returns { shape, kind, turns, L } or nil, why,
-- wired. dry (place mode's preview) only works out what would be placed and changes nothing.
-- THE PLAIN PIECE (docs/junction-tool/08-place-junction.md). Where the crossing doesn't fit the pattern,
-- the mod's own square X or T is placed anyway, lined up with the main road at the cursor: never refused,
-- never the old builder. Each of its points that lands on a lane running its way joins that lane; the
-- rest are laid free, and any of the piece's arm ends left free is a LOOSE END, listed on the card, to
-- join by hand. The pieces in doc 05's numbering, in lane gaps (the T's side road to +z).
local JX_PLAIN = {
    X = {
        nodes = { [1] = { 0, 0 }, [2] = { -0.5, 0.5 }, [3] = { -0.75, 0.5 }, [4] = { -1.5, 0.5 }, [5] = { -0.5, 0.75 },
            [6] = { -0.5, 1.5 }, [7] = { 0.5, 1.5 }, [8] = { 0.5, 0.75 }, [9] = { 0.5, 0.5 }, [10] = { 0.75, 0.5 },
            [11] = { 1.5, 0.5 }, [12] = { 1.5, -0.5 }, [13] = { 0.75, -0.5 }, [14] = { 0.5, -0.5 }, [15] = { 0.5, -0.75 },
            [16] = { 0.5, -1.5 }, [17] = { -0.5, -1.5 }, [18] = { -0.5, -0.75 }, [19] = { -0.5, -0.5 }, [20] = { -0.75, -0.5 },
            [21] = { -1.5, -0.5 } },
        links = { { 1, 2 }, { 2, 1 }, { 1, 9 }, { 9, 1 }, { 1, 14 }, { 14, 1 }, { 1, 19 }, { 19, 1 }, { 2, 5 }, { 2, 9 },
            { 3, 2 }, { 3, 5 }, { 4, 3 }, { 5, 6 }, { 7, 8 }, { 8, 9 }, { 8, 10 }, { 9, 10 }, { 9, 14 }, { 10, 11 },
            { 12, 13 }, { 13, 14 }, { 13, 15 }, { 14, 15 }, { 14, 19 }, { 15, 16 }, { 17, 18 }, { 18, 19 }, { 18, 20 },
            { 19, 20 }, { 19, 2 }, { 20, 21 } },
    },
    T = {
        nodes = { [1] = { 0, 0 }, [2] = { -0.5, 0.5 }, [3] = { -0.75, 0.5 }, [4] = { -1.5, 0.5 }, [5] = { -0.5, 0.75 },
            [6] = { -0.5, 1.5 }, [7] = { 0.5, 1.5 }, [8] = { 0.5, 0.75 }, [9] = { 0.5, 0.5 }, [10] = { 0.75, 0.5 },
            [11] = { 1.5, 0.5 }, [12] = { 1.5, -0.5 }, [13] = { -1.5, -0.5 } },
        links = { { 1, 2 }, { 1, 13 }, { 2, 5 }, { 2, 9 }, { 3, 2 }, { 3, 5 }, { 4, 3 }, { 5, 6 }, { 7, 8 }, { 8, 9 },
            { 8, 10 }, { 9, 10 }, { 9, 1 }, { 10, 11 }, { 12, 13 }, { 12, 1 } },
    },
}

local JX_PATTERN_RIGHT, JX_PATTERN_LEFT = 1.5, 1.71
local function junctionPlaceFitted(cx, cz, reach, shape, dry)
    local R = math.max(reach or 15, 15)
    local function near(w, r) return (w.x - cx) ^ 2 + (w.z - cz) ^ 2 <= r * r end
    local linksNear, unit = jxpLinksNear, jxpUnit

    -- 1. INNER CORNERS: two lanes crossing at a real angle near the site, either in open space or at a
    -- point they already share.
    local corners = {}
    local function addCorner(x, z, u1x, u1z, u2x, u2z)
        if not near({ x = x, z = z }, 12) then return end
        for _, c in ipairs(corners) do
            if (c.x - x) ^ 2 + (c.z - z) ^ 2 < 0.25 then return end
        end
        corners[#corners + 1] = { x = x, z = z, dirs = { { u1x, u1z }, { u2x, u2z } } }
    end
    local L0 = linksNear(cx, cz, R + 10)
    for i = 1, #L0 do
        for j = i + 1, #L0 do
            local p, q = L0[i], L0[j]
            if p.a ~= q.a and p.a ~= q.b and p.b ~= q.a and p.b ~= q.b then
                local ax, az, bx, bz = p.a.x, p.a.z, p.b.x, p.b.z
                local qx, qz, rx, rz = q.a.x, q.a.z, q.b.x, q.b.z
                local den = (bx - ax) * (rz - qz) - (bz - az) * (rx - qx)
                if math.abs(den) > 1e-9 then
                    local t = ((qx - ax) * (rz - qz) - (qz - az) * (rx - qx)) / den
                    local u = ((qx - ax) * (bz - az) - (qz - az) * (bx - ax)) / den
                    if t > 0 and t < 1 and u > 0 and u < 1 then
                        local u1x, u1z = unit(bx - ax, bz - az)
                        local u2x, u2z = unit(rx - qx, rz - qz)
                        if math.abs(u1x * u2x + u1z * u2z) < 0.5 then
                            addCorner(ax + t * (bx - ax), az + t * (bz - az), u1x, u1z, u2x, u2z)
                        end
                    end
                end
            end
        end
    end
    -- Lanes that already share a point where they cross: two straight runs through one point.
    for _, w in pairs(ADGraphManager:getWayPoints()) do
        if w ~= nil and w.id ~= nil and near(w, 12) and #(w.incoming or {}) >= 2 and #(w.out or {}) >= 2 then
            local runs = {}
            for _, iid in ipairs(w.incoming) do
                local i = ADGraphManager:getWayPointById(iid)
                for _, oid in ipairs(w.out) do
                    local o = ADGraphManager:getWayPointById(oid)
                    if i ~= nil and o ~= nil and i ~= o then
                        local ax, az = unit(w.x - i.x, w.z - i.z)
                        local bx, bz = unit(o.x - w.x, o.z - w.z)
                        if ax * bx + az * bz > 0.94 then runs[#runs + 1] = { ax, az } end
                    end
                end
            end
            for a = 1, #runs do
                for b = a + 1, #runs do
                    if math.abs(runs[a][1] * runs[b][1] + runs[a][2] * runs[b][2]) < 0.5 then
                        addCorner(w.x, w.z, runs[a][1], runs[a][2], runs[b][1], runs[b][2])
                    end
                end
            end
        end
    end
    -- 2. THE FRAME. An X: from its four inner corners. A T: from where the side road's two lanes end,
    -- and the main road's two lanes, which run straight past.
    -- SKEW (doc 08, 2026-10-05): the frame has two directions of its own, E1 along the main road and E2
    -- along the cross or side road, so a road meeting off square gets the pattern leant to its real angle.
    -- Straight paths stay straight and curves stay tangent to the lanes they join. How far off square is
    -- set by AutoDrive's 80-degree bend limit on the mod's shape: an X to 35 (its lefts run corner - centre -
    -- corner, worst bend 73), a T to 50 (worst 72; at 55 its sharp left would bend 81).
    local kind, ox, oz, ux, uz, vx, vz, L = nil, 0, 0, nil, nil, nil, nil, 0
    local e1x, e1z, e2x, e2z = nil, nil, nil, nil
    local sideIn, sideOut = nil, nil
    local twoWaySide = nil      -- a T whose side road is one two-way road: its end
    if #corners == 4 then
        kind = "X"
        for _, c in ipairs(corners) do ox, oz = ox + c.x / 4, oz + c.z / 4 end
        local ex = nil
        for _, c in ipairs(corners) do
            for _, d in ipairs(c.dirs) do
                -- +z is +x turned a quarter to the right; the +x lane must run on the +z side of the centre.
                local zx, zz = -d[2], d[1]
                if ex == nil and (c.x - ox) * zx + (c.z - oz) * zz > 0 then ex = d end
            end
        end
        if ex == nil then return nil, "could not tell the lane directions apart" end
        ux, uz = ex[1], ex[2]
        vx, vz = -uz, ux
        -- The corners by quarter, in the first guess at the frame: (+x, +z), (+x, -z), (-x, +z), (-x, -z).
        local q = {}
        for _, c in ipairs(corners) do
            local lx, lz = (c.x - ox) * ux + (c.z - oz) * uz, (c.x - ox) * vx + (c.z - oz) * vz
            local key = (lx > 0 and "+" or "-") .. (lz > 0 and "+" or "-")
            if q[key] ~= nil then return nil, "the lanes do not cross in a four-cornered box" end
            q[key] = c
        end
        if not (q["++"] and q["+-"] and q["-+"] and q["--"]) then
            return nil, "the lanes do not cross in a four-cornered box"
        end
        e1x = (q["++"].x + q["+-"].x - q["-+"].x - q["--"].x) / 2
        e1z = (q["++"].z + q["+-"].z - q["-+"].z - q["--"].z) / 2
        e2x = (q["++"].x + q["-+"].x - q["+-"].x - q["--"].x) / 2
        e2z = (q["++"].z + q["-+"].z - q["+-"].z - q["--"].z) / 2
        local n1, n2 = math.sqrt(e1x * e1x + e1z * e1z), math.sqrt(e2x * e2x + e2z * e2z)
        if n1 < 1e-3 or n2 < 1e-3 then return nil, "the lanes do not cross in a four-cornered box" end
        ux, uz = e1x / n1, e1z / n1
        vx, vz = -uz, ux
        L = math.abs(e2x * vx + e2z * vz)      -- the main road's lane gap, square across it
        if math.abs((e1x * e2x + e1z * e2z) / (n1 * n2)) > 0.574 then
            return nil, "the roads cross more than 35 degrees off square"
        end
        for key, c in pairs(q) do
            local sx = key:sub(1, 1) == "+" and 0.5 or -0.5
            local sz = key:sub(2, 2) == "+" and 0.5 or -0.5
            local px, pz = ox + sx * e1x + sz * e2x, oz + sx * e1z + sz * e2z
            if math.sqrt((px - c.x) ^ 2 + (pz - c.z) ^ 2) > 0.25 * math.min(n1, n2) then
                return nil, "the lanes do not cross in an even box (a lane bends between the corners)"
            end
        end    else
        kind = "T"
        -- The side road: one lane in that stops near the main road, one lane out that starts there.
        local ends, starts = {}, {}
        for _, w in pairs(ADGraphManager:getWayPoints()) do
            if w ~= nil and w.id ~= nil and near(w, 14) then
                local nin, nout = #(w.incoming or {}), #(w.out or {})
                if nout == 0 and nin >= 1 then ends[#ends + 1] = w end
                if nin == 0 and nout >= 1 then starts[#starts + 1] = w end
            end
        end
        -- The side road is a PAIR: a lane in and a lane out running opposite ways, a lane gap apart.
        -- Another end the clear left nearby is not part of it (in game j3 had one), so the pair nearest the
        -- middle is taken and any stray is ignored.
        local bestPair, bestD = nil, nil
        if #corners == 0 then
            for _, e in ipairs(ends) do
                local p = ADGraphManager:getWayPointById(e.incoming[1])
                for _, s in ipairs(starts) do
                    local q = ADGraphManager:getWayPointById(s.out[1])
                    if p ~= nil and q ~= nil then
                        local ax, az = unit(e.x - p.x, e.z - p.z)
                        local bx, bz = unit(q.x - s.x, q.z - s.z)
                        local gap = math.sqrt((e.x - s.x) ^ 2 + (e.z - s.z) ^ 2)
                        if ax * bx + az * bz < -0.94 and gap > 1.5 and gap < 14 then
                            local d = ((e.x + s.x) / 2 - cx) ^ 2 + ((e.z + s.z) / 2 - cz) ^ 2
                            if bestD == nil or d < bestD then bestPair, bestD = { e, s }, d end
                        end
                    end
                end
            end
        end
        -- A SIDE ROAD THAT IS ONE TWO-WAY ROAD: its end (one neighbour, joined both ways) stands for both
        -- lanes. The piece's two side lanes split from it at the mouth: lane out -> road end -> lane in.
        if bestPair == nil and #corners == 0 then
            local bd2 = nil
            for _, w in pairs(ADGraphManager:getWayPoints()) do
                if w ~= nil and w.id ~= nil and near(w, 14) then
                    local nb, n, only = {}, 0, nil
                    for _, id in ipairs(w.out or {}) do if not nb[id] then nb[id] = true n = n + 1 only = id end end
                    for _, id in ipairs(w.incoming or {}) do if not nb[id] then nb[id] = true n = n + 1 only = id end end
                    if n == 1 and table.contains(w.out or {}, only) and table.contains(w.incoming or {}, only) then
                        local d = (w.x - cx) ^ 2 + (w.z - cz) ^ 2
                        if bd2 == nil or d < bd2 then bestPair, bd2, twoWaySide = { w, w, only }, d, w end
                    end
                end
            end
        end
        if bestPair == nil then
            return nil, string.format("not an X (%d lane crossings) and no side road found (%d lane ends, %d lane starts near the middle)",
                #corners, #ends, #starts)
        end
        sideIn, sideOut = bestPair[1], bestPair[2]
        local p = ADGraphManager:getWayPointById(sideIn.incoming[1])
        local q = ADGraphManager:getWayPointById(sideOut.out[1])
        if twoWaySide ~= nil then p = ADGraphManager:getWayPointById(bestPair[3]) q = p end
        if p == nil or q == nil then return nil, "lost the side road's lanes" end
        local dix, diz = unit(sideIn.x - p.x, sideIn.z - p.z)      -- heading in, towards the main road
        local dox, doz = unit(q.x - sideOut.x, q.z - sideOut.z)    -- heading out, away from it
        if twoWaySide ~= nil then dox, doz = -dix, -diz end
        if dix * dox + diz * doz > -0.94 then return nil, "the side road's two lanes do not run opposite ways" end
        -- First guess: square to the side road. Then the main road's own lanes at the mouth set +x, and
        -- the side road may sit up to 50 degrees off square to them.
        vx, vz = -dix, -diz      -- +z runs down the side road
        ux, uz = vz, -vx         -- +x is +z turned a quarter back to the left
        local xOut, xm, east, west
        local function pickMain(minAlong)
            -- Where the side road's lanes sit across it: in at x = 0 (from sideIn), out at about -L.
            xOut = (sideOut.x - sideIn.x) * ux + (sideOut.z - sideIn.z) * uz
            xm = xOut / 2
            -- The main road's two lanes passing the mouth: the +x one nearer, the -x one next beyond it.
            -- Positions measured along +z from sideIn.
            local cand = {}
            for _, l in ipairs(linksNear(sideIn.x, sideIn.z, 25)) do
                local lx, lz = unit(l.b.x - l.a.x, l.b.z - l.a.z)
                local along = lx * ux + lz * uz
                local ua = (l.a.x - sideIn.x) * ux + (l.a.z - sideIn.z) * uz
                local ub = (l.b.x - sideIn.x) * ux + (l.b.z - sideIn.z) * uz
                if math.abs(along) > minAlong and math.min(ua, ub) <= xm and math.max(ua, ub) >= xm then
                    local tt = (xm - ua) / (ub - ua)
                    local zl = ((l.a.x + tt * (l.b.x - l.a.x)) - sideIn.x) * vx + ((l.a.z + tt * (l.b.z - l.a.z)) - sideIn.z) * vz
                    if zl < 0 then cand[#cand + 1] = { zl = zl, dir = along > 0 and 1 or -1, dx = lx, dz = lz } end
                end
            end
            local e, w = nil, nil
            for _, c in ipairs(cand) do
                if c.dir > 0 and (e == nil or c.zl > e.zl) then e = c end
            end
            if e == nil then return nil, "no main-road lane runs past the side road the right way" end
            for _, c in ipairs(cand) do
                if c.dir < 0 and c.zl < e.zl - 0.5 and (w == nil or c.zl > w.zl) then w = c end
            end
            if w == nil then return nil, "no second main-road lane beyond the first" end
            return e, w
        end
        local e, w = pickMain(0.5)
        if e == nil then return nil, w end
        ux, uz = unit(e.dx - w.dx, e.dz - w.dz)
        vx, vz = -uz, ux
        -- The side road's own direction, away from the main road: the average of its two lanes.
        local sdx, sdz = unit(dox - dix, doz - diz)
        local cosS = sdx * vx + sdz * vz
        if cosS < 0.643 then
            return nil, "the side road meets the main road more than 50 degrees off square"
        end
        e, w = pickMain(0.966)
        if e == nil then return nil, w end
        east, west = e.zl, w.zl
        L = east - west
        -- Each side lane, followed along the side road to the main road's centre line (zm, measured
        -- along +z from sideIn): the lane in crosses it at x = +0.5, the lane out at x = -0.5.
        local zm = (east + west) / 2
        local zOut = (sideOut.x - sideIn.x) * vx + (sideOut.z - sideIn.z) * vz
        local tIn, tOut = zm / cosS, (zm - zOut) / cosS
        local pix, piz = sideIn.x + tIn * sdx, sideIn.z + tIn * sdz
        local pox, poz = sideOut.x + tOut * sdx, sideOut.z + tOut * sdz
        ox, oz = (pix + pox) / 2, (piz + poz) / 2
        e1x, e1z = pix - pox, piz - poz
        -- One two-way road: its line is the side road's middle; the piece's side lanes go a lane gap apart.
        if twoWaySide ~= nil then e1x, e1z = L * ux, L * uz end
        local n1 = math.sqrt(e1x * e1x + e1z * e1z)
        if n1 < 0.6 * L or n1 > 1.6 * L then
            return nil, string.format("the side road's lanes are %.1f m apart, not like the main road's %.1f m", n1, L)
        end
        e2x, e2z = L * sdx / cosS, L * sdz / cosS
    end    if L < 2 or L > 12 then return nil, string.format("lane gap %.1f m is outside 2-12 m", L) end
    local skew = math.deg(math.acos(math.max(-1, math.min(1, math.abs(e2x * vx + e2z * vz)
        / math.max(1e-6, math.sqrt(e2x * e2x + e2z * e2z))))))
    if not dry then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction pattern - frame: %s, centre %.1f, %.1f, lane gap %.1f m, +x heading %.2f, %.2f, %.0f deg off square.",
            kind, ox, oz, L, ux, uz, skew)
    end
    local function W(mx, mz) return ox + mx * e1x + mz * e2x, oz + mx * e1z + mz * e2z end
    local function D(mx, mz) return unit(mx * e1x + mz * e2x, mx * e1z + mz * e2z) end
    -- Curves are sampled by the longer of the two directions.
    local Lscale = math.max(math.sqrt(e1x * e1x + e1z * e1z), math.sqrt(e2x * e2x + e2z * e2z))
    -- The mod's corner cut starts and ends a quarter lane gap from the corner. Measured in METRES along
    -- each lane, not in the frame's units, so on a leaning piece the cut still splits the turn into two
    -- equal bends (two of 67 degrees at 45 off square, where frame units would give 45 and 90).
    local f1 = 0.25 * L / math.max(1e-6, math.sqrt(e1x * e1x + e1z * e1z))
    local f2 = 0.25 * L / math.max(1e-6, math.sqrt(e2x * e2x + e2z * e2z))
    local function cutAt(k)   -- the corner cut of approach k: start on its lane in, end on the lane out
        local fa, fb = f1, f2
        if k % 2 == 1 then fa, fb = f2, f1 end
        local ax, az, bx, bz = -0.5 - fa, 0.5, -0.5, 0.5 + fb
        for _ = 1, k do ax, az = -az, ax bx, bz = -bz, bx end   -- turned k quarters (as rot, defined below)
        return ax, az, bx, bz
    end
    local function rot(x, z, k)
        for _ = 1, k do x, z = -z, x end
        return x, z
    end
    local groundY, onLane = jxpGroundY, jxpOnLane

    -- A POINT THE PATTERN NEEDS on the lane running (ddx, ddz) in the mod frame. In a T the side road's
    -- lanes stop short of the main road; a point between a lane's end and the main road extends that
    -- lane to it (in: lane end -> point; out: point -> lane start). `dry` only says whether it can.
    local function lanePoint(mx, mz, ddx, ddz, dry)
        local px, pz = W(mx, mz)
        local dx, dz = D(ddx, ddz)
        local sidePoint = kind == "T" and math.abs(ddx) <= 0.5
        local r = nil
        if not (sidePoint and twoWaySide ~= nil) then r = onLane(px, pz, dx, dz, nil, dry) end
        if r ~= nil then return r end
        if kind ~= "T" or math.abs(ddx) > 0.5 then return nil end
        local stub, forward = sideOut, false
        if ddz < 0 then stub, forward = sideIn, true end
        local ahead = (px - stub.x) * dx + (pz - stub.z) * dz
        if (forward and ahead <= 0.3) or (not forward and ahead >= -0.3) then return nil end
        if math.sqrt((px - stub.x) ^ 2 + (pz - stub.z) ^ 2) > 2.5 * L then return nil end
        if dry then return true end
        local N = ADFlyoverRecordWayPoint(px, groundY(px, pz, stub.y or 0), pz, false, false, false, 0,
            stub.flags or AutoDrive.FLAG_NONE, false)
        jxNoteAdded(N)
        if N == nil then return nil end
        if forward then junctionConnect(stub, N, false) else junctionConnect(N, stub, false) end
        return N
    end

    -- THE TURNS OF EACH SHAPE, in the mod frame (doc 05's node numbers in the comments).
    -- Smooth: a right of approach k (the +x lane turned k quarters) runs on a circle centred
    -- (-0.5 - r, 0.5 + r), a left on one centred (0.5 - r, 0.5 - r) through the centre.
    local RR, LR = JX_PATTERN_RIGHT, JX_PATTERN_LEFT
    local function smoothRight(k)
        local ax, az = rot(-0.5 - RR, 0.5, k)
        local bx, bz = rot(-0.5, 0.5 + RR, k)
        local d1x, d1z = rot(1, 0, k)
        local d2x, d2z = rot(0, 1, k)
        return { a = { ax, az, d1x, d1z, "right turn start" }, b = { bx, bz, d2x, d2z, "right turn end" },
                 arc = { -0.5 - RR, 0.5 + RR, RR, -math.pi / 2, 0, k, false }, kind = "R90" }
    end
    local function smoothLeft(k)
        local ax, az = rot(0.5 - LR, 0.5, k)
        local bx, bz = rot(0.5, 0.5 - LR, k)
        local d1x, d1z = rot(1, 0, k)
        local d3x, d3z = rot(0, -1, k)
        return { a = { ax, az, d1x, d1z, "left turn start" }, b = { bx, bz, d3x, d3z, "left turn end" },
                 arc = { 0.5 - LR, 0.5 - LR, LR, math.pi / 2, 0, k, true }, kind = "L90" }
    end
    -- A T keeps only the turns that exist: the side road is to the +z side. Rights: +x into the side
    -- road (k 0), the side road into +x (k 3). Lefts: -x into the side road (k 2), the side road into -x (k 3).
    local function smoothTurns()
        local t = {}
        if kind == "X" then
            for k = 0, 3 do t[#t + 1] = smoothRight(k) t[#t + 1] = smoothLeft(k) end
        else
            t = { smoothRight(0), smoothRight(3), smoothLeft(2), smoothLeft(3) }
        end
        return t
    end
    -- The mod's T: points on the +x lane 3 (-0.75), 2 (-0.5), 9 (0.5), 10 (0.75); on the -x lane 12 (1.5)
    -- and 13 (-1.5); the side road's out lane at 5 (-0.5, 0.75), its in lane at 8 (0.5, 0.75).
    local T_EXACT = {
        n3 = { -0.5 - f1, 0.5, 1, 0, "right turn start" }, n2 = { -0.5, 0.5, 1, 0, "inner corner" },
        n9 = { 0.5, 0.5, 1, 0, "inner corner" }, n10 = { 0.5 + f1, 0.5, 1, 0, "right turn end" },
        n12 = { 1.5, -0.5, -1, 0, "left turn start" }, n13 = { -1.5, -0.5, -1, 0, "left turn end" },
        n5 = { -0.5, 0.5 + f2, 0, 1, "side road's lane out" }, n8 = { 0.5, 0.5 + f2, 0, -1, "side road's lane in" },
    }
    local T_ORDER = { "n3", "n2", "n9", "n10", "n12", "n13", "n5", "n8" }

    -- ALL OR NOTHING: every point the shape needs must have its lane before anything is laid. The smooth
    -- turns end further out (2 L), where a lane may already have bent away; the mod's shape stays within
    -- about 0.75 L of the centre (1.5 L along a T's main road), so where smooth does not fit, the mod's
    -- shape is placed instead.
    local function needs(sh)
        local t = {}
        if kind == "X" then
            for k = 0, 3 do
                local cx1, cz1 = rot(-0.5, 0.5, k)
                local d1x, d1z = rot(1, 0, k)
                local d2x, d2z = rot(0, 1, k)
                t[#t + 1] = { cx1, cz1, d1x, d1z, "inner corner" }
                t[#t + 1] = { cx1, cz1, d2x, d2z, "inner corner" }
                if sh == "exact" then
                    local ax, az, bx, bz = cutAt(k)
                    t[#t + 1] = { ax, az, d1x, d1z, "right turn start" }
                    t[#t + 1] = { bx, bz, d2x, d2z, "right turn end" }
                end
            end
        elseif sh == "exact" then
            for _, key in ipairs(T_ORDER) do t[#t + 1] = T_EXACT[key] end
        end
        if sh ~= "exact" then
            for _, turn in ipairs(smoothTurns()) do t[#t + 1] = turn.a t[#t + 1] = turn.b end
        end
        return t
    end
    local function fits(sh)
        if twoWaySide ~= nil and sh ~= "exact" then
            return false, "the side road is one two-way road, and the smooth shape needs two side lanes"
        end
        for _, n in ipairs(needs(sh)) do
            if not lanePoint(n[1], n[2], n[3], n[4], true) then
                local x, z = W(n[1], n[2])
                return false, string.format("no lane under the %s at %.1f, %.1f", n[5], x, z)
            end
        end
        return true
    end
    local okFit, whyNot = fits(shape)
    if not okFit and shape == "smooth" and fits("exact") then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction pattern - the smooth %s does not fit here (%s); placing the mod's %s instead.",
            kind, whyNot, kind)
        shape = "exact"
    elseif not okFit then
        return nil, whyNot
    end
    if dry then
        -- What the preview draws: each new path as a line through world points, and the shared points.
        local lines, marks = {}, {}
        local function P(mx, mz) local x, z = W(mx, mz) return { x = x, z = z } end
        local piece = JX_PLAIN[kind]
        -- The corner cuts where they are really laid (see cutAt).
        local pos = {}
        for n, p in pairs(piece.nodes) do pos[n] = p end
        if kind == "X" then
            for k, pair in pairs({ [0] = { 3, 5 }, [1] = { 18, 20 }, [2] = { 13, 15 }, [3] = { 8, 10 } }) do
                local ax, az, bx, bz = cutAt(k)
                pos[pair[1]], pos[pair[2]] = { ax, az }, { bx, bz }
            end
        else
            pos[3], pos[5] = { T_EXACT.n3[1], T_EXACT.n3[2] }, { T_EXACT.n5[1], T_EXACT.n5[2] }
            pos[8], pos[10] = { T_EXACT.n8[1], T_EXACT.n8[2] }, { T_EXACT.n10[1], T_EXACT.n10[2] }
        end
        if shape == "exact" then
            local new = (kind == "X")
                and { { 1, 2, true }, { 1, 9, true }, { 1, 14, true }, { 1, 19, true },
                      { 3, 5 }, { 8, 10 }, { 13, 15 }, { 18, 20 } }
                or { { 3, 5 }, { 8, 10 }, { 12, 1 }, { 1, 2 }, { 2, 5 }, { 8, 9 }, { 9, 1 }, { 1, 13 } }
            for _, l in ipairs(new) do
                local a, b = pos[l[1]], pos[l[2]]
                lines[#lines + 1] = { pts = { P(a[1], a[2]), P(b[1], b[2]) }, dual = l[3] == true }
            end
            local shared = (kind == "X") and { 1, 2, 9, 14, 19, 5, 10, 15, 20 } or { 1, 2, 9, 5, 10, 13 }
            for _, n in ipairs(shared) do marks[#marks + 1] = P(pos[n][1], pos[n][2]) end
        else
            for _, turn in ipairs(smoothTurns()) do
                local c = turn.arc
                local pts = { P(turn.a[1], turn.a[2]) }
                for i = 1, 11 do
                    local a = c[4] + (c[5] - c[4]) * i / 12
                    pts[#pts + 1] = P(rot(c[1] + c[3] * math.cos(a), c[2] + c[3] * math.sin(a), c[6]))
                end
                pts[#pts + 1] = P(turn.b[1], turn.b[2])
                lines[#lines + 1] = { pts = pts }
            end
            marks[#marks + 1] = P(0, 0)
        end
        return { shape = shape, kind = kind, L = L, ox = ox, oz = oz, ux = ux, uz = uz, turns = 0,
                 lines = lines, marks = marks }
    end

    -- 4. LAYING.
    local turns = 0
    local function label(k)
        jxState.jxLaySeq = jxState.jxLaySeq + 1
        jxState.jxLayLabel = k .. "#" .. jxState.jxLaySeq
    end
    local function lay(A, pts, B, k)
        if A == nil or B == nil or A == B then return false end
        label(k)
        local ok, laid = tryCall("junction pattern lay", function()
            return junctionLayChain(A, pts, B, false, B.flags or AutoDrive.FLAG_NONE)
        end)
        jxState.jxLayLabel = nil
        if ok and laid == true then turns = turns + 1 return true end
        return false
    end
    -- Interior points of an arc in mod units, about every 2 m, as world points; with centreMid the
    -- middle sample is the junction's centre (the lefts' shared point).
    local function arcPoints(acx, acz, r, a0, a1, k, centreMid, y0, y1)
        local len = math.abs(a1 - a0) * r * Lscale
        local n = math.max(2, math.floor(len / 2 + 0.5))
        if centreMid and n % 2 == 1 then n = n + 1 end
        local pts = {}
        for i = 1, n - 1 do
            local a = a0 + (a1 - a0) * i / n
            local mx, mz = rot(acx + r * math.cos(a), acz + r * math.sin(a), k)
            local x, z = W(mx, mz)
            local fy = y0 + (y1 - y0) * i / n
            pts[#pts + 1] = { x = x, z = z, y = groundY(x, z, fy), centre = (centreMid and i == n / 2) or nil }
        end
        return pts
    end
    local function newCentre(flags, y)
        local cxw, czw = W(0, 0)
        local O = ADFlyoverRecordWayPoint(cxw, groundY(cxw, czw, y), czw, false, false, false, 0,
            flags or AutoDrive.FLAG_NONE, false)
        jxState.jxLayLabel = "centre"
        jxNoteAdded(O)
        jxState.jxLayLabel = nil
        return O
    end

    -- An X's inner corners, shared by both lanes. Corner k sits at (-0.5, 0.5) turned k quarters: where
    -- the +x lane (turned k) crosses the +z lane (turned k).
    local cornerNode = {}
    if kind == "X" then
        for k = 0, 3 do
            local mx, mz = rot(-0.5, 0.5, k)
            local px, pz = W(mx, mz)
            local d2x, d2z = D(rot(0, 1, k))
            local d1mx, d1mz = rot(1, 0, k)
            local N = lanePoint(mx, mz, d1mx, d1mz)
            if N == nil then return nil, "lost a lane at an inner corner" end
            if onLane(px, pz, d2x, d2z, N) == nil then return nil, "lost a lane at an inner corner" end
            cornerNode[k] = N
        end
    end

    if shape == "exact" and kind == "X" then
        local cy = 0
        for k = 0, 3 do cy = cy + (cornerNode[k].y or 0) / 4 end
        local O = newCentre(cornerNode[0].flags, cy)
        if O == nil then return nil, "could not add the centre point" end
        -- The spokes: every left turn goes corner -> centre -> corner, so each spoke runs both ways.
        label("L-spokes")
        for k = 0, 3 do junctionConnect(O, cornerNode[k], true) end
        jxState.jxLayLabel = nil
        turns = turns + 4
        for k = 0, 3 do
            local ax, az, bx, bz = cutAt(k)
            local d1x, d1z = rot(1, 0, k)
            local d2x, d2z = rot(0, 1, k)
            lay(lanePoint(ax, az, d1x, d1z), {}, lanePoint(bx, bz, d2x, d2z), "R45")
        end
    elseif shape == "exact" then
        -- The mod's T (doc 05): every path one-way. The left from -x into the side road runs 12 ->
        -- centre -> 2 -> 5; the left out of the side road 8 -> 9 -> centre -> 13; they take turns at the
        -- centre. The rights are the short cuts 3 -> 5 and 8 -> 10.
        local n = {}
        for _, key in ipairs(T_ORDER) do
            local s = T_EXACT[key]
            n[key] = lanePoint(s[1], s[2], s[3], s[4])
            if n[key] == nil then return nil, "lost the lane under the " .. s[5] end
        end
        local O = newCentre(n.n2.flags, ((n.n2.y or 0) + (n.n9.y or 0)) / 2)
        if O == nil then return nil, "could not add the centre point" end
        lay(n.n3, {}, n.n5, "R45")
        lay(n.n8, {}, n.n10, "R45")
        label("L-in")
        junctionConnect(n.n12, O, false)
        junctionConnect(O, n.n2, false)
        junctionConnect(n.n2, n.n5, false)
        jxState.jxLayLabel = nil
        label("L-out")
        junctionConnect(n.n8, n.n9, false)
        junctionConnect(n.n9, O, false)
        junctionConnect(O, n.n13, false)
        jxState.jxLayLabel = nil
        turns = turns + 2
    else
        for _, turn in ipairs(smoothTurns()) do
            local A = lanePoint(turn.a[1], turn.a[2], turn.a[3], turn.a[4])
            local B = lanePoint(turn.b[1], turn.b[2], turn.b[3], turn.b[4])
            if A ~= nil and B ~= nil then
                local c = turn.arc
                lay(A, arcPoints(c[1], c[2], c[3], c[4], c[5], c[6], c[7], A.y or 0, B.y or 0), B, turn.kind)
            end
        end
    end

    -- A T's side lanes may now run on past the turns towards the main road, to an end nothing uses:
    -- take those bits back to the first point a turn uses.
    if kind == "T" then
        local function tidy(w, back)
            for _ = 1, 30 do
                if w == nil or w.id == nil or ADGraphManager:getWayPointById(w.id) ~= w then return end
                local nout, nin = #(w.out or {}), #(w.incoming or {})
                local nextW = nil
                if back and nout == 0 and nin == 1 then
                    nextW = ADGraphManager:getWayPointById(w.incoming[1])
                elseif not back and nin == 0 and nout == 1 then
                    nextW = ADGraphManager:getWayPointById(w.out[1])
                else
                    return
                end
                jxRemove(w, "junction pattern unused lane end", true)
                w = nextW
            end
        end
        tidy(sideIn, true)
        tidy(sideOut, false)
    end
    ADFlyoverSettings.debugLog("[FlyoverEditor]: junction pattern (%s) placed: %s, lane gap %.1f m, centre %.1f, %.1f, %d turn piece(s).",
        shape, kind, L, ox, oz, turns)
    return { shape = shape, kind = kind, turns = turns, L = L, ox = ox, oz = oz, ux = ux, uz = uz }
end

local function junctionPlacePlain(cx, cz, dry)
    local unit = jxpUnit
    -- THE MAIN ROAD: the lane nearest the cursor that runs on past it, and its partner running the other
    -- way beside it. A lane that ends within 20 m of the cursor is a side road or a stub, never the main road.
    local function endsNear(l)
        for _, dir in ipairs({ "out", "incoming" }) do
            local prev, cur = (dir == "out") and l.a or l.b, (dir == "out") and l.b or l.a
            for _ = 1, 40 do
                if (cur.x - cx) ^ 2 + (cur.z - cz) ^ 2 > 20 * 20 then break end
                local nextW = nil
                for _, id in ipairs(cur[dir] or {}) do
                    local w = ADGraphManager:getWayPointById(id)
                    if w ~= nil and w ~= prev and nextW == nil then nextW = w end
                end
                if nextW == nil then return true end
                prev, cur = cur, nextW
            end
        end
        return false
    end
    -- Lanes that end near the cursor are a last resort: never refused (doc 08), so with nothing else
    -- the nearest lane serves.
    local best, bd = nil, 15
    for pass = 1, 2 do
    if best == nil then
    bd = 15
    for _, l in ipairs(jxpLinksNear(cx, cz, 30)) do
        local sx, sz = l.b.x - l.a.x, l.b.z - l.a.z
        local len2 = sx * sx + sz * sz
        if len2 > 1e-6 and (pass == 2 or not endsNear(l)) then
            local t = math.max(0, math.min(1, ((cx - l.a.x) * sx + (cz - l.a.z) * sz) / len2))
            local px, pz = l.a.x + t * sx, l.a.z + t * sz
            local d = math.sqrt((cx - px) ^ 2 + (cz - pz) ^ 2)
            if d < bd then best, bd = { l = l, px = px, pz = pz, y = (l.a.y or 0) + t * ((l.b.y or 0) - (l.a.y or 0)) }, d end
        end
    end
    end
    end
    if best == nil then return nil, "no road here to line a junction up with" end
    local dx, dz = unit(best.l.b.x - best.l.a.x, best.l.b.z - best.l.a.z)
    local rx, rz = -dz, dx                          -- right of the nearest lane
    local L, partner, pd = nil, false, nil
    for _, l in ipairs(jxpLinksNear(best.px, best.pz, 25)) do
        local lx, lz = unit(l.b.x - l.a.x, l.b.z - l.a.z)
        if lx * dx + lz * dz < -0.94 then
            -- Measured to the nearest point of that link, not its start: on a bending road the start can sit
            -- well round the bend and read short.
            local sx2, sz2 = l.b.x - l.a.x, l.b.z - l.a.z
            local len2 = math.max(1e-6, sx2 * sx2 + sz2 * sz2)
            local tt = math.max(0, math.min(1, ((best.px - l.a.x) * sx2 + (best.pz - l.a.z) * sz2) / len2))
            local qx, qz = l.a.x + tt * sx2, l.a.z + tt * sz2
            local off = (qx - best.px) * rx + (qz - best.pz) * rz
            local along = (qx - best.px) * dx + (qz - best.pz) * dz
            -- With right-hand traffic the lane the other way runs on the left (negative offset).
            -- The partner is the opposite lane NEAREST in a straight line: on a bending road a stretch further
            -- along can sit closer across but is not the lane beside this point.
            local dist = math.sqrt((qx - best.px) ^ 2 + (qz - best.pz) ^ 2)
            if off < -1.5 and off > -12 and math.abs(along) < 25 and (pd == nil or dist < pd) then
                L, partner, pd = -off, true, dist
            end
        end
    end
    L = L or 4
    if not dry then ADFlyoverSettings.debugLog("[FlyoverEditor]: junction plain - main lane %.1f, %.1f -> %.1f, %.1f (cursor %.1f m off), lane gap %.1f m%s.",
        best.l.a.x, best.l.a.z, best.l.b.x, best.l.b.z, bd, L, partner and "" or " (no partner)") end

    -- WHICH PIECE, and which way round: side-road lanes stopping near the cursor make it a T with its side
    -- road towards them; lanes crossing near it make an X; nothing else to go by, an X.
    local ends = {}
    for _, w in pairs(ADGraphManager:getWayPoints()) do
        if w ~= nil and w.id ~= nil and (w.x - cx) ^ 2 + (w.z - cz) ^ 2 <= 14 * 14 then
            -- A lane end: a point with only one neighbour (a two-way road's end has a link each way).
            local nb, n = {}, 0
            for _, id in ipairs(w.out or {}) do if not nb[id] then nb[id] = true n = n + 1 end end
            for _, id in ipairs(w.incoming or {}) do if not nb[id] then nb[id] = true n = n + 1 end end
            if n == 1 then ends[#ends + 1] = w end
        end
    end
    -- Lane ends on BOTH sides of the main road are a cross road the clear cut in two: an X.
    local kind, sx, sz = "X", nil, nil
    if #ends > 0 then
        local left, right = false, false
        sx, sz = 0, 0
        for _, w in ipairs(ends) do
            sx, sz = sx + w.x / #ends, sz + w.z / #ends
            local off = (w.x - best.px) * rx + (w.z - best.pz) * rz
            if off > 0.5 then right = true elseif off < -(L + 0.5) then left = true end
        end
        kind = (left and right) and "X" or "T"
    end
    -- The frame: +z (to the right of +x) points at the side road on a T. The nearest lane is the +x lane
    -- (at +0.5 L) when +x is its own direction, the -x lane (at -0.5 L) when +x runs against it.
    local ux, uz = dx, dz
    if kind == "T" then
        local side = (sx - best.px) * rx + (sz - best.pz) * rz
        -- Right of the nearest lane is away from its partner; if the side road is not that way, the
        -- nearest lane is the -x one.
        if side < 0 then ux, uz = -dx, -dz end
    end
    local vx, vz = -uz, ux
    local laneZ = (ux == dx and uz == dz) and 0.5 or -0.5
    local ox, oz = best.px - laneZ * L * vx, best.pz - laneZ * L * vz
    -- Along the road: the side road's middle on a T, else the cursor.
    local tx, tz = cx, cz
    if sx ~= nil then tx, tz = sx, sz end
    local along = (tx - ox) * ux + (tz - oz) * uz
    ox, oz = ox + along * ux, oz + along * uz
    -- SKEW: the side (or cross) road's own direction, from how its lanes run away from their ends. The
    -- piece's side arm leans to it (an X to 35 degrees off square, a T to 50); past that it stays square.
    local s2x, s2z = vx, vz
    if sx ~= nil then
        local ax, az, n = 0, 0, 0
        for _, w in ipairs(ends) do
            local nbId = (w.out ~= nil and w.out[1]) or (w.incoming ~= nil and w.incoming[1]) or nil
            local nb = nbId ~= nil and ADGraphManager:getWayPointById(nbId) or nil
            if nb ~= nil then
                local ex, ez = unit(nb.x - w.x, nb.z - w.z)      -- away from the main road
                -- Ends across the road (an X cut in two) run the other way: fold them onto +z. An end running
                -- along the main road (a stray) says nothing about the side road's angle: left out.
                if ex * vx + ez * vz < 0 then ex, ez = -ex, -ez end
                if ex * vx + ez * vz >= 0.5 then ax, az, n = ax + ex, az + ez, n + 1 end
            end
        end
        if n > 0 then
            local mx2, mz2 = unit(ax, az)
            -- As far as the mod's shape stays drivable: an X to 35 degrees off square, a T to 50.
            if mx2 * vx + mz2 * vz >= ((kind == "X") and 0.819 or 0.643) then s2x, s2z = mx2, mz2 end
        end
        -- The centre: where the side road's middle line meets the main road's.
        local c = s2x * vx + s2z * vz
        local t = ((ox - sx) * vx + (oz - sz) * vz) / c
        ox, oz = sx + t * s2x, sz + t * s2z
    end
    local cosS = s2x * vx + s2z * vz
    local e1x, e1z = L * ux, L * uz
    local e2x, e2z = L * s2x / cosS, L * s2z / cosS
    local function W(mx, mz) return ox + mx * e1x + mz * e2x, oz + mx * e1z + mz * e2z end
    local function D(mx, mz) return unit(mx * e1x + mz * e2x, mx * e1z + mz * e2z) end
    -- The corner cuts a quarter lane gap from each corner in METRES along each lane, so on a leaning
    -- piece the two bends of a cut stay equal (as in the fitted pattern's cutAt).
    local f1 = 0.25 * L / math.sqrt(e1x * e1x + e1z * e1z)
    local f2 = 0.25 * L / math.sqrt(e2x * e2x + e2z * e2z)
    local nodePos = {}
    for n, p in pairs(JX_PLAIN[kind].nodes) do nodePos[n] = p end
    local cuts = (kind == "X") and { [0] = { 3, 5 }, [1] = { 18, 20 }, [2] = { 13, 15 }, [3] = { 8, 10 } }
        or { [0] = { 3, 5 }, [3] = { 8, 10 } }
    for k, pair in pairs(cuts) do
        local fa, fb = f1, f2
        if k % 2 == 1 then fa, fb = f2, f1 end
        local ax, az, bx, bz = -0.5 - fa, 0.5, -0.5, 0.5 + fb
        for _ = 1, k do ax, az = -az, ax bx, bz = -bz, bx end
        nodePos[pair[1]], nodePos[pair[2]] = { ax, az }, { bx, bz }
    end
    local function roles(p)
        local r = {}
        if math.abs(p[2] - 0.5) < 1e-6 then r[#r + 1] = { 1, 0 } end
        if math.abs(p[2] + 0.5) < 1e-6 then r[#r + 1] = { -1, 0 } end
        if math.abs(p[1] + 0.5) < 1e-6 then r[#r + 1] = { 0, 1 } end
        if math.abs(p[1] - 0.5) < 1e-6 then r[#r + 1] = { 0, -1 } end
        return r
    end
    local piece = JX_PLAIN[kind]
    local ids = {}
    for n in pairs(piece.nodes) do ids[#ids + 1] = n end
    table.sort(ids)

    -- What would join and what would be left loose, worked out the same way dry or not.
    local loose = {}
    local function isArmEnd(p) return math.abs(p[1]) > 1.4 or math.abs(p[2]) > 1.4 end
    -- A TWO-WAY SIDE ROAD ending by the side arms (in game j66): its end takes both of them, lane out ->
    -- road end -> lane in, so they aren't left loose.
    local twoWayEnd = nil
    if kind == "T" then
        local mx0, mz0 = W(0, 1.5)
        local bd2 = (2 * L + 2) ^ 2
        for _, w in ipairs(ends) do
            local only = w.out ~= nil and w.out[1] or nil
            if only ~= nil and #w.out == 1 and #(w.incoming or {}) == 1 and w.incoming[1] == only then
                local d = (w.x - mx0) ^ 2 + (w.z - mz0) ^ 2
                if d < bd2 then twoWayEnd, bd2 = w, d end
            end
        end
    end
    -- Only where AutoDrive can drive it: every bend on lane out -> road end and road end -> lane in under
    -- 80 degrees. A road meeting far off square (j66, a Y) would double back; its arms stay loose instead.
    if twoWayEnd ~= nil then
        local function bend(ax, az, bx, bz)
            local n1, n2 = math.sqrt(ax * ax + az * az), math.sqrt(bx * bx + bz * bz)
            if n1 < 1e-6 or n2 < 1e-6 then return 180 end
            return math.deg(math.acos(math.max(-1, math.min(1, (ax * bx + az * bz) / (n1 * n2)))))
        end
        local nb = ADGraphManager:getWayPointById(twoWayEnd.out[1])
        local p5x, p5z = W(nodePos[5][1], nodePos[5][2])
        local p6x, p6z = W(nodePos[6][1], nodePos[6][2])
        local p7x, p7z = W(nodePos[7][1], nodePos[7][2])
        local p8x, p8z = W(nodePos[8][1], nodePos[8][2])
        local wx, wz = twoWayEnd.x, twoWayEnd.z
        local ok = nb ~= nil
            and bend(p6x - p5x, p6z - p5z, wx - p6x, wz - p6z) < 80              -- out arm into the join
            and bend(wx - p6x, wz - p6z, nb.x - wx, nb.z - wz) < 80              -- join onto the road
            and bend(wx - nb.x, wz - nb.z, p7x - wx, p7z - wz) < 80              -- road into the join
            and bend(p7x - wx, p7z - wz, p8x - p7x, p8z - p7z) < 80              -- join into the in arm
        if not ok then twoWayEnd = nil end
    end
    if dry then
        for _, n in ipairs(ids) do
            local p = nodePos[n]
            local joined = false
            for _, r in ipairs(roles(p)) do
                local px, pz = W(p[1], p[2])
                local ddx, ddz = D(r[1], r[2])
                if jxpOnLane(px, pz, ddx, ddz, nil, true) then joined = true end
            end
            if not joined and isArmEnd(p) then
                local px, pz = W(p[1], p[2])
                loose[#loose + 1] = { x = px, z = pz, n = n }
            end
        end
        local lines = {}
        local l6, l7 = nil, nil
        for i, e in ipairs(loose) do if e.n == 6 then l6 = i elseif e.n == 7 then l7 = i end end
        if twoWayEnd ~= nil and l6 ~= nil and l7 ~= nil then
            local a6, a7 = loose[l6], loose[l7]
            lines[#lines + 1] = { pts = { { x = a6.x, z = a6.z }, { x = twoWayEnd.x, z = twoWayEnd.z } } }
            lines[#lines + 1] = { pts = { { x = twoWayEnd.x, z = twoWayEnd.z }, { x = a7.x, z = a7.z } } }
            table.remove(loose, math.max(l6, l7))
            table.remove(loose, math.min(l6, l7))
        end
        local set = {}
        for _, l in ipairs(piece.links) do set[l[1] .. ">" .. l[2]] = true end
        for _, l in ipairs(piece.links) do
            local dual = set[l[2] .. ">" .. l[1]] == true
            if not (dual and l[1] > l[2]) then
                local a, b = nodePos[l[1]], nodePos[l[2]]
                local ax, az = W(a[1], a[2])
                local bx, bz = W(b[1], b[2])
                lines[#lines + 1] = { pts = { { x = ax, z = az }, { x = bx, z = bz } }, dual = dual }
            end
        end
        return { shape = "plain", kind = kind, L = L, ox = ox, oz = oz, ux = ux, uz = uz, turns = 0,
                 loose = loose, partner = partner, lines = lines, marks = {} }
    end

    local node, onRole = {}, {}
    for _, n in ipairs(ids) do
        local p = nodePos[n]
        local px, pz = W(p[1], p[2])
        onRole[n] = {}
        for _, r in ipairs(roles(p)) do
            local ddx, ddz = D(r[1], r[2])
            local key = r[1] .. "," .. r[2]
            if node[n] == nil then
                local N = jxpOnLane(px, pz, ddx, ddz)
                if N ~= nil then node[n], onRole[n][key] = N, true end
            elseif jxpOnLane(px, pz, ddx, ddz, node[n]) ~= nil then
                onRole[n][key] = true
            end
        end
        if node[n] == nil then
            jxState.jxLayLabel = "plain"
            local N = ADFlyoverRecordWayPoint(px, jxpGroundY(px, pz, best.y), pz, false, false, false, 0,
                best.l.a.flags or AutoDrive.FLAG_NONE, false)
            jxNoteAdded(N)
            jxState.jxLayLabel = nil
            if N == nil then return nil, "could not add a point of the piece" end
            node[n] = N
            if isArmEnd(p) then loose[#loose + 1] = { x = px, z = pz, node = N, n = n } end
        end
    end
    local set = {}
    for _, l in ipairs(piece.links) do set[l[1] .. ">" .. l[2]] = true end
    local laid = 0
    for _, l in ipairs(piece.links) do
        local a, b = l[1], l[2]
        local dual = set[b .. ">" .. a] == true
        local onSameLane = false
        for k in pairs(onRole[a]) do if onRole[b][k] then onSameLane = true end end
        if not onSameLane and not (dual and a > b) and node[a] ~= node[b] then
            jxState.jxLaySeq = jxState.jxLaySeq + 1
            jxState.jxLayLabel = "plain#" .. jxState.jxLaySeq
            junctionConnect(node[a], node[b], dual)
            jxState.jxLayLabel = nil
            laid = laid + 1
        end
    end
    do
        local l6, l7 = nil, nil
        for i, e in ipairs(loose) do if e.n == 6 then l6 = i elseif e.n == 7 then l7 = i end end
        if twoWayEnd ~= nil and l6 ~= nil and l7 ~= nil then
            jxState.jxLaySeq = jxState.jxLaySeq + 1
            jxState.jxLayLabel = "plain#" .. jxState.jxLaySeq
            junctionConnect(node[6], twoWayEnd, false)
            junctionConnect(twoWayEnd, node[7], false)
            jxState.jxLayLabel = nil
            laid = laid + 2
            table.remove(loose, math.max(l6, l7))
            table.remove(loose, math.min(l6, l7))
            ADFlyoverSettings.debugLog("[FlyoverEditor]: junction plain - side arms joined to the two-way road's end at %.1f, %.1f.",
                twoWayEnd.x, twoWayEnd.z)
        end
    end
    ADFlyoverSettings.debugLog("[FlyoverEditor]: junction plain %s placed: lane gap %.1f m%s, centre %.1f, %.1f, %d link(s), %d loose end(s).",
        kind, L, partner and "" or " (no second lane found, 4 m used)", ox, oz, laid, #loose)
    for _, e in ipairs(loose) do
        ADFlyoverSettings.debugLog("[FlyoverEditor]:   loose end at %.1f, %.1f - join it by hand.", e.x, e.z)
    end
    return { shape = "plain", kind = kind, L = L, ox = ox, oz = oz, ux = ux, uz = uz, turns = laid,
             loose = loose, partner = partner }
end

-- PLACE (doc 08): the pattern fitted to the crossing where it fits, the plain piece everywhere else.
-- Only turn wiring still there, or no road at all, stops it.
local function junctionPlacePattern(cx, cz, reach, shape, dry)
    -- TWO-WAY ROADS ARE TABLED (decided 2026-10-05): a junction where any road running both ways meets is
    -- refused, fitted or plain, until there has been time to research how they should join. The two-way
    -- side road code below (twoWaySide in the fitted T, twoWayEnd in the plain piece) stays, switched off;
    -- FLYOVER_JUNCTION_PLACE_TWO_WAY = true brings it back.
    if AutoDrive.FLYOVER_JUNCTION_PLACE_TWO_WAY ~= true then
        for _, a in pairs(ADGraphManager:getWayPoints()) do
            if a ~= nil and a.id ~= nil and (a.x - cx) ^ 2 + (a.z - cz) ^ 2 <= 14 * 14 then
                for _, bid in ipairs(a.out or {}) do
                    local b = ADGraphManager:getWayPointById(bid)
                    if b ~= nil and table.contains(b.out or {}, a.id) then
                        return nil, "a two-way road meets here - two-way roads aren't handled yet"
                    end
                end
            end
        end
    end
    local res, why, wired = nil, "forced plain (test switch)", nil
    -- Test switch (harness): always the plain piece, without trying the fit at all.
    if AutoDrive.FLYOVER_JUNCTION_PLACE_FORCE_PLAIN ~= true then
        res, why, wired = junctionPlaceFitted(cx, cz, reach, shape, dry)
    end
    if res ~= nil or wired then return res, why, wired end
    local p, pwhy = junctionPlacePlain(cx, cz, dry)
    if p == nil then return nil, pwhy end
    p.fitWhy = why
    return p
end


-- THE ROUTE CHECK (docs/junction-tool/06-one-click-build.md, layout rule 7). A shared point lets
-- AutoDrive switch from one path to another wherever the bend there is 80 degrees or less
-- (GraphManager.prepareWayPoints), so two paths crossing at a shallow angle can open a route nobody
-- laid - a U-turn among them. From every lane in, this follows every route AutoDrive could take under
-- that rule until it reaches a lane out, and compares each lane-in/lane-out pair it finds with the
-- turns meant to be there: movements that already existed, and those this build laid. Anything else -
-- a pair skipped as a U-turn, refused as undrivable, or never asked for - is an extra route, but only
-- when it runs over at least one link this build laid: a route the roads already offered is not the
-- build's doing.
-- Returns { routes = <pairs found>, extra = { { from = <in node>, to = <out node>, why = ... } } }.
local function junctionRouteCheck(jp, placedSet, cx, cz, reach)
    local ins, outAt = {}, {}
    local function alive(w) return w ~= nil and w.id ~= nil and ADGraphManager:getWayPointById(w.id) == w end
    for _, ap in ipairs(jp.approaches or {}) do
        if alive(ap.wp) then
            if ap.dir == "in" then ins[#ins + 1] = ap else outAt[ap.wp] = true end
        end
    end
    -- What is meant: every movement that existed, and every one this build laid, by its two nodes.
    local meant, why = {}, {}
    local function key(a, b) return tostring(a) .. ">" .. tostring(b) end
    for _, m in ipairs(jp.movements or {}) do
        local k = key(m.from.wp, m.to.wp)
        -- "lane": skipped only because a closer lane makes the same turn - driving it is the same turn.
        -- "far": the two lanes belong to two separate crossings in one scope - a route between them runs
        -- through both junctions, and is neither junction's turn to judge.
        if m.exists or placedSet[m] or m.refused == "lane" or m.refused == "far" then
            meant[k] = true
        elseif why[k] == nil then
            why[k] = (m.refused ~= nil) and ("refused: " .. tostring(m.refused)) or "planned but not laid"
        end
    end
    local R2 = (reach + 10) ^ 2
    local function inRegion(w) return (w.x - cx) ^ 2 + (w.z - cz) ^ 2 <= R2 or outAt[w] ~= nil end
    local function bend(a, b, c)
        local ux, uz, vx, vz = b.x - a.x, b.z - a.z, c.x - b.x, c.z - b.z
        local nu, nv = math.sqrt(ux * ux + uz * uz), math.sqrt(vx * vx + vz * vz)
        if nu < 1e-6 or nv < 1e-6 then return 0 end
        return math.deg(math.acos(math.max(-1, math.min(1, (ux * vx + uz * vz) / (nu * nv)))))
    end
    local found, nRoutes, extra = {}, 0, {}
    for _, e in ipairs(ins) do
        local start = e.wp
        -- Seeded from every link into the lane's first point, so its first bend is judged too.
        local stack, seen = {}, {}
        for _, pid in ipairs(start.incoming or {}) do
            local p = ADGraphManager:getWayPointById(pid)
            if p ~= nil then stack[#stack + 1] = { p, start, false, { start } } end
        end
        if #stack == 0 then stack[1] = { nil, start, false, { start } } end
        while #stack > 0 do
            local top = table.remove(stack)
            local prev, cur, usedNew, path = top[1], top[2], top[3], top[4]
            local sk = tostring(prev) .. ">" .. tostring(cur) .. (usedNew and "+" or "")
            if not seen[sk] then
                seen[sk] = true
                if cur ~= start and outAt[cur] then
                    local k = key(start, cur)
                    if not found[k] then
                        found[k] = true
                        nRoutes = nRoutes + 1
                    end
                    if not meant[k] and usedNew and not found["x" .. k] then
                        found["x" .. k] = true
                        extra[#extra + 1] = { from = start, to = cur, why = why[k] or "no such turn was planned", path = path }
                    end
                else
                    for _, nid in ipairs(cur.out or {}) do
                        local nx = ADGraphManager:getWayPointById(nid)
                        if nx ~= nil and nx ~= prev and inRegion(nx)
                            and (prev == nil or bend(prev, cur, nx) <= 80) then
                            local np = {}
                            for i = 1, #path do np[i] = path[i] end
                            np[#np + 1] = nx
                            stack[#stack + 1] = { cur, nx, usedNew or jxIsNewLink(cur, nx), np }
                        end
                    end
                end
            end
        end
    end
    -- In a fixed order, so the log reads the same every run.
    table.sort(extra, function(p, q)
        if p.from.x ~= q.from.x then return p.from.x < q.from.x end
        if p.from.z ~= q.from.z then return p.from.z < q.from.z end
        if p.to.x ~= q.to.x then return p.to.x < q.to.x end
        return p.to.z < q.to.z
    end)
    -- And the other way round: a turn this build laid that no route can actually drive (a piece that
    -- did not join, or a bend over 80 degrees on the way).
    local missing = {}
    for _, m in ipairs(jp.movements or {}) do
        if placedSet[m] and alive(m.from.wp) and alive(m.to.wp) then
            local k = key(m.from.wp, m.to.wp)
            if not found[k] and not found["m" .. k] then
                found["m" .. k] = true
                missing[#missing + 1] = { from = m.from.wp, to = m.to.wp }
            end
        end
    end
    return { routes = nRoutes, extra = extra, missing = missing }
end

-- How far a fork may sit from the middle of its group and still belong to it, for the SELECTION's
-- fork clusters. Named, and up here, because the registry below has to hold lane ends away from
-- exactly the same clusters the selection does: two copies of a 12 would drift apart the first time
-- one of them was tuned, and the two would then disagree about which lane ends are loose.
local JUNCTION_FORK_LINK = 12

-- Group points by CENTROID linkage: a point joins a group while it lies within `link` of the
-- group's running middle, and the group is swept again whenever it grows, because its middle has
-- moved. Returns { x, z, nodes } per group, in the order their first members were met - so the
-- same list in the same order always comes back as the same groups.
local function junctionCentroidClusters(list, link)
    local used, out = {}, {}
    for i = 1, #list do
        if not used[i] then
            used[i] = true
            local grp, sx, sz, grew = { list[i] }, list[i].x, list[i].z, true
            while grew do
                grew = false
                for j = 1, #list do
                    if not used[j] then
                        local mx, mz = sx / #grp, sz / #grp
                        if (list[j].x - mx) ^ 2 + (list[j].z - mz) ^ 2 <= link * link then
                            used[j] = true
                            grp[#grp + 1] = list[j]
                            sx, sz, grew = sx + list[j].x, sz + list[j].z, true
                        end
                    end
                end
            end
            out[#out + 1] = { x = sx / #grp, z = sz / #grp, nodes = grp }
        end
    end
    return out
end

-- MODSPLIT: SHARED WITH THE FILES LOADED AFTER THIS ONE (tools/modsplit/split.py writes this block)
ADFlyoverEditor.shared.JUNCTION_FORK_LINK = JUNCTION_FORK_LINK
ADFlyoverEditor.shared.junctionCentroidClusters = junctionCentroidClusters
ADFlyoverEditor.shared.junctionPlacePattern = junctionPlacePattern
ADFlyoverEditor.shared.junctionRouteCheck = junctionRouteCheck
ADFlyoverEditor.shared.junctionShareCrossings = junctionShareCrossings
ADFlyoverEditor.shared.jxpUnit = jxpUnit
-- MODSPLIT: end of the shared block

-- ONE PART OF A SPLIT JUNCTION, THEN ITS TWIN: does the first clear leave the twin's turns working?
-- (the user's split-junction rules of 2026-10-03, doc 04). Clears part A, then part B, and follows each
-- of B's turns end to end after each clear - B's turns as B's own clear reads its turn wiring on the
-- fresh network (its preview with through roads kept), each one ending where it first merges into
-- another way. Independent of the clear's own record of B's turns (junctionTwinTurns) and of the
-- check: it only walks the network.
--   LEAVE=1|0 A=ax,az B=bx,bz [TURNR=12] [DUMP=prefix] lua dbgtwin.lua
-- Prints B's turns, then for each stage (BEFORE, AFTER_A, AFTER_B):
--   <stage> TURN i <state> from (x,z) to (x,z) len=.. in=<m back, or far> out=<m on, or far> why
-- state: drives (a way onto it and off it, each running 60 m or more), fromcut / tocut (whole, but
-- its way in starts - or its way on ends - within 60 m: the stub a clear with through roads off
-- leaves), broken (its start gone, or no drive from its start to its end along where it ran: points
-- the respacing slid along a lane are found by the link running over their old place), nowayin /
-- nowayout (whole, but nothing leads onto it, or it leads nowhere). Also each clear's check lines,
-- card and counts, and with DUMP the network around both parts at each stage (DUMP_0before.txt ...).
-- After A's clear, what A's check says of each of B's turns:
--   AFTER_A SAID i <state> joins=<why,...> dots=<why,...> problem=yes|no wait=yes|no [MISMATCH <what>]
-- every join whose drive runs over the turn's first link, every teal dot on one of its points, and
-- whether a problem line (kind "twin") is about the turn (every point of it lies on the turn the
-- line names: two turns can share their first stretch). MISMATCH, for a turn that drives: a join or dot over it said as anything that
-- reports a fault (missed, made, the end of a cut turn, not drivable now...; "left working", "next
-- part's wiring" and the like are fine), or a problem line for it. For a turn that does not drive:
-- one called "left working". A teal dot two of B's turns share is fine when it fits either of them
-- (at 26 one of 26n's turns drives, the other only from 26s's cut lane, and both end at one dot).
-- A "waits for the build" note (kind "twinwait", the user's call of 2026-10-05) is the check's word on a
-- turn that is whole but hangs off A's cut lane (fromcut, tocut): said, not a fault. Said of a turn
-- that drives, or of one that is broken or has no way in or out, it is a MISMATCH.
-- UNSAID: a turn that does not drive, with no problem line, no waiting note and nothing over it said as a fault -
-- counted apart, with how far its nearest point lies from A's saved point (near=): the check
-- follows only the other part's turns in A's own area (the user's rule 1), and a turn further out
-- that hangs off the road between the two, cut by A with through roads off, is not one of them.
-- regtwin.sh runs it over every ordered pair of parts in split_decisions.txt.
LOG_ECHO = false
local H = dofile("harness.lua")
local lv = (os.getenv("LEAVE") == "1")
local function xy(s) local a, b = s:match("(%S+),(%S+)") return tonumber(a), tonumber(b) end
local ax, az = xy(os.getenv("A"))
local bx, bz = xy(os.getenv("B"))
local DUMP = os.getenv("DUMP")
local FAR = tonumber(os.getenv("FAR") or "") or 60
local TURNR = tonumber(os.getenv("TURNR") or "") or 12

local function key(w) return string.format("%.2f %.2f", w.x, w.z) end
local function findAt(p, tol)
    tol = tol or 0.05
    local best, bd = nil, tol * tol
    for _, w in ipairs(ADGraphManager:getWayPoints()) do
        local d = (w.x - p.x) ^ 2 + (w.z - p.z) ^ 2
        if d <= bd then bd, best = d, w end
    end
    return best
end
local function linked(a, b)
    for _, id in ipairs(a.out or {}) do if id == b.id then return true end end
    return false
end
local function node(id) return ADGraphManager:getWayPointById(id) end
local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2) end

-- B's turn movements, read off B's own preview on the fresh network (through roads kept, so only its
-- turn wiring is listed).
local movements = {}
local movesSeen = {}
do
    local jb = H.lock(bx, bz, { mode = "clear", radius = 12, leaveThrough = true, turnRadius = TURNR })
    if jb == nil then
        print("B REFUSED " .. tostring(ADFlyoverEditor.junctionRefused))
        return
    end
    print("B NAME " .. tostring(jb.junctionName))
    local isT = {}
    for _, w in ipairs(jb.turnDebris or {}) do isT[w] = true end
    local seen = {}
    local list = {}
    for w in pairs(isT) do list[#list + 1] = w end
    table.sort(list, function(p, q) if p.x ~= q.x then return p.x < q.x end return p.z < q.z end)
    for _, w0 in ipairs(list) do
        if not seen[w0] then
            local piece, stack = {}, { w0 }
            seen[w0] = true
            while #stack > 0 do
                local c = table.remove(stack)
                piece[c] = true
                for _, lst in ipairs({ c.out or {}, c.incoming or {} }) do
                    for _, id in ipairs(lst) do
                        local o = node(id)
                        if o ~= nil and isT[o] and not seen[o] then seen[o] = true stack[#stack + 1] = o end
                    end
                end
            end
            -- entries: road point u -> piece point v; exits: piece point -> road point t
            local entries = {}
            for c in pairs(piece) do
                for _, id in ipairs(c.incoming or {}) do
                    local u = node(id)
                    if u ~= nil and not piece[u] then entries[#entries + 1] = { u = u, v = c } end
                end
            end
            table.sort(entries, function(p, q) return key(p.u) .. key(p.v) < key(q.u) .. key(q.v) end)
            for _, e in ipairs(entries) do
                -- BFS inside the piece to every exit
                local par, q, h = { [e.v] = false }, { e.v }, 1
                local exits = {}
                while h <= #q do
                    local c = q[h]; h = h + 1
                    for _, id in ipairs(c.out or {}) do
                        local t = node(id)
                        if t ~= nil and t ~= c then
                            if piece[t] then
                                if par[t] == nil then par[t] = c q[#q + 1] = t end
                            else
                                exits[#exits + 1] = { c = c, t = t }
                            end
                        end
                    end
                end
                table.sort(exits, function(p, q2) return key(p.t) .. key(p.c) < key(q2.t) .. key(q2.c) end)
                for _, x in ipairs(exits) do
                    local path, c = { x.t }, x.c
                    while c do table.insert(path, 1, c) c = par[c] end
                    table.insert(path, 1, e.u)
                    -- A turn ends where it first merges into another way (two ways in): past that it
                    -- runs along a road (40w's preview reads 15 m of the main road as its turn wiring).
                    local cutAt = #path
                    for k = 2, #path do
                        local seenIn, nIn = {}, 0
                        for _, id in ipairs(path[k].incoming or {}) do
                            if not seenIn[id] then seenIn[id] = true nIn = nIn + 1 end
                        end
                        if nIn >= 2 then cutAt = k break end
                    end
                    local pts = {}
                    for k = 1, cutAt do pts[#pts + 1] = { x = path[k].x, z = path[k].z } end
                    local key0 = string.format("%.2f,%.2f>%.2f,%.2f", pts[1].x, pts[1].z, pts[#pts].x, pts[#pts].z)
                    if not movesSeen[key0] then
                        movesSeen[key0] = true
                        movements[#movements + 1] = pts
                    end
                end
            end
        end
    end
    -- direct links between two of B's lanes (no point in between)
    for _, pr in ipairs(jb.staleLinks or {}) do
        if not pr.isThrough and pr[1] ~= nil and pr[2] ~= nil then
            movements[#movements + 1] = { { x = pr[1].x, z = pr[1].z }, { x = pr[2].x, z = pr[2].z } }
        end
    end
end
print(string.format("B TURNS %d", #movements))

-- A turn's way in: how far back a vehicle can come to its first point, and whether from far away.
local function reachBack(w, skip)
    local best, open, far = { [w] = 0 }, { w }, false
    local maxd = 0
    while #open > 0 do
        local c = table.remove(open, 1)
        for _, id in ipairs(c.incoming or {}) do
            local f = node(id)
            if f ~= nil and f ~= c and not skip[f] then
                local d = best[c] + dist(f, c)
                if best[f] == nil or d < best[f] then
                    best[f] = d
                    if d > maxd then maxd = d end
                    if d >= FAR then far = true else open[#open + 1] = f end
                end
            end
        end
        if far then break end
    end
    return far, maxd
end
local function reachOn(w, skip)
    local best, open, far = { [w] = 0 }, { w }, false
    local maxd = 0
    while #open > 0 do
        local c = table.remove(open, 1)
        for _, id in ipairs(c.out or {}) do
            local t = node(id)
            if t ~= nil and t ~= c and not skip[t] then
                local d = best[c] + dist(c, t)
                if best[t] == nil or d < best[t] then
                    best[t] = d
                    if d > maxd then maxd = d end
                    if d >= FAR then far = true else open[#open + 1] = t end
                end
            end
        end
        if far then break end
    end
    return far, maxd
end

local lastJudge = {}
local function judge(stage)
    lastJudge = {}
    for i, m in ipairs(movements) do
        local state, why = nil, ""
        local len = 0
        for k = 2, #m do len = len + dist(m[k - 1], m[k]) end
        local inF, inD, outF, outD = false, 0, false, 0
        -- Whole: a drive from its first point to its last, along links, every point of it within
        -- 2 m of the turn as it was (respacing may move points; forks never move).
        -- A point that the respacing slid along its lane is found by the link now running over its
        -- old place (within 0.75 m): the drive starts at that link's far end, and is through once a
        -- link it takes passes within 0.75 m of where the turn ended.
        local function segD(px, pz, a, b)
            local vx, vz = b.x - a.x, b.z - a.z
            local L2 = vx * vx + vz * vz
            local t = 0
            if L2 > 1e-9 then t = math.max(0, math.min(1, ((px - a.x) * vx + (pz - a.z) * vz) / L2)) end
            return math.sqrt((px - a.x - vx * t) ^ 2 + (pz - a.z - vz * t) ^ 2)
        end
        local E = findAt(m[1], 0.5)
        local Ein = nil
        if E == nil then
            for _, w in ipairs(ADGraphManager:getWayPoints()) do
                if (w.x - m[1].x) ^ 2 + (w.z - m[1].z) ^ 2 < 100 then
                    for _, id in ipairs(w.out or {}) do
                        local t = node(id)
                        if t ~= nil and segD(m[1].x, m[1].z, w, t) <= 0.75 then E, Ein = t, w end
                    end
                end
            end
        end
        local X = nil
        local function nearLine(w)
            local best = math.huge
            for k = 2, #m do
                local d = segD(w.x, w.z, m[k - 1], m[k])
                if d < best then best = d end
            end
            return best <= 2
        end
        local interior = {}
        if E == nil then
            state, why = "broken", string.format("its start (%.1f,%.1f) is gone", m[1].x, m[1].z)
        else
            local par, q, h = { [E] = false }, { E }, 1
            local xe = m[#m]
            if (E.x - xe.x) ^ 2 + (E.z - xe.z) ^ 2 <= 0.25 then X = E end
            while h <= #q and X == nil do
                local c = q[h]; h = h + 1
                for _, id in ipairs(c.out or {}) do
                    local t = node(id)
                    if t ~= nil and t ~= c and par[t] == nil then
                        if segD(xe.x, xe.z, c, t) <= 0.75 then par[t] = c X = t break end
                        if nearLine(t) then par[t] = c q[#q + 1] = t end
                    end
                end
            end
            if X == nil then
                state, why = "broken", "cut part-way along, or its end is gone"
            else
                local c = par[X]
                while c and c ~= E do interior[c] = true c = par[c] end
            end
        end
        if state == nil then
            local skip = interior
            inF, inD = reachBack(E, skip)
            outF, outD = reachOn(X, skip)
            if inD == 0 then state, why = "nowayin", "its first point has no way in"
            elseif outD == 0 then state, why = "nowayout", "its last point has no way on"
            elseif inF and outF then state = "drives"
            elseif not inF then state, why = "fromcut", string.format("fed from %.1f m back only", inD)
            else state, why = "tocut", string.format("leads on %.1f m only", outD) end
        end
        lastJudge[i] = state
        print(string.format("%s TURN %d %s from (%.1f,%.1f) to (%.1f,%.1f) len=%.1f in=%s out=%s %s", stage, i, state,
            m[1].x, m[1].z, m[#m].x, m[#m].z, len, inF and "far" or string.format("%.1f", inD),
            outF and "far" or string.format("%.1f", outD), why))
    end
end

local function dump(tag)
    if DUMP == nil then return end
    local f = assert(io.open(DUMP .. "_" .. tag .. ".txt", "w"))
    local cx, cz = (ax + bx) / 2, (az + bz) / 2
    for _, w in ipairs(ADGraphManager:getWayPoints()) do
        if (w.x - cx) ^ 2 + (w.z - cz) ^ 2 <= 80 * 80 then
            local outs = {}
            for _, id in ipairs(w.out or {}) do
                local o = node(id)
                if o then outs[#outs + 1] = string.format("%.2f,%.2f", o.x, o.z) end
            end
            f:write(string.format("N %.2f %.2f %d %d %s\n", w.x, w.z, #(w.incoming or {}), #(w.out or {}), table.concat(outs, ";")))
        end
    end
    for i, m in ipairs(movements) do
        local pts = {}
        for _, p in ipairs(m) do pts[#pts + 1] = string.format("%.2f,%.2f", p.x, p.z) end
        f:write(string.format("T %d %s %s\n", i, tostring(lastJudge[i]), table.concat(pts, ";")))
    end
    local r = ADFlyoverEditor.junctionLastCheck
    if r ~= nil and tag ~= "0before" then
        for _, c in ipairs(r.card or {}) do f:write("CARD " .. c .. "\n") end
    end
    f:write(string.format("PARTS %.2f %.2f %.2f %.2f\n", ax, az, bx, bz))
    f:close()
end

local function check(stage)
    local r = ADFlyoverEditor.junctionLastCheck
    if r == nil then print(stage .. " NOCHECK") return end
    for _, c in ipairs(r.card or {}) do print(stage .. " CARD " .. c) end
    if r.joins == nil then return end
    local function tally(list, field)
        local by, keys = {}, {}
        for _, it in ipairs(list) do
            local k = it[field] or "?"
            if by[k] == nil then keys[#keys + 1] = k end
            by[k] = (by[k] or 0) + 1
        end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do parts[#parts + 1] = string.format("%s:%d", k, by[k]) end
        return string.format("%d%s", #list, (#parts > 0) and (" " .. table.concat(parts, " ")) or "")
    end
    print(string.format("%s COUNTS joins %s | dots %s | other %s", stage,
        tally(r.joins or {}, "why"), tally(r.dots or {}, "why"), tally(r.issues or {}, "kind")))
end

local function logLines(stage, log)
    local errs = 0
    for _, line in ipairs(log or {}) do
        if line:find("junction %- check") then print(stage .. " LOG " .. line:gsub("^%[FlyoverEditor%]: junction %- ", "")) end
        if line:find("attempt to") or line:find("stack traceback") or line:find("check[^:]* failed") then errs = errs + 1 end
    end
    print(stage .. " ERRORS " .. errs)
end

judge("BEFORE")
dump("0before")
-- A
local ja = H.lock(ax, az, { mode = "clear", radius = 12, leaveThrough = lv, turnRadius = TURNR })
if ja == nil then
    print("A REFUSED " .. tostring(ADFlyoverEditor.junctionRefused))
    return
end
print("A NAME " .. tostring(ja.junctionName))
ADFlyoverEditor.junctionLastCheck = nil
local ok, log = pcall(H.apply)
if not ok then print("A STOPPED " .. tostring(log)) log = LOG end
logLines("A", log)
check("A")
judge("AFTER_A")
do
    local r = ADFlyoverEditor.junctionLastCheck
    local function near(p, q) return (p.x - q.x) ^ 2 + (p.z - q.z) ^ 2 <= 0.3 * 0.3 end
    -- reasons that report a fault, and those that do not
    local FINE = { twin = true, part = true, through = true, oneroad = true, selfjoin = true, crossing = true }
    local function onTurn(m, d)
        for _, p in ipairs(m) do if near(p, d) then return true end end
        return false
    end
    for i, m in ipairs(movements) do
        local js, ds, bad = {}, {}, {}
        local faultSaid = false
        for _, j in ipairs((r and r.joins) or {}) do
            local h1, h2 = false, false
            for _, p in ipairs(j.path or {}) do
                if near(p, m[1]) then h1 = true end
                if m[2] ~= nil and near(p, m[2]) then h2 = true end
            end
            if h1 and h2 then js[#js + 1] = j.why end
        end
        local dotsOn = {}
        for _, d in ipairs((r and r.dots) or {}) do
            if onTurn(m, d) then ds[#ds + 1] = d.why dotsOn[#dotsOn + 1] = d end
        end
        local problem, waitNote = false, false
        local function onLine(pts, p)
            for k = 2, #(pts or {}) do
                local a, b = pts[k - 1], pts[k]
                local vx, vz = b.x - a.x, b.z - a.z
                local L2 = vx * vx + vz * vz
                local t = 0
                if L2 > 1e-9 then t = math.max(0, math.min(1, ((p.x - a.x) * vx + (p.z - a.z) * vz) / L2)) end
                if (p.x - a.x - vx * t) ^ 2 + (p.z - a.z - vz * t) ^ 2 <= 0.3 * 0.3 then return true end
            end
            return false
        end
        for _, it in ipairs((r and r.issues) or {}) do
            if it.kind == "twin" and it.turn ~= nil then
                local all = true
                for _, p in ipairs(m) do
                    if not onLine(it.turn, p) then all = false end
                end
                if all then problem = true end
            end
        end
        for _, it in ipairs((r and r.notes) or {}) do
            if it.kind == "twinwait" and it.turn ~= nil then
                local all = true
                for _, p in ipairs(m) do
                    if not onLine(it.turn, p) then all = false end
                end
                if all then waitNote = true end
            end
        end
        local st = lastJudge[i]
        local whole = (st == "fromcut" or st == "tocut")
        for _, w in ipairs(js) do
            if not FINE[w] then faultSaid = true end
            if st == "drives" and not FINE[w] then bad[#bad + 1] = "join:" .. w end
            if st ~= "drives" and w == "twin" then bad[#bad + 1] = "join:twin-but-" .. st end
            if st ~= "drives" and not whole and w == "twinwait" then bad[#bad + 1] = "join:twinwait-but-" .. st end
        end
        for _, d in ipairs(dotsOn) do
            local w = d.why
            if not FINE[w] then faultSaid = true end
            -- the states of every turn of B's this dot lies on
            local any, anyNot = false, false
            for k, m2 in ipairs(movements) do
                if onTurn(m2, d) then
                    if lastJudge[k] == "drives" then any = true else anyNot = true end
                end
            end
            if st == "drives" and not FINE[w] and not anyNot then bad[#bad + 1] = "dot:" .. w end
            if st ~= "drives" and w == "twin" and not any then bad[#bad + 1] = "dot:twin-but-" .. st end
            if st ~= "drives" and not whole and w == "twinwait" then bad[#bad + 1] = "dot:twinwait-but-" .. st end
        end
        if st == "drives" and problem then bad[#bad + 1] = "problem-line-for-a-turn-that-drives" end
        if st ~= nil and not whole and waitNote then bad[#bad + 1] = "waits-note-for-a-turn-that-is-" .. st end
        local unsaid = ""
        if st ~= "drives" and not problem and not faultSaid and not waitNote then
            local nd = math.huge
            for _, p in ipairs(m) do nd = math.min(nd, math.sqrt((p.x - ax) ^ 2 + (p.z - az) ^ 2)) end
            unsaid = string.format(" UNSAID near=%.1f", nd)
        end
        print(string.format("AFTER_A SAID %d %s joins=%s dots=%s problem=%s wait=%s%s%s", i, tostring(st), table.concat(js, ","),
            table.concat(ds, ","), problem and "yes" or "no", waitNote and "yes" or "no", unsaid,
            (#bad > 0) and (" MISMATCH " .. table.concat(bad, ",")) or ""))
    end
end
dump("1afterA")
-- then B
local jb2 = H.lock(bx, bz, { mode = "clear", radius = 12, leaveThrough = lv, turnRadius = TURNR })
if jb2 == nil then
    print("B2 REFUSED " .. tostring(ADFlyoverEditor.junctionRefused))
    return
end
print("B2 NAME " .. tostring(jb2.junctionName))
ADFlyoverEditor.junctionLastCheck = nil
ok, log = pcall(H.apply)
if not ok then print("B STOPPED " .. tostring(log)) log = LOG end
logLines("B", log)
if os.getenv("ALLB") == "1" then for _, l in ipairs(log or {}) do print("BALL " .. l) end end
check("B")
judge("AFTER_B")
dump("2afterB")

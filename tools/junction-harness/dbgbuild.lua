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

if os.getenv("CLEARFIRST") == "1" then
    local cjp = H.lock(CX, CZ, { mode = "clear", radius = 12, leaveThrough = true })
    if cjp == nil then
        print("CLEAR REFUSED: " .. tostring(ADFlyoverEditor.junctionRefused))
        return
    end
    H.apply()
    print("cleared the site first (through roads kept)")
end

local before = survey()
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
print(string.format("points %d -> %d | links %d -> %d | two-way links %d -> %d | teal dots %d -> %d",
    before.points, after.points, before.links, after.links, before.dual, after.dual, before.teal, after.teal))
print(string.format("COUNTS %.1f %.1f moves=%d new=%d refused=%d points=%d links=%d dual=%d teal=%d",
    CX, CZ, moves, newMoves, refused, after.points - before.points, after.links - before.links,
    after.dual - before.dual, after.teal - before.teal))

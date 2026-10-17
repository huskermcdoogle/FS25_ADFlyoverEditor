--[[ STEP 6, AS A STORY: per-player undo skips what someone else changed, says so, and lets it back when
they undo. Small hand-made network, the mod's own GraphOps/ActionCodec/NetCore, messages delivered at once.

    lua undo_story.lua            (prints each step; exits 1 on the first thing that is not as told)
]]
Logging = { info = function() end, warning = print, error = print }
dofile("../../scripts/editor/GraphOps.lua")
dofile("../../scripts/editor/ActionCodec.lua")
dofile("../../scripts/editor/NetCore.lua")
local G, N = ADFlyoverGraphOps, ADFlyoverNet

local function line(n)
    local g = { wayPoints = {}, mapMarkers = {}, groups = { All = 1 } }
    for i = 1, n do
        g.wayPoints[i] = { id = i, x = i * 4, y = 0, z = 0, flags = 0, out = i < n and { i + 1 } or {},
                           incoming = i > 1 and { i - 1 } or {} }
    end
    return g
end
local base = line(20)
G.setTagSpace(0)
G.tagAll(base.wayPoints)
local baseNext = G.nextTag

local queue = {}
local peers = {}
local function as(p) G.tagBase, G.nextTag = p.tagBase, p.nextTag end
local function leave(p) p.nextTag = G.nextTag end

local server = { graph = G.copyGraph(base), tagBase = 0, nextTag = baseNext }
server.net = N.newServer({ graph = server.graph, send = function(to, msg) queue[#queue + 1] = { to = to, msg = msg } end,
                           linger = 0 })   -- zones off: this story is about undo
local function newPlayer(name, slot)
    local p = { name = name, graph = G.copyGraph(base), tagBase = slot * G.TAG_BLOCK, nextTag = slot * G.TAG_BLOCK }
    as(p)
    p.net = N.newClient({ graph = p.graph, player = name, send = function(msg) queue[#queue + 1] = { to = "server", from = name, msg = msg } end })
    leave(p)
    N.serverAddPlayer(server.net, name)
    peers[name] = p
    return p
end
local anna, bob = newPlayer("Anna", 1), newPlayer("Bob", 2)

local function settle()
    while #queue > 0 do
        local m = table.remove(queue, 1)
        if m.to == "server" then
            as(server); N.serverReceive(server.net, m.from, m.msg); leave(server)
        else
            local p = peers[m.to]
            as(p); assert(N.clientReceive(p.net, m.msg), "out of step"); leave(p)
        end
    end
end
local function pointByTag(p, tag)
    for _, w in ipairs(p.graph.wayPoints) do if w.fxTag == tag then return w end end
end
local function move(p, tag, dx, label)
    as(p)
    local w = pointByTag(p, tag)
    w.x = w.x + dx
    N.clientFlush(p.net, label)
    leave(p)
    settle()
end
local function undo(p) as(p); local t = N.clientUndo(p.net, false); leave(p); settle(); return t end
local function redo(p) as(p); local t = N.clientUndo(p.net, true); leave(p); settle(); return t end

local fails = 0
local function expect(what, ok)
    print((ok and "  ok   " or "  FAIL ") .. what)
    if not ok then fails = fails + 1 end
end
local function allSame()
    return G.same(anna.graph, server.graph) and G.same(bob.graph, server.graph)
end

local P = base.wayPoints[10].fxTag          -- the point everyone fights over
local Q = base.wayPoints[3].fxTag           -- somewhere else
local x0 = pointByTag(server, P).x

print("1. Anna moves point P (Smooth), then point Q (Move)")
move(anna, P, 2, "Smooth")
move(anna, Q, 1, "Move")
expect("P is at +2 everywhere", pointByTag(server, P).x == x0 + 2 and allSame())

print("2. Bob moves P again (Straighten)")
move(bob, P, 5, "Straighten")
expect("P is at +7 everywhere", pointByTag(server, P).x == x0 + 7 and allSame())

print("3. Anna presses undo: Q's move comes back (it is hers and untouched)")
local t = undo(anna)
print("     screen: " .. t)
expect("said 'Undid: Move.'", t == "Undid: Move.")
expect("Q back, P still +7, everyone the same", pointByTag(server, Q).x == base.wayPoints[3].x and pointByTag(server, P).x == x0 + 7 and allSame())

print("4. Anna presses undo again: Smooth is blocked by Bob - skipped, and nothing older of hers is left")
t = undo(anna)
print("     screen: " .. t)
expect("says Bob changed that spot (Straighten)", t:find("Bob changed that spot %(Straighten%)") ~= nil)
expect("nothing moved: P still +7", pointByTag(server, P).x == x0 + 7 and allSame())

print("5. Bob undoes his Straighten")
t = undo(bob)
print("     Bob's screen: " .. t)
expect("P back to +2 everywhere", pointByTag(server, P).x == x0 + 2 and allSame())

print("6. Anna presses undo: her Smooth fits again and comes back")
t = undo(anna)
print("     screen: " .. t)
expect("said 'Undid: Smooth.'", t == "Undid: Smooth.")
expect("P back where it started, everyone the same", pointByTag(server, P).x == x0 and allSame())

print("7. Anna redoes twice: Smooth, then Move")
local r1 = redo(anna); local r2 = redo(anna)
print("     screen: " .. r1 .. " / " .. r2)
expect("both redone in order", r1 == "Redid: Smooth." and r2 == "Redid: Move." and pointByTag(server, P).x == x0 + 2 and allSame())

print("8. Anna moves P once more (Ditch); Bob's redo of Straighten is now blocked")
move(anna, P, 1, "Ditch")
t = redo(bob)
print("     Bob's screen: " .. t)
expect("says Anna changed that spot (Ditch)", t:find("Anna changed that spot %(Ditch%)") ~= nil)
expect("P still +3, everyone the same", pointByTag(server, P).x == x0 + 3 and allSame())

print("9. Anna undoes Ditch; now Bob's redo fits (P looks as his undo left it) and goes through")
undo(anna)
t = redo(bob)
print("     Bob's screen: " .. t)
expect("said 'Redid: Straighten.'", t == "Redid: Straighten." and pointByTag(server, P).x == x0 + 7 and allSame())

print(fails == 0 and "STORY: all as told" or ("STORY: " .. fails .. " FAIL"))
if fails > 0 then os.exit(1) end

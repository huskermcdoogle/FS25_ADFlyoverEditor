--[[ IDENTITY STORY (issue #26, multiplayer port). An undo puts a deleted point or marker back as the SAME
table, so anything holding it (a vehicle's route, a vehicle's destination) still holds the live one.
The value checks in undo_story.lua cannot see this: they compare numbers, not tables.

    lua identity_story.lua     (prints each check; exits 1 if any check is not as told)
]]
Logging = { info = function() end, warning = print, error = print }
dofile("../../scripts/editor/GraphOps.lua")
local G = ADFlyoverGraphOps

local fails = 0
local function expect(label, ok)
    print(string.format("  %-4s %s", ok and "ok" or "FAIL", label))
    if not ok then fails = fails + 1 end
end

local function line(n)
    local g = { wayPoints = {}, mapMarkers = {}, groups = { All = 1 } }
    for i = 1, n do
        g.wayPoints[i] = { id = i, x = i * 4, y = 0, z = 0, flags = 0,
                           out = i < n and { i + 1 } or {}, incoming = i > 1 and { i - 1 } or {} }
    end
    return g
end

-- remove point number k the way the editor does: unlink it, renumber above it, move the markers
local function deletePoint(g, k)
    local prev, nxt = g.wayPoints[k - 1], g.wayPoints[k + 1]
    if prev then
        for i = #prev.out, 1, -1 do if prev.out[i] == k then table.remove(prev.out, i) end end
        if nxt then table.insert(prev.out, k + 1) end
    end
    if nxt then
        for i = #nxt.incoming, 1, -1 do if nxt.incoming[i] == k then table.remove(nxt.incoming, i) end end
        if prev then table.insert(nxt.incoming, k - 1) end
    end
    table.remove(g.wayPoints, k)
    for i, o in ipairs(g.wayPoints) do
        o.id = i
        for j, v in ipairs(o.out) do if v > k then o.out[j] = v - 1 end end
        for j, v in ipairs(o.incoming) do if v > k then o.incoming[j] = v - 1 end end
    end
    for _, m in ipairs(g.mapMarkers) do if m.id > k then m.id = m.id - 1 end end
end

-- is this table the graph's own table for that point or marker?
local function inGraph(list, t)
    for _, x in ipairs(list) do if x == t then return true end end
    return false
end

print("CASE 1: a deleted point comes back as the same table")
local g = line(12)
G.setTagSpace(0)
G.tagAll(g.wayPoints)
g.mapMarkers = { { id = 9, name = "D", group = "All", markerIndex = 1 },
                 { id = 12, name = "E", group = "All", markerIndex = 2 } }
local holder = { point = g.wayPoints[10] }
local before = G.capture(g)
deletePoint(g, 10)
local a = G.diff(before, g, "delete 10")
expect("the delete is recorded as one removed point", a ~= nil and #a.dels == 1)
G.apply(g, a, true)
expect("undo: 12 points again", #g.wayPoints == 12)
expect("undo: the holder's point 10 is the graph's point 10 (same table)", g.wayPoints[10] == holder.point)
expect("undo: the holder's point is in the graph", inGraph(g.wayPoints, holder.point))
G.apply(g, a, false)
expect("redo: 11 points", #g.wayPoints == 11)
G.apply(g, a, true)
expect("undo again: the holder's point is still the graph's point 10", g.wayPoints[10] == holder.point)

print("")
print("CASE 2: a deleted marker comes back as the same table")
g = line(12)
G.setTagSpace(0)
G.tagAll(g.wayPoints)
g.mapMarkers = { { id = 9, name = "D", group = "All", markerIndex = 1 },
                 { id = 12, name = "E", group = "All", markerIndex = 2 } }
holder = { marker = g.mapMarkers[2] }
before = G.capture(g)
table.remove(g.mapMarkers, 2)
a = G.diff(before, g, "delete marker E")
expect("the marker delete is recorded", a ~= nil and a.markers ~= nil)
G.apply(g, a, true)
expect("undo: marker E is back", #g.mapMarkers == 2)
expect("undo: the holder's marker E is the graph's marker E (same table)", g.mapMarkers[2] == holder.marker)
G.apply(g, a, false)
expect("redo: marker E gone", #g.mapMarkers == 1)
G.apply(g, a, true)
expect("undo again: the holder's marker E is still the graph's marker E", g.mapMarkers[2] == holder.marker)

print("")
print(fails == 0 and "STORY: all as told" or ("STORY: " .. fails .. " FAIL"))
os.exit(fails == 0 and 0 or 1)

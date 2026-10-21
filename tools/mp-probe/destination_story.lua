--[[ DESTINATION STORY (issue #26, multiplayer port). A name is made (a marker X on a point), two vehicles are
sent to it, then the name is undone. The marker X goes. Each vehicle's destinations must end on markers that
exist, and a vehicle heading to X as its current destination must move with its first or second slot.

    lua destination_story.lua     (prints each check; exits 1 if any check is not as told)
]]
Logging = { info = function() end, warning = print, error = print }
dofile("../../scripts/editor/GraphOps.lua")
local G = ADFlyoverGraphOps

local fails = 0
local function expect(label, ok)
    print(string.format("  %-4s %s", ok and "ok" or "FAIL", label))
    if not ok then fails = fails + 1 end
end

-- the state module's destination part, as AutoDrive keeps it (plain table, same method names)
local SM = {}
SM.__index = SM
function SM:setCurrentDestination(m) self.currentDestination = m end
local function vehicle(name, first, second, current)
    local sm = setmetatable({ firstMarker = first, secondMarker = second, currentDestination = current }, SM)
    return { name = name, ad = { stateModule = sm } }
end

-- AutoDrive's own marker reset: a destination whose marker is gone moves to marker 1 (first and second only)
local function resetLikeAutoDrive(vehicles, markers)
    for _, v in ipairs(vehicles) do
        local sm = v.ad.stateModule
        local present = {}
        for _, m in ipairs(markers) do present[m] = true end
        if sm.firstMarker == nil or not present[sm.firstMarker] then sm.firstMarker = markers[1] end
        if sm.secondMarker == nil or not present[sm.secondMarker] then sm.secondMarker = markers[1] end
    end
end

local function line(n)
    local g = { wayPoints = {}, mapMarkers = {}, groups = { All = 1 } }
    for i = 1, n do
        g.wayPoints[i] = { id = i, x = i * 4, y = 0, z = 0, flags = 0,
                           out = i < n and { i + 1 } or {}, incoming = i > 1 and { i - 1 } or {} }
    end
    return g
end

local g = line(12)
G.setTagSpace(0)
G.tagAll(g.wayPoints)
g.mapMarkers = { { id = 9, name = "D", group = "All", markerIndex = 1 },
                 { id = 12, name = "E", group = "All", markerIndex = 2 } }
local D, E = g.mapMarkers[1], g.mapMarkers[2]

-- V1 heads to the new name X as its first AND current destination; V2 heads to it as its second and current
local v1 = vehicle("V1", nil, E, nil)
local v2 = vehicle("V2", D, nil, nil)
local vehicles = { v1, v2 }

-- make the name: a marker X on point 11
local before = G.capture(g)
local X = { id = 11, name = "nbame", group = "All", markerIndex = 3 }
g.mapMarkers[3] = X
v1.ad.stateModule.firstMarker, v1.ad.stateModule.currentDestination = X, X
v2.ad.stateModule.secondMarker, v2.ad.stateModule.currentDestination = X, X
local act = G.diff(before, g, "name point 11")
expect("the name is an action that changed the markers", act ~= nil and act.markers ~= nil)

-- undo the name, the way the server does: remember the destinations, then the change, then the fix
local heading = G.destinationsOf(vehicles)
G.apply(g, act, true)
expect("undo: X is gone from the marker list", #g.mapMarkers == 2)
resetLikeAutoDrive(vehicles, g.mapMarkers)
local moved = G.fixCurrentDestinations(heading, g.mapMarkers)

local present = {}
for _, m in ipairs(g.mapMarkers) do present[m] = true end
expect("V1: first is a marker that exists", present[v1.ad.stateModule.firstMarker] == true)
expect("V1: current is no longer X, and is its first destination now",
       v1.ad.stateModule.currentDestination == v1.ad.stateModule.firstMarker and present[v1.ad.stateModule.currentDestination] == true)
expect("V2: current was its second slot, so it follows the second destination",
       v2.ad.stateModule.currentDestination == v2.ad.stateModule.secondMarker and present[v2.ad.stateModule.currentDestination] == true)
expect("two destinations were moved", moved == 2)
expect("the marker E is still the graph's own table (identity kept)", g.mapMarkers[2] == E)

-- nothing to fix when no marker went: a second call changes nothing
local again = G.fixCurrentDestinations(G.destinationsOf(vehicles), g.mapMarkers)
expect("with no marker gone, nothing is moved", again == 0)

print("")
print(fails == 0 and "STORY: all as told" or ("STORY: " .. fails .. " FAIL"))
os.exit(fails == 0 and 0 or 1)

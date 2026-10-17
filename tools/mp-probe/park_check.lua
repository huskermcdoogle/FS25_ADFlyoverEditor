--[[ ISSUE #24: DO PARKING SPOTS STAY ON THEIR NAME THROUGH AN UNDO?

AutoDrive keeps a parking spot as a place in its list of names. Deleting a name moves the later ones
up a place (AutoDrive's own removeMapMarker fixes the parking spots for that). Undo puts the name back;
before the fix the parking spots were not moved back, so each one named the name before it.

Runs AutoDrive's REAL GraphManager.lua and the editor's GraphOps.lua + EditorHistory.lua, both undo
kinds (actions, and the old whole copies), for: delete a name; delete a point carrying a name.

    lua park_check.lua <AutoDrive GraphManager.lua>      (run from tools/mp-probe)
]]

local GM_PATH = arg[1]
assert(GM_PATH, "usage: lua park_check.lua <GraphManager.lua>")

function table:contains(value) for _, v in pairs(self) do if v == value then return true end end return false end
function table:indexOf(value) for k, v in pairs(self) do if v == value then return k end end return nil end
function table:removeValue(value)
    for k, v in pairs(self) do if v == value then table.remove(self, k) return true end end
    return false
end
function table:count() local c = 0 for _ in pairs(self) do c = c + 1 end return c end
bit32 = bit32 or { band = function(a, b)
    local r, bitv = 0, 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then r = r + bitv end
        a, b, bitv = math.floor(a / 2), math.floor(b / 2), bitv * 2
    end
    return r
end }
Logging = { info = function() end, warning = print, error = print }
ADFlyoverSettings = { debugLog = function() end }
g_server, g_client = {}, nil

local vehicles = {}
AutoDrive = { Hud = { lastUIScale = 0 }, FLAG_NONE = 0, FLAG_SUBPRIO = 1,
              getAllVehicles = function() return vehicles end, notifyDestinationListeners = function() end }

dofile(GM_PATH)
-- main (1.0.3.x) has no GraphOps: only the whole-copy undo is checked there
local hasOps = io.open("../../scripts/editor/GraphOps.lua") ~= nil
if hasOps then dofile("../../scripts/editor/GraphOps.lua") end
dofile("../../scripts/editor/EditorHistory.lua")
local GM, H = ADGraphManager, ADEditorHistory
GM.createDebugMarkers = function() end

local function newVehicle(park, toolPark)
    local sm = { park = park }
    function sm:getParkDestinationAtJobFinished() return self.park end
    function sm:setParkDestinationAtJobFinished(p) self.park = p end
    function sm:resetMarkersOnReload() end
    function sm:getFirstMarkerId() return -1 end
    function sm:getSecondMarkerId() return -1 end
    function sm:getCurrentDestinationId() return -1 end
    local advd = { parkDestination = toolPark }
    function advd:getParkDestination() return self.parkDestination end
    function advd:setParkDestination(_, p) self.parkDestination = p end
    return { ad = { stateModule = sm }, advd = advd }
end

local NAMES = { "Farm", "Silo", "Field 3", "Shed", "Yard" }
local function setup()
    GM.wayPoints, GM.mapMarkers, GM.groups = {}, {}, { All = 1 }
    for i = 1, 8 do
        GM.wayPoints[i] = GM:createNode(i, i * 10, 0, 0, i < 8 and { i + 1 } or {}, i > 1 and { i - 1 } or {}, 0, nil, nil)
    end
    for i, n in ipairs(NAMES) do
        GM.mapMarkers[i] = { id = i + 1, name = n, group = "All", markerIndex = i }
    end
    -- parked at Shed, at Yard, at Silo; and a tool parked at Yard
    vehicles = { newVehicle(4, -1), newVehicle(5, -1), newVehicle(2, -1), newVehicle(-1, 5) }
    H.stack, H.redoStack, H.shadow, H.shadowOf, H.open = {}, {}, nil, nil, nil
end

local function parkedAt()
    local out = {}
    for _, v in ipairs(vehicles) do
        local p = v.ad.stateModule.park
        if v.advd.parkDestination ~= -1 then p = v.advd.parkDestination end
        local m = GM.mapMarkers[p]
        table.insert(out, m and m.name or "(none)")
    end
    return table.concat(out, ", ")
end

local fails = 0
local function expect(what, want)
    local got = parkedAt()
    local ok = got == want
    if not ok then fails = fails + 1 end
    print(string.format("  %-30s %s  %s%s", what, ok and "ok  " or "FAIL", got, ok and "" or ("   (want " .. want .. ")")))
end

local START = "Shed, Yard, Silo, Yard"
for _, actions in ipairs(hasOps and { true, false } or { false }) do
    if hasOps then ADFlyoverGraphOps.USE_FOR_UNDO = actions end
    local kind = actions and "actions" or "copies"

    print(kind .. ": delete the name Silo")
    setup()
    H:snapshot("delete name")
    GM:removeMapMarker(2, false)
    expect("after the delete", "Shed, Yard, (none), Yard")
    H:undo()
    expect("after undo", "Shed, Yard, (none), Yard")
    H:redo()
    expect("after redo", "Shed, Yard, (none), Yard")

    print(kind .. ": delete the point under Silo")
    setup()
    H:snapshot("delete point")
    GM:removeWayPoint(3, false)
    expect("after the delete", "Shed, Yard, (none), Yard")
    H:undo()
    expect("after undo", "Shed, Yard, (none), Yard")

    print(kind .. ": add a name, undo it")
    setup()
    H:snapshot("add name")
    GM:createMapMarker(8, "New", false)
    expect("after the add", START)
    H:undo()
    expect("after undo", START)
end
print(fails == 0 and "ALL PASS" or (fails .. " FAIL(S)"))
os.exit(fails == 0 and 0 or 1)

-- Offline check of the shared surface rule (scripts/editor/tools/Ground.lua, "THE SURFACE RULE").
--
-- Runs the REAL Ground.lua (and resolveHeightAt cut out of the real Move.lua) against a made-up
-- scene with a stubbed raycastClosest that follows the engine's rules as we know them: a downward
-- ray hits the top face of a shape whose collision GROUP shares a bit with the ray's MASK; it reports
-- the closest such hit with its object id and normal. Buildings and static objects carry the game's
-- presets (shared/collisionMaskFlags.xml): no DEFAULT bit.
--
-- Usage (Lua 5.1, from the repo root):
--   lua tools/surface-harness/surface_rule.lua [Ground.lua] [Move.lua]
-- Pass the old files (git show HEAD~1:...) to see the same cases under the old code.

local groundPath = arg[1] or "scripts/editor/tools/Ground.lua"
local movePath = arg[2] or "scripts/editor/tools/Move.lua"

-- ---- engine stubs ---------------------------------------------------------------------------
CollisionFlag = { DEFAULT = 1, STATIC_OBJECT = 2, CAMERA_BLOCKING = 4, GROUND_TIP_BLOCKING = 8,
    PLACEMENT_BLOCKING = 16, AI_BLOCKING = 32, TERRAIN = 256, TREE = 2048, BUILDING = 4096,
    ROAD = 8192, AI_DRIVABLE = 16384, VEHICLE = 65536, DYNAMIC_OBJECT = 262144 }
local CF = CollisionFlag
-- the game's presets
local G_BUILDING = CF.CAMERA_BLOCKING + CF.GROUND_TIP_BLOCKING + CF.PLACEMENT_BLOCKING + CF.AI_BLOCKING + CF.BUILDING
local G_STATIC = CF.STATIC_OBJECT + CF.CAMERA_BLOCKING + CF.GROUND_TIP_BLOCKING + CF.PLACEMENT_BLOCKING + CF.AI_BLOCKING
local G_ROAD = CF.CAMERA_BLOCKING + CF.GROUND_TIP_BLOCKING + CF.PLACEMENT_BLOCKING + CF.ROAD + CF.AI_DRIVABLE
local G_DEFAULT = CF.DEFAULT
local G_TERRAIN = CF.TERRAIN

local function band(a, b)
    local r, bit = 0, 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then r = r + bit end
        a, b, bit = math.floor(a / 2), math.floor(b / 2), bit * 2
    end
    return r
end

local TERRAIN_ID = 1
local TERRAIN_Y = 80.02
local shapes = {}      -- { id, name, group, top = function(x, z) -> y or nil, ny }
local function terrainAt(x, z)
    -- a ramp's terrain is flat too; one low dip at x 900..910 for the "point in a dip" case
    if x >= 900 and x <= 910 then return TERRAIN_Y - 0.8 end
    return TERRAIN_Y
end
local function box(id, name, group, x0, x1, z0, z1, y, ny)
    shapes[#shapes + 1] = { id = id, name = name, group = group, ny = ny or 1,
        top = function(x, z)
            if x >= x0 and x <= x1 and z >= z0 and z <= z1 then return y end
        end }
end

g_currentMission = { terrainRootNode = TERRAIN_ID }
g_time = nil           -- no cache between cases
function getTerrainHeightAtWorldPos(_, x, _, z) return terrainAt(x, z) end
function getCollisionFilterGroup(id)
    if id == TERRAIN_ID then return G_TERRAIN end
    for _, s in ipairs(shapes) do if s.id == id then return s.group end end
    return 0
end
function getName(id)
    if id == TERRAIN_ID then return "terrain" end
    for _, s in ipairs(shapes) do if s.id == id then return s.name end end
    return "?"
end
function getParent() return 0 end
RAYS = 0
function raycastClosest(x, y, z, dx, dy, dz, len, cbName, target, mask)
    RAYS = RAYS + 1
    assert(dx == 0 and dy == -1 and dz == 0, "only straight down is modelled")
    local best = nil
    local function consider(hy, id, ny)
        if hy <= y + 1e-9 and hy >= y - len then
            if best == nil or hy > best.y then best = { y = hy, id = id, ny = ny } end
        end
    end
    if band(G_TERRAIN, mask) ~= 0 then consider(terrainAt(x, z), TERRAIN_ID, 1) end
    for _, s in ipairs(shapes) do
        if band(s.group, mask) ~= 0 then
            local hy = s.top(x, z)
            if hy ~= nil then consider(hy, s.id, s.ny) end
        end
    end
    if best ~= nil then
        target[cbName](target, best.id, x, best.y, z, y - best.y, 0, best.ny, 0)
    end
    return best ~= nil and 1 or 0
end
LOG = {}
Logging = { info = function(fmt, ...) LOG[#LOG + 1] = string.format(fmt, ...) end,
    error = function(...) print("ERROR", string.format(...)) end }
ADFlyoverSettings = { debugLog = function(fmt, ...) LOG[#LOG + 1] = string.format(fmt, ...) end, get = function() end }
MathUtil = { vector2Length = function(a, b) return math.sqrt(a * a + b * b) end }

-- AutoDrive's own lookup, as in AutoDrive/scripts/Utils/UtilFuncs.lua (5 m cast from 3 m over the start)
AutoDrive = { FLYOVER_STRUCTURE_HEIGHT = 0.5, FLYOVER_GROUND_UNDER = 0.02 }
function AutoDrive:getTerrainHeightAtWorldPos(x, z, startingHeight)
    self.raycastHeight = nil
    local startHeight = startingHeight or getTerrainHeightAtWorldPos(TERRAIN_ID, x, 1, z)
    raycastClosest(x, startHeight + 3, z, 0, -1, 0, 5, "cb", { cb = function(_, _, _, hy) AutoDrive.raycastHeight = hy end },
        CF.DEFAULT + CF.ROAD + CF.TERRAIN)
    return self.raycastHeight or startHeight
end

ADFlyoverEditor = { shared = { heightAlongChain = function() return 0 end },
    GROUND_LEVEL = { SPAN = 1, TOP = 2 }, groundLevel = 1, snapToTerrain = false }

dofile(groundPath)
do
    local f = assert(io.open(movePath, "r"))
    local src = f:read("*a")
    f:close()
    local a = src:find("function ADFlyoverEditor:resolveHeightAt", 1, true)
    local b = src:find("\nend\n", a, true)
    assert(loadstring(src:sub(a, b + 4)))()
end
local E = ADFlyoverEditor

-- ---- the scene --------------------------------------------------------------------------------
-- x ranges keep the cases apart; every case is probed at z = 5.
box(10, "floorSlab_5cm",  G_BUILDING, 0, 20, 0, 10, TERRAIN_Y + 0.05)        -- the Welker case
box(11, "floorSlab_12cm", G_STATIC,  100, 120, 0, 10, TERRAIN_Y + 0.12)
box(12, "shedFloor",      G_BUILDING, 200, 220, 0, 10, TERRAIN_Y + 0.10)
box(13, "shedRoof",       G_BUILDING, 200, 220, 0, 10, TERRAIN_Y + 7.0)
box(14, "bridgeDeck",     G_ROAD,    300, 320, 0, 10, TERRAIN_Y + 6.0)
box(15, "roadUnder",      G_ROAD,    300, 320, 0, 10, TERRAIN_Y + 0.04)
box(16, "fenceRail",      G_STATIC,  400, 420, 4.98, 5.02, TERRAIN_Y + 1.0)  -- 4 cm wide, along x
box(17, "kerb",           G_STATIC,  500, 520, 4.85, 5.15, TERRAIN_Y + 0.15)  -- 30 cm wide
box(18, "lightPole",      G_STATIC,  599.9, 600.1, 4.9, 5.1, TERRAIN_Y + 8.0)
shapes[#shapes + 1] = { id = 19, name = "ramp10deg", group = G_BUILDING, ny = math.cos(math.rad(10)),
    top = function(x, z)
        if x >= 700 and x <= 707 and z >= 0 and z <= 10 then return TERRAIN_Y + (x - 700) * math.tan(math.rad(10)) end
    end }
box(20, "oldDefaultDeck", G_DEFAULT, 800, 820, 0, 10, TERRAIN_Y + 5.0)      -- old-style DEFAULT mesh
box(21, "loadingDock",    G_BUILDING, 1000, 1020, 0, 10, TERRAIN_Y + 1.2)

-- ---- cases ------------------------------------------------------------------------------------
local cases = {
    -- name, x, point y, expected y (span line), level, what is right
    { "floor 5 cm, point on terrain",      10, TERRAIN_Y,        nil, 1, TERRAIN_Y + 0.05 },
    { "floor 5 cm, point on floor",        10, TERRAIN_Y + 0.05, nil, 1, TERRAIN_Y + 0.05 },
    { "floor 12 cm, point on terrain",    110, TERRAIN_Y,        nil, 1, TERRAIN_Y + 0.12 },
    { "shed, point on terrain",           210, TERRAIN_Y,        nil, 1, TERRAIN_Y + 0.10 },
    { "shed, top surface",                210, TERRAIN_Y,        nil, 2, TERRAIN_Y + 0.10 },
    { "bridge, road point",               310, TERRAIN_Y + 0.04, nil, 1, TERRAIN_Y + 0.04 },
    { "bridge, road point on terrain",    310, TERRAIN_Y,        nil, 1, TERRAIN_Y + 0.04 },
    { "bridge, deck point",               310, TERRAIN_Y + 6.0,  nil, 1, TERRAIN_Y + 6.0 },
    { "bridge, deck by span line",        310, TERRAIN_Y + 4.0,  TERRAIN_Y + 6.0, 1, TERRAIN_Y + 6.0 },
    { "bridge, top surface",              310, TERRAIN_Y,        nil, 2, TERRAIN_Y + 6.0, TERRAIN_Y + 0.04 },
    { "under a fence rail",               410, TERRAIN_Y,        nil, 1, TERRAIN_Y },
    { "on a kerb line",                   510, TERRAIN_Y,        nil, 1, TERRAIN_Y },
    { "under a light pole",               600, TERRAIN_Y,        nil, 2, TERRAIN_Y },
    { "ramp, half way, point on terrain", 703.5, TERRAIN_Y,      nil, 1, TERRAIN_Y + 3.5 * math.tan(math.rad(10)) },
    { "old DEFAULT deck, deck point",     810, TERRAIN_Y + 5.0,  nil, 1, TERRAIN_Y + 5.0 },
    { "old DEFAULT deck, ground point",   810, TERRAIN_Y,        nil, 1, TERRAIN_Y },
    { "open ground",                      950, TERRAIN_Y + 0.3,  nil, 1, TERRAIN_Y },
    { "loading dock 1.2 m, point on it", 1010, TERRAIN_Y + 1.2,  nil, 1, TERRAIN_Y + 1.2 },
}

local function f(v) if v == nil then return "  nil  " end return string.format("%7.3f", v - TERRAIN_Y) end
print("Heights shown as metres over the terrain (80.02). '*' = wrong.")
print("ground = the ground tool's target (0.5 m tolerance), flagged = its preview marks the point,")
print("resolve = placing a point at that height, cursor = placing it where the cursor reads that height.")
print(string.format("%-34s %8s %8s %8s %8s %8s %6s", "case", "right", "ground", "flagged", "resolve", "cursor", "rays"))
local wrong = 0
for _, c in ipairs(cases) do
    local name, x, y, expected, level, right = c[1], c[2], c[3], c[4], c[5], c[6]
    local rightPlace = c[7] or right      -- placing a point has no "top surface" toggle
    E.groundLevel = level
    RAYS = 0
    -- the ground tool: target with the default tolerance, and whether its preview flags the point
    local target, kind = E:groundTargetAt(x, y, 5, expected, false, 0.5)
    local flagged = "-"
    if target ~= nil then
        local delta = y - target
        local under = kind ~= nil and kind ~= "terrain" and delta < -AutoDrive.FLYOVER_GROUND_UNDER
        if under or math.abs(delta) > 0.5 then flagged = "yes" else flagged = "no" end
        -- what the old preview did: tolerance only
        if E.surfaceNear == nil then flagged = (math.abs(delta) > 0.5) and "yes" or "no" end
    end
    local rays = RAYS
    -- placing a new point: resolveHeightAt with the point's height as reference, and with the cursor's
    E.groundLevel = 1
    local resolved = E:resolveHeightAt(x, 5, y)
    local cursor = E:resolveHeightAt(x, 5, y, y)
    -- a point is right when it lands at the right height, or is flagged to go there
    -- flagged when further off than the 0.5 m tolerance, or under the surface it belongs on
    local shouldFlag = math.abs(y - right) > 0.5 or y < right - 0.02
    local okGround = math.abs(target - right) < 0.005 and ((flagged == "yes") == shouldFlag)
    -- placing: on the right surface, or (more than 0.5 m up, nothing seen there) left at its height
    local okResolve = math.abs(resolved - rightPlace) < 0.005 or (y - TERRAIN_Y > 0.5 and math.abs(resolved - y) < 0.005)
    local okCursor = math.abs(cursor - rightPlace) < 0.005 or (math.abs(cursor - y) < 0.005 and math.abs(y - rightPlace) > 0.5)
    if not okGround then wrong = wrong + 1 end
    if not okResolve then wrong = wrong + 1 end
    if not okCursor then wrong = wrong + 1 end
    print(string.format("%-34s %8s %7s%s %8s %7s%s %7s%s %6d", name, f(right), f(target), okGround and " " or "*",
        flagged, f(resolved), okResolve and " " or "*", f(cursor), okCursor and " " or "*", rays))
end
print(string.format("%d wrong answer(s).", wrong))
if E.describeSurfaces ~= nil then
    LOG = {}
    E:describeSurfaces(210, 5, TERRAIN_Y, "(shed)", TERRAIN_Y + 0.10)
    E:describeSurfaces(410, 5, TERRAIN_Y, "(fence rail)", TERRAIN_Y)
    print("")
    for _, l in ipairs(LOG) do print(l) end
end

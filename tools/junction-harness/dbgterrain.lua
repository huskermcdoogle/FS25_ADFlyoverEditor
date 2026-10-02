-- The ground around a point, as the offline harness now sees it (TERRAIN=1 data, see terrain.lua):
-- paint, drive cost, height, field, and the editor's own road verdict (isRoadAt, reached through
-- junctionCorridorOffRoad, so it is the shipping code deciding, not a copy of it).
--
--   lua dbgterrain.lua X Z [R] [STEP]    grids R metres round (X, Z), every STEP m (default 6, 1)
--   lua dbgterrain.lua check             the road check at known spots; prints PASS/FAIL per spot
--
-- Loads terrain.lua itself when TERRAIN is not set, since without it there is nothing to show.
-- Rows run north (small z) to south, columns west to east; the centre cell is bracketed.
LOG_ECHO = false
local H = dofile("harness.lua")
if os.getenv("TERRAIN") ~= "1" then dofile("terrain.lua") end
local T = TERRAIN
local E = ADFlyoverEditor

--- The editor's own answer: a zero-length turn from (x, z) to (x, z) is probed at both ends, centre
--- only, so it is off the road exactly when isRoadAt says no.
local function editorRoad(x, z)
    local off = E:junctionCorridorOffRoad({ ax = x, az = z, bx = x, bz = z, points = {} })
    return off == 0
end

local function fieldDensity(x, z)
    return getDensityAtWorldPos(g_currentMission.terrainDetailId, x, 0, z)
end

if arg[1] == "check" then
    -- Spots picked from the paint and the drive-cost map (dbgterrain grids at each), with the
    -- verdict the game's rules give there. Each says why it is that answer.
    local spots = {
        { "j1 road middle (asphalt02, cost 52)",                  -37.06, 495.68, true },
        { "j1 west verge (forestLeaves01, grass sound)",          -46.06, 495.68, false },
        { "rock (forestRockRoots02, asphalt sound, cost 207)",    329.0, -394.0, false },
        { "field (mudDark01: dirt sound, inside an outline)",    -926.0, -963.0, false },
        { "gravel track (gravelPebblesMossPatchy01, cost 92)",   -262.0, -959.0, true },
    }
    local fails = 0
    for _, s in ipairs(spots) do
        local name, x, z, want = s[1], s[2], s[3], s[4]
        local got = editorRoad(x, z)
        local L = T.layers[T.paintAt(x, z) + 1]
        print(string.format("%s  %-52s (%.1f, %.1f)  paint %s (material %d)  cost %d  field %s  -> %s",
            got == want and "PASS" or "FAIL", name, x, z, L.name, L.materialId, T.costAt(x, z),
            tostring(T.fieldAt(x, z)), got and "road" or "not road"))
        if got ~= want then fails = fails + 1 end
    end
    for _, line in ipairs(LOG) do
        if line:find("junction clearance") then print("  log: " .. line) end
    end
    print(fails == 0 and "all spots agree" or (fails .. " spot(s) disagree"))
    os.exit(fails == 0 and 0 or 1)
end

local CX, CZ = tonumber(arg[1]), tonumber(arg[2])
if CX == nil or CZ == nil then
    print("usage: lua dbgterrain.lua X Z [R] [STEP]   |   lua dbgterrain.lua check")
    os.exit(1)
end
local R = tonumber(arg[3]) or 6
local STEP = tonumber(arg[4]) or 1
local n = math.floor(R / STEP)

local function grid(title, fmt, f)
    print(title)
    for j = -n, n do
        local row = {}
        for i = -n, n do
            local s = string.format(fmt, f(CX + i * STEP, CZ + j * STEP))
            if i == 0 and j == 0 then s = "[" .. s:sub(2) .. "]" end
            row[#row + 1] = s
        end
        print(string.format("%8.1f ", CZ + j * STEP) .. table.concat(row))
    end
    print()
end

local cy = T.heightAt(CX, CZ)
local nx, ny, nz = T.normalAt(CX, CZ)
local L0 = T.layers[T.paintAt(CX, CZ) + 1]
print(string.format("(%.2f, %.2f): height %.3f m, slope %.1f deg, paint %d %s (material %d, softness %.3f, cost %g), drive cost %d, field %s, editor says %s",
    CX, CZ, cy, math.deg(math.acos(ny)), T.paintAt(CX, CZ), L0.name, L0.materialId, L0.softness, L0.cost,
    T.costAt(CX, CZ), tostring(fieldDensity(CX, CZ) ~= 0), editorRoad(CX, CZ) and "road" or "not road"))
print(string.format("columns x = %.1f .. %.1f every %g m; rows z north to south\n", CX - n * STEP, CX + n * STEP, STEP))

local seen = {}
grid("paint layer index", " %3d", function(x, z) local p = T.paintAt(x, z); seen[p] = true; return p end)
grid("drive cost (255 = blocked)", " %3d", T.costAt)
grid("height - centre, cm", " %4d", function(x, z) return math.floor((T.heightAt(x, z) - cy) * 100 + 0.5) end)
grid("field (F) / not (.)", " %s", function(x, z) return fieldDensity(x, z) ~= 0 and "F" or "." end)
grid("editor's road check: road (R) / not (.)", " %s", function(x, z) return editorRoad(x, z) and "R" or "." end)

print("paint layers here:")
local keys = {}
for p in pairs(seen) do keys[#keys + 1] = p end
table.sort(keys)
for _, p in ipairs(keys) do
    local L = T.layers[p + 1]
    print(string.format("  %3d %-28s material %d  softness %.3f  cost %g", p, L.name, L.materialId, L.softness, L.cost))
end

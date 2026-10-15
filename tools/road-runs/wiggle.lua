-- How much does a walked line wiggle? Walk from a spot (as the mouse would) and measure the laid
-- line against the chord 12 m either side: a weave from half to half of the road shows as metres.
--   lua wiggle.lua x z [x z ...]       NOFILL=1: without the patch fill (compare)
local HERE = (arg[0]:match("^(.*)[/\\]") or ".") .. "/"
local JH = HERE .. "../../../junction-rework-fec884/tools/junction-harness/"
local real = os.getenv
os.getenv = function(k) if k == "TERRAIN_DIR" then return JH .. "terrain_data/" end return real(k) end
g_currentMission = { terrainRootNode = 1 }; AutoDrive, CollisionFlag = {}, {}
dofile(HERE .. "terrain.lua"); dofile(HERE .. "../../scripts/editor/RoadFinder.lua")
local RF = ADRoadFinder
if os.getenv("NOFILL") then RF.PATCH_FILL = -1 end
local sqrt = math.sqrt
local shoulderAt = RF.newShoulderMap(RF.groundKindAt)
local isRoadOf = function(cls)
    if cls == "paved" then return function(x, z) return RF.groundKindAt(x, z) == RF.KIND_PAVED end end
    return function(x, z) local k = RF.groundKindAt(x, z) return (k == 1 or k == 2) and not shoulderAt(x, z) end
end
local isStopOf = function(cls) if cls == "track" then return function(x, z) return RF.groundKindAt(x, z) == 3 or shoulderAt(x, z) end end end
RF.WALK.maxLen = 400
for i = 1, #arg - 1, 2 do
    local x, z = tonumber(arg[i]), tonumber(arg[i + 1])
    local r = RF.walkFrom(isRoadOf, x, z, { "paved", "track" }, isStopOf)
    if r == nil then print(string.format("(%.1f,%.1f): nothing", x, z)) else
        local P = r.pts
        -- each point against the chord 12 m either side (a bend of radius 50 m sags 0.36 m there;
        -- a weave from half to half of the road shows as metres)
        local sum, worst, n = 0, 0, 0
        for k = 7, #P - 6 do
            local a, b = P[k - 6], P[k + 6]
            local hx, hz = b.x - a.x, b.z - a.z
            local hl = sqrt(hx * hx + hz * hz)
            if hl > 1e-6 then
                local off = math.abs(((P[k].x - a.x) * -hz + (P[k].z - a.z) * hx) / hl)
                sum, worst, n = sum + off, math.max(worst, off), n + 1
            end
        end
        print(string.format("(%.1f,%.1f): %s %.0f m, %.1f m wide; off the 24 m chord: mean %.2f m, worst %.2f m", x, z,
            r.class, r.len or 0, r.width or -1, n > 0 and sum / n or 0, worst))
    end
end

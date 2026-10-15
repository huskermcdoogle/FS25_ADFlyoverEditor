-- Does the laid line sit toward the inside of bends? For each point on a bend (radius under 60 m),
-- the asphalt's middle measured toward the bend's inside (+ = the line is outside the middle, i.e.
-- the middle lies further in; - = the line cuts inside). lua bendbias.lua x z   (AREA= for saved ground)
local HERE = (arg[0]:match("^(.*)[/\]") or ".") .. "/"
local JH = dofile(HERE .. "datadir.lua")(HERE)
local real = os.getenv
os.getenv = function(k) if k == "TERRAIN_DIR" then return JH .. "terrain_data/" end return real(k) end
g_currentMission = { terrainRootNode = 1 }; AutoDrive, CollisionFlag = {}, {}
local T = dofile(HERE .. "terrain.lua"); dofile(HERE .. "../../scripts/editor/RoadFinder.lua")
local RF = ADRoadFinder
local isRoadOf = function(cls) return function(x, z) return RF.groundKindAt(x, z) == 3 end end
RF.WALK.maxLen = 400
local r = RF.walkFrom(isRoadOf, tonumber(arg[1]), tonumber(arg[2]), { "paved" }, function() return nil end)
local function stats(P, name)
    local inS, inN, straightS, straightN = 0, 0, 0, 0
    for i = 4, #P - 3 do
        local a, b, c = P[i - 3], P[i], P[i + 3]
        if T.areaChar == nil or T.areaChar(b.x, b.z) ~= nil then
            local hx, hz = c.x - a.x, c.z - a.z
            local l = math.sqrt(hx * hx + hz * hz)
            local nx, nz = -hz / l, hx / l
            -- the bend's inside: the side the chord's middle lies on from b
            local mx, mz = (a.x + c.x) / 2 - b.x, (a.z + c.z) / 2 - b.z
            local sag = mx * nx + mz * nz
            local radius = (l * l) / (8 * math.max(1e-6, math.abs(sag)))
            local best, cur
            for o = -4, 4, 0.25 do
                if RF.groundKindAt(b.x + nx * o, b.z + nz * o) == 3 then
                    if cur then cur.hi = o else cur = { lo = o, hi = o } end
                else
                    if cur and (not best or cur.hi - cur.lo > best.hi - best.lo) then best = cur end
                    cur = nil
                end
            end
            if cur and (not best or cur.hi - cur.lo > best.hi - best.lo) then best = cur end
            if best and best.hi - best.lo >= 1.25 then
                local mid = (best.lo + best.hi) / 2
                if radius < 60 then
                    local inward = (sag >= 0) and mid or -mid       -- + : the middle lies inward of the line
                    inS, inN = inS + inward, inN + 1
                else
                    straightS, straightN = straightS + math.abs(mid), straightN + 1
                end
            end
        end
    end
    print(string.format("%-9s bends: the asphalt's middle lies %+.2f m toward the inside of the line (%d points); straights: %.2f m off (%d)",
        name, inS / math.max(1, inN), inN, straightS / math.max(1, straightN), straightN))
end
stats(r.raw, "walker")
stats(r.debug.filtered, "filtered")
stats(r.pts, "final")

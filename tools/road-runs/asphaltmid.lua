-- How far a walked paved line sits from the middle of its asphalt (the widest asphalt run within 4 m
-- each side of each point, read every 0.25 m across):  lua asphaltmid.lua x z   (AREA= for saved ground)
local HERE = (arg[0]:match("^(.*)[/\]") or ".") .. "/"
local JH = dofile(HERE .. "datadir.lua")(HERE)
local real = os.getenv
os.getenv = function(k) if k == "TERRAIN_DIR" then return JH .. "terrain_data/" end return real(k) end
g_currentMission = { terrainRootNode = 1 }; AutoDrive, CollisionFlag = {}, {}
dofile(HERE .. "terrain.lua"); dofile(HERE .. "../../scripts/editor/RoadFinder.lua")
local RF = ADRoadFinder
local sh = RF.newShoulderMap(RF.groundKindAt)
local isRoadOf = function(cls) if cls == "paved" then return function(x,z) return RF.groundKindAt(x,z) == 3 end end
  return function(x,z) local k = RF.groundKindAt(x,z) return (k == 1 or k == 2) and not sh(x, z) end end
local isStopOf = function(cls) if cls == "track" then return function(x,z) return RF.groundKindAt(x,z) == 3 or sh(x, z) end end end
RF.WALK.maxLen = 400
local r = RF.walkFrom(isRoadOf, tonumber(arg[1]), tonumber(arg[2]), { "paved" }, isStopOf)
if not r then print("nothing") return end
local P = r.pts
local sum, n, worst, lean, rows = 0, 0, 0, 0, {}
for i = 2, #P - 1 do
    local hx, hz = P[i + 1].x - P[i - 1].x, P[i + 1].z - P[i - 1].z
    local l = math.sqrt(hx * hx + hz * hz)
    local nx, nz = -hz / l, hx / l
    local best, cur = nil, nil
    for o = -4, 4, 0.25 do
        if RF.groundKindAt(P[i].x + nx * o, P[i].z + nz * o) == 3 then
            if cur then cur.hi = o else cur = { lo = o, hi = o } end
        else
            if cur and (best == nil or cur.hi - cur.lo > best.hi - best.lo) then best = cur end
            cur = nil
        end
    end
    if cur and (best == nil or cur.hi - cur.lo > best.hi - best.lo) then best = cur end
    if best and best.hi - best.lo >= 1.25 then
        local mid = (best.lo + best.hi) / 2
        sum, n, worst, lean = sum + math.abs(mid), n + 1, math.max(worst, math.abs(mid)), lean + mid
        if i % 5 == 0 then rows[#rows + 1] = string.format("(%.0f,%.0f)%+.2f", P[i].x, P[i].z, mid) end
    end
end
print(string.format("%.0f m %s..%s; off the asphalt's middle: mean %.2f, lean %+.2f, worst %.2f m over %d points", r.len, r.startTag, r.endTag, sum / math.max(1, n), lean / math.max(1, n), worst, n))
print(table.concat(rows, " "))

-- One junction for dbgtypes.lua: lock it (through paths off) and print its type, route counts and
-- the main road - each through route's two ends as compass degrees (0 = north), read where the route is
-- 25 m from the centre (so a road that loops back is read by the way it leaves, not where it ends).
local H = dofile("harness.lua")
local jp = H.lock(tonumber(arg[1]), tonumber(arg[2]), { mode = "clear", radius = 12, leaveThrough = false })
-- An already-cleared junction is refused by the clear; read it the way build sees it instead.
local cleared = false
if jp == nil and tostring(ADFlyoverEditor.junctionRefused):find("already clear") then
    jp = H.lock(tonumber(arg[1]), tonumber(arg[2]), { mode = "build", radius = 15, leaveThrough = false })
    cleared = jp ~= nil
end
local r = jp and jp.pathRoutes or {}
local c = jp and (jp._boxCentre or jp.boxCentre or jp.tracksCentre)
local function compass(w)   -- degrees clockwise from north (FS25 z grows south)
    return math.floor((180 - math.deg(math.atan2(w.x - c.x, w.z - c.z))) % 360 + 0.5)
end
local function leaving(t, from, step)
    -- walk from the node nearest the centre outward until 25 m from the centre
    for i = from, (step > 0) and #t or 1, step do
        local w = t[i]
        if (w.x - c.x) ^ 2 + (w.z - c.z) ^ 2 >= 25 * 25 then return w end
    end
    return t[(step > 0) and #t or 1]
end
local mains = {}
for _, t in ipairs(r.through or {}) do
    local k, kd = 1, math.huge
    for i, w in ipairs(t) do
        local d = (w.x - c.x) ^ 2 + (w.z - c.z) ^ 2
        if d < kd then kd, k = d, i end
    end
    local a, b = compass(leaving(t, k, -1)), compass(leaving(t, k, 1))
    if a > b then a, b = b, a end
    mains[#mains + 1] = a .. "/" .. b
    -- and where the route ends up (~60 m out): a road that bends just past 25 m (46) is named by
    -- the way it goes, not the way it leaves
    local fa, fb = compass(t[1]), compass(t[#t])
    if fa > fb then fa, fb = fb, fa end
    mains[#mains + 1] = "far" .. fa .. "/" .. fb
end
local uniq = mains
local kind = tostring(jp and ADFlyoverEditor.junctionClassify(ADFlyoverEditor, jp))
if cleared and jp._clearedMain then
    -- the classifier's bearings are atan2(dx, dz) in degrees; compass = 180 - that
    local a, b = (180 - jp._clearedMain[1]) % 360, (180 - jp._clearedMain[2]) % 360
    uniq = { string.format("%d/%d", math.floor(math.min(a, b) + 0.5), math.floor(math.max(a, b) + 0.5)) }
end
-- the measured geometry behind the branch angle: meeting point and the two directions (compass
-- degrees, 0 = north), for comparing measuring methods
local g = jp and jp._branch and jp._branch.meet
if g ~= nil then
    print(string.format("MEET %.2f %.2f main %.1f side %.1f angle %.1f", g.x, g.z, (180 - g.main) % 360, (180 - g.side) % 360, jp._branch.angle))
end
print(string.format("TYPE %s%s | %d through, %d side | branch %s | main %s", kind, cleared and " (cleared)" or "",
    #(r.through or {}), #(r.side or {}), (jp and jp._branch) and string.format("%.0f", jp._branch.angle) or "-",
    #uniq > 0 and table.concat(uniq, ",") or "none"))

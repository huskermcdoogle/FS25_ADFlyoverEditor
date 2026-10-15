-- How much of the map's own AI road lines (aiSystem.roadSplines, dumped by FlyoverRoadSplines) runs
-- where the AutoDrive network has no path? lua splinecheck.lua <roadSplines.xml>
local HERE = (arg[0]:match("^(.*)[/\]") or ".") .. "/"
local JH = os.getenv("JH") or (HERE .. "../../../junction-rework-fec884/tools/junction-harness/")
dofile(HERE .. "../../scripts/editor/RoadFinder.lua")
local RF = ADRoadFinder
local wps = dofile(os.getenv("GRAPH") or (JH .. "graph_data.lua"))
local byId = {}
for _, w in ipairs(wps) do byId[w.id] = w end
local grid = RF.indexNetwork(wps, function(id) return byId[id] end, -1100, -1100, 1100, 1100)
local f = assert(io.open(arg[1], "rb")); local xml = f:read("*a"); f:close()
local total, uncovered, n, splinesUncovered = 0, 0, 0, 0
local out = {}
for name, pts in xml:gmatch('<spline name="([^"]*)"[^>]-points="([^"]*)"') do
    local P = {}
    for x, z in pts:gmatch("(-?[%d%.]+),(-?[%d%.]+)") do P[#P + 1] = { x = tonumber(x), z = tonumber(z) } end
    n = n + 1
    local un, len = 0, 0
    for i = 2, #P do
        local a, b = P[i - 1], P[i]
        local l = math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
        len = len + l
        local hit = false
        RF.networkNear(grid, b.x, b.z, 4, function(sg)
            local sx, sz = sg.bx - sg.ax, sg.bz - sg.az
            local sl = math.sqrt(sx * sx + sz * sz)
            if sl > 0 and l > 0 and math.abs(((b.x - a.x) * sx + (b.z - a.z) * sz) / (l * sl)) > 0.8 then hit = true end
        end)
        if not hit then un = un + l end
    end
    total, uncovered = total + len, uncovered + un
    if un > 0.5 * len and len > 20 then
        splinesUncovered = splinesUncovered + 1
        out[#out + 1] = string.format("  %s %.0f m, %.0f m without a path, starts (%.0f, %.0f)", name, len, un, P[1].x, P[1].z)
    end
end
print(string.format("%d splines, %.1f km; %.1f km (%.0f%%) with no AutoDrive path within 4 m; %d splines mostly uncovered",
    n, total / 1000, uncovered / 1000, 100 * uncovered / total, splinesUncovered))
for i = 1, math.min(15, #out) do print(out[i]) end

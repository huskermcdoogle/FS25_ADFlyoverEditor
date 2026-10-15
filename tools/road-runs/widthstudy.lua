-- How wide are paved roads that already have two AutoDrive lanes, and how far apart are those lanes?
-- Feeds the lane gap rule ("from road"). lua widthstudy.lua x z [size] - prints width vs lane gap.
local HERE = (arg[0]:match("^(.*)[/\]") or ".") .. "/"
local JH = dofile(HERE .. "datadir.lua")(HERE)
local real = os.getenv
os.getenv = function(k) if k == "TERRAIN_DIR" and real(k) == nil then return JH .. "terrain_data/" end return real(k) end
g_currentMission = { terrainRootNode = 1 }
AutoDrive, CollisionFlag = {}, {}
dofile(HERE .. "terrain.lua")
dofile(HERE .. "../../scripts/editor/RoadFinder.lua")
local RF = ADRoadFinder
local wps = dofile(os.getenv("GRAPH") or (JH .. "graph_data.lua"))
local byId = {}
for _, w in ipairs(wps) do byId[w.id] = w end
local rows = {}
for i = 1, #arg - 1, 2 do
    local cx, cz, size = tonumber(arg[i]), tonumber(arg[i + 1]), 384
    local cache = RF.newCache()
    local ix0, iz0 = math.floor(cx - size / 2), math.floor(cz - size / 2)
    RF.cacheRequest(cache, ix0, iz0, ix0 + size - 1, iz0 + size - 1)
    while not RF.cacheStep(cache, 1e6) do end
    local win = RF.buildWindow(function(a, b) return RF.cacheKind(cache, a, b) end, ix0, iz0, size, size, {})
    local grid = RF.indexNetwork(wps, function(id) return byId[id] end, ix0, iz0, ix0 + size, iz0 + size)
    for _, e in ipairs(win.edges) do
        local P = e.pts
        for k = 4, #P - 3, 3 do
            local a, b = P[k - 1], P[k + 1]
            local hx, hz = b.x - a.x, b.z - a.z
            local hl = math.sqrt(hx * hx + hz * hz)
            if hl > 0 and P[k].w then
                hx, hz = hx / hl, hz / hl
                local rx, rz = -hz, hx
                local left, right = nil, nil
                RF.networkNear(grid, P[k].x, P[k].z, 7, function(sg, d, px, pz)
                    local sx, sz = sg.bx - sg.ax, sg.bz - sg.az
                    local sl = math.sqrt(sx * sx + sz * sz)
                    if sl > 0 and math.abs((sx * hx + sz * hz) / sl) > 0.95 then
                        local off = (px - P[k].x) * rx + (pz - P[k].z) * rz
                        if off > 0.5 and (right == nil or off < right) then right = off end
                        if off < -0.5 and (left == nil or off > left) then left = off end
                    end
                end)
                if left and right then rows[#rows + 1] = { e.class, P[k].w, right - left, (right + left) / 2 } end
            end
        end
    end
end
local by = {}
for _, r in ipairs(rows) do
    local b = math.floor(r[2])
    local key = r[1] .. string.format(" w%2d", b)
    by[key] = by[key] or {}
    table.insert(by[key], r)
end
local keys = {}
for k in pairs(by) do keys[#keys + 1] = k end
table.sort(keys)
print("class width-band  samples  median-lane-gap  median-centre-offset")
for _, k in ipairs(keys) do
    local L = by[k]
    local g, o = {}, {}
    for _, r in ipairs(L) do g[#g + 1] = r[3] o[#o + 1] = r[4] end
    table.sort(g) table.sort(o)
    print(string.format("%-14s %5d  %5.2f  %5.2f", k, #L, g[math.floor(#g / 2) + 1], o[math.floor(#o / 2) + 1]))
end

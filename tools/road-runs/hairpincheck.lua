-- How many of a window's road lines turn back on themselves (two roads joined at a mouth), before and
-- after the refine walk, and does RF.cutHairpins leave any?   lua hairpincheck.lua <x> <z> [size]
local HERE = (arg[0]:match("^(.*)[/\]") or ".") .. "/"
local JH = HERE .. "../../../junction-rework-fec884/tools/junction-harness/"
local real = os.getenv
os.getenv = function(k) if k == "TERRAIN_DIR" then return JH .. "terrain_data/" end return real(k) end
g_currentMission = { terrainRootNode = 1 }; AutoDrive, CollisionFlag = {}, {}
dofile(HERE .. "terrain.lua"); dofile(HERE .. "../../scripts/editor/RoadFinder.lua")
local RF = ADRoadFinder
local cx, cz, size = tonumber(arg[1]), tonumber(arg[2]), tonumber(arg[3] or "224")
local cache = RF.newCache()
local ix0, iz0 = math.floor(cx - size / 2), math.floor(cz - size / 2)
RF.cacheRequest(cache, ix0, iz0, ix0 + size - 1, iz0 + size - 1)
while not RF.cacheStep(cache, 100000) do end
local kinds = { [RF.KIND_PAVED] = true, [RF.KIND_GRAVEL] = true, [RF.KIND_DIRT] = true }
local win = RF.buildWindow(function(ix, iz) return RF.cacheKind(cache, ix, iz) end, ix0, iz0, size, size, { kinds = kinds })
local wps = dofile(JH .. "graph_data.lua"); local byId = {}; for _, w in ipairs(wps) do byId[w.id] = w end
local grid = RF.indexNetwork(wps, function(id) return byId[id] end, ix0, iz0, ix0 + size, iz0 + size)
local stretches = RF.findStretches(win, grid)
local isRoadOf = function(cls)
    if cls == "paved" then return function(x, z) return RF.groundKindAt(x, z) == RF.KIND_PAVED end end
    return function(x, z) local k = RF.groundKindAt(x, z) return k == RF.KIND_GRAVEL or k == RF.KIND_DIRT end
end
local isStopOf = function(cls) if cls == "track" then return function(x, z) return RF.groundKindAt(x, z) == RF.KIND_PAVED end end end
local function hairpins(st)
    local cut = RF.cutHairpins(st, st.pts[1].x, st.pts[1].z)
    return cut ~= st
end
local raw, ref, left = 0, 0, 0
for _, st in ipairs(stretches) do
    if hairpins(st) then raw = raw + 1 end
    local r = RF.refineStretch(st, isRoadOf, isStopOf)
    if r ~= nil and #r.pts >= 5 then
        if hairpins(r) then
            ref = ref + 1
            local P = r.pts
            print(string.format("  turn-back in a refined line from (%.0f,%.0f) to (%.0f,%.0f), %.0f m", P[1].x, P[1].z, P[#P].x, P[#P].z, r.len or 0))
            -- cut at the middle: no piece may still turn back
            local m = P[math.floor(#P / 2) + 1]
            local c = RF.cutHairpins(r, m.x, m.z)
            if RF.cutHairpins(c, m.x, m.z) ~= c then left = left + 1 end
            -- each piece through the ghost check
            for _, q in ipairs({ P[2], P[#P - 1] }) do
                local piece = RF.cutHairpins(r, q.x, q.z)
                local g = RF.trimGhosts(piece, isRoadOf(r.class), r.class, q.x, q.z)
                print(string.format("    piece from (%.0f,%.0f): %.0f m -> %s", q.x, q.z, piece.len or 0,
                    g and string.format("kept %.0f m", g.len or 0) or "GHOST, dropped"))
            end
        end
    end
end
print(string.format("%d stretches: %d turn back as read, %d after the walk; %d still turn back after the cut", #stretches, raw, ref, left))
-- the ghost check over every line in the window: how many dropped, how much trimmed
local dropped, trimmed, total = 0, 0, 0
for _, st in ipairs(stretches) do
    local r = RF.refineStretch(st, isRoadOf, isStopOf)
    if r ~= nil and #r.pts >= 3 then
        local m = st.pts[math.floor(#st.pts / 2) + 1]
        local c = RF.cutHairpins(r, m.x, m.z)
        local g = RF.trimGhosts(c, isRoadOf(r.class), r.class, m.x, m.z)
        total = total + (c.len or 0)
        if g == nil then
            dropped = dropped + 1
            print(string.format("  ghost: %s %.0f m from (%.0f,%.0f) to (%.0f,%.0f)", r.class, c.len or 0, c.pts[1].x, c.pts[1].z, c.pts[#c.pts].x, c.pts[#c.pts].z))
        elseif g ~= c then
            trimmed = trimmed + (c.len or 0) - (g.len or 0)
            print(string.format("  trimmed %s %.0f -> %.0f m near (%.0f,%.0f)", r.class, c.len or 0, g.len or 0, m.x, m.z))
        end
    end
end
print(string.format("ghost check: %d dropped, %.0f m trimmed of %.0f m", dropped, trimmed, total))

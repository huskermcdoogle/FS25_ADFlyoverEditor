-- Made-up bridges for the road finder and the lane fitting: no map data has the bridge meshes or the
-- railings, so this builds a little world in code and checks what comes out.
--   lua bridgetest.lua
-- World: a paved road (7 m) running east-west along z = 0, cut by a river from x = -30 to 30. A deck
-- spans it at 6 m up (|x| <= 30), with ground-level ramp feet from 30 to 35 m, railings along both
-- deck edges. Cases vary the deck width; one adds a wall beside the road on the ground.
local HERE = (arg[0]:match("^(.*)[/\\]") or ".") .. "/"
g_currentMission = { terrainRootNode = 1 }
function getTerrainHeightAtWorldPos() return 0 end
dofile(HERE .. "../../scripts/editor/RoadFinder.lua")
local RF = ADRoadFinder

local fails = 0
local function check(ok, what)
    print((ok and "  ok   " or "  FAIL ") .. what)
    if not ok then fails = fails + 1 end
end

local function world(deckHalf, wall)
    local W = {}
    function W.kind(x, z)
        if math.abs(z) <= 3.5 and math.abs(x) >= 30 and math.abs(x) <= 150 then return RF.KIND_PAVED end
        return RF.KIND_NONE
    end
    function W.mesh(x, z)
        if math.abs(z) <= deckHalf then
            if math.abs(x) <= 30 then return 6, true end
            if math.abs(x) <= 35 then return 0.2, false end
        end
        return nil
    end
    -- room to the first obstacle on each side of p: railings on the deck, an optional wall beside
    -- the road at z = wall (for 60 <= x <= 100) on the ground
    function W.clear(p, rx, rz)
        local function room(sx)
            for d = 0.25, 8, 0.25 do
                local x, z = p.x + sx * rx * d, p.z + sx * rz * d
                if math.abs(p.x) <= 30 and math.abs(z) >= deckHalf - 0.2 then return d - 0.25 end
                if wall ~= nil and x >= 60 and x <= 100 and z >= wall then return d - 0.25 end
            end
            return nil
        end
        return room(-1), room(1)
    end
    return W
end

local function run(name, deckHalf, mode, everywhere, wall)
    print(string.format("%s (deck %.0f m wide, %s%s)", name, deckHalf * 2, mode, everywhere and ", everywhere" or ""))
    local W = world(deckHalf, wall)
    local cache = RF.newCache(W.kind, W.mesh)
    local S = 384
    local ix0, iz0 = -S / 2, -S / 2
    RF.cacheRequest(cache, ix0, iz0, ix0 + S - 1, iz0 + S - 1)
    while not RF.cacheStep(cache, 1e6) do end
    -- the deck tiles are queued once the paint read has found a mesh: ask again
    RF.cacheRequest(cache, ix0, iz0, ix0 + S - 1, iz0 + S - 1)
    while not RF.cacheStep(cache, 1e6) do end
    local win = RF.buildWindow(function(a, b) return RF.cacheKind(cache, a, b) end, ix0, iz0, S, S,
        { deckAt = function(a, b) return RF.cacheDeck(cache, a, b) end })
    local stretches = RF.findStretches(win, nil)
    local long, deckPts, maxY = nil, 0, 0
    for _, st in ipairs(stretches) do
        if long == nil or st.len > long.len then long = st end
    end
    if long ~= nil then
        for _, p in ipairs(long.pts) do
            if p.deck then deckPts = deckPts + 1 end
            if (p.y or 0) > maxY then maxY = p.y end
        end
    end
    print(string.format("    found %d stretch(es); longest %.0f m (%s..%s), %d deck points, top %.1f m; decks joined %d",
        #stretches, long and long.len or 0, long and long.startTag or "-", long and long.endTag or "-", deckPts, maxY, win.decks or 0))
    local gap = math.max(3.3, math.min(6, (long and long.width or 7) * 0.6))
    local lanes = long and RF.planLanes(long, mode, 1, gap, 15,
        { clear = W.clear, everywhere = everywhere, rigClear = 1.8, minGap = 3.3, taper = 10 })
    if lanes ~= nil then
        local desc = {}
        for k, ln in ipairs(lanes) do
            -- the lane's offset from z = 0 at the bridge middle, if it crosses x = 0
            local at = nil
            for q = 2, #ln.pts do
                local a, b = ln.pts[q - 1], ln.pts[q]
                if (a.x <= 0 and b.x >= 0) or (a.x >= 0 and b.x <= 0) then at = a.z end
            end
            desc[#desc + 1] = string.format("%d:%s%s%s", k, ln.dual and "two-way" or "one-way",
                at and string.format(" z=%.2f mid-bridge", at) or "", string.format(" (%d pts)", #ln.pts))
        end
        print("    lanes: " .. table.concat(desc, " | ") .. string.format("; links %d, collapsed %.0f m, pulled %s, too narrow %s",
            #lanes.links, lanes.collapsed, tostring(lanes.pulled), tostring(lanes.tooNarrow)))
    end
    return long, lanes, win
end

-- lane offsets (z) where the lanes cross x = at
local function lanesAt(lanes, at)
    local zs = {}
    for _, ln in ipairs(lanes or {}) do
        for q = 2, #ln.pts do
            local a, b = ln.pts[q - 1], ln.pts[q]
            if (a.x <= at and b.x >= at) or (a.x >= at and b.x <= at) then
                local f = (at - a.x) / (b.x - a.x)
                zs[#zs + 1] = a.z + (b.z - a.z) * f
                break
            end
        end
    end
    table.sort(zs)
    return zs
end
-- a 3.0 m rig on each lane stays inside railings at +-rail (0.3 m margin)
local function rigsInside(zs, rail)
    for _, z in ipairs(zs) do if math.abs(z) + 1.8 > rail + 0.01 then return false end end
    return true
end

local st, lanes = run("wide bridge", 4.5, "lanes", false)
check(st ~= nil and st.len > 250, "one stretch carries across the bridge (deck joined to the road at both ends)")
local z = lanesAt(lanes, 0)
check(#lanes == 2 and #z == 2 and rigsInside(z, 4.3), string.format("9 m deck: two lanes, rigs inside the railings (%.2f, %.2f)", z[1] or 0, z[2] or 0))

st, lanes = run("8 m bridge", 4.0, "lanes", false)
z = lanesAt(lanes, 0)
check(#lanes == 2 and #z == 2 and lanes.pulled, "8 m deck: two lanes, moved in")
check(#z == 2 and z[2] - z[1] >= 3.25 and rigsInside(z, 3.8),
    string.format("8 m deck: lanes %.2f m apart (min 3.3), rigs inside the railings", (z[2] or 0) - (z[1] or 0)))
local zr = lanesAt(lanes, 120)
check(#zr == 2 and zr[2] - zr[1] > 4.0, string.format("8 m deck: back to %.2f m apart on the road", (zr[2] or 0) - (zr[1] or 0)))

st, lanes = run("7 m bridge", 3.5, "lanes", false)
check(lanes ~= nil and #lanes == 5 and #lanes.links == 4, "7 m deck: two lanes + rigs (6.9 m) do not fit: one two-way line over it")

st, lanes = run("narrow bridge", 2.5, "lanes", false)
check(lanes ~= nil and #lanes == 5 and #lanes.links == 4, "5 m deck: lanes, one two-way line over the bridge, lanes (4 links)")
check(lanes ~= nil and lanes.collapsed > 60 and lanes.collapsed < 110, string.format("5 m deck: the one-line part spans the bridge plus easing (%.0f m)", lanes and lanes.collapsed or 0))
z = lanesAt(lanes, 0)
check(#z == 1 and math.abs(z[1]) < 0.6, "5 m deck: the line runs down the middle")

st, lanes = run("narrow bridge, two-way", 2.5, "two", false)
check(lanes ~= nil and #lanes == 1 and lanes[1].dual, "5 m deck, two-way mode: one line")

st, lanes = run("wall beside the road", 4.5, "lanes", true, 3.0)
z = lanesAt(lanes, 80)
check(#z == 2 and z[2] + 1.8 <= 3.0 + 0.01, string.format("a wall 3.0 m off the centre: the lane beside it comes in (%.2f)", z[2] or 0))
st, lanes = run("wall, bridges only", 4.5, "lanes", false, 3.0)
z = lanesAt(lanes, 80)
check(#z == 2 and z[2] > 1.5, string.format("the same wall is ignored when fitting is bridges only (%.2f)", z[2] or 0))

print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))

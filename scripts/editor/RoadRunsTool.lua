--[[
Road runs tool: lays AutoDrive runs along map roads and farm tracks that have no path yet.

  hover         the road under the mouse lights up, fork to fork (RoadFinder.lua finds the roads)
  click         adds that stretch to the pick (click a picked one again to drop it)
  double-click  the whole road: carries straight on through forks while the road does
  right-click   builds every picked stretch - one undo takes it all back

The card picks how the lanes are laid (auto, one-way, two-way, two lanes), primary or secondary,
which kinds of road to find (paved, gravel, dirt), whether everything nearby lights up faintly, the
lane gap and the gap left at forks for the junction tool. Where a picked road runs straight into an
existing AutoDrive path it joins it; at forks it stops short.

The ground is read in a square window round the mouse, a few thousand spots per frame, and the road
lines are worked out in a coroutine where the engine has one (FS25 does not: there in one go, per window). The window follows the
mouse; picks are kept as their own copies, so they survive the window moving.

Loaded after FlyoverEditor.lua (it adds to ADFlyoverEditor), see Prelude.EDITOR_FILES.
]]

local RF = ADRoadFinder
local E = ADFlyoverEditor

E.TOOL.ROADRUNS = 16
E.TOOL_NAMES[E.TOOL.ROADRUNS] = "road runs"

E.ROADRUNS_WINDOW = (coroutine ~= nil and coroutine.create ~= nil) and 288 or 224            -- metres a side of the ground read round the mouse
E.ROADRUNS_RECENTRE = (coroutine ~= nil and coroutine.create ~= nil) and 72 or 56           -- the window moves when the mouse is this far from its middle
E.ROADRUNS_SNAP = 32               -- window centres snap to this grid, so a small wobble re-uses it
E.ROADRUNS_SAMPLES_PER_FRAME = 4000 -- cap; reads stop sooner once the frame's time slice is used
E.ROADRUNS_RIG_MARGIN = 0.3        -- clearance kept beyond a rig's own width: to the other lane, to a railing
E.ROADRUNS_PROBE_REACH = 6         -- how far out from the centre line the side check looks
E.ROADRUNS_TAPER = 12              -- metres over which a lane eases in or out round a narrow part
E.ROADRUNS_JOIN_SIDE = 2           -- a path to join lies no further than this off the run's line
E.ROADRUNS_JOIN_RADIUS = 10        -- how far a run's end looks for an existing path to join
E.ROADRUNS_MODE_NAMES = { "auto", "one-way", "two-way", "two lanes" }
E.ROADRUNS_MODE_KEYS = { "auto", "one", "two", "lanes" }

-- the tool's own sticky settings (session only for now)
E.roadMode = 1                     -- index into ROADRUNS_MODE_NAMES
E.roadSubPrio = false
E.roadKinds = { [RF.KIND_PAVED] = true, [RF.KIND_GRAVEL] = true, [RF.KIND_DIRT] = true }
E.roadShowAll = true               -- light up every unpathed road nearby, faintly
E.roadGapAuto = true               -- lane gap from the road's width
E.roadLaneGap = 4.0
E.roadForkGap = 7.5                -- room left at forks; the junction tool's clear trims or extends to its own box
E.roadRigWidth = 3.0               -- the widest rig the lanes must pass; sets the minimum lane gap and side room
E.roadFitEverywhere = false        -- the side check on every road, not only bridges and ramps
-- Detection view (2026-10-13, the user: "a tool that just focuses on detection methods and overlay the
-- different layers"): instead of the lane preview, the ground under the mouse is drawn layer by layer,
-- flat on the ground, so what the tool reads can be checked against what is there. Not saved.
E.roadView = false
E.roadLayers = { paint = true, read = true, lines = true, splines = true }
E.roadPaint = false                -- detection view: left-drag paints squares to save (no picking)
E.ROADVIEW_TILE = 8                -- painted squares (m)
E.ROADVIEW_BRUSH = 6               -- the brush reaches this far round the mouse (m)
E.ROADVIEW_HALF = 15               -- the paint layer covers this far round the mouse (m)
E.ROADVIEW_STEP = 0.5              -- one paint mark per this (m)
-- Test cases (2026-10-14, the user: "a multipoint spline draw tool, and I can then draw the center
-- nicely"): in the detection view, click points along a track's true middle; a smooth curve runs
-- through them. 'save track' writes the ground along the curve (ROADCASE_HALF each side) and the
-- curve itself - the answer key - to modSettings/FS25_ADFlyoverEditor/roadCases/track_N.xml.
-- tools/road-runs/scorecases.lua scores the walk against every saved case.
E.roadDrawMid = false              -- detection view: clicks place middle points (no picking)
E.ROADCASE_HALF = 12               -- ground saved this far each side of the middle (m)
E.ROADCASE_GRAB = 1.5              -- a click this close to a point grabs it (m)
E.ROADCASE_MAX_TILES = 3000        -- about 1.5 km of track; more freezes the game too long
E.ROADVIEW_WHY = {                 -- the colour of a reading left out, by why
    none = { 0.35, 0.35, 0.35 },   -- no road band found across here
    junction = { 0.75, 0.3, 1 },   -- held out: a junction the walk went through
    wide = { 1, 0.55, 0.1 },       -- much wider than the road usually is: a mouth or a patch beside it
    jumped = { 1, 0.15, 0.15 },    -- too far from where the line was: the filter did not trust it
}

-- The card's choices persist in ADFlyoverSettings (Settings.lua, roadRuns*): read once when the tool is
-- first used, written whenever one changes.
local SAVED = {
    { "roadRunsMode", "roadMode" }, { "roadRunsLaneGap", "roadLaneGap" }, { "roadRunsRigWidth", "roadRigWidth" },
    { "roadRunsForkGapM", "roadForkGap" },
}
local SAVED_FLAGS = {
    { "roadRunsSubPrio", "roadSubPrio" }, { "roadRunsShowAll", "roadShowAll" }, { "roadRunsGapAuto", "roadGapAuto" },
    { "roadRunsFitEverywhere", "roadFitEverywhere" },
}
local SAVED_KINDS = { { "roadRunsPaved", RF.KIND_PAVED }, { "roadRunsGravel", RF.KIND_GRAVEL }, { "roadRunsDirt", RF.KIND_DIRT } }

function E:roadRunsLoadSettings()
    local S = ADFlyoverSettings
    if S == nil or S.settings == nil then return end
    for _, k in ipairs(SAVED) do
        local v = S.settings[k[1]] ~= nil and S.get(k[1]) or nil
        if type(v) == "number" then self[k[2]] = v end
    end
    self.roadMode = math.floor((self.roadMode or 1) + 0.5)
    for _, k in ipairs(SAVED_FLAGS) do
        local v = S.settings[k[1]] ~= nil and S.get(k[1]) or nil
        if type(v) == "number" then self[k[2]] = v >= 0.5 end
    end
    for _, k in ipairs(SAVED_KINDS) do
        local v = S.settings[k[1]] ~= nil and S.get(k[1]) or nil
        if type(v) == "number" then self.roadKinds[k[2]] = v >= 0.5 end
    end
end

function E:roadRunsSaveSettings()
    local S = ADFlyoverSettings
    if S == nil or S.settings == nil or S.save == nil then return end
    local function put(name, v)
        local st = S.settings[name]
        if st ~= nil and st.range ~= nil then st.value = math.max(st.range.min, math.min(st.range.max, v)) end
    end
    for _, k in ipairs(SAVED) do put(k[1], self[k[2]]) end
    for _, k in ipairs(SAVED_FLAGS) do put(k[1], self[k[2]] and 1 or 0) end
    for _, k in ipairs(SAVED_KINDS) do put(k[1], self.roadKinds[k[2]] and 1 or 0) end
    pcall(S.save)
end

local function roadState(self)
    if not self.roadRunsLoaded then
        -- before anything reads or changes a setting, so a change is never overwritten by the load
        self.roadRunsLoaded = true
        self:roadRunsLoadSettings()
    end
    local s = self.roadRuns
    if s == nil then
        s = { cache = nil, win = nil, stretches = {}, picks = {}, job = nil, jobKey = nil,
            centreX = nil, centreZ = nil, netKey = nil, grid = nil, mapGap = nil, progress = 1 }
        self.roadRuns = s
    end
    if s.cache == nil then s.cache = RF.newCache() end
    return s
end

local function kindsKey(k)
    return (k[RF.KIND_PAVED] and "p" or "") .. (k[RF.KIND_GRAVEL] and "g" or "") .. (k[RF.KIND_DIRT] and "d" or "")
end

--- The lay-as mode for one stretch: "auto" lays two lanes on paved roads and one two-way line on
--- farm tracks, which is how the map's own network is mostly built.
function E:roadModeFor(st)
    local key = self.ROADRUNS_MODE_KEYS[self.roadMode] or "auto"
    if key == "auto" then
        -- two lanes only on a paved road wide enough for two rigs side by side; else one two-way line
        -- (the map's own two-lane roads start about 5 m wide in paint: widthstudy.lua)
        if st ~= nil and st.class == "paved" and (st.width == nil or st.width >= self:roadMinGap() + 1.2) then
            return "lanes"
        end
        return "two"
    end
    return key
end

--- Lane centre gap for a stretch. From the road: 0.6 x its width - what the map's own two-lane roads
--- measure (Riverbend, 2026-10-12, tools/road-runs/widthstudy.lua: roads 5-7 m wide carry lanes
--- 3.75-3.9 m apart, 9 m roads 5.2 m, and our centre line sits within 0.1 m of the middle between
--- them). Set: the typed value. Never under the minimum two big rigs need to pass.
E.ROADRUNS_GAP_PER_WIDTH = 0.6
E.ROADRUNS_MAX_LANE_GAP = 6
function E:roadGapFor(st)
    local gap = self.roadLaneGap
    if self.roadGapAuto and st ~= nil and st.width ~= nil then
        gap = math.min(self.ROADRUNS_MAX_LANE_GAP, st.width * self.ROADRUNS_GAP_PER_WIDTH)
    end
    return math.max(self:roadMinGap(), gap)
end

--- The least two lanes may be apart: two rigs of the set width side by side, plus the margin.
function E:roadMinGap()
    return self.roadRigWidth + self.ROADRUNS_RIG_MARGIN
end

function E:roadRunsReset()
    local s = self.roadRuns
    if s ~= nil then
        s.picks = {}
        s.hover = nil
        s.lastClick = nil
    end
end

-- ---------------------------------------------------------------------------------------------
-- reading the ground and finding the roads

-- Colours for the 3D lines and spheres are authored in sRGB (as a colour picker shows them); the
-- engine takes LINEAR light, so they are converted here - passed straight through, the display's
-- gamma lifts every value and the colours read washed out (2026-10-14 user; Theme.lua does the same
-- for the HUD). Every draw call in this file goes through Draw.
local function srgbToLinear(v)
    if v == nil then return nil end
    if v <= 0.04045 then return v / 12.92 end
    return ((v + 0.055) / 1.055) ^ 2.4
end
local Draw = {}
function Draw:addLineTask(x1, y1, z1, x2, y2, z2, w, r, g, b)
    ADDrawingManager:addLineTask(x1, y1, z1, x2, y2, z2, w, srgbToLinear(r), srgbToLinear(g), srgbToLinear(b))
end
function Draw:addSphereTask(x, y, z, size, r, g, b, glow)
    ADDrawingManager:addSphereTask(x, y, z, size, srgbToLinear(r), srgbToLinear(g), srgbToLinear(b), glow)
end

local function terrainY(x, z)
    local terrain = g_currentMission ~= nil and g_currentMission.terrainRootNode or nil
    if terrain == nil or not RF.onMap(x, z) then return 0 end
    return getTerrainHeightAtWorldPos(terrain, x, 0, z) or 0
end

-- A number the engine can take: not nil, not NaN, not infinite. A NaN handed to a draw, probe or
-- waypoint call can take the whole game down rather than raise a Lua error.
local function finite(v) return type(v) == "number" and v == v and v > -1e7 and v < 1e7 end
E.roadRunsFinite = finite

--- Heights filled in from the terrain where missing, and any point that is not a real position
--- dropped (in place, so cached lanes stay clean).
local function withHeights(pts)
    local bad = false
    for _, p in ipairs(pts) do
        if p.y == nil then p.y = terrainY(p.x, p.z) end
        if not (finite(p.x) and finite(p.z) and finite(p.y)) then bad = true end
    end
    if bad then
        local n = 0
        for i = 1, #pts do
            local p = pts[i]
            pts[i] = nil
            if finite(p.x) and finite(p.z) and finite(p.y) then n = n + 1 pts[n] = p end
        end
        ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - dropped points with no real position (NaN) from a lane.")
    end
    return pts
end

--- The AutoDrive network and the picked centre lines, indexed over the window - what "already has a
--- path" is measured against.
function E:roadRunsIndex(s)
    local win = s.win
    if win == nil then return nil end
    local wps = ADGraphManager:getWayPoints()
    local x0, z0 = win.ix0 - 10, win.iz0 - 10
    local x1, z1 = win.ix0 + win.W + 10, win.iz0 + win.H + 10
    local grid = RF.indexNetwork(wps, function(id) return ADGraphManager:getWayPointById(id) end, x0, z0, x1, z1)
    -- picked stretches count as covered, so the same road is never offered twice
    for _, pk in ipairs(s.picks) do
        local P = pk.st.pts
        local pseudo = {}
        for i = 1, #P do pseudo[i] = { x = P[i].x, z = P[i].z, out = {} } end
        for i = 1, #P - 1 do pseudo[i].out[1] = pseudo[i + 1] end
        local extra = RF.indexNetwork(pseudo, function() return nil end, x0, z0, x1, z1)
        for _, sg in ipairs(extra.segs) do
            sg.picked = true
            grid.segs[#grid.segs + 1] = sg
        end
        for k, list in pairs(extra.cells) do
            local into = grid.cells[k]
            if into == nil then grid.cells[k] = list else
                for _, sg in ipairs(list) do into[#into + 1] = sg end
            end
        end
    end
    s.mapGap = RF.networkLaneGap(grid)
    return grid
end

--- Recompute which parts of the window's roads are uncovered (cheap: a few ms).
function E:roadRunsRefreshStretches()
    local s = roadState(self)
    if s.win == nil then return end
    s.grid = self:roadRunsIndex(s)
    local list = RF.findStretches(s.win, s.grid)
    local kept = {}
    for _, st in ipairs(list) do
        if self.roadKinds[st.kind] then
            withHeights(st.pts)
            st.id = string.format("%d:%d:%d", math.floor(st.pts[1].x), math.floor(st.pts[1].z), #st.pts)
            kept[#kept + 1] = st
        end
    end
    s.stretches = kept
    s.hover = nil
    s.walked = nil
    s.splineHover = nil
end

--- What is under the mouse: a stretch with no path, or a picked one. Works on whatever stretches the
--- last finished read found, so it keeps working while the window is being read again.
function E:roadRunsHover(overPanel)
    local s = roadState(self)
    local cx, cz = self.cursorX, self.cursorZ
    s.hoverPick = nil
    if overPanel then
        s.hover = nil
        return
    end
    -- on the selected run's handles or line, a click shapes it: no new road lights up
    if s.sel ~= nil and (s.handleDrag ~= nil or s.handleHover ~= nil or self:roadRunsHandlePiece() ~= nil) then
        s.hover = nil
        s.hoverPick = s.sel
        return
    end
    -- over a picked stretch? (a click there drops it)
    local best, bd = nil, math.huge
    for _, pk in ipairs(s.picks) do
        local p, d = RF.stretchNear({ pk.st }, cx, cz, 3)
        if p ~= nil and d < bd then best, bd = pk, d end
    end
    if best ~= nil then
        s.hoverPick = best
        s.hover = nil
        return
    end
    -- The road under the mouse: walked from the mouse first (it follows the road's own middle, round
    -- corners, and stops at junctions - 2026-10-12: on a ragged old lane the square read gave chunks
    -- joined off the centre line, the walk kept within ~0.5 m of the old path). The square's stretches
    -- are the fallback.
    local st = self:roadRunsSplineAtCursor(cx, cz)
    -- on a road the map maker drew, walk it anyway (not shown) so the log scores the walker against it
    if st ~= nil and st ~= s.hover then self:roadRunsWalkAtCursor(cx, cz) end
    if st == nil then st = self:roadRunsWalkAtCursor(cx, cz) end
    if st == nil then
        st = RF.stretchNear(s.stretches, cx, cz, 3)
        -- a line that turns back on itself is two roads: keep the one under the mouse
        if st ~= nil then st = RF.cutHairpins(st, cx, cz) end
        -- a square line the walk can hardly read as road (under 30% of its cross-sections) is a
        -- phantom - a kerb, a patch's edge - and is not offered
        if st ~= nil then
            local r = self:roadRunsRefined(st)
            if st.ghost or (r ~= nil and r.walk ~= nil and r.walk.read < 0.3 * r.walk.sections) then st = nil end
        end
    end
    s.hover = st
    if st ~= nil then s.hoverSide = RF.sideOf(st, cx, cz) end
    -- the last spot on the map (the card's "save this area" is pressed with the mouse on the card)
    if cx ~= nil then s.lastMap = { x = cx, z = cz, hover = st } end
end

-- ---------------------------------------------------------------------------------------------
-- the map's own road lines (AI splines)

-- The map maker's road splines (the game's AI road network: farm ways like "dirtwaysSawmillTwoDirections",
-- "fieldsNorthTwoDirections", and the traffic lanes) are the exact middle of the road where they exist:
-- the old lane's spline993 runs within 0.3-1.4 m of its old AutoDrive path the whole 327 m (2026-10-13).
-- A two-way farm way is a spline and its reversed twin ("993" and "993R") on the same line; those are
-- used as centre lines. Traffic lanes (one per direction, a lane apart) are left to the ground reading.
E.ROADRUNS_SPLINE_REACH = 4            -- the mouse within this of a spline picks it
E.ROADRUNS_SPLINE_PATH_END = 10      -- an existing path this close to a line's end: the run joins it there
E.ROADRUNS_SPLINE_JUNCTION = 15        -- another spline's end or line this close to an end: a junction

local function splineRoot()
    local terrain = g_currentMission ~= nil and g_currentMission.terrainRootNode or nil
    if terrain == nil or getParent == nil then return nil end
    return getParent(terrain)
end

--- The map's splines, sampled every 2 m, indexed in 32 m squares. Read once.
function E:roadRunsSplines()
    if self.roadRunsSplineOverride ~= nil then return self.roadRunsSplineOverride end
    local s = roadState(self)
    if s.splines ~= nil then return s.splines end
    local list = {}
    local nodes = {}
    local ai = g_currentMission ~= nil and g_currentMission.aiSystem or nil
    if ai ~= nil and type(ai.roadSplines) == "table" and #ai.roadSplines > 0 then
        for _, sp in ipairs(ai.roadSplines) do nodes[#nodes + 1] = sp end
    else
        -- not the host (the game fills its list there only): look for the map's "splines" group
        local root = splineRoot()
        if root ~= nil and I3DUtil ~= nil and I3DUtil.iterateRecursively ~= nil then
            pcall(I3DUtil.iterateRecursively, root, function(node)
                if getName(node) == "splines" then
                    I3DUtil.iterateRecursively(node, function(sub)
                        if I3DUtil.getIsSpline(sub) then nodes[#nodes + 1] = sub end
                    end, true)
                end
            end, true)
        end
    end
    for _, sp in ipairs(nodes) do
        local ok, len = pcall(getSplineLength, sp)
        if ok and type(len) == "number" and len > 4 then
            local P, k = {}, math.max(2, math.floor(len / 2))
            for i = 0, k do
                local x, y, z = getSplinePosition(sp, i / k)
                if x ~= nil then P[#P + 1] = { x = x, y = y, z = z } end
            end
            local parent = getParent(sp)
            list[#list + 1] = { node = sp, name = tostring(getName(sp) or ""), group = parent and tostring(getName(parent) or "") or "",
                pts = P, len = len }
        end
    end
    s.splines = RF.indexSplines(list)
    ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - read %d map road spline(s), %d usable as centre lines.",
        #list, #s.splines.centre)
    return s.splines
end

--- A map spline under the mouse with no AutoDrive path along it, as a stretch; nil if none.
function E:roadRunsSplineAtCursor(cx, cz)
    local S = self:roadRunsSplines()
    if S == nil or #S.centre == 0 then return nil end
    local s = roadState(self)
    local sp = RF.splineNear(S, cx, cz, self.ROADRUNS_SPLINE_REACH)
    if sp == nil then return nil end
    if s.splineHover ~= nil and s.splineHover.src == sp then return s.splineHover end
    local st = RF.splineStretch(S, sp, self.ROADRUNS_SPLINE_JUNCTION)
    local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(st.pts) do
        x0, z0, x1, z1 = math.min(x0, p.x), math.min(z0, p.z), math.max(x1, p.x), math.max(z1, p.z)
    end
    local grid = RF.indexNetwork(ADGraphManager:getWayPoints(), function(id) return ADGraphManager:getWayPointById(id) end,
        x0 - 10, z0 - 10, x1 + 10, z1 + 10)
    for _, pk in ipairs(s.picks) do
        local P = pk.st.pts
        local pseudo = {}
        for i = 1, #P do pseudo[i] = { x = P[i].x, z = P[i].z, out = {} } end
        for i = 1, #P - 1 do pseudo[i].out[1] = pseudo[i + 1] end
        local extra = RF.indexNetwork(pseudo, function() return nil end, x0 - 10, z0 - 10, x1 + 10, z1 + 10)
        for k, l in pairs(extra.cells) do
            local into = grid.cells[k]
            if into == nil then grid.cells[k] = l else for _, sg in ipairs(l) do into[#into + 1] = sg end end
        end
    end
    -- the uncovered run nearest the mouse
    local cut = RF.keepUncoveredNear(st, grid, cx, cz)
    if cut == nil or #cut.pts < 3 then return nil end
    -- an end where the map's lines meet but an existing path is right there: the road runs into that
    -- path, so it joins it rather than stopping short (2026-10-13: the old lane's south end, where the
    -- path carries on, was left 7.5 m short and joined by hand)
    for _, e in ipairs({ { tag = "startTag", node = "startNode", p = cut.pts[1] }, { tag = "endTag", node = "endNode", p = cut.pts[#cut.pts] } }) do
        if cut[e.tag] ~= "path" then
            local near = false
            RF.networkNear(grid, e.p.x, e.p.z, self.ROADRUNS_SPLINE_PATH_END, function() near = true end)
            if near then cut[e.tag], cut[e.node] = "path", nil end
        end
    end
    local k = RF.groundKindAt(cut.pts[math.floor(#cut.pts / 2) + 1].x, cut.pts[math.floor(#cut.pts / 2) + 1].z)
    cut.class = (k == RF.KIND_PAVED) and "paved" or "track"
    cut.kind = (k ~= RF.KIND_NONE) and k or RF.KIND_DIRT
    cut.width = cut.width or 4
    withHeights(cut.pts)
    cut.id = "spline:" .. sp.name
    cut.refinedTo, cut.fromSpline, cut.src = cut, true, sp
    s.splineHover = cut
    ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - the map's road line %s (%s) under the mouse: %.0f m with no path (%s to %s).",
        sp.name, sp.group, cut.len or 0, cut.startTag, cut.endTag)
    return cut
end

--- The road under the mouse, walked from the mouse (RF.walkFrom), for roads the square read missed
--- (user 2026-10-12: "this should be an easy one" - point at a road, get the road). Up to 400 m each
--- way, stopping at forks, paved/track changes and the road's end, cut at the first AutoDrive path.
--- Tried again only when the mouse has moved off the last result, at most four times a second.
E.ROADRUNS_POINT_WALK = 400
E.ROADRUNS_COVER_REACH = 2.5        -- a path this close along the road: the walk has run onto it

--- One index of the whole network plus the picks (they count as covered too), kept a few seconds.
function E:roadRunsCoverGrid()
    local s = roadState(self)
    local now = self:nowMs()
    local wps = ADGraphManager:getWayPoints()
    local key = tostring(#s.picks) .. ":" .. tostring(s.builds or 0) .. ":" .. tostring(wps ~= nil and #wps or 0)
    local c = s.coverGrid
    if c ~= nil and c.key == key and now - c.at < 5000 then return c.grid end
    local H = RF.mapHalf() or 1100
    local grid = RF.indexNetwork(wps, function(id) return ADGraphManager:getWayPointById(id) end, -H, -H, H, H)
    for _, pk in ipairs(s.picks) do
        local P = pk.st.pts
        local pseudo = {}
        for i = 1, #P do pseudo[i] = { x = P[i].x, z = P[i].z, out = {} } end
        for i = 1, #P - 1 do pseudo[i].out[1] = pseudo[i + 1] end
        local extra = RF.indexNetwork(pseudo, function() return nil end, -H, -H, H, H)
        for k, list in pairs(extra.cells) do
            local into = grid.cells[k]
            if into == nil then grid.cells[k] = list else for _, sg in ipairs(list) do into[#into + 1] = sg end end
        end
    end
    s.coverGrid = { key = key, at = now, grid = grid }
    return grid
end

--- RF.walkFrom with the hover walk's limits: at most ROADRUNS_POINT_WALK each way, and ending where
--- it runs onto an existing path or a pick.
function E:roadRunsWalkFrom(isRoadOf, x, z, classes, isStopOf)
    local grid = self:roadRunsCoverGrid()
    local reach = self.ROADRUNS_COVER_REACH
    local keepLen, keepCov = RF.WALK.maxLen, RF.walkCovered
    RF.WALK.maxLen = self.ROADRUNS_POINT_WALK
    RF.walkCovered = function(px, pz, hx, hz) return RF.coveredHere(grid, px, pz, hx, hz, reach) end
    local ok, r = pcall(RF.walkFrom, isRoadOf, x, z, classes, isStopOf)
    RF.WALK.maxLen, RF.walkCovered = keepLen, keepCov
    if not ok then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - walking from (%.1f, %.1f) failed: %s", x, z, tostring(r))
        return nil
    end
    return r
end

--- One walk of the road at (cx, cz), as the tool lays it: walked, cut to the uncovered part, hairpins,
--- hooks and ghosts trimmed. nil if there is no road there. No caching, no log.
function E:roadRunsWalkLine(cx, cz)
    local classes = {}
    if self.roadKinds[RF.KIND_PAVED] then classes[#classes + 1] = "paved" end
    if self.roadKinds[RF.KIND_GRAVEL] or self.roadKinds[RF.KIND_DIRT] then classes[#classes + 1] = "track" end
    local isRoadOf, isStopOf = self:roadRunsWalkTests()
    local r = self:roadRunsWalkFrom(isRoadOf, cx, cz, classes, isStopOf)
    if r == nil or #r.pts < 4 then return nil end
    local grid = self:roadRunsCoverGrid()
    r = RF.keepUncovered(r, grid)
    if r ~= nil then r = RF.cutHairpins(r, cx, cz) end
    if r ~= nil then r = RF.cutEndHooks(r, function(x, z) return E.roadRunsKindAt(x, z) == RF.KIND_PAVED end) end
    if r ~= nil then r = RF.trimGhosts(r, isRoadOf(r.class), r.class, cx, cz) end
    if r == nil or #r.pts < 4 then return nil end
    local k = RF.groundKindAt(cx, cz)
    if r.class == "paved" then r.kind = RF.KIND_PAVED
    elseif k == RF.KIND_DIRT or k == RF.KIND_GRAVEL then r.kind = k
    else r.kind = RF.KIND_GRAVEL end
    withHeights(r.pts)
    r.id = string.format("walk:%d:%d", math.floor(r.pts[1].x), math.floor(r.pts[1].z))
    r.refinedTo = r
    r.pointWalk = true
    return r
end

--- The road under the mouse for hovering: a road already voted on (a click) is shown as voted;
--- otherwise one quick walk (kept while the mouse stays on it).
function E:roadRunsWalkAtCursor(cx, cz)
    local s = roadState(self)
    local voted = self:roadRunsVotedAt(cx, cz)
    if voted ~= nil then return voted end
    local w = s.walked
    if w ~= nil and RF.stretchNear({ w }, cx, cz, 3) ~= nil then return w end
    local now = self:nowMs()
    local last = s.walkTry
    if last ~= nil and now - last.at < 250 and math.abs(cx - last.x) < 1.5 and math.abs(cz - last.z) < 1.5 then
        return nil
    end
    s.walkTry = { at = now, x = cx, z = cz }
    local r = self:roadRunsWalkLine(cx, cz)
    s.walked = r
    if r == nil then return nil end
    local mi = math.max(1, math.floor(#r.pts / 2))
    ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - walked a %s road from the mouse at (%.1f, %.1f): %.0f m, %.1f m wide (%s to %s); across its middle (%.1f, %.1f): %s",
        r.class, cx, cz, r.len or 0, r.width or -1, r.startTag, r.endTag, r.pts[mi].x, r.pts[mi].z,
        RF.crossText(E.roadRunsKindAt, r.pts, mi, E.roadRunsFieldAt))
    -- where the map maker drew this road, score the walk against it (+ = right of the way it walks)
    local S = self:roadRunsSplines()
    local sc = (S ~= nil and #S.centre > 0) and RF.splineScore(S, r.pts, 4) or nil
    if sc ~= nil then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - walk vs the map's line %s: leans %+.2f m (+ = right), off %.2f m on average, worst %.2f m, over %d of %d points.",
            sc.sp.name, sc.lean, sc.mean, sc.worst, sc.n, #r.pts)
    end
    return r
end

--- A road voted on earlier (a click) under (cx, cz), while the network is as it was then.
function E:roadRunsVotedAt(cx, cz)
    local s = roadState(self)
    if s.voted == nil then return nil end
    local key = s.coverGrid and s.coverGrid.key or nil
    for _, v in ipairs(s.voted) do
        if v.key == key and RF.stretchNear({ v.st }, cx, cz, 3) ~= nil then return v.st end
    end
    return nil
end

--- Vote on the road at (cx, cz): walked from the mouse and from five spots along it, the majority
--- line kept (RF.voteWalk). Remembered, so hovering it again shows the same line.
function E:roadRunsVote(cx, cz)
    local s = roadState(self)
    local walks = 0
    local st = RF.voteWalk(function(x, z) walks = walks + 1 return self:roadRunsWalkLine(x, z) end, cx, cz)
    if st == nil then return nil end
    withHeights(st.pts)
    st.pointWalk = true
    st.refinedTo = st
    st.id = string.format("vote:%d:%d", math.floor(st.pts[1].x), math.floor(st.pts[1].z))
    s.voted = s.voted or {}
    self:roadRunsCoverGrid()
    table.insert(s.voted, 1, { st = st, key = s.coverGrid and s.coverGrid.key or nil })
    while #s.voted > 20 do table.remove(s.voted) end
    local v = st.votes or {}
    ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - voted: %d walk(s), %s; %.0f m kept (%s to %s)%s%s.",
        v.walks or walks, v.need and string.format("%d needed to agree", v.need) or "too few to vote",
        st.len or 0, st.startTag, st.endTag, v.cutStart and "; cut at the start where the walks split" or "",
        v.cutEnd and "; cut at the end where the walks split" or "")
    return st
end

-- ---------------------------------------------------------------------------------------------
-- shaping a picked run with handles (2026-10-14 user: "tool drops it close, then the user can massage
-- into place"). Only the SELECTED pick shows handles: a new pick is selected; a click on another
-- pick selects it; a click on empty ground clears the selection. Drag a handle to shape the run (the
-- curve is the multi-point spline's, ADSplinePath); click on the selected run's line to add a handle;
-- Ctrl-click a handle to remove it; an end handle snaps onto a waypoint right under the mouse (Alt
-- held: never). Build lays the shaped line.

E.ROADRUNS_HANDLE_TOL = 0.3          -- handles: as few as keep the picked line within this (m)

--- Handles for a pick: the ends, and as few between as keep its line within ROADRUNS_HANDLE_TOL.
function E:roadRunsMakeHandles(pk)
    local P = pk.st.pts
    local S = RF.simplifyLine(P, self.ROADRUNS_HANDLE_TOL)
    local H = {}
    for _, q in ipairs(S) do H[#H + 1] = { x = q.x, y = q.y, z = q.z } end
    if #H < 2 then H = { { x = P[1].x, y = P[1].y, z = P[1].z }, { x = P[#P].x, y = P[#P].y, z = P[#P].z } } end
    pk.handles = H
    pk.orig = pk.orig or pk.st
    self:roadRunsHandleCurve(pk)
end

--- The curve through a pick's handles (ADSplinePath), with snapped ends following their roads.
function E:roadRunsHandleCurve(pk)
    local H = pk.handles
    local startDir, endDir = nil, nil
    local function node(h)
        if h.wpId == nil then return nil end
        local wp = ADGraphManager:getWayPointById(h.wpId)
        if wp ~= nil and math.abs(wp.x - h.x) < 0.05 and math.abs(wp.z - h.z) < 0.05 then return wp end
        h.wpId = nil
        return nil
    end
    local a, b = node(H[1]), node(H[#H])
    if a ~= nil and self.splineRoadHeading ~= nil then startDir = self:splineRoadHeading(a, H[2].x, H[2].z) end
    if b ~= nil and self.splineRoadHeading ~= nil then
        local hd = self:splineRoadHeading(b, 2 * b.x - H[#H - 1].x, 2 * b.z - H[#H - 1].z)
        if hd ~= nil then endDir = hd end
    end
    pk.curve = ADSplinePath ~= nil and ADSplinePath.build(H, startDir, endDir) or nil
end

--- After an edit: the pick's line is laid along its handles' curve, 2 m apart. A moved end is a plain
--- end (no junction gap); one snapped onto a waypoint joins it.
function E:roadRunsApplyHandles(pk, movedStart, movedEnd)
    self:roadRunsHandleCurve(pk)
    local H, C = pk.handles, pk.curve
    if C == nil or #H < 2 then return end
    local pts = { { x = H[1].x, z = H[1].z, y = H[1].y } }
    for _, q in ipairs(ADSplinePath.resample(C, 2)) do pts[#pts + 1] = { x = q.x, z = q.z, y = q.y } end
    pts[#pts + 1] = { x = H[#H].x, z = H[#H].z, y = H[#H].y }
    for _, q in ipairs(pts) do q.y = nil end
    withHeights(pts)
    local st = {}
    for k, v in pairs(pk.st) do st[k] = v end
    -- nothing worked out for the old line carries over (the lanes were cached ON the stretch, and the
    -- build laid the line from before the edit - 2026-10-14)
    st.laneCache, st.hairpinPieces, st.debug, st.walk, st.raw = nil, nil, nil, nil, nil
    st.pts, st.refinedTo, st.edited = pts, nil, true
    st.refinedTo = st
    local len = 0
    for i = 2, #pts do len = len + math.sqrt((pts[i].x - pts[i - 1].x) ^ 2 + (pts[i].z - pts[i - 1].z) ^ 2) end
    st.len = len
    E.roadRunsEditSerial = (E.roadRunsEditSerial or 0) + 1
    st.id = string.format("edit:%d", E.roadRunsEditSerial)      -- every shaped version its own (lanes are cached by id)
    if movedStart or H[1].wpId ~= nil then
        st.startTag, st.startNode, st.joinStart = "end", nil, H[1].wpId
    end
    if movedEnd or H[#H].wpId ~= nil then
        st.endTag, st.endNode, st.joinEnd = "end", nil, H[#H].wpId
    end
    pk.st = st
end

--- The selected pick's handle under the mouse (screen distance, as spline points), or nil.
function E:roadRunsHandleAtCursor()
    local s = roadState(self)
    local pk = s.sel
    if pk == nil or pk.handles == nil or self.cursorX == nil then return nil end
    local best, bestD = nil, nil
    if project ~= nil and g_lastMousePosX ~= nil and g_lastMousePosY ~= nil then
        bestD = AutoDrive.FLYOVER_PICK_SCREEN_RADIUS * AutoDrive.FLYOVER_PICK_SCREEN_RADIUS
        for i, h in ipairs(pk.handles) do
            local ok, sx, sy, depth = pcall(project, h.x, (h.y or terrainY(h.x, h.z)) + 0.8, h.z)
            if ok and sx ~= nil and depth ~= nil and depth > 0 then
                local dx, dy = sx - g_lastMousePosX, sy - g_lastMousePosY
                if dx * dx + dy * dy < bestD then best, bestD = i, dx * dx + dy * dy end
            end
        end
        return best
    end
    bestD = 4
    for i, h in ipairs(pk.handles) do
        local dx, dz = h.x - self.cursorX, h.z - self.cursorZ
        if dx * dx + dz * dz < bestD then best, bestD = i, dx * dx + dz * dz end
    end
    return best
end

--- Which piece of the selected pick's curve the mouse is on (to put a handle in), or nil.
function E:roadRunsHandlePiece()
    local s = roadState(self)
    local pk = s.sel
    if pk == nil or pk.curve == nil or self.cursorX == nil then return nil end
    local seg, dist, px, pz, py = ADSplinePath.nearestPiece(pk.curve, self.cursorX, self.cursorZ)
    if seg == nil then return nil end
    if project ~= nil and g_lastMousePosX ~= nil and g_lastMousePosY ~= nil then
        local ok, sx, sy, depth = pcall(project, px, (py or self.cursorY or 0) + 0.6, pz)
        if ok and sx ~= nil and depth ~= nil and depth > 0 then
            local dx, dy = sx - g_lastMousePosX, sy - g_lastMousePosY
            local r = AutoDrive.FLYOVER_PICK_SCREEN_RADIUS
            return (dx * dx + dy * dy <= r * r) and seg or nil
        end
        return nil
    end
    return dist <= 2 and seg or nil
end

--- Select a pick (handles shown), or clear the selection with nil.
function E:roadRunsSelect(pk)
    local s = roadState(self)
    s.sel = pk
    s.handlePress, s.handleDrag = nil, nil
    if pk ~= nil and pk.handles == nil then self:roadRunsMakeHandles(pk) end
end

--- A press on a handle of the selected pick: it may become a drag. True when it took the press.
function E:roadRunsPress()
    local s = roadState(self)
    local idx = self:roadRunsHandleAtCursor()
    if idx == nil then return false end
    s.handlePress = { idx = idx, mx = self.mouseX, my = self.mouseY }
    return true
end

--- Ctrl-click on a handle of the selected pick removes it (two stay). True when it took the click.
function E:roadRunsRemoveHandleAtCursor()
    local s = roadState(self)
    local pk = s.sel
    local idx = self:roadRunsHandleAtCursor()
    if pk == nil or idx == nil then return false end
    if #pk.handles <= 2 then
        self:warnPlayer("A run keeps its two end handles.")
        return true
    end
    table.remove(pk.handles, idx)
    self:roadRunsApplyHandles(pk, false, false)
    ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - handle %d removed (%d left).", idx, #pk.handles)
    return true
end

--- Per frame while a pick is selected: a press past the drag threshold drags its handle.
function E:roadRunsUpdateHandles()
    local s = roadState(self)
    local pk = s.sel
    if pk == nil then return end
    local press = s.handlePress
    if press ~= nil and s.handleDrag == nil and self.leftDown and self.mouseX ~= nil and press.mx ~= nil then
        local dx, dy = self.mouseX - press.mx, self.mouseY - press.my
        if math.sqrt(dx * dx + dy * dy) > (self.MOVE_DRAG_THRESHOLD or 0.004) then s.handleDrag = press.idx end
    end
    local idx = s.handleDrag
    if idx ~= nil then
        if not self.leftDown or pk.handles[idx] == nil then
            s.handleDrag, s.handlePress = nil, nil
        elseif self.cursorX ~= nil then
            local isEnd = idx == 1 or idx == #pk.handles
            local wp = (isEnd and self.splineSnapCandidate ~= nil) and self:splineSnapCandidate() or nil
            local h
            if wp ~= nil then
                h = { x = wp.x, y = wp.y, z = wp.z, wpId = wp.id }
            else
                h = { x = self.cursorX, y = terrainY(self.cursorX, self.cursorZ), z = self.cursorZ }
            end
            local old = pk.handles[idx]
            if math.abs(old.x - h.x) > 0.05 or math.abs(old.z - h.z) > 0.05 or old.wpId ~= h.wpId then
                pk.handles[idx] = h
                self:roadRunsApplyHandles(pk, idx == 1, idx == #pk.handles)
            end
        end
    end
    s.handleHover = (s.handleDrag == nil) and self:roadRunsHandleAtCursor() or nil
end

--- Per frame, guarded: an error in the tool is logged once and the tool stops reading, but the
--- editor's own update (camera keys, edge scroll) always carries on.
function E:updateRoadRuns(overPanel)
    if self.roadRunsBroken then return end
    local ok, err = pcall(self.updateRoadRunsInner, self, overPanel)
    if not ok then
        self.roadRunsBroken = true
        Logging.error("[FlyoverEditor]: road runs stopped after an error: %s", tostring(err))
        if self.warnPlayer ~= nil then pcall(self.warnPlayer, self, "Road runs hit an error and stopped - see log.txt.") end
    end
end

--- Per frame: keep the window round the mouse, sample a budget of ground, run the road-line job.
--- Paint the squares round the mouse (detection view, paint on, left button held on the map).
function E:roadRunsPaintAt(cx, cz)
    local s = roadState(self)
    s.painted = s.painted or {}
    local T, B = self.ROADVIEW_TILE, self.ROADVIEW_BRUSH
    for tx = math.floor((cx - B) / T), math.floor((cx + B) / T) do
        for tz = math.floor((cz - B) / T), math.floor((cz + B) / T) do
            local key = tx * 100003 + tz
            if s.painted[key] == nil and RF.onMap(tx * T + T / 2, tz * T + T / 2) then
                s.painted[key] = { tx = tx, tz = tz }
                s.paintedN = (s.paintedN or 0) + 1
            end
        end
    end
end

function E:updateRoadRunsInner(overPanel)
    do
        local s = roadState(self)
        local wps = ADGraphManager:getWayPoints()
        local n = 0
        if wps ~= nil then n = #wps end
        if s.wpCount ~= nil and n ~= s.wpCount and (#s.picks > 0 or s.voted ~= nil) then
            self:roadRunsForget("the waypoints changed")
        end
        s.wpCount = n
    end
    if not overPanel then self:roadRunsUpdateHandles() end
    if self.roadView and self.roadDrawMid then self:roadMidUpdate(overPanel) end
    if self.roadView and self.roadPaint and self.leftDown and not overPanel and self.cursorX ~= nil then
        self:roadRunsPaintAt(self.cursorX, self.cursorZ)
    end
    local s = roadState(self)
    local cx, cz = self.cursorX, self.cursorZ
    if cx == nil then return end
    self:roadRunsHover(overPanel)

    local want = (s.centreX == nil)
        or math.abs(cx - s.centreX) > self.ROADRUNS_RECENTRE or math.abs(cz - s.centreZ) > self.ROADRUNS_RECENTRE
    local key = kindsKey(self.roadKinds)
    if want then
        local snap = self.ROADRUNS_SNAP
        s.centreX = math.floor(cx / snap + 0.5) * snap
        s.centreZ = math.floor(cz / snap + 0.5) * snap
        -- keep the read square on the map (its edge is not safe to read past)
        local lim = RF.mapHalf() - self.ROADRUNS_WINDOW / 2
        if lim > 0 then
            s.centreX = math.max(-lim, math.min(lim, s.centreX))
            s.centreZ = math.max(-lim, math.min(lim, s.centreZ))
        end
        s.job, s.jobKey = nil, nil
    end
    local half = self.ROADRUNS_WINDOW / 2
    local ix0, iz0 = math.floor(s.centreX - half), math.floor(s.centreZ - half)
    local jobKey = string.format("%d:%d:%s", ix0, iz0, key)

    -- the network changed (an edit, an undo): only the cover needs redoing
    local netKey = tostring(ADGraphManager:getWayPointsCount()) .. ":" .. tostring(ADEditorHistory:depth())
        .. ":" .. tostring(#s.picks)
    if s.win ~= nil and s.netKey ~= netKey and s.job == nil then
        s.netKey = netKey
        self:roadRunsRefreshStretches()
    end

    if (s.win == nil or s.win.key ~= jobKey) and s.job == nil then
        local missing = RF.cacheRequest(s.cache, ix0, iz0, ix0 + self.ROADRUNS_WINDOW - 1, iz0 + self.ROADRUNS_WINDOW - 1)
        if missing > 0 then
            local total = self.ROADRUNS_WINDOW * self.ROADRUNS_WINDOW
            s.progress = 0.8 * (1 - missing / total)
            -- a time slice of ground reads, in small batches, never more than the per-frame cap
            local t0, done = RF.clock(), 0
            repeat
                local finished = RF.cacheStep(s.cache, 250)
                done = done + 250
                local now = RF.clock()
            until finished or done >= self.ROADRUNS_SAMPLES_PER_FRAME or (t0 ~= nil and now ~= nil and now - t0 >= RF.SLICE)
            return
        end
        local kinds = {}
        for k, v in pairs(self.roadKinds) do kinds[k] = v end
        local cache = s.cache
        s.jobKey = jobKey
        local function build()
            RF.yielding = true
            local win = RF.buildWindow(function(ix, iz) return RF.cacheKind(cache, ix, iz) end,
                ix0, iz0, self.ROADRUNS_WINDOW, self.ROADRUNS_WINDOW,
                { kinds = kinds, deckAt = function(ix, iz) return RF.cacheDeck(cache, ix, iz) end })
            RF.yielding = false
            return win
        end
        -- FS25's script environment has no coroutine library (2026-10-12 log: "attempt to index nil
        -- with 'create'"); there the road lines are worked out in one go, a short pause per new window
        if coroutine ~= nil and coroutine.create ~= nil then
            s.job = coroutine.create(build)
        else
            s.job = { sync = build }
        end
        s.progress = 0.85
    end
    if s.job ~= nil then
        RF.sliceStart = RF.clock()
        local ok, result, done
        if type(s.job) == "table" then
            RF.yielding = false
            ok, result = pcall(s.job.sync)
            done = true
        else
            ok, result = coroutine.resume(s.job)
            done = ok and coroutine.status(s.job) == "dead"
        end
        if not ok then
            Logging.error("[FlyoverEditor]: road runs - reading the roads failed: %s", tostring(result))
            s.job, s.jobKey = nil, nil
            RF.yielding = false
            s.win = { key = jobKey, edges = {}, nodes = {}, ix0 = ix0, iz0 = iz0, W = 0, H = 0 }
            s.stretches = {}
            return
        end
        if done then
            s.win = result
            s.win.key = s.jobKey
            s.builds = (s.builds or 0) + 1
            s.job, s.jobKey = nil, nil
            s.progress = 1
            s.netKey = netKey
            self:roadRunsRefreshStretches()
            ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - window (%d, %d): %d road lines, %d stretches with no path, %d bridge/ramp landing(s) joined%s.",
                ix0, iz0, #s.win.edges, #s.stretches, s.win.decks or 0, RF.noRockCheck and " (no drive-cost map: rock may read as paved)" or "")
        else
            s.progress = math.min(0.98, (s.progress or 0.85) + 0.01)
        end
    end

end

-- ---------------------------------------------------------------------------------------------
-- walking the road under the mouse

-- The square read finds roads and forks; the line the tool lays comes from WALKING the road (RoadFinder
-- RF.walkRoad): it steers gently toward the middle of what it sees, takes two wheel ruts as one track,
-- ignores one-off bumps, and is straightened afterwards. Ground is read on a 0.25 m grid, remembered.
local walkMemo, walkMemoN = {}, 0
local function kindAtWalk(x, z)
    local key = math.floor(x * 4) * 1000003 + math.floor(z * 4)
    local k = walkMemo[key]
    if k == nil then
        if walkMemoN > 800000 then walkMemo, walkMemoN = {}, 0 end
        k = RF.groundKindAt(math.floor(x * 4) / 4 + 0.125, math.floor(z * 4) / 4 + 0.125)
        walkMemo[key] = k
        walkMemoN = walkMemoN + 1
    end
    return k
end

local fieldMemo, fieldMemoN = {}, 0
local function fieldAtWalk(x, z)
    local key = math.floor(x * 4) * 1000003 + math.floor(z * 4)
    local f = fieldMemo[key]
    if f == nil then
        if fieldMemoN > 800000 then fieldMemo, fieldMemoN = {}, 0 end
        f = RF.isFieldAt(math.floor(x * 4) / 4 + 0.125, math.floor(z * 4) / 4 + 0.125)
        fieldMemo[key] = f
        fieldMemoN = fieldMemoN + 1
    end
    return f
end

-- Is there paving within PAVED_EDGE of (x, z)? Eight looks round, remembered on the 0.25 m grid.
local nearMemo, nearMemoN = {}, 0
local function nearPavedWalk(x, z)
    local key = math.floor(x * 4) * 1000003 + math.floor(z * 4)
    local v = nearMemo[key]
    if v == nil then
        if nearMemoN > 800000 then nearMemo, nearMemoN = {}, 0 end
        v = false
        local d = RF.PAVED_EDGE
        for k = 0, 7 do
            local a = k * math.pi / 4
            if kindAtWalk(x + math.cos(a) * d, z + math.sin(a) * d) == RF.KIND_PAVED then v = true break end
        end
        nearMemo[key] = v
        nearMemoN = nearMemoN + 1
    end
    return v
end

-- the paved roads' shoulders and aprons (gravel/dirt joined to asphalt): not track, and a track walked
-- into one has met the road
local shoulderAtWalk = RF.newShoulderMap(kindAtWalk)
RF.kindReader = kindAtWalk
RF.fieldReader = fieldAtWalk

-- for code above this point in the file (the locals are not visible there)
E.roadRunsKindAt, E.roadRunsFieldAt, E.roadRunsShoulderAt = kindAtWalk, fieldAtWalk, shoulderAtWalk

function E:roadRunsWalkTests()
    local editor = self
    local function isRoadOf(cls)
        if cls == "paved" then
            return function(x, z) return kindAtWalk(x, z) == RF.KIND_PAVED end
        end
        return function(x, z)
            local k = kindAtWalk(x, z)
            if not ((k == RF.KIND_GRAVEL and editor.roadKinds[RF.KIND_GRAVEL]) or (k == RF.KIND_DIRT and editor.roadKinds[RF.KIND_DIRT])) then
                return false
            end
            -- a paved road's verge is not a track (a 255 m walk along a road's gravel verge, 2026-10-12),
            -- nor its wider shoulder or apron (2026-10-13)
            return not nearPavedWalk(x, z) and not shoulderAtWalk(x, z)
        end
    end
    local function isStopOf(cls)
        -- a track walked onto a paved road has met it: a fork for the junction tool
        if cls == "track" then return function(x, z) return kindAtWalk(x, z) == RF.KIND_PAVED or shoulderAtWalk(x, z) end end
        return nil
    end
    return isRoadOf, isStopOf
end

--- The stretch as it will be laid: walked, straightened, cut to its ends, and (where the walk ran past
--- the read square) stopped at the first AutoDrive path. Worked out once per stretch.
function E:roadRunsRefined(st)
    if st == nil then return nil end
    if st.refinedTo ~= nil then return st.refinedTo end
    local isRoadOf, isStopOf = self:roadRunsWalkTests()
    local ok, r = pcall(RF.refineStretch, st, isRoadOf, isStopOf, fieldAtWalk)
    if not ok then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - walking the road failed (%s); using the square's line.", tostring(r))
        r = nil
    end
    if r ~= nil then
        local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
        for _, p in ipairs(r.pts) do
            x0, z0, x1, z1 = math.min(x0, p.x), math.min(z0, p.z), math.max(x1, p.x), math.max(z1, p.z)
        end
        local grid = RF.indexNetwork(ADGraphManager:getWayPoints(), function(id) return ADGraphManager:getWayPointById(id) end,
            x0 - 10, z0 - 10, x1 + 10, z1 + 10)
        r = RF.keepUncovered(r, grid)
        -- the walk can run down one track and back up its neighbour (2026-10-13): keep the piece
        -- around the stretch it was walked from
        if r ~= nil then
            local m = st.pts[math.floor(#st.pts / 2) + 1]
            r = RF.cutHairpins(r, m.x, m.z)
            r = RF.cutEndHooks(r, function(x, z) return E.roadRunsKindAt(x, z) == RF.KIND_PAVED end)
            -- and no line where there is no road under it (dirt patches in grass read as a track)
            local isRoad = isRoadOf(r.class or st.class)
            r = RF.trimGhosts(r, isRoad, r.class or st.class, m.x, m.z)
            if r == nil then
                ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - the line round (%.1f, %.1f) has too little road under it; not offered.", m.x, m.z)
                st.ghost = true
            end
        end
    end
    if r == nil or #r.pts < 3 then
        r = st
    else
        withHeights(r.pts)
        r.id = st.id
        r.refinedTo = r
    end
    st.refinedTo = r
    return r
end

-- ---------------------------------------------------------------------------------------------
-- picking

--- Following the road straight on through a fork: from the node a stretch ends at, the stretch on the
--- edge leaving that node most nearly straight ahead (within 35 degrees), if it has no path.
local function continueThrough(s, st, atEnd)
    local node = atEnd and st.endNode or st.startNode
    if node == nil or node.tag ~= "fork" then return nil end
    local P = st.pts
    local a, b
    if atEnd then a, b = P[math.max(1, #P - 3)], P[#P] else a, b = P[math.min(#P, 4)], P[1] end
    local hx, hz = b.x - a.x, b.z - a.z
    local hl = math.sqrt(hx * hx + hz * hz)
    if hl < 1e-6 then return nil end
    local best, bestCos = nil, math.cos(math.rad(35))
    for _, cand in ipairs(s.stretches) do
        local e = cand.edge
        -- matched by the road line, not by the stretch's own end: picked roads count as covered, so
        -- the first metres of the next stretch past the fork can read as covered and start "path"
        if cand ~= st and e ~= st.edge and (e.a == node or e.b == node) then
            local forward = (e.a == node)
            local Q = cand.pts
            local c, d
            if forward then c, d = Q[1], Q[math.min(#Q, 4)] else c, d = Q[#Q], Q[math.max(1, #Q - 3)] end
            local near = math.sqrt((c.x - node.x) ^ 2 + (c.z - node.z) ^ 2)
            local qx, qz = d.x - c.x, d.z - c.z
            local ql = math.sqrt(qx * qx + qz * qz)
            if near < 20 and ql > 1e-6 then
                local cosv = (hx * qx + hz * qz) / (hl * ql)
                if cosv > bestCos then best, bestCos = { st = cand, forward = forward }, cosv end
            end
        end
    end
    return best
end

local function addPick(s, st, dir)
    s.picks[#s.picks + 1] = { st = st, dir = dir or 1 }
end

function E:roadRunsClick()
    if self.roadView and self.roadDrawMid then self:roadMidClick() return end
    if self.roadView and self.roadPaint then return end      -- painting: the drag paints, see update
    local s = roadState(self)
    -- shaping the selected run
    if s.handleDrag ~= nil then
        local pk = s.sel
        local h = pk ~= nil and pk.handles[s.handleDrag] or nil
        ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - handle %d moved to (%.1f, %.1f)%s; run now %.0f m.", s.handleDrag,
            h and h.x or 0, h and h.z or 0, (h and h.wpId) and string.format(" (on waypoint %d)", h.wpId) or "",
            pk and pk.st.len or 0)
        s.handleDrag, s.handlePress = nil, nil
        return
    end
    if s.handlePress ~= nil then
        s.handlePress = nil                                     -- a click on a handle without a drag
        return
    end
    if s.sel ~= nil then
        local seg = self:roadRunsHandlePiece()
        if seg ~= nil then
            local pk = s.sel
            table.insert(pk.handles, seg + 1, { x = self.cursorX, y = terrainY(self.cursorX, self.cursorZ), z = self.cursorZ })
            self:roadRunsApplyHandles(pk, false, false)
            ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - handle added at (%.1f, %.1f) (%d handles).",
                self.cursorX, self.cursorZ, #pk.handles)
            return
        end
    end
    local now = self:nowMs()
    local last = s.lastClick
    local isDouble = last ~= nil and (now - last.at) < self.DOUBLE_CLICK_MS
    s.lastClick = { at = now }

    if isDouble and last.pick ~= nil then
        -- double-click: the stretch the first click picked, carried on through forks both ways
        local count = 0
        if last.pick.st.pointWalk then
            count = self:roadRunsWalkThrough(last.pick)
            self:roadRunsRefreshStretches()
            ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - double-click walked on through %d junction(s).", count)
            return
        end
        for _, atEnd in ipairs({ true, false }) do
            local cur, curAtEnd = last.pick.st, atEnd
            for _ = 1, 40 do
                local nxt = continueThrough(s, cur, curAtEnd)
                if nxt == nil then break end
                local already = false
                for _, pk in ipairs(s.picks) do if pk.st == nxt.st or pk.st == nxt.st.refinedTo then already = true end end
                if already then break end
                -- one-way: keep the same direction of travel along the chain
                local dir = last.pick.dir
                local sameOrder = (curAtEnd and nxt.forward) or ((not curAtEnd) and not nxt.forward)
                local cdir = (cur == last.pick.st) and dir or (s.chainDir[cur] or dir)
                local ndir = sameOrder and cdir or -cdir
                s.chainDir[nxt.st] = ndir
                addPick(s, self:roadRunsRefined(nxt.st), ndir)
                count = count + 1
                cur, curAtEnd = nxt.st, nxt.forward
            end
        end
        self:roadRunsRefreshStretches()
        ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - double-click took %d more stretch(es) along the road.", count)
        return
    end

    if s.hover ~= nil then
        local st = s.hover
        -- a road walked from the mouse is voted on first (the same road from anywhere on it)
        if st.pointWalk and not st.votes and self.cursorX ~= nil then
            local voted = self:roadRunsVote(self.cursorX, self.cursorZ)
            if voted ~= nil then
                st = voted
                s.hover = voted
            end
        end
        st = self:roadRunsRefined(st)
        if #self:roadRunsLanesFor(st, s.hoverSide or 1, true) == 0 then
            self:warnPlayer(string.format("This stretch is too short to lay with %.1f m left at its forks - lower the fork gap.",
                self.roadForkGap))
            return
        end
        local pick = { st = st, dir = s.hoverSide or 1 }
        s.picks[#s.picks + 1] = pick
        s.chainDir = {}
        s.lastClick.pick = pick
        self:roadRunsSelect(pick)
        ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - picked a %s stretch, %.0f m, %.1f m wide (%s to %s), %s.",
            RF.KIND_NAMES[st.kind] or "?", st.len, st.width or -1, st.startTag, st.endTag,
            st.fromSpline and "the map's own road line" or st.pointWalk and "walked from the mouse"
                or (st.walk ~= nil and string.format("walked: road read across it at %d of %d points", st.walk.read, st.walk.sections))
                or "NOT walked (square's line)")
        -- what the ground looks like straight across the laid line, a quarter, half and three quarters along
        for _, f in ipairs({ 0.25, 0.5, 0.75 }) do
            local i = math.max(1, math.min(#st.pts, math.floor(#st.pts * f)))
            local p = st.pts[i]
            ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - across at (%.1f, %.1f): %s", p.x, p.z,
                RF.crossText(kindAtWalk, st.pts, i, fieldAtWalk))
            -- the same, exactly: every strip of road ground (0.25 m), and the middle the walk reads there
            local detail = RF.crossDetail(function(cls) return self:roadRunsWalkTests()(cls) end, st, i)
            if detail ~= nil then
                ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs -    strips %s; read middle %+.2f m from the line", detail.strips, detail.mid)
            end
        end
        self:roadRunsRefreshStretches()
    elseif s.hoverPick ~= nil then
        -- a click on a pick selects it for shaping (it is dropped with the card's button)
        self:roadRunsSelect(s.hoverPick)
    else
        self:roadRunsSelect(nil)                                -- empty ground: nothing selected
    end
end

--- Forget everything not built: picks, their handles and shaping, the selection, the remembered
--- votes and walks (2026-10-14 user: a shaped run that was never placed, or whose waypoints were
--- deleted, must not stay). Called on leaving the tool and when the network changes under us.
function E:roadRunsForget(why)
    local s = self.roadRuns
    if s == nil then return end
    local had = #s.picks
    s.picks, s.voted, s.walked, s.hover, s.hoverPick = {}, nil, nil, nil, nil
    s.sel, s.handlePress, s.handleDrag, s.handleHover = nil, nil, nil, nil
    if had > 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - %d unbuilt pick(s) dropped (%s).", had, why or "?")
    end
end

--- Drop the selected pick (the card's button).
function E:roadRunsDropSelected()
    local s = roadState(self)
    for k, pk in ipairs(s.picks) do
        if pk == s.sel then table.remove(s.picks, k) break end
    end
    self:roadRunsSelect(nil)
    self:roadRunsRefreshStretches()
end

--- Double-click on a road walked from the mouse: from each end that stopped at a junction, hop
--- straight on past it (WALK_THROUGH: the hop lengths tried) and walk the same road on the far side (it must line up
--- within 35 degrees), again and again. Each piece is its own pick, so each keeps the gap at the
--- junction for the junction tool. Returns how many pieces were added.
E.ROADRUNS_WALK_THROUGH = { 15, 25, 35 }
function E:roadRunsWalkThrough(pick)
    local s = roadState(self)
    local isRoadOf, isStopOf = self:roadRunsWalkTests()
    local added = 0
    for _, atEnd in ipairs({ true, false }) do
        local cur = pick.st
        local dir = pick.dir
        for _ = 1, 12 do
            local tag = atEnd and cur.endTag or cur.startTag
            if tag ~= "fork" then break end
            local P = cur.pts
            local n = #P
            if n < 4 then break end
            local a, b
            if atEnd then a, b = P[math.max(1, n - 4)], P[n] else a, b = P[math.min(n, 5)], P[1] end
            local hx, hz = b.x - a.x, b.z - a.z
            local hl = math.sqrt(hx * hx + hz * hz)
            if hl < 1e-6 then break end
            hx, hz = hx / hl, hz / hl
            -- hop over the junction: try a few distances (a short hop can land in the junction's own
            -- wide paving, where no road reads)
            local r, jx, jz = nil, nil, nil
            for _, hop in ipairs(self.ROADRUNS_WALK_THROUGH) do
                jx, jz = b.x + hx * hop, b.z + hz * hop
                local got = self:roadRunsWalkFrom(isRoadOf, jx, jz, { cur.class }, isStopOf)
                if got ~= nil and #got.pts >= 4 then r = got break end
            end
            if r == nil then
                ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - no road found past the junction at (%.1f, %.1f).", b.x, b.z)
                break
            end
            -- the far road must carry on the same way; orient it to run away from the junction
            local Q = r.pts
            local d1 = (Q[1].x - b.x) ^ 2 + (Q[1].z - b.z) ^ 2
            local d2 = (Q[#Q].x - b.x) ^ 2 + (Q[#Q].z - b.z) ^ 2
            local away = d1 <= d2
            local c, d
            if away then c, d = Q[1], Q[math.min(#Q, 5)] else c, d = Q[#Q], Q[math.max(1, #Q - 4)] end
            local qx, qz = d.x - c.x, d.z - c.z
            local ql = math.sqrt(qx * qx + qz * qz)
            if ql < 1e-6 or (qx * hx + qz * hz) / ql < math.cos(math.rad(35)) then
                ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - the road past the junction at (%.1f, %.1f) turns away; not carried on.", b.x, b.z)
                break
            end
            local grid = RF.indexNetwork(ADGraphManager:getWayPoints(), function(id) return ADGraphManager:getWayPointById(id) end,
                jx - 450, jz - 450, jx + 450, jz + 450)
            r = RF.keepUncovered(r, grid)
            if r == nil or #r.pts < 4 then
                ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - the road past the junction at (%.1f, %.1f) already has a path.", b.x, b.z)
                break
            end
            withHeights(r.pts)
            r.refinedTo, r.pointWalk = r, true
            r.kind = cur.kind
            r.id = string.format("walk:%d:%d", math.floor(r.pts[1].x), math.floor(r.pts[1].z))
            -- one-way: keep the direction of travel: same point order as the chain's run -> same dir
            local sameOrder = (atEnd and away) or ((not atEnd) and not away)
            local ndir = sameOrder and dir or -dir
            addPick(s, r, ndir)
            added = added + 1
            cur, dir = r, ndir
            -- walk on from the new piece's far end (its end away from the junction)
            atEnd = away
        end
    end
    return added
end

function E:roadRunsClearPicks()
    local s = roadState(self)
    s.picks = {}
    self:roadRunsSelect(nil)
    self:roadRunsRefreshStretches()
end

function E:roadRunsPickedLength()
    local s = self.roadRuns
    if s == nil then return 0, 0 end
    local L = 0
    for _, pk in ipairs(s.picks) do L = L + (pk.st.len or 0) end
    return #s.picks, L
end

-- ---------------------------------------------------------------------------------------------
-- the side check: how much room the road has on each side

-- AutoDrive's own object-sensor mask (as the junction tool's corridor check): map furniture is often in
-- the DEFAULT group and knock-over signs are DYNAMIC bodies. Vehicles, bales and pallets are dropped.
local SideProbe = { hits = 0 }
function SideProbe.cb(self, id)
    if id ~= nil and id ~= 0 and id ~= g_currentMission.terrainRootNode then
        local obj = g_currentMission.nodeToObject ~= nil and g_currentMission.nodeToObject[id] or nil
        if obj ~= nil and (obj.rootVehicle ~= nil or obj.spec_wheels ~= nil or obj.getRootVehicle ~= nil
            or obj.isRoundbale ~= nil or obj.baleDiameter ~= nil or obj.spec_pallet ~= nil) then
            return true
        end
        self.hits = self.hits + 1
    end
    return true
end
local sideMask = nil
local sideProbeNoted = false

--- Metres from the centre line at p to the first thing in the way on its left and right (nil = clear
--- out to PROBE_REACH): something standing there from 0.8 to 2.8 m above the road (a railing, wall,
--- post, tree), the edge of the deck on a bridge or ramp, or on the ground a bank rising over 1 m or a
--- drop of over 1.5 m. (rx, rz) is the unit vector to the right. Checked in 0.5 m steps; the answer
--- is the last clear step, so it never overstates the room.
function E:roadRunsClearance(p, rx, rz)
    if overlapBox == nil or g_currentMission == nil or g_currentMission.terrainRootNode == nil then return nil, nil end
    if sideMask == nil then
        -- plus ROAD: a bridge's railings may be part of its deck mesh, in the road group. The probe box
        -- floats 0.8 m over the deck, so the deck itself is not hit.
        sideMask = (CollisionFlag.DEFAULT or 0) + (CollisionFlag.STATIC_OBJECT or 0) + (CollisionFlag.DYNAMIC_OBJECT or 0)
            + (CollisionFlag.TREE or 0) + (CollisionFlag.BUILDING or 0) + (CollisionFlag.ROAD or 0)
    end
    local y = p.y or terrainY(p.x, p.z)
    if not (finite(p.x) and finite(p.z) and finite(y) and finite(rx) and finite(rz)) then return nil, nil end
    local ry = math.atan2(rz, -rx)        -- heading (rz, -rx): the box's long side runs along the road
    local step = 0.5
    local function room(side)
        for d = step, self.ROADRUNS_PROBE_REACH, step do
            local x, z = p.x + side * rx * d, p.z + side * rz * d
            if not RF.onMap(x, z) then return d - step end
            local blocked = false
            if p.deck then
                -- still on the deck: a road mesh under the wheel within 0.6 m of the deck's height
                local my = RF.roadMeshAt(x, z)
                if my == nil or math.abs(my - y) > 0.6 then blocked = true end
            else
                local ty = terrainY(x, z)
                if ty > y + 1.0 or ty < y - 1.5 then blocked = true end
            end
            if not blocked then
                SideProbe.hits = 0
                local ok, err = pcall(overlapBox, x, y + 1.8, z, 0, ry, 0, step / 2, 1.0, 0.5, "cb", SideProbe, sideMask,
                    true, true, true, true)
                if not ok and not sideProbeNoted then
                    sideProbeNoted = true
                    ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - side check FAILED (%s): lanes are not fitted to railings.", tostring(err))
                end
                blocked = ok and SideProbe.hits > 0
            end
            if blocked then return d - step end
        end
        return nil
    end
    return room(-1), room(1)
end

--- The side-check settings handed to the lane planner.
function E:roadRunsFit()
    local editor = self
    return {
        clear = function(p, rx, rz) return editor:roadRunsClearance(p, rx, rz) end,
        everywhere = self.roadFitEverywhere,
        rigClear = self.roadRigWidth / 2 + self.ROADRUNS_RIG_MARGIN,
        minGap = self:roadMinGap(),
        taper = self.ROADRUNS_TAPER,
    }
end

-- ---------------------------------------------------------------------------------------------
-- building

local function neighbourCount(wp)
    local seen, n = {}, 0
    for _, id in ipairs(wp.out or {}) do if not seen[id] then seen[id] = true n = n + 1 end end
    for _, id in ipairs(wp.incoming or {}) do if not seen[id] then seen[id] = true n = n + 1 end end
    return n
end

--- Which way the network runs through wp: along its first outgoing link, else its first incoming.
local function travelAt(wp)
    local o = wp.out ~= nil and wp.out[1] or nil
    local ow = o ~= nil and ADGraphManager:getWayPointById(o) or nil
    if ow ~= nil then return ow.x - wp.x, ow.z - wp.z end
    local i = wp.incoming ~= nil and wp.incoming[1] or nil
    local iw = i ~= nil and ADGraphManager:getWayPointById(i) or nil
    if iw ~= nil then return wp.x - iw.x, wp.z - iw.z end
    return nil
end

--- The waypoint a lane end should join, within JOIN_RADIUS:
---   * the loose END of an existing path (one that stops there: for the lane's start, a path that
---     runs in and stops; for its end, a path that starts there), at any angle up to a right-angle
---     corner - preferred;
---   * or a path running the same way as the lane (so a lane joins its own side of a two-lane road),
---     behind the lane's start or ahead of its end.
--- `owner[id]` says which pick laid a point in this build: the lane's own pick is never a target (its
--- other lane would make a U-turn), and only points that existed before the build count as ends.
local function joinTarget(j, owner, pickIndex, R)
    local hx, hz = j.h[1], j.h[2]
    local hl = math.sqrt(hx * hx + hz * hz)
    if hl < 1e-6 then return nil end
    hx, hz = hx / hl, hz / hl
    local best, bestScore = nil, math.huge
    for _, wp in pairs(ADGraphManager:getWayPoints()) do
        if type(wp) == "table" and wp.x ~= nil and owner[wp.id] ~= pickIndex then
            local dx, dz = wp.x - j.p.x, wp.z - j.p.z
            local d = math.sqrt(dx * dx + dz * dz)
            if d <= R and d > 0.05 then
                local score = nil
                local tx, tz = travelAt(wp)
                local c = nil
                if tx ~= nil then
                    local tl = math.sqrt(tx * tx + tz * tz)
                    if tl > 1e-6 then c = (tx * hx + tz * hz) / tl end
                end
                -- only straight on in line with the run: no more than ROADRUNS_JOIN_SIDE off its line
                -- (a diagonal link 8 m along a road the run met in a T, 2026-10-14)
                local ahead = dx * hx + dz * hz
                if j.atStart then ahead = -ahead end
                local side = math.abs(dx * hz - dz * hx)
                local inLine = ahead > -1 and side <= E.ROADRUNS_JOIN_SIDE
                -- a loose end of the old network
                if inLine and owner[wp.id] == nil and neighbourCount(wp) <= 1 then
                    local fits
                    if j.dual then
                        fits = true
                    elseif j.atStart then
                        fits = #(wp.out or {}) == 0
                        if not fits and #(wp.incoming or {}) == 1 and #(wp.out or {}) == 1 and wp.out[1] == wp.incoming[1] then fits = true end
                    else
                        fits = #(wp.incoming or {}) == 0
                        if not fits and #(wp.incoming or {}) == 1 and #(wp.out or {}) == 1 and wp.out[1] == wp.incoming[1] then fits = true end
                    end
                    -- not a hairpin: the end may meet the lane at up to about a right angle
                    if fits and (c == nil or c > -0.2) then score = d - 3 end
                end
                -- or a path running the same way
                if score == nil and c ~= nil and inLine then
                    local cc = j.dual and math.abs(c) or c
                    if cc > math.cos(math.rad(30)) then score = d + (1 - cc) * 10 end
                end
                if score ~= nil and score < bestScore then best, bestScore = wp, score end
            end
        end
    end
    return best
end

--- T-join: the lane crossed first straight on from a run's end (within ROADRUNS_TEE_REACH, crossing
--- at more than ROADRUNS_TEE_ANGLE), with a waypoint put into it where they cross. Returns that
--- waypoint (an existing end point when the crossing is within 1 m of it), or nil.
E.ROADRUNS_TEE_REACH = 15
E.ROADRUNS_TEE_ANGLE = 30
function E:roadRunsTeeTarget(j, owner)
    local hx, hz = j.h[1], j.h[2]
    if j.atStart then hx, hz = -hx, -hz end
    local hl = math.sqrt(hx * hx + hz * hz)
    if hl < 1e-6 then return nil end
    hx, hz = hx / hl, hz / hl
    local ox, oz = j.p.x, j.p.z
    local sinMin = math.sin(math.rad(self.ROADRUNS_TEE_ANGLE))
    local best, bestT = nil, math.huge
    for _, a in pairs(ADGraphManager:getWayPoints()) do
        if type(a) == "table" and a.x ~= nil and owner[a.id] == nil and math.abs(a.x - ox) < 60 and math.abs(a.z - oz) < 60 then
            for _, bid in ipairs(a.out or {}) do
                local b = ADGraphManager:getWayPointById(bid)
                if b ~= nil and owner[b.id] == nil then
                    -- ray o + t*h against segment a + u*(b - a)
                    local ex, ez = b.x - a.x, b.z - a.z
                    local den = hx * ez - hz * ex
                    local el = math.sqrt(ex * ex + ez * ez)
                    if el > 1e-6 and math.abs(den) / el >= sinMin then
                        local wx, wz = a.x - ox, a.z - oz
                        local t = (wx * ez - wz * ex) / den
                        local u = (wx * hz - wz * hx) / den
                        if t >= -1 and t <= self.ROADRUNS_TEE_REACH and u >= 0 and u <= 1 and t < bestT then
                            best, bestT = { a = a, b = b, u = u, el = el }, t
                        end
                    end
                end
            end
        end
    end
    if best == nil then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - no lane crossed within %d m straight on from the run's %s at (%.1f, %.1f).",
            self.ROADRUNS_TEE_REACH, j.atStart and "start" or "end", ox, oz)
        return nil
    end
    local a, b = best.a, best.b
    local near = (best.u * best.el <= 1 and a) or (((1 - best.u) * best.el <= 1) and b) or nil
    if near ~= nil then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - T-joined the lane at its point %d, %.1f m on from the run's end.", near.id, bestT)
        return near
    end
    if self.insertOnSegment == nil then return nil end
    local dual = false
    for _, id in ipairs(b.out or {}) do if id == a.id then dual = true end end
    local pos = { x = a.x + (b.x - a.x) * best.u, z = a.z + (b.z - a.z) * best.u }
    local flags = (a.flags ~= nil) and a.flags or AutoDrive.FLAG_NONE
    local newId = self:insertOnSegment(a.id, b.id, pos, dual, flags)
    if newId == nil then return nil end
    ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - T-joined the lane %d->%d at (%.1f, %.1f), %.1f m on from the run's end.",
        a.id, b.id, pos.x, pos.z, bestT)
    return ADGraphManager:getWayPointById(newId)
end

--- Build every picked stretch. One undo step for all of it.
function E:commitRoadRuns()
    local s = roadState(self)
    if #s.picks == 0 then return false end
    ADEditorHistory:snapshot("road runs")
    local flags = self.roadSubPrio and AutoDrive.FLAG_SUBPRIO or AutoDrive.FLAG_NONE
    local laid, points, joins, narrow = 0, 0, 0, 0
    local pending = {}       -- ends to join once everything is laid (a pick may join another pick)
    local owner = {}         -- point id -> the pick that laid it, this build
    for pickIndex, pk in ipairs(s.picks) do
        local st = pk.st
        local mode = self:roadModeFor(st)
        local lanes = self:roadRunsLanesFor(st, pk.dir)
        local ids = {}
        for k, ln in ipairs(lanes) do
            if #ln.pts >= 2 then
                local firstId, lastId = self:createRunFrom(withHeights(ln.pts), ln.dual, flags)
                if firstId ~= nil and lastId ~= nil then
                    ids[k] = { first = firstId, last = lastId }
                    for id = firstId, lastId do owner[id] = pickIndex end
                    laid = laid + 1
                    points = points + (lastId - firstId + 1)
                    -- a lane end at a stretch end that an existing path takes over from: join it there
                    local P, n = ln.pts, #ln.pts
                    local function tagAt(at) return (at == "start") and st.startTag or st.endTag end
                    -- only where an existing path carries the road on (never at a T with a road:
                    -- the junction tool ties those in - 2026-10-14 user)
                    local function joins(tag) return tag == "path" end
                    -- an end handle snapped onto a waypoint joins that waypoint
                    local function snapAt(at) return (at == "start") and st.joinStart or st.joinEnd end
                    if ln.startAt ~= nil and snapAt(ln.startAt) ~= nil then
                        pending[#pending + 1] = { pick = pickIndex, id = firstId, p = P[1], h = { P[2].x - P[1].x, P[2].z - P[1].z }, atStart = true, dual = ln.dual, joinId = snapAt(ln.startAt) }
                    elseif ln.startAt ~= nil and joins(tagAt(ln.startAt)) then
                        pending[#pending + 1] = { pick = pickIndex, id = firstId, p = P[1], h = { P[2].x - P[1].x, P[2].z - P[1].z }, atStart = true, dual = ln.dual }
                    end
                    if ln.endAt ~= nil and snapAt(ln.endAt) ~= nil then
                        pending[#pending + 1] = { pick = pickIndex, id = lastId, p = P[n], h = { P[n].x - P[n - 1].x, P[n].z - P[n - 1].z }, atStart = false, dual = ln.dual, joinId = snapAt(ln.endAt) }
                    elseif ln.endAt ~= nil and joins(tagAt(ln.endAt)) then
                        pending[#pending + 1] = { pick = pickIndex, id = lastId, p = P[n], h = { P[n].x - P[n - 1].x, P[n].z - P[n - 1].z }, atStart = false, dual = ln.dual }
                    end
                end
            end
        end
        -- lanes into and out of a one-line part (a narrow bridge)
        for _, lk in ipairs(lanes.links or {}) do
            local a, b = ids[lk.from], ids[lk.to]
            if a ~= nil and b ~= nil then
                local wa = ADGraphManager:getWayPointById(lk.fromStart and a.first or a.last)
                local wb = ADGraphManager:getWayPointById(lk.toEnd and b.last or b.first)
                if wa ~= nil and wb ~= nil then
                    ADGraphManager:toggleConnectionBetween(wa, wb, false, false, false)
                end
            end
        end
        if lanes.collapsed ~= nil and lanes.collapsed > 0 then narrow = narrow + lanes.collapsed end
    end
    for _, j in ipairs(pending) do
        local own = ADGraphManager:getWayPointById(j.id)
        -- a run that meets a road's lane head-on joins it in a T: straight on from its end to the
        -- first lane it crosses, a waypoint put into that lane there (2026-10-14 user: a diagonal
        -- link to a waypoint 8 m along the road "I don't much like the way it is connecting")
        local target
        if j.joinId ~= nil then target = ADGraphManager:getWayPointById(j.joinId)
        else target = joinTarget(j, owner, j.pick, self.ROADRUNS_JOIN_RADIUS) end
        if target ~= nil and own ~= nil and target ~= own and finite(target.x) and finite(target.z) then
            if j.atStart then
                ADGraphManager:toggleConnectionBetween(target, own, false, j.dual, false)
            else
                ADGraphManager:toggleConnectionBetween(own, target, false, j.dual, false)
            end
            joins = joins + 1
        else
            ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - no path to join within %.0f m of the lane %s at (%.1f, %.1f).",
                self.ROADRUNS_JOIN_RADIUS, j.atStart and "start" or "end", j.p.x, j.p.z)
        end
    end
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
    ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - built %d stretch(es): %d lane(s), %d point(s), %d join(s) to existing paths, %.0f m laid as one two-way line where two lanes did not fit, %s.",
        #s.picks, laid, points, joins, narrow, self.roadSubPrio and "secondary" or "primary")
    s.picks = {}
    s.sel, s.handlePress, s.handleDrag, s.handleHover = nil, nil, nil, nil
    s.netKey = nil
    self:roadRunsRefreshStretches()
    return true
end

-- ---------------------------------------------------------------------------------------------
-- drawing

local function drawLine(P, step, lw, r, g, b, lift)
    local prev = nil
    for i = 1, #P, step do
        local p = P[i]
        if not (finite(p.x) and finite(p.z) and finite(p.y or 0)) then return end
        if prev ~= nil then
            Draw:addLineTask(prev.x, (prev.y or 0) + lift, prev.z, p.x, (p.y or 0) + lift, p.z, lw, r, g, b)
        end
        prev = p
    end
    local last = P[#P]
    if prev ~= nil and prev ~= last and finite(last.x) and finite(last.z) and finite(last.y or 0) then
        Draw:addLineTask(prev.x, (prev.y or 0) + lift, prev.z, last.x, (last.y or 0) + lift, last.z, lw, r, g, b)
    end
end

--- The lanes a stretch would get, with heights, as drawn (cached per stretch and settings).
--- `hover`: the stretch is only under the mouse. Its side check then runs on bridges only, even with
--- "everywhere" set: probing a whole long road every time the mouse crosses it could stutter. Picked
--- stretches get the full check.
function E:roadRunsLanesFor(st, dir, hover)
    local mode = self:roadModeFor(st)
    local gap = self:roadGapFor(st)
    local everywhere = self.roadFitEverywhere and not hover
    local key = string.format("%s:%d:%.2f:%.1f:%.1f:%s", mode, dir or 1, gap, self.roadForkGap, self.roadRigWidth,
        tostring(everywhere))
    st.laneCache = st.laneCache or {}
    local lanes = st.laneCache[key]
    if lanes == nil then
        local fit = self:roadRunsFit()
        fit.everywhere = everywhere
        lanes = RF.planLanes(st, mode, dir, gap, self.roadForkGap, fit) or { links = {} }
        for _, ln in ipairs(lanes) do withHeights(ln.pts) end
        st.laneCache[key] = lanes
    end
    return lanes
end

function E:drawRoadRunLanes(lanes, lw, r, g, b)
    for _, lk in ipairs(lanes.links or {}) do
        local a, b2 = lanes[lk.from], lanes[lk.to]
        if a ~= nil and b2 ~= nil and #a.pts > 0 and #b2.pts > 0 then
            local p = lk.fromStart and a.pts[1] or a.pts[#a.pts]
            local q = lk.toEnd and b2.pts[#b2.pts] or b2.pts[1]
            Draw:addLineTask(p.x, p.y + 0.6, p.z, q.x, q.y + 0.6, q.z, lw, r, g, b)
        end
    end
    for _, ln in ipairs(lanes) do
        drawLine(ln.pts, 1, lw, r, g, b, 0.6)
        for i, p in ipairs(ln.pts) do
            Draw:addSphereTask(p.x, p.y + 0.6, p.z, 1.6, r, g, b, 0.15)
            -- an arrow tick every few points on one-way lanes, pointing the way of travel
            if not ln.dual and i > 1 and i % 3 == 0 then
                local q = ln.pts[i - 1]
                local hx, hz = p.x - q.x, p.z - q.z
                local hl = math.sqrt(hx * hx + hz * hz)
                if hl > 1e-6 then
                    hx, hz = hx / hl, hz / hl
                    local bx, bz = p.x - hx * 1.2, p.z - hz * 1.2
                    Draw:addLineTask(p.x, p.y + 0.6, p.z, bx - hz * 0.7, p.y + 0.6, bz + hx * 0.7, lw, r, g, b)
                    Draw:addLineTask(p.x, p.y + 0.6, p.z, bx + hz * 0.7, p.y + 0.6, bz - hx * 0.7, lw, r, g, b)
                end
            end
        end
    end
end

function E:drawRoadRuns(lw)
    if self.roadRunsBroken then return end
    local ok, err = pcall(self.drawRoadRunsInner, self, lw)
    if not ok then
        self.roadRunsBroken = true
        Logging.error("[FlyoverEditor]: road runs stopped after an error while drawing: %s", tostring(err))
    end
end

--- The detection view: ground paint round the mouse, what the walker read across the hovered road
--- and why it left readings out, the line before and after smoothing, and the map's own line.
function E:drawRoadView(lw)
    local s = self.roadRuns
    local cx, cz = self.cursorX, self.cursorZ
    if s == nil or cx == nil or not finite(cx) or not finite(cz) then return end
    local L = self.roadLayers
    local lift = 0.06
    local function seg(ax, az, bx, bz, w, r, g, b)
        if not (finite(ax) and finite(az) and finite(bx) and finite(bz)) then return end
        Draw:addLineTask(ax, terrainY(ax, az) + lift, az, bx, terrainY(bx, bz) + lift, bz, w, r, g, b)
    end
    -- ground paint: a short mark per cell (paved light grey, gravel yellow, dirt brown, field red)
    if L.paint then
        local st = self.ROADVIEW_STEP
        local gx, gz = math.floor(cx / 2) * 2, math.floor(cz / 2) * 2
        local cache = s.viewCells
        if cache == nil or cache.x ~= gx or cache.z ~= gz then
            cache = { x = gx, z = gz, cells = {} }
            local H = self.ROADVIEW_HALF
            for x = gx - H, gx + H, st do
                for z = gz - H, gz + H, st do
                    if RF.onMap(x, z) then
                        local k = kindAtWalk(x, z)
                        local col = nil
                        if k == RF.KIND_PAVED then col = { 0.85, 0.85, 0.85 }
                        elseif (k == RF.KIND_GRAVEL or k == RF.KIND_DIRT) and shoulderAtWalk(x, z) then col = { 0.45, 0.7, 1 }
                        elseif k == RF.KIND_GRAVEL then col = { 1, 0.85, 0.2 }
                        elseif k == RF.KIND_DIRT then col = { 0.6, 0.35, 0.1 }
                        elseif fieldAtWalk(x, z) then col = { 0.9, 0.2, 0.2 } end
                        if col ~= nil then
                            cache.cells[#cache.cells + 1] = { x = x, y = terrainY(x, z) + lift, z = z, c = col }
                        end
                    end
                end
            end
            s.viewCells = cache
        end
        local h = st * 0.35
        for _, c in ipairs(cache.cells) do
            Draw:addLineTask(c.x - h, c.y, c.z, c.x + h, c.y, c.z, lw, c.c[1], c.c[2], c.c[3])
        end
    end
    -- painted squares (to save): outlined in cyan
    if s.painted ~= nil then
        local T = self.ROADVIEW_TILE
        for _, t in pairs(s.painted) do
            local x0, z0 = t.tx * T, t.tz * T
            if math.abs(x0 - cx) < 150 and math.abs(z0 - cz) < 150 then
                seg(x0, z0, x0 + T, z0, lw, 0.2, 0.9, 1)
                seg(x0 + T, z0, x0 + T, z0 + T, lw, 0.2, 0.9, 1)
                seg(x0 + T, z0 + T, x0, z0 + T, lw, 0.2, 0.9, 1)
                seg(x0, z0 + T, x0, z0, lw, 0.2, 0.9, 1)
            end
        end
    end
    local hov = s.hover and self:roadRunsRefined(s.hover) or nil
    local D = hov ~= nil and hov.debug or nil
    -- what the walker read across the road: each band of road, the one it took green (or coloured by
    -- why it was left out), the others thin grey; a white post where the filtered line crossed
    if L.read and D ~= nil then
        for _, sc in ipairs(D.sections) do
            for _, b in ipairs(sc.bands) do
                local r, g, bl, w = 0.5, 0.5, 0.5, lw * 0.5
                if b.picked then
                    w = lw * 1.2
                    if sc.why ~= nil then
                        local c = self.ROADVIEW_WHY[sc.why] or { 1, 1, 1 }
                        r, g, bl = c[1], c[2], c[3]
                    else
                        r, g, bl = 0.2, 1, 0.3
                    end
                end
                seg(sc.x + sc.nx * b.lo, sc.z + sc.nz * b.lo, sc.x + sc.nx * b.hi, sc.z + sc.nz * b.hi, w, r, g, bl)
            end
            if #sc.bands == 0 then
                local c = self.ROADVIEW_WHY.none
                seg(sc.x - sc.nx * 0.3, sc.z - sc.nz * 0.3, sc.x + sc.nx * 0.3, sc.z + sc.nz * 0.3, lw, c[1], c[2], c[3])
            end
            if sc.off ~= nil then
                local px, pz = sc.x + sc.nx * sc.off, sc.z + sc.nz * sc.off
                if finite(px) and finite(pz) then
                    local y = terrainY(px, pz)
                    Draw:addLineTask(px, y, pz, px, y + 0.6, pz, lw, 1, 1, 1)
                end
            end
        end
    end
    -- lines: filtered (white), as laid (orange), both on the ground
    if L.lines and hov ~= nil then
        if D ~= nil and D.filtered ~= nil then
            for i = 2, #D.filtered do
                local a, b = D.filtered[i - 1], D.filtered[i]
                seg(a.x, a.z, b.x, b.z, lw * 0.7, 1, 1, 1)
            end
        end
        for i = 2, #hov.pts do
            local a, b = hov.pts[i - 1], hov.pts[i]
            seg(a.x, a.z, b.x, b.z, lw * 1.2, 1, 0.55, 0.1)
        end
    end
    -- the map maker's road lines near the mouse (cyan)
    if L.splines then
        local S = self:roadRunsSplines()
        if S ~= nil then
            local R = 60
            local seen = {}
            for gx = math.floor((cx - R) / 32), math.floor((cx + R) / 32) do
                for gz = math.floor((cz - R) / 32), math.floor((cz + R) / 32) do
                    for _, e in ipairs(S.grid[gx * 100003 + gz] or {}) do
                        local P = e.sp.pts
                        local key = e.sp.name .. ":" .. e.i
                        if e.i < #P and not seen[key] then
                            seen[key] = true
                            seg(P[e.i].x, P[e.i].z, P[e.i + 1].x, P[e.i + 1].z, lw, 0.2, 0.9, 1)
                        end
                    end
                end
            end
        end
    end
    self:drawRoadMid(lw, seg)
end

--- The ground as the game reads it round the mouse, saved for the offline tests: kinds every 0.25 m
--- over ROADVIEW_SAVE_HALF each way ('.' none, 'd' dirt, 'g' gravel, 'p' paved, 'F' field), and the
--- walk under the mouse (its raw path and laid line). modSettings/FS25_ADFlyoverEditor/roadArea_X_Z.xml
--- (2026-10-13: the offline map - an old save at 1 m - did not match what the game read, so fixes
--- tuned on it missed in game).
E.ROADVIEW_SAVE_HALF = 40
function E:roadRunsSaveArea()
    local last = roadState(self).lastMap
    if last == nil then return end
    local cx, cz = last.x, last.z
    if cx == nil or getUserProfileAppPath == nil or createXMLFile == nil then return end
    local folder = getUserProfileAppPath() .. "modSettings/FS25_ADFlyoverEditor/"
    createFolder(getUserProfileAppPath() .. "modSettings/")
    createFolder(folder)
    local path = string.format("%sroadArea_%d_%d.xml", folder, math.floor(cx), math.floor(cz))
    local xml = createXMLFile("ADFlyoverRoadArea", path, "roadArea")
    if xml == nil or xml == 0 then return end
    local H, st = self.ROADVIEW_SAVE_HALF, 0.25
    local x0, z0 = math.floor(cx - H), math.floor(cz - H)
    local n = math.floor(2 * H / st) + 1
    setXMLFloat(xml, "roadArea#x0", x0)
    setXMLFloat(xml, "roadArea#z0", z0)
    setXMLFloat(xml, "roadArea#step", st)
    setXMLInt(xml, "roadArea#n", n)
    local chars = { [RF.KIND_NONE] = ".", [RF.KIND_DIRT] = "d", [RF.KIND_GRAVEL] = "g", [RF.KIND_PAVED] = "p" }
    for j = 0, n - 1 do
        local row = {}
        local z = z0 + j * st + st / 2
        for i = 0, n - 1 do
            local x = x0 + i * st + st / 2
            local c = "."
            if RF.onMap(x, z) then
                local k = kindAtWalk(x, z)
                c = chars[k] or "."
                if c == "." and fieldAtWalk(x, z) then c = "F" end
            end
            row[#row + 1] = c
        end
        setXMLString(xml, string.format("roadArea.row(%d)#k", j), table.concat(row))
    end
    local hov = last.hover and self:roadRunsRefined(last.hover) or nil
    local function pts(P)
        local t = {}
        for _, p in ipairs(P or {}) do t[#t + 1] = string.format("%.2f,%.2f", p.x, p.z) end
        return table.concat(t, ";")
    end
    setXMLFloat(xml, "roadArea.mouse#x", cx)
    setXMLFloat(xml, "roadArea.mouse#z", cz)
    if hov ~= nil then
        setXMLString(xml, "roadArea.line#pts", pts(hov.pts))
        setXMLString(xml, "roadArea.walk#pts", pts(hov.raw))
        setXMLString(xml, "roadArea.line#class", tostring(hov.class))
    end
    saveXMLFile(xml)
    delete(xml)
    ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - saved the area round (%.1f, %.1f) to %s", cx, cz, path)
    if self.warnPlayer ~= nil then pcall(self.warnPlayer, self, "Saved this area for Claude: " .. path) end
end

--- Save every painted square: the ground the game reads every 0.25 m ('.', d, g, p, F), one tile
--- element per square, to modSettings/FS25_ADFlyoverEditor/roadPaint_N.xml.
function E:roadRunsSavePainted()
    local s = roadState(self)
    if s.painted == nil or getUserProfileAppPath == nil or createXMLFile == nil then return end
    local folder = getUserProfileAppPath() .. "modSettings/FS25_ADFlyoverEditor/"
    createFolder(getUserProfileAppPath() .. "modSettings/")
    createFolder(folder)
    local n = 1
    while fileExists ~= nil and fileExists(string.format("%sroadPaint_%d.xml", folder, n)) do n = n + 1 end
    local path = string.format("%sroadPaint_%d.xml", folder, n)
    local xml = createXMLFile("ADFlyoverRoadPaint", path, "roadArea")
    if xml == nil or xml == 0 then return end
    local count = self:roadRunsWriteTiles(xml, s.painted)
    saveXMLFile(xml)
    delete(xml)
    ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - saved %d painted squares to %s", count, path)
    if self.warnPlayer ~= nil then pcall(self.warnPlayer, self, string.format("Saved %d painted squares: %s", count, path)) end
end

--- Write squares ({ [key] = { tx, tz } }, ROADVIEW_TILE m each) as roadArea.tile(i) x0 z0 k: the ground
--- the game reads every 0.25 m ('.', d, g, p, F), row by row. Returns how many.
function E:roadRunsWriteTiles(xml, squares)
    local T, st = self.ROADVIEW_TILE, 0.25
    local per = math.floor(T / st)
    setXMLFloat(xml, "roadArea#step", st)
    setXMLFloat(xml, "roadArea#tile", T)
    local chars = { [RF.KIND_NONE] = ".", [RF.KIND_DIRT] = "d", [RF.KIND_GRAVEL] = "g", [RF.KIND_PAVED] = "p" }
    local keys = {}
    for k in pairs(squares) do keys[#keys + 1] = k end
    table.sort(keys)
    for i, k in ipairs(keys) do
        local t = squares[k]
        local x0, z0 = t.tx * T, t.tz * T
        local cells = {}
        for j = 0, per - 1 do
            local z = z0 + j * st + st / 2
            for c = 0, per - 1 do
                local x = x0 + c * st + st / 2
                local ch = chars[kindAtWalk(x, z)] or "."
                if ch == "." and fieldAtWalk(x, z) then ch = "F" end
                cells[#cells + 1] = ch
            end
        end
        local base = string.format("roadArea.tile(%d)", i - 1)
        setXMLFloat(xml, base .. "#x0", x0)
        setXMLFloat(xml, base .. "#z0", z0)
        setXMLString(xml, base .. "#k", table.concat(cells))
    end
    return #keys
end

-- ---------------------------------------------------------------------------------------------
-- test cases: the user draws a track's true middle; it is saved with the ground along it

--- A smooth curve through the points (centripetal Catmull-Rom: no loops or overshoot at sharp
--- corners), a point every `step` m. Each sample carries the index of the point it leaves from.
local function midCurve(P, step)
    local out = {}
    if #P == 0 then return out end
    if #P == 1 then return { { x = P[1].x, z = P[1].z, seg = 1 } } end
    local function knot(a, b)
        return math.max(1e-3, math.sqrt(math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)))
    end
    local function mix(a, b, ta, tb, t)
        local u = (t - ta) / (tb - ta)
        return { x = a.x + (b.x - a.x) * u, z = a.z + (b.z - a.z) * u }
    end
    for i = 1, #P - 1 do
        local p1, p2 = P[i], P[i + 1]
        local p0 = P[i - 1] or { x = 2 * p1.x - p2.x, z = 2 * p1.z - p2.z }
        local p3 = P[i + 2] or { x = 2 * p2.x - p1.x, z = 2 * p2.z - p1.z }
        local t0 = 0
        local t1 = t0 + knot(p0, p1)
        local t2 = t1 + knot(p1, p2)
        local t3 = t2 + knot(p2, p3)
        local len = math.sqrt((p2.x - p1.x) ^ 2 + (p2.z - p1.z) ^ 2)
        local n = math.max(1, math.ceil(len / step))
        for k = 0, n - 1 do
            local t = t1 + (t2 - t1) * k / n
            local a1, a2, a3 = mix(p0, p1, t0, t1, t), mix(p1, p2, t1, t2, t), mix(p2, p3, t2, t3, t)
            local b1, b2 = mix(a1, a2, t0, t2, t), mix(a2, a3, t1, t3, t)
            local c = mix(b1, b2, t1, t2, t)
            out[#out + 1] = { x = c.x, z = c.z, seg = i }
        end
    end
    out[#out + 1] = { x = P[#P].x, z = P[#P].z, seg = #P - 1 }
    return out
end

local function midState(self)
    local s = roadState(self)
    s.mid = s.mid or { pts = {} }
    return s.mid
end

local function midSamples(m)
    if m.curve == nil then m.curve = midCurve(m.pts, 0.5) end
    return m.curve
end

local function midLength(C)
    local L = 0
    for i = 2, #C do L = L + math.sqrt((C[i].x - C[i - 1].x) ^ 2 + (C[i].z - C[i - 1].z) ^ 2) end
    return L
end

local function nearestPoint(m, x, z, reach)
    local best, bd = nil, reach
    for i, p in ipairs(m.pts) do
        local d = math.sqrt((p.x - x) ^ 2 + (p.z - z) ^ 2)
        if d < bd then best, bd = i, d end
    end
    return best
end

--- Per frame while drawing the middle: which point is under the mouse, and drag the grabbed one.
function E:roadMidUpdate(overPanel)
    local m = midState(self)
    local cx, cz = self.cursorX, self.cursorZ
    if self.leftDown and not m.wasDown and not overPanel and cx ~= nil then
        m.drag = nearestPoint(m, cx, cz, self.ROADCASE_GRAB)
    end
    if not self.leftDown then m.drag = nil end
    if m.drag ~= nil and cx ~= nil and m.pts[m.drag] ~= nil then
        local p = m.pts[m.drag]
        if p.x ~= cx or p.z ~= cz then
            p.x, p.z = cx, cz
            m.curve, m.dragged = nil, true
        end
    end
    m.wasDown = self.leftDown
    m.hover = (cx ~= nil and not overPanel) and nearestPoint(m, cx, cz, self.ROADCASE_GRAB) or nil
end

--- A click adds a point: between two points when it is near the curve there, else on the nearer end.
function E:roadMidClick()
    local m = midState(self)
    if m.dragged then m.dragged = false return end      -- the end of a drag, not a new point
    local cx, cz = self.cursorX, self.cursorZ
    if cx == nil or nearestPoint(m, cx, cz, self.ROADCASE_GRAB) ~= nil then return end
    local at = #m.pts + 1
    if #m.pts >= 2 then
        local seg, bd = nil, 3
        for _, c in ipairs(midSamples(m)) do
            local d = math.sqrt((c.x - cx) ^ 2 + (c.z - cz) ^ 2)
            if d < bd then seg, bd = c.seg, d end
        end
        if seg ~= nil then
            at = seg + 1
        else
            local a, b = m.pts[1], m.pts[#m.pts]
            if (a.x - cx) ^ 2 + (a.z - cz) ^ 2 < (b.x - cx) ^ 2 + (b.z - cz) ^ 2 then at = 1 end
        end
    end
    table.insert(m.pts, at, { x = cx, z = cz })
    m.last, m.curve = at, nil
end

--- Right-click: take off the point under the mouse, or else the last one placed.
function E:roadMidRemove()
    local m = midState(self)
    if #m.pts == 0 then return false end
    local i = m.hover or m.last or #m.pts
    if m.pts[i] == nil then i = #m.pts end
    table.remove(m.pts, i)
    m.last, m.hover, m.curve = nil, nil, nil
    return true
end

--- Save the track: the ground along the curve (ROADCASE_HALF each side, plus any painted squares) and
--- the curve, to modSettings/FS25_ADFlyoverEditor/roadCases/track_N.xml. Then start a new middle.
function E:roadRunsSaveTrack()
    local s = roadState(self)
    local m = midState(self)
    if #m.pts < 2 or getUserProfileAppPath == nil or createXMLFile == nil then return end
    local C = midSamples(m)
    local T, H = self.ROADVIEW_TILE, self.ROADCASE_HALF
    local squares, count = {}, 0
    local function add(tx, tz)
        local key = tx * 100003 + tz
        if squares[key] == nil and RF.onMap(tx * T + T / 2, tz * T + T / 2) then
            squares[key] = { tx = tx, tz = tz }
            count = count + 1
        end
    end
    for i = 1, #C, 2 do
        local c = C[i]
        for tx = math.floor((c.x - H) / T), math.floor((c.x + H) / T) do
            for tz = math.floor((c.z - H) / T), math.floor((c.z + H) / T) do add(tx, tz) end
        end
    end
    for _, t in pairs(s.painted or {}) do add(t.tx, t.tz) end
    if count > self.ROADCASE_MAX_TILES then
        if self.warnPlayer ~= nil then
            pcall(self.warnPlayer, self, string.format("Track too long to save in one go (%.0f m) - save it in parts.", midLength(C)))
        end
        return
    end
    local base = getUserProfileAppPath() .. "modSettings/FS25_ADFlyoverEditor/"
    local folder = base .. "roadCases/"
    createFolder(getUserProfileAppPath() .. "modSettings/")
    createFolder(base)
    createFolder(folder)
    local n = 1
    while fileExists ~= nil and fileExists(string.format("%strack_%d.xml", folder, n)) do n = n + 1 end
    local path = string.format("%strack_%d.xml", folder, n)
    local xml = createXMLFile("ADFlyoverRoadCase", path, "roadArea")
    if xml == nil or xml == 0 then return end
    self:roadRunsWriteTiles(xml, squares)
    local function pts(P)
        local o = {}
        for _, p in ipairs(P) do o[#o + 1] = string.format("%.2f,%.2f", p.x, p.z) end
        return table.concat(o, " ")
    end
    setXMLFloat(xml, "roadArea.middle#half", H)
    setXMLString(xml, "roadArea.middle#clicks", pts(m.pts))
    setXMLString(xml, "roadArea.middle#pts", pts(C))
    saveXMLFile(xml)
    delete(xml)
    local len = midLength(C)
    ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - saved track %d: %.0f m of middle (%d points), %d squares of ground, to %s",
        n, len, #m.pts, count, path)
    if self.warnPlayer ~= nil then
        pcall(self.warnPlayer, self, string.format("Saved track %d (%.0f m): %s", n, len, path))
    end
    s.mid = nil
end

--- The middle being drawn: the curve (magenta), its points (posts; white under the mouse) and the
--- edges of the ground that will be saved (faint cyan).
function E:drawRoadMid(lw, seg)
    local m = self.roadRuns and self.roadRuns.mid or nil
    if m == nil or #m.pts == 0 then return end
    local cx, cz = self.cursorX, self.cursorZ
    local C = midSamples(m)
    local R = 300
    local function near(p) return cx == nil or (math.abs(p.x - cx) < R and math.abs(p.z - cz) < R) end
    for i = 2, #C do
        if near(C[i]) then seg(C[i - 1].x, C[i - 1].z, C[i].x, C[i].z, lw * 1.4, 1, 0.2, 0.9) end
    end
    if self.roadDrawMid then
        local H = self.ROADCASE_HALF
        local prev = nil
        for i = 1, #C, 4 do
            local a, b = C[math.max(1, i - 1)], C[math.min(#C, i + 1)]
            local dx, dz = b.x - a.x, b.z - a.z
            local l = math.sqrt(dx * dx + dz * dz)
            if l > 1e-6 then
                local nx, nz = -dz / l, dx / l
                local cur = { C[i].x + nx * H, C[i].z + nz * H, C[i].x - nx * H, C[i].z - nz * H }
                if prev ~= nil and near(C[i]) then
                    seg(prev[1], prev[2], cur[1], cur[2], lw * 0.5, 0.2, 0.9, 1)
                    seg(prev[3], prev[4], cur[3], cur[4], lw * 0.5, 0.2, 0.9, 1)
                end
                prev = cur
            end
        end
    end
    for i, p in ipairs(m.pts) do
        if near(p) then
            local y = terrainY(p.x, p.z)
            local r, g, b = 1, 0.2, 0.9
            if i == m.hover or i == m.drag then r, g, b = 1, 1, 1 end
            Draw:addLineTask(p.x, y, p.z, p.x, y + 1.5, p.z, lw * 2, r, g, b)
        end
    end
end

function E:drawRoadRunsInner(lw)
    local s = self.roadRuns
    if s == nil then return end
    if self.roadView then
        self:drawRoadView(lw)
        return
    end
    local cx, cz = self.cursorX, self.cursorZ
    local radius = AutoDrive.FLYOVER_DRAW_RADIUS or 200
    local pr, pg, pb = 0.3, 0.7, 1
    if self.roadSubPrio then pr, pg, pb = 1, 0.83, 0.3 end

    -- every unpathed road nearby, faint
    if self.roadShowAll and cx ~= nil then
        for _, st in ipairs(s.stretches) do
            if st ~= s.hover then
                local P = st.pts
                local near = false
                for i = 1, #P, 4 do
                    if math.abs(P[i].x - cx) < radius and math.abs(P[i].z - cz) < radius then near = true break end
                end
                if near then drawLine(P, 2, lw * 0.6, 0.55, 0.45, 0.15, 0.3) end
            end
        end
    end
    -- the picks, as they will be laid
    for _, pk in ipairs(s.picks) do
        self:drawRoadRunLanes(self:roadRunsLanesFor(pk.st, pk.dir), lw, pr, pg, pb)
        if pk == s.hoverPick and pk ~= s.sel then
            drawLine(pk.st.pts, 1, lw * 1.5, 1, 1, 1, 0.4)          -- white: a click selects it
        end
    end
    -- the selected pick's handles: ends larger, the one under the mouse (or dragged) bright
    local sel = s.sel
    if sel ~= nil and sel.handles ~= nil then
        drawLine(sel.st.pts, 1, lw * 1.2, 1, 1, 1, 0.5)
        for i, h in ipairs(sel.handles) do
            if finite(h.x) and finite(h.z) then
                local y = (h.y or terrainY(h.x, h.z)) + 0.8
                local isEnd = i == 1 or i == #sel.handles
                local hot = i == s.handleHover or i == s.handleDrag
                if hot then
                    Draw:addSphereTask(h.x, y, h.z, isEnd and 4 or 3, 1, 0.9, 0.1, 0.20)
                elseif h.wpId ~= nil then
                    Draw:addSphereTask(h.x, y, h.z, 4, 1, 0.9, 0.1, 0.15)          -- joined to a waypoint
                else
                    Draw:addSphereTask(h.x, y, h.z, isEnd and 4 or 3, 0.3, 0.8, 1, 0.15)
                end
            end
        end
    end
    -- the hovered stretch: bright, with its lanes previewed and the forks it stops short of
    local st = s.hover and self:roadRunsRefined(s.hover) or nil
    if st ~= nil then
        drawLine(st.pts, 1, lw * 1.5, 1, 0.69, 0.13, 0.4)
        self:drawRoadRunLanes(self:roadRunsLanesFor(st, s.hoverSide or 1, true), lw, 1, 0.85, 0.5)
        for _, n in ipairs({ st.startNode, st.endNode }) do
            if n ~= nil and n.tag == "fork" then
                Draw:addSphereTask(n.x, terrainY(n.x, n.z) + 0.8, n.z, 3, 1, 1, 1, 0.15)
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- the card

--- Card rows, built with the HUD's own kit (tgl, seg, segFlip, btn, add, numberAfter).
function E:roadRunsCard(kit)
    local s = roadState(self)
    local editor = self
    local opts = {}
    for i, name in ipairs(self.ROADRUNS_MODE_NAMES) do
        opts[i] = { label = name, active = self.roadMode == i, action = function()
            editor.roadMode = i
            editor:roadRunsSaveSettings()
        end }
    end
    kit.seg("lay as", opts)
    if self.ROADRUNS_MODE_KEYS[self.roadMode] == "auto" then
        kit.add("hint", "auto = two lanes on paved, two-way on tracks")
    end
    kit.segFlip("priority", "primary", "secondary", self.roadSubPrio, function()
        editor.roadSubPrio = not editor.roadSubPrio
        editor:roadRunsSaveSettings()
    end)
    kit.seg("roads to find", {
        { label = "paved", active = self.roadKinds[RF.KIND_PAVED], action = function() editor:roadRunsToggleKind(RF.KIND_PAVED) end },
        { label = "gravel", active = self.roadKinds[RF.KIND_GRAVEL], action = function() editor:roadRunsToggleKind(RF.KIND_GRAVEL) end },
        { label = "dirt", active = self.roadKinds[RF.KIND_DIRT], action = function() editor:roadRunsToggleKind(RF.KIND_DIRT) end },
    })
    kit.segFlip("view", "build", "detection", self.roadView, function()
        editor.roadView = not editor.roadView
    end)
    if self.roadView then
        local L = self.roadLayers
        kit.tgl("ground paint", L.paint, function() L.paint = not L.paint end)
        kit.tgl("road read", L.read, function() L.read = not L.read end)
        kit.tgl("lines", L.lines, function() L.lines = not L.lines end)
        kit.tgl("map lines", L.splines, function() L.splines = not L.splines end)
        local hov = s.hover and self:roadRunsRefined(s.hover) or nil
        if hov ~= nil and hov.debug ~= nil then
            local c = { used = 0, none = 0, junction = 0, wide = 0, jumped = 0 }
            for _, sc in ipairs(hov.debug.sections) do
                local k = sc.why or "used"
                c[k] = (c[k] or 0) + 1
            end
            kit.add("cursor", "read across", string.format("%d used of %d", c.used, #hov.debug.sections))
            kit.add("cursor", "left out", string.format("no road %d, junction %d, too wide %d, jumped %d",
                c.none, c.junction, c.wide, c.jumped))
        elseif hov ~= nil then
            kit.add("cursor", "read across", hov.fromSpline and "the map's own line: nothing read" or "no readings kept")
        end
        kit.add("hint", "green used; grey no road; purple junction; orange too wide; red jumped; white post = filtered middle")
        kit.tgl("paint area (left-drag)", self.roadPaint, function()
            editor.roadPaint = not editor.roadPaint
            if editor.roadPaint then editor.roadDrawMid = false end
        end)
        if (s.paintedN or 0) > 0 then
            kit.add("cursor", "painted", string.format("%d squares of %d m", s.paintedN, self.ROADVIEW_TILE))
            kit.btn("save painted", function() editor:roadRunsSavePainted() end)
            kit.btn("clear painted", function() s.painted, s.paintedN = nil, 0 end)
        end
        kit.btn("save this area (for offline tests)", function() editor:roadRunsSaveArea() end)
        kit.tgl("draw the middle (test case)", self.roadDrawMid, function()
            editor.roadDrawMid = not editor.roadDrawMid
            if editor.roadDrawMid then editor.roadPaint = false end
        end)
        local m = s.mid
        if m ~= nil and #m.pts > 0 then
            kit.add("cursor", "middle", string.format("%d points, %.0f m", #m.pts, midLength(midSamples(m))))
            if #m.pts >= 2 then kit.btn("save track (ground + middle)", function() editor:roadRunsSaveTrack() end) end
            kit.btn("clear middle", function() s.mid = nil end)
        end
        if self.roadDrawMid then
            kit.add("hint", "click points along the true middle; drag a point to move it; right-click takes one off")
        end
        return
    end
    kit.segFlip("light up", "under mouse", "all nearby", self.roadShowAll, function()
        editor.roadShowAll = not editor.roadShowAll
        editor:roadRunsSaveSettings()
    end)

    kit.segFlip("lane gap", "from road", "set", not self.roadGapAuto, function()
        editor.roadGapAuto = not editor.roadGapAuto
        editor:roadRunsSaveSettings()
    end)
    kit.numberAfter("lane gap")
    local st = (s.hover and self:roadRunsRefined(s.hover)) or (s.picks[#s.picks] ~= nil and s.picks[#s.picks].st) or nil
    if st ~= nil and st.width ~= nil then
        kit.add("cursor", "this road", string.format("%.1f m wide, lanes %.1f m apart", st.width, self:roadGapFor(st)))
    end
    if s.mapGap ~= nil then
        kit.add("cursor", "map's own lanes", string.format("%.1f m apart", s.mapGap))
    end
    if not self.roadGapAuto and self.roadLaneGap < self:roadMinGap() then
        kit.add("hint", string.format("under %.1f m: the lanes are put %.1f m apart", self:roadMinGap(), self:roadMinGap()))
    end
    kit.segFlip("side check", "bridges", "everywhere", self.roadFitEverywhere, function()
        editor.roadFitEverywhere = not editor.roadFitEverywhere
        editor:roadRunsSaveSettings()
    end)
    kit.numberAfter("rig width")
    kit.add("hint", "lanes come in from railings and banks; too narrow = one two-way line")
    local hovering = s.hover ~= nil and st == s.hover.refinedTo
    local lanes = st ~= nil and self:roadRunsLanesFor(st, (hovering and s.hoverSide) or 1, hovering) or nil
    if lanes ~= nil and (lanes.collapsed or 0) > 0 then
        kit.add("cursor", "too narrow for two", string.format("%.0f m as one two-way line", lanes.collapsed))
    elseif lanes ~= nil and lanes.pulled then
        kit.add("cursor", "side check", "lanes moved in to clear the sides")
    end
    if lanes ~= nil and lanes.tooNarrow then
        kit.add("hint", string.format("narrower than one %.1f m rig somewhere on this road", self.roadRigWidth))
    end
    kit.numberAfter("fork gap")
    kit.add("hint", "room left at forks for the junction tool")

    if s.job ~= nil or (s.progress or 1) < 1 then
        kit.add("cursor", "reading the ground", string.format("%d%%", math.floor((s.progress or 0) * 100)))
    end
    local n, L = self:roadRunsPickedLength()
    kit.add("cursor", "picked", n > 0 and string.format("%d stretch%s, %.0f m", n, n == 1 and "" or "es", L) or "-")
    if n > 0 then
        kit.btn("build (right-click)", function() editor:commitRoadRuns() end)
        kit.btn("clear picks", function() editor:roadRunsClearPicks() end)
        if s.sel ~= nil then
            kit.add("cursor", "selected run", string.format("%d handles, %.0f m%s", #(s.sel.handles or {}), s.sel.st.len or 0,
                s.sel.st.edited and ", shaped" or ""))
            kit.add("hint", "drag a handle to shape; click the line to add one; ctrl-click one to remove; alt: ends do not snap")
            kit.btn("drop selected run", function() editor:roadRunsDropSelected() end)
        end
    end
    if RF.noRockCheck then
        kit.add("hint", "not the host: rock may light up as paved")
    end
end

function E:roadRunsToggleKind(kind)
    local s = roadState(self)
    self.roadKinds[kind] = not self.roadKinds[kind]
    self:roadRunsSaveSettings()
    -- the road lines depend on the kinds (they are thinned per class): read the window again
    s.win, s.job, s.jobKey = nil, nil, nil
end

--- Typed numbers on the card (getEditableNumbers hands over its fieldEntry builder).
function E:roadRunsNumbers(fieldEntry)
    roadState(self)
    local editor = self
    local function save() editor:roadRunsSaveSettings() end
    local list = {}
    if not self.roadGapAuto then
        list[#list + 1] = fieldEntry("lane gap", "m", 1, "roadLaneGap", 2.5, 8, 0.1, false, save)
    end
    list[#list + 1] = fieldEntry("rig width", "m", 1, "roadRigWidth", 2.0, 5.0, 0.1, false, save)
    list[#list + 1] = fieldEntry("fork gap", "m", 1, "roadForkGap", 0, 40, 0.5, false, save)
    return list
end

function E:roadRunsNextStep()
    local s = self.roadRuns
    local function L(t) return ADFlyoverLocale ~= nil and ADFlyoverLocale.t(t) or t end
    if s ~= nil and #s.picks > 0 then
        return L("Click more roads, double-click for a whole road. Right-click builds.")
    end
    if s ~= nil and s.hover ~= nil then
        return L("Click to pick this road, double-click for the whole road.")
    end
    return L("Point at a road with no AutoDrive path - it lights up.")
end

--- Right-click: build what is picked. Returns true if there was something.
function E:roadRunsStop()
    local s = self.roadRuns
    if self.roadView and self.roadDrawMid then return self:roadMidRemove() end
    if s ~= nil and #s.picks > 0 then
        self:commitRoadRuns()
        return true
    end
    return false
end

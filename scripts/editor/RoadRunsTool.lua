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
lines are worked out in a coroutine so a big window never stalls a frame. The window follows the
mouse; picks are kept as their own copies, so they survive the window moving.

Loaded after FlyoverEditor.lua (it adds to ADFlyoverEditor), see Prelude.EDITOR_FILES.
]]

local RF = ADRoadFinder
local E = ADFlyoverEditor

E.TOOL.ROADRUNS = 16
E.TOOL_NAMES[E.TOOL.ROADRUNS] = "road runs"

E.ROADRUNS_WINDOW = 384            -- metres a side of the ground read round the mouse
E.ROADRUNS_RECENTRE = 96           -- the window moves when the mouse is this far from its middle
E.ROADRUNS_SNAP = 32               -- window centres snap to this grid, so a small wobble re-uses it
E.ROADRUNS_SAMPLES_PER_FRAME = 2500
E.ROADRUNS_MIN_LANE_GAP = 3.3      -- two passing rigs ~2.8-3.0 m wide need about this between lane centres
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
E.roadForkGap = 15

local function roadState(self)
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
        return (st ~= nil and st.class == "paved") and "lanes" or "two"
    end
    return key
end

--- Lane centre gap for a stretch: the road's own width split in two (each lane in the middle of its
--- half) when auto, else the typed value; never under the minimum.
function E:roadGapFor(st)
    local gap = self.roadLaneGap
    if self.roadGapAuto and st ~= nil and st.width ~= nil then
        gap = st.width / 2
        if self.roadRuns ~= nil and self.roadRuns.mapGap ~= nil then
            gap = math.min(gap, self.roadRuns.mapGap + 1.0)
        end
        gap = math.min(gap, 6)
    end
    return math.max(self.ROADRUNS_MIN_LANE_GAP, gap)
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

local function terrainY(x, z)
    local terrain = g_currentMission ~= nil and g_currentMission.terrainRootNode or nil
    if terrain == nil then return 0 end
    return getTerrainHeightAtWorldPos(terrain, x, 0, z) or 0
end

local function withHeights(pts)
    for _, p in ipairs(pts) do
        if p.y == nil then p.y = terrainY(p.x, p.z) end
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
end

--- What is under the mouse: a stretch with no path, or a picked one. Works on whatever stretches the
--- last finished read found, so it keeps working while the window is being read again.
function E:roadRunsHover(overPanel)
    local s = roadState(self)
    local cx, cz = self.cursorX, self.cursorZ
    if overPanel then
        s.hover = nil
    else
        local st = RF.stretchNear(s.stretches, cx, cz, 3)
        s.hover = st
        if st ~= nil then s.hoverSide = RF.sideOf(st, cx, cz) end
        s.hoverPick = nil
        if st == nil then
            -- over a picked stretch?
            local best, bd = nil, math.huge
            for _, pk in ipairs(s.picks) do
                local p, d = RF.stretchNear({ pk.st }, cx, cz, 3)
                if p ~= nil and d < bd then best, bd = pk, d end
            end
            s.hoverPick = best
        end
    end
end

--- Per frame: keep the window round the mouse, sample a budget of ground, run the road-line job.
function E:updateRoadRuns(overPanel)
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
            RF.cacheStep(s.cache, self.ROADRUNS_SAMPLES_PER_FRAME)
            return
        end
        local kinds = {}
        for k, v in pairs(self.roadKinds) do kinds[k] = v end
        local cache = s.cache
        s.jobKey = jobKey
        s.job = coroutine.create(function()
            RF.yielding = true
            local win = RF.buildWindow(function(ix, iz) return RF.cacheKind(cache, ix, iz) end,
                ix0, iz0, self.ROADRUNS_WINDOW, self.ROADRUNS_WINDOW, { kinds = kinds })
            RF.yielding = false
            return win
        end)
        s.progress = 0.85
    end
    if s.job ~= nil then
        local ok, result = coroutine.resume(s.job)
        if not ok then
            Logging.error("[FlyoverEditor]: road runs - reading the roads failed: %s", tostring(result))
            s.job, s.jobKey = nil, nil
            RF.yielding = false
            s.win = { key = jobKey, edges = {}, nodes = {}, ix0 = ix0, iz0 = iz0, W = 0, H = 0 }
            s.stretches = {}
            return
        end
        if coroutine.status(s.job) == "dead" then
            s.win = result
            s.win.key = s.jobKey
            s.builds = (s.builds or 0) + 1
            s.job, s.jobKey = nil, nil
            s.progress = 1
            s.netKey = netKey
            self:roadRunsRefreshStretches()
            ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - window (%d, %d): %d road lines, %d stretches with no path%s.",
                ix0, iz0, #s.win.edges, #s.stretches, RF.noRockCheck and " (no drive-cost map: rock may read as paved)" or "")
        else
            s.progress = math.min(0.98, (s.progress or 0.85) + 0.01)
        end
    end

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
    local s = roadState(self)
    local now = self:nowMs()
    local last = s.lastClick
    local isDouble = last ~= nil and (now - last.at) < self.DOUBLE_CLICK_MS
    s.lastClick = { at = now }

    if isDouble and last.pick ~= nil then
        -- double-click: the stretch the first click picked, carried on through forks both ways
        local count = 0
        for _, atEnd in ipairs({ true, false }) do
            local cur, curAtEnd = last.pick.st, atEnd
            for _ = 1, 40 do
                local nxt = continueThrough(s, cur, curAtEnd)
                if nxt == nil then break end
                local already = false
                for _, pk in ipairs(s.picks) do if pk.st == nxt.st then already = true end end
                if already then break end
                -- one-way: keep the same direction of travel along the chain
                local dir = last.pick.dir
                local sameOrder = (curAtEnd and nxt.forward) or ((not curAtEnd) and not nxt.forward)
                local cdir = (cur == last.pick.st) and dir or (s.chainDir[cur] or dir)
                local ndir = sameOrder and cdir or -cdir
                s.chainDir[nxt.st] = ndir
                addPick(s, nxt.st, ndir)
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
        if #self:roadRunsLanesFor(st, s.hoverSide or 1) == 0 then
            self:warnPlayer(string.format("This stretch is too short to lay with %d m left at its forks - lower the fork gap.",
                self.roadForkGap))
            return
        end
        local pick = { st = st, dir = s.hoverSide or 1 }
        s.picks[#s.picks + 1] = pick
        s.chainDir = {}
        s.lastClick.pick = pick
        ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - picked a %s stretch, %.0f m, %.1f m wide (%s to %s).",
            RF.KIND_NAMES[st.kind] or "?", st.len, st.width or -1, st.startTag, st.endTag)
        self:roadRunsRefreshStretches()
    elseif s.hoverPick ~= nil then
        for k, pk in ipairs(s.picks) do
            if pk == s.hoverPick then table.remove(s.picks, k) break end
        end
        s.hoverPick = nil
        self:roadRunsRefreshStretches()
    end
end

function E:roadRunsClearPicks()
    local s = roadState(self)
    s.picks = {}
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
                -- a loose end of the old network
                if owner[wp.id] == nil and neighbourCount(wp) <= 1 then
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
                if score == nil and c ~= nil then
                    local cc = j.dual and math.abs(c) or c
                    local ahead = dx * hx + dz * hz
                    if j.atStart then ahead = -ahead end
                    if cc > 0.7 and ahead > -2 then score = d + (1 - cc) * 10 end
                end
                if score ~= nil and score < bestScore then best, bestScore = wp, score end
            end
        end
    end
    return best
end

--- Build every picked stretch. One undo step for all of it.
function E:commitRoadRuns()
    local s = roadState(self)
    if #s.picks == 0 then return false end
    ADEditorHistory:snapshot("road runs")
    local flags = self.roadSubPrio and AutoDrive.FLAG_SUBPRIO or AutoDrive.FLAG_NONE
    local laid, points, joins = 0, 0, 0
    local pending = {}       -- ends to join once everything is laid (a pick may join another pick)
    local owner = {}         -- point id -> the pick that laid it, this build
    for pickIndex, pk in ipairs(s.picks) do
        local st = pk.st
        local mode = self:roadModeFor(st)
        local lanes = RF.planLanes(st, mode, pk.dir, self:roadGapFor(st), self.roadForkGap)
        for _, ln in ipairs(lanes or {}) do
            if #ln.pts >= 2 then
                local firstId, lastId = self:createRunFrom(withHeights(ln.pts), ln.dual, flags)
                if firstId ~= nil and lastId ~= nil then
                    for id = firstId, lastId do owner[id] = pickIndex end
                    laid = laid + 1
                    points = points + (lastId - firstId + 1)
                    -- which end of the lane sits at which end of the stretch: lanes run along the
                    -- stretch's point order unless reversed (the back lane, or a one-way laid against it)
                    local P = ln.pts
                    local alongOrder
                    if ln.side == 1 then alongOrder = true
                    elseif ln.side == -1 then alongOrder = false
                    else alongOrder = (mode ~= "one") or (pk.dir or 1) >= 0 end
                    local startTag = alongOrder and st.startTag or st.endTag
                    local endTag = alongOrder and st.endTag or st.startTag
                    if startTag == "path" then
                        pending[#pending + 1] = { pick = pickIndex, id = firstId, p = P[1], h = { P[2].x - P[1].x, P[2].z - P[1].z }, atStart = true, dual = ln.dual }
                    end
                    if endTag == "path" then
                        local n = #P
                        pending[#pending + 1] = { pick = pickIndex, id = lastId, p = P[n], h = { P[n].x - P[n - 1].x, P[n].z - P[n - 1].z }, atStart = false, dual = ln.dual }
                    end
                end
            end
        end
    end
    for _, j in ipairs(pending) do
        local own = ADGraphManager:getWayPointById(j.id)
        local target = joinTarget(j, owner, j.pick, self.ROADRUNS_JOIN_RADIUS)
        if target ~= nil and own ~= nil then
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
    ADFlyoverSettings.debugLog("[FlyoverEditor]: road runs - built %d stretch(es): %d lane(s), %d point(s), %d join(s) to existing paths, %s.",
        #s.picks, laid, points, joins, self.roadSubPrio and "secondary" or "primary")
    s.picks = {}
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
        if prev ~= nil then
            ADDrawingManager:addLineTask(prev.x, (prev.y or 0) + lift, prev.z, p.x, (p.y or 0) + lift, p.z, lw, r, g, b)
        end
        prev = p
    end
    local last = P[#P]
    if prev ~= nil and prev ~= last then
        ADDrawingManager:addLineTask(prev.x, (prev.y or 0) + lift, prev.z, last.x, (last.y or 0) + lift, last.z, lw, r, g, b)
    end
end

--- The lanes a stretch would get, with heights, as drawn (cached per stretch and settings).
function E:roadRunsLanesFor(st, dir)
    local mode = self:roadModeFor(st)
    local gap = self:roadGapFor(st)
    local key = string.format("%s:%d:%.2f:%d", mode, dir or 1, gap, self.roadForkGap)
    st.laneCache = st.laneCache or {}
    local lanes = st.laneCache[key]
    if lanes == nil then
        lanes = RF.planLanes(st, mode, dir, gap, self.roadForkGap) or {}
        for _, ln in ipairs(lanes) do withHeights(ln.pts) end
        st.laneCache[key] = lanes
    end
    return lanes
end

function E:drawRoadRunLanes(lanes, lw, r, g, b)
    for _, ln in ipairs(lanes) do
        drawLine(ln.pts, 1, lw, r, g, b, 0.6)
        for i, p in ipairs(ln.pts) do
            ADDrawingManager:addSphereTask(p.x, p.y + 0.6, p.z, 1.6, r, g, b, 0.15)
            -- an arrow tick every few points on one-way lanes, pointing the way of travel
            if not ln.dual and i > 1 and i % 3 == 0 then
                local q = ln.pts[i - 1]
                local hx, hz = p.x - q.x, p.z - q.z
                local hl = math.sqrt(hx * hx + hz * hz)
                if hl > 1e-6 then
                    hx, hz = hx / hl, hz / hl
                    local bx, bz = p.x - hx * 1.2, p.z - hz * 1.2
                    ADDrawingManager:addLineTask(p.x, p.y + 0.6, p.z, bx - hz * 0.7, p.y + 0.6, bz + hx * 0.7, lw, r, g, b)
                    ADDrawingManager:addLineTask(p.x, p.y + 0.6, p.z, bx + hz * 0.7, p.y + 0.6, bz - hx * 0.7, lw, r, g, b)
                end
            end
        end
    end
end

function E:drawRoadRuns(lw)
    local s = self.roadRuns
    if s == nil then return end
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
        if pk == s.hoverPick then
            drawLine(pk.st.pts, 1, lw * 1.5, 1, 0.3, 0.3, 0.4)    -- red: a click drops it
        end
    end
    -- the hovered stretch: bright, with its lanes previewed and the forks it stops short of
    local st = s.hover
    if st ~= nil then
        drawLine(st.pts, 1, lw * 1.5, 1, 0.69, 0.13, 0.4)
        self:drawRoadRunLanes(self:roadRunsLanesFor(st, s.hoverSide or 1), lw, 1, 0.85, 0.5)
        for _, n in ipairs({ st.startNode, st.endNode }) do
            if n ~= nil and n.tag == "fork" then
                ADDrawingManager:addSphereTask(n.x, terrainY(n.x, n.z) + 0.8, n.z, 3, 1, 1, 1, 0.15)
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
        end }
    end
    kit.seg("lay as", opts)
    if self.ROADRUNS_MODE_KEYS[self.roadMode] == "auto" then
        kit.add("hint", "auto = two lanes on paved, two-way on tracks")
    end
    kit.segFlip("priority", "primary", "secondary", self.roadSubPrio, function()
        editor.roadSubPrio = not editor.roadSubPrio
    end)
    kit.seg("roads to find", {
        { label = "paved", active = self.roadKinds[RF.KIND_PAVED], action = function() editor:roadRunsToggleKind(RF.KIND_PAVED) end },
        { label = "gravel", active = self.roadKinds[RF.KIND_GRAVEL], action = function() editor:roadRunsToggleKind(RF.KIND_GRAVEL) end },
        { label = "dirt", active = self.roadKinds[RF.KIND_DIRT], action = function() editor:roadRunsToggleKind(RF.KIND_DIRT) end },
    })
    kit.segFlip("light up", "under mouse", "all nearby", self.roadShowAll, function()
        editor.roadShowAll = not editor.roadShowAll
    end)

    kit.segFlip("lane gap", "from road", "set", not self.roadGapAuto, function()
        editor.roadGapAuto = not editor.roadGapAuto
    end)
    kit.numberAfter("lane gap")
    local st = s.hover or (s.picks[#s.picks] ~= nil and s.picks[#s.picks].st) or nil
    if st ~= nil and st.width ~= nil then
        kit.add("cursor", "this road", string.format("%.1f m wide, lanes %.1f m apart", st.width, self:roadGapFor(st)))
    end
    if s.mapGap ~= nil then
        kit.add("cursor", "map's own lanes", string.format("%.1f m apart", s.mapGap))
    end
    if not self.roadGapAuto and self.roadLaneGap < self.ROADRUNS_MIN_LANE_GAP then
        kit.add("hint", string.format("under %.1f m: big rigs may not pass", self.ROADRUNS_MIN_LANE_GAP))
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
    end
    if RF.noRockCheck then
        kit.add("hint", "not the host: rock may light up as paved")
    end
end

function E:roadRunsToggleKind(kind)
    self.roadKinds[kind] = not self.roadKinds[kind]
    local s = roadState(self)
    -- the road lines depend on the kinds (they are thinned per class): read the window again
    s.win, s.job, s.jobKey = nil, nil, nil
end

--- Typed numbers on the card (getEditableNumbers hands over its fieldEntry builder).
function E:roadRunsNumbers(fieldEntry)
    local list = {}
    if not self.roadGapAuto then
        list[#list + 1] = fieldEntry("lane gap", "m", 1, "roadLaneGap", 2.5, 8, 0.1, false)
    end
    list[#list + 1] = fieldEntry("fork gap", "m", 0, "roadForkGap", 0, 40, 1, true)
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
    if s ~= nil and #s.picks > 0 then
        self:commitRoadRuns()
        return true
    end
    return false
end

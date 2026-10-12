-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua
-- loads it after FlyoverEditor.lua, in the old file's order.
-- MODSPLIT: HELPERS FROM THE FILES LOADED BEFORE THIS ONE (tools/modsplit/split.py writes this block)
for _, name in ipairs({ "junctionPlacePattern", "junctionRouteCheck", "junctionShareCrossings", "junctionTieTidy", "jxBuildBegin", "jxBuildEnd", "jxState", "jxpUnit", "tryCall" }) do
    if ADFlyoverEditor.shared == nil or ADFlyoverEditor.shared[name] == nil then
        Logging.error("[FlyoverEditor]: JxPlaceCheck.lua needs %s, which no file loaded before it shares", name)
    end
end
local junctionPlacePattern = ADFlyoverEditor.shared.junctionPlacePattern
local junctionRouteCheck = ADFlyoverEditor.shared.junctionRouteCheck
local junctionShareCrossings = ADFlyoverEditor.shared.junctionShareCrossings
local junctionTieTidy = ADFlyoverEditor.shared.junctionTieTidy
local jxBuildBegin = ADFlyoverEditor.shared.jxBuildBegin
local jxBuildEnd = ADFlyoverEditor.shared.jxBuildEnd
local jxState = ADFlyoverEditor.shared.jxState
local jxpUnit = ADFlyoverEditor.shared.jxpUnit
local tryCall = ADFlyoverEditor.shared.tryCall
-- MODSPLIT: end of the helpers

-- THE ROUTE CHECK FOR A PLACED PIECE (doc 08 step 4). The build's check (junctionRouteCheck) wants the
-- junction's lanes in and out and the turns meant; place works those out from the piece itself:
--   * lanes in and out: every lane crossing a circle three lane gaps out from the piece's centre;
--   * roads: those lanes grouped by their direction from the centre (in and out of one road sit
--     side by side);
--   * meant: every lane in to every lane out on another road - no U-turns.
-- Then the same check: routes AutoDrive could drive that we didn't mean, and meant turns it can't.
local function junctionPlaceRouteCheck(res)
    local cx, cz = res.ox, res.oz
    local Rc = math.max(12, 3 * (res.L or 4))
    local aps, seen = {}, {}
    local ldx, ldz = 0, 0
    local function add(w, dir)
        local k = tostring(w) .. dir
        if seen[k] then return end
        seen[k] = true
        aps[#aps + 1] = { wp = w, dir = dir, bearing = math.atan2(w.x - cx, w.z - cz), dx = ldx, dz = ldz }
    end
    for _, a in pairs(ADGraphManager:getWayPoints()) do
        if a ~= nil and a.id ~= nil then
            local ain = (a.x - cx) ^ 2 + (a.z - cz) ^ 2 <= Rc * Rc
            for _, bid in ipairs(a.out or {}) do
                local b = ADGraphManager:getWayPointById(bid)
                if b ~= nil then
                    local bin = (b.x - cx) ^ 2 + (b.z - cz) ^ 2 <= Rc * Rc
                    if ain ~= bin then ldx, ldz = jxpUnit(b.x - a.x, b.z - a.z) end
                    if not ain and bin then add(a, "in") elseif ain and not bin then add(b, "out") end
                end
            end
        end
    end
    if #aps == 0 then return nil end
    -- Roads: two approaches are one road's two lanes when they run parallel (either way), sit side by side
    -- (within 1.6 lane gaps across) and on the same side of the centre. Not by direction from the centre
    -- alone: a side road meeting far off square (j7, 47 degrees) comes in right beside the main road's arm.
    local road, L0 = {}, res.L or 4
    local function find(i) while road[i] ~= i do i = road[i] end return i end
    for i = 1, #aps do road[i] = i end
    for i = 1, #aps do
        for j = i + 1, #aps do
            local a, b = aps[i], aps[j]
            local par = math.abs(a.dx * b.dx + a.dz * b.dz) > 0.94
            local across = math.abs((b.wp.x - a.wp.x) * a.dz - (b.wp.z - a.wp.z) * a.dx)
            local gap = math.abs(a.bearing - b.bearing)
            if gap > math.pi then gap = 2 * math.pi - gap end
            if par and across < 1.6 * L0 and gap < math.rad(60) then road[find(i)] = find(j) end
        end
    end
    local roots, arm = {}, 0
    for i = 1, #aps do
        local r = find(i)
        if roots[r] == nil then arm = arm + 1 roots[r] = arm end
        road[i] = roots[r]
    end    local moves, placedSet = {}, {}
    for i, a in ipairs(aps) do
        if a.dir == "in" then
            for j, b in ipairs(aps) do
                if b.dir == "out" and road[i] ~= road[j] then
                    local m = { from = { wp = a.wp }, to = { wp = b.wp }, exists = false }
                    moves[#moves + 1] = m
                    placedSet[m] = true
                end
            end
        end
    end
    local rc = junctionRouteCheck({ approaches = aps, movements = moves }, placedSet, cx, cz, Rc)
    if rc == nil then return nil end
    rc.roads, rc.meant = math.max(arm, 1), #moves
    -- A ROAD NO ROUTE REACHES AT ALL isn't part of this piece: a lane of something else crossing the
    -- circle (j34), or a plain piece's arm left loose. Its turns are counted apart as "not joined" instead
    -- of as turns that can't be driven.
    local roadOf = {}
    for i, a in ipairs(aps) do roadOf[tostring(a.wp) .. a.dir] = road[i] end
    local meantBy, missBy = {}, {}
    for _, m in ipairs(moves) do
        for _, r in ipairs({ roadOf[tostring(m.from.wp) .. "in"], roadOf[tostring(m.to.wp) .. "out"] }) do
            meantBy[r] = (meantBy[r] or 0) + 1
        end
    end
    for _, e in ipairs(rc.missing or {}) do
        for _, r in ipairs({ roadOf[tostring(e.from) .. "in"], roadOf[tostring(e.to) .. "out"] }) do
            missBy[r] = (missBy[r] or 0) + 1
        end
    end
    local unjoined = {}
    for r, n in pairs(meantBy) do if (missBy[r] or 0) >= n then unjoined[r] = true end end
    local kept, nUn = {}, 0
    for _ in pairs(unjoined) do nUn = nUn + 1 end
    for _, e in ipairs(rc.missing or {}) do
        if not unjoined[roadOf[tostring(e.from) .. "in"]] and not unjoined[roadOf[tostring(e.to) .. "out"]] then
            kept[#kept + 1] = e
        end
    end
    rc.missing, rc.unjoined = kept, nUn
    return rc
end

--- THE JUNCTION'S MOVEMENTS, COUNTED AT 15 M whatever the search radius is set to (the pattern's test,
--- step A, in game 2026-10-12): at the user's 22 m the build's circle took in more than the junction - the
--- course's J4 read 12 movements and 1e, its twin 1w being inside the circle, 4 - so the T was refused
--- where it fitted. 15 m is what every survey result was measured at. Worked out with the road, obstacle
--- and swept checks off: they refuse turns but never change which turns there are.
function ADFlyoverEditor:junctionMovementsAt15(jp)
    local R = self:junctionRadiusValue()
    if math.abs(R - 15) < 0.5 or self._jxCountAt15 then return #(jp.movements or {}) end
    local keep = { self.junctionRadius, self.junctionPreview, self.junctionPreviewKey, self.junctionSite,
        self.junctionRefused, self.junctionSwept, self.junctionCheckSurface, self.junctionCheckObstacles }
    self._jxCountAt15 = true
    self.junctionRadius, self.junctionSwept, self.junctionCheckSurface, self.junctionCheckObstacles = 15, false, false, false
    self.junctionPreview, self.junctionPreviewKey = nil, nil
    local n = #(jp.movements or {})
    tryCall("junction build: the pattern's count at 15 m", function()
        self:updateJunctionPreview()
        local p15 = self.junctionPreview
        if p15 ~= nil and not p15.clearMode and not p15.placeMode then n = #(p15.movements or {}) end
    end)
    self.junctionRadius, self.junctionPreview, self.junctionPreviewKey, self.junctionSite = keep[1], keep[2], keep[3], keep[4]
    self.junctionRefused, self.junctionSwept, self.junctionCheckSurface, self.junctionCheckObstacles = keep[5], keep[6], keep[7], keep[8]
    self._jxCountAt15 = false
    return n
end

--- DOES THE PATTERN FIT, dry: the build's own test (junctionBuildAsPattern), asked without laying
--- anything, so the card can say before the right-click what the build will do (doc 12). Returns the
--- site and place's plan where the pattern (junctionPattern: mod or smooth) fits every road, else nil
--- and why not.
function ADFlyoverEditor:junctionPatternFit(jp)
    local site = self.junctionSite
    if site ~= nil and not site.virgin then
        return nil, nil, "turn wiring is still here"
    end
    if site == nil then
        -- A cleared junction the finder no longer sees: the numbered list anchors it, as for place. A
        -- junction split into parts is anchored by its parts, each its own junction (the course's pair:
        -- 1w lies 15.3 m from the pair's middle, and was not found).
        local bd = 15 * 15
        for _, e in ipairs(self:junctionRegistry() or {}) do
            local spots = { e }
            if e.decision == "split" and e.parts ~= nil and #e.parts >= 2 then spots = e.parts end
            for _, q in ipairs(spots) do
                local d = (q.x - jp.cx) ^ 2 + (q.z - jp.cz) ^ 2
                if d < bd then site, bd = { x = q.x, z = q.z, virgin = true }, d end
            end
        end
    end
    if site == nil then
        return nil, nil, "no junction place knows here"
    end
    local shape = self.junctionPattern or "exact"
    local ok, res, why = tryCall("junction build: does the pattern fit", function()
        return junctionPlacePattern(site.x, site.z, 15, shape, true)
    end)
    if not ok or res == nil then
        return nil, nil, tostring(why or "it does not fit")
    end
    if #(res.loose or {}) > 0 then
        return nil, nil, string.format("it would leave %d lane end(s) loose", #res.loose)
    end
    -- ONLY A PLAIN TWO-LANE T OR X: the pattern lays 6 movements on a T and 12 on an X, so the junction
    -- must have exactly those - no more (a T laid on a 4-way left half its routes out: 38, 83 on the
    -- survey map), no fewer (one-way roads), refused turns counted, as the pattern lays them anyway.
    -- And never the plain piece on a T: that is place's fallback where the T does not fit, and in game
    -- it left a road unjoined (43, 2026-10-07).
    local need = self:junctionMovementsAt15(jp)
    local lays = (res.kind == "X") and 12 or 6
    if need ~= lays then
        return nil, nil, string.format("the junction has %d movement(s), the %s lays %d", need, tostring(res.kind), lays)
    end
    if res.shape == "plain" and res.kind ~= "X" then
        return nil, nil, "only the plain piece would go here"
    end
    return site, res
end

--- Place mode's right-click: lay the X or T the preview worked out, under one undo.
--- THE BUILD LAYS THE MOD'S PATTERN WHERE IT FITS (the user, 2026-10-02 "build must place the X/T pattern",
--- and 2026-10-08). The traffic study (doc 09) ran every pair of movements through each layout: the
--- mod's exact T and plain X came out with no crash and no stand-off, for both tractor rigs, where the
--- turn-by-turn build of the same X still crashed (24 of 3168 runs, big rig). So on a cleared junction
--- the build first asks place, dry, whether the pattern fits; if it joins every road there (no lane
--- end left loose) it is laid exactly as place lays it, and the turn-by-turn build is only for
--- junctions the pattern does not fit. Wired, or nowhere place would work, it says no.
--- Returns true when it laid the pattern (the build is done).
function ADFlyoverEditor:junctionBuildAsPattern(jp)
    self.junctionLastPattern, self.junctionLastPatternWhy = nil, nil
    local site, res, why = self:junctionPatternFit(jp)
    if site == nil then
        self.junctionLastPatternWhy = why
        return false
    end
    local shape = self.junctionPattern or "exact"
    Logging.info("[FlyoverEditor]: junction build - the mod's %s %s fits every road here, so it is laid as the pattern (the traffic study, doc 09).",
        tostring(res.shape), tostring(res.kind))
    self.junctionPreview = { placeMode = true, cx = site.x, cz = site.z, shape = shape, ok = true, plan = res }
    self:applyJunctionPlace()
    local last = self.junctionLastPlace or {}
    self.junctionLastPattern = { shape = last.shape, kind = last.kind }
    self.junctionLastRouteCheck = self.junctionLastPlaceRouteCheck
    self:junctionBuildCheckKeep({ card = last.routeCard or { "Route check: could not run - see the log" },
        number = jp.junctionNumber, x = site.x, z = site.z, extra = last.extra })
    return true
end

function ADFlyoverEditor:applyJunctionPlace()
    local jp = self.junctionPreview
    if jp == nil or not jp.ok then return end
    local cap = self:debugCaptureBegin("place", { x = jp.cx, z = jp.cz }, {
        string.format("shape                %s", tostring(jp.shape)),
    })
    ADEditorHistory:snapshot("place junction")
    jxBuildBegin()
    local okCall, res, why = tryCall("junction place", function()
        return junctionPlacePattern(jp.cx, jp.cz, 15, jp.shape)
    end)
    local placed = okCall and res ~= nil
    -- Smooth curves cross the lanes and each other between the pattern's own points: each crossing gets
    -- its shared point, as everywhere else.
    local shared = 0
    -- (Not the plain piece: it is the mod's own shape, its shared points already in it, and it may sit
    -- over roads it does not fit, which it must not be joined to.)
    if placed and res.shape ~= "plain" and AutoDrive.FLYOVER_JUNCTION_SHARE_CROSSINGS ~= false then
        tryCall("junction share crossings", function() shared = junctionShareCrossings(jp.cx, jp.cz, 15) end)
    end
    -- ...and the old lane points left right beside the pattern's ties taken out (doc 09).
    if placed and res.shape ~= "plain" and AutoDrive.FLYOVER_JUNCTION_TIE_TIDY ~= false then
        local tidied = 0
        tryCall("junction tie tidy", function() tidied = junctionTieTidy(jp.cx, jp.cz, 15) end)
        if tidied > 0 then
            ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - %d old lane point(s) right beside a new tie taken out, so AutoDrive sees further ahead.", tidied)
        end
    end
    if placed then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction placed: %s %s, lane gap %.1f m, %d turn piece(s), %d shared crossing point(s), %d loose end(s).",
            res.shape == "exact" and "mod" or res.shape, res.kind, res.L, res.turns, shared, #(res.loose or {}))
        if res.fitWhy ~= nil then
            ADFlyoverSettings.debugLog("[FlyoverEditor]:   placed plain because it does not fit: %s.", tostring(res.fitWhy))
        end
    else
        Logging.warning("[FlyoverEditor]: junction place failed: %s", tostring(why or "see above"))
    end
    -- THE ROUTE CHECK on the piece as laid (report only: never refused, doc 08).
    local rc = nil
    if placed then
        tryCall("junction place route check", function() rc = junctionPlaceRouteCheck(res) end)
    end
    local routeCard = nil
    if placed then
        if rc == nil then
            routeCard = { "Route check: could not run - see the log" }
        elseif #rc.extra == 0 and #(rc.missing or {}) == 0 then
            routeCard = { string.format("Route check: all %d routes as meant", rc.routes) }
            if (rc.unjoined or 0) > 0 then routeCard[#routeCard + 1] = string.format("%d road(s) nearby not joined to it", rc.unjoined) end
        else
            routeCard = {}
            if #rc.extra > 0 then routeCard[#routeCard + 1] = string.format("Route check: %d route(s) we did not lay", #rc.extra) end
            if #(rc.missing or {}) > 0 then routeCard[#routeCard + 1] = string.format("Route check: %d turn(s) cannot be driven", #rc.missing) end
            if (rc.unjoined or 0) > 0 then routeCard[#routeCard + 1] = string.format("%d road(s) nearby not joined to it", rc.unjoined) end
            routeCard[#routeCard + 1] = "see the log for where"
        end
        if rc ~= nil then
            ADFlyoverSettings.debugLog("[FlyoverEditor]: junction place route check - %d road(s), %d turn(s) meant, %d route(s) found, %d extra, %d cannot be driven, %d road(s) not joined.",
                rc.roads or 0, rc.meant or 0, rc.routes, #rc.extra, #(rc.missing or {}), rc.unjoined or 0)
            for _, e in ipairs(rc.extra) do
                Logging.warning("[FlyoverEditor]:   route we did not lay: from the lane in at %.1f, %.1f to the lane out at %.1f, %.1f.",
                    e.from.x, e.from.z, e.to.x, e.to.z)
                -- The way it goes, point by point, so where it slips through can be seen.
                local via = {}
                for i, w in ipairs(e.path or {}) do
                    if i <= 16 then via[#via + 1] = string.format("%.1f,%.1f", w.x, w.z) end
                end
                ADFlyoverSettings.debugLog("[FlyoverEditor]:     by way of %s%s", table.concat(via, " > "),
                    (#(e.path or {}) > 16) and " ..." or "")
            end
            for _, e in ipairs(rc.missing or {}) do
                Logging.warning("[FlyoverEditor]:   turn that cannot be driven: from the lane in at %.1f, %.1f to the lane out at %.1f, %.1f.",
                    e.from.x, e.from.z, e.to.x, e.to.z)
            end
        end
    end
    self.junctionLastPlace = { ok = placed, kind = placed and res.kind or nil, shape = placed and res.shape or nil,
        routeCard = routeCard, extra = rc and #rc.extra or nil, missing = rc and #(rc.missing or {}) or nil, routes = rc and rc.routes or nil,
        unjoined = rc and rc.unjoined or nil,
        turns = placed and res.turns or 0, shared = shared, why = (not placed) and tostring(why) or nil,
        loose = placed and #(res.loose or {}) or 0, fitWhy = placed and res.fitWhy or nil,
        x = jp.cx, z = jp.cz }
    self.junctionLastPlaceRouteCheck = rc
    self.junctionLastLinkLabels = jxState.jxLinkLabel
    self.junctionLastNodeLabels = jxState.jxNodeLabel
    jxBuildEnd()
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
    self:debugCaptureEnd(cap)
    self.junctionArmed, self.junctionPreview, self.junctionPreviewKey = nil, nil, nil
end

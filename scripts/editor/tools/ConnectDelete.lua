-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua
-- loads it after FlyoverEditor.lua, in the old file's order.
-- MODSPLIT: HELPERS FROM THE FILES LOADED BEFORE THIS ONE (tools/modsplit/split.py writes this block)
for _, name in ipairs({ "LINK_LISTS", "linkList" }) do
    if ADFlyoverEditor.shared == nil or ADFlyoverEditor.shared[name] == nil then
        Logging.error("[FlyoverEditor]: ConnectDelete.lua needs %s, which no file loaded before it shares", name)
    end
end
local LINK_LISTS = ADFlyoverEditor.shared.LINK_LISTS
local linkList = ADFlyoverEditor.shared.linkList
-- MODSPLIT: end of the helpers

-- ---------------------------------------------------------------------------------------------
-- Connect / disconnect two existing waypoints.
-- ---------------------------------------------------------------------------------------------

--- The draw tool. One click, and what it does depends on what is under the cursor:
---
---   empty ground           create a waypoint, joined to the open end of the run
---   a waypoint, no run     start the run there, creating nothing
---   a waypoint, run open   toggle the connection between the run and it, then carry on from there
---
--- The toggle is AutoDrive own, and its DIRECTIONAL semantics are why this needs no separate
--- disconnect mode. Given an existing A->B, clicking A then B removes it, while clicking B then A
--- adds B->A and so makes the pair two-way. That is the rule stock AutoDrive editor already
--- follows, so it should be familiar rather than something new to learn here.
function ADFlyoverEditor:drawClick()
    -- Nothing under the cursor: this is a placement.
    if self.hoverId == nil then
        self:placeWaypointAtCursor()
        return
    end

    -- A waypoint, and no run open: start from it rather than stacking a duplicate on top of it.
    if self.lastWaypointId == nil then
        self.lastWaypointId = self.hoverId
        ADFlyoverSettings.debugLog("[FlyoverEditor]: run starts at existing waypoint id=%s; click on to draw from it.",
            tostring(self.lastWaypointId))
        return
    end

    if self.lastWaypointId == self.hoverId then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: cannot connect a waypoint to itself.")
        return
    end

    local startNode = ADGraphManager:getWayPointById(self.lastWaypointId)
    local endNode = ADGraphManager:getWayPointById(self.hoverId)
    if startNode == nil or endNode == nil then
        self.lastWaypointId = nil
        return
    end

    local reverseDirection, dualConnection = self:getConnectionOptions()

    ADEditorHistory:snapshot("toggle connection")
    ADGraphManager:toggleConnectionBetween(startNode, endNode, reverseDirection, dualConnection, false)

    ADFlyoverSettings.debugLog("[FlyoverEditor]: toggled the connection %s -> %s (dual=%s reverse=%s).",
        tostring(self.lastWaypointId), tostring(self.hoverId), tostring(dualConnection), tostring(reverseDirection))

    -- Carry the run on from the waypoint just clicked, so a route can be drawn straight through an
    -- existing junction without stopping to re-anchor it.
    self.lastWaypointId = self.hoverId
end

-- ---------------------------------------------------------------------------------------------
-- Delete.
-- ---------------------------------------------------------------------------------------------

--- Which tools offer the picked-span / whole-run choice: everything that works on a span between
--- two points. Delete and convert have their own point-vs-run scope, which means something else.
function ADFlyoverEditor:toolTakesSpanScope()
    return false   -- retired: every span tool now shows the shared pick row instead of "covers"
end

--- Tools that pick a span with the shared gesture (spanPickClick) and show the selection-type row.
--- The two ends of the span the active span tool has picked (either may be nil), for highlighting it.
function ADFlyoverEditor:pickedSpanEnds()
    local t, T = self.tool, self.TOOL
    if t == T.SMOOTH then return self.smoothFromId, self.smoothToId
    elseif t == T.DIVIDE then return self.divideFromId, self.divideToId
    elseif t == T.GROUND then return self.groundFromId, self.groundToId
    elseif t == T.STRAIGHTEN then return self.straightenFromId, self.straightenToId
    elseif t == T.PARALLEL then return self.offsetFromId, self.offsetToId
    elseif t == T.MERGE then return self.mergeFromId, self.mergeToId
    end
    return nil, nil
end

--- Is there a pick for the card's indicator to describe right now? A pending span, or (Ground) a selection.
function ADFlyoverEditor:pickIsActive()
    if self.tool == self.TOOL.MOVE then
        return self.moveSpanFromId ~= nil or self.dragId ~= nil
    end
    return self:toolHasPendingStart() or (self.tool == self.TOOL.GROUND and self.groundUsesSelection == true)
end

function ADFlyoverEditor:toolUsesSpanPick()
    return self.tool == self.TOOL.SMOOTH
        or self.tool == self.TOOL.MERGE
        or self.tool == self.TOOL.PARALLEL
        or self.tool == self.TOOL.DIVIDE
        or self.tool == self.TOOL.STRAIGHTEN
        or self.tool == self.TOOL.GROUND
end

--- One click instead of two, when the scope says whole run. Returns true when it handled the click.
---
--- In whole-run scope EVERY click resolves a run - including one made while a run is already
--- selected. It used to fall through to the two-click path instead, which treated the click as
--- re-picking the far end and quietly cut a 28-waypoint run down to 16. Whole run means the run
--- you clicked; to pick an arbitrary sub-span, switch to the picked span.
--- A refusal the player can SEE: the log line plus an on-screen warning (a log-only refusal reads as the
--- click doing nothing).
function ADFlyoverEditor:warnPlayer(message)
    if ADFlyoverLocale ~= nil and ADFlyoverLocale.t ~= nil then
        message = ADFlyoverLocale.t(message)
    end
    Logging.warning("[FlyoverEditor]: %s", message)
    self:showWarning(message)
end

--- Show a message in the editor's own warning box, attached to whichever card is in front (drawn by
--- ADFlyoverHud:drawWarning). The game's red blinking warning is small, fixed in size and sits in the
--- middle of the screen, away from where the player is looking - it is only the fallback now, for
--- when the editor is closed. Stays up for a reading time that grows with the message; a click on the
--- box closes it early.
function ADFlyoverEditor:showWarning(message)
    if self.active then
        self.warning = { text = message, untilMs = self:nowMs() + math.max(5000, #message * 65) }
        return
    end
    if g_currentMission ~= nil and g_currentMission.showBlinkingWarning ~= nil then
        pcall(g_currentMission.showBlinkingWarning, g_currentMission, message, 4000)
    end
end

local function listHas(list, id)
    for _, v in pairs(list or {}) do
        if v == id then return true end
    end
    return false
end

--- The shortest path from startId to endId that follows the direction of the links (out only), or nil.
local function directedPath(startId, endId, maxNodes)
    local cameFrom = { [startId] = false }
    local frontier, visited, found = { startId }, 1, startId == endId
    while #frontier > 0 and not found and visited < maxNodes do
        local nextFrontier = {}
        for _, id in ipairs(frontier) do
            local wp = ADGraphManager:getWayPointById(id)
            if wp ~= nil then
                for _, other in pairs(wp.out or {}) do
                    if cameFrom[other] == nil then
                        cameFrom[other] = id
                        visited = visited + 1
                        if other == endId then
                            found = true
                            break
                        end
                        table.insert(nextFrontier, other)
                    end
                end
            end
            if found then break end
        end
        frontier = nextFrontier
    end
    if not found then
        return nil
    end
    local path, id = {}, endId
    while id do
        table.insert(path, 1, id)
        id = cameFrom[id]
    end
    return path
end

--- The route between two picked points, following the RUN'S direction: along the links from a to b, or from
--- b to a (returned in a..b order), and only if neither exists falls back to the plain path search that
--- ignores direction. Where a track has more than one route between two points (a siding, a loop, a
--- shortcut), the plain search takes the shortest and can pick one that runs against the traffic; this
--- takes the one the traffic actually uses.
---
--- On a loop BOTH directions exist: a to b one way round, b to a the other. Taking a to b whenever it
--- existed meant a loop clicked against the traffic gave the route almost all the way round, which the
--- long-way check then refused (2026-11-03). So both are tried and the shorter wins - unless `prefer`
--- (the span being changed, as a list of ids) is given: then the route that keeps more of it wins, so
--- moving one end on round a loop grows the span the way it already runs instead of flipping it to the
--- other side.
local function routeLength(ids)
    local length, prev = 0, nil
    for _, id in ipairs(ids) do
        local wp = ADGraphManager:getWayPointById(id)
        if wp ~= nil then
            if prev ~= nil then
                length = length + MathUtil.vector2Length(wp.x - prev.x, wp.z - prev.z)
            end
            prev = wp
        end
    end
    return length
end

function ADFlyoverEditor:spanPath(a, b, prefer)
    local maxNodes = AutoDrive.FLYOVER_MERGE_MAX_RUN
    local candidates = {}
    local fwd = directedPath(a, b, maxNodes)
    if fwd ~= nil then
        candidates[#candidates + 1] = fwd
    end
    local back = directedPath(b, a, maxNodes)
    if back ~= nil then
        local reversed = {}
        for i = #back, 1, -1 do reversed[#reversed + 1] = back[i] end
        candidates[#candidates + 1] = reversed
    end
    if #candidates == 0 then
        return self:runPathBetween(a, b)
    end
    if #candidates == 1 then
        return candidates[1]
    end

    local keep = {}
    for _, id in ipairs(prefer or {}) do keep[id] = true end
    local best, bestKept, bestLength
    for _, path in ipairs(candidates) do
        local kept = 0
        for _, id in ipairs(path) do
            if keep[id] then kept = kept + 1 end
        end
        local length = routeLength(path)
        if best == nil or kept > bestKept or (kept == bestKept and length < bestLength - 0.01) then
            best, bestKept, bestLength = path, kept, length
        end
    end
    return best
end

--- Where a route turns OFF at a junction: the first interior waypoint with more than two neighbours at
--- which the route's heading (measured over about 4 m either side) changes by more than
--- ROUTE_JUNCTION_TURN_DEG. Nil when it never does - the route stays on one track, going straight on
--- through any junction it passes. Returns the id and the turn in degrees.
ADFlyoverEditor.ROUTE_JUNCTION_TURN_DEG = 60
function ADFlyoverEditor:spanTurnsOffAtJunction(span)
    local pts = {}
    for i, id in ipairs(span) do
        local wp = ADGraphManager:getWayPointById(id)
        if wp == nil then
            return nil
        end
        pts[i] = wp
    end
    local cum = { 0 }
    for i = 2, #pts do
        cum[i] = cum[i - 1] + MathUtil.vector2Length(pts[i].x - pts[i - 1].x, pts[i].z - pts[i - 1].z)
    end
    local reach = 4
    for i = 2, #pts - 1 do
        local seen, count = {}, 0
        for _, listName in ipairs(LINK_LISTS) do
            for _, other in pairs(linkList(pts[i], listName) or {}) do
                if not seen[other] and other ~= pts[i].id then
                    seen[other] = true
                    count = count + 1
                end
            end
        end
        if count > 2 then
            local j, k = i - 1, i + 1
            while j > 1 and cum[i] - cum[j] < reach do j = j - 1 end
            while k < #pts and cum[k] - cum[i] < reach do k = k + 1 end
            local ax, az = pts[i].x - pts[j].x, pts[i].z - pts[j].z
            local bx, bz = pts[k].x - pts[i].x, pts[k].z - pts[i].z
            local la, lb = MathUtil.vector2Length(ax, az), MathUtil.vector2Length(bx, bz)
            if la > 0.01 and lb > 0.01 then
                local c = math.max(-1, math.min(1, (ax * bx + az * bz) / (la * lb)))
                local turn = math.deg(math.acos(c))
                if turn > self.ROUTE_JUNCTION_TURN_DEG then
                    return pts[i].id, turn
                end
            end
        end
    end
    return nil
end

--- A span picked by two clicks must be the short, obvious way between them. When the only route found runs
--- a long way round (away through a junction and back, or down a different run), refuse it rather than
--- quietly take it: over ROUTE_MAX_RATIO times the straight distance AND more than ROUTE_MAX_EXTRA metres
--- longer than it. Returns ok, routeLength, straightLength, turnId, turnDeg.
---
--- A long route that stays CLOSE and on one track is not "the long way round": the track itself bends
--- back, as round a turnaround loop at a road's end. Two points far round such a loop are close
--- together but joined only along the loop, so the length test alone refused them (2026-11-03). Such a
--- route is kept when it never turns off at a junction AND never goes more than ROUTE_MAX_STRAY metres
--- from the nearer of its two ends. Both are needed: a route that turns off at a junction (a U-turn onto
--- the other lane, a siding taper and back) is a detour however close it stays, and one that stays on a
--- track but wanders far (the next lap of a field loop, a long ring road) is not what two clicks a few
--- metres apart meant. turnId, turnDeg name where a refused route turned off (nil when it strayed).
ADFlyoverEditor.ROUTE_MAX_RATIO = 2.0
ADFlyoverEditor.ROUTE_MAX_EXTRA = 40
ADFlyoverEditor.ROUTE_MAX_STRAY = 50
function ADFlyoverEditor:spanRouteIsDirect(span)
    if span == nil or #span < 2 then
        return true, 0, 0
    end
    local length = routeLength(span)
    local a = ADGraphManager:getWayPointById(span[1])
    local b = ADGraphManager:getWayPointById(span[#span])
    local straight = (a ~= nil and b ~= nil) and MathUtil.vector2Length(b.x - a.x, b.z - a.z) or 0
    local direct = not (length > straight * self.ROUTE_MAX_RATIO and length - straight > self.ROUTE_MAX_EXTRA)
    if direct then
        return true, length, straight
    end
    local turnId, turnDeg = self:spanTurnsOffAtJunction(span)
    if turnId ~= nil then
        return false, length, straight, turnId, turnDeg
    end
    local stray = 0
    for _, id in ipairs(span) do
        local wp = ADGraphManager:getWayPointById(id)
        if wp ~= nil and a ~= nil and b ~= nil then
            stray = math.max(stray, math.min(MathUtil.vector2Length(wp.x - a.x, wp.z - a.z),
                MathUtil.vector2Length(wp.x - b.x, wp.z - b.z)))
        end
    end
    if stray > self.ROUTE_MAX_STRAY then
        return false, length, straight
    end
    ADFlyoverSettings.debugLog("[FlyoverEditor]: long route kept: %.0fm for %.0fm apart, but it stays on one track "
        .. "within %.0fm of its ends (a loop).", length, straight, stray)
    return true, length, straight
end

--- Put a span's ids in the direction TRAFFIC runs along it. runPathBetween walks the graph ignoring link
--- direction, so a span clicked from downstream to upstream came out running AGAINST the traffic - and a
--- run's own end order was arbitrary - which made anything direction-sensitive (Parallel's "same way",
--- the side, the order of a one-way) come out backwards. One-way segments vote (a -> b only, or b -> a
--- only); two-way segments do not vote, so a two-way span keeps the order it was picked in. Returns the
--- ids (a reversed copy when they had to be turned round) and whether they were reversed.
function ADFlyoverEditor:trafficOrder(ids)
    if ids == nil or #ids < 2 then
        return ids, false
    end
    local forward, backward = 0, 0
    for i = 1, #ids - 1 do
        local a = ADGraphManager:getWayPointById(ids[i])
        local b = ADGraphManager:getWayPointById(ids[i + 1])
        if a ~= nil and b ~= nil then
            local aToB, bToA = listHas(a.out, b.id), listHas(b.out, a.id)
            if aToB and not bToA then
                forward = forward + 1
            elseif bToA and not aToB then
                backward = backward + 1
            end
        end
    end
    if backward > forward then
        local reversed = {}
        for i = #ids, 1, -1 do reversed[#reversed + 1] = ids[i] end
        return reversed, true
    end
    return ids, false
end

--- THE span-pick gesture, shared by every span tool (Smooth, Divide, Ground, Straighten; the others follow).
---
---   click a point            starts a span
---   click a second point     completes it (the path between them)
---   click again              replaces whichever end is nearer to the click
---   double-click a point     takes the whole run through it, junction to junction
---
--- self.pickFilter locks one of these types deliberately ("span": no double-click runs; "run": a single
--- click takes the run); nil is auto, where the gesture decides. self.pickKind records what the last
--- pick produced, which the tool card shows as its indicator.
---
--- `cfg` is how a tool plugs in: getFrom()/getTo() read its own end fields; setEnds(from, to, ids)
--- writes them and drops its previews; onSpan(from, to, span) (optional) runs when a full span exists.
function ADFlyoverEditor:spanPickClick(cfg)
    local id = self.hoverId
    if id == nil then
        return
    end
    local now = self:nowMs()
    local isDouble = self.lastPickId == id and (now - (self.lastPickAt or -1e9)) < self.DOUBLE_CLICK_MS
    self.lastPickId, self.lastPickAt = id, now

    local filter = self.pickFilter
    if filter ~= "span" and filter ~= "run" then
        filter = nil   -- "point" / "set" mean nothing to a span tool
    end

    if filter == "run" or (filter == nil and isDouble) then
        local fromId, toId, ids = self:resolveWholeRun(id)
        if fromId ~= nil then
            local ordered, turned = self:trafficOrder(ids)
            if turned then
                ids = ordered
                fromId, toId = ids[1], ids[#ids]
            end
            self.spanIds = ids
            self.spanMovingEndId = nil
            self.spanPickedUpId = nil
            cfg.setEnds(fromId, toId, ids)
            self.pickKind = "run"
            if cfg.onSpan ~= nil then cfg.onSpan(fromId, toId, ids) end
            ADFlyoverSettings.debugLog("[FlyoverEditor]: %s takes the whole run: %d waypoint(s), id=%s to id=%s.",
                self.TOOL_NAMES[self.tool] or "tool", #ids, tostring(fromId), tostring(toId))
            return
        end
        self:warnPlayer(string.format("No clear run through here - it is a junction, or a loop that leaves and returns to one "
            .. "junction. Click the two ends of the part you want instead."))
        if filter == "run" or isDouble then
            return
        end
    end

    -- A plain click after a Ctrl-built chain drops the chain and starts a fresh pick, rather than
    -- stretching the chain's span to the clicked point.
    if self.selectionCount > 0 and self:toolNeedsChainSelection() then
        self:clearSelection()
        self.spanIds = nil
        cfg.setEnds(nil, nil, nil)
        ADFlyoverSettings.debugLog("[FlyoverEditor]: plain click - dropped the Ctrl chain, starting a new pick.")
    end

    local from, to = cfg.getFrom(), cfg.getTo()

    if from == nil then
        self.spanIds = nil
        self.spanMovingEndId = nil
        self.spanPickedUpId = nil
        cfg.setEnds(id, nil, nil)
        self.pickKind = "span"
        ADFlyoverSettings.debugLog("[FlyoverEditor]: %s span from id=%s; click the far end (or double-click for the whole run).",
            self.TOOL_NAMES[self.tool] or "tool", tostring(id))
        return
    end

    if to == nil then
        if id == from then
            return
        end
        local span = self:spanPath(from, id)
        if span == nil and cfg.anyPoints then
            span = { from, id }   -- a tool that does not need a path takes any two points
        end
        if span == nil then
            self:warnPlayer(string.format("Those two points are not connected, so they are not two ends of one span."))
            return
        end
        local direct, routeLength, straightLength, turnId, turnDeg = self:spanRouteIsDirect(span)
        if not direct then
            ADFlyoverSettings.debugLog("[FlyoverEditor]: refused span id=%s to id=%s: the route is %.0fm for %.0fm apart (%d waypoint(s)), "
                .. "turns off %.0f deg at junction id=%s.",
                tostring(from), tostring(id), routeLength, straightLength, #span, turnDeg or 0, tostring(turnId))
            self:warnPlayer("Those two points are only joined the long way round - pick points on the same stretch of track.")
            return
        end
        local a, b = from, id
        local ordered, turned = self:trafficOrder(span)
        if turned then
            a, b, span = id, from, ordered   -- the traffic runs the other way: the span starts at the second click
        end
        self.spanIds = span   -- the route that was picked, so the preview and the commit follow exactly it
        self.spanMovingEndId = id   -- the second click is the end being placed; clicks on past it keep moving it
        self.spanPickedUpId = nil
        cfg.setEnds(a, b, nil)
        self.pickKind = "span"
        if cfg.onSpan ~= nil then cfg.onSpan(a, b, span) end
        ADFlyoverSettings.debugLog("[FlyoverEditor]: %s span of %d waypoint(s), id=%s to id=%s%s.",
            self.TOOL_NAMES[self.tool] or "tool", #span, tostring(a), tostring(b),
            turned and " (turned round to follow the traffic)" or "")
        return
    end

    -- Both ends exist: move the CARRIED end to this click. The end clicked first is the anchor and stays
    -- put (2026-11-03, build 717: carried round a loop to where it meets the road again, the start
    -- jumped to the point beside it). Clicking the anchor itself picks it up instead, so the next click
    -- moves it. With no carried end yet (a whole-run pick), pickEndToMove chooses one along the track.
    local current = self.spanIds
    if current ~= nil and not (current[1] == from and current[#current] == to) then
        current = nil
    end
    local moving = self.spanMovingEndId
    if moving ~= from and moving ~= to then
        local replacingFrom = self:pickEndToMove(from, to, id, current)
        if replacingFrom == nil then
            return
        end
        moving = replacingFrom and from or to
    end
    local anchor = (moving == from) and to or from
    if id == moving then
        return
    end
    if id == anchor then
        self.spanMovingEndId = anchor
        self.spanPickedUpId = anchor   -- the card says so until it is placed
        ADFlyoverSettings.debugLog("[FlyoverEditor]: %s span: picked up the end at id=%s; the next click moves it.",
            self.TOOL_NAMES[self.tool] or "tool", tostring(anchor))
        return
    end
    local replacingFrom = moving == from
    local newFrom = replacingFrom and id or from
    local newTo = replacingFrom and to or id

    -- The new span is the current one, changed only at the carried end: cut back to the click when it
    -- is on the span, otherwise carried on from the span's last point that reaches the click without
    -- crossing the span. A fresh path search between the two ends could take a short cut and drop the
    -- span (1480 to 2650 at Welker: 3 m along the road instead of round the loop).
    local span = current ~= nil and self:carrySpanEnd(current, anchor, id) or nil
    if span ~= nil and replacingFrom then
        local reversed = {}
        for i = #span, 1, -1 do reversed[#reversed + 1] = span[i] end
        span = reversed
    end
    if span == nil then
        span = self:spanPath(newFrom, newTo, current)
    end
    if span == nil and cfg.anyPoints then
        span = { newFrom, newTo }
    end
    if span == nil then
        self:warnPlayer("That point is not connected to the other end, so the span was not changed.")
        return
    end
    local direct, routeLength, straightLength, turnId, turnDeg = self:spanRouteIsDirect(span)
    if not direct then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: refused span end id=%s: the route is %.0fm for %.0fm apart (%d waypoint(s)), "
            .. "turns off %.0f deg at junction id=%s.",
            tostring(id), routeLength, straightLength, #span, turnDeg or 0, tostring(turnId))
        self:warnPlayer("That point is only joined to the span the long way round - the span was not changed.")
        return
    end
    local ordered, turned = self:trafficOrder(span)
    if turned then
        newFrom, newTo, span = newTo, newFrom, ordered
    end
    self.spanIds = span
    self.spanMovingEndId = id   -- still the carried end; the anchor is whichever end is not this
    self.spanPickedUpId = nil
    cfg.setEnds(newFrom, newTo, nil)
    self.pickKind = "span"
    if cfg.onSpan ~= nil then cfg.onSpan(newFrom, newTo, span) end
    ADFlyoverSettings.debugLog("[FlyoverEditor]: %s span end replaced: %d waypoint(s), id=%s to id=%s%s.",
        self.TOOL_NAMES[self.tool] or "tool", #span, tostring(newFrom), tostring(newTo),
        turned and " (turned round to follow the traffic)" or "")
end

--- How many links from `startId` to `targetId` without passing through the span (`inSpan`, a set of
--- ids; only startId itself may be in it), ignoring direction. Nil when the span is in the way or the
--- target is too far.
local function hopsAvoiding(startId, targetId, inSpan, maxNodes)
    if startId == targetId then
        return 0
    end
    local seen = { [startId] = true }
    local frontier, hops, visited = { startId }, 0, 1
    while #frontier > 0 and visited < maxNodes do
        hops = hops + 1
        local nextFrontier = {}
        for _, id in ipairs(frontier) do
            local wp = ADGraphManager:getWayPointById(id)
            if wp ~= nil then
                for _, listName in ipairs(LINK_LISTS) do
                    for _, other in pairs(linkList(wp, listName) or {}) do
                        if other == targetId then
                            return hops
                        end
                        if not seen[other] and not inSpan[other] then
                            seen[other] = true
                            visited = visited + 1
                            nextFrontier[#nextFrontier + 1] = other
                        end
                    end
                end
            end
        end
        frontier = nextFrontier
    end
    return nil
end

--- The span `span` (either way round) with its end that is NOT `anchor` carried to `id`, as a list of
--- ids from the anchor to `id`, or nil when that cannot be done along the track.
---   - `id` on the span: the span cut back to it.
---   - otherwise: the span kept from the anchor as far as the last point that reaches `id` within
---     CARRY_MAX_HOPS links without crossing the span, then that way on to `id`. Starting from the
---     carried end and stepping back means the span is kept as far as it can be - carried past a
---     junction onto a spur, a click back on the other branch turns off at the junction rather than
---     cutting the span short.
ADFlyoverEditor.CARRY_MAX_HOPS = 40
function ADFlyoverEditor:carrySpanEnd(span, anchor, id)
    local cur = span
    if span[#span] == anchor then
        cur = {}
        for i = #span, 1, -1 do cur[#cur + 1] = span[i] end
    elseif span[1] ~= anchor then
        return nil
    end

    local inSpan = {}
    for i, sid in ipairs(cur) do
        if sid == id then
            local out = {}
            for k = 1, i do out[k] = cur[k] end
            return #out >= 2 and out or nil
        end
        inSpan[sid] = true
    end

    for k = #cur, 1, -1 do
        -- Breadth-first from cur[k] to id, not through any other span point, at most CARRY_MAX_HOPS.
        local start = cur[k]
        local cameFrom = { [start] = false }
        local frontier, found = { start }, false
        for _ = 1, self.CARRY_MAX_HOPS do
            local nextFrontier = {}
            for _, nid in ipairs(frontier) do
                local wp = ADGraphManager:getWayPointById(nid)
                if wp ~= nil then
                    for _, listName in ipairs(LINK_LISTS) do
                        for _, other in pairs(linkList(wp, listName) or {}) do
                            if cameFrom[other] == nil and not inSpan[other] then
                                cameFrom[other] = nid
                                if other == id then
                                    found = true
                                    break
                                end
                                nextFrontier[#nextFrontier + 1] = other
                            end
                        end
                        if found then break end
                    end
                end
                if found then break end
            end
            if found or #nextFrontier == 0 then break end
            frontier = nextFrontier
        end
        if found then
            local tail, nid = {}, id
            while nid ~= start do
                table.insert(tail, 1, nid)
                nid = cameFrom[nid]
            end
            local out = {}
            for j = 1, k do out[j] = cur[j] end
            for _, t in ipairs(tail) do out[#out + 1] = t end
            return out
        end
    end
    return nil
end

--- Which end of a picked span a click moves: true for the `from` end, false for `to`, nil to ignore.
---
--- Decided along the track, by node order, not by straight distance. Straight distance broke on a loop
--- (2026-11-03): with the span run nearly all the way round, its two ends sit side by side, and a click
--- just past the end being moved was nearer the OTHER end, which then jumped back to the short side.
---   - A click ON the span moves the end it is fewer points from (shrinking the span from that end).
---   - A click off the span keeps moving the end that was placed last (spanMovingEndId), if that end can
---     reach the click without crossing the span and is no more than one link farther from it than the
---     other end - so carrying an end on round a loop keeps going the way it was going, even once it is
---     next to the other end, while a click just past the other end still moves that one.
---   - Otherwise the end fewer links away from the click, not crossing the span.
---   - Straight distance only when neither end can be reached that way.
function ADFlyoverEditor:pickEndToMove(from, to, id, span)
    span = span or self:spanPath(from, to)
    local inSpan, index = {}, {}
    for i, sid in ipairs(span or {}) do
        inSpan[sid] = true
        index[sid] = i
    end

    if index[id] ~= nil and span ~= nil then
        local i = index[id]
        if i - 1 ~= #span - i then
            return i - 1 < #span - i
        end
    elseif span ~= nil then
        local maxNodes = AutoDrive.FLYOVER_MERGE_MAX_RUN or 4096
        local hFrom = hopsAvoiding(from, id, inSpan, maxNodes)
        local hTo = hopsAvoiding(to, id, inSpan, maxNodes)
        -- The end being moved wins unless the other end is clearly nearer the click (two links or more):
        -- on a loop both ends reach a click in the gap, and the one just carried there is meant.
        local moving = self.spanMovingEndId
        if moving == from and hFrom ~= nil and (hTo == nil or hFrom <= hTo + 1) then
            return true
        elseif moving == to and hTo ~= nil and (hFrom == nil or hTo <= hFrom + 1) then
            return false
        end
        if hFrom ~= nil or hTo ~= nil then
            if hTo == nil then
                return true
            elseif hFrom == nil then
                return false
            elseif hFrom ~= hTo then
                return hFrom < hTo
            end
        end
    end

    local wp = ADGraphManager:getWayPointById(id)
    local fromWp = ADGraphManager:getWayPointById(from)
    local toWp = ADGraphManager:getWayPointById(to)
    if wp == nil or fromWp == nil or toWp == nil then
        return nil
    end
    local dFrom = MathUtil.vector2Length(wp.x - fromWp.x, wp.z - fromWp.z)
    local dTo = MathUtil.vector2Length(wp.x - toWp.x, wp.z - toWp.z)
    return dFrom <= dTo
end

--- Lock the selection type (or, with nil, go back to auto). Clicking the lit type on a tool card
--- again unlocks it.
function ADFlyoverEditor:setPickFilter(filter)
    self.pickFilter = filter
    ADFlyoverSettings.debugLog("[FlyoverEditor]: selection type %s.", filter ~= nil and ("locked to " .. filter) or "auto")
end

function ADFlyoverEditor:claimWholeRunClick(setEnds)
    if self.offsetScope ~= self.OFFSET_SCOPE.RUN or self.hoverId == nil then
        return false
    end
    local fromId, toId, ids = self:resolveWholeRun(self.hoverId)
    if fromId == nil then
        Logging.warning("[FlyoverEditor]: no clear run through id=%s - it is a junction, or the run "
            .. "closes on itself. Switch to the picked span and click both ends.", tostring(self.hoverId))
        return true
    end
    self.spanIds = ids
    setEnds(fromId, toId)
    ADFlyoverSettings.debugLog("[FlyoverEditor]: %s covers the whole run: %d waypoint(s), id=%s to id=%s.",
        self.TOOL_NAMES[self.tool] or "tool", #ids, tostring(fromId), tostring(toId))
    return true
end

ADFlyoverEditor.OFFSET_SCOPE = { SPAN = 1, RUN = 2 }
ADFlyoverEditor.OFFSET_SCOPE_NAMES = { "picked span", "whole run" }

--- Is this ordered run two-way? Sides of a two-way track have no "left of travel" (there is no single
--- direction), so the selector names them by what the player did instead. Two-way when at least half
--- the segments also run the other way, so one stray one-way piece does not flip the wording.
function ADFlyoverEditor:runIsTwoWay(pts)
    if pts == nil or #pts < 2 then return false end
    local total, reverse = 0, 0
    for i = 1, #pts - 1 do
        local a = ADGraphManager:getWayPointById(pts[i].id)
        local b = ADGraphManager:getWayPointById(pts[i + 1].id)
        if a ~= nil and b ~= nil then
            total = total + 1
            for _, otherId in pairs(b.out or {}) do
                if otherId == pts[i].id then reverse = reverse + 1 break end
            end
        end
    end
    return total > 0 and reverse * 2 >= total
end

--- Take the side from where the cursor points, and remember which side that was and whether the track
--- is two-way, so the side selector can say "picked side / other side" on a two-way track.
function ADFlyoverEditor:pickSideFromCursor(seedPts)
    local side, a, b = self:offsetSideFromCursor(seedPts)
    self.offsetSide = side
    self.offsetSidePicked = side
    self.sideTwoWay = self:runIsTwoWay(seedPts)
    -- The stretch of track the side was judged against: on a two-way track the sides are named by where
    -- they lie on SCREEN, worked out from this each frame (see screenSideLabels).
    if a ~= nil and b ~= nil then
        self.sideRefA = { x = a.x, y = a.y or 0, z = a.z }
        self.sideRefB = { x = b.x, y = b.y or 0, z = b.z }
    else
        self.sideRefA, self.sideRefB = nil, nil
    end
end

--- Where the two sides of a two-way track lie on screen: returns the words for the + side and the -
--- side (right/left when the track runs mostly up and down the screen, up/down when it runs mostly
--- across it), or nil when that cannot be worked out. Recomputed as the camera moves, so the words
--- always describe what is on screen.
function ADFlyoverEditor:screenSideLabels()
    local a, b = self.sideRefA, self.sideRefB
    if a == nil or b == nil or project == nil then return nil end
    local dx, dz = b.x - a.x, b.z - a.z
    local len = math.sqrt(dx * dx + dz * dz)
    if len < 1e-6 then return nil end
    local nx, nz = -dz / len, dx / len   -- the + side's normal, as the offset maths uses it
    local mx, my, mz = (a.x + b.x) * 0.5, (a.y + b.y) * 0.5, (a.z + b.z) * 0.5
    local ok0, x0, y0, d0 = pcall(project, mx, my, mz)
    local ok1, x1, y1, d1 = pcall(project, mx + nx * 5, my, mz + nz * 5)
    if not (ok0 and ok1 and x0 and x1 and ADFlyoverEditor.inFrontDepth(d0) and ADFlyoverEditor.inFrontDepth(d1)) then return nil end
    -- Normalised screen x is squeezed by the aspect ratio; scale it back so the two axes compare fairly.
    local vx, vy = (x1 - x0) * (g_screenAspectRatio or (16 / 9)), y1 - y0
    if math.abs(vx) >= math.abs(vy) then
        if vx > 0 then return "right", "left" end
        return "left", "right"
    end
    if vy > 0 then return "up", "down" end
    return "down", "up"
end

--- The name of the current side, the same words the selector shows: left / right of travel on a one-way
--- track, picked side / other side on a two-way one.
function ADFlyoverEditor:sideName()
    local side = self.offsetSide or 1
    -- Two-way: where the side lies on screen (see the side selector on the card); one-way: left / right of
    -- the run, below.
    if self.sideTwoWay then
        local plus, minus = self:screenSideLabels()
        if plus ~= nil then
            return side >= 0 and plus or minus
        end
        return side == (self.offsetSidePicked or 1) and "picked side" or "other side"
    end
    return side >= 0 and "right" or "left"
end

function ADFlyoverEditor:flipOffsetSide()
    -- offsetSide +1 is the side the (-uz, ux) normal points to, which in this map's x/z (z grows toward
    -- the bottom of a north-up view) is the RIGHT-hand side of the direction of travel; -1 is the left.
    self.offsetSide = -(self.offsetSide or 1)
    self.offsetCache = nil
    ADFlyoverSettings.debugLog("[FlyoverEditor]: offset side -> %s.", self:sideName())
end

function ADFlyoverEditor:cycleOffsetScope()
    self.offsetScope = (self.offsetScope % #self.OFFSET_SCOPE_NAMES) + 1
    self.offsetFromId, self.offsetToId, self.offsetPreview, self.offsetCache = nil, nil, nil, nil
    self.spanIds = nil
    ADFlyoverSettings.debugLog("[FlyoverEditor]: offset covers the %s.", self.OFFSET_SCOPE_NAMES[self.offsetScope])
end

ADFlyoverEditor.DELETE_SCOPE = { POINT = 1, RUN = 2 }
ADFlyoverEditor.DELETE_SCOPE_NAMES = { "one waypoint", "whole run" }

-- Move's own pick, separate from DELETE_SCOPE even though Point/Run overlap it: move additionally
-- has Span (and, later, Box/Circle/Freehand), none of which delete has any use for.
ADFlyoverEditor.MOVE_SELECT = { POINT = 1, RUN = 2, SPAN = 3 }
ADFlyoverEditor.MOVE_SELECT_NAMES = { "point", "run", "span" }

function ADFlyoverEditor:cancelMoveSpan()
    if self.moveSpanFromId ~= nil or self.moveSpanToId ~= nil then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: move span cancelled.")
    end
    self.moveSpanFromId, self.moveSpanToId, self.moveSpanIds = nil, nil, nil
    -- Nothing picked any more: a following drag is a single point again, and the indicator goes dark.
    self.moveSelectMode = self.MOVE_SELECT.POINT
    self.pickKind = nil
end

function ADFlyoverEditor:cycleMoveSelectMode()
    self.moveSelectMode = (self.moveSelectMode % #self.MOVE_SELECT_NAMES) + 1
    self:cancelMoveSpan()
    ADFlyoverSettings.debugLog("[FlyoverEditor]: move picks %s.", self.MOVE_SELECT_NAMES[self.moveSelectMode])
    self:refreshActiveDrag()
end

function ADFlyoverEditor:toggleMoveFalloff()
    -- Guards (the card greys these): a tapered drag stays joined to the track it came from, so it cannot
    -- also be disconnected; and a selection always moves rigidly, so falloff means nothing with one.
    if not self.moveFalloffOn and (self.moveBreakOn
        or (self.selectionCount > 0 and self:selectionChain() == nil)) then
        return
    end
    self.moveFalloffOn = not self.moveFalloffOn
    ADFlyoverSettings.debugLog("[FlyoverEditor]: move falloff %s.", self.moveFalloffOn and "on" or "off")
    self:refreshActiveDrag()
end

--- Convert a completed move into a copy: every ORIGINAL point restores to where it started, and a
--- NEW waypoint is created at each one's final (already re-grounded) position instead. Internal
--- connections among the moved set are replicated onto the clones - walking only wp.out, so each
--- directed edge is reconstructed exactly once; a dual connection reconstructs itself naturally as
--- two separate directed edges when both directions were present, no special case needed. Nothing
--- connects a clone to anything OUTSIDE the moved set - it never had a link there, and a copy
--- being disconnected by default is the whole point of it (see move-tool-copy-and-break-spec in
--- project memory).
---
--- `record.members` is a plain list of { id, originalX, originalZ } - see finishDrag, which builds
--- it for every move (not just copies), and toggleMoveCopy, which is what lets a plain move already
--- released get turned into a copy afterward.
function ADFlyoverEditor:applyMoveAsCopy(record)
    if record == nil or record.members == nil then
        return
    end

    local movedSet = {}
    for _, m in ipairs(record.members) do
        movedSet[m.id] = true
    end

    local newIds = {}
    for _, m in ipairs(record.members) do
        local wp = ADGraphManager:getWayPointById(m.id)
        if wp ~= nil then
            -- Final position first - restoring the original below moves THIS waypoint, not the
            -- clone, so its current x/y/z has to be captured before that happens. Skipped
            -- entirely when breaking: the original is about to be deleted anyway, so there is no
            -- point writing it back to its start position first.
            --
            -- m.finalX/finalZ, when present, override reading wp's own live position - the frozen-
            -- copy path (dragFrozenCopy: copy was on before or during the drag, so the REAL
            -- waypoint never moved at all and is sitting at its original spot right now, not the
            -- drop point) records where the drag would have ended separately, since wp.x/z cannot
            -- tell us that anymore. The retroactive path (copy toggled on AFTER release) has no
            -- such override - wp really is sitting at its final dropped position, which is exactly
            -- what should be read live.
            local fx, fy, fz, flags = wp.x, wp.y, wp.z, wp.flags
            if m.finalX ~= nil then
                fx, fz = m.finalX, m.finalZ
                fy = AutoDrive:getTerrainHeightAtWorldPos(fx, fz, wp.y)
            end
            if not self.moveBreakOn then
                self:moveTo(m.id, m.originalX, m.originalZ)
            end

            local newWp = ADFlyoverRecordWayPoint(fx, fy, fz, false, false, false, nil, flags, false)
            if newWp ~= nil then
                newIds[m.id] = newWp.id
            end
        end
    end

    local edgeCount = 0
    for _, m in ipairs(record.members) do
        local wp = ADGraphManager:getWayPointById(m.id)
        local newFromId = newIds[m.id]
        if wp ~= nil and newFromId ~= nil then
            for _, otherId in pairs(wp.out or {}) do
                if movedSet[otherId] and newIds[otherId] ~= nil then
                    local newFrom = ADGraphManager:getWayPointById(newFromId)
                    local newTo = ADGraphManager:getWayPointById(newIds[otherId])
                    if newFrom ~= nil and newTo ~= nil then
                        ADGraphManager:toggleConnectionBetween(newFrom, newTo, false, false, false)
                        edgeCount = edgeCount + 1
                    end
                end
            end
        end
    end

    -- Break (item 4): delete every original NOW, after the clones exist and their internal edges
    -- are wired, but before anything reads the originals again. This is what turns a copy into a
    -- relocate - the clone is already disconnected by default (a fresh waypoint never inherited
    -- the source's links), so deleting the source leaves it moved and cleanly detached rather than
    -- leaving a stretched connection or a lost waypoint (see move-tool-copy-and-break-spec).
    if self.moveBreakOn then
        local toDelete = {}
        for _, m in ipairs(record.members) do
            table.insert(toDelete, m.id)
        end
        -- Same reasoning deleteSelection already relies on: descending order, so each pending id
        -- is still valid when its turn comes.
        table.sort(toDelete, function(a, b) return a > b end)
        for _, id in ipairs(toDelete) do
            ADGraphManager:removeWayPoint(id, false)
        end

        -- Every original has a LOWER id than every clone (clones are always appended strictly
        -- after this operation starts, never inserted below anything), so deleting #toDelete of
        -- them shifts every clone's id down by exactly that count - uniformly, regardless of
        -- which original happened to cause which shift.
        local shift = #toDelete
        for oldId, newId in pairs(newIds) do
            newIds[oldId] = newId - shift
        end
        self:invalidateIdReferences()
    end

    -- The clone becomes the new selection - the natural thing to act on next, the same way a
    -- freshly picked span or box leaves its own result selected. After invalidateIdReferences
    -- above (break only), which already cleared it - this still has to run either way, copy or
    -- break, so it is unconditional rather than duplicated into both branches.
    self:clearSelection()
    local finalIds = {}
    for _, newId in pairs(newIds) do
        self.selection[newId] = true
        self.selectionCount = self.selectionCount + 1
        table.insert(finalIds, newId)
    end

    -- The clone's own ends (item 6) - not the source's, which either still exists (plain copy) or
    -- is already gone (break). Using newIds' FINAL values here matters: they were already shifted
    -- above when breaking, so this checks the ids the clone actually has now.
    self:autoHookupEndpoints(finalIds)

    ADFlyoverSettings.debugLog("[FlyoverEditor]: %s %d waypoint(s), %d internal connection(s), now selected.",
        self.moveBreakOn and "broke off" or "copied", #record.members, edgeCount)
    ADGraphManager:markChanges()
end

--- Copy is a toggle sitting on top of whichever move just happened or is about to, not a mode of
--- its own - see move-tool-copy-and-break-spec in project memory for the two ways it applies:
---
---   1. Toggled on BEFORE or DURING a drag: finishDrag sees moveCopyOn and applies the copy
---      itself once the drag actually completes.
---   2. Toggled on AFTER a drag has already finished (self.dragId == nil): there is no pending
---      drag to wait for, so this converts the just-finished move right now, using the record
---      finishDrag already stashed in lastMoveRecord for exactly this case.
---
--- Auto-clears back to off once actually applied (case 2, and the mirror of it inside finishDrag)
--- rather than staying on for the next drag too - a defensible default given a copy creates new
--- waypoints, not just repositions existing ones, so leaving it silently armed risks a drag some
--- time later cloning when a plain move was intended.
function ADFlyoverEditor:toggleMoveCopy()
    self.moveCopyOn = not self.moveCopyOn

    -- An offset is live (dragging, or waiting for its right-click): copy freezes / unfreezes the original.
    if self.moveOffsetChainIds ~= nil then
        self:setMoveOffsetFrozen(self.moveCopyOn)
        ADFlyoverSettings.debugLog("[FlyoverEditor]: move copy %s (offset: original %s).", self.moveCopyOn and "on" or "off",
            self.moveCopyOn and "back in place, sliding a copy" or "follows the offset again")
        return
    end

    if self.moveCopyOn and self.dragId == nil and self.lastMoveRecord ~= nil then
        self:applyMoveAsCopy(self.lastMoveRecord)
        self.lastMoveRecord = nil
        self.moveCopyOn = false
        self.moveBreakOn = false
        return
    end

    -- Turned on WHILE a drag is already live: freeze the real waypoint(s) back at their pre-drag
    -- spot right now, same as beginDrag does when copy is already on at grab time - the original
    -- should never look like it "moved and then undid," it should just stop following the cursor
    -- from this frame on. finishDrag tracks where the drag would have ended separately (via the
    -- members' finalX/finalZ) so the eventual clone still lands wherever you actually release,
    -- even though the real point stopped moving here.
    if self.moveCopyOn and self.dragId ~= nil then
        for _, n in ipairs(self.dragNeighbours or {}) do
            self:moveTo(n.id, n.x, n.z)
        end
        if self.dragStartX ~= nil then
            self:moveTo(self.dragId, self.dragStartX, self.dragStartZ)
        end
        self.dragFrozenCopy = true
    elseif not self.moveCopyOn then
        self.dragFrozenCopy = false
    end

    ADFlyoverSettings.debugLog("[FlyoverEditor]: move copy %s.", self.moveCopyOn and "on" or "off")
end

--- Disconnect (item 4, HUD label "disconnect") is independent of copy - decided 2026-09-21 after
--- copy being a prerequisite read as confusing (it isn't a copy modifier, it just happens to
--- BECOME one when copy is also on):
---
---   copy off, disconnect on:  standalone - finishDrag moves the set as normal, then severs its
---                              OUTSIDE connections in place (disconnectExternal). No clone.
---   copy on,  disconnect on:  same net result as before - applyMoveAsCopy clones, then deletes
---                              the originals instead of restoring them, leaving a disconnected
---                              clone at the drop spot.
---
--- So this toggle always applies; it no longer resets when copy turns off, and the HUD always
--- shows its row under Move (see move-tool-copy-and-break-spec in project memory for the older,
--- copy-gated history of this toggle).
function ADFlyoverEditor:toggleMoveBreak()
    -- Not with a taper, plain or offset (the card shows it greyed): tapered points stay joined to the track.
    if not self.moveBreakOn and ((self.moveOffsetOn and self.moveOffsetFalloffOn)
        or (not self.moveOffsetOn and self.moveFalloffOn)) then
        return
    end
    self.moveBreakOn = not self.moveBreakOn
    ADFlyoverSettings.debugLog("[FlyoverEditor]: move disconnect %s.", self.moveBreakOn and "on" or "off")
end

function ADFlyoverEditor:toggleMoveAutoHookup()
    self.moveAutoHookupOn = not self.moveAutoHookupOn
    ADFlyoverSettings.debugLog("[FlyoverEditor]: move auto-hookup %s.", self.moveAutoHookupOn and "on" or "off")
end

--- Item 6, widened 2026-09-21 (was total connections <= 1 only - resolveWholeRun's own "an end has
--- at most one inside connection" idea for a run's two ends). A genuine THROUGH point (one
--- incoming, one outgoing, to two DIFFERENT neighbours) is still excluded - that is a normal
--- interior point with both its connections, snapping it elsewhere would replace a link, not add
--- one. But a FORK where every remaining connection points the same logical way is now eligible
--- too, on request: "two two-way, or both one-ways leaving or entering should be eligible" - a
--- node that lost its one outside tie and kept two internal branches all flowing the same
--- direction (all out, all in, or all dual) still has an unambiguous single role to reconnect.
---
--- Returns (eligible, neighbourIdSet, role) - role is "isolated" (0 connections), "source" (only
--- outgoing - needs a new incoming link), "destination" (only incoming - needs a new outgoing
--- link), or "dual" (every neighbour is a two-way pair - the new link should be dual too).
local function isEndpoint(id)
    local wp = ADGraphManager:getWayPointById(id)
    if wp == nil then
        return false
    end
    local seen = {}
    for _, listName in ipairs(LINK_LISTS) do
        for _, other in pairs(linkList(wp, listName) or {}) do
            seen[other] = true
        end
    end

    local outCount, inCount = #(wp.out or {}), #(wp.incoming or {})
    if outCount == 0 and inCount == 0 then
        return true, seen, "isolated"
    end
    if outCount == 0 then
        return true, seen, "destination"
    end
    if inCount == 0 then
        return true, seen, "source"
    end

    -- Both lists non-empty: eligible only if EVERY neighbour appears in BOTH lists (all pairs
    -- genuinely dual) - otherwise this is a normal through-point (different neighbours in and
    -- out), not a fork, and stays excluded exactly as before.
    for other in pairs(seen) do
        if not (table.contains(wp.out or {}, other) and table.contains(wp.incoming or {}, other)) then
            return false
        end
    end
    return true, seen, "dual"
end

--- Auto-hookup for a moved or copied set of ids (item 6) - checked at the tail of finishDrag (a
--- plain move) and applyMoveAsCopy (copy/break), after positions are settled. Endpoints only (see
--- isEndpoint) - an interior point already has both its connections, and snapping it elsewhere
--- would mean REPLACING a link, not adding one; left for later if this ever extends past
--- endpoints, per move-tool-auto-hookup-spec.
---
--- One candidate per endpoint - the single NEAREST other waypoint within tolerance, excluding the
--- moved/copied set itself (reconnecting to something already there is the point; two ends of the
--- same set drifting near each other is not what this is for). Divergence is only checked when the
--- endpoint already has one neighbour to measure a heading from - a bare point (zero connections,
--- e.g. a lone copied point) has no heading to diverge from, so distance alone decides it.
function ADFlyoverEditor:autoHookupEndpoints(ids)
    if not self.moveAutoHookupOn or ids == nil then
        return 0
    end

    local movedSet = {}
    for _, id in ipairs(ids) do
        movedSet[id] = true
    end

    local maxDistance = ADFlyoverSettings.get("flyoverAutoHookupDistance") or 3.0
    local maxDivergence = ADFlyoverSettings.get("flyoverAutoHookupDivergence") or 15
    local wayPoints = ADGraphManager:getWayPoints()
    local hooked = 0

    for _, id in ipairs(ids) do
        local endpoint, neighbours, role = isEndpoint(id)
        if endpoint then
            local wp = ADGraphManager:getWayPointById(id)
            if wp ~= nil then
                -- Heading: the AVERAGE direction away from every surviving neighbour, not just
                -- one - a fork (role "source"/"destination"/"dual" with more than one neighbour,
                -- widened 2026-09-21) has several, and none of them alone says which way the
                -- candidate should roughly continue. "isolated" (a bare copied point) has none at
                -- all, so heading/divergence is skipped entirely for it, same as before.
                --
                -- Direction and dual-ness both come straight from role now instead of inspecting
                -- one neighbour's own lists: "source" (only outgoing survives) means wp used to be
                -- fed from outside, so the replacement should too (target->wp); "destination"
                -- (only incoming survives) means wp used to feed onward, so the replacement
                -- continues that (wp->target); "dual" (every neighbour two-way) makes the new link
                -- dual too. Got wpIsSource backwards on an earlier single-neighbour pass (reported
                -- 2026-09-21 as "one connection was the wrong direction") - role removes the need
                -- to infer it from an "inverse of the survivor" rule at all.
                local headingX, headingZ = nil, nil
                local hSumX, hSumZ, hCount = 0, 0, 0
                for otherId in pairs(neighbours) do
                    local ow = ADGraphManager:getWayPointById(otherId)
                    if ow ~= nil then
                        local hx, hz = wp.x - ow.x, wp.z - ow.z
                        local len = MathUtil.vector2Length(hx, hz)
                        if len > 1e-6 then
                            hSumX, hSumZ, hCount = hSumX + hx / len, hSumZ + hz / len, hCount + 1
                        end
                    end
                end
                if hCount > 0 then
                    local len = MathUtil.vector2Length(hSumX, hSumZ)
                    if len > 1e-6 then
                        headingX, headingZ = hSumX / len, hSumZ / len
                    end
                end
                local dual = (role == "dual")
                local wpIsSource = (role == "destination")

                local bestId, bestDist = nil, maxDistance
                for i = 1, #wayPoints do
                    local other = wayPoints[i]
                    if not movedSet[other.id] and not neighbours[other.id] then
                        local dx, dz = other.x - wp.x, other.z - wp.z
                        local dist = MathUtil.vector2Length(dx, dz)
                        if dist <= bestDist and dist > 1e-6 then
                            local ok = true
                            if headingX ~= nil then
                                local ux, uz = dx / dist, dz / dist
                                local cosAngle = math.max(-1, math.min(1, ux * headingX + uz * headingZ))
                                local angleDeg = math.deg(math.acos(cosAngle))
                                ok = angleDeg <= maxDivergence
                            end
                            if ok then
                                bestId, bestDist = other.id, dist
                            end
                        end
                    end
                end

                if bestId ~= nil then
                    local target = ADGraphManager:getWayPointById(bestId)
                    if target ~= nil then
                        -- Argument order carries the direction directly (rather than trusting the
                        -- exact sign convention of a reverseDirection flag): wp was a source, so
                        -- wp->target continues it; wp was a destination, so target->wp does.
                        if wpIsSource then
                            ADGraphManager:toggleConnectionBetween(wp, target, false, dual, false)
                        else
                            ADGraphManager:toggleConnectionBetween(target, wp, false, dual, false)
                        end
                        hooked = hooked + 1
                    end
                end
            end
        end
    end

    if hooked > 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: auto-hookup connected %d endpoint(s).", hooked)
    end
    return hooked
end

--- Run/Span only - see gatherDragNeighbours/gatherOffsetChain. Blocked while an offset is already
--- pending (moveOffsetChainIds ~= nil): flipping the toggle off then would leave the panel saying
--- "off" while a chain is still live and awaiting its right-click commit, which is exactly the
--- kind of stale-looking-inactive-but-still-armed state the rest of this feature works to avoid.
function ADFlyoverEditor:toggleMoveOffset()
    if self.moveOffsetChainIds ~= nil then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: an offset is still pending - right-click to finish it first.")
        return
    end
    self.moveOffsetOn = not self.moveOffsetOn
    ADFlyoverSettings.debugLog("[FlyoverEditor]: move offset %s.", self.moveOffsetOn and "on" or "off")
end

--- Item requested 2026-09-21: taper the offset slide toward either end of the chain instead of
--- sliding it all rigidly - see applyMoveOffset for the actual blend. Live while a chain is
--- already pending too (unlike toggleMoveOffset itself), since flipping it mid-adjust is exactly
--- when you would want to see the effect.
function ADFlyoverEditor:toggleMoveOffsetFalloff()
    if not self.moveOffsetFalloffOn and self.moveBreakOn then
        return   -- disconnect is on: a taper cannot stay joined to a track it is cut from
    end
    self.moveOffsetFalloffOn = not self.moveOffsetFalloffOn
    -- An offset that tapers into the track it came from cannot also be cut loose from it.
    if self.moveOffsetFalloffOn then
        self.moveBreakOn = false
    end
    if self.moveOffsetChainIds ~= nil then
        self:applyMoveOffset()
    end
    ADFlyoverSettings.debugLog("[FlyoverEditor]: move offset falloff %s.", self.moveOffsetFalloffOn and "on" or "off")
end

--- Rotate's pivot choice (settled 2026-09-21): "click" rotates the moved set around the dragged
--- point's own start position, "centroid" around the average of the whole set's start positions.
--- Only takes effect on the NEXT grab (see beginDrag) - changing it mid-drag would yank the
--- pivot out from under an already-rotating shape.
function ADFlyoverEditor:cycleMoveRotatePivot()
    self.moveRotatePivotMode = (self.moveRotatePivotMode == "click") and "centroid" or "click"
    ADFlyoverSettings.debugLog("[FlyoverEditor]: move rotate pivot -> %s.", self.moveRotatePivotMode)
end

function ADFlyoverEditor:setMoveOffsetFalloffRadius(value)
    self.moveOffsetFalloffRadius = math.max(0, math.min(AutoDrive.FLYOVER_FALLOFF_MAX, value))
    if self.moveOffsetChainIds ~= nil then
        self:applyMoveOffset()
    end
end

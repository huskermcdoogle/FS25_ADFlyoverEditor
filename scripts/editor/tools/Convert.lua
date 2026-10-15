-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua
-- loads it after FlyoverEditor.lua, in the old file's order.
-- MODSPLIT: HELPERS FROM THE FILES LOADED BEFORE THIS ONE (tools/modsplit/split.py writes this block)
for _, name in ipairs({ "LINK_LISTS", "addLink", "linkList", "removeLink" }) do
    if ADFlyoverEditor.shared == nil or ADFlyoverEditor.shared[name] == nil then
        Logging.error("[FlyoverEditor]: Convert.lua needs %s, which no file loaded before it shares", name)
    end
end
local LINK_LISTS = ADFlyoverEditor.shared.LINK_LISTS
local addLink = ADFlyoverEditor.shared.addLink
local linkList = ADFlyoverEditor.shared.linkList
local removeLink = ADFlyoverEditor.shared.removeLink
-- MODSPLIT: end of the helpers

-- ---------------------------------------------------------------------------------------------
-- Convert a track: priority, direction, or reversed.
--
-- Scoped the same way as delete - one waypoint, or the whole run out to the junctions at each end -
-- because these are the same kind of edit: something you decide about a stretch of route, not about
-- an individual point.
-- ---------------------------------------------------------------------------------------------

-- REVERSE flips which way a one-way runs ("other way"); REVERSEROAD makes AutoDrive's reverse road - a
-- link vehicles drive in reverse gear (listed in the start's out, not the end's incoming).
ADFlyoverEditor.CONVERT_OP = { SECONDARY = 1, PRIMARY = 2, TWOWAY = 3, ONEWAY = 4, REVERSE = 5, REVERSEROAD = 6 }
ADFlyoverEditor.CONVERT_OP_NAMES = { "secondary", "primary", "two-way", "one-way", "other way", "reverse-way" }

function ADFlyoverEditor:cycleConvertOp()
    self.convertOp = (self.convertOp % #self.CONVERT_OP_NAMES) + 1
    ADFlyoverSettings.debugLog("[FlyoverEditor]: convert will make it %s.", self.CONVERT_OP_NAMES[self.convertOp])
end

function ADFlyoverEditor:cycleConvertScope()
    self.convertScope = (self.convertScope % #self.DELETE_SCOPE_NAMES) + 1
    ADFlyoverSettings.debugLog("[FlyoverEditor]: convert applies to %s.", self.DELETE_SCOPE_NAMES[self.convertScope])
end

--- The selection popup's conversions: change only the connections BETWEEN selected points (a link to a
--- point outside the selection is not part of it), or - for priority - the selected points themselves.
function ADFlyoverEditor:menuConvertSelection(op)
    if self.selectionCount == 0 then
        return
    end
    ADEditorHistory:snapshot("convert selection " .. self.CONVERT_OP_NAMES[op])
    local OP, changed = self.CONVERT_OP, 0
    if op == OP.PRIMARY or op == OP.SECONDARY then
        -- only the priority bit: AutoDrive's own marks (map road, field point) stay
        for id in pairs(self.selection) do
            local wp = ADGraphManager:getWayPointById(id)
            if wp ~= nil then
                ADGraphManager:setWayPointFlags(id, ADFlyoverEditor.withPriority(wp.flags, op == OP.SECONDARY), false)
                changed = changed + 1
            end
        end
    else
        local done = {}
        for a in pairs(self.selection) do
            local aw = ADGraphManager:getWayPointById(a)
            local near = {}
            if aw ~= nil then
                for _, listName in ipairs(LINK_LISTS) do
                    for _, b in pairs(linkList(aw, listName) or {}) do
                        if self.selection[b] and b ~= a then near[b] = true end
                    end
                end
            end
            for b in pairs(near) do
                local key = math.min(a, b) .. ":" .. math.max(a, b)
                if not done[key] then
                    done[key] = true
                    local bw = ADGraphManager:getWayPointById(b)
                    local forward = table.contains(aw.out, b)
                    local backward = bw ~= nil and table.contains(bw.out, a)
                    if op == OP.TWOWAY and not (forward and backward) then
                        addLink(a, b); addLink(b, a); changed = changed + 1
                    elseif op == OP.ONEWAY and forward and backward then
                        removeLink(b, a); changed = changed + 1
                    elseif op == OP.REVERSE and forward ~= backward then
                        if forward then removeLink(a, b); addLink(b, a) else removeLink(b, a); addLink(a, b) end
                        changed = changed + 1
                    end
                end
            end
        end
    end
    ADFlyoverSettings.debugLog("[FlyoverEditor]: converted the selection to %s (%d change(s)).", self.CONVERT_OP_NAMES[op], changed)
    ADGraphManager:markChanges()
    -- Kept open like the point/span/run popups: the button swaps to the opposite, so it can be toggled.
end

--- The Convert tool's click: set BOTH the direction and the priority the card is configured for, as one
--- action and one undo step. (The point/span/run popup's "make two-way" etc. stay single changes.)
function ADFlyoverEditor:convertToolClick()
    if self.hoverId == nil then
        return
    end
    ADEditorHistory:snapshot(string.format("convert %s + %s",
        self.CONVERT_OP_NAMES[self.convertDirection], self.CONVERT_OP_NAMES[self.convertPriority]))
    local saved = self.convertOp
    self.convertSkipSnapshot = true
    self.convertOp = self.convertDirection
    self:convertAtCursor()
    self.convertOp = self.convertPriority
    self:convertAtCursor()
    self.convertSkipSnapshot = false
    self.convertOp = saved
end

function ADFlyoverEditor:convertAtCursor()
    if self.hoverId == nil then
        return
    end

    -- Which waypoints, and in what order. Direction work needs the run as an ordered polyline, not
    -- a set: "one-way" and "reversed" only mean anything relative to travelling along it.
    local ordered
    -- Points whose FLAGS may change. The boundary junctions are deliberately not in here: their
    -- priority belongs to the routes that meet at them, not to this leg.
    local flagIds = nil
    -- A lone point's connections, as {from, to} pairs; otherwise the consecutive pairs of `ordered`.
    local pointPairs = nil
    -- The run is a loop and `ordered` ends where it began.
    local closedLoop = false
    if self.convertScope == self.DELETE_SCOPE.RUN then
        local run, count, _, junctions = self:collectRunBetweenJunctions(self.hoverId)
        if count >= AutoDrive.FLYOVER_DELETE_RUN_MAX then
            Logging.warning("[FlyoverEditor]: that run reaches %d waypoints, at or past the safety cap - refusing.", count)
            return
        end
        ordered = self:orderRun(run, self.hoverId)
        flagIds = {}
        for _, id in ipairs(ordered) do
            table.insert(flagIds, id)
        end

        -- Extend the ordered list onto the junctions at each end. Without this the connections
        -- BETWEEN the last run point and the junction were never touched, so converting a leg to
        -- two-way left its two end connections one-way and the leg still could not be driven both
        -- ways - the change looked like it had not taken at all.
        local function junctionNeighbourOf(id, except)
            local wp = ADGraphManager:getWayPointById(id)
            if wp == nil then
                return nil
            end
            for _, listName in ipairs(LINK_LISTS) do
                for _, other in pairs(linkList(wp, listName) or {}) do
                    if junctions[other] and other ~= except then
                        return other
                    end
                end
            end
            return nil
        end
        local function linked(a, b)
            local aw, bw = ADGraphManager:getWayPointById(a), ADGraphManager:getWayPointById(b)
            return aw ~= nil and bw ~= nil and (table.contains(aw.out, b) or table.contains(bw.out, a))
        end

        if #ordered > 0 then
            local first, last = ordered[1], ordered[#ordered]
            local head = junctionNeighbourOf(first)
            -- not the head again: a lone point between two junctions found the same one twice
            local tail = junctionNeighbourOf(last, head)
            if head ~= nil then
                table.insert(ordered, 1, head)
            end
            if tail ~= nil then
                table.insert(ordered, tail)
            elseif (head ~= nil and first ~= last and linked(last, head))
                or (head == nil and #ordered >= 3 and linked(last, first)) then
                -- The run closes on itself: a loop on its own (AutoDrive's field loop) comes back to
                -- the clicked point, a loop off one junction comes back to that junction. The link
                -- that closes it is the run's like any other. Left out, it kept its old direction
                -- while the rest changed - and a later click elsewhere picked it up.
                table.insert(ordered, head or first)
                closedLoop = true
            end
        end
    else
        -- A single waypoint on its own has no direction, so every connection at it is what the
        -- direction operations act on (the popup judges the same set). Each pair is ordered the way
        -- traffic flows through the point: a link that only arrives stays arriving; of the rest, the
        -- first leaves and any further two-way ones arrive, so a mid-road point keeps a through flow.
        ordered = { self.hoverId }
        local wp = ADGraphManager:getWayPointById(self.hoverId)
        if wp ~= nil and self.convertOp ~= self.CONVERT_OP.SECONDARY and self.convertOp ~= self.CONVERT_OP.PRIMARY then
            local near = {}
            for _, listName in ipairs(LINK_LISTS) do
                for _, other in pairs(linkList(wp, listName) or {}) do
                    if other ~= self.hoverId and not table.contains(near, other) then
                        near[#near + 1] = other
                    end
                end
            end
            table.sort(near)
            local pairsList, leaving = {}, false
            for _, other in ipairs(near) do
                local ow = ADGraphManager:getWayPointById(other)
                local fwd = table.contains(wp.out, other)
                local back = ow ~= nil and table.contains(ow.out, self.hoverId)
                if fwd and back then
                    local side = self:roadFlowBeyond(self.hoverId, other)
                    if side == "in" then fwd = false elseif side == "out" then back = false end
                end
                if back and not fwd then
                    pairsList[#pairsList + 1] = { other, self.hoverId }
                elseif fwd and not back then
                    pairsList[#pairsList + 1] = { self.hoverId, other }
                    leaving = true
                elseif not leaving then
                    pairsList[#pairsList + 1] = { self.hoverId, other }
                    leaving = true
                else
                    pairsList[#pairsList + 1] = { other, self.hoverId }
                end
            end
            pointPairs = pairsList
        end
    end

    if #ordered == 0 then
        return
    end

    if not self.convertSkipSnapshot then
        ADEditorHistory:snapshot("convert " .. self.CONVERT_OP_NAMES[self.convertOp])
    end

    local op = self.convertOp
    local changed = 0

    if op == self.CONVERT_OP.SECONDARY or op == self.CONVERT_OP.PRIMARY then
        -- only the priority bit: AutoDrive's own marks (map road, field point) stay
        for _, id in ipairs(flagIds or ordered) do
            local wp = ADGraphManager:getWayPointById(id)
            if wp ~= nil then
                ADGraphManager:setWayPointFlags(id, ADFlyoverEditor.withPriority(wp.flags, op == self.CONVERT_OP.SECONDARY), false)
                changed = changed + 1
            end
        end
    else
        if pointPairs == nil then
            -- One-way and reverse-way keep the way the run already runs: the way most of its one-way
            -- links go. The walk only decides a run that is two-way throughout - it starts from
            -- whichever end it found first, or on a loop from the clicked point, so a click on a
            -- two-way bit of a one-way loop could otherwise send it all the other way round.
            if op == self.CONVERT_OP.ONEWAY or op == self.CONVERT_OP.REVERSEROAD then
                local vote = 0
                for i = 1, #ordered - 1 do
                    local aw = ADGraphManager:getWayPointById(ordered[i])
                    local bw = ADGraphManager:getWayPointById(ordered[i + 1])
                    if aw ~= nil and bw ~= nil then
                        local f = table.contains(aw.out, ordered[i + 1])
                        local b = table.contains(bw.out, ordered[i])
                        if f and not b then vote = vote + 1 elseif b and not f then vote = vote - 1 end
                    end
                end
                if vote < 0 then
                    local rev = {}
                    for i = #ordered, 1, -1 do rev[#rev + 1] = ordered[i] end
                    ordered = rev
                end
            end
            pointPairs = {}
            for i = 1, #ordered - 1 do
                pointPairs[#pointPairs + 1] = { ordered[i], ordered[i + 1] }
            end
        end
        for _, pair in ipairs(pointPairs) do
            local a, b = pair[1], pair[2]
            local aw = ADGraphManager:getWayPointById(a)
            local bw = ADGraphManager:getWayPointById(b)
            if aw ~= nil and bw ~= nil then
                local forward = table.contains(aw.out, b)
                local backward = table.contains(bw.out, a)

                if op == self.CONVERT_OP.TWOWAY then
                    if not (forward and backward) then
                        addLink(a, b)
                        addLink(b, a)
                        changed = changed + 1
                    end
                elseif op == self.CONVERT_OP.ONEWAY then
                    -- Keep the walk direction. On an already two-way run there is no existing
                    -- direction to preserve, so one has to be chosen; 'reversed' flips it if it
                    -- came out the wrong way round.
                    if forward and backward then
                        removeLink(b, a)
                        changed = changed + 1
                    elseif not forward and backward then
                        removeLink(b, a)
                        addLink(a, b)
                        changed = changed + 1
                    elseif not forward and not backward then
                        addLink(a, b)
                        changed = changed + 1
                    end
                elseif op == self.CONVERT_OP.REVERSEROAD then
                    -- Keep the way it runs (a two-way or unlinked pair takes the walk direction), then make
                    -- the link a reverse road: in the start's out, NOT in the end's incoming.
                    local fromId, toId = a, b
                    if backward and not forward then
                        fromId, toId = b, a
                    end
                    local fw, tw = ADGraphManager:getWayPointById(fromId), ADGraphManager:getWayPointById(toId)
                    local already = table.contains(fw.out, toId) and not table.contains(tw.incoming, fromId)
                        and not table.contains(tw.out, fromId)
                    if not already then
                        removeLink(toId, fromId)
                        if not table.contains(fw.out, toId) then
                            table.insert(fw.out, toId)
                        end
                        table.removeValue(tw.incoming, fromId)
                        changed = changed + 1
                    end
                elseif op == self.CONVERT_OP.REVERSE then
                    if forward ~= backward then
                        local fromId, toId = a, b
                        if not forward then
                            fromId, toId = b, a
                        end
                        -- A reverse-way link (in the start's out, NOT the end's incoming) stays a reverse-way
                        -- link, just the other way round; an ordinary one-way stays ordinary.
                        local tw = ADGraphManager:getWayPointById(toId)
                        local wasReverse = tw ~= nil and not table.contains(tw.incoming or {}, fromId)
                        removeLink(fromId, toId)
                        if wasReverse then
                            if not table.contains(tw.out, fromId) then
                                table.insert(tw.out, fromId)
                            end
                        else
                            addLink(toId, fromId)
                        end
                        changed = changed + 1
                    end
                end
            end
        end
    end

    ADFlyoverSettings.debugLog("[FlyoverEditor]: converted %s to %s (%d change(s)).",
        (op == self.CONVERT_OP.SECONDARY or op == self.CONVERT_OP.PRIMARY)
            and string.format("%d waypoint(s)", #(flagIds or ordered))
            or string.format("%d connection(s)%s", #(pointPairs or {}),
                self.convertScope ~= self.DELETE_SCOPE.RUN and " at the point"
                    or closedLoop and ", a closed loop" or ", junctions at the ends included"),
        self.CONVERT_OP_NAMES[op], changed)
    if changed == 0 then
        ADFlyoverSettings.debugLog("[AD]   nothing to do - it was already %s.", self.CONVERT_OP_NAMES[op])
    end

    ADGraphManager:markChanges()
end

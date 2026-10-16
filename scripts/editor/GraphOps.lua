--[[ ADFlyoverGraphOps - THE ONE DOOR (multiplayer step 1)

Every change to the route network, written down in a form that means the same thing on every PC.

How it works. Instead of routing ~80 call sites through new functions, the door compares the network
before and after each action. Points carry a permanent tag of ours (wp.fxTag) that AutoDrive's
renumbering cannot touch (proven against AutoDrive 3.0.1.4's own code, docs/multiplayer-probe-results.md).
So "before" and "after" can be matched point by point, by tag, and the difference IS the action:

    dels   points that were there and are gone          (tag, old index, everything about them)
    adds   points that are new, in their final order    (tag, everything about them)
    sets   points whose place, height, flags or field number changed (before + after)
    lists  points whose out or incoming list changed, as lists of TAGS (before + after)
    markers, groups   the whole list, before + after, only when it changed (they are few)

Because every entry carries before AND after, the same action runs backwards for undo.

This catches every write, including the hand-made link changes in the junction code and the merge
tool, and any write nobody thought of. It costs one walk over the network per action (not per frame).

Order. AutoDrive numbers points by position. A delete shifts later points down; an add goes on the
end. So after any mix of deletes and adds, the order is: the points that survived, in their old
order, then the new points, in the order they were made. apply() rebuilds exactly that, and checks
it: diff() refuses to describe an action whose result does not have that shape (AutoDrive's
createWayPointWithConnections with connect=true overwrites a slot, for one) and says so.

Nothing here sends anything. Step 2 packs actions for the network; this file only describes them
and can play them forwards and backwards. Pure Lua on plain tables, so the harness can test it.
]]

ADFlyoverGraphOps = ADFlyoverGraphOps or {}
local G = ADFlyoverGraphOps

-- Round new and moved coordinates to the millimetre (docs/multiplayer-plan.md 4.2). Off until the
-- regression is proven identical without it; then on, in single player too.
G.QUANTIZE = G.QUANTIZE or false

G.nextTag = G.nextTag or 0

local function q(v)
    if v == nil then return nil end
    return math.floor(v * 1000 + 0.5) / 1000
end

--- Give every untagged point a tag, in id order (so two PCs holding the same network tag it the same).
function G.tagAll(wayPoints)
    local fresh = 0
    for i = 1, #wayPoints do
        local wp = wayPoints[i]
        if wp.fxTag == nil then
            G.nextTag = G.nextTag + 1
            wp.fxTag = G.nextTag
            fresh = fresh + 1
        elseif wp.fxTag > G.nextTag then
            G.nextTag = wp.fxTag
        end
    end
    return fresh
end

local function tagsOf(list, wayPoints)
    local t = {}
    for i = 1, #(list or {}) do
        local w = wayPoints[list[i]]
        -- a link to a number nobody holds: keep it visible rather than drop it
        t[i] = (w ~= nil and w.fxTag) or -list[i]
    end
    return t
end

local function sameList(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

local function copyMarkers(markers)
    local out = {}
    for i, m in ipairs(markers or {}) do
        local c = {}
        for k, v in pairs(m) do c[k] = v end
        out[i] = c
    end
    return out
end

local function copyGroups(groups)
    local out = {}
    for k, v in pairs(groups or {}) do out[k] = v end
    return out
end

--- The network as tags: what diff() compares against. One walk over the graph.
--- graph = { wayPoints = {...}, mapMarkers = {...}, groups = {...} } (ADGraphManager's own tables).
function G.capture(graph)
    local wps = graph.wayPoints
    G.tagAll(wps)
    local s = { order = {}, pts = {}, markers = {}, groups = copyGroups(graph.groups) }
    for i = 1, #wps do
        local wp = wps[i]
        s.order[i] = wp.fxTag
        s.pts[wp.fxTag] = { x = wp.x, y = wp.y, z = wp.z, flags = wp.flags, fieldID = wp.fieldID,
                            out = tagsOf(wp.out, wps), incoming = tagsOf(wp.incoming, wps), index = i }
    end
    -- markers point at a waypoint NUMBER; keep the tag instead
    for i, m in ipairs(graph.mapMarkers or {}) do
        local c = {}
        for k, v in pairs(m) do c[k] = v end
        local w = wps[m.id]
        c.id = nil
        c.tag = w ~= nil and w.fxTag or nil
        s.markers[i] = c
    end
    return s
end

local function sameMarkers(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        local x, y = a[i], b[i]
        if x.tag ~= y.tag or x.name ~= y.name or x.group ~= y.group or (x.isADDebug == true) ~= (y.isADDebug == true) then
            return false
        end
    end
    return true
end

local function sameGroups(a, b)
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k, v in pairs(b) do if a[k] ~= v then return false end end
    return true
end

--- What changed between `before` (a capture) and the network as it is now. Tags new points.
--- Returns the action, or nil and why when the change has a shape apply() cannot rebuild.
--- An action with nothing in it is returned as nil, "nothing changed".
function G.diff(before, graph, label)
    local wps = graph.wayPoints
    G.tagAll(wps)
    if G.QUANTIZE then
        for i = 1, #wps do
            local wp = wps[i]
            local b = before.pts[wp.fxTag]
            if b == nil or b.x ~= wp.x or b.y ~= wp.y or b.z ~= wp.z then
                wp.x, wp.y, wp.z = q(wp.x), q(wp.y), q(wp.z)
            end
        end
    end
    local after = G.capture(graph)
    local a = { label = label, dels = {}, adds = {}, sets = {}, lists = {} }
    local empty = true

    -- deleted: in before, not now (kept in before's order, with their old index)
    for i, tag in ipairs(before.order) do
        if after.pts[tag] == nil then
            local p = before.pts[tag]
            a.dels[#a.dels + 1] = { tag = tag, index = i, x = p.x, y = p.y, z = p.z, flags = p.flags,
                                    fieldID = p.fieldID, out = p.out, incoming = p.incoming }
            empty = false
        end
    end
    -- the order must be: survivors in their old order, then the new points
    local k = 0
    for _, tag in ipairs(before.order) do
        if after.pts[tag] ~= nil then
            k = k + 1
            if after.order[k] ~= tag then
                return nil, string.format("order changed at %d (an overwritten or moved slot): %s", k, tostring(label))
            end
        end
    end
    for i = k + 1, #after.order do
        local tag = after.order[i]
        if before.pts[tag] ~= nil then
            return nil, string.format("an old point sits among the new ones at %d: %s", i, tostring(label))
        end
        local p = after.pts[tag]
        a.adds[#a.adds + 1] = { tag = tag, x = p.x, y = p.y, z = p.z, flags = p.flags, fieldID = p.fieldID,
                                out = p.out, incoming = p.incoming }
        empty = false
    end
    -- changed points: place, flags, field number, lists
    for i = 1, k do
        local tag = after.order[i]
        local p, b = after.pts[tag], before.pts[tag]
        if p.x ~= b.x or p.y ~= b.y or p.z ~= b.z or p.flags ~= b.flags or p.fieldID ~= b.fieldID then
            a.sets[#a.sets + 1] = { tag = tag,
                before = { x = b.x, y = b.y, z = b.z, flags = b.flags, fieldID = b.fieldID },
                after = { x = p.x, y = p.y, z = p.z, flags = p.flags, fieldID = p.fieldID } }
            empty = false
        end
        if not sameList(p.out, b.out) or not sameList(p.incoming, b.incoming) then
            a.lists[#a.lists + 1] = { tag = tag, bo = b.out, bi = b.incoming, ao = p.out, ai = p.incoming }
            empty = false
        end
    end
    if not sameMarkers(before.markers, after.markers) then
        a.markers = { before = before.markers, after = after.markers }
        empty = false
    end
    if not sameGroups(before.groups, after.groups) then
        a.groups = { before = before.groups, after = after.groups }
        empty = false
    end
    if empty then return nil, "nothing changed" end
    a.countBefore, a.countAfter = #before.order, #after.order
    return a, after
end

--- Play an action on a graph, forwards (backwards = true for undo). Works on the graph's own tables:
--- reuses every point table it keeps (so vehicles and tools holding one still hold the right point),
--- makes tables only for points that come into being, renumbers once, rewrites every link once.
--- Returns true, or false and why (the graph is not the one the action was made on).
function G.apply(graph, a, backwards)
    local wps = graph.wayPoints
    local gone, born, sets, lists
    if backwards then
        gone, born = {}, a.dels
        for _, p in ipairs(a.adds) do gone[p.tag] = true end
    else
        gone, born = {}, a.adds
        for _, p in ipairs(a.dels) do gone[p.tag] = true end
    end
    if #wps ~= (backwards and a.countAfter or a.countBefore) then
        return false, string.format("network has %d points, the action expects %d", #wps,
            backwards and a.countAfter or a.countBefore)
    end

    -- old number -> tag, before anything moves (for the links of points the action does not touch)
    local tagAt, byTag = {}, {}
    for i = 1, #wps do
        local wp = wps[i]
        if wp.fxTag == nil then return false, "untagged point " .. i end
        tagAt[i] = wp.fxTag
        byTag[wp.fxTag] = wp
    end

    -- the new order
    local order = {}
    for i = 1, #wps do
        if not gone[wps[i].fxTag] then order[#order + 1] = wps[i] end
    end
    local function make(p)
        return { id = 0, x = p.x, y = p.y, z = p.z, out = {}, incoming = {}, flags = p.flags,
                 fieldID = p.fieldID, fxTag = p.tag }
    end
    if backwards then
        -- deleted points go back where they were, lowest number first
        for _, p in ipairs(born) do
            local t = make(p)
            table.insert(order, p.index, t)
            byTag[p.tag] = t
        end
    else
        for _, p in ipairs(born) do
            local t = make(p)
            order[#order + 1] = t
            byTag[p.tag] = t
        end
    end
    for _, s in ipairs(a.sets) do
        local v = backwards and s.before or s.after
        local wp = byTag[s.tag]
        if wp == nil then return false, "no point with tag " .. tostring(s.tag) end
        wp.x, wp.y, wp.z, wp.flags, wp.fieldID = v.x, v.y, v.z, v.flags, v.fieldID
    end

    -- renumber once
    local newId = {}
    for i, wp in ipairs(order) do
        wp.id = i
        newId[wp.fxTag] = i
    end
    local function ids(tagList)
        local out = {}
        for i, t in ipairs(tagList) do
            -- a negative "tag" is a link to a number nobody held; keep the number as it was
            out[i] = (t > 0 and newId[t]) or -t
        end
        return out
    end
    -- links: points the action names get their lists from it; every other point keeps its lists,
    -- renumbered (old number -> tag -> new number)
    local named = {}
    for _, l in ipairs(a.lists) do named[l.tag] = l end
    local bornLists = {}
    for _, p in ipairs(born) do bornLists[p.tag] = p end
    for _, wp in ipairs(order) do
        local l, b = named[wp.fxTag], bornLists[wp.fxTag]
        if l ~= nil then
            wp.out = ids(backwards and l.bo or l.ao)
            wp.incoming = ids(backwards and l.bi or l.ai)
        elseif b ~= nil then
            wp.out, wp.incoming = ids(b.out), ids(b.incoming)
        else
            for i, id in ipairs(wp.out) do
                local t = tagAt[id]
                wp.out[i] = (t ~= nil and newId[t]) or id
            end
            for i, id in ipairs(wp.incoming) do
                local t = tagAt[id]
                wp.incoming[i] = (t ~= nil and newId[t]) or id
            end
        end
    end
    -- put the order in place (same table, so ADGraphManager keeps its reference)
    for i = 1, math.max(#wps, #order) do wps[i] = order[i] end

    -- markers: the action's list when it changed them, otherwise renumber what is there
    if a.markers ~= nil then
        local list = backwards and a.markers.before or a.markers.after
        local markers = graph.mapMarkers
        for i = #markers, 1, -1 do markers[i] = nil end
        for i, m in ipairs(list) do
            local c = {}
            for k, v in pairs(m) do c[k] = v end
            c.tag = nil
            c.id = m.tag ~= nil and newId[m.tag] or -1
            c.markerIndex = i
            markers[i] = c
        end
    else
        for _, m in ipairs(graph.mapMarkers or {}) do
            local t = tagAt[m.id]
            if t ~= nil and newId[t] ~= nil then m.id = newId[t] end
        end
    end
    if a.groups ~= nil then
        local g = graph.groups
        for k in pairs(g) do g[k] = nil end
        for k, v in pairs(backwards and a.groups.before or a.groups.after) do g[k] = v end
    end
    return true
end

--- Two graphs the same, point by point (number, tag, place, flags, field, both lists) and markers.
--- For tests: returns true, or false and the first difference.
function G.same(ga, gb)
    local a, b = ga.wayPoints, gb.wayPoints
    if #a ~= #b then return false, string.format("%d points vs %d", #a, #b) end
    for i = 1, #a do
        local x, y = a[i], b[i]
        if x.id ~= y.id or x.fxTag ~= y.fxTag then return false, "number/tag at " .. i end
        if x.x ~= y.x or x.y ~= y.y or x.z ~= y.z then return false, "place at " .. i end
        if x.flags ~= y.flags or x.fieldID ~= y.fieldID then return false, "flags/field at " .. i end
        if not sameList(x.out, y.out) then return false, "out list at " .. i end
        if not sameList(x.incoming, y.incoming) then return false, "incoming list at " .. i end
    end
    local ma, mb = ga.mapMarkers or {}, gb.mapMarkers or {}
    if #ma ~= #mb then return false, "marker count" end
    for i = 1, #ma do
        if ma[i].id ~= mb[i].id or ma[i].name ~= mb[i].name or ma[i].group ~= mb[i].group then
            return false, "marker " .. i
        end
    end
    return true
end

--- A plain copy of a graph (tags included), for tests and for checking an action plays back.
function G.copyGraph(graph)
    local wps = {}
    for i, wp in ipairs(graph.wayPoints) do
        local o, n = {}, {}
        for j, v in ipairs(wp.out or {}) do o[j] = v end
        for j, v in ipairs(wp.incoming or {}) do n[j] = v end
        wps[i] = { id = wp.id, x = wp.x, y = wp.y, z = wp.z, flags = wp.flags, fieldID = wp.fieldID,
                   out = o, incoming = n, fxTag = wp.fxTag }
    end
    return { wayPoints = wps, mapMarkers = copyMarkers(graph.mapMarkers), groups = copyGroups(graph.groups) }
end

--- How big an action is, in plain numbers, for the log.
function G.describe(a)
    if a == nil then return "nothing" end
    return string.format("%s: %d added, %d deleted, %d moved/flagged, %d relinked%s%s", tostring(a.label),
        #a.adds, #a.dels, #a.sets, #a.lists, a.markers and ", markers" or "", a.groups and ", groups" or "")
end

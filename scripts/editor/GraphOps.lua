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

-- TAG SPACES (multiplayer): each player numbers the points THEY make from their own block, so two
-- players adding points at the same moment can never hand out the same tag. Block = player slot * 2^24;
-- the server (and single player) is slot 0, which also holds the tags of the network as loaded.
G.TAG_BLOCK = 2 ^ 24
G.tagBase = G.tagBase or 0

--- Use player slot `slot`'s block for new tags from now on.
function G.setTagSpace(slot)
    G.tagBase = slot * G.TAG_BLOCK
    G.nextTag = G.tagBase
end

--- Give every untagged point a tag, in id order (so two PCs holding the same network tag it the same).
function G.tagAll(wayPoints)
    local fresh = 0
    local top = G.tagBase + G.TAG_BLOCK
    for i = 1, #wayPoints do
        local wp = wayPoints[i]
        if wp.fxTag == nil then
            G.nextTag = G.nextTag + 1
            wp.fxTag = G.nextTag
            fresh = fresh + 1
        elseif wp.fxTag > G.nextTag and wp.fxTag < top then
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
    -- every point and marker is remembered by its table here too: a delete that is about to be
    -- undone must find the table it had, even if no action has run since it was made (issue #26)
    graph.tableOf = graph.tableOf or {}
    graph.markerOf = graph.markerOf or {}
    for i = 1, #wps do
        local wp = wps[i]
        s.order[i] = wp.fxTag
        graph.tableOf[wp.fxTag] = wp
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
        if c.tag ~= nil then graph.markerOf[c.tag] = m end
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
    -- the table each point and each marker had, by tag, kept across actions: an undo that brings one
    -- back reuses its table, so anything still holding it (a vehicle's route, its destination) keeps
    -- the live one. Without this the undo built new tables and those holders lost them (issue #26).
    graph.tableOf = graph.tableOf or {}
    graph.markerOf = graph.markerOf or {}
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
        graph.tableOf[wp.fxTag] = wp
    end
    for _, m in ipairs(graph.mapMarkers or {}) do
        local t = tagAt[m.id]
        if t ~= nil then graph.markerOf[t] = m end
    end

    -- the new order
    local order = {}
    for i = 1, #wps do
        if not gone[wps[i].fxTag] then order[#order + 1] = wps[i] end
    end
    local function make(p)
        -- the point's own table when it has one (see the top of apply): cleared, then filled in
        local t = graph.tableOf[p.tag] or {}
        for k in pairs(t) do t[k] = nil end
        t.id, t.x, t.y, t.z, t.out, t.incoming = 0, p.x, p.y, p.z, {}, {}
        t.flags, t.fieldID, t.fxTag = p.flags, p.fieldID, p.tag
        graph.tableOf[p.tag] = t
        return t
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
            -- the marker's own table when it has one (see the top of apply), so vehicles keep it
            local c = (m.tag ~= nil and graph.markerOf[m.tag]) or {}
            for k in pairs(c) do c[k] = nil end
            for k, v in pairs(m) do c[k] = v end
            c.tag = nil
            c.id = m.tag ~= nil and newId[m.tag] or -1
            c.markerIndex = i
            if m.tag ~= nil then graph.markerOf[m.tag] = c end
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

-- ------------------------------------------------------------------ REPLAY: apply by tag, forgivingly
--[[ apply() above is EXACT: it needs the very network the action was made on, and rebuilds the order
from it. That is right for undo in single player and for a client applying what the server sends.

replay() is for an action made on a slightly different network: the server applying a player's action
after other players' actions got in first, or a player putting their own unconfirmed actions back on
top of what the server sent. It works only by tag:

  deleted points   removed if still there; every link to them, anywhere, removed too
  new points       added at the end, in order (unless a point with that tag is already there);
                   played backwards, deleted points come back at the end too
  place / flags    set, if the point is still there
  links            as CHANGES, not whole lists: the tags the action took out of a list are taken out
                   (first match), the tags it added are added at the end - so another player's new link
                   on the same point survives. A link to a point that is gone is skipped.
  markers          names the action removed are removed, names it added are added
  groups           set to the action's

Points keep their tables. Returns true and a list of what it had to skip (each a short text).
]]
local function counts(list)
    local c = {}
    for _, t in ipairs(list) do c[t] = (c[t] or 0) + 1 end
    return c
end

-- the change from list b to list a, as removals (multiset) and additions (in a's order)
local function delta(b, a)
    local cb, ca = counts(b), counts(a)
    local rem, add = {}, {}
    for t, n in pairs(cb) do
        local k = n - (ca[t] or 0)
        if k > 0 then rem[t] = k end
    end
    local seen = {}
    for _, t in ipairs(a) do
        seen[t] = (seen[t] or 0) + 1
        if seen[t] > (cb[t] or 0) then add[#add + 1] = t end
    end
    return rem, add
end

local function applyDelta(list, rem, add, exists, skipped, what)
    if next(rem) ~= nil then
        local left = {}
        for t, n in pairs(rem) do left[t] = n end
        local out = {}
        for _, t in ipairs(list) do
            if (left[t] or 0) > 0 then left[t] = left[t] - 1 else out[#out + 1] = t end
        end
        for i = #list, 1, -1 do list[i] = nil end
        for i, t in ipairs(out) do list[i] = t end
    end
    for _, t in ipairs(add) do
        if exists(t) then list[#list + 1] = t else skipped[#skipped + 1] = what .. " to a point that is gone" end
    end
end

function G.replay(graph, a, backwards)
    local wps = graph.wayPoints
    local skipped = {}
    local gone, born = {}, nil
    if backwards then
        born = a.dels
        for _, p in ipairs(a.adds) do gone[p.tag] = true end
    else
        born = a.adds
        for _, p in ipairs(a.dels) do gone[p.tag] = true end
    end

    -- the network in tags
    local byTag, tagAt = {}, {}
    for i = 1, #wps do
        local wp = wps[i]
        if wp.fxTag == nil then return false, { "untagged point " .. i } end
        byTag[wp.fxTag] = wp
        tagAt[i] = wp.fxTag
    end
    local L = {}   -- table -> { out = tags, incoming = tags }
    for i = 1, #wps do
        local wp = wps[i]
        local o, n = {}, {}
        for k, id in ipairs(wp.out or {}) do o[k] = tagAt[id] or -id end
        for k, id in ipairs(wp.incoming or {}) do n[k] = tagAt[id] or -id end
        L[wp] = { out = o, incoming = n }
    end

    -- order: survivors, then the born (backwards: the deleted go back where they were, if they can)
    local order = {}
    for i = 1, #wps do
        if not gone[wps[i].fxTag] then order[#order + 1] = wps[i] end
    end
    local bornLists = {}
    for _, p in ipairs(born) do
        if byTag[p.tag] ~= nil and not gone[p.tag] then
            skipped[#skipped + 1] = "a point that is already there"
        else
            local t = { id = 0, x = p.x, y = p.y, z = p.z, out = {}, incoming = {}, flags = p.flags,
                        fieldID = p.fieldID, fxTag = p.tag }
            L[t] = { out = {}, incoming = {} }
            -- always on the end: on a network others have changed, the old place in the list means
            -- nothing, and the end is the one place the door can describe (survivors, then new points)
            order[#order + 1] = t
            byTag[p.tag] = t
            bornLists[#bornLists + 1] = { t = t, out = p.out, incoming = p.incoming }
        end
    end
    for tag in pairs(gone) do byTag[tag] = nil end
    local function exists(t) return t > 0 and byTag[t] ~= nil end

    -- place and flags
    for _, s in ipairs(a.sets) do
        local v = backwards and s.before or s.after
        local wp = byTag[s.tag]
        if wp == nil then
            skipped[#skipped + 1] = "a move of a point that is gone"
        else
            wp.x, wp.y, wp.z, wp.flags, wp.fieldID = v.x, v.y, v.z, v.flags, v.fieldID
        end
    end

    -- links to deleted points go, wherever they are
    for _, wp in ipairs(order) do
        for _, key in ipairs({ "out", "incoming" }) do
            local keep = {}
            for _, t in ipairs(L[wp][key]) do
                if t <= 0 or not gone[t] then keep[#keep + 1] = t end
            end
            L[wp][key] = keep
        end
    end
    -- the action's link changes
    for _, l in ipairs(a.lists) do
        local wp = byTag[l.tag]
        if wp == nil then
            skipped[#skipped + 1] = "links of a point that is gone"
        else
            local bo, bi, ao, ai = l.bo, l.bi, l.ao, l.ai
            if backwards then bo, bi, ao, ai = ao, ai, bo, bi end
            local r1, a1 = delta(bo, ao)
            applyDelta(L[wp].out, r1, a1, exists, skipped, "a link")
            local r2, a2 = delta(bi, ai)
            applyDelta(L[wp].incoming, r2, a2, exists, skipped, "a link")
        end
    end
    -- the born points' own lists
    for _, b in ipairs(bornLists) do
        for _, t in ipairs(b.out or {}) do
            if exists(t) then table.insert(L[b.t].out, t) else skipped[#skipped + 1] = "a link to a point that is gone" end
        end
        for _, t in ipairs(b.incoming or {}) do
            if exists(t) then table.insert(L[b.t].incoming, t) else skipped[#skipped + 1] = "a link to a point that is gone" end
        end
    end

    -- renumber, write the lists back as numbers
    local newId = {}
    for i, wp in ipairs(order) do
        wp.id = i
        newId[wp.fxTag] = i
    end
    for _, wp in ipairs(order) do
        local o, n = {}, {}
        for _, t in ipairs(L[wp].out) do o[#o + 1] = (t > 0 and newId[t]) or -t end
        for _, t in ipairs(L[wp].incoming) do n[#n + 1] = (t > 0 and newId[t]) or -t end
        wp.out, wp.incoming = o, n
    end
    for i = 1, math.max(#wps, #order) do wps[i] = order[i] end

    -- markers: keep the ones not touched (renumbered), take out what the action removed, add what it added
    local markers = graph.mapMarkers or {}
    local mb, ma
    if a.markers ~= nil then
        mb, ma = a.markers.before, a.markers.after
        if backwards then mb, ma = ma, mb end
    end
    local function mkey(tag, name) return tostring(tag) .. "|" .. tostring(name) end
    local removeM, addM = {}, {}
    if mb ~= nil then
        local inA, inB = {}, {}
        for _, m in ipairs(ma) do inA[mkey(m.tag, m.name)] = true end
        for _, m in ipairs(mb) do inB[mkey(m.tag, m.name)] = true end
        for _, m in ipairs(mb) do if not inA[mkey(m.tag, m.name)] then removeM[mkey(m.tag, m.name)] = true end end
        for _, m in ipairs(ma) do if not inB[mkey(m.tag, m.name)] then addM[#addM + 1] = m end end
    end
    local kept = {}
    for _, m in ipairs(markers) do
        local t = tagAt[m.id]
        if not removeM[mkey(t, m.name)] and (t == nil or not gone[t]) then
            if t ~= nil then m.id = newId[t] or m.id end
            kept[#kept + 1] = m
        end
    end
    for _, m in ipairs(addM) do
        if m.tag ~= nil and newId[m.tag] ~= nil then
            local c = {}
            for k, v in pairs(m) do c[k] = v end
            c.tag = nil
            c.id = newId[m.tag]
            kept[#kept + 1] = c
        else
            skipped[#skipped + 1] = "a name on a point that is gone"
        end
    end
    for i = #markers, 1, -1 do markers[i] = nil end
    for i, m in ipairs(kept) do
        m.markerIndex = i
        markers[i] = m
    end
    if a.groups ~= nil then
        local g = graph.groups
        for k in pairs(g) do g[k] = nil end
        for k, v in pairs(backwards and a.groups.before or a.groups.after) do g[k] = v end
    end
    return true, skipped
end

-- ------------------------------------------------------------------ FITS: may this action be undone (redone)?
--[[ Per-player undo (multiplayer step 6). An action may be undone only while everything it changed still
looks exactly as the action left it - nobody, the player included, has changed those things since. Then
undoing it takes back only what the player did. Redo is the same the other way: everything must still look
as the undo left it.

Judged on the network as it is NOW, not on who touched what: so when the player who got in the way
undoes their own change, the blocked action fits again by itself.

What "everything it changed" means:
  points it added       still there, same place/flags/field, same links      (undo deletes them)
  points it deleted     still gone                                             (undo brings them back)
  place/flags it set    still those values
  links it made/broke   still made/broken - the links only, another player's new link on the same point
                        does not get in the way (a link belongs to whoever makes it)
  names it added/removed  still added/removed

G.fits(graph, a, backwards): backwards = true asks "may it be undone?" (graph must show the action's
AFTER); false asks "may it be redone?" (graph must show its BEFORE). Returns true, or false, the tag of
the first point in the way (for "who changed it") and a short reason.
]]
local function multiset(list)
    local c = {}
    for _, t in ipairs(list or {}) do c[t] = (c[t] or 0) + 1 end
    return c
end
local function sameMultiset(a, b)
    local ca, cb = multiset(a), multiset(b)
    for k, v in pairs(ca) do if cb[k] ~= v then return false end end
    for k, v in pairs(cb) do if ca[k] ~= v then return false end end
    return true
end

function G.fits(graph, a, backwards)
    local wps = graph.wayPoints
    local byTag, tagAt = {}, {}
    for i = 1, #wps do
        local wp = wps[i]
        if wp.fxTag ~= nil then byTag[wp.fxTag] = wp; tagAt[i] = wp.fxTag end
    end
    local function tagsOfList(list)
        local t = {}
        for i, id in ipairs(list or {}) do t[i] = tagAt[id] or -id end
        return t
    end
    local function samePoint(wp, v)
        return wp.x == v.x and wp.y == v.y and wp.z == v.z and wp.flags == v.flags and wp.fieldID == v.fieldID
    end

    -- the points that must be there (with these values and links), and the ones that must be gone
    local mustBe, mustGo = a.adds, a.dels
    if not backwards then mustBe, mustGo = a.dels, a.adds end
    for _, p in ipairs(mustBe) do
        local wp = byTag[p.tag]
        if wp == nil then return false, p.tag, "a point it made is gone" end
        if not samePoint(wp, p) then return false, p.tag, "a point it made was moved" end
        if not sameMultiset(tagsOfList(wp.out), p.out) or not sameMultiset(tagsOfList(wp.incoming), p.incoming) then
            return false, p.tag, "a point it made was linked to or from"
        end
    end
    for _, p in ipairs(mustGo) do
        if byTag[p.tag] ~= nil then return false, p.tag, "a point it deleted is back" end
    end
    for _, s in ipairs(a.sets) do
        local wp = byTag[s.tag]
        if wp == nil then return false, s.tag, "a point it moved is gone" end
        if not samePoint(wp, backwards and s.after or s.before) then return false, s.tag, "a point it moved was moved again" end
    end
    -- links: what it added must still be there, what it took away must still be away
    for _, l in ipairs(a.lists) do
        local wp = byTag[l.tag]
        if wp == nil then return false, l.tag, "a point it linked is gone" end
        local fromO, toO, fromI, toI = l.bo, l.ao, l.bi, l.ai
        if not backwards then fromO, toO, fromI, toI = l.ao, l.bo, l.ai, l.bi end
        for _, pair in ipairs({ { fromO, toO, wp.out }, { fromI, toI, wp.incoming } }) do
            local before, after, now = multiset(pair[1]), multiset(pair[2]), multiset(tagsOfList(pair[3]))
            for t, n in pairs(after) do
                if n > (before[t] or 0) and (now[t] or 0) < n then return false, l.tag, "a link it made was taken away" end
            end
            for t, n in pairs(before) do
                if n > (after[t] or 0) and (now[t] or 0) > (after[t] or 0) then return false, l.tag, "a link it took away was made again" end
            end
        end
    end
    if a.markers ~= nil then
        local want, other = a.markers.after, a.markers.before
        if not backwards then want, other = a.markers.before, a.markers.after end
        local have = {}
        for _, m in ipairs(graph.mapMarkers or {}) do have[tostring(tagAt[m.id]) .. "|" .. tostring(m.name)] = true end
        local inWant = {}
        for _, m in ipairs(want) do inWant[tostring(m.tag) .. "|" .. tostring(m.name)] = true end
        for _, m in ipairs(want) do
            if not have[tostring(m.tag) .. "|" .. tostring(m.name)] then return false, m.tag, "a name it gave was changed" end
        end
        for _, m in ipairs(other) do
            local k = tostring(m.tag) .. "|" .. tostring(m.name)
            if not inWant[k] and have[k] then return false, m.tag, "a name it took away is back" end
        end
    end
    return true
end

--- Every tag an action touches (for "who changed it last"): points added, deleted, moved, relinked, named.
function G.touched(a)
    local t = {}
    for _, p in ipairs(a.adds) do t[#t + 1] = p.tag end
    for _, p in ipairs(a.dels) do t[#t + 1] = p.tag end
    for _, s in ipairs(a.sets) do t[#t + 1] = s.tag end
    for _, l in ipairs(a.lists) do t[#t + 1] = l.tag end
    if a.markers ~= nil then
        for _, m in ipairs(a.markers.before) do if m.tag then t[#t + 1] = m.tag end end
        for _, m in ipairs(a.markers.after) do if m.tag then t[#t + 1] = m.tag end end
    end
    return t
end

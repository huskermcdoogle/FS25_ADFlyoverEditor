-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua
-- loads it after FlyoverEditor.lua, in the old file's order.
-- MODSPLIT: HELPERS FROM THE FILES LOADED BEFORE THIS ONE (tools/modsplit/split.py writes this block)
for _, name in ipairs({ "JX_PART_AT", "JX_PART_NEAR", "JX_WHOLE_PIECE_REACH", "junctionConnect", "junctionDisconnect", "junctionLayChain", "junctionRouteCheck", "junctionShareCrossings", "jxBeforeInPlace", "jxBegin", "jxBuildBegin", "jxBuildEnd", "jxByPlace", "jxCheckKept", "jxCheckLanes", "jxCheckMiddle", "jxCheckPassages", "jxCheckReport", "jxCheckSetup", "jxCheckTouched", "jxCheckTwin", "jxCheckTwinReport", "jxEnd", "jxInSite", "jxKeptRoadsOf", "jxMayDelete", "jxNoteAdded", "jxPartLetters", "jxRemove", "jxRouteLines", "jxSnapshot", "jxState", "jxTurnLabel", "tryCall" }) do
    if ADFlyoverEditor.shared == nil or ADFlyoverEditor.shared[name] == nil then
        Logging.error("[FlyoverEditor]: JxCheckCard.lua needs %s, which no file loaded before it shares", name)
    end
end
local JX_PART_AT = ADFlyoverEditor.shared.JX_PART_AT
local JX_PART_NEAR = ADFlyoverEditor.shared.JX_PART_NEAR
local JX_WHOLE_PIECE_REACH = ADFlyoverEditor.shared.JX_WHOLE_PIECE_REACH
local junctionConnect = ADFlyoverEditor.shared.junctionConnect
local junctionDisconnect = ADFlyoverEditor.shared.junctionDisconnect
local junctionLayChain = ADFlyoverEditor.shared.junctionLayChain
local junctionRouteCheck = ADFlyoverEditor.shared.junctionRouteCheck
local junctionShareCrossings = ADFlyoverEditor.shared.junctionShareCrossings
local jxBeforeInPlace = ADFlyoverEditor.shared.jxBeforeInPlace
local jxBegin = ADFlyoverEditor.shared.jxBegin
local jxBuildBegin = ADFlyoverEditor.shared.jxBuildBegin
local jxBuildEnd = ADFlyoverEditor.shared.jxBuildEnd
local jxByPlace = ADFlyoverEditor.shared.jxByPlace
local jxCheckKept = ADFlyoverEditor.shared.jxCheckKept
local jxCheckLanes = ADFlyoverEditor.shared.jxCheckLanes
local jxCheckMiddle = ADFlyoverEditor.shared.jxCheckMiddle
local jxCheckPassages = ADFlyoverEditor.shared.jxCheckPassages
local jxCheckReport = ADFlyoverEditor.shared.jxCheckReport
local jxCheckSetup = ADFlyoverEditor.shared.jxCheckSetup
local jxCheckTouched = ADFlyoverEditor.shared.jxCheckTouched
local jxCheckTwin = ADFlyoverEditor.shared.jxCheckTwin
local jxCheckTwinReport = ADFlyoverEditor.shared.jxCheckTwinReport
local jxEnd = ADFlyoverEditor.shared.jxEnd
local jxInSite = ADFlyoverEditor.shared.jxInSite
local jxKeptRoadsOf = ADFlyoverEditor.shared.jxKeptRoadsOf
local jxMayDelete = ADFlyoverEditor.shared.jxMayDelete
local jxNoteAdded = ADFlyoverEditor.shared.jxNoteAdded
local jxPartLetters = ADFlyoverEditor.shared.jxPartLetters
local jxRemove = ADFlyoverEditor.shared.jxRemove
local jxRouteLines = ADFlyoverEditor.shared.jxRouteLines
local jxSnapshot = ADFlyoverEditor.shared.jxSnapshot
local jxState = ADFlyoverEditor.shared.jxState
local jxTurnLabel = ADFlyoverEditor.shared.jxTurnLabel
local tryCall = ADFlyoverEditor.shared.tryCall
-- MODSPLIT: end of the helpers

--- THE LANE ENDS AROUND A SITE, by place: every point within 45 m of (cx, cz) with one neighbour.
--- Taken before and after a clear, so the build that follows knows which ends this clear cut
--- (junctionReachEnds) - by place, as the clear reissues ids. Neighbours are counted by PLACE too:
--- a loose track start beside 1 led to two points lying on one spot, which the clear folded into one,
--- and counted by id it came out as an end this clear had cut.
local function jxLaneEndsNear(cx, cz)
    local out = {}
    for _, w in pairs(ADGraphManager:getWayPoints() or {}) do
        if w ~= nil and w.id ~= nil and (w.x - cx) ^ 2 + (w.z - cz) ^ 2 <= 45 * 45 then
            local s, n = {}, 0
            for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
                for _, id in ipairs(lst) do
                    local o = id ~= w.id and ADGraphManager:getWayPointById(id) or nil
                    if o ~= nil then
                        local k = string.format("%.1f_%.1f", o.x, o.z)
                        if not s[k] then s[k], n = true, n + 1 end
                    end
                end
            end
            if n == 1 then out[string.format("%.2f_%.2f", w.x, w.z)] = { x = w.x, z = w.z } end
        end
    end
    return out
end


--- WHAT THE NETWORK LOOKS LIKE AROUND A CLEARED JUNCTION, as one string: every point within 60 m,
--- where it stands and where each of its links leads. Equal strings mean the clear's result still
--- describes the network there.
local function jxCheckSignature(cx, cz)
    local parts = {}
    for _, w in pairs(ADGraphManager:getWayPoints() or {}) do
        if w ~= nil and w.id ~= nil and (w.x - cx) ^ 2 + (w.z - cz) ^ 2 <= 60 * 60 then
            local outs = {}
            for _, id in ipairs(w.out or {}) do
                local t = ADGraphManager:getWayPointById(id)
                if t ~= nil then outs[#outs + 1] = string.format("%.2f,%.2f", t.x, t.z) end
            end
            table.sort(outs)
            parts[#parts + 1] = string.format("%.2f,%.2f,%.2f>%s", w.x, w.y or 0, w.z, table.concat(outs, ";"))
        end
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

--- Keep the result for the card, with what the network looked like when the check was made. Every
--- field is worked out before any is set, so an error part-way leaves the result as it was rather
--- than half marked: a result with a signature but nothing to compare it with would stop the card.
--- Marks a result with the network it describes. Shared by the clear's check and the build's (below).
local function jxKeepRecord(self, res)
    if res ~= nil and res.x ~= nil then
        local list = ADGraphManager:getWayPoints()
        local sig = jxCheckSignature(res.x, res.z)
        -- Held weakly: the list a later undo throws away must not be kept alive by the card.
        res.seen = setmetatable({ list = list }, { __mode = "v" })
        res.seenCount, res.shown, res.askedAt = #(list or {}), true, self:nowMs()
        res.sig = sig
    end
    return res
end

function ADFlyoverEditor:junctionCheckKeep(res)
    self.junctionLastCheck = jxKeepRecord(self, res)
end

function ADFlyoverEditor:junctionClearCheck(ck)
    local C = nil
    if ck ~= nil and ck.before ~= nil and ck.failed == nil then C = jxCheckSetup(ck) end
    if C == nil then
        -- Said, and shown, rather than left to the card's last result: that described another clear.
        local why = "nothing is left to say where the junction was"
        if ck ~= nil and ck.failed ~= nil then why = ck.failed end
        Logging.info("[FlyoverEditor]: junction - check after the clear could not run: %s.", why)
        self:junctionCheckFailed(ck)
        return nil
    end
    jxCheckLanes(C)
    jxCheckPassages(C)
    jxCheckKept(C)
    jxCheckTwin(C)
    jxCheckMiddle(C)
    jxCheckTouched(C)
    jxCheckTwinReport(C)
    local res = jxCheckReport(C)
    -- The offline harness looks at the workings through this; nothing in the game sets it.
    if ADFlyoverEditor.junctionCheckProbe ~= nil then ADFlyoverEditor.junctionCheckProbe(C, res) end
    self:junctionCheckKeep(res)
    return res
end

--- The card's line when the check could not run or stopped with an error (tryCall has logged it).
--- Called from the clear's own ending, so nothing in here may throw: an error escaping it would
--- leave the clear's last steps undone (the debug capture still open, the tool still armed). The
--- line is set first, plainly; keeping it the usual way - with the network's signature, so the card
--- can drop it after a later edit - is tried after, and if that fails the line simply stays.
function ADFlyoverEditor:junctionCheckFailed(ck)
    local res = { card = { "Check: could not run - see the log" } }
    self.junctionLastCheck = res
    tryCall("junction clear check (could not run)", function()
        if ck ~= nil and ck.jp ~= nil then res.number = ck.jp.junctionNumber end
        if ck ~= nil then res.name = ck.name end
        if ck ~= nil and ck.site ~= nil then res.x, res.z = ck.site.x, ck.site.z end
        self:junctionCheckKeep(res)
    end)
    self.junctionLastCheck = res
end

--- The last check, while it still describes the network. Asked again whenever the network is
--- swapped whole (an undo or a redo does that) or its number of points changes, and otherwise
--- every half second: a link made or a point moved inside the cleared junction changes neither the
--- list nor the count, and the card went on describing a junction that was no longer there. If the
--- 60 m round the junction is no longer what the clear left, the card stops showing it - and shows
--- it again once it is, after an undo of a later edit, or a redo of the clear. Tied to the network
--- itself, not to an undo step: an undo step is a new table after a redo, falls off the 25-step stack
--- after 25 more edits, and a clear with nothing to cut takes none. The card draws this every frame,
--- so an error comparing hides the line rather than taking the card down.
--- WHEN IT GOES FOR ANY OTHER REASON THAN AN UNDO OR A REDO, THE LOG SAYS SO, once. After clearing
--- 39se the user did not find the line on the card, and nothing could tell afterwards whether it
--- had been hidden, or why: a hide left no trace, and one caused by the comparison failing was
--- silent too. An undo or a redo swaps the whole list, and hiding then is what the line is for, so
--- that stays quiet; a change in place (an edit within 60 m) or a failed comparison is said.
--- Shared by the clear's check and the build's (`what`: "clear" or "build", for the log line).
local function jxRecordShown(self, r, what)
    if r == nil or r.sig == nil or r.seen == nil then return r end
    local list = ADGraphManager:getWayPoints()
    local n = #(list or {})
    local now = self:nowMs()
    if r.seen.list ~= list or r.seenCount ~= n or now - (r.askedAt or 0) >= 500 or now < (r.askedAt or 0) then
        local swapped = (r.seen.list ~= list)
        local wasShown = r.shown
        r.seen.list, r.seenCount, r.askedAt = list, n, now
        local ok, sig = pcall(jxCheckSignature, r.x, r.z)
        r.shown = ok and sig == r.sig
        if wasShown and not r.shown and (not swapped or not ok) then
            local who = r.name
            if who == nil and r.number ~= nil then who = string.format("j%02d", r.number) end
            who = who or ("the last " .. what)
            if ok then
                Logging.info("[FlyoverEditor]: junction - the card stops showing the check on %s: the network within 60 m of it is no longer what the %s left (an edit there since).", who, what)
            else
                Logging.info("[FlyoverEditor]: junction - the card stops showing the check on %s: comparing it with the network failed: %s", who, tostring(sig))
            end
        end
    end
    if r.shown then return r end
    return nil
end

function ADFlyoverEditor:junctionLastCheckShown()
    return jxRecordShown(self, self.junctionLastCheck, "clear")
end

--- WHAT THE ROUTE CHECK SAID ABOUT THE LAST BUILD, for the build card: the same record as the clear's
--- check, kept and hidden the same way (gone after an undo of the build, back after a redo).
--- Decided 2026-10-02: a build with an extra route still builds, and the card marks it (doc 06, Still
--- open 3), until the left-turn work can reshape the turns that cause them.
function ADFlyoverEditor:junctionBuildCheckKeep(res)
    self.junctionLastBuild = jxKeepRecord(self, res)
end

function ADFlyoverEditor:junctionLastBuildShown()
    return jxRecordShown(self, self.junctionLastBuild, "build")
end

--- WHERE THE ROADS MET BEFORE THE CLEAR, when the one number stands for more than one such place - a
--- junction the user wants split (20, 26, 39, 40). What a clear of one part leaves near another is
--- that part's own wiring, which this clear leaves alone; read now, before anything changes, since
--- the part being cleared stops being a meeting point once it is. `at` is where the selection locked
--- the site, which is the meeting point this site is (the same rule as junctionPartsNote). Nil
--- when the number stands for one place, or none.
function ADFlyoverEditor:junctionCheckMeetings(jp, at)
    local n = nil
    if jp ~= nil then n = jp.junctionNumber end
    if n == nil or at == nil then return nil end
    local mine = self:junctionMeetingPointsOf(n)
    if #mine < 2 then return nil end
    local pts = {}
    for _, m in ipairs(mine) do pts[#pts + 1] = { x = m.x, z = m.z } end
    jxPartLetters(pts)
    -- ONCE THE USER HAS SPLIT IT, THE SAVED NAMES, NOT FRESH LETTERS. Lettered afresh, the places
    -- left after one part was cleared are lettered by the two-part rule (39nw would be said as
    -- 39w). So each place takes the name of the saved part within JX_PART_AT of it - where a
    -- lock on that part would land - and one with no saved part that close is said by distance and
    -- direction instead. Which places count as another part (`here`, below) is not changed by this.
    local f = self:junctionEntryOf(n)
    local saved = nil
    if f ~= nil and f.decision == "split" then saved = f.parts end
    local here, hd = nil, 10 * 10
    for _, p in ipairs(pts) do
        if saved ~= nil then
            local best, bd = nil, JX_PART_AT * JX_PART_AT
            for _, s in ipairs(saved) do
                local d = (s.x - p.x) ^ 2 + (s.z - p.z) ^ 2
                if d <= bd then bd, best = d, s end
            end
            p.name = nil
            if best ~= nil then p.name = string.format("j%02d%s", n, best.letter) end
        elseif p.letter ~= nil then
            p.name = string.format("j%02d%s", n, p.letter)
        end
        local d = (p.x - at.x) ^ 2 + (p.z - at.z) ^ 2
        if d < hd then hd, here = d, p end
    end
    if here == nil then return nil end
    return { pts = pts, here = here }
end

--- ANOTHER PART'S TURNS IN THIS PART'S AREA. Where the user has split a junction into parts on one
--- main road, a turn of the other part can leave (or join) the main road inside the area of the part
--- being cleared: at 39, 39se's right turn leaves the main road 6.5 m from 39's middle; at 20, 20s's
--- left turn leaves the road between the two parts 6.3 m from 20n's. The user's rules (2026-10-03,
--- doc 04, "Split junctions: clearing one part"): such a turn is LEFT WORKING - the clear stops short
--- of where it leaves or joins the main road, so it can still be driven, and this part's stub on that
--- side is longer than usual (junctionTidyByPaths); and the check calls it fine only if it still
--- drives end to end (jxCheckTwin). Three earlier rounds cut the road just before such a turn, which
--- left it hanging off a lane nothing could reach, and relabelled the check's findings; neither is
--- done here.
---
--- What is the other part's is what the selection already leaves to it (foreignWiring): wiring
--- joining a side road that ends at another crossing. Its owner is that crossing, and the turn is a
--- twin's only where that crossing is one of this junction's saved parts (within JX_PART_NEAR) - a
--- neighbouring junction's wiring is not a twin. And a turn from this part's through road onto a
--- road that is none of this part's lanes, which this clear does not take either: a run of plain
--- points (one way in, one way out) from a fork on a through lane to a fork on another road, none of
--- them on this part's lanes or in what it clears. At 40e, 40w's right turn onto its north road
--- leaves the main road 8 m from 40w and 13 m from 40e; 40e's lanes do not include 40w's north road,
--- so the selection never flooded that turn as anyone's, and with through roads off 40e's cut left
--- it starting at the cut. Its owner is the saved part nearest the fork it reaches, when that fork
--- lies nearer that part than this one, within 20 m. Never anything this clear takes as its own:
--- so a turn of this part's that it misses is never one of these. Only pieces with a point, or a
--- point they leave or join the road at, inside this clear's bound: the rest lies outside anything
--- the clear touches.
---
--- Returns nil where the lock is not on a part of a split the user saved (or
--- AutoDrive.FLYOVER_JUNCTION_TWIN_TURNS = false, for the harness), else { moves, attach, spans }:
--- each move one way through a piece - from the road point it leaves (its first point) to the road
--- point it joins (its last) - with its points (pts, positions; nodes, the points themselves), the
--- part's name and place; attach, the road points the moves leave and join, by object, each to the
--- place of the part whose turn it is; spans, the
--- stretches of road the tidy keeps for them (filled by junctionTidyByPaths). Sets jxTwinKeep to
--- every point of every move, so nothing in this clear removes them.
function ADFlyoverEditor:junctionTwinTurns(jp)
    if AutoDrive.FLYOVER_JUNCTION_TWIN_TURNS == false then return nil end
    if jp == nil or jp.junctionPart == nil or jp.junctionNumber == nil then return nil end
    local f = self:junctionEntryOf(jp.junctionNumber)
    if f == nil or f.decision ~= "split" or f.parts == nil then return nil end
    local foreign, owner = jp.foreignWiring or {}, jp.foreignOwner or {}
    local function live(w) return w ~= nil and w.id ~= nil and ADGraphManager:getWayPointById(w.id) == w end
    local function partAt(c)
        if c == nil then return nil end
        local best, bd = nil, JX_PART_NEAR * JX_PART_NEAR
        for _, p in ipairs(f.parts) do
            local d = (p.x - c.x) ^ 2 + (p.z - c.z) ^ 2
            if d <= bd then bd, best = d, p end
        end
        if best == jp.junctionPart then return nil end
        return best
    end
    local list = {}
    for w in pairs(foreign) do
        if live(w) then list[#list + 1] = w end
    end
    table.sort(list, jxBeforeInPlace)
    -- This part's own: its lanes (through roads, side roads, the runs its lanes were followed along)
    -- and everything it clears.
    local mine, onThrough = {}, {}
    for _, nodes in ipairs((jp.pathRoutes and jp.pathRoutes.through) or {}) do
        for _, n in ipairs(nodes) do mine[n], onThrough[n] = true, true end
    end
    for _, sl in ipairs((jp.pathRoutes and jp.pathRoutes.side) or {}) do
        for _, n in ipairs(sl.nodes or {}) do mine[n] = true end
    end
    for n in pairs(jp.runNodes or {}) do
        if type(n) == "table" then mine[n] = true end
    end
    local takes = {}
    for _, key in ipairs({ "debris", "turnDebris", "throughDebris" }) do
        for _, n in ipairs(jp[key] or {}) do mine[n], takes[n] = true, true end
    end
    local function nbOf(w)
        local nb, n = {}, 0
        for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
            for _, id in ipairs(lst) do
                local o = ADGraphManager:getWayPointById(id)
                if o ~= nil and o ~= w and not nb[o] then nb[o] = true n = n + 1 end
            end
        end
        return nb, n
    end
    -- the runs of plain points leaving a through lane of this part's at a fork
    local chainOwner = {}
    local here = jp.junctionPart
    for n in jxByPlace(onThrough) do
        if live(n) and jxMayDelete(n.x, n.z) then
            local nb, k = nbOf(n)
            if k >= 3 then
                for o in jxByPlace(nb) do
                    local _, ko = nbOf(o)
                    if not mine[o] and not foreign[o] and not chainOwner[o] and ko == 2 then
                        -- walk the plain run to its far fork
                        local run, prev, cur, far = { o }, n, o, nil
                        for _ = 1, 60 do
                            local nb2 = nbOf(cur)
                            local nxt = nil
                            for q in pairs(nb2) do if q ~= prev then nxt = q end end
                            -- back onto this part's through road, into what it clears, or into the
                            -- selection's own say: not such a run
                            if nxt == nil or onThrough[nxt] or takes[nxt] or foreign[nxt] then break end
                            -- the far end: a fork, or a lane this part's lanes were followed along
                            -- (at 20n, 20s's east road is one of 20n's arms)
                            local _, kn = nbOf(nxt)
                            if kn ~= 2 or mine[nxt] then far = nxt break end
                            run[#run + 1] = nxt
                            prev, cur = cur, nxt
                        end
                        if far ~= nil then
                            local best, bd = nil, 20 * 20
                            for _, p in ipairs(f.parts) do
                                local d = (p.x - far.x) ^ 2 + (p.z - far.z) ^ 2
                                if d < bd then bd, best = d, p end
                            end
                            local dHere = math.huge
                            if here ~= nil then dHere = (here.x - far.x) ^ 2 + (here.z - far.z) ^ 2 end
                            if best ~= nil and best ~= here and bd < dHere then
                                for _, r in ipairs(run) do
                                    chainOwner[r] = { x = best.x, z = best.z }
                                    list[#list + 1] = r
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(list, jxBeforeInPlace)
    -- What makes a point another part's: the selection's say (foreignWiring) or such a run.
    local theirs = {}
    for w in pairs(foreign) do theirs[w] = true end
    for w in pairs(chainOwner) do theirs[w] = true end
    local seen, moves, attach, keepSet = {}, {}, {}, {}
    for _, w0 in ipairs(list) do
        if not seen[w0] then
            -- the piece: foreign points joined to each other
            local piece, pts, stack = {}, {}, { w0 }
            seen[w0] = true
            while #stack > 0 do
                local c = table.remove(stack)
                piece[c] = true
                pts[#pts + 1] = c
                for _, lst in ipairs({ c.out or {}, c.incoming or {} }) do
                    for _, id in ipairs(lst) do
                        local o = ADGraphManager:getWayPointById(id)
                        if o ~= nil and theirs[o] and not seen[o] and live(o) then
                            seen[o] = true
                            stack[#stack + 1] = o
                        end
                    end
                end
            end
            table.sort(pts, jxBeforeInPlace)
            local part = partAt(owner[pts[1]] or chainOwner[pts[1]])
            -- where it leaves the road (a road point leading into it) and joins it (one it leads to)
            local entries, exits = {}, {}
            for _, c in ipairs(pts) do
                for _, id in ipairs(c.incoming or {}) do
                    local u = ADGraphManager:getWayPointById(id)
                    if u ~= nil and u ~= c and not piece[u] then entries[#entries + 1] = { u = u, v = c } end
                end
                for _, id in ipairs(c.out or {}) do
                    local t = ADGraphManager:getWayPointById(id)
                    if t ~= nil and t ~= c and not piece[t] then exits[#exits + 1] = { c = c, t = t } end
                end
            end
            local inside = false
            for _, c in ipairs(pts) do
                if jxMayDelete(c.x, c.z) then inside = true break end
            end
            for _, e in ipairs(entries) do
                if jxMayDelete(e.u.x, e.u.z) then inside = true end
            end
            for _, x in ipairs(exits) do
                if jxMayDelete(x.t.x, x.t.z) then inside = true end
            end
            if part ~= nil and inside and #entries > 0 and #exits > 0 then
                local name = string.format("j%02d%s", f.n, part.letter or "")
                for _, e in ipairs(entries) do
                    -- every way through the piece from this entry, the fewest points first
                    local par, q, h = { [e.v] = false }, { e.v }, 1
                    while h <= #q do
                        local c = q[h]
                        h = h + 1
                        local outs = {}
                        for _, id in ipairs(c.out or {}) do
                            local t = ADGraphManager:getWayPointById(id)
                            if t ~= nil and piece[t] and par[t] == nil then outs[#outs + 1] = t end
                        end
                        table.sort(outs, jxBeforeInPlace)
                        for _, t in ipairs(outs) do
                            par[t] = c
                            q[#q + 1] = t
                        end
                    end
                    for _, x in ipairs(exits) do
                        if par[x.c] ~= nil then
                            local nodes, c = { x.t }, x.c
                            while c do
                                table.insert(nodes, 1, c)
                                c = par[c]
                            end
                            table.insert(nodes, 1, e.u)
                            local mpts = {}
                            for _, n in ipairs(nodes) do mpts[#mpts + 1] = { x = n.x, z = n.z } end
                            moves[#moves + 1] = { nodes = nodes, pts = mpts, name = name, part = { x = part.x, z = part.z } }
                            local at = { x = part.x, z = part.z }
                            attach[e.u], attach[x.t] = attach[e.u] or at, attach[x.t] or at
                            for _, n in ipairs(nodes) do keepSet[n] = true end
                        end
                    end
                end
            end
        end
    end
    if #moves == 0 then return nil end
    table.sort(moves, function(a, b)
        local p, q = a.pts[1], b.pts[1]
        if p.x ~= q.x then return p.x < q.x end
        if p.z ~= q.z then return p.z < q.z end
        p, q = a.pts[#a.pts], b.pts[#b.pts]
        if p.x ~= q.x then return p.x < q.x end
        return p.z < q.z
    end)
    jxState.jxTwinKeep = keepSet
    for _, m in ipairs(moves) do
        local a, b = m.pts[1], m.pts[#m.pts]
        Logging.info("[FlyoverEditor]: junction - %s's turn from %.1f, %.1f to %.1f, %.1f runs in this part's area: left working, with the road it leaves and joins.",
            m.name, a.x, a.z, b.x, b.z)
    end
    return { moves = moves, attach = attach, spans = {} }
end

--- The parts of the split the lock is on, for the check: { here = {x, z, name}, others = { ... } }, or
--- nil where the lock is not on a part of a split the user saved.
function ADFlyoverEditor:junctionSplitPartsOf(jp)
    if jp == nil or jp.junctionPart == nil or jp.junctionNumber == nil then return nil end
    local f = self:junctionEntryOf(jp.junctionNumber)
    if f == nil or f.decision ~= "split" or f.parts == nil then return nil end
    local out = { here = nil, others = {} }
    for _, q in ipairs(f.parts) do
        local r = { x = q.x, z = q.z, name = string.format("j%02d%s", f.n, q.letter or "") }
        if q == jp.junctionPart then out.here = r else out.others[#out.others + 1] = r end
    end
    if out.here == nil then return nil end
    return out
end

function ADFlyoverEditor:applyJunctionClear()
    local jp = self.junctionPreview
    if jp == nil then return end
    -- The lane ends before, to tell the ones this clear cuts (self.junctionClearedEnds, below).
    local endsAt = jp.tracksCentre or self.junctionSite
    local endsBefore = nil
    if endsAt ~= nil then endsBefore = jxLaneEndsNear(endsAt.x, endsAt.z) end
    -- The card's line on the last clear goes now: whatever this clear's check says or fails to say,
    -- the last one described another clear.
    self.junctionLastCheck = nil
    -- Where the selection locked the site, for the check at the end only (which of a split
    -- junction's parts this is); the line below moves the site onto the crossing.
    local lockedAt = nil
    if self.junctionSite ~= nil then lockedAt = { x = self.junctionSite.x, z = self.junctionSite.z } end
    -- The bounds are measured from the crossing too, where there is one, so that "this junction"
    -- means the same place to the deletions as it does on screen.
    if self.junctionSite ~= nil and jp.boxCentre ~= nil then
        self.junctionSite.x, self.junctionSite.z = jp.boxCentre.x, jp.boxCentre.z
    end
    -- From here until jxEnd, nothing is deleted outside the junction that was selected. See jxRemove.
    jxBegin(self.junctionSite)
    jxState.jxKeptRoad = jxKeptRoadsOf(jp, self.junctionLeaveThrough ~= false)
    -- THE NETWORK BEFORE, AND THE RECORD OF WHAT THIS CLEAR DOES TO IT, for the check at the end.
    -- Taken here, before the cleaning, because the cleaning changes the network too. Reading only:
    -- nothing below decides anything from either. Read under tryCall, like every other step of the
    -- check: the check only reports, so an error in it must never stop the clear. If the network
    -- cannot be read, the clear carries on and the check says it could not run.
    -- The name the card showed for this lock ("j39se"), worked out from lockedAt when the preview
    -- was made. Kept here, because reading the site again after the cleaning makes a new preview.
    local chk = { site = self.junctionSite, leave = (self.junctionLeaveThrough ~= false), forkSpots = {},
                  name = jp.junctionName }
    if not tryCall("junction clear check (the network before)", function()
        chk.before = jxSnapshot()
        for _, f in ipairs((self.junctionSite ~= nil and self.junctionSite.forks) or {}) do
            chk.forkSpots[#chk.forkSpots + 1] = { x = f.x, z = f.z }
        end
    end) then
        chk.before, chk.failed = nil, "the network before the clear could not be read"
    end
    tryCall("junction check parts", function() chk.meetings = self:junctionCheckMeetings(jp, lockedAt) end)
    jxState.jxJournal, jxState.jxStage = {}, "cleaning the site"

    -- The network as it stands, before a single point moves, when capture is on. Nil otherwise, and
    -- every debugCapture call below is a no-op on nil.
    local cap = self:debugCaptureBegin("clear", self.junctionSite, {
        string.format("leave through paths  %s", (self.junctionLeaveThrough ~= false) and "on" or "off"),
        string.format("turn radius          %s m", tostring(self.junctionTurnRadius or 12)),
    }, jp.junctionName)

    -- UNDO GOES BACK TO HERE, before the cleaning: the cleaning changes the network as surely as the
    -- clear does, and undo used to bring back the cleaned site rather than the one the user had. Not
    -- put on the undo stack until something has actually changed, because the cleaning may find
    -- nothing to do and the site then nothing to clear - and a clear that changed nothing must leave
    -- no undo step behind. One step per clear, whichever change comes first.
    local undo = ADEditorHistory:capture("clear junction")
    local function keepUndo()
        if undo ~= nil then
            ADEditorHistory:commit(undo)
            undo = nil
        end
    end

    -- STEP 2: CLEAN THE SITE BEFORE ANYTHING MEASURES IT. This used to run last of all, which meant
    -- the box, the road widths and the answer to which lanes are parent road were all worked out on
    -- a site that still had points sitting on top of each other and chains leading nowhere in it -
    -- and those get counted as tracks of a road. The same road measured 2.50 m one way and 4.23 m
    -- the other at one site, purely from what the measurement happened to catch.
    --
    -- It cannot run in the preview: the preview is pure inspection and runs on every frame, and this
    -- changes waypoints. So the site is cleaned here, once, and the preview is then rebuilt on the
    -- cleaned graph before the rest of the clear reads it.
    do
        local site = self.junctionSite
        local c0 = site or jp._boxCentre or jp.tracksCentre
        if c0 ~= nil and AutoDrive.FLYOVER_JUNCTION_CLEAN_FIRST ~= false then
            local notes, touched = {}, 0
            local tot = { doubles = 0, repaired = 0, removed = 0, reversals = 0, unjoined = 0 }
            -- Repeated until the site settles: taking a chain out can leave the next point along
            -- with nothing leading into it, so one pass is never enough. Three is, and anything that
            -- will not settle by then is left alone rather than chased.
            for _ = 1, 3 do
                jxState.jxStage = "cleaning the site"
                local ok, r = pcall(function()
                    return self:networkIntegritySweep(c0.x, c0.z, 45, false)
                end)
                if not ok or r == nil then break end
                tot.doubles = tot.doubles + r.doubles
                tot.repaired = tot.repaired + r.repaired
                tot.removed = tot.removed + r.removed
                tot.reversals, tot.unjoined = r.reversals, r.unjoined or 0
                for _, n in ipairs(r.notes or {}) do notes[#notes + 1] = n end
                local did = r.doubles + r.repaired + r.removed
                touched = touched + did
                if did == 0 then break end
            end
            if tot.repaired + tot.removed + tot.doubles > 0 then
                Logging.info("[FlyoverEditor]: junction - cleaned the site first: %d chain(s) tied back to the road, %d removed with nothing to tie them to, %d doubled point(s) folded together.",
                    tot.repaired, tot.removed, tot.doubles)
            end
            if (tot.unjoined or 0) > 0 then
                Logging.warning("[FlyoverEditor]: junction - %d lane end(s) with nothing leading into them and nothing close enough to tie them back to. Left in place, not removed: a one-way dead-end lane looks the same from here.",
                    tot.unjoined)
            end
            if tot.reversals > 0 then
                Logging.warning("[FlyoverEditor]: junction - %d point(s) where the road doubles back on itself. Left alone: reported, not guessed at.",
                    tot.reversals)
            end
            for _, n in ipairs(notes) do
                Logging.info("[FlyoverEditor]: junction - %s.", n)
            end
            -- STEP 3, FIRST HALF: SMOOTH THE PARENT LANES BEFORE THE BOX IS MEASURED. Years of
            -- tie-ins and re-laid ends leave an approach with 0.9 m hops next to 12 m ones, and a
            -- box measured against that is measured against the spacing rather than the road. The
            -- spec put the box first and the smoothing after; measuring unsmoothed lanes is exactly
            -- what has been moving the box, so it is done the other way round.
            local rsM, rsR, rsC = 0, 0, 0
            jxState.jxStage = "smoothing the lanes first"
            tryCall("junction smooth parent lanes", function()
                rsM, rsR, rsC = self:junctionRespaceApproaches(jp)
            end)
            if (rsM or 0) + (rsR or 0) + (rsC or 0) > 0 then
                touched = touched + 1
                Logging.info("[FlyoverEditor]: junction - smoothed the parent lanes before measuring: %d point(s) moved, %d removed, %d added.",
                    rsM or 0, rsR or 0, rsC or 0)
            end

            -- Whatever was measured before the cleaning was measured on the wrong site.
            if touched > 0 then
                -- ONCE A SITE IS ACCEPTED, THE CLEAR SEES IT THROUGH. Rebuilding the preview runs
                -- the selection again, and the cleaning it has just done can change the answer -
                -- folding one doubled point drops a fork, the site no longer counts as a junction,
                -- and the clear walked away having cleaned the site and cleared nothing: twenty
                -- links still running across the box, no line in the log, and the deletion bound
                -- left switched on behind it. The rebuild is there to measure the cleaned site, not
                -- to reconsider whether to work on it, so a refusal here keeps what we already had.
                local keep = jp
                self.junctionPreviewKey = nil
                jxState.jxStage = "reading the site again"
                tryCall("junction preview after cleaning", function() self:updateJunctionPreview() end)
                jp = self.junctionPreview
                if jp == nil then
                    jp = keep
                    self.junctionPreview = keep
                    Logging.info("[FlyoverEditor]: junction - cleaning the site changed it enough that it no longer reads as a junction; carrying on with the site as first found.")
                end
            end
            -- NO BOX IS A RESULT, AND IT HAS TO BE SAID. The box is the overlap of two roads' claim
            -- bands, and it needs two roads that actually cross: where the roads here run nearly
            -- parallel, or meet at a shallow merge, no pair qualifies and no box is built. The clear
            -- then trims what it can and leaves whatever lies between the roads standing - which
            -- looks exactly like a clear that half worked, with nothing anywhere saying why.
            if jp._box == nil then
                Logging.warning("[FlyoverEditor]: junction - NO BOX could be built here: no two of its roads cross at an angle the box can be made from (they run nearly parallel, or meet at a shallow merge). What lies between them is left alone; the lanes are still tidied.")
            end
            local kind = jp.junctionType or "?"
            if kind == "?" then
                tryCall("junction classify", function() kind = self:junctionClassify(jp) end)
            end
            jp.junctionType = kind
            if self.junctionSite ~= nil then self.junctionSite.kind = kind end
            Logging.info("[FlyoverEditor]: junction - this is a %s, %s. Nothing branches on that yet; it is recorded so rules for each kind have somewhere to attach.",
                kind, tostring(jp.junctionSituation or "situation unknown"))
        end
    end
    -- The cleaning changed the site: that is a step to undo already, even if nothing is left to clear.
    -- Read off the clear's own record of its edits, which every change the cleaning makes goes into.
    if jxState.jxJournal ~= nil and #jxState.jxJournal > 0 then keepUndo() end
    -- The preview the rest of the clear works from, and its through roads as they lie now, before
    -- any of them is cut, smoothed or respaced - what the check holds the kept roads up against.
    -- Under tryCall for the same reason as the network before: without these lines the check would
    -- take every kept road for a join, so it says it could not run instead, and the clear goes on.
    chk.jp = jp
    jxState.jxKeptRoad = jxKeptRoadsOf(jp, self.junctionLeaveThrough ~= false)
    -- ANOTHER PART'S TURNS IN THIS PART'S AREA, read now, before anything is cut: they are left
    -- working (junctionTwinTurns). Nil unless the lock is on a part of a split the user saved.
    jp._twin = nil
    tryCall("junction twin turns", function() jp._twin = self:junctionTwinTurns(jp) end)
    chk.twin = jp._twin
    tryCall("junction check parts (split)", function() chk.parts = self:junctionSplitPartsOf(jp) end)
    if not tryCall("junction clear check (the through roads)", function() chk.routeLines = jxRouteLines(jp) end) then
        chk.routeLines, chk.failed = nil, chk.failed or "the through roads could not be read"
    end
    local leave = self.junctionLeaveThrough ~= false
    -- Through paths KEPT: only the turn wiring goes. Through paths CLEARED: the through route's
    -- own WIRING goes with it and its links are cut, but its ROAD stays.
    --
    -- Keeping every through node and merely cutting the links was too literal a reading of "sever
    -- continuity, keep the road" - it left the whole route sitting in the junction as disconnected
    -- points, which is not a cleared junction. Keeping the road means keeping the RUN: the part the
    -- lane chains walked from the anchor to the last fork. The wiring in between is not road and
    -- has no business surviving a clear that was asked to take the through path out.
    local nodes = jp.turnDebris
    if not leave then
        local keep = jp.runNodes or {}
        local both = {}
        for _, w in ipairs(jp.turnDebris or {}) do both[#both + 1] = w end
        for _, w in ipairs(jp.throughDebris or {}) do
            if not keep[w] then both[#both + 1] = w end
        end
        nodes = both
    end
    local links = jp.staleLinks or {}
    local nodeCount = nodes ~= nil and #nodes or 0
    local throughSkippedLinks = 0
    local linksToSever = {}
    for _, pair in ipairs(links) do
        if leave and pair.isThrough then
            throughSkippedLinks = throughSkippedLinks + 1
        else
            linksToSever[#linksToSever + 1] = pair
        end
    end
    local throughCut = 0
    if not leave then
        for _, pair in ipairs(jp.throughLinks or {}) do
            local a, b = pair[1], pair[2]
            if a ~= nil and b ~= nil and a.id ~= nil and b.id ~= nil
                and a.id >= 0 and b.id >= 0 then
                linksToSever[#linksToSever + 1] = { a, b }
                throughCut = throughCut + 1
            end
        end
    end
    if nodeCount == 0 and #linksToSever == 0 then
        Logging.info("[FlyoverEditor]: junction - nothing here for this site to clear.")
        jxState.jxTwinKeep = nil
        -- The cleaning above may still have changed the site, so its work is checked all the same.
        chk.journal = jxState.jxJournal
        jxState.jxJournal, jxState.jxStage, jxState.jxKeptRoad = nil, nil, nil
        if not tryCall("junction clear check", function() self:junctionClearCheck(chk) end) then
            self:junctionCheckFailed(chk)
        end
        return
    end

    keepUndo()
    jxState.jxStage = "cutting old links"
    local staleCut = 0
    for _, pair in ipairs(linksToSever) do
        local a, b = pair[1], pair[2]
        if a ~= nil and b ~= nil and a.id ~= nil and b.id ~= nil and a.id >= 0 and b.id >= 0 then
            junctionDisconnect(a, b)
            staleCut = staleCut + 1
        end
    end

    -- PARENT ROAD IS NEVER DELETED, whatever the toggle says.
    --
    -- "Leave through paths" governs whether the route ACROSS this junction survives. It was doing
    -- far more than that: with it off the clear deleted every node on those routes, and where two
    -- junctions sit close together the route between them IS the road joining them - so clearing one
    -- took out the road to its neighbour. The run set is the tool's own answer to which nodes are
    -- parent road, and it is held by OBJECT because ids renumber on every removal.
    local roadKept = 0
    local keep = jp.runNodes or {}
    local doomed = {}
    -- The through paths stay WHOLE through this stage: the tidy smooths each one right across the
    -- junction and then cuts it at the box, and it cannot smooth a path with its middle gone.
    local onPath = {}
    if jp._box ~= nil and jp.pathRoutes ~= nil then
        for _, nodes in ipairs(jp.pathRoutes.through or {}) do
            for _, n in ipairs(nodes) do onPath[n] = true end
        end
    end
    for _, w in ipairs(nodes or {}) do
        if w ~= nil and w.id ~= nil and w.id >= 0 then
            if keep[w] or onPath[w] then roadKept = roadKept + 1 else doomed[#doomed + 1] = w end
        end
    end
    if roadKept > 0 then
        Logging.info("[FlyoverEditor]: junction - kept %d point(s) of parent road that the clear would otherwise have taken.",
            roadKept)
    end

    -- Highest id first: removeWayPoint renumbers everything above the id it removes, so a pending
    -- lower id is still valid when its turn comes; a pending higher id would not be.
    jxState.jxStage = "removing turn wiring"
    -- A TURN GOES WHOLE OR NOT AT ALL. Each point used to be put to the bound on its own, and where
    -- the bound's arms are read off-line some ends of a turn fall outside it: at 36 two turns lost
    -- their middles but kept their ends 13-15 m out - one left as a 4 m dead end off its lane, the
    -- other as a tail fed by nothing and still joined into its lane, a teal dot. So the doomed turn
    -- points are gathered into connected pieces, linked to each other only. The lane points a turn
    -- hangs off are not turn points, so a piece stops where it meets the lanes, which is as far as
    -- the user's spec lets a delete run. A fork inside the turn wiring itself (one connector
    -- splitting into two turns) is a turn point, and the piece runs on through it. A piece with any
    -- point inside the bound, and every point outside it within JX_WHOLE_PIECE_REACH of one inside,
    -- is taken whole. Any other piece is put to the bound point by point, as before. Whether a piece
    -- is taken does not depend on order.
    local isTurn = {}
    for _, w in ipairs(jp.turnDebris or {}) do isTurn[w] = true end
    local turnDoomed = {}
    for _, w in ipairs(doomed) do
        if isTurn[w] then turnDoomed[w] = true end
    end
    local whole, seenPiece = {}, {}
    for _, w in ipairs(doomed) do
        if turnDoomed[w] and not seenPiece[w] then
            local piece, stack, inside, outside = {}, { w }, {}, {}
            seenPiece[w] = true
            while #stack > 0 do
                local c = table.remove(stack)
                piece[#piece + 1] = c
                if jxMayDelete(c.x, c.z) then inside[#inside + 1] = c else outside[#outside + 1] = c end
                for _, lst in ipairs({ c.out or {}, c.incoming or {} }) do
                    for _, id in ipairs(lst) do
                        local o = ADGraphManager:getWayPointById(id)
                        if o ~= nil and turnDoomed[o] and not seenPiece[o] then
                            seenPiece[o] = true
                            stack[#stack + 1] = o
                        end
                    end
                end
            end
            local takeWhole = #inside > 0
            for _, c in ipairs(outside) do
                local close = false
                for _, i0 in ipairs(inside) do
                    if (c.x - i0.x) ^ 2 + (c.z - i0.z) ^ 2 <= JX_WHOLE_PIECE_REACH ^ 2 then close = true break end
                end
                if not close then takeWhole = false end
            end
            if takeWhole then
                for _, c in ipairs(piece) do whole[c] = true end
            end
        end
    end
    local byId = {}
    for _, w in ipairs(doomed) do byId[#byId + 1] = w end
    table.sort(byId, function(a, b) return a.id > b.id end)
    local cleared = 0
    for _, w in ipairs(byId) do
        if jxRemove(w, "junction clear", whole[w] == true) then
            cleared = cleared + 1
        end
    end

    -- STEP 4: THE CONNECTORS GO BEFORE THE TIDY, not after it. A tidy trims a lane end back to the
    -- box; it has no business running with connector remnants still hanging off the lanes it is
    -- measuring. The cost of the move is that the tidy's own lane walks are not available yet, so
    -- the stub sweep falls back to its cruder walk - which is why this was the other way round.
    local stubs = 0
    jxState.jxStage = "removing connector stubs"
    tryCall("junction clear stubs", function() stubs = self:junctionClearStubs(jp) end)
    if stubs > 0 then
        Logging.info("[FlyoverEditor]: junction - removed %d point(s) of connector left hanging off the lanes.",
            stubs)
    end

    -- Tidy AFTER the removals: the ends being measured are the ones the clear just created.
    local tidyTrim, tidyAdd, tidyLanes, boxSwept, boxSevered = 0, 0, 0, 0, 0
    jxState.jxStage = "tidying lane ends"
    tryCall("junction tidy lane ends", function()
        local nEnds, nMade, nRemoved, nCut = self:junctionTidyByPaths(jp)
        if nEnds ~= nil then
            tidyLanes, tidyAdd, tidyTrim, boxSwept, boxSevered = nEnds, nMade, 0, nRemoved, nCut
        else
            tidyTrim, tidyAdd, tidyLanes, boxSwept, boxSevered = self:junctionTidyLaneEnds(jp)
        end
    end)
    -- WHERE EVERY LANE ENDS, AND WHETHER A ROAD'S TWO LANES AGREE.
    --
    -- Asked of the finished network rather than of whichever tidy ran, so it reports the same thing
    -- however the lane was handled - and reports a lane that no pass touched at all, which is the
    -- case that used to pass in silence.
    --
    -- The pair check is the one the eye makes first. At j33 one lane of a road ended 18.5 m from the
    -- middle and its partner 5.1 m: obvious on screen, invisible to every count the tool kept, and
    -- it took a capture and an hour to find. Two lanes of one road should stop together.
    do
        local c = jp._boxCentre or jp.tracksCentre
        if c ~= nil then
            local lanes = {}
            for _, ap in ipairs(jp.approaches or {}) do
                local b = math.deg(ap.bearing or 0) % 360
                local nearest = nil
                for _, w in pairs(ADGraphManager:getWayPoints()) do
                    if w ~= nil and w.id ~= nil then
                        local dx, dz = w.x - c.x, w.z - c.z
                        local d = math.sqrt(dx * dx + dz * dz)
                        if d <= 45 then
                            local wb = math.deg(math.atan2(dx, dz)) % 360
                            local sep = math.abs(wb - b) % 360
                            if sep > 180 then sep = 360 - sep end
                            if sep <= 12 and (nearest == nil or d < nearest) then nearest = d end
                        end
                    end
                end
                if nearest ~= nil then
                    lanes[#lanes + 1] = { b = b, d = nearest, dir = ap.dir }
                end
            end
            -- Pair the lanes of a road: same bearing within 20 degrees, opposite travel.
            local said = {}
            for i = 1, #lanes do
                for j = i + 1, #lanes do
                    if not said[i] and not said[j] then
                        local sep = math.abs(lanes[i].b - lanes[j].b) % 360
                        if sep > 180 then sep = 360 - sep end
                        if sep <= 20 then
                            local gap = math.abs(lanes[i].d - lanes[j].d)
                            said[i], said[j] = true, true
                            if gap > 3 then
                                Logging.warning("[FlyoverEditor]: junction - the two lanes of the road on bearing %.0f do not stop together: one ends %.1f m from the middle, the other %.1f m. A lane no pass could reach is left where it was.",
                                    lanes[i].b, lanes[i].d, lanes[j].d)
                            else
                                Logging.info("[FlyoverEditor]: junction - road on bearing %.0f: both lanes end %.1f and %.1f m from the middle.",
                                    lanes[i].b, lanes[i].d, lanes[j].d)
                            end
                        end
                    end
                end
            end
            for i = 1, #lanes do
                if not said[i] then
                    Logging.info("[FlyoverEditor]: junction - single lane on bearing %.0f ends %.1f m from the middle.",
                        lanes[i].b, lanes[i].d)
                end
            end
        end
    end

    if (boxSwept or 0) + (boxSevered or 0) > 0 then
        Logging.info("[FlyoverEditor]: junction - the box (the roads' own offset lines, centred %.1f, %.1f): removed %d point(s) inside it and cut %d link(s) running across it; lanes now end on its edge.",
            jp._boxCentre and jp._boxCentre.x or 0, jp._boxCentre and jp._boxCentre.z or 0,
            boxSwept or 0, boxSevered or 0)
    end


    -- Respace LAST: the ends are where they belong and the stubs are gone, so what is left is lane.
    local rsMoved, rsRemoved, rsCreated = 0, 0, 0
    jxState.jxStage = "respacing"
    tryCall("junction respace approaches", function()
        rsMoved, rsRemoved, rsCreated = self:junctionRespaceApproaches(jp)
    end)
    if (rsMoved or 0) + (rsRemoved or 0) + (rsCreated or 0) > 0 then
        Logging.info("[FlyoverEditor]: junction - respaced the approaches like the smooth tool's rebuild - up to %.0f m apart, closer through bends - over the last %.0f m: %d point(s) moved, %d removed, %d added. Ends, forks and marker points stay put.",
            AutoDrive.FLYOVER_JUNCTION_RESPACE_STEP or 5, AutoDrive.FLYOVER_JUNCTION_RESPACE_LEN or 50,
            rsMoved or 0, rsRemoved or 0, rsCreated or 0)
    end

    -- KEPT ROADS DO NOT SHARE THE POINT WHERE THEY CROSS. Where two kept through roads already ran
    -- through one shared point before the clear (64), a lane in on one could still drive out on the
    -- other. The user's default is that they pass through each other, so the second road gets its
    -- own point in the same place and its two links move onto it. Only a point where the two roads
    -- arrive from different points and leave to different points: two roads running together along
    -- a stretch share points on purpose.
    --
    -- A TWO-WAY ROAD STAYS TWO-WAY. The routes run one way each, so a two-way road is listed twice,
    -- once per direction, and moving its links off the shared point takes both directions at once.
    -- So each link goes back onto the copy the way it was before - two-way if it was two-way - and
    -- when the road's other direction comes round, its list is pointed at the same copy instead of
    -- being parted again. Without this the road would cross one way only. Found by reading the
    -- code; none of the 75 junctions has a two-way road through such a point.
    --
    -- The copy sits on the very spot of the shared point. Nothing in this clear folds the two back
    -- together (see jxKeptRoad), but jxKeptRoad lives only while this clear runs: a later clear
    -- whose bound reaches this point, with through roads off, would fold them back into one point,
    -- as it folds any two points under 0.3 m apart.
    if leave and jp.pathRoutes ~= nil then
        jxState.jxStage = "parting kept roads where they cross"
        tryCall("junction part crossing roads", function()
            local owner, partedAs = {}, {}
            for r, nodes in ipairs(jp.pathRoutes.through or {}) do
                for k = 1, #nodes do
                    local n = nodes[k]
                    local o = owner[n]
                    local p, q = nodes[k - 1], nodes[k + 1]
                    local done = nil
                    for _, pa in ipairs(partedAs[n] or {}) do
                        if p ~= nil and q ~= nil and pa.p == q and pa.q == p then done = pa end
                    end
                    if done ~= nil then
                        -- The other direction of a road already parted here: the same copy.
                        nodes[k] = done.wp
                    elseif o == nil then
                        owner[n] = { r = r, prev = p, nxt = q }
                    elseif o.r ~= r and k > 1 and k < #nodes and n.id ~= nil and jxInSite(n.x, n.z) then
                        if p ~= o.prev and p ~= o.nxt and q ~= o.prev and q ~= o.nxt
                            and p.id ~= nil and q.id ~= nil
                            and table.contains(p.out, n.id) and table.contains(n.out, q.id) then
                            local wp = ADFlyoverRecordWayPoint(n.x, n.y, n.z, false, false, false, 0,
                                n.flags or AutoDrive.FLAG_NONE, false, ADFlyoverEditor.fieldOf(n))
                            if wp ~= nil then
                                local pDual = table.contains(n.out, p.id) and table.contains(p.incoming, n.id)
                                local qDual = table.contains(q.out, n.id) and table.contains(n.incoming, q.id)
                                jxNoteAdded(wp)
                                junctionDisconnect(p, n)
                                junctionDisconnect(n, q)
                                junctionConnect(p, wp, pDual)
                                junctionConnect(wp, q, qDual)
                                nodes[k] = wp
                                if jxState.jxKeptRoad ~= nil then jxState.jxKeptRoad[wp] = r end
                                partedAs[n] = partedAs[n] or {}
                                table.insert(partedAs[n], { p = p, q = q, wp = wp })
                            end
                        end
                    end
                end
            end
        end)
    end

    -- A SECOND SWEEP, AND IT ONLY EVER COUNTS. The site was cleaned before anything measured it
    -- (step 2); anything broken by the time we get here was broken by the stages in between, and
    -- that number is worth knowing - moving the single sweep to the front took the map from 1 broken
    -- connector to 25, because this pass at the end had never been a cleanup step at all, only a
    -- bandage over the stages before it.
    --
    -- IT MUST NOT REPAIR. A clear's whole job is to cut the branches away from the road they joined,
    -- and a branch end left hanging afterwards is not damage - it is the work. Repairing it tied
    -- every branch straight back to its parent: two or three links running back across the box at
    -- every junction on the map, and a clear that visibly did nothing. So it reports and changes
    -- nothing, and the number belongs at zero.
    do
        local c0 = self.junctionSite or jp._boxCentre or jp.tracksCentre
        if c0 ~= nil and AutoDrive.FLYOVER_JUNCTION_FINAL_SWEEP ~= false then
            -- Repairing again here, and only here, because this is the one point at which the three
            -- kinds of loose end can be told apart: what was already loose when the clear began, what
            -- the clear cut on purpose, and what one of its own passes broke by accident. Only the
            -- last is put back.
            jxState.jxStage = "final sweep"
            local ok, r = pcall(function()
                return self:networkIntegritySweep(c0.x, c0.z, 45, false)
            end)
            if ok and r ~= nil then
                local n = r.repaired
                if n > 0 then
                    Logging.warning("[FlyoverEditor]: junction - %d link(s) that this clear broke by accident, put back. Not the branches it cut on purpose, and nothing that was already loose before it started. This count belongs at zero.",
                        n)
                end
                if r.reversals > 0 then
                    Logging.warning("[FlyoverEditor]: junction - %d point(s) where the road doubles back on itself.",
                        r.reversals)
                end
            end
        end
    end

    -- LAST OF ALL, ANYTHING LEFT JOINED TO NOTHING. Every stage before this can strand a point: the
    -- box sweep takes a connector's middle, the stub sweep takes its far end, the respace bridges
    -- over one and deletes it. Whatever is standing near the junction with no link left on it is
    -- not road by any reading, so it goes - but only if it is genuinely alone, so a real dead-end
    -- lane (which still has the link back up its own road) is untouched.
    do
        local c0 = jp._boxCentre or jp.tracksCentre
        local stranded = {}
        if c0 ~= nil then
            for _, w in pairs(ADGraphManager:getWayPoints()) do
                if w ~= nil and w.id ~= nil and (w.x - c0.x) ^ 2 + (w.z - c0.z) ^ 2 <= 45 * 45
                    and #(w.out or {}) == 0 and #(w.incoming or {}) == 0 then
                    stranded[#stranded + 1] = w.id
                end
            end
        end
        table.sort(stranded, function(a, b) return a > b end)
        jxState.jxStage = "removing stranded points"
        for _, id in ipairs(stranded) do
            jxRemove(id, "junction stranded point")
        end
        if #stranded > 0 then
            Logging.info("[FlyoverEditor]: junction - removed %d point(s) left joined to nothing.", #stranded)
        end
    end
    if tidyLanes > 0 then
        Logging.info("[FlyoverEditor]: junction - tidied %d lane end(s) onto the box edge: %d point(s) trimmed, %d added.",
            tidyLanes, tidyTrim, tidyAdd)
    end

    if throughCut > 0 then
        Logging.info("[FlyoverEditor]: junction - cut %d through-route link(s); the roads themselves are left in place.",
            throughCut)
    end
    local throughLeft = leave and (#(jp.throughDebris or {})) or 0
    if leave and (throughLeft > 0 or throughSkippedLinks > 0) then
        -- SAYS WHICH STAGE IT IS COUNTING. `cleared` is the turn wiring and nothing else - not the
        -- box sweep, not the respace - so on a junction that has been cleared once already it is
        -- legitimately 0 while the stage line beneath reports 18 taken. Phrased as though it were
        -- the total, those two lines flatly contradict each other, and the total is on the next line
        -- anyway.
        Logging.info("[FlyoverEditor]: junction - removed %d point(s) of old turn wiring and %d stale link(s); left %d through-path point(s) and %d through link(s) in place.",
            cleared, staleCut, throughLeft, throughSkippedLinks)
    else
        Logging.info("[FlyoverEditor]: junction - removed %d point(s) of old turn wiring and %d stale link(s). Roads it joined are untouched.",
            cleared, staleCut)
    end
    -- WHICH STAGE TOOK WHAT, AND FROM HOW FAR. One total hides the stage that is over-reaching: in
    -- game a clear reported 29 points taken, the farthest 39 m out, at a junction 12 m across - and
    -- nothing in the log said which of fourteen removers had gone that far.
    do
        local parts = {}
        for why, e in pairs(jxState.jxWhy) do
            parts[#parts + 1] = string.format("%s %d (to %.0f m)", why:gsub("^junction ", ""), e.n, e.far)
        end
        table.sort(parts)
        if #parts > 0 then
            Logging.info("[FlyoverEditor]: junction - taken by stage: %s.", table.concat(parts, "; "))
        end
    end
    local held, took, farOut = jxEnd()
    chk.journal = jxState.jxJournal
    jxState.jxJournal, jxState.jxStage, jxState.jxKeptRoad = nil, nil, nil
    Logging.info("[FlyoverEditor]: junction - took %d point(s) in all, the farthest %.0f m out; %d left alone as belonging to a neighbouring junction rather than this one.",
        took, farOut, held)
    if jxState.jxTwinHeld > 0 then
        Logging.info("[FlyoverEditor]: junction - %d point(s) a step of the clear would have taken were kept: another part's turn, or the road it leaves or joins (left working).",
            jxState.jxTwinHeld)
    end
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
    -- THE LANE ENDS THIS CLEAR CUT, for the build that follows: its circle grows to take them in
    -- (junctionReachEnds). Only these - the loose track ends that were lying near 1, 26 and 63 before
    -- any clear are not this junction's lanes, and a circle grown to them laid turns to nowhere.
    if endsBefore ~= nil then
        local cut = {}
        for k, e in pairs(jxLaneEndsNear(endsAt.x, endsAt.z)) do
            if endsBefore[k] == nil then cut[#cut + 1] = e end
        end
        table.sort(cut, function(a, b) if a.x ~= b.x then return a.x < b.x end return a.z < b.z end)
        self.junctionClearedEnds = { x = endsAt.x, z = endsAt.z, ends = cut,
            serial = ((self.junctionClearedEnds or {}).serial or 0) + 1 }
    end
    -- THE CLEAR CHECKS ITS OWN WORK. Report only: it undoes nothing and refuses nothing, and a
    -- failure inside it cannot stop the clear, which is already done. Before the capture closes, so
    -- a capture's tool.log carries the check too.
    if not tryCall("junction clear check", function() self:junctionClearCheck(chk) end) then
        self:junctionCheckFailed(chk)
    end
    -- After markChanges, so what is written is the network as the game now holds it.
    self:debugCaptureEnd(cap)
    self.junctionArmed, self.junctionPreview, self.junctionPreviewKey = nil, nil, nil
end

function ADFlyoverEditor:applyJunction()
    local jp = self.junctionPreview
    if jp == nil then return end
    if jp.placeMode then
        self:applyJunctionPlace()
        return
    end
    if jp.clearMode then
        self:applyJunctionClear()
        return
    end
    -- A build changes the network just as a clear does, so it is captured the same way: the point of
    -- the numbered folders is to follow a SEQUENCE, and a sequence with the builds missing from it
    -- cannot be replayed.
    local cap = self:debugCaptureBegin("build", self.junctionSite, {
        string.format("turn radius          %s m", tostring(self.junctionTurnRadius or 12)),
    }, jp.junctionName)

    local newMoves = {}
    for _, m in ipairs(jp.movements) do
        if (not m.exists or m.rebuild) and m.connector ~= nil and m.refused == nil then
            newMoves[#newMoves + 1] = m
        end
    end
    -- Refusing a turn is a valid, verbose outcome (see docs/junction-plan.md s5): better unbuilt than
    -- undrivable. Loosen the turn radius, or widen the scope so a gentler tie-in is found, to force it.
    -- Every count below comes straight from the preview that was just looked at (armed, so it already
    -- logged the per-pair detail) - not recomputed here, so this summary can never disagree with it.
    if (jp.nTight or 0) > 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - refused %d turn(s): tighter than the %.0f m turn radius even at the %.0f m floor.",
            jp.nTight, jp.turnRadius or 0, AutoDrive.FLYOVER_JUNCTION_TURN_MIN or 4)
    end
    if (jp.nOffRoad or 0) > 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - refused %d turn(s): no radius down to %.0f m keeps a %.1f m corridor on the road.",
            jp.nOffRoad, AutoDrive.FLYOVER_JUNCTION_TURN_MIN or 4,
            self.junctionCorridor or AutoDrive.FLYOVER_JUNCTION_CORRIDOR or 4)
    end
    if (jp.nNoCurve or 0) > 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - %d pair(s) had no joinable curve (see the id lines above) - not placed.",
            jp.nNoCurve)
    end
    if (jp.nUTurn or 0) > 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - %d pair(s) skipped as U-turns (bearings over 170 deg apart, see above).",
            jp.nUTurn)
    end
    if (jp.nFar or 0) > 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - %d pair(s) never came close to each other - likely two separate crossings caught by one scope; not placed.",
            jp.nFar)
    end
    if (jp.nLane or 0) > 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - %d redundant lane pairing(s) skipped (a closer match exists for the same turn, see above).",
            jp.nLane)
    end
    if (jp.nBlocked or 0) > 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - refused %d turn(s): a static obstacle sits in the corridor at every radius tried.",
            jp.nBlocked)
    end
    if #newMoves == 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - nothing new to connect here.")
        return
    end

    ADEditorHistory:snapshot("junction")
    jxBuildBegin()
    -- The WORK region, not the search circle: tie-ins and kickouts land wherever the geometry puts
    -- them on the tracks, which is routinely outside the circle that merely found those tracks.
    local cx, cz, radius = jp.cx, jp.cz, (jp.workRadius or jp.radius)
    self.junctionChainCache = nil
    local allStubs = {}
    local placed = 0

    -- Rebuild: sever the stale skeleton-to-skeleton links FIRST (old direct bridges with no interior
    -- node - the node sweep cannot touch those). Before laying, so a fresh replacement over the same
    -- pair cannot be cut by its own cleanup, and the tie-in chain walks see a clean graph.
    local staleCut = 0
    if jp.staleLinks ~= nil then
        for _, pair in ipairs(jp.staleLinks) do
            local a, b = pair[1], pair[2]
            if a ~= nil and b ~= nil and a.id ~= nil and b.id ~= nil and a.id >= 0 and b.id >= 0 then
                junctionDisconnect(a, b)
                staleCut = staleCut + 1
            end
        end
    end
    if staleCut > 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - severed %d stale direct link(s) between road nodes (rebuild).", staleCut)
    end
    -- A movement (e,x) and its MIRROR (e2,x2) with e2.wp.id==x.wp.id and x2.wp.id==e.wp.id can only
    -- both exist when BOTH boundary nodes carry traffic in and out of the scope - a genuine two-way
    -- point on each end (see the U-turn log's approach dump: a two-way node shows up as both an "in"
    -- AND an "out" approach under the same id). That is exactly the ONLY case where a connector should
    -- be dual - both directions were actually asked for. An earlier version instead asked each tie-in
    -- "is the LOCAL track here two-way", which is the wrong question (it can be true on both ends of a
    -- perfectly ordinary one-way turn, e.g. two different two-way roads meeting, with no request for
    -- the turn itself to run both ways) and coloured connectors dual for no real reason. Confirming
    -- the mirror ACTUALLY exists in this batch is the one signal that is never a false positive.
    local function pairKey(a, b)
        local lo, hi = math.min(a, b), math.max(a, b)
        return lo .. "_" .. hi
    end
    local mirrorOf = {}
    for _, m in ipairs(newMoves) do
        mirrorOf[pairKey(m.from.wp.id, m.to.wp.id)] = (mirrorOf[pairKey(m.from.wp.id, m.to.wp.id)] or 0) + 1
    end
    local dualPairPlaced = {}
    local dualPlaced, mirrorsSkipped, rebuiltPlaced = 0, 0, 0
    -- THE invariant (hard gate, not a heuristic): if no two-way track comes into this site
    -- (jp.siteHasTwoWay, established structurally while scoping), then NOTHING placed here may be
    -- two-way. The mirror-pair signal cannot fire without two-way boundary nodes anyway, but this
    -- gate makes the guarantee independent of that reasoning ever being wrong.
    -- No two-way TURNS since 2026-10-02 (doc 06, "Two-way roads"): on a two-way link AutoDrive stops
    -- checking for traffic, so each direction gets its own one-way turn, tied in at the two-way road's
    -- mouth (see junctionTrackConnector). FLYOVER_JUNCTION_DUAL_TURNS = true brings the old behaviour back.
    local allowDual = (jp.siteHasTwoWay == true) and AutoDrive.FLYOVER_JUNCTION_DUAL_TURNS == true
    local baseCount = ADGraphManager:getWayPointsCount()
    local placedSet = {}   -- movements laid by this build, for the route check
    -- Every lane walked once, before anything is laid, so each turn ties into its lane and never into
    -- a turn laid a moment before (see junctionTieLanesPrepare).
    self:junctionTieLanesPrepare(newMoves, cx, cz, radius)
    for _, m in ipairs(newMoves) do
        local key = pairKey(m.from.wp.id, m.to.wp.id)
        if m.tieOffLane ~= nil then
            Logging.warning("[FlyoverEditor]: junction - turn from id=%d to id=%d not laid: one of its ends lies %.0f m off the lane it joins (a curve that did not land on its lane).",
                m.from.wp.id, m.to.wp.id, m.tieOffLane)
        elseif dualPairPlaced[key] then
            mirrorsSkipped = mirrorsSkipped + 1
        else
        local c = m.connector
        local NA, _flagsA, stubsA = self:junctionTieIn(m.from, c.ax, c.az, cx, cz, radius)
        local NB, exitFlags, stubsB = self:junctionTieIn(m.to, c.bx, c.bz, cx, cz, radius)
        if NA ~= nil and NB ~= nil and NA.id ~= NB.id then
            local dual = allowDual and (mirrorOf[key] or 0) > 1
            -- Our own deterministic chain-layer - NOT createSplineConnection, whose links go through
            -- toggleConnectionBetween (a flip, not a set). Flags match the joined (exit) road and are
            -- set at creation.
            jxState.jxLaySeq = jxState.jxLaySeq + 1
            jxState.jxLayLabel = jxTurnLabel(c) .. "#" .. jxState.jxLaySeq
            local ok, laid = tryCall("junction lay chain", function()
                return junctionLayChain(NA, c.points, NB, dual, exitFlags, true)
            end)
            jxState.jxLayLabel = nil
            ok = ok and laid == true
            if ok and dual then
                dualPlaced = dualPlaced + 1
                dualPairPlaced[key] = true
            end
            if ok then
                placed = placed + 1
                placedSet[m] = true
                if m.rebuild then rebuiltPlaced = rebuiltPlaced + 1 end
            end
            for _, s in ipairs(stubsA) do allStubs[#allStubs + 1] = s end
            for _, s in ipairs(stubsB) do allStubs[#allStubs + 1] = s end
        end
        end
    end

    self.junctionTieLanes = nil
    -- A mirrored pair folded into one two-way connector was laid by that connector too.
    for _, m in ipairs(newMoves) do
        if dualPairPlaced[pairKey(m.from.wp.id, m.to.wp.id)] then placedSet[m] = true end
    end

    -- Tripwire for THE invariant, run BEFORE stub deletion renumbers ids: on a one-way site, no node
    -- this placement created may carry a two-way link. With deterministic primitives and the
    -- allowDual gate this cannot happen by construction - so if it EVER fires, a creation path has a
    -- real bug, and it says so loudly instead of quietly shipping a blue link. Where the intended
    -- direction is provable (both nodes new: createSplineConnection appends interior points in travel
    -- order, so lower id -> higher id IS the travel direction), it also repairs on the spot.
    -- Keyed to the SITE, not to allowDual: since two-way turns stopped (2026-10-02) allowDual is false on
    -- every site, and a tie-in spliced into a two-way road rightly keeps that road two-way. Keyed to
    -- allowDual, this "repaired" those road links into one-way ones.
    if jp.siteHasTwoWay ~= true then
        local total = ADGraphManager:getWayPointsCount()
        for id = baseCount + 1, total do
            local n = ADGraphManager:getWayPointById(id)
            if n ~= nil then
                for _, outId in pairs(n.out or {}) do
                    local o = ADGraphManager:getWayPointById(outId)
                    if o ~= nil and table.contains(o.out or {}, n.id) then
                        Logging.warning("[FlyoverEditor]: junction INVARIANT VIOLATION - two-way link %d<->%d created on a one-way site. Report this.",
                            n.id, o.id)
                        if outId > baseCount then
                            local keepFrom = math.min(n.id, o.id)
                            local keepTo = math.max(n.id, o.id)
                            local kf = ADGraphManager:getWayPointById(keepFrom)
                            local kt = ADGraphManager:getWayPointById(keepTo)
                            table.removeValue(kt.out, keepFrom)
                            table.removeValue(kf.incoming, keepTo)
                            Logging.warning("[FlyoverEditor]: junction - repaired to one-way %d -> %d (interior points run in travel order).",
                                keepFrom, keepTo)
                        end
                    end
                end
            end
        end
    end

    local stubSeen = {}
    for _, s in ipairs(allStubs) do
        if s ~= nil and not stubSeen[s] and s.id ~= nil and s.id >= 0
            and #(s.out or {}) + #(s.incoming or {}) <= 2 then
            stubSeen[s] = true
            jxRemove(s.id, "junction removeWayPoint")
        end
    end

    -- Rebuild's debris clearing, LAST of all and only once something actually placed: every old
    -- off-skeleton node wired to this junction goes, including duplicate connectors and connectors of
    -- pairs the matrix now refuses - the per-movement path deletion this replaces left those behind.
    -- No degree guard here: a degree-3 debris node is an old connector fork, not road (roads are
    -- skeleton and never in this list). Deleted by object reference, id re-read each time.
    local debrisCleared = 0
    -- Clear the old wiring when something was LAID, and ALSO when turns were deliberately REFUSED
    -- because the design vehicle cannot take them (too tight, off road, blocked, rig off road, rig
    -- hits something). A refusal is a decision that the turn should not exist - leaving the old
    -- connector standing keeps an undrivable turn on the network, which is worse than no turn at all:
    -- AutoDrive will happily route a rig into it. The `placed > 0` guard alone meant a junction whose
    -- every movement was refused kept ALL of its old wiring and the rebuild silently did nothing.
    -- Reasons that are NOT a drivability judgement (nFar = two separate crossings in one scope, nLane
    -- = a redundant lane pairing, nNoCurve = no joinable geometry) deliberately do not trigger this:
    -- they mean "not this junction's business", not "this turn is undrivable".
    local nRefusedForVehicle = (jp.nTight or 0) + (jp.nOffRoad or 0) + (jp.nBlocked or 0)
        + (jp.nTrailerRoad or 0) + (jp.nTrailerHit or 0)
    if placed == 0 and nRefusedForVehicle > 0 then
        Logging.info("[FlyoverEditor]: junction - nothing could be laid here, but %d turn(s) were refused as undrivable - clearing their old wiring rather than leaving it.",
            nRefusedForVehicle)
    end
    if (placed > 0 or nRefusedForVehicle > 0) and jp.debris ~= nil then
        for _, s in ipairs(jp.debris) do
            if s ~= nil and not stubSeen[s] and s.id ~= nil and s.id >= 0 then
                stubSeen[s] = true
                if jxRemove(s.id, "junction clear debris") then
                    debrisCleared = debrisCleared + 1
                end
            end
        end
    end
    if debrisCleared > 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - cleared %d old junction point(s) (rebuild).", debrisCleared)
    end

    if mirrorsSkipped > 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - %d mirrored one-way pair(s) folded into their dual connector (built once, not twice).",
            mirrorsSkipped)
    end
    ADFlyoverSettings.debugLog("[FlyoverEditor]: junction placed %d connector(s) (%d dual, %d rebuilt over old ones), consumed %d stub point(s).",
        placed, dualPlaced, rebuiltPlaced, #allStubs)
    -- Last of all, once the stubs and old debris are gone, so a crossing is never shared with a link
    -- that is about to be deleted.
    local shared = 0
    if AutoDrive.FLYOVER_JUNCTION_SHARE_CROSSINGS ~= false then
        tryCall("junction share crossings", function() shared = junctionShareCrossings(cx, cz, radius) end)
    end
    if shared > 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - %d crossing(s) joined at a shared point, so AutoDrive makes one driver wait there (%d of them at 80 deg or less, where it can also switch paths).",
            shared, jxState.jxShallowJoins)
    end
    if jxState.jxSquaredJoins > 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - %d shallow crossing(s) squared up with a small S-bend in the new path, so AutoDrive cannot switch paths there.",
            jxState.jxSquaredJoins)
    end
    self.junctionLastShared = { joined = shared, shallow = jxState.jxShallowJoins, squared = jxState.jxSquaredJoins }
    -- THE ROUTE CHECK, on the junction as built (report only, like the clear's own check).
    local rc = nil
    tryCall("junction route check", function() rc = junctionRouteCheck(jp, placedSet, cx, cz, radius) end)
    self.junctionLastRouteCheck = rc
    -- The card's record of this build. Built anyway when a route is extra; the card says so.
    tryCall("junction route check (card)", function()
        local card
        if rc == nil then
            card = { "Route check: could not run - see the log" }
        elseif #rc.extra == 0 and #(rc.missing or {}) == 0 then
            card = { string.format("Route check: all %d routes as meant", rc.routes) }
        elseif #rc.extra == 0 then
            card = { string.format("Route check: %d turn(s) we laid cannot be driven", #rc.missing), "see the log" }
        else
            card = { string.format("Route check: %d route(s) we did not lay", #rc.extra),
                     "most likely U-turns - AutoDrive can drive them, see the log" }
        end
        self:junctionBuildCheckKeep({ card = card, number = jp.junctionNumber, x = cx, z = cz,
            extra = rc and #rc.extra or nil })
    end)
    if rc ~= nil and #(rc.missing or {}) > 0 then
        Logging.warning("[FlyoverEditor]: junction route check - %d turn(s) we laid cannot be driven:", #rc.missing)
        for _, e in ipairs(rc.missing) do
            Logging.warning("[FlyoverEditor]:   from the lane in at %.1f, %.1f to the lane out at %.1f, %.1f.",
                e.from.x, e.from.z, e.to.x, e.to.z)
        end
    end
    if rc ~= nil then
        if #rc.extra == 0 then
            ADFlyoverSettings.debugLog("[FlyoverEditor]: junction route check - %d route(s) AutoDrive can take through here, all of them turns we meant.",
                rc.routes)
        else
            Logging.warning("[FlyoverEditor]: junction route check - %d route(s) AutoDrive can take through here that we did not mean to lay:",
                #rc.extra)
            for _, e in ipairs(rc.extra) do
                Logging.warning("[FlyoverEditor]:   from the lane in at %.1f, %.1f to the lane out at %.1f, %.1f (%s).",
                    e.from.x, e.from.z, e.to.x, e.to.z, e.why)
            end
        end
    end
    self.junctionLastLinkLabels = jxState.jxLinkLabel
    self.junctionLastNodeLabels = jxState.jxNodeLabel   -- for the harness's route study; nothing in game reads it
    jxBuildEnd()
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
    self:debugCaptureEnd(cap)
    self.junctionArmed, self.junctionPreview, self.junctionPreviewKey = nil, nil, nil
end

--- Wheel handler. Returns true when the wheel was consumed, which is what stops the camera zoom.
--- Apply one wheel step to the active tool's key setting, ignoring the "has a pending action" gates.
--- Shared by the gated handleWheel paths below and by wheeling directly over the tool card, where the
--- whole point is to dial a value in (move's falloff, a tolerance) before anything is selected.
--- Returns true if it changed a value.
function ADFlyoverEditor:applyWheelToActiveTool(step)
    local t = self.tool
    if t == self.TOOL.SIDING then
        -- Siding: the wheel is the LENGTH, the dimension that changes per site.
        local setting = ADFlyoverSettings.settings.sidingLength
        if setting ~= nil then
            local nextIndex = math.max(1, math.min(#setting.values, setting.current + step))
            if nextIndex ~= setting.current then
                ADFlyoverSettings.setIndex("sidingLength", nextIndex)
            end
        end
        return true
    elseif t == self.TOOL.PARALLEL then
        self.offsetDistance = math.max(AutoDrive.FLYOVER_OFFSET_MIN,
            math.min(AutoDrive.FLYOVER_OFFSET_MAX,
                self.offsetDistance + step * AutoDrive.FLYOVER_OFFSET_STEP))
        self.offsetCache = nil
        return true
    elseif t == self.TOOL.GROUND then
        self.groundTolerance = math.max(AutoDrive.FLYOVER_GROUND_MIN,
            math.min(AutoDrive.FLYOVER_GROUND_MAX,
                self.groundTolerance + step * AutoDrive.FLYOVER_GROUND_STEP))
        return true
    elseif t == self.TOOL.STRAIGHTEN then
        self.straightenTolerance = math.max(AutoDrive.FLYOVER_STRAIGHTEN_MIN,
            math.min(AutoDrive.FLYOVER_STRAIGHTEN_MAX,
                self.straightenTolerance + step * AutoDrive.FLYOVER_STRAIGHTEN_STEP))
        return true
    elseif t == self.TOOL.DIVIDE then
        self.divideCount = math.max(0, math.min(AutoDrive.FLYOVER_DIVIDE_MAX, self.divideCount + step))
        return true
    elseif t == self.TOOL.MOVE then
        -- R+wheel rotates the currently-dragged set live (settled 2026-09-21) - takes priority
        -- over falloff/offset whenever it applies, since holding R is a deliberate, active choice
        -- to rotate rather than just wheeling absent-mindedly. Only meaningful mid-drag (there is
        -- nothing to rotate once released) and does nothing for a frozen copy-preview drag (see
        -- updateDrag - out of scope for now, not handled).
        if self.rotateKeyHeld and self.dragId ~= nil then
            self.moveRotateAngle = self.moveRotateAngle - step * AutoDrive.FLYOVER_ROTATE_WHEEL_STEP
            self:updateDrag()
            ADFlyoverSettings.debugLog("[FlyoverEditor]: move rotate %.0f deg.", math.deg(self.moveRotateAngle))
            return true
        end
        -- A pending offset (released, awaiting its right-click commit) takes the wheel over
        -- falloff whenever both could apply - it is the thing actually awaiting input right now,
        -- and handleWheel also claims the wheel for it everywhere, not just over the card (see the
        -- MOVE branch of the pending-action list below), so this has to agree with that.
        if self.moveOffsetChainIds ~= nil then
            -- Same direction as every other number (no per-field exception; see handleWheel).
            self:setMoveOffsetDistance(self.moveOffsetDistance + step * AutoDrive.FLYOVER_OFFSET_STEP)
            return true
        end
        -- Falloff is a spatial reach, not a tolerance/count - wheel-up should WIDEN it, the
        -- opposite of the global reversal `step` already carries (see handleWheel), so this
        -- negates it back to the raw scroll direction. This is the one negation Move's wheel
        -- actually needs; an earlier attempt removed it entirely instead of scoping it to just
        -- this field, which is what made the wheel read backwards again.
        -- A scattered selection moves rigidly: there is no reach to set, so the wheel must not quietly change
        -- a hidden value (it did, and the yellow preview changed shape for no reason). Leave the wheel to
        -- the camera instead.
        if self.selectionCount > 0 or self.moveSpanIds ~= nil then
            return false   -- no reach to set: the wheel goes to the camera
        end
        self:setFalloffRadius(self.falloffRadius + step * AutoDrive.FLYOVER_FALLOFF_WHEEL_STEP)
        return true
    elseif t == self.TOOL.SMOOTH then
        -- Each mode gets the number it actually uses; rebuild ignores strength.
        if self.smoothMode == self.SMOOTH_MODE.REBUILD then
            self.smoothSpacing = math.max(AutoDrive.FLYOVER_SPACING_MIN,
                math.min(AutoDrive.FLYOVER_SPACING_MAX,
                    self.smoothSpacing + step * AutoDrive.FLYOVER_SPACING_STEP))
        else
            self.smoothStrength = math.max(0, math.min(AutoDrive.FLYOVER_SMOOTH_MAX, self.smoothStrength + step))
        end
        return true
    elseif t == self.TOOL.JUNCTION then
        -- NOTHING IN CLEAR MODE. The scope radius used to be "the primary disambiguation lever for
        -- what the crossing is", and that was the trouble: what belongs to a junction is a property
        -- of the road, and letting a wheel decide it meant the same click gave different answers.
        -- Clearing takes its scope from the junction now, so there is nothing here to turn. Build
        -- mode still has one - its tie-in and kickout geometry is laid out around it.
        if self.junctionMode == "clear" then return false end
        self:setJunctionRadius(self:junctionRadiusValue() + step * AutoDrive.FLYOVER_JUNCTION_RADIUS_STEP)
        return true
    end
    return false
end

function ADFlyoverEditor:handleWheel(offset)
    if offset == nil or offset == 0 then
        return false
    end
    -- Deliberately reversed: wheel-up now DECREASES / pages down, wheel-down the reverse. Every wheel
    -- the mod itself drives runs through here - the card's numeric fields, the tool settings, the
    -- settings-dialog fields, and the manual's page scroll - so one negation flips them all to match
    -- the direction players expected. The -/+ stepper BUTTONS are untouched (they call stepAction
    -- directly, not this), and so is spline curvature: that wheel never reaches here - it falls
    -- through to AutoDrive's handleSplineCurvature on the camera-zoom path (see updateSplinePreview),
    -- which is exactly the one control the player asked to leave alone.
    local step = offset > 0 and -1 or 1

    -- A modal owns the wheel while it is up, and consumes it so nothing zooms behind. In the manual
    -- the wheel pages; in the settings dialog it adjusts the field under the cursor (via dialogWheel).
    if self:isModalOpen() then
        if self.manualOpen then
            self:manualScrollBy(step)
        elseif ADFlyoverHud ~= nil then
            ADFlyoverHud:dialogWheel(self.mouseX, self.mouseY, step)
        end
        return true
    end

    -- The contextual help is non-modal, but the wheel scrolls it when the cursor is over it, so a long
    -- page (Select's, say) can be read without paging to the manual. Same reversed step and 0.06 notch
    -- as the manual, so the two scroll the same way.
    if self.helpOpen and ADFlyoverHud ~= nil and ADFlyoverHud:isMouseOverHelp(self.mouseX, self.mouseY) then
        self:helpScrollBy(step)
        return true
    end

    -- Move's falloff radius is a spatial REACH, and players expect wheel-up to WIDEN it - the opposite
    -- of the tolerances and counts the global reversal above suits. Two rounds of history here:
    --
    --   1. (2026-09-21, earlier) a `-step` negation for Move fought an unrelated second negation
    --      elsewhere and produced wheel-up NARROWING the reach - backwards. "Fixed" by deleting
    --      the negation entirely, so Move fell through to the same plain reversed `step` as every
    --      tolerance/count field.
    --   2. (2026-09-21, later) that "fix" was itself backwards: it removed the ONE negation Move
    --      actually needed (to counteract the global reversal, not to double it), so the wheel was
    --      reported backwards again. The negation is back, but scoped correctly this time - see
    --      applyWheelToActiveTool's MOVE branch and the `wheelReach` field flag below, not a
    --      standing local here. The -/+ steppers were never affected either way (they call
    --      stepAction directly with a raw, unreversed dir, not through here).
    local toolStep = step

    -- Any numeric field under the cursor takes the wheel: the floating card's fields, the settings
    -- fields in the corner block, and the armed popup. Only rows carrying a stepAction match, so a
    -- scroll over a plain button or empty space still falls through to the camera zoom below.
    if ADFlyoverHud ~= nil then
        local field = ADFlyoverHud:numberFieldAt(self.mouseX, self.mouseY)
        if field ~= nil and field.stepAction ~= nil then
            -- wheelReach fields (Move's falloff) want the raw, unreversed sign - see the field's
            -- own definition in getEditableNumbers for why.
            -- One rule for every number field: the wheel steps it the same way. Move's falloff and offset
            -- used to be exempt (wheelReach), which made them run backwards next to everything else.
            field.stepAction(step)
            return true
        end
    end

    -- Over the tool card but not on a specific field: adjust the active tool's setting anyway, so the
    -- card is a place you can dial a value in before you start (move's falloff without a point picked).
    if ADFlyoverHud ~= nil and ADFlyoverHud:isMouseOverToolCard(self.mouseX, self.mouseY) then
        if self:applyWheelToActiveTool(toolStep) then
            return true
        end
    end

    -- Otherwise a tool claims the wheel only while it has a pending action (a span picked, a drag in
    -- progress), so the camera zoom keeps the wheel the rest of the time. toolStep is the plain
    -- reversed step for every tool - Move's own falloff negation happens inside
    -- applyWheelToActiveTool, not here, since that is the one call site shared by both the
    -- mid-drag and hover-over-card cases.
    if self.tool == self.TOOL.SIDING and self.sidingAnchorId ~= nil then return self:applyWheelToActiveTool(toolStep) end
    if self.tool == self.TOOL.PARALLEL and self.offsetToId ~= nil then return self:applyWheelToActiveTool(toolStep) end
    if self.tool == self.TOOL.GROUND and (self.groundToId ~= nil or self.groundUsesSelection) then return self:applyWheelToActiveTool(toolStep) end
    if self.tool == self.TOOL.STRAIGHTEN and self.straightenToId ~= nil then return self:applyWheelToActiveTool(toolStep) end
    if self.tool == self.TOOL.DIVIDE and self.divideToId ~= nil then return self:applyWheelToActiveTool(toolStep) end
    -- Also claimed with a pending (released, not yet right-click-committed) offset - not just
    -- mid-drag - so the wheel adjusts it from anywhere in the view, not only over the card
    -- (requested 2026-09-21: it previously only worked while actually hovering the tool card).
    if self.tool == self.TOOL.MOVE and (self.dragId ~= nil or self.moveOffsetChainIds ~= nil) then
        return self:applyWheelToActiveTool(toolStep)
    end
    if self.tool == self.TOOL.SMOOTH and self.smoothToId ~= nil then return self:applyWheelToActiveTool(toolStep) end
    -- Junction claims the wheel once a SITE IS LOCKED (its pending action - the lock message says
    -- "wheel = scope" at that moment), the same rule as every tool above. It used to claim the wheel
    -- unconditionally while the tool was up, which took the camera zoom away for the whole time the
    -- tool was selected - hunting for the next crossing with no way to zoom. Before the lock the card
    -- still takes the wheel when hovered (the branch above), so the scope can be dialled in first.
    if self.tool == self.TOOL.JUNCTION and self.junctionArmed ~= nil then return self:applyWheelToActiveTool(toolStep) end

    return false
end

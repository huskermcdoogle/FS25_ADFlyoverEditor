-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua
-- loads it after FlyoverEditor.lua, in the old file's order.
-- MODSPLIT: HELPERS FROM THE FILES LOADED BEFORE THIS ONE (tools/modsplit/split.py writes this block)
for _, name in ipairs({ "JUNCTION_FORK_LINK", "JUNCTION_REGISTRY_FILE", "junctionCentroidClusters", "junctionPlacePattern", "junctionRegistryFolder", "junctionVirginSites", "jxHomeIsHere", "jxHomeNow", "jxNetworkMark", "jxSameNetwork", "tryCall" }) do
    if ADFlyoverEditor.shared == nil or ADFlyoverEditor.shared[name] == nil then
        Logging.error("[FlyoverEditor]: JxRegistry.lua needs %s, which no file loaded before it shares", name)
    end
end
local JUNCTION_FORK_LINK = ADFlyoverEditor.shared.JUNCTION_FORK_LINK
local JUNCTION_REGISTRY_FILE = ADFlyoverEditor.shared.JUNCTION_REGISTRY_FILE
local junctionCentroidClusters = ADFlyoverEditor.shared.junctionCentroidClusters
local junctionPlacePattern = ADFlyoverEditor.shared.junctionPlacePattern
local junctionRegistryFolder = ADFlyoverEditor.shared.junctionRegistryFolder
local junctionVirginSites = ADFlyoverEditor.shared.junctionVirginSites
local jxHomeIsHere = ADFlyoverEditor.shared.jxHomeIsHere
local jxHomeNow = ADFlyoverEditor.shared.jxHomeNow
local jxNetworkMark = ADFlyoverEditor.shared.jxNetworkMark
local jxSameNetwork = ADFlyoverEditor.shared.jxSameNetwork
local tryCall = ADFlyoverEditor.shared.tryCall
-- MODSPLIT: end of the helpers

-- THE PARTS OF A SPLIT JUNCTION, AS THE USER NAMED THEM (split_decisions.txt in the harness). The
-- number never changes; each part carries an 8-point compass letter after it, or none - the middle
-- one of three keeps the bare number (39, 39se, 39nw). This is the order a junction's parts are
-- written and listed in: the bare number first, then clockwise from north. A fixed order, so two
-- saves of the same decisions are the same file.
local JX_PART_LETTERS = { "", "n", "ne", "e", "se", "s", "sw", "w", "nw" }
local JX_PART_RANK = {}
for i, l in ipairs(JX_PART_LETTERS) do JX_PART_RANK[l] = i end

local function jxSortParts(parts)
    table.sort(parts, function(a, b) return JX_PART_RANK[a.letter] < JX_PART_RANK[b.letter] end)
end

-- How far out a CLEARED site's lanes are read for its kind and its parts, from the site's middle.
-- Fixed, not the build's search radius: build cuts the lanes where the wheel's circle crosses them,
-- and read from there the answer moved with the wheel - at 18 m it suggested splitting 71, which
-- the user keeps whole; at 12 and 14 it lost 73's split; at 30 it swapped 72's two kinds. 15 is the
-- wheel's own default, the radius every cleared site on the survey map was read at when the user
-- made the split decisions (split_decisions.txt in the harness).
-- Up here, not beside junctionVirginReading where it is mostly used, because naming a locked site
-- (junctionNameAt, below) uses it too: a file-local is only seen by code written after it.
local JUNCTION_CLEARED_READ_R = 15

-- HOW NEAR A SAVED PART, in two steps. Where the user's parts sit and what lands near them was
-- measured on the survey map with the user's decisions loaded (both through-road settings, every
-- part cleared on its own and in pairs):
--   - a lock ON a part lands within 0.2 m of where it was saved while it is wired, and a cleared
--     part's middle within 4.8 m (39, cleared together with 39se; most within 3.8 m); what is left
--     of a part after a clear is found by the numbering within 3.7 m of it (14se 2.6 m, cleared 20s
--     3.2 m, cleared 20n 3.7 m);
--   - the nearest site of ANOTHER junction to any saved part is 13.7 m off: the Y beside 39se that
--     belongs to 30 (the user's j30.1, its own tie forks).
-- JX_PART_AT: a lock this near a part IS that part. Under half the distance between the two closest
-- parts the user has split (72w and 72e, 10.8 m), so one lock can never be at two.
local JX_PART_AT = 5
-- JX_PART_NEAR: a site this near a part belongs to that part's junction - it takes that number, and
-- the numbering never hands it a number of its own. Room for a part's middle to drift after a clear,
-- and well short of the Y beside 39se, which stays 30's.
local JX_PART_NEAR = 8

--- READ A JUNCTION FILE: the numbers and, for each, the user's decision on splitting it. Returns a
--- list of { n, x, z, decision, parts, partsAside } - decision "split", "whole" or nil (not
--- decided); parts only on a split, each { letter, x, z } in JX_PART_LETTERS order; partsAside the
--- same, on a junction that is not split now but was, with the names its parts had then - or nil and
--- why it could not be read. A plain function, not a method, so the offline harness reads and writes
--- exactly as the game does (split_registry.lua). The file is trusted no further than it has to be:
--- anything that is not whole is left out with one warning, and the rest is still read.
---
--- The parts are written the same way whatever the decision: `decision="split"` puts them in use,
--- `decision="whole"` or none sets them aside for a later split (junctionDecide).
function ADFlyoverEditor.junctionRegistryReadFile(path)
    local list, seen = {}, {}
    local ok, err = pcall(function()
        local xml = loadXMLFile("ADFlyoverJunctions", path)
        local i = 0
        while true do
            local key = string.format("flyoverEditor.junctions.junction(%d)", i)
            if not hasXMLProperty(xml, key) then break end
            local n = getXMLInt(xml, key .. "#n")
            local x, z = getXMLFloat(xml, key .. "#x"), getXMLFloat(xml, key .. "#z")
            -- Skip an entry that is not whole rather than trusting the file: a number with no
            -- position can never be matched, so it would sit on that number for good; and the same
            -- number twice would put one name on two junctions, which is the very thing the file
            -- exists to prevent. The first one read wins.
            if n ~= nil and n >= 1 and x ~= nil and z ~= nil and not seen[n] then
                seen[n] = true
                local f = { n = n, x = x, z = z }
                local decision = getXMLString(xml, key .. "#decision")
                -- A part is kept only if its name is this number and a compass letter (or the bare
                -- number), it has a place, and no other part has its name: a part named twice would
                -- put one name on two places, and that is what the names are for telling apart.
                local parts, have, k = {}, {}, 0
                while true do
                    local pk = string.format("%s.part(%d)", key, k)
                    if not hasXMLProperty(xml, pk) then break end
                    local name = getXMLString(xml, pk .. "#name")
                    local px, pz = getXMLFloat(xml, pk .. "#x"), getXMLFloat(xml, pk .. "#z")
                    local num, letter = nil, nil
                    if name ~= nil then num, letter = name:match("^(%d+)(%a*)$") end
                    local bad = nil
                    if num ~= tostring(n) or JX_PART_RANK[letter] == nil then
                        bad = "its name is not this junction's number with a compass letter"
                    elseif px == nil or pz == nil then
                        bad = "it has no position"
                    elseif have[letter] then
                        bad = "another part already has that name"
                    end
                    if bad ~= nil then
                        Logging.warning("[FlyoverEditor]: junction j%02d - a saved part (%s) is left out: %s. (%s)",
                            n, tostring(name), bad, path)
                    else
                        have[letter] = true
                        parts[#parts + 1] = { letter = letter, x = px, z = pz }
                    end
                    k = k + 1
                end
                jxSortParts(parts)
                if decision == "split" then
                    if #parts >= 2 then
                        f.decision, f.parts = "split", parts
                    else
                        Logging.warning("[FlyoverEditor]: junction j%02d is saved as split, but fewer than two of its parts could be read - taken as not decided. (%s)",
                            n, path)
                    end
                else
                    if decision == "whole" then
                        f.decision = "whole"
                    elseif decision ~= nil then
                        Logging.warning("[FlyoverEditor]: junction j%02d has a decision this version does not know (%s) - taken as not decided. (%s)",
                            n, tostring(decision), path)
                    end
                    -- Not split now: the names its parts had when it was, set aside for a split.
                    if #parts >= 2 then
                        f.partsAside = parts
                    elseif k > 0 then
                        Logging.warning("[FlyoverEditor]: junction j%02d - fewer than two of the part names set aside for a later split could be read - they are left out. (%s)",
                            n, path)
                    end
                end
                list[#list + 1] = f
            end
            i = i + 1
        end
        delete(xml)
    end)
    if not ok then return nil, err end
    return list
end

--- WRITE A JUNCTION FILE: every numbered junction in `reg`, in number order, each with its decision
--- and its parts - in use on a split, set aside (partsAside) otherwise. True when written; false and
--- why when not. Like the reader, a plain function the harness uses too. Nothing here decides WHERE:
--- the caller has checked the folder.
---
--- n, x and z stay first on each junction, in that order: the harness's scripts read the numbers
--- with a grep for exactly that. A part has no n of its own, so no such grep can take a part for a
--- junction, and its name is never empty (39, not ""), so nothing rests on how an empty value reads.
function ADFlyoverEditor.junctionRegistryWriteFile(path, reg)
    local byNumber = {}
    for _, f in ipairs(reg or {}) do
        if f.n ~= nil then byNumber[#byNumber + 1] = f end
    end
    -- In number order, so the file reads as the survey does and two saves of the same registry
    -- are the same file.
    table.sort(byNumber, function(a, b) return a.n < b.n end)
    local ok, err = pcall(function()
        local xml = createXMLFile("ADFlyoverJunctions", path, "flyoverEditor")
        for i, f in ipairs(byNumber) do
            local key = string.format("flyoverEditor.junctions.junction(%d)", i - 1)
            setXMLInt(xml, key .. "#n", f.n)
            setXMLFloat(xml, key .. "#x", f.x)
            setXMLFloat(xml, key .. "#z", f.z)
            local saved = nil
            if f.decision == "whole" then
                setXMLString(xml, key .. "#decision", "whole")
            elseif f.decision == "split" and f.parts ~= nil and #f.parts >= 2 then
                setXMLString(xml, key .. "#decision", "split")
                saved = f.parts
            end
            if f.decision ~= "split" and f.partsAside ~= nil and #f.partsAside >= 2 then saved = f.partsAside end
            if saved ~= nil then
                local parts = {}
                for _, p in ipairs(saved) do parts[#parts + 1] = p end
                jxSortParts(parts)
                for k, p in ipairs(parts) do
                    local pk = string.format("%s.part(%d)", key, k - 1)
                    setXMLString(xml, pk .. "#name", string.format("%d%s", f.n, p.letter))
                    setXMLFloat(xml, pk .. "#x", p.x)
                    setXMLFloat(xml, pk .. "#z", p.z)
                end
            end
        end
        saveXMLFile(xml)
        delete(xml)
    end)
    if not ok then return false, err end
    return true
end

--- The numbers as they were last written: the list junctionRegistryReadFile gives and the path it
--- came from, or nil when this savegame has no file yet or it cannot be read. Only number, position
--- and the user's split decision are kept, because position is all a junction can be recognised by
--- after a restart - its node ids are reissued by every removal, and a clear replaces the nodes
--- outright. `home` (jxHomeNow) is the game and folder they are read for.
local function junctionRegistryLoad(home)
    local folder = home ~= nil and home.folder or nil
    if folder == nil or fileExists == nil then return nil end
    local path = folder .. JUNCTION_REGISTRY_FILE
    if not fileExists(path) then return nil end
    local list, err = ADFlyoverEditor.junctionRegistryReadFile(path)
    if list == nil then
        Logging.warning("[FlyoverEditor]: junction - could not read the saved numbers (%s): %s",
            path, tostring(err))
        return nil
    end
    return list, path
end

--- Write every numbered junction, found or not: the ones the scan no longer sees are exactly the
--- ones whose numbers would otherwise be handed out again after a restart. Returns true and the
--- path when the file was written.
---
--- ONLY INTO THE FOLDER THEY WERE READ FROM (`home`, the registry's), and only while that game is
--- still the one loaded: anywhere else they would replace another career's numbers and decisions
--- with these.
local function junctionRegistrySave(reg, home)
    if not jxHomeIsHere(home) then return false end
    local folder = home.folder
    if folder == nil or createXMLFile == nil or fileExists == nil then return false end
    -- A career that has never been saved has no folder yet, and making one here would leave a
    -- savegame slot holding nothing but this file for the game to trip over. The numbers stay in
    -- memory, the registry stays marked unsaved, and junctionRegistrySaveWaiting writes them once
    -- the game's first save has made the folder.
    if not fileExists(folder .. "careerSavegame.xml") then return false end
    local path = folder .. JUNCTION_REGISTRY_FILE
    local ok, err = ADFlyoverEditor.junctionRegistryWriteFile(path, reg)
    if not ok then
        Logging.warning("[FlyoverEditor]: junction - could not save the numbers (%s): %s",
            path, tostring(err))
        return false
    end
    return true, path
end

--- EVERY JUNCTION ON THE MAP, NUMBERED, so a site can be named out loud. Without a number, talking
--- about a particular junction means quoting coordinates at each other and hoping we mean the same
--- one, and a survey done on Tuesday cannot be compared with a run done on Thursday.
---
--- The rules for a WIRED junction are the ones the survey was built with: a fork is a point with
--- three or more neighbours, forks within 15 m of each other are one junction, and it takes four of
--- them to count - which is what a junction of two two-lane roads comes to. Deliberately NOT the
--- same test the clear uses to decide whether to work on a site: this one only has to name things,
--- and a name that changes when the rule is tuned is worse than no name.
---
--- Numbers are carried over from the last build by POSITION, so adding a junction does not renumber
--- the ones already there - a new one takes the next free number and is logged, so it can be added
--- to the survey rather than silently shifting everything by one.
--- THE JUNCTION'S SITUATION - what stands on its arms. Shape says what a junction IS (T, Y, 4-way);
--- situation says what it is NEXT TO, and the right rule for clearing it depends on both: merging a
--- second crossing into this one is correct where that crossing is this junction's own kickout, and
--- wipes out a neighbour where it is the other half of a close pair. One rule for every junction
--- was tuned four times in a day to fit one of those and broke the other each time.
---
--- This only CLASSIFIES. Nothing branches on it yet; it is shown and logged so it can be checked
--- against the map before any rule is allowed to depend on it.
---
---   isolated             - nothing else on any arm within the walk
---   close pair           - another wired junction, with a road of its own, stands on an arm
---   neighbour cleared    - an arm ends at the box of a junction that has already been cleared
---   own far tie forks    - a cluster of forks up one of the arms, all of whose long roads are
---                          this junction's own roads running on: a kickout merge, not a junction
function ADFlyoverEditor:junctionSituation(site)
    if site == nil or site.roads == nil then return nil end
    local function sep(a, b)
        local d = math.abs(a - b) % (2 * math.pi)
        if d > math.pi then d = 2 * math.pi - d end
        return d
    end
    local found = {}
    for _, r in ipairs(site.roads) do
        local probes = {}
        for _, st in ipairs(r.stops or {}) do probes[#probes + 1] = st end
        for _, de in ipairs(r.deadEnds or {}) do probes[#probes + 1] = de end
        for _, p in ipairs(probes) do
            local other = self:junctionSelect(p.x, p.z)
            -- beyond the arm walk it is just the next junction down the road, not this one's situation
            if other ~= nil and (other.x - site.x) ^ 2 + (other.z - site.z) ^ 2 > 8 * 8
                and (other.x - site.x) ^ 2 + (other.z - site.z) ^ 2 <= 45 * 45 then
                local dist = math.sqrt((other.x - site.x) ^ 2 + (other.z - site.z) ^ 2)
                local kind
                if other.virgin then
                    kind = "neighbour cleared"
                else
                    -- A road of its OWN: long, and not PHYSICALLY one of this junction's roads -
                    -- asked of the nodes, not the bearings. Two T's on one road have side roads
                    -- that point the same way, and by bearing a genuine neighbour's side road read
                    -- as "one of mine" and the pair as a kickout.
                    local myNodes = {}
                    for _, fk in ipairs(site.forks or {}) do myNodes[fk] = true end
                    for _, m in ipairs(site.roads) do
                        for wn in pairs(m.walked or {}) do myNodes[wn] = true end
                    end
                    local own = 0
                    for _, o in ipairs(other.roads or {}) do
                        if o.len >= 15 then
                            local shared, total = 0, 0
                            for wn in pairs(o.walked or {}) do
                                total = total + 1
                                if myNodes[wn] then shared = shared + 1 end
                            end
                            if total > 0 and shared == 0 then own = own + 1 end
                        end
                    end
                    kind = (own >= 1) and "close pair" or "own far tie forks"
                end
                local dup = false
                for _, f in ipairs(found) do
                    if (f.x - other.x) ^ 2 + (f.z - other.z) ^ 2 <= 8 * 8 then dup = true break end
                end
                if not dup then found[#found + 1] = { kind = kind, dist = dist, x = other.x, z = other.z } end
            end
        end
    end
    if #found == 0 then return "isolated", found end
    table.sort(found, function(a, b) return a.dist < b.dist end)
    local parts = {}
    for _, f in ipairs(found) do parts[#parts + 1] = string.format("%s %.0f m", f.kind, f.dist) end
    return table.concat(parts, "; "), found
end

--- THE NUMBERS IN MEMORY, ONLY WHILE THEY ARE THIS GAME'S. Another game loaded since they were read
--- (back to the menu, another savegame), or this game's folder no longer the one they were read from:
--- they are dropped - with anything still waiting for a first save, said once - and read afresh
--- from the folder of the game loaded now. True when they are this game's (or there are none).
function ADFlyoverEditor:junctionRegistryCheckHome()
    if self._jxReg == nil or jxHomeIsHere(self._jxRegHome) then return true end
    if self._jxRegUnsaved then
        local home = self._jxRegHome
        Logging.info("[FlyoverEditor]: junction - another savegame is loaded now: the junction numbers and decisions still waiting to be written to %s are dropped, not written into this one.",
            tostring(home ~= nil and home.folder or "an earlier game"))
    end
    self._jxReg, self._jxRegCount, self._jxRegHome, self._jxRegNet = nil, nil, nil, nil
    self._jxRegUnsaved, self._jxRegWaitMs = false, 0
    return false
end

function ADFlyoverEditor:junctionRegistry()
    self:junctionRegistryCheckHome()
    local count = ADGraphManager:getWayPointsCount()
    if self._jxReg ~= nil and self._jxRegCount == count and jxSameNetwork(self._jxRegNet) then return self._jxReg end

    local wps = ADGraphManager:getWayPoints()
    -- By id, so the order is the graph's own and two builds of the same map agree.
    local ids = {}
    for _, w in pairs(wps) do
        if w ~= nil and w.id ~= nil then ids[#ids + 1] = w.id end
    end
    table.sort(ids)

    local forks, ends = {}, {}
    for _, id in ipairs(ids) do
        local w = ADGraphManager:getWayPointById(id)
        if w ~= nil then
            local nb, deg = {}, 0
            for _, t in ipairs(w.out or {}) do nb[t] = true end
            for _, f in ipairs(w.incoming or {}) do nb[f] = true end
            for _ in pairs(nb) do deg = deg + 1 end
            if deg >= 3 then forks[#forks + 1] = w
            elseif deg == 1 then ends[#ends + 1] = w end
        end
    end

    local used, found = {}, {}
    for i = 1, #forks do
        if not used[i] then
            used[i] = true
            local grp, stack = {}, { i }
            while #stack > 0 do
                local k = table.remove(stack)
                grp[#grp + 1] = forks[k]
                for j = 1, #forks do
                    if not used[j]
                        and (forks[j].x - forks[k].x) ^ 2 + (forks[j].z - forks[k].z) ^ 2 < 15 * 15 then
                        used[j] = true
                        stack[#stack + 1] = j
                    end
                end
            end
            if #grp >= 4 then
                local sx, sz = 0, 0
                for _, g in ipairs(grp) do sx, sz = sx + g.x, sz + g.z end
                local mx, mz = sx / #grp, sz / #grp
                local dup = false
                for _, f in ipairs(found) do
                    if (f.x - mx) ^ 2 + (f.z - mz) ^ 2 <= 15 * 15 then dup = true break end
                end
                if not dup then found[#found + 1] = { x = mx, z = mz, forks = #grp } end
            end
        end
    end
    -- The virgin ones, after every wired one. Lane ends are held away from the SELECTION's fork
    -- clusters (centroid linkage, any size), not from the four-fork groups above: a lone fork at a
    -- field entrance is enough to make the ends beside it that entrance's debris, and the point is
    -- to see a virgin junction exactly where a click would lock one.
    -- ...AND ONLY IF A CLICK WOULD ACTUALLY LOCK IT. A ring of lane ends says something was cleared
    -- here; it does not say a junction was. Three ends facing each other across a GAP in a road is a
    -- ring too, and the selection refuses it outright - "only 2 roads meet here". Naming a site the
    -- tool then declines to work on is worse than leaving it unnamed: the number is a promise that
    -- there is something there to clear. One such site on the survey map, at (7.5, -212.3), read as
    -- a junction by the ring rule alone.
    for _, s in ipairs(junctionVirginSites(junctionCentroidClusters(forks, JUNCTION_FORK_LINK), ends)) do
        if self:junctionSelect(s.x, s.z) ~= nil then
            found[#found + 1] = { x = s.x, z = s.z, ends = #s.nodes, virgin = true }
        end
    end

    -- What was numbered before: the last build, or - the first time in a session - the file.
    -- The file is the one in the folder of the game loaded now, and that folder is the only one these
    -- numbers are ever written back to (junctionRegistrySave).
    local prev, fromFile = self._jxReg, nil
    if prev == nil then
        self._jxRegHome = jxHomeNow()
        prev, fromFile = junctionRegistryLoad(self._jxRegHome)
        prev = prev or {}
    end

    -- Carry the numbers across, NEAREST PAIR FIRST. Taking the first old entry within reach was
    -- good enough while the old entries were last build's and in the same order; read from a file,
    -- against a scan whose order a clear has reshuffled, it is not - two junctions closer together
    -- than the reach (j55 and j56 are 28 m apart, and two T's on one road can sit closer still)
    -- are each inside the other's circle, and whichever was scanned first would take the other's
    -- number. Closest pairs settle first, so each keeps its own.
    local MATCH = 20
    local pairings = {}
    for fi, f in ipairs(found) do
        for pi, p in ipairs(prev) do
            if p.n ~= nil then
                local d2 = (p.x - f.x) ^ 2 + (p.z - f.z) ^ 2
                if d2 <= MATCH * MATCH then
                    pairings[#pairings + 1] = { f = f, p = p, d2 = d2, fi = fi, pi = pi }
                end
            end
        end
    end
    -- Ties broken by list order, so the same two lists always pair the same way.
    table.sort(pairings, function(a, b)
        if a.d2 ~= b.d2 then return a.d2 < b.d2 end
        if a.fi ~= b.fi then return a.fi < b.fi end
        return a.pi < b.pi
    end)
    local taken, added, nKept = {}, {}, 0
    for _, m in ipairs(pairings) do
        if m.f.n == nil and not taken[m.p.n] then
            m.f.n = m.p.n
            -- THE USER'S SPLIT DECISION GOES WITH THE NUMBER, parts and all, exactly as saved. The
            -- parts are never lettered again from what the scan sees now: a three-part junction
            -- that lost a part to a clear would be lettered by the two-part rule, and 39nw would
            -- come back as 39w - the very shuffle the saved names are there to stop. The same for
            -- the names set aside by "keep whole" or "not decided", which a split brings back.
            m.f.decision, m.f.parts, m.f.partsAside = m.p.decision, m.p.parts, m.p.partsAside
            taken[m.p.n] = true
        end
    end
    -- A JUNCTION THE SCAN HAS LOST KEEPS ITS NUMBER. The scan knows both forms now, but a junction
    -- can still drop out of it: cleared with its through road left in, all that remains is the side
    -- road's two lane ends, and two lane ends are a gap in a road, not a junction. Dropping it here
    -- would hand its number to the next new one. Whatever was numbered before and was not found
    -- again is carried forward as it stood - and written to the file with the rest.
    for _, p in ipairs(prev) do
        if p.n ~= nil and not taken[p.n] then
            found[#found + 1] = { x = p.x, z = p.z, forks = p.forks, ends = p.ends, n = p.n,
                                  cleared = true, decision = p.decision, parts = p.parts,
                                  partsAside = p.partsAside }
            taken[p.n] = true
            nKept = nKept + 1
        end
    end
    -- A SAVED PART NEVER BECOMES A NEW NUMBER. Anything the scan found that has no number yet and
    -- lies within JX_PART_NEAR of a part the user has named is what is left of that part, so it is
    -- not numbered at all: a part 27 m from its number's own point (39se) is outside the 20 m the
    -- numbers are carried over by, and what is left of it after a clear would otherwise come back
    -- as a new number. No further than JX_PART_NEAR: at 15 m this also swallowed the Y beside 39se
    -- that belongs to 30 (13.7 m off), so if that Y were ever found as a junction of its own it would
    -- have been dropped without a word instead of being numbered and logged. With no split saved
    -- anywhere nothing here changes. A part set aside ("keep whole", "not decided") holds the same:
    -- it is still the user's word on where that junction's parts are, and a number handed out on it
    -- would sit on the place a split brings that part back to.
    local PART_HOLD = JX_PART_NEAR
    local held = {}
    for _, g in ipairs(found) do
        if g.n ~= nil then
            for _, p in ipairs(g.parts or g.partsAside or {}) do held[#held + 1] = p end
        end
    end
    if #held > 0 then
        local keep = {}
        for _, f in ipairs(found) do
            local isPart = false
            if f.n == nil then
                for _, p in ipairs(held) do
                    if (p.x - f.x) ^ 2 + (p.z - f.z) ^ 2 <= PART_HOLD * PART_HOLD then isPart = true break end
                end
            end
            if not isPart then keep[#keep + 1] = f end
        end
        found = keep
    end
    local next_, gained = 1, false
    for _, f in ipairs(found) do
        if f.n == nil then
            while taken[next_] do next_ = next_ + 1 end
            f.n, taken[next_] = next_, true
            gained = true
            if #prev > 0 then added[#added + 1] = f end
        end
    end

    for _, f in ipairs(added) do
        if f.virgin then
            Logging.info("[FlyoverEditor]: junction j%02d is new, at %.1f, %.1f (%d lane ends, nothing joining them). Worth adding to the survey.",
                f.n, f.x, f.z, f.ends)
        else
            Logging.info("[FlyoverEditor]: junction j%02d is new, at %.1f, %.1f (%d fork points). Worth adding to the survey.",
                f.n, f.x, f.z, f.forks)
        end
    end
    if #prev == 0 then
        Logging.info("[FlyoverEditor]: junction - %d junction(s) on this map, numbered j01 to j%02d.",
            #found, #found)
    elseif fromFile ~= nil then
        -- Said once a session, and with the path: when a number on the card looks wrong, the first
        -- question is whether the file was read at all, and from which savegame.
        Logging.info("[FlyoverEditor]: junction - %d number(s) read from %s: %d found on the map, %d not found and kept, %d new.",
            #prev, fromFile, #found - nKept - #added, nKept, #added)
    end

    -- Saved when the registry GAINS a number, and only then: a number is the one thing that cannot
    -- be worked out again after a restart. Positions drift a little as a junction is cleared and
    -- rebuilt, but every form of it sits round the same crossing, well inside the match radius of
    -- where it was first written, so they are not worth a write. A save that fails (a career not
    -- yet saved has no folder) leaves the registry marked, and junctionRegistrySaveWaiting writes it
    -- once the folder is there.
    if gained then self._jxRegUnsaved = true end
    if self._jxRegUnsaved and junctionRegistrySave(found, self._jxRegHome) then
        self._jxRegUnsaved = false
    end

    self._jxReg, self._jxRegCount, self._jxRegNet = found, count, jxNetworkMark()
    return found
end

--- The registry entry of the junction at (x, z): the one with a saved part within JX_PART_NEAR of it,
--- if any; otherwise the one whose own point is nearest, within 30 m; nil when there is none.
---
--- A SAVED PART CLAIMS ONLY WHAT IS NEAR IT. 39se is 27 m from 39's own point, so a lock on 39se
--- that drifted a few metres further out would fall outside the 30 m and lose its number - the
--- part's claim keeps it. But counted out to 30 m like a junction's own point, a part took sites
--- that are not it: 39se is nearer than 30's own point to the Y that belongs to 30 (13.7 m against
--- 21.3 m), so that Y was called j39 and the card offered 39's decision buttons on it, where one
--- click would have undone 39's split. With no split saved this is the plain nearest point, as it
--- always was. A part set aside by "keep whole" or "not decided" claims the same - a lock there is
--- still that junction's, named by its bare number, and its card is the one that can split it back.
function ADFlyoverEditor:junctionEntryAt(x, z)
    if x == nil or z == nil then return nil end
    local reg = self:junctionRegistry() or {}
    -- In the registry's own order, and only a strictly nearer one replaces the best: a tie always
    -- goes the same way.
    local best, bestD = nil, JX_PART_NEAR * JX_PART_NEAR
    for _, f in ipairs(reg) do
        for _, p in ipairs(f.parts or f.partsAside or {}) do
            local d = (p.x - x) ^ 2 + (p.z - z) ^ 2
            if d < bestD then bestD, best = d, f end
        end
    end
    if best ~= nil then return best end
    bestD = 30 * 30
    for _, f in ipairs(reg) do
        local d = (f.x - x) ^ 2 + (f.z - z) ^ 2
        if d < bestD then bestD, best = d, f end
    end
    return best
end

--- The number of the junction nearest (x, z), or nil when there is none close enough to name.
function ADFlyoverEditor:junctionNumberAt(x, z)
    local f = self:junctionEntryAt(x, z)
    if f == nil then return nil end
    return f.n
end

--- The registry entry with number n, or nil.
function ADFlyoverEditor:junctionEntryOf(n)
    if n == nil then return nil end
    for _, f in ipairs(self:junctionRegistry() or {}) do
        if f.n == n then return f end
    end
    return nil
end

--- The parts of junction n as names ("j39nw", "j39", "j39se"), in map order: west to east where they
--- lie more east-west, north to south where they lie more north-south - the order the card lists
--- them in, whatever order they are saved in.
local function jxPartNames(n, parts)
    local list = {}
    for _, p in ipairs(parts or {}) do list[#list + 1] = p end
    local x0, x1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
    for _, p in ipairs(list) do
        x0, x1 = math.min(x0, p.x), math.max(x1, p.x)
        z0, z1 = math.min(z0, p.z), math.max(z1, p.z)
    end
    local byX = (x1 - x0) >= (z1 - z0)
    table.sort(list, function(a, b)
        if byX then
            if a.x ~= b.x then return a.x < b.x end
            return a.z < b.z
        end
        if a.z ~= b.z then return a.z < b.z end
        return a.x < b.x
    end)
    local names = {}
    for _, p in ipairs(list) do names[#names + 1] = string.format("j%02d%s", n, p.letter or "") end
    return names
end

--- "a and b", "a, b and c".
local function jxAndList(names)
    if #names <= 1 then return names[1] or "" end
    return table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
end

--- WHAT TO CALL A LOCKED SITE. (x, z) is where the selection locked it; virgin says it is a cleared
--- site. Returns the name ("j39se", or "j39" - also for every junction that is not split), the
--- number, the saved part it is (or nil), the saved parts the lock covers, and a note for the card
--- when the lock is not on exactly one part. Nil when no junction is close enough to name.
---
--- Only a SAVED split names a part. A suggestion is only a suggestion: until the user splits a
--- junction its parts have no names to give.
---
--- THE PART A LOCK IS AT is the nearest one, if it is within JX_PART_AT. A WIRED lock is only ever
--- that part, or none.
---
--- A CLEARED lock can also stand for other parts: where both halves were cleared together they
--- share one middle (72, 73 - 2.6 m from one half and 8.7 m from the other), and a click on either
--- half locks that one middle. So a cleared lock also covers each other part that is within the
--- radius a cleared site's lanes are read out to (JUNCTION_CLEARED_READ_R) AND where a click on the
--- part itself locks this same cleared site. Distance alone was not enough: 26n's saved point sits
--- 15.06 m from cleared 26s's middle, so 6 cm decided between "j26s" and "covers j26n and j26s" -
--- and decided it the same way whether 26n was still wired or had gone with 26s's clear. A part
--- that is still wired, or has a cleared site of its own, locks something else when clicked, so it
--- is never covered by a neighbour's clear however close it is; one that went with the clear is
--- covered whenever it is inside the radius.
function ADFlyoverEditor:junctionNameAt(x, z, virgin)
    local f = self:junctionEntryAt(x, z)
    if f == nil then return nil end
    local base = string.format("j%02d", f.n)
    if f.decision ~= "split" or f.parts == nil then return base, f.n, nil, {}, nil end
    -- f.parts is in its fixed saved order, and only a strictly nearer part replaces the best, so a
    -- tie always goes the same way.
    local at, atD = nil, math.huge
    for _, p in ipairs(f.parts) do
        local d = (p.x - x) ^ 2 + (p.z - z) ^ 2
        if d < atD then atD, at = d, p end
    end
    if atD > JX_PART_AT * JX_PART_AT then at = nil end
    local covers = {}
    for _, p in ipairs(f.parts) do
        local inside = (p == at)
        if not inside and virgin
            and (p.x - x) ^ 2 + (p.z - z) ^ 2 <= JUNCTION_CLEARED_READ_R * JUNCTION_CLEARED_READ_R then
            -- the selection a click on the part would make, asked of the network as it is now
            local s = self:junctionSelect(p.x, p.z)
            inside = (s ~= nil and s.virgin == true and (s.x - x) ^ 2 + (s.z - z) ^ 2 <= 1)
        end
        if inside then covers[#covers + 1] = p end
    end
    if #covers == 1 then return base .. covers[1].letter, f.n, covers[1], covers, nil end
    if #covers == 0 then
        return base, f.n, nil, covers, string.format("not at one of %s's parts", base)
    end
    -- Two or more: a cleared site whose halves share one middle (72, 73). Which half is meant can
    -- only be said by a click on it, and that is not built yet - so it is named by its number and
    -- the card says what it covers.
    return base, f.n, nil, covers, "covers " .. jxAndList(jxPartNames(f.n, covers))
end

--- Name the site jp was locked on (jp.lockedAt, jp.lockedVirgin, set by the preview) and say what the
--- user has decided about it: sets jp.junctionName, junctionPart, junctionCovers, junctionNameNote,
--- junctionDecision, on a split junctionSplitNames, and otherwise junctionNamesAside when it has
--- names set aside. Cheap - a look in the registry, and on a cleared lock of a split junction at most
--- one selection a part - so it is run again straight after a decision without solving the preview
--- again.
function ADFlyoverEditor:junctionNameSite(jp)
    if jp == nil then return end
    jp.junctionName, jp.junctionPart, jp.junctionCovers, jp.junctionNameNote = nil, nil, nil, nil
    jp.junctionDecision, jp.junctionSplitNames, jp.junctionNamesAside = nil, nil, nil
    local at = jp.lockedAt
    if at == nil then return end
    local name, n, part, covers, note = self:junctionNameAt(at.x, at.z, jp.lockedVirgin == true)
    jp.junctionName, jp.junctionPart, jp.junctionCovers, jp.junctionNameNote = name, part, covers, note
    local f = self:junctionEntryOf(n)
    if f ~= nil then
        jp.junctionDecision = f.decision
        if f.decision == "split" then jp.junctionSplitNames = jxPartNames(f.n, f.parts) end
        -- the names a split would bring back (set aside by "keep whole" or "not decided")
        if f.decision ~= "split" and f.partsAside ~= nil then
            jp.junctionNamesAside = jxPartNames(f.n, f.partsAside)
        end
    end
end

--- A decision taken: saved at once, beside the numbers, and said in the log. Where the career has
--- never been saved there is no folder to save into, so it is kept in memory and written as soon as
--- the first save makes the folder (junctionRegistrySaveWaiting). The card is named again.
local function jxDecisionTaken(self, n, said)
    local ok, path = junctionRegistrySave(self:junctionRegistry() or {}, self._jxRegHome)
    if ok then
        Logging.info("[FlyoverEditor]: junction j%02d - %s, saved to %s", n, said, tostring(path))
    else
        self._jxRegUnsaved = true
        Logging.info("[FlyoverEditor]: junction j%02d - %s, kept until the game is saved once", n, said)
    end
    if self.junctionPreview ~= nil then
        tryCall("junction name", function() self:junctionNameSite(self.junctionPreview) end)
    end
    -- AND THE PREVIEW IS WORKED OUT AGAIN. A split changes what the clear does, not only what the
    -- card calls the site: a lane from one part's side road to another part's is a connector, not a
    -- through road ("A LANE FROM THIS PART'S SIDE ROAD TO ANOTHER PART'S", in updateJunctionPreview).
    -- The preview is only redone when its key changes, and the key knows nothing of decisions; the
    -- buttons only show once a click has locked the site, so the usual order is lock, split, clear -
    -- and that clear used the through roads read before the split. At j39 it came out right only
    -- because the clear's own cleaning happened to change the site and force a new reading.
    self.junctionPreviewKey = nil
end

--- THE USER'S DECISION ON SPLITTING JUNCTION n: "split", "whole", or nil for not decided (which is
--- how a decision is undone). Returns true when the decision was taken.
---
--- THE PARTS' NAMES ARE NEVER LOST BY A CHANGE OF MIND. "Keep whole" and "not decided" set a split's
--- parts aside (f.partsAside, saved in the file with them) instead of throwing them away, and a split
--- brings them back exactly as they were - the same names on the same places. Thrown away, one click
--- erased the saved parts on disk for good, and splitting again lettered the places the roads meet
--- NOW: with 39se cleared that is two places, lettered by the two-part rule, so the user's "j39se"
--- landed on what had been j39. Only junctionForgetParts lets them go.
---
--- With no parts set aside, a split takes the parts the card offered for the locked site
--- (jp.junctionOffer) with the names it showed. A junction already split stays as it is: its parts
--- are only ever moved on purpose (not decided, forget the names, then split).
function ADFlyoverEditor:junctionDecide(n, decision)
    local f = self:junctionEntryOf(n)
    if f == nil then return false end
    local said
    if decision == "split" then
        if f.decision == "split" then
            Logging.info("[FlyoverEditor]: junction j%02d - already split into %s; nothing changed.",
                n, table.concat(jxPartNames(n, f.parts), ", "))
            return false
        end
        local parts
        if f.partsAside ~= nil and #f.partsAside >= 2 then
            parts = f.partsAside
            said = "split again into " .. table.concat(jxPartNames(n, parts), ", ") .. ", the names it had before"
        else
            local jp = self.junctionPreview
            local offer = nil
            if jp ~= nil and jp.junctionNumber == n then offer = jp.junctionOffer end
            if offer == nil or offer.parts == nil or #offer.parts < 2 then
                Logging.info("[FlyoverEditor]: junction j%02d - not split: the card has no named parts to split it into.", n)
                return false
            end
            parts = {}
            for _, p in ipairs(offer.parts) do parts[#parts + 1] = { letter = p.letter, x = p.x, z = p.z } end
            jxSortParts(parts)
            said = "split into " .. table.concat(jxPartNames(n, parts), ", ")
        end
        f.decision, f.parts, f.partsAside = "split", parts, nil
    else
        if f.decision == "split" and f.parts ~= nil and #f.parts >= 2 then f.partsAside = f.parts end
        if decision == "whole" then
            f.decision, said = "whole", "kept whole"
        else
            f.decision, said = nil, "not decided (any earlier decision undone)"
        end
        f.parts = nil
        if f.partsAside ~= nil then
            said = said .. "; the names " .. table.concat(jxPartNames(n, f.partsAside), ", ")
                .. " are kept, for if it is split again"
        end
    end
    jxDecisionTaken(self, n, said)
    return true
end

--- FORGET THE NAMES junction n's parts had (the parts set aside by "keep whole" or "not decided"):
--- the one deliberate way to let them go, so the next split names the parts afresh from the card.
--- Not while it is split - those parts are in use. Returns true when they were forgotten.
function ADFlyoverEditor:junctionForgetParts(n)
    local f = self:junctionEntryOf(n)
    if f == nil or f.decision == "split" or f.partsAside == nil then return false end
    local names = jxPartNames(n, f.partsAside)
    f.partsAside = nil
    jxDecisionTaken(self, n, "the names " .. table.concat(names, ", ") .. " forgotten; a split names its parts afresh")
    return true
end

--- NUMBERS AND DECISIONS STILL WAITING FOR A FOLDER: a career that has never been saved has none,
--- so the registry stays marked unsaved. It used to be tried again only when the registry was built
--- again, which happens only when the network changes - so a decision made, the game saved and the
--- game quit without another edit was lost, although the card had said it would be kept until the
--- game was saved. Called from update() every frame, editor open or not; looks every 2 s, and only
--- while something is waiting.
---
--- ONLY FOR THE GAME IT WAS MADE IN. update() goes on reaching this table after the player has left
--- to the menu and loaded another savegame, until the editor files are sourced again; written then,
--- into whatever folder the game loaded NOW has, one career's numbers and decisions replaced
--- another's. So what is waiting is written only into the folder the numbers were read from, while
--- that game is still loaded, and is dropped the moment another game is (junctionRegistryCheckHome).
function ADFlyoverEditor:junctionRegistrySaveWaiting(dt)
    if not self._jxRegUnsaved or self._jxReg == nil then return end
    if not self:junctionRegistryCheckHome() then return end
    self._jxRegWaitMs = (self._jxRegWaitMs or 0) + (dt or 0)
    if self._jxRegWaitMs < 2000 then return end
    self._jxRegWaitMs = 0
    local ok, path = junctionRegistrySave(self._jxReg, self._jxRegHome)
    if ok then
        self._jxRegUnsaved = false
        Logging.info("[FlyoverEditor]: junction - numbers and split decisions saved to %s, now that the game has been saved once.",
            tostring(path))
    end
end

--- Recompute the junction preview around the cursor: the scope circle, the approaches it cuts, and
--- which entry->exit movements are new versus already connected. Stored on self.junctionPreview; nil
--- when there is nothing to show. Pure inspection - it changes no waypoints.
--- PLACE MODE (docs/junction-tool/08-place-junction.md): point at roads that cross and the card says what
--- would go there. The pattern is worked out dry - nothing changes until the right-click.
function ADFlyoverEditor:updatePlacePreview()
    local cx, cz
    if self.junctionArmed ~= nil then
        cx, cz = self.junctionArmed.cx, self.junctionArmed.cz
    elseif self.cursorX ~= nil then
        cx, cz = self.cursorX, self.cursorZ
    else
        self.junctionPreview, self.junctionPreviewKey = nil, nil
        return
    end
    local shape = self.junctionPattern or "exact"
    -- ONLY ON A JUNCTION (in-game test 2026-10-05): place works on junctions the clear knows, picked the
    -- clear's way. Anywhere else it does nothing and says so - no piece sliding about under the cursor,
    -- and nothing worked out at every step of the mouse. The pick itself is remembered per 2 m of cursor
    -- travel, so pointing around inside one junction costs nothing.
    local selKey = string.format("%d_%d_%d", math.floor(cx / 2), math.floor(cz / 2), ADGraphManager:getWayPointsCount())
    local site = nil
    if self.placeSelectKey == selKey then
        site = self.placeSelectSite
    else
        tryCall("junction place: which junction", function() site = self:junctionSelect(cx, cz) end)
        -- A cleared junction the clear's finder no longer sees (an X cleared with its through roads kept has
        -- no lane ends at all): the numbered list keeps every junction's place, and that anchors it.
        if site == nil then
            tryCall("junction place: numbered list", function()
                local bd = 15 * 15
                for _, e in ipairs(self:junctionRegistry() or {}) do
                    local d = (e.x - cx) ^ 2 + (e.z - cz) ^ 2
                    if d < bd then site, bd = { x = e.x, z = e.z, virgin = true, n = e.n }, d end
                end
            end)
        end
        self.placeSelectKey, self.placeSelectSite = selKey, site
    end
    if site == nil or site.x == nil then
        self.junctionPreview = { placeMode = true, cx = cx, cz = cz, cy = self.cursorY or 0, shape = shape, ok = false,
            why = "point at a junction - place works on junctions the clear knows" }
        self.junctionPreviewKey = nil
        return
    end
    -- THE CLICK PICKS THE JUNCTION, as in the clear: pointing anywhere on it, the piece is worked out from
    -- the junction's own centre, so where you click and how the camera looks at it can't change what is
    -- placed (in game j3 gave different answers from different clicks).
    cx, cz = site.x, site.z
    -- TURN WIRING STILL HERE: place never deletes anything, so it refuses exactly where the clear would
    -- find something to take out - the clear's own finder decides, so the two always agree. (A fork alone
    -- is no sign of it: a two-way road splitting into its two lanes is a fork too.)
    if not site.virgin then
        self.junctionPreview = { placeMode = true, cx = cx, cz = cz, shape = shape, ok = false, wired = true,
            cy = AutoDrive:getTerrainHeightAtWorldPos(cx, cz) or 0,
            why = "turn wiring is still here - clear the junction first" }
        self.junctionPreviewKey = nil
        return
    end
    local key = string.format("place_%.1f_%.1f_%s_%s_%d", cx, cz, shape,
        tostring(self.junctionArmed ~= nil), ADGraphManager:getWayPointsCount())
    if key == self.junctionPreviewKey and self.junctionPreview ~= nil then return end
    self.junctionPreviewKey = key    local okCall, res, why, wired = tryCall("junction place preview", function()
        return junctionPlacePattern(cx, cz, 15, shape, true)
    end)
    -- Ground heights for the drawing, once per preview rather than every frame.
    local function ground(p) p.y = AutoDrive:getTerrainHeightAtWorldPos(p.x, p.z) or 0 end
    if okCall and res ~= nil then
        for _, line in ipairs(res.lines or {}) do for _, p in ipairs(line.pts) do ground(p) end end
        for _, p in ipairs(res.marks or {}) do ground(p) end
        for _, p in ipairs(res.loose or {}) do ground(p) end
    end
    self.junctionPreview = {
        placeMode = true, cx = cx, cz = cz, cy = AutoDrive:getTerrainHeightAtWorldPos(cx, cz) or 0, shape = shape,
        ok = okCall and res ~= nil, plan = res,
        why = (not okCall) and "it failed - see the log" or why, wired = wired == true,
    }
end

--- KEPT THROUGH THE GAME'S OWN SAVE. FS25 saves by writing the savegame folder afresh: a file it did
--- not write during that save is gone afterwards. The junction numbers and split decisions were such
--- a file (2026-10-06: a save at 17:48 left savegame6 without ADFlyoverEditor_junctions.xml, the next
--- numbering found no file, and the user's 16 decisions survived only in the game's own backup in
--- savegameBackup). AutoDrive keeps its route file the way this does: written during the game's save
--- (ItemSystem.save), into the folder the game is saving.
---
--- What is written then: the registry as built in this game, or - when the junction tool has not been
--- used in this game - the file as it was when the game loaded, held here, so a game saved without
--- ever opening the tool keeps them too. Read again whenever another game (or folder) is loaded.
function ADFlyoverEditor:junctionRegistryKeepFile(dt)
    if g_currentMission == nil then return end
    self._jxRegFileMs = (self._jxRegFileMs or 1000) + (dt or 0)
    if self._jxRegFileMs < 1000 then return end
    self._jxRegFileMs = 0
    if self._jxRegFileHome ~= nil and jxHomeIsHere(self._jxRegFileHome) then return end
    local home = jxHomeNow()
    if home.folder == nil then return end
    local list = junctionRegistryLoad(home)
    if list == nil then list = false end
    self._jxRegFile, self._jxRegFileHome = list, home
end

function ADFlyoverEditor:junctionRegistryOnGameSave()
    if g_currentMission == nil or g_server == nil then return end
    self:junctionRegistryCheckHome()
    local list, what = nil, nil
    if self._jxReg ~= nil and self._jxRegHome ~= nil and self._jxRegHome.mission == g_currentMission then
        list, what = self._jxReg, "as numbered in this game"
    elseif self._jxRegFile and self._jxRegFileHome ~= nil and self._jxRegFileHome.mission == g_currentMission then
        list, what = self._jxRegFile, "as read when the game loaded"
    end
    if list == nil then return end
    -- The folder the game is saving now, worked out as AutoDrive works out its own (junctionRegistryFolder).
    local folder = junctionRegistryFolder()
    if folder == nil then return end
    local path = folder .. JUNCTION_REGISTRY_FILE
    local ok, err = ADFlyoverEditor.junctionRegistryWriteFile(path, list)
    if not ok then
        Logging.warning("[FlyoverEditor]: junction - could not write the numbers with the game's save (%s): %s",
            path, tostring(err))
        return
    end
    if list == self._jxReg then self._jxRegUnsaved = false end
    local decided = 0
    for _, f in ipairs(list) do
        if f.decision ~= nil then decided = decided + 1 end
    end
    Logging.info("[FlyoverEditor]: junction - %d junction number(s) and %d split decision(s) written with the game's save (%s): %s",
        #list, decided, what, path)
end

-- Into the game's save, once however often the editor files are sourced again; the editor table is
-- looked up when the game saves, so a re-sourced editor's function is the one called. Never lets a
-- failure here stop the game's own save.
if ItemSystem ~= nil and type(ItemSystem.save) == "function" and not ItemSystem.__adFlyoverJunctionsHooked then
    ItemSystem.__adFlyoverJunctionsHooked = true
    local gameSave = ItemSystem.save
    ItemSystem.save = function(...)
        if ADFlyoverEditor ~= nil and ADFlyoverEditor.junctionRegistryOnGameSave ~= nil then
            local ok, err = pcall(ADFlyoverEditor.junctionRegistryOnGameSave, ADFlyoverEditor)
            if not ok then
                Logging.warning("[FlyoverEditor]: junction - writing the numbers with the game's save failed: %s", tostring(err))
            end
        end
        return gameSave(...)
    end
end

-- MODSPLIT: SHARED WITH THE FILES LOADED AFTER THIS ONE (tools/modsplit/split.py writes this block)
ADFlyoverEditor.shared.JUNCTION_CLEARED_READ_R = JUNCTION_CLEARED_READ_R
ADFlyoverEditor.shared.JX_PART_AT = JX_PART_AT
ADFlyoverEditor.shared.JX_PART_NEAR = JX_PART_NEAR
ADFlyoverEditor.shared.jxPartNames = jxPartNames
ADFlyoverEditor.shared.jxSortParts = jxSortParts
-- MODSPLIT: end of the shared block

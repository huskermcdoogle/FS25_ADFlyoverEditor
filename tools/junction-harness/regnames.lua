-- WHAT A LOCKED SITE IS CALLED, once the user has split junctions: one scenario a run, for regnames.sh.
-- All but `copy` and `badfile` need REGDIR=<folder with an ADFlyoverEditor_junctions.xml holding the
-- decisions> (split_registry.lua makes one), so the editor reads the decisions as the game does.
--
--   lua regnames.lua lock X Z      lock the site at (X, Z): the clear, or - where the clear refuses it
--                                  as already clear - build, as a cleared site is only ever seen in
--                                  build. Prints  NAME <name> [| <note>]
--   lua regnames.lua gone          clear 39se, then lock 39 and 39nw in the same run. Prints a NAME
--                                  line for each, NEW for any "is new" line in the log, and MAXN, the
--                                  highest number in the registry afterwards
--   lua regnames.lua gonecheck     clear 39nw, then 39se: prints CHECK lines with what each check
--                                  after the clear names the other parts' wiring
--   lua regnames.lua moved D       move 39se's SAVED part D metres east (as if its crossing had moved
--                                  since it was saved), then lock 39se. Prints NAME
--   lua regnames.lua near D        clear 20s without through roads (20n stays wired), move 20n's SAVED
--                                  part D metres south - towards the cleared 20s - and lock 20s again.
--                                  Prints NAME and DIST, how far the moved part is from the lock
--   lua regnames.lua clear26 D     clear 26s without through roads (26n's turns are left working, so
--                                  26n stays wired), move 26n's SAVED part D metres south and lock 26s
--                                  again. Prints NAME and DIST
--   lua regnames.lua hover         the card at 20s, first only pointed at (no click), then locked.
--                                  Prints ROW lines: whether the decision buttons are on the card
--   lua regnames.lua firstsave DIR a decision made before the career was ever saved - its folder
--                                  worked out from the slot number (DIR/savegame7, which must exist
--                                  and be empty), then the game's first save names that folder
--                                  outright: prints SAVED lines and what the file then says
--   lua regnames.lua switch DIR    a decision waiting for career A's first save (DIR/A, empty), then
--                                  another game loaded (DIR/B: careerSavegame.xml and a junction
--                                  file). Prints SWITCH lines: B's file untouched, B's own names
--   lua regnames.lua switchfolder DIR  the same, but the same game with its folder now DIR/C
--   lua regnames.lua decide1 DIR   DIR: careerSavegame.xml and the user's file. 39se cleared, then
--                                  39 kept whole, not decided and split again: prints FILE, SAME,
--                                  NAME and ROW lines. Leaves 39 kept whole, for decide2
--   lua regnames.lua decide2 DIR   a restart on what decide1 left: split, keep whole, forget the
--                                  names, split again
--   lua regnames.lua copy IN OUT   read IN and write OUT with the editor's own reader and writer
--   lua regnames.lua badfile DIR   write a hand-broken junction file into DIR, read it, and print what
--                                  was kept of each junction and every warning (the reader's checks)
--
-- LEAVE=1|0 is the through-roads setting for the clear (default 1); the name does not depend on it.
local mode = arg[1]

local function editorOnly()
    dofile("xmlstub.lua")
    WARNED = {}
    Logging = {
        info = function() end,
        warning = function(fmt, ...) WARNED[#WARNED + 1] = string.format(fmt, ...) end,
        error = function(fmt, ...) WARNED[#WARNED + 1] = "ERR " .. string.format(fmt, ...) end,
    }
    AutoDrive = AutoDrive or {}
    dofile("editor_load.lua")()
    return ADFlyoverEditor
end

if mode == "copy" then
    local E = editorOnly()
    local list, err = E.junctionRegistryReadFile(arg[2])
    if list == nil then error("could not read " .. tostring(arg[2]) .. ": " .. tostring(err)) end
    local ok, werr = E.junctionRegistryWriteFile(arg[3], list)
    if not ok then error("could not write " .. tostring(arg[3]) .. ": " .. tostring(werr)) end
    for _, w in ipairs(WARNED) do print("WARN " .. w) end
    return
end

if mode == "badfile" then
    local E = editorOnly()
    local path = arg[2] .. "/bad.xml"
    local f = assert(io.open(path, "wb"))
    f:write(table.concat({
        '<?xml version="1.0" encoding="utf-8" standalone="no"?>',
        '<flyoverEditor>',
        '    <junctions>',
        -- fine: three parts, written out of order
        '        <junction n="1" x="0.000000" z="0.000000" decision="split">',
        '            <part name="1nw" x="-10.000000" z="-10.000000"/>',
        '            <part name="1" x="0.000000" z="0.000000"/>',
        '            <part name="1se" x="10.000000" z="10.000000"/>',
        '        </junction>',
        -- one part of another number, one with no x, one twice: two good parts are left
        '        <junction n="2" x="100.000000" z="0.000000" decision="split">',
        '            <part name="2n" x="100.000000" z="-10.000000"/>',
        '            <part name="3s" x="100.000000" z="10.000000"/>',
        '            <part name="2s" z="10.000000"/>',
        '            <part name="2n" x="101.000000" z="-11.000000"/>',
        '            <part name="2s" x="100.000000" z="10.000000"/>',
        '        </junction>',
        -- a letter that is not a compass point, an empty name: one good part, so not decided
        '        <junction n="3" x="200.000000" z="0.000000" decision="split">',
        '            <part name="3up" x="200.000000" z="-10.000000"/>',
        '            <part name="" x="200.000000" z="10.000000"/>',
        '            <part name="3e" x="210.000000" z="0.000000"/>',
        '        </junction>',
        -- a decision this version does not know
        '        <junction n="4" x="300.000000" z="0.000000" decision="maybe"/>',
        -- kept whole; its one stray part is too few to split back into, so it is left out
        '        <junction n="5" x="400.000000" z="0.000000" decision="whole">',
        '            <part name="5n" x="400.000000" z="-10.000000"/>',
        '        </junction>',
        '        <junction n="6" x="500.000000" z="0.000000"/>',
        -- kept whole, and not decided: the names its parts had when it was split, set aside
        '        <junction n="7" x="600.000000" z="0.000000" decision="whole">',
        '            <part name="7s" x="600.000000" z="10.000000"/>',
        '            <part name="7n" x="600.000000" z="-10.000000"/>',
        '        </junction>',
        '        <junction n="8" x="700.000000" z="0.000000">',
        '            <part name="8w" x="690.000000" z="0.000000"/>',
        '            <part name="8e" x="710.000000" z="0.000000"/>',
        '        </junction>',
        '    </junctions>',
        '</flyoverEditor>', '' }, "\r\n"))
    f:close()
    local list = E.junctionRegistryReadFile(path)
    for _, j in ipairs(list or {}) do
        local parts = {}
        for _, p in ipairs(j.parts or {}) do
            parts[#parts + 1] = string.format("%d%s@%.0f,%.0f", j.n, p.letter, p.x, p.z)
        end
        local aside = {}
        for _, p in ipairs(j.partsAside or {}) do
            aside[#aside + 1] = string.format("%d%s@%.0f,%.0f", j.n, p.letter, p.x, p.z)
        end
        local a = ""
        if #aside > 0 then a = " | aside " .. table.concat(aside, " ") end
        print(string.format("READ j%d %s %s%s", j.n, tostring(j.decision), table.concat(parts, " "), a))
    end
    print(string.format("WARNINGS %d", #WARNED))
    for _, w in ipairs(WARNED) do print("  " .. w) end
    return
end

LOG_ECHO = false
local H = dofile("harness.lua")
local E = ADFlyoverEditor
local leave = os.getenv("LEAVE") ~= "0"
local ALL = {}
local function keep()
    for _, l in ipairs(LOG) do ALL[#ALL + 1] = l end
end

local function lockAt(x, z)
    local jp = H.lock(x, z, { mode = "clear", radius = 12, leaveThrough = leave })
    keep()
    if jp == nil and tostring(E.junctionRefused):find("already clear") then
        jp = H.lock(x, z, { mode = "build", radius = 15, leaveThrough = false })
        keep()
    end
    return jp
end

local function say(jp, tag)
    if jp == nil then
        print(string.format("NAME%s (no lock: %s)", tag or "", tostring(E.junctionRefused)))
        return
    end
    local note = ""
    if jp.junctionNameNote ~= nil then note = " | " .. jp.junctionNameNote end
    print(string.format("NAME%s %s%s", tag or "", tostring(jp.junctionName), note))
end

-- THE CARD as the game draws it (FlyoverHud.lua's own rows). Prints
--   ROW <tag> <junction row> | <live decision buttons, or none> | <notes under it> [| button: <b>]
-- the last only when the card has a button there (only "forget these names" is one).
local hudLoaded = false
local function loadHud()
    if hudLoaded then return end
    g_screenAspectRatio = 16 / 9
    dofile("../../scripts/editor/FlyoverHud.lua")
    ADEditorHistory.canUndo = function() return false end
    ADEditorHistory.canRedo = function() return false end
    ADEditorHistory.depth = function() return 0 end
    E.selectionCount = E.selectionCount or 0
    E.placedCount = E.placedCount or 0
    hudLoaded = true
end
local function rowSay(tag)
    loadHud()
    local rows = ADFlyoverHud:buildRows(E)
    local name, dec, notes, btns, on = "?", "no decision buttons", {}, {}, false
    for _, r in ipairs(rows) do
        if r.kind == "toggle" and r.text == "junction" then name, on = tostring(r.value), true
        elseif r.kind == "toggle" and on and r.text ~= "type" then on = false end
        if r.kind == "seg" and r.text == "decision" then
            local live = {}
            for _, o in ipairs(r.options) do
                if o.action ~= nil then live[#live + 1] = o.label end
            end
            dec = "decision buttons: " .. table.concat(live, ", ")
        end
        if on and r.kind == "note" then notes[#notes + 1] = tostring(r.text) end
        if on and r.kind == "btn" and r.action ~= nil then btns[#btns + 1] = tostring(r.text) end
    end
    local b = ""
    if #btns > 0 then b = " | button: " .. table.concat(btns, ", ") end
    print(string.format("ROW %s %s | %s | %s%s", tag, name, dec, table.concat(notes, " / "), b))
    return rows
end

-- What a junction file says about junction n: its decision, the parts in use and the parts set
-- aside, by name. With `at`, each part's place as well, to the file's own six decimals.
local function fileSays(path, n, at)
    for _, j in ipairs(E.junctionRegistryReadFile(path) or {}) do
        if j.n == n then
            local function list(ps)
                local t = {}
                for _, p in ipairs(ps or {}) do
                    if at then
                        t[#t + 1] = string.format("%d%s@%.6f,%.6f", n, p.letter, p.x, p.z)
                    else
                        t[#t + 1] = string.format("%d%s", n, p.letter)
                    end
                end
                return table.concat(t, " ")
            end
            return string.format("%s | in use: %s | aside: %s", tostring(j.decision or "not decided"),
                list(j.parts), list(j.partsAside)), list(j.parts or j.partsAside)
        end
    end
    return "no junction " .. tostring(n), ""
end

local function readBytes(path)
    local f = io.open(path, "rb")
    if f == nil then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

-- The numbers in a junction file: n -> { x, z, said = its decision and parts by name }.
local function numbersIn(path)
    local t = {}
    for _, j in ipairs(E.junctionRegistryReadFile(path) or {}) do
        t[j.n] = { x = j.x, z = j.z, said = (fileSays(path, j.n)) }
    end
    return t
end

-- The game leaving to the menu and loading another savegame: a new mission, with that savegame's
-- folder. This editor table is the old one, as in the game until its files are sourced again.
local function loadAnotherGame(folder)
    local m = {}
    for k, v in pairs(g_currentMission) do m[k] = v end
    m.missionInfo = { savegameDirectory = folder }
    g_currentMission = m
end

if mode == "lock" then
    say(lockAt(tonumber(arg[2]), tonumber(arg[3])))
elseif mode == "gone" then
    local jp = lockAt(22.5, 0.1)
    say(jp, " cleared")
    if jp == nil or not jp.clearMode then error("39se did not lock for a clear") end
    H.apply()
    keep()
    say(lockAt(6.9, -13.6), " 39")
    say(lockAt(-15.0, -24.5), " 39nw")
    for _, l in ipairs(ALL) do
        if l:find("is new, at") then print("NEW " .. l) end
    end
    local maxN = 0
    for _, f in ipairs(E:junctionRegistry() or {}) do maxN = math.max(maxN, f.n or 0) end
    print("MAXN " .. maxN)
elseif mode == "gonecheck" then
    -- The check after a clear, once a part has gone: clear 39nw, then 39se. What 39se's check
    -- calls the wiring left at 39 must be j39 - lettered afresh from the two places left, it was
    -- "j39nw". Prints CHECK <lock name> (<summary line's name>) parts: <each part named>
    for _, xz in ipairs({ { -15.0, -24.5 }, { 22.5, 0.1 } }) do
        local jp = lockAt(xz[1], xz[2])
        if jp == nil or not jp.clearMode then error("no clear locked at " .. xz[1] .. ", " .. xz[2]) end
        local log = H.apply()
        local summary, names = "?", {}
        for _, l in ipairs(log) do
            summary = l:match("check after the clear %(([^)]+)%)") or summary
            if l:find("junction %- check: ") then
                -- "j39's own wiring", or - since 2026-10-05, where the check followed that part's
                -- turn end to end - "j39's turn, left working"
                local nm = l:match(" %- ([^-]-)'s own wiring") or l:match(" %- ([^-]-)'s turn, left working")
                if nm ~= nil then names[#names + 1] = nm end
            end
        end
        print(string.format("CHECK %s (%s) parts: %s", tostring(jp.junctionName), summary, table.concat(names, ", ")))
    end
elseif mode == "moved" then
    local d = tonumber(arg[2]) or 0
    local f = E:junctionEntryOf(39)
    if f == nil or f.decision ~= "split" then error("j39 is not saved as split in REGDIR's file") end
    for _, p in ipairs(f.parts) do
        if p.letter == "se" then p.x = p.x + d end
    end
    say(lockAt(22.5, 0.1))
elseif mode == "near" or mode == "clear26" then
    -- A cleared part beside one that is not cleared with it. The saved point of the other part is
    -- moved closer (D m south), standing in for a cleared middle that came to rest nearer to it:
    -- within the 15 m a cleared site is read out to, the other part is covered only when a click on
    -- it locks this same cleared site - never while it is still wired (20n), as distance alone had it.
    local d = tonumber(arg[2]) or 0
    local n, clearAt, other = 20, { -947.0, 46.0 }, "n"
    if mode == "clear26" then n, clearAt = 26, { -933.8, 493.3 } end
    local jp = H.lock(clearAt[1], clearAt[2], { mode = "clear", radius = 12, leaveThrough = false })
    if jp == nil or not jp.clearMode then error("no clear locked at " .. clearAt[1] .. ", " .. clearAt[2]) end
    H.apply()
    local f = E:junctionEntryOf(n)
    if f == nil or f.decision ~= "split" then error("j" .. n .. " is not saved as split in REGDIR's file") end
    local moved = nil
    for _, p in ipairs(f.parts) do
        if p.letter == other then p.z = p.z + d moved = p end
    end
    local jp2 = H.lock(clearAt[1], clearAt[2], { mode = "build", radius = 15, leaveThrough = false })
    say(jp2)
    if jp2 ~= nil and jp2.lockedAt ~= nil and moved ~= nil then
        print(string.format("DIST %.2f", math.sqrt((moved.x - jp2.lockedAt.x) ^ 2 + (moved.z - jp2.lockedAt.z) ^ 2)))
    end
elseif mode == "hover" then
    -- The card's decision buttons only for a junction a click has locked: pointed at, the preview
    -- follows the cursor, and a click on a button would save a decision for whatever the mouse last
    -- passed over on its way to the panel.
    loadHud()
    -- pointed at: what the preview does with no click - follows the cursor
    local function pointAt(x, z)
        H.lock(x, z, { mode = "clear", radius = 12, leaveThrough = true })
        E.junctionArmed, E.junctionPreviewKey, E.junctionPreview = nil, nil, nil
        E:updateJunctionPreview()
    end
    pointAt(-947.0, 46.0)
    rowSay("pointed")
    -- clicked
    H.lock(-947.0, 46.0, { mode = "clear", radius = 12, leaveThrough = true })
    rowSay("locked")
    -- a junction kept whole, pointed at: what was decided, still no buttons
    local f30 = E:junctionEntryOf(30)
    pointAt(f30.x, f30.z)
    rowSay("pointed30")
elseif mode == "firstsave" then
    -- A career never saved has no folder for the file: the decision is kept in memory and written
    -- once the game's first save has made the folder - not only when the network next changes. As
    -- the game has it: until that save the folder is worked out from the slot number (savegame7 in
    -- the profile folder, DIR here), and the save then names it outright (savegameDirectory) - the
    -- same folder, so what is waiting is written there. No junction file yet, so the numbers are the
    -- harness's own.
    local dir = arg[2]
    local save7 = dir .. "/savegame7"
    getUserProfileAppPath = function() return dir .. "/" end
    g_currentMission.missionInfo = { savegameIndex = 7 }
    local jp = lockAt(22.5, 0.1)
    if jp == nil or jp.junctionNumber == nil then error("no numbered lock at 22.5, 0.1") end
    local n = jp.junctionNumber
    LOG = {}
    E:junctionDecide(n, "whole")
    for _, l in ipairs(LOG) do if l:find("junction j") then print("DECIDED " .. l) end end
    E:update(2500)
    print("SAVED before the first save: " .. tostring(fileExists(save7 .. "/ADFlyoverEditor_junctions.xml")))
    -- the game's first save (regnames.sh has made the folder)
    local f = assert(io.open(save7 .. "/careerSavegame.xml", "wb"))
    f:write("<careerSavegame/>\n")
    f:close()
    g_currentMission.missionInfo.savegameDirectory = save7
    LOG = {}
    E:update(2500)
    print("SAVED after the first save: " .. tostring(fileExists(save7 .. "/ADFlyoverEditor_junctions.xml")))
    for _, l in ipairs(LOG) do if l:find("saved to") then print("LOGGED " .. l:gsub(" to .-, now", " to <dir>, now")) end end
    for _, j in ipairs(E.junctionRegistryReadFile(save7 .. "/ADFlyoverEditor_junctions.xml") or {}) do
        if j.n == n then print("FILE the locked junction " .. tostring(j.decision)) end
    end
elseif mode == "switch" or mode == "switchfolder" then
    -- A DECISION WAITING FOR A FIRST SAVE, AND THEN ANOTHER GAME. Career A (DIR/A) was never saved,
    -- so a decision made in it waits in memory. Then:
    --   switch        the player leaves to the menu and loads career B (DIR/B, saved, with its own
    --                 junction file - the user's numbers and decisions). The old editor goes on
    --                 getting update() until its files are sourced again.
    --   switchfolder  the same game, but its folder is now C (DIR/C, saved, its own file too).
    -- Either way what was waiting is A's, and must not be written into B or C. Prints SWITCH lines.
    local dir = arg[2]
    local A, other = dir .. "/A", dir .. "/B"
    if mode == "switchfolder" then other = dir .. "/C" end
    local otherFile = other .. "/ADFlyoverEditor_junctions.xml"
    g_currentMission.missionInfo = { savegameDirectory = A }
    local jp = lockAt(22.5, 0.1)
    if jp == nil or jp.junctionNumber == nil then error("no numbered lock at 22.5, 0.1") end
    LOG = {}
    E:junctionDecide(jp.junctionNumber, "whole")
    local waiting = false
    for _, l in ipairs(LOG) do if l:find("kept until the game is saved once") then waiting = true end end
    print("SWITCH waiting for A's first save: " .. tostring(waiting))
    local before = readBytes(otherFile)
    local numbersBefore = numbersIn(otherFile)
    if mode == "switch" then
        loadAnotherGame(other)
    else
        g_currentMission.missionInfo.savegameDirectory = other
    end
    LOG = {}
    E:update(2500)
    E:update(2500)
    print("SWITCH other file unchanged: " .. tostring(before ~= nil and readBytes(otherFile) == before))
    print("SWITCH written into A: " .. tostring(fileExists(A .. "/ADFlyoverEditor_junctions.xml")))
    local dropped = false
    for _, l in ipairs(LOG) do if l:find("are dropped, not written into this one") then dropped = true end end
    print("SWITCH said it was dropped: " .. tostring(dropped))
    -- The numbers in memory now are the other game's own: 39se is its part, as its file says.
    print("SWITCH name at 39se: " .. tostring((E:junctionNameAt(22.5, 0.1, false))))
    -- ...and a decision made there writes its numbers and decisions, not A's: every number where it
    -- was, every other junction decided as it was (20, 26, 14 and 40 still split, and so on).
    E:junctionDecide(39, "whole")
    local after, same, count = numbersIn(otherFile), true, 0
    for n, p in pairs(numbersBefore) do
        count = count + 1
        local q = after[n]
        if q == nil or (q.x - p.x) ^ 2 + (q.z - p.z) ^ 2 > 5 * 5 then same = false
        elseif n ~= 39 and q.said ~= p.said then same = false end
    end
    for n in pairs(after) do if numbersBefore[n] == nil then same = false end end
    print("SWITCH other keeps its numbers and decisions: " .. tostring(same and count > 0))
elseif mode == "decide1" or mode == "decide2" then
    -- A CHANGE OF MIND KEEPS THE NAMES. DIR is a saved career holding the user's file (39 split into
    -- j39nw, j39, j39se). 39se is cleared first, so what is left at 39 is two places, which a fresh
    -- lettering names by the two-part rule.
    --   decide1  keep whole, not decided, split: the same names at the same places come back; then
    --            keep whole again, which is how the file is left for decide2
    --   decide2  a restart (a new process reads that file): split brings the names back again; then
    --            keep whole, forget the names, and split takes the card's own offer
    -- Prints FILE lines (what the file on disk says about 39), SAME, NAME and the card's ROW lines.
    local dir = arg[2]
    local path = dir .. "/ADFlyoverEditor_junctions.xml"
    g_currentMission.missionInfo = { savegameDirectory = dir }
    local _, savedAt = fileSays(path, 39, true)
    local cleared = lockAt(22.5, 0.1)
    if cleared == nil or not cleared.clearMode then error("39se did not lock for a clear") end
    H.apply()
    local function file(tag)
        print("FILE " .. tag .. " " .. (fileSays(path, 39)))
    end
    local function same(tag)
        local _, now = fileSays(path, 39, true)
        print("SAME " .. tag .. " " .. tostring(now == savedAt and now ~= ""))
    end
    if mode == "decide1" then
        file("as saved")
        say(lockAt(6.9, -13.6), " 39")
        E:junctionDecide(39, "whole")
        file("kept whole")
        rowSay("kept whole")
        E:junctionDecide(39, nil)
        file("not decided")
        rowSay("not decided")
        E:junctionDecide(39, "split")
        file("split again")
        same("split again")
        say(lockAt(6.9, -13.6), " 39 split again")
        say(lockAt(-15.0, -24.5), " 39nw split again")
        E:junctionDecide(39, "whole")
        file("kept whole again")
    else
        file("after the restart")
        say(lockAt(6.9, -13.6), " 39")
        rowSay("restart")
        E:junctionDecide(39, "split")
        file("split after the restart")
        same("split after the restart")
        E:junctionDecide(39, "whole")
        local forgot = E.junctionForgetParts ~= nil and E:junctionForgetParts(39)
        print("FORGOT " .. tostring(forgot))
        file("forgotten")
        rowSay("forgotten")
        E:junctionDecide(39, "split")
        file("split as offered")
    end
else
    print("usage: see the top of regnames.lua")
    os.exit(1)
end

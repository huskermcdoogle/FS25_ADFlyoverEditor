-- THE JUNCTION NUMBERS AND SPLIT DECISIONS LIVE THROUGH THE GAME'S OWN SAVE (JxRegistry.lua,
-- junctionRegistryOnGameSave). FS25 saves by writing the savegame folder afresh, so a file it did not
-- write during that save is gone; on 2026-10-06 that took the user's 16 decisions. This plays it out:
-- the game's save (ItemSystem.save) is stood in for, the folder's junction file is deleted the way the
-- save drops it, and the hook must have written it back.
--   REGDIR=<a copy of a folder holding ADFlyoverEditor_junctions.xml> lua regsave.lua
-- Prints one line per case and "REGSAVE ok" or "REGSAVE FAIL".
ItemSystem = { save = function() GAME_SAVED = (GAME_SAVED or 0) + 1 end }
local H = dofile("harness.lua")
local E = ADFlyoverEditor
g_server = g_server or {}
local dir = assert(os.getenv("REGDIR"), "REGDIR not set")
local path = dir .. "/ADFlyoverEditor_junctions.xml"
local function read(p)
    local f = io.open(p, "rb")
    if f == nil then return nil end
    local s = f:read("*a")
    f:close()
    return s
end
local function decisions(s)
    local n = 0
    for _ in (s or ""):gmatch('decision="') do n = n + 1 end
    return n
end
local fails = 0
local function check(name, ok, detail)
    print(string.format("%-4s %s%s", ok and "ok" or "FAIL", name, detail and (" - " .. detail) or ""))
    if not ok then fails = fails + 1 end
end

check("the hook is in the game's save", ItemSystem.__adFlyoverJunctionsHooked == true)

-- 1. A game where the junction tool is never used: the file as read at load goes back.
local before = read(path)
E:junctionRegistryKeepFile(1000)
os.remove(path)
ItemSystem.save()
local after = read(path)
check("never used: the file is written back", after ~= nil)
check("never used: the same numbers and decisions", after ~= nil and decisions(after) == decisions(before),
    string.format("%d decision(s) before, %d after", decisions(before), decisions(after)))
check("never used: the game's own save still ran", GAME_SAVED == 1)

-- 2. The tool numbers the junctions and a decision changes; the save writes the new one.
E:junctionRegistry()
local n, was
for _, f in ipairs(E._jxReg or {}) do
    if f.decision == "split" then n, was = f.n, f.decision break end
end
check("a split junction to change", n ~= nil)
if n ~= nil then
    E:junctionDecide(n, "whole")
    os.remove(path)
    ItemSystem.save()
    local s = read(path)
    check("after a decision: the file is written back", s ~= nil)
    local line = s and s:match('<junction n="' .. n .. '"[^>]*>') or ""
    check("after a decision: the new decision is in it", line:find('decision="whole"') ~= nil, line)
end

-- 2b. The folder the game reads during its save is not the one the numbers were read from (as in game
-- on 2026-10-06: the first hooked save wrote the file "as read when the game loaded", dropping what that
-- session had built). The numbers as built - with the decision just changed - must still be written,
-- into the folder of the save, and still be in memory afterwards.
if n ~= nil then
    local during = dir .. "/during_save"
    os.execute('mkdir "' .. during:gsub("/", "\\") .. '" 2>nul')
    local info = g_currentMission.missionInfo
    local home = info.savegameDirectory
    info.savegameDirectory = during
    ItemSystem.save()
    info.savegameDirectory = home
    local s = read(during .. "/ADFlyoverEditor_junctions.xml")
    check("folder changed during the save: the file is written there", s ~= nil)
    local line = s and s:match('<junction n="' .. n .. '"[^>]*>') or ""
    check("folder changed during the save: the decision made this game is in it", line:find('decision="whole"') ~= nil, line)
    check("folder changed during the save: the numbers are still in memory", E._jxReg ~= nil)
    os.remove(during .. "/ADFlyoverEditor_junctions.xml")
    os.execute('rmdir "' .. during:gsub("/", "\\") .. '" 2>nul')
end

-- 3. Another game loaded since: nothing of this game's is written into it.
local other = g_currentMission
g_currentMission = { terrainRootNode = 1, missionInfo = { savegameDirectory = dir .. "/elsewhere" } }
os.remove(path)
ItemSystem.save()
check("another game loaded: nothing written into this folder", read(path) == nil)
g_currentMission = other

print(fails == 0 and "REGSAVE ok" or ("REGSAVE FAIL " .. fails))

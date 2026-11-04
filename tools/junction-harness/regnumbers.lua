-- JUNCTION NUMBERS THROUGH UNDO, REDO AND SAVE (the user's plan, 2026-11-03; JxRegistry junctionNumbersCapture,
-- junctionNumbersRestore, jxNumbersStillThere, junctionForgetNumber). On a fresh junction: the clear + build
-- hands out a number, undo takes it back, redo puts it back; the game's save drops a number with no junction
-- left and keeps one with the user's decision; FlyoverForgetJunction drops one.
--   GRAPH=<network> REGDIR=<a COPY of a folder with ADFlyoverEditor_junctions.xml> lua regnumbers.lua X Z
-- Prints one line per check and "REGNUMBERS ok" or "REGNUMBERS FAIL n".
ItemSystem = { save = function() end }
local H = dofile("harness.lua")
dofile("../../scripts/editor/EditorHistory.lua")
local E = ADFlyoverEditor
g_server = g_server or {}
local x, z = tonumber(arg[1]), tonumber(arg[2])
local dir = assert(os.getenv("REGDIR"), "REGDIR not set")
local path = dir .. "/ADFlyoverEditor_junctions.xml"
local fails = 0
local function check(name, ok, detail)
    print(string.format("%-4s %s%s", ok and "ok" or "FAIL", name, detail and (" - " .. detail) or ""))
    if not ok then fails = fails + 1 end
end
local function numberAt(px, pz)
    for _, f in ipairs(E:junctionRegistry() or {}) do
        if (f.x - px) ^ 2 + (f.z - pz) ^ 2 <= 15 * 15 then return f.n end
    end
    return nil
end
local function numbersInFile()
    local f = io.open(path, "rb")
    local s = f and f:read("*a") or ""
    if f then f:close() end
    local t = {}
    for n in s:gmatch('<junction n="(%d+)"') do t[tonumber(n)] = true end
    return t
end
local function logHas(pat)
    for _, l in ipairs(LOG) do if l:find(pat) then return l end end
    return nil
end

E:junctionRegistry()
local before = numberAt(x, z)
check("fresh: no number at the site", before == nil, before and ("j" .. before) or nil)

-- clear + build, as the card's right-click
H.lock(x, z, { mode = "clear", thenBuild = true })
E.tool = E.TOOL.JUNCTION
LOG = {}
E:applyJunctionClearThenBuild()
local built = numberAt(x, z)
check("after the build: numbered", built ~= nil, built and ("j" .. built) or nil)
check("the build laid the mod's pattern", logHas("laid as the pattern") ~= nil)

LOG = {}
ADEditorHistory:undo()
check("after undo: no number at the site", numberAt(x, z) == nil, logHas("junction numbers %-"))
LOG = {}
ADEditorHistory:redo()
local again = numberAt(x, z)
check("after redo: the same number back", again == built, (again and ("j" .. again) or "none") .. "; " .. tostring(logHas("junction numbers %-")))
ADEditorHistory:undo()
check("undone again: no number", numberAt(x, z) == nil)

-- the game's save: the file must not have the taken-back number
ItemSystem.save()
check("saved after undo: the number is not in the file", built == nil or numbersInFile()[built] == nil)

-- a number whose junction has gone, and one with the user's decision, at an empty spot
local reg = E:junctionRegistry()
-- (as the scan carries a number it no longer finds: cleared)
table.insert(reg, { n = 97, x = 5000, z = 5000, forks = 4, cleared = true })
table.insert(reg, { n = 98, x = 5100, z = 5100, forks = 4, cleared = true, decision = "whole" })
LOG = {}
ItemSystem.save()
local inFile = numbersInFile()
for _, l in ipairs(LOG) do if l:find("dropped with the save") then print("     " .. l) end end
check("save: a number with no junction left is dropped", inFile[97] == nil, logHas("j97 dropped"))
check("save: a number with the user's decision is kept", inFile[98] == true)
local kept = 0
for n in pairs(inFile) do if n ~= 98 then kept = kept + 1 end end
check("save: every number still on the map is kept", kept >= 1, kept .. " number(s)")

-- no churn: built again and saved again, the file holds the same numbers
local function same(a, b)
    for n in pairs(a) do if not b[n] then return false end end
    for n in pairs(b) do if not a[n] then return false end end
    return true
end
E._jxRegCount = nil
E:junctionRegistry()
ItemSystem.save()
local second = numbersInFile()
local t = {}
for n in pairs(second) do t[#t + 1] = n end
table.sort(t)
check("saved again: the same numbers, none handed out afresh", same(inFile, second), table.concat(t, " "))

-- the console command
local some = nil
for _, f in ipairs(E:junctionRegistry()) do if f.n ~= 98 then some = f break end end
local said = E:junctionForgetNumber(some.n)
local gone = true
for _, f in ipairs(E._jxReg) do if f.n == some.n and f.x == some.x then gone = false end end
check("FlyoverForgetJunction drops the number", gone, said)
check("FlyoverForgetJunction with no number says how", E:junctionForgetNumber(nil):find("Give a junction number") ~= nil)

print(fails == 0 and "REGNUMBERS ok" or ("REGNUMBERS FAIL " .. fails))

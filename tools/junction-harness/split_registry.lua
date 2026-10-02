-- THE USER'S SPLIT DECISIONS INTO A JUNCTION FILE. Reads a junction file (ADFlyoverEditor_junctions.xml)
-- and split_decisions.txt, and writes a copy of every number with the decisions in it - read and
-- written by the editor's own code (junctionRegistryReadFile / junctionRegistryWriteFile), so the
-- file is the one the game itself would write.
--
--   lua split_registry.lua <junctions.xml> <split_decisions.txt> <out.xml>
--
-- It only ever writes <out.xml>, and refuses to: without one, over the file it reads, or into a
-- folder holding careerSavegame.xml (a real savegame). Putting it into the game is the user's step:
-- close FS25, then copy it over <savegame>/ADFlyoverEditor_junctions.xml. The game reads that file
-- once a session, so a copy made while it runs is not seen - and is overwritten when it next saves.
--
-- split_decisions.txt: one part a line - its name (number and compass letter, or the bare number),
-- then anything, then its x and z last ("39se T square 22.5 0.1"); "whole N N ..." lists junctions
-- kept whole; "#" starts a comment. A decision named here replaces any the file had; a junction not
-- named keeps what the file says. Refused, writing nothing: a number not in the file, a number both
-- split and kept whole, a split with fewer than two parts, a name used twice, a letter that is not
-- one of the eight (n ne e se s sw w nw).
local inPath, txtPath, outPath = arg[1], arg[2], arg[3]

local function fail(msg)
    io.stderr:write("split_registry: " .. msg .. "\n")
    os.exit(1)
end
if inPath == nil or txtPath == nil or outPath == nil or outPath == "" then
    fail("usage: lua split_registry.lua <junctions.xml> <split_decisions.txt> <out.xml>")
end

dofile("xmlstub.lua")
local function norm(p) return (p:gsub("\\", "/"):gsub("/+", "/"):gsub("^%./", ""):lower()) end
if norm(outPath) == norm(inPath) then fail("the output is the file being read - write a copy") end
local outDir = outPath:match("^(.*)[/\\][^/\\]*$") or "."
if fileExists(outDir .. "/careerSavegame.xml") then
    fail(outDir .. " is a savegame folder (it has careerSavegame.xml). Write somewhere else, then copy it in with FS25 closed.")
end
if not fileExists(inPath) then fail("no such file: " .. inPath) end

-- The editor, for its reader and writer. It needs nothing else from the game to load.
Logging = {
    info = function() end,
    warning = function(fmt, ...) io.stderr:write("warning: " .. string.format(fmt, ...) .. "\n") end,
    error = function(fmt, ...) io.stderr:write("error: " .. string.format(fmt, ...) .. "\n") end,
}
AutoDrive = AutoDrive or {}
dofile(os.getenv("FE_SRC") or "../../scripts/editor/FlyoverEditor.lua")
local E = ADFlyoverEditor

local list, err = E.junctionRegistryReadFile(inPath)
if list == nil then fail("could not read " .. inPath .. ": " .. tostring(err)) end
local byN = {}
for _, f in ipairs(list) do byN[f.n] = f end

local LETTER = { [""] = true, n = true, ne = true, e = true, se = true, s = true, sw = true, w = true, nw = true }
local splits, splitOrder, whole = {}, {}, {}
local f = io.open(txtPath, "r")
if f == nil then fail("no such file: " .. txtPath) end
local lineNo = 0
for line in f:lines() do
    lineNo = lineNo + 1
    line = line:gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" then
        local words = {}
        for w in line:gmatch("%S+") do words[#words + 1] = w end
        if words[1] == "whole" then
            for i = 2, #words do
                local n = tonumber(words[i])
                if n == nil then fail(string.format("line %d: %q is not a junction number", lineNo, words[i])) end
                whole[n] = true
            end
        else
            local num, letter = words[1]:match("^(%d+)(%a*)$")
            local x, z = tonumber(words[#words - 1] or ""), tonumber(words[#words] or "")
            if num == nil or #words < 3 or x == nil or z == nil then
                fail(string.format("line %d: expected a part name, then its x and z last: %s", lineNo, line))
            end
            if not LETTER[letter] then
                fail(string.format("line %d: %s - %q is not one of n ne e se s sw w nw", lineNo, words[1], letter))
            end
            local n = tonumber(num)
            if splits[n] == nil then
                splits[n] = {}
                splitOrder[#splitOrder + 1] = n
            end
            for _, p in ipairs(splits[n]) do
                if p.letter == letter then fail(string.format("line %d: %s is named twice", lineNo, words[1])) end
            end
            table.insert(splits[n], { letter = letter, x = x, z = z })
        end
    end
end
f:close()

table.sort(splitOrder)
local wholeList = {}
for n in pairs(whole) do wholeList[#wholeList + 1] = n end
table.sort(wholeList)
for _, n in ipairs(splitOrder) do
    if byN[n] == nil then fail(string.format("j%02d is split, but the file has no junction %d", n, n)) end
    if whole[n] then fail(string.format("j%02d is both split and kept whole", n)) end
    if #splits[n] < 2 then fail(string.format("j%02d is split into fewer than two parts", n)) end
end
for _, n in ipairs(wholeList) do
    if byN[n] == nil then fail(string.format("j%02d is kept whole, but the file has no junction %d", n, n)) end
end

for _, n in ipairs(splitOrder) do byN[n].decision, byN[n].parts = "split", splits[n] end
for _, n in ipairs(wholeList) do byN[n].decision, byN[n].parts = "whole", nil end

local ok, werr = E.junctionRegistryWriteFile(outPath, list)
if not ok then fail("could not write " .. outPath .. ": " .. tostring(werr)) end

local said = {}
for _, n in ipairs(splitOrder) do
    local names = {}
    for _, p in ipairs(splits[n]) do names[#names + 1] = string.format("j%02d%s", n, p.letter) end
    said[#said + 1] = table.concat(names, "/")
end
local kept = {}
for _, n in ipairs(wholeList) do kept[#kept + 1] = string.format("j%02d", n) end
print(string.format("wrote %s: %d junctions, %d split (%s), %d kept whole (%s).", outPath, #list,
    #splitOrder, table.concat(said, " "), #wholeList, table.concat(kept, " ")))
print("To use it in the game: close FS25, then copy it over <savegame>/ADFlyoverEditor_junctions.xml.")

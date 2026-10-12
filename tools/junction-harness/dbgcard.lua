-- The junction card offline (doc 12): lock a junction in each of the card's actions, print the rows the
-- real FlyoverHud builds, then (CLICK=1) right-click it as Mouse.lua does and print the card again.
--   lua dbgcard.lua <x> <z> [clear|build|both] [advanced]
-- With GAMEFLAGS=1 the road and swept checks run as in game (see harness.lua).
local H = dofile("harness.lua")
local E = ADFlyoverEditor
local x, z = tonumber(arg[1]), tonumber(arg[2])
local action = arg[3] or "both"
-- The real card, over the harness's stub. It reads the theme and settings only when drawing.
ADFlyoverHud = nil
dofile("../../scripts/editor/FlyoverHud.lua")
-- The real undo history, so a clear + build can be seen to leave one undo entry.
dofile("../../scripts/editor/EditorHistory.lua")
-- The vehicle set, as dbgbuild loads it: the card's "must fit" row lists its rigs.
if os.getenv("GAMEFLAGS") == "1" then dofile("../../scripts/editor/SweptSim.lua") end
if ADFlyoverSettings.get == nil then ADFlyoverSettings.get = function() return nil end end

local function card(title)
    print("---- " .. title)
    local ok, rows = pcall(function() return ADFlyoverHud:buildRows(E) end)
    if not ok then print("buildRows failed: " .. tostring(rows)) return end
    local on = false
    for _, r in ipairs(rows) do
        -- only the tool's own card: from the action row to the NEXT section
        if r.kind == "seg" and r.text == "action" then on = true end
        if r.kind == "section" and r.text == "NEXT" then on = false end
        if on then
            local dep = r.dep and "  | " or "    "
            if r.kind == "seg" then
                local o = {}
                for _, opt in ipairs(r.options) do o[#o + 1] = opt.active and ("[" .. opt.label .. "]") or opt.label end
                print(dep .. string.format("%-22s %s", r.text, table.concat(o, "  ")))
            elseif r.kind == "note" then
                print(dep .. "    " .. tostring(r.text))
            elseif r.kind ~= "gap" then
                print(dep .. string.format("%-22s %s", tostring(r.text), tostring(r.value or "")))
            end
        end
    end
    local okS, st = pcall(function() return E:getNextStepLines() end)
    print("status: " .. tostring(st))
end

-- PRECLEAR=1: a plain clear first, so the card is seen on a cleared junction. SHAPE=smooth and
-- NOFIT=refuse set the card's shape and "pattern won't fit".
if os.getenv("PRECLEAR") == "1" then
    H.lock(x, z, { mode = "clear" })
    H.apply()
end
local lockOpts = { mode = (action == "build") and "build" or "clear", thenBuild = (action == "both"), radius = tonumber(os.getenv("RADIUS") or ""),
    pattern = os.getenv("SHAPE") == "smooth" and "smooth" or nil, noFit = os.getenv("NOFIT") }
H.lock(x, z, lockOpts)
E.junctionAdvancedOpen = (arg[4] == "advanced")
card(string.format("locked %.1f, %.1f as %s", x, z, action))
if os.getenv("CLICK") == "1" then
    E.tool = E.TOOL.JUNCTION
    local before = #ADEditorHistory.stack
    E.lastRightClickTime = nil
    LOG = {}
    do
        -- the right-click's junction branch, as Mouse.lua runs it
        if E.junctionMode == "clear" and E.junctionThenBuild then
            if not E:applyJunctionClearThenBuild() then print("nothing to place") end
        elseif E:junctionHasWork(E.junctionPreview) then
            E:applyJunction()
        else
            print("nothing to place")
        end
        E.junctionArmed = nil
        E.junctionPreview, E.junctionPreviewKey = nil, nil
    end
    for _, l in ipairs(LOG) do
        if l:find("clear %+ build") or l:find("refused") or l:find("laid as the pattern") or l:find("junction placed") or l:find("did not lay") or l:find("cannot be driven") or l:find("frame:") or l:find("by way of") or l:find("placed plain because") then print("  log: " .. l) end
    end
    print(string.format("undo entries added: %d", #ADEditorHistory.stack - before))
    if E.junctionLastPatternWhy ~= nil then print("pattern did not fit: " .. tostring(E.junctionLastPatternWhy)) end
    H.lock(x, z, lockOpts)
    E.junctionAdvancedOpen = (arg[4] == "advanced")
    card("after the right-click, locked again")
end

-- OUTGRAPH=<file>: the network as it stands now, in export_graph.py's format (graph_dump.py plots it).
if os.getenv("OUTGRAPH") then
    local f = io.open(os.getenv("OUTGRAPH"), "w")
    f:write("return {\n")
    local wps = ADGraphManager:getWayPoints()
    for i = 1, #wps do
        local w = wps[i]
        if w ~= nil then
            f:write(string.format("  {id=%d,x=%.3f,y=%.3f,z=%.3f,flags=%d,out={%s}},\n", w.id, w.x, w.y or 0, w.z,
                w.flags or 0, table.concat(w.out or {}, ",")))
        end
    end
    f:write("}\n")
    f:close()
end

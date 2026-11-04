-- THE HUD'S DRAW-ORDER RULE, OFFLINE (FlyoverHud.lua, top of file): open the editor's panels in pairs and
-- check that (1) no text of a panel underneath is drawn where a panel on top covers it - the game draws
-- all text after all backgrounds, so it would show straight through - and (2) a click, a wheel notch
-- and a drag there go to the panel on top.
--   lua hudlayers.lua            (run from tools/junction-harness)
--   HUDFILE=<old FlyoverHud.lua> lua hudlayers.lua   checks another copy (the one before the fix fails)
-- Prints one line per check and "HUDLAYERS ok" or "HUDLAYERS FAIL n".
local H = dofile("harness.lua")
local E = ADFlyoverEditor
local fails = 0
local function check(name, ok, detail)
    if not ok then fails = fails + 1 end
    print((ok and "ok   " or "FAIL ") .. name .. (detail ~= nil and (" - " .. tostring(detail)) or ""))
end

-- Engine stand-ins: overlays draw nothing, text is recorded.
local texts = {}
local function fakeOverlay() return { setPosition = function() end, setDimension = function() end,
    setColor = function() end, render = function() end, setUVs = function() end } end
Overlay = { new = function() return fakeOverlay() end }
g_baseUIFilename, g_colorBgUVs = "ui.png", { 0, 0, 1, 1 }
RenderText = { ALIGN_LEFT = 0, ALIGN_CENTER = 1, ALIGN_RIGHT = 2 }
local align = 0
function renderText(x, y, size, text) texts[#texts + 1] = { x = x, y = y, size = size, text = tostring(text), align = align } end
function setTextColor() end
function setTextAlignment(a) align = a or 0 end
function setTextBold() end
function getTextWidth(size, text) return #tostring(text) * size * 0.5 end
GuiUtils = nil
dofile("xmlstub.lua")
dofile("../../scripts/editor/Theme.lua")
dofile("../../scripts/editor/Help.lua")
ADFlyoverHud = nil
dofile(os.getenv("HUDFILE") or "../../scripts/editor/FlyoverHud.lua")
local hud = ADFlyoverHud
local settings = {}
ADFlyoverSettings.get = function(k) return settings[k] end
ADFlyoverSettings.cycle = function() end
E.nowMs = E.nowMs or function() return 0 end
AutoDrive.FLAG_SUBPRIO = AutoDrive.FLAG_SUBPRIO or 1
ADEditorHistory.canUndo = function() return false end
ADEditorHistory.canRedo = function() return false end
ADEditorHistory.depth = function() return 0, 0 end

local function bbox(t)
    local w = getTextWidth(t.size, t.text)
    local x0 = t.x
    if t.align == 1 then x0 = t.x - w * 0.5 elseif t.align == 2 then x0 = t.x - w end
    return x0, t.y - t.size * 0.25, x0 + w, t.y + t.size
end
local function touches(t, r)
    local x0, y0, x1, y1 = bbox(t)
    return r ~= nil and x1 > r.x and x0 < r.x + r.w and y1 > r.y and y0 < r.y + r.h
end
local function frame()
    texts = {}
    hud:draw(E)
end
local function ctxRect() return { x = hud.ctxFrameX, y = hud.ctxFrameY, w = hud.ctxFrameW, h = hud.ctxFrameH } end
local function cornerRect() return { x = hud.frameX, y = hud.frameY, w = hud.frameW, h = hud.frameH } end
-- Texts a panel draws on its own (drawn straight, outside draw()), to tell its own lines from bleed.
local function ownTexts(fn)
    texts = {}
    hud.rows = {}
    fn()
    local set = {}
    for _, t in ipairs(texts) do set[t.text] = true end
    return set
end
--- Text inside `r` that is not the top panel's own: the bleed this file exists to catch.
local function bleed(r, own)
    local n, first = 0, nil
    for _, t in ipairs(texts) do
        if t.text ~= "" and touches(t, r) and not own[t.text] then
            n = n + 1
            first = first or t.text
        end
    end
    return n, first
end
local function rowCenterIn(r, wantAction)
    -- a lower-panel row with an action whose centre lies inside r
    for _, row in ipairs(hud.rows) do
        if row.action ~= nil and row.x ~= nil and (row.layer or 0) < 3 then
            local cx, cy = row.x + row.w * 0.5, row.y + row.h * 0.5
            if cx > r.x and cx < r.x + r.w and cy > r.y and cy < r.y + r.h then return cx, cy, row end
        end
    end
end

E.active = true
E.mouseX, E.mouseY = 0.9, 0.1

-- 1. Smooth's card under Smooth's help page (the build 720 report).
E.tool = E.TOOL.SMOOTH
E.helpOpen = true
E.toolCardX, E.toolCardY = nil, nil
frame()
local helpR = hud.helpRect
check("smooth card + help: both drawn", helpR ~= nil and hud.ctxFrameW > 0)
local own = ownTexts(function() hud:drawHelp(E) end)
frame()
local n, first = bleed(helpR, own)
check("smooth card + help: no card text inside the help page", n == 0, n > 0 and (n .. " line(s), first: " .. first) or nil)
local cx, cy, row = rowCenterIn(helpR)
if cx ~= nil then
    local over, hit = hud:isMouseOver(cx, cy)
    check("smooth card + help: a click on the help over a card button goes to the help", over and hit ~= row and hit.action ~= row.action)
    check("smooth card + help: no card field takes the wheel under the help", hud:numberFieldAt(cx, cy) == nil)
else
    print("note: no card button under the help page in this layout")
end
-- the wheel over the help scrolls the help, not the card
local hx, hy = helpR.x + helpR.w * 0.5, helpR.y + helpR.h * 0.5
check("smooth card + help: the wheel over the help is the help's", hud:isMouseOverHelp(hx, hy) and not hud:isMouseOverToolCard(hx, hy))

-- 2. Every tool's card under its help page.
local worst, worstTool = 0, nil
for name, id in pairs(E.TOOL) do
    E.tool = id
    frame()
    if hud.helpRect ~= nil then
        own = ownTexts(function() hud:drawHelp(E) end)
        frame()
        local k = bleed(hud.helpRect, own)
        if k > worst then worst, worstTool = k, name end
    end
end
check("every tool: no card text inside its help page", worst == 0, worstTool and (worstTool .. ": " .. worst .. " line(s)"))
E.helpOpen = false

-- 3. The card dragged onto the corner panel: the panel's text must not show through the card.
E.tool = E.TOOL.SMOOTH
E.toolCardX, E.toolCardY = hud.posX + 0.03, hud.topY - 0.05
settings.toolCardStatic = true
frame()
local cr = ctxRect()
own = {}
for _, t in ipairs(texts) do
    local x0, y0, x1, y1 = bbox(t)
    if x0 >= cr.x and x1 <= cr.x + cr.w and y0 >= cr.y and y1 <= cr.y + cr.h then own[t.text] = true end
end
-- corner texts are the ones drawn when the card is moved away
E.toolCardX = 0.7
frame()
local cornerOnly = {}
local cardSet = {}
for _, t in ipairs(texts) do
    if touches(t, ctxRect()) then cardSet[t.text] = true else cornerOnly[#cornerOnly + 1] = t end
end
E.toolCardX = hud.posX + 0.03
frame()
local leak = 0
for _, t in ipairs(texts) do
    if t.text ~= "" and touches(t, cr) and not cardSet[t.text] then leak = leak + 1 end
end
check("card over the corner panel: no panel text through the card", leak == 0, leak > 0 and (leak .. " line(s)") or nil)
local gx, gy = cr.x + cr.w * 0.5, cr.y + cr.h - 0.005
local _, gHit = hud:isMouseOver(gx, gy)
check("card over the corner panel: a click on the card's header is the card's", gHit ~= nil and gHit.layer == 2, gHit and gHit.layer)
settings.toolCardStatic = nil
E.toolCardX, E.toolCardY = nil, nil

-- 4. A warning box over the card.
E.warning = { text = "This is a long warning that wraps onto a few lines so it covers part of the tool card.", untilMs = 1e9 }
frame()
local wr = hud.warnRect
if wr ~= nil then
    own = ownTexts(function() hud:drawWarning(E) end)
    frame()
    n, first = bleed(wr, own)
    check("warning over the card: no card text inside the warning", n == 0, n > 0 and (n .. " line(s), first: " .. first) or nil)
    local _, wHit = hud:isMouseOver(wr.x + wr.w * 0.5, wr.y + wr.h * 0.5)
    check("warning over the card: a click on it closes the warning", wHit ~= nil and wHit.layer == 6)
else
    check("warning drawn", false)
end
E.warning = nil

-- 5. Help over the corner panel, when the panel is wide (big scale): the help sits beside it, but a
-- panel dragged right sits under the help - its text must not show.
E.tool = E.TOOL.NONE
E.helpOpen = true
local oldX = hud.posX
hud.posX = 0.62   -- help clamps to the right edge and lands over the panel
frame()
if hud.helpRect ~= nil then
    own = ownTexts(function() hud:drawHelp(E) end)
    frame()
    n, first = bleed(hud.helpRect, own)
    check("help over the corner panel: no panel text inside the help", n == 0, n > 0 and (n .. " line(s), first: " .. first) or nil)
end
hud.posX = oldX
E.helpOpen = false

-- 6. A Select popup opened over the help page: the popup is on top (it is what is being worked on).
E.tool = E.TOOL.NONE
E.helpOpen = true
frame()
local hr = hud.helpRect
E.ctxMenu = { kind = "point", id = 1, sx = hr.x + 0.05, sy = hr.y + hr.h * 0.5, placeX = hr.x + 0.05, placeTop = hr.y + hr.h * 0.7 }
frame()
local mr = hud.menuRect
check("popup over the help: both drawn", mr ~= nil and hud.helpRect ~= nil)
if mr ~= nil then
    own = ownTexts(function() hud:drawContextMenu(E) end)
    frame()
    n, first = bleed(mr, own)
    check("popup over the help: no help text inside the popup", n == 0, n > 0 and (n .. " line(s), first: " .. first) or nil)
    local _, pHit = hud:isMouseOver(mr.x + mr.w * 0.5, mr.y + mr.h * 0.5)
    check("popup over the help: a click inside the popup is the popup's", pHit ~= nil and pHit.layer == 4, pHit and pHit.layer)
    check("popup over the help: the wheel there does not scroll the help", not hud:isMouseOverHelp(mr.x + mr.w * 0.5, mr.y + mr.h * 0.5))
end
E.ctxMenu = nil
E.helpOpen = false

print(fails == 0 and "HUDLAYERS ok" or ("HUDLAYERS FAIL " .. fails))

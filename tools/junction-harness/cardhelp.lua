-- TOOL CARD vs HELP PAGE, offline (2026-11-03): the real HUD draw (FlyoverHud.lua, Theme.lua) with the
-- engine's draw calls stubbed to record what lands where. Smooth held, help open: no text of the tool card
-- may land on the help panel (game text draws above every background, so the help cannot cover it).
-- Then the same with the card dragged so nothing fits beside or below the help: it is left out, and none
-- of its buttons can be clicked. And with help shut, the card is back at its own spot.
--   lua cardhelp.lua           (from tools/junction-harness; needs the harness map data, as harness.lua)
-- Prints PASS or FAIL lines and exits 1 on any FAIL.

dofile("harness.lua")
local E = ADFlyoverEditor

-- Engine draw calls: overlays and text are recorded, nothing is drawn.
local texts = {}
local function noop() end
createImageOverlay = function() return 1 end
setOverlayColor, renderOverlay, delete, setTextBold, setTextAlignment, setTextColor = noop, noop, noop, noop, noop, noop
setTextVerticalAlignment, setTextWrapWidth, setTextClipArea, setTextLineBounds = noop, noop, noop, noop
setOverlayUVs, setOverlayRotation, setTextFirstLineIndentation = noop, noop, noop
renderText = function(x, y, size, text) texts[#texts + 1] = { x = x, y = y, size = size, text = tostring(text) } end
getTextWidth = function(size, text) return size * 0.5 * #tostring(text or "") end
g_baseUIFilename, g_baseHUDFilename = "", ""
-- Any engine object the HUD makes (Overlay.new ...): every method answers with the object itself.
local function anyObject()
    local o
    o = setmetatable({}, { __index = function() return function() return o end end, __call = function() return o end })
    return o
end
Overlay = anyObject()
-- Undo history and other stand-ins the harness keeps minimal: anything missing answers nil / false.
setmetatable(ADEditorHistory, { __index = function(_, k) return function() if k == "depth" then return 0 end return nil end end })
E_placed = true
RenderText = RenderText or { ALIGN_LEFT = 0, ALIGN_CENTER = 1, ALIGN_RIGHT = 2, VERTICAL_ALIGN_BASELINE = 0,
    VERTICAL_ALIGN_TOP = 1, VERTICAL_ALIGN_MIDDLE = 2, VERTICAL_ALIGN_BOTTOM = 3 }
g_currentMission.hud = g_currentMission.hud or {}
ADFlyoverSettings.get = function(name)
    if name == "toolCardStatic" then return false end
    return 1
end
ADFlyoverSettings.cycle = noop
ADFlyoverTheme = nil
dofile("../../scripts/editor/Theme.lua")
if ADFlyoverTheme.load ~= nil then pcall(ADFlyoverTheme.load) end
dofile("../../scripts/editor/Locale.lua")
dofile("../../scripts/editor/Help.lua")
dofile("../../scripts/editor/FlyoverHud.lua")
local HUD = ADFlyoverHud
if HUD.new ~= nil and getmetatable(HUD) == nil and HUD.posX == nil then
    local ok, inst = pcall(HUD.new, HUD)
    if ok and inst ~= nil then HUD = inst end
end

E.tool = E.TOOL.SMOOTH
E.placedCount = E.placedCount or 0
E.selectionCount = E.selectionCount or 0
E.mouseX, E.mouseY = 0.9, 0.1
E.toolCardX, E.toolCardY = nil, nil

local function frame()
    texts = {}
    HUD:draw(E)
end
local function inRect(t, r)
    return r ~= nil and t.x >= r.x and t.x <= r.x + r.w and t.y >= r.y and t.y <= r.y + r.h
end
-- The card's own text: what lands inside the card's frame. None of it may land on the help, so the two
-- frames must not overlap at all (any text in the overlap would read through the help page).
local function cardRect()
    if (HUD.ctxFrameW or 0) <= 0 then return nil end
    return { x = HUD.ctxFrameX, y = HUD.ctxFrameY, w = HUD.ctxFrameW, h = HUD.ctxFrameH }
end
local function framesOverlap(a, b)
    return a ~= nil and b ~= nil and a.x < b.x + b.w and a.x + a.w > b.x and a.y < b.y + b.h and a.y + a.h > b.y
end
local function cardTextCount()
    local c, n = cardRect(), 0
    for _, t in ipairs(texts) do if inRect(t, c) then n = n + 1 end end
    return n
end
-- The card's selectors ("picks", "mode") are its own; the corner panel has none of these.
local function cardControls()
    local n = 0
    for _, row in ipairs(HUD.rows or {}) do
        if row.kind == "seg" and (row.text == "picks" or row.text == "mode") then n = n + 1 end
    end
    return n
end
local function describe()
    local c, h = cardRect(), HUD.helpRect
    return string.format("help x %.3f..%.3f y %.3f..%.3f; card %s", h and h.x or -1, h and h.x + h.w or -1,
        h and h.y or -1, h and h.y + h.h or -1,
        c and string.format("x %.3f..%.3f y %.3f..%.3f", c.x, c.x + c.w, c.y, c.y + c.h) or "not drawn")
end

local fails = 0
local function check(what, ok, detail)
    print((ok and "PASS " or "FAIL ") .. what .. (detail and ("  (" .. detail .. ")") or ""))
    if not ok then fails = fails + 1 end
end

-- 1. help shut: where the card sits on its own
E.helpOpen = false
frame(); frame()
local home = { x = HUD.ctxFrameX, y = HUD.ctxFrameY, w = HUD.ctxFrameW }
check("help shut: the card is drawn, with its controls", cardTextCount() > 0 and cardControls() > 0)

-- 2. help open: the card steps clear of the help and stays usable
E.helpOpen = true
frame(); frame()
check("help open: the card does not overlap the help page", not framesOverlap(cardRect(), HUD.helpRect), describe())
check("help open: the card is still drawn, with its controls", cardTextCount() > 0 and cardControls() > 0)

-- 3. help open at a large ui scale: nothing fits beside or below the help, so the card is left out
ADFlyoverTheme.scale = 2.6
frame(); frame()
check("no room: the card is left out", cardRect() == nil, describe())
check("no room: none of its controls can be clicked", cardControls() == 0, "controls " .. cardControls())
ADFlyoverTheme.scale = 1

-- 4. help shut again: back home
E.helpOpen = false
frame(); frame()
check("help shut again: the card is back at its own spot",
    math.abs((HUD.ctxFrameX or -1) - home.x) < 1e-6 and math.abs((HUD.ctxFrameY or -1) - home.y) < 1e-6)

print(fails == 0 and "ALL PASS" or (fails .. " FAIL(S)"))
os.exit(fails == 0 and 0 or 1)

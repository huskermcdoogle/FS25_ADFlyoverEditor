-- THE IN-GAME TEST PANEL, OFFLINE (scripts/editor/TestPanel.lua): the plan read from a packed
-- testplan.xml, automatic ticks from the build and from editor log lines, a click winning over a later
-- automatic tick, results written and read back after a "restart", and the log wrapped only once.
--   TPTMP=<an empty scratch folder> lua testpanel.lua        (run from tools/junction-harness)
-- Prints one line per check and "TESTPANEL ok" or "TESTPANEL FAIL n".
local TMP = assert(os.getenv("TPTMP"), "TPTMP not set")
dofile("xmlstub.lua")
function getXMLBool(xml, key) local v = getXMLString(xml, key); if v == nil then return nil end return v == "true" end
function setXMLBool(xml, key, v) setXMLString(xml, key, v and "true" or "false") end
Utils = { getFilename = function(rel, dir) return dir .. rel end }
ADFlyoverPrelude = { MOD_DIRECTORY = TMP .. "/mod/", BUILD = "1.0.2.1+999.test" }
function getUserProfileAppPath() return TMP .. "/profile/" end
function createFolder(p) os.execute('mkdir "' .. p:gsub("/", "\\") .. '" 2>nul') end
getDate = os.date
g_time = 0
LINES = {}
Logging = {
    info = function(f, ...) LINES[#LINES + 1] = string.format(f, ...) end,
    warning = function(f, ...) LINES[#LINES + 1] = "WARN " .. string.format(f, ...) end,
    error = function(f, ...) LINES[#LINES + 1] = "ERR " .. string.format(f, ...) end,
}
local fails = 0
local function check(name, ok, detail)
    print(string.format("%-4s %s%s", ok and "ok" or "FAIL", name, detail and (" - " .. tostring(detail)) or ""))
    if not ok then fails = fails + 1 end
end
-- the plan, packed the way build_zip.py packs it
local src = assert(io.open("../testplans/current.xml", "rb")):read("*a")
createFolder(TMP .. "/mod/")
local f = assert(io.open(TMP .. "/mod/testplan.xml", "wb")); f:write((src:gsub("@BUILD@", ADFlyoverPrelude.BUILD))); f:close()

dofile("../../scripts/editor/TestPanel.lua")
local T = ADFlyoverTestPanel
check("plan read", T.plan ~= nil and #T.plan.tests == 8, T.plan and #T.plan.tests)
check("plan names its build", T.plan and T.plan.build == ADFlyoverPrelude.BUILD, T.plan and T.plan.build)
T.poll()
check("build ticks itself", T.state.build and T.state.build.status == "pass" and T.state.build.auto, T.state.build and T.state.build.evidence)
check("next test is the card's own", T.nextTest() and T.nextTest().id == "card")

Logging.info("[FlyoverEditor]: junction vehicle set - %s %s.", "semi", "must fit the turns")
check("a log line ticks the rig toggle", T.state.rigToggle and T.state.rigToggle.status == "pass" and T.state.rigToggle.auto,
    T.state.rigToggle and T.state.rigToggle.evidence)
Logging.info("[FlyoverEditor]: swept - %s (%s, %s): fits %d of the %d turns this build lays.", "small rig", "Fendt", "must fit", 3, 4)
check("a log line ticks the fit counts", T.state.fitCounts and T.state.fitCounts.status == "pass")
check("other mods' lines are not kept", (function() local n = #T.log; Logging.info("[AutoDrive] hello"); return #T.log == n end)())
check("the log keeps editor lines", #T.log == 3 and T.log[2].text:find("^junction vehicle set") ~= nil, T.log[2] and T.log[2].text)

T.set("card", "pass", false)
check("a click sets a test", T.state.card and T.state.card.status == "pass" and not T.state.card.auto)
T.set("rigToggle", "fail", false)
Logging.info("[FlyoverEditor]: junction vehicle set - %s %s.", "semi", "must fit the turns")
check("a click wins over a later automatic tick", T.state.rigToggle.status == "fail" and not T.state.rigToggle.auto)
T.set("rigToggle", "fail", false)
check("clicking the same status again clears it", T.state.rigToggle == nil)
local done, total, pass, fail = T.counts()
check("counts", done == 3 and total == 8 and pass == 3 and fail == 0, string.format("%d/%d pass %d fail %d", done, total, pass, fail))

local rp = TMP .. "/profile/modSettings/FS25_ADFlyoverEditor/testresults.xml"
local r = io.open(rp, "rb")
check("results written", r ~= nil)
local text = r and r:read("*a") or ""
if r then r:close() end
check("results hold the statuses and the log", text:find('id="card"') and text:find('status="pass"') and text:find("<log>") ~= nil)

-- a restart on the same build picks the ticks up; another build does not
T.state = {}
T.load()
check("same build: ticks come back", T.state.card and T.state.card.status == "pass" and T.state.fitCounts and T.state.fitCounts.status == "pass")
ADFlyoverPrelude.BUILD = "1.0.2.1+1000.other"
T.load()
check("another build: a fresh card", next(T.state) == nil)
T.poll()
check("another build: the build check fails", T.state.build and T.state.build.status == "fail", T.state.build and T.state.build.evidence)
-- the wrap is installed once, even when the file is sourced again (each savegame load)
local wrapped = Logging.info
dofile("../../scripts/editor/TestPanel.lua")
check("sourced again: the log is wrapped once", Logging.info == wrapped)
-- THE CARD ITSELF (FlyoverHud.lua drawTestPanel), drawn with stand-ins for the engine's drawing calls:
-- it must draw without a Lua error, show every test, and its buttons must set the tests they sit on.
ADFlyoverPrelude.BUILD = "1.0.2.1+999.test"
T.load()
local texts = {}
local function fakeOverlay() return { setPosition = function() end, setDimension = function() end,
    setColor = function() end, render = function() end, setUVs = function() end } end
Overlay = { new = function() return fakeOverlay() end }
g_baseUIFilename, g_colorBgUVs = "ui.png", { 0, 0, 1, 1 }
RenderText = { ALIGN_LEFT = 0, ALIGN_CENTER = 1, ALIGN_RIGHT = 2 }
function renderText(x, y, size, text) texts[#texts + 1] = { x = x, y = y, text = text } end
function setTextColor() end
function setTextAlignment() end
function setTextBold() end
function getTextWidth(size, text) return #text * size * 0.5 end
dofile("../../scripts/editor/Theme.lua")
dofile("../../scripts/editor/FlyoverHud.lua")
local hud = ADFlyoverHud
hud.rows = {}
hud:ensureOverlays()
local editor = { mouseX = 0.5, mouseY = 0.5 }
local ok, err = pcall(hud.drawTestPanel, hud, editor)
check("the card draws", ok, err)
local seen = {}
for _, t in ipairs(texts) do seen[t.text] = true end
local allShown = true
for _, t in ipairs(T.plan.tests) do if not seen[t.title] then allShown = false end end
check("every test is on the card", allShown, #texts .. " text(s) drawn")
check("the card has a header and a log", seen["log"] == true and hud.testRect ~= nil)
-- press the "pass" button of the card's own test: the button rows follow the test's title row
local pressed = false
for _, row in ipairs(hud.rows) do
    if row.action ~= nil and not pressed and row.w < 0.05 then
        -- the first small button belongs to the first test (build): its "pass"
        row.action(); pressed = true
    end
end
check("a button sets its test", pressed and T.state.build ~= nil and T.state.build.status == "pass" and not T.state.build.auto)
-- fold with the header (the full-width row with an action), draw again: only the header is left
for _, row in ipairs(hud.rows) do if row.action ~= nil and row.w > 0.2 then row.action() break end end
texts, hud.rows = {}, {}
ok, err = pcall(hud.drawTestPanel, hud, editor)
check("folded, it draws the header alone", ok and T.folded and #texts <= 2, (ok and #texts or err))
T.shown = false
hud.rows = {}
hud:drawTestPanel(editor)
check("hidden, nothing is drawn and nothing blocks clicks", hud.testRect == nil and #hud.rows == 0)
for _, l in ipairs(LINES) do if l:find("^WARN") or l:find("^ERR") then print("  " .. l) end end
print(fails == 0 and "TESTPANEL ok" or ("TESTPANEL FAIL " .. fails))

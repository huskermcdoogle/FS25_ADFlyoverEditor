-- THE IN-GAME TEST PANEL (asked for 2026-10-02, built 2026-10-07): the test plan for a test build, ticked
-- off in the game instead of on a web page, with the editor's own log beside it and results written to
-- a file Claude reads after the session.
--
-- The PLAN is testplan.xml at the mod's root. Only a test build carries one (tools/testbuild.sh packs
-- tools/testplans/current.xml through build_zip.py --testplan), so a released build never shows the
-- panel. A new plan each round is a new XML file, no code change:
--   <testPlan title="..." build="@BUILD@">            build_zip.py writes the build number into @BUILD@
--     <test id="..." title="..." hint="what to do and what you should see"
--           auto="build"                                 ticks itself: this game runs the plan's build
--           passLog="lua pattern" failLog="lua pattern"/> ticks itself on an editor log line
--   </testPlan>
-- A click always wins over an automatic tick. RESULTS go to modSettings/FS25_ADFlyoverEditor/
-- testresults.xml on every change (never the savegame folder: FS25's save deletes files it did not
-- write), with the last log lines; a restart on the same build picks the ticks back up.
ADFlyoverTestPanel = ADFlyoverTestPanel or {}
local T = ADFlyoverTestPanel

T.FOLDER = "modSettings/FS25_ADFlyoverEditor/"
T.FILE = "testresults.xml"
T.LOG_KEEP = 60

T.plan = T.plan
T.state = T.state or {}
T.log = T.log or {}
if T.shown == nil then T.shown = true end
if T.folded == nil then T.folded = false end

local function nowText()
    if getDate ~= nil then
        local ok, s = pcall(getDate, "%Y-%m-%d %H:%M:%S")
        if ok and s ~= nil then return s end
    end
    return ""
end

local function resultsPath()
    if getUserProfileAppPath == nil then return nil end
    return getUserProfileAppPath() .. T.FOLDER .. T.FILE
end

--- The running build, as the card's header shows it.
function T.runningBuild()
    if ADFlyoverPrelude ~= nil and ADFlyoverPrelude.BUILD ~= nil then return ADFlyoverPrelude.BUILD end
    return "?"
end

--- Read testplan.xml from the mod (nil when this build has none) and the results file of the same
--- build, if there is one.
function T.load()
    if loadXMLFile == nil or fileExists == nil or Utils == nil or ADFlyoverPrelude == nil
        or ADFlyoverPrelude.MOD_DIRECTORY == nil then
        return false
    end
    local path = Utils.getFilename("testplan.xml", ADFlyoverPrelude.MOD_DIRECTORY)
    if path == nil or not fileExists(path) then
        T.plan = nil
        return false
    end
    local xml = loadXMLFile("ADFlyoverTestPlan", path)
    if xml == nil or xml == 0 then return false end
    local plan = { title = getXMLString(xml, "testPlan#title") or "test plan",
        build = getXMLString(xml, "testPlan#build") or "", tests = {} }
    local i = 0
    while true do
        local key = string.format("testPlan.test(%d)", i)
        if not hasXMLProperty(xml, key) then break end
        plan.tests[#plan.tests + 1] = {
            id = getXMLString(xml, key .. "#id") or tostring(i + 1),
            title = getXMLString(xml, key .. "#title") or "?",
            hint = getXMLString(xml, key .. "#hint") or "",
            auto = getXMLString(xml, key .. "#auto"),
            passLog = getXMLString(xml, key .. "#passLog"),
            failLog = getXMLString(xml, key .. "#failLog"),
        }
        i = i + 1
    end
    delete(xml)
    T.plan = plan
    T.state = {}
    -- Ticks from an earlier session of the SAME build come back; another build's are not this plan's.
    local rp = resultsPath()
    if rp ~= nil and fileExists(rp) then
        local rx = loadXMLFile("ADFlyoverTestResults", rp)
        if rx ~= nil and rx ~= 0 then
            if getXMLString(rx, "testResults#build") == T.runningBuild() then
                local k = 0
                while true do
                    local key = string.format("testResults.test(%d)", k)
                    if not hasXMLProperty(rx, key) then break end
                    local id, status = getXMLString(rx, key .. "#id"), getXMLString(rx, key .. "#status")
                    if id ~= nil and status ~= nil and status ~= "" then
                        T.state[id] = { status = status, auto = getXMLBool(rx, key .. "#auto") == true,
                            evidence = getXMLString(rx, key .. "#evidence"), at = getXMLString(rx, key .. "#at") }
                    end
                    k = k + 1
                end
            end
            delete(rx)
        end
    end
    Logging.info("[FlyoverEditor]: test panel - plan '%s', %d test(s), for build %s (running %s).",
        plan.title, #plan.tests, plan.build, T.runningBuild())
    return true
end

--- Write the results file: every test's status, how it got it, and the editor's last log lines.
function T.save()
    local path = resultsPath()
    if path == nil or T.plan == nil or createXMLFile == nil then return false end
    local ok, err = pcall(function()
        createFolder(getUserProfileAppPath() .. "modSettings/")
        createFolder(getUserProfileAppPath() .. T.FOLDER)
        local xml = createXMLFile("ADFlyoverTestResults", path, "testResults")
        setXMLString(xml, "testResults#build", T.runningBuild())
        setXMLString(xml, "testResults#planBuild", T.plan.build or "")
        setXMLString(xml, "testResults#plan", T.plan.title or "")
        setXMLString(xml, "testResults#saved", nowText())
        for i, t in ipairs(T.plan.tests) do
            local key = string.format("testResults.test(%d)", i - 1)
            local s = T.state[t.id] or {}
            setXMLString(xml, key .. "#id", t.id)
            setXMLString(xml, key .. "#title", t.title)
            setXMLString(xml, key .. "#status", s.status or "")
            setXMLBool(xml, key .. "#auto", s.auto == true)
            setXMLString(xml, key .. "#evidence", s.evidence or "")
            setXMLString(xml, key .. "#at", s.at or "")
        end
        for i, l in ipairs(T.log) do
            setXMLString(xml, string.format("testResults.log.line(%d)#text", i - 1), l.text)
        end
        saveXMLFile(xml)
        delete(xml)
    end)
    if not ok then
        Logging.warning("[FlyoverEditor]: test panel - could not write the results (%s): %s", tostring(path), tostring(err))
    end
    return ok
end

--- Set a test's status. A click (auto = false) always wins; an automatic tick never overwrites one.
--- Clicking the status a test already has clears it.
function T.set(id, status, auto, evidence)
    local s = T.state[id]
    if auto and s ~= nil and s.status ~= nil and not s.auto then return end
    if not auto and s ~= nil and s.status == status and not s.auto then
        T.state[id] = nil
    else
        T.state[id] = { status = status, auto = auto == true, evidence = evidence or (s and s.evidence), at = nowText() }
    end
    T.savedAt = g_time or 0
    T.save()
end

function T.counts()
    local done, pass, fail = 0, 0, 0
    if T.plan == nil then return 0, 0, 0, 0 end
    for _, t in ipairs(T.plan.tests) do
        local s = T.state[t.id]
        if s ~= nil and s.status ~= nil then
            done = done + 1
            if s.status == "pass" then pass = pass + 1 elseif s.status == "fail" then fail = fail + 1 end
        end
    end
    return done, #T.plan.tests, pass, fail
end

--- The first test with no status yet: the one whose instructions the card shows.
function T.nextTest()
    if T.plan == nil then return nil end
    for _, t in ipairs(T.plan.tests) do
        local s = T.state[t.id]
        if s == nil or s.status == nil then return t end
    end
    return nil
end

--- "Step 2 of 5": the card numbers the steps itself, so the plan's titles carry no numbers.
function T.stepLabel(t)
    if T.plan == nil or t == nil then return "" end
    for i, x in ipairs(T.plan.tests) do
        if x == t then return string.format("Step %d of %d", i, #T.plan.tests) end
    end
    return ""
end

--- What the card says once every step has a status: "" until then.
function T.progressText()
    local done, total, pass, fail = T.counts()
    if total == 0 or done < total then return "" end
    return string.format("All %d steps done: %d passed, %d failed, %d skipped.",
        total, pass, fail, done - pass - fail)
end

--- An editor log line: kept for the card's log and the results, and matched against the plan.
function T.capture(text, level)
    if T.plan == nil or type(text) ~= "string" or T.capturing then return end
    T.capturing = true
    local ok, err = pcall(T.captureLine, text, level)
    T.capturing = false
    if not ok then print("[FlyoverEditor]: test panel - a log line could not be matched: " .. tostring(err)) end
end

function T.captureLine(text, level)
    T.logDirty = true
    local line = text:gsub("^%[FlyoverEditor%]:%s*", "")
    if level == "warning" then line = "! " .. line elseif level == "error" then line = "!! " .. line end
    T.log[#T.log + 1] = { text = line, at = nowText() }
    while #T.log > T.LOG_KEEP do table.remove(T.log, 1) end
    for _, t in ipairs(T.plan.tests) do
        local ok1, failHit = pcall(function() return t.failLog ~= nil and text:find(t.failLog) ~= nil end)
        local ok2, passHit = pcall(function() return t.passLog ~= nil and text:find(t.passLog) ~= nil end)
        if ok1 and failHit then
            T.set(t.id, "fail", true, line)
        elseif ok2 and passHit then
            local s = T.state[t.id]
            if s == nil or s.status == nil or (s.auto and s.status ~= "fail") then T.set(t.id, "pass", true, line) end
        end
    end
end

--- Checks the panel can answer by itself, polled while the card is drawn. Also writes the results
--- again every 10 s while new log lines are coming in, so the file's log is never far behind.
function T.poll()
    if T.plan == nil then return end
    local now = g_time or 0
    if T.logDirty and now - (T.savedAt or 0) > 10000 then
        T.logDirty = false
        T.savedAt = now
        T.save()
    end
    for _, t in ipairs(T.plan.tests) do
        if t.auto == "build" then
            local s = T.state[t.id]
            if s == nil or s.auto then
                local running = T.runningBuild()
                local want = s and s.status
                local now = (T.plan.build ~= "" and running == T.plan.build) and "pass" or "fail"
                if want ~= now then
                    T.set(t.id, now, true, string.format("running %s, plan for %s", running, T.plan.build))
                end
            end
        end
    end
end

function T.toggleShown()
    T.shown = not T.shown
    return T.shown
end

-- Every editor line through Logging reaches the panel: wrapped once per game session (the editor files
-- are sourced again for each savegame; the flag on Logging stops a second wrap). Only lines tagged with
-- the editor's own prefix are kept.
if Logging ~= nil and not Logging.__adFlyoverTestPanel then
    Logging.__adFlyoverTestPanel = true
    for _, level in ipairs({ "info", "warning", "error" }) do
        local orig = Logging[level]
        if type(orig) == "function" then
            Logging[level] = function(fmt, ...)
                orig(fmt, ...)
                if ADFlyoverTestPanel ~= nil and ADFlyoverTestPanel.plan ~= nil and type(fmt) == "string"
                    and fmt:find("[FlyoverEditor]", 1, true) == 1 then
                    local ok, s = pcall(string.format, fmt, ...)
                    pcall(ADFlyoverTestPanel.capture, ok and s or fmt, level)
                end
            end
        end
    end
end

pcall(T.load)

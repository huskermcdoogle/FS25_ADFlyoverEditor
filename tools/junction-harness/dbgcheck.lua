-- THE CHECK AFTER A CLEAR, for one junction: runs the real clear offline, exactly as dbgstages.lua
-- does, and prints the lines the game's log gets from the check that follows it - the summary, then
-- one line per problem - and the line the junction card shows. Report only: the check changes
-- nothing.
--   LEAVE=1 lua dbgcheck.lua X Z        (LEAVE=1 through roads kept, LEAVE=0 not)
-- ALL=1 prints the clear's whole log as well.
-- The last line, COUNTS, is for reg75check.sh: joins, teal dots and other problems, each split by
-- reason (joins and dots: made, crossmade, new, selfmade, tail, missed, nobox, through, part,
-- oneroad, selfjoin, crossing; other problems: reach, through, stub, flip, spur, leftover, link,
-- moved, gone, new, vanished, stayed), then the lines said as not this clear's doing, and the notes.
-- The check itself is ADFlyoverEditor:junctionClearCheck in FlyoverEditor.lua; this only runs it.
--
-- THE CHECK CAN NEVER STOP THE CLEAR. THROW=<step> makes one step of the check throw, to show it:
--   snapshot  reading the network before the clear (jxSnapshot)
--   routes    reading the through roads (jxRouteLines)
--   keep      keeping the result for the card (junctionCheckKeep) - which the line for a check that
--             could not run goes through too
--   check     the check itself (junctionClearCheck)
-- With THROW (or NET=1) it also prints TOOK (the clear's own total), NET (every point of the
-- network after the clear, as one checksum), and ENDED (whether the clear's last steps ran: the
-- tool is disarmed and the preview dropped). Run with and without THROW and compare: the clear
-- must be the same, and the card must say the check could not run.
--
-- WIRE=1 plays a tidy that went wrong: just before the check, the end of a lane the clear laid is
-- wired to the nearest start of a lane it laid, and the link is put in the clear's record as the
-- tidy's own. The check must say that join as new ("now joins ... joined by a link that was not
-- there before the clear, from (a) to (b)", with a and b the two ends printed on the WIRED line),
-- never as a connection the clear missed.
LOG_ECHO = false
local H = dofile("harness.lua")
local x, z = tonumber(arg[1]), tonumber(arg[2])
if x == nil or z == nil then
    print("usage: LEAVE=1|0 lua dbgcheck.lua X Z")
    os.exit(1)
end
local jp = H.lock(x, z, { mode = "clear", radius = 12, leaveThrough = (os.getenv("LEAVE") == "1") })
if jp == nil then
    print("REFUSED: " .. tostring(ADFlyoverEditor.junctionRefused))
    return
end
-- What the card and the log call the locked site: "j39se" once 39 is split (REGDIR=<a registry
-- with the user's decisions>), the bare number otherwise. Not read by reg75check.sh.
print("NAME " .. tostring(jp.junctionName) .. (jp.junctionNameNote and (" | " .. jp.junctionNameNote) or ""))
local THROW = os.getenv("THROW")
if THROW ~= nil and THROW ~= "" then
    -- The two reads are the clear's own locals; they are swapped through its upvalues.
    local function force(fn, name)
        local i = 1
        while debug.getupvalue(fn, i) ~= nil do
            if debug.getupvalue(fn, i) == name then
                debug.setupvalue(fn, i, function() error("forced for the test: " .. name) end)
                return
            end
            i = i + 1
        end
        error("no such step to force: " .. name)
    end
    if THROW == "snapshot" then
        force(ADFlyoverEditor.applyJunctionClear, "jxSnapshot")
    elseif THROW == "routes" then
        force(ADFlyoverEditor.applyJunctionClear, "jxRouteLines")
    elseif THROW == "keep" then
        ADFlyoverEditor.junctionCheckKeep = function() error("forced for the test: junctionCheckKeep") end
    elseif THROW == "check" then
        ADFlyoverEditor.junctionClearCheck = function() error("forced for the test: junctionClearCheck") end
    else
        error("THROW must be snapshot, routes, keep or check")
    end
end
if os.getenv("WIRE") == "1" then
    local real = ADFlyoverEditor.junctionClearCheck
    ADFlyoverEditor.junctionClearCheck = function(self, ck)
        local ends, starts = {}, {}
        if ck ~= nil and ck.before ~= nil and ck.site ~= nil then
            for _, w in ipairs(ADGraphManager:getWayPoints()) do
                if ck.before[w] == nil and (w.x - ck.site.x) ^ 2 + (w.z - ck.site.z) ^ 2 <= 45 * 45 then
                    if #w.out == 0 and #w.incoming > 0 then ends[#ends + 1] = w end
                    if #w.incoming == 0 and #w.out > 0 then starts[#starts + 1] = w end
                end
            end
        end
        local a, b, bd = nil, nil, math.huge
        for _, p in ipairs(ends) do
            for _, q in ipairs(starts) do
                local d = (p.x - q.x) ^ 2 + (p.z - q.z) ^ 2
                if d < bd then a, b, bd = p, q, d end
            end
        end
        if a == nil then
            print("WIRED nothing: the clear laid no lane end and lane start here")
        else
            table.insert(a.out, b.id)
            table.insert(b.incoming, a.id)
            ck.journal[#ck.journal + 1] = { op = "out+", a = a, b = b, stage = "tidying lane ends", x = a.x, y = a.y, z = a.z }
            ck.journal[#ck.journal + 1] = { op = "in+", a = b, b = a, stage = "tidying lane ends", x = b.x, y = b.y, z = b.z }
            print(string.format("WIRED (%.1f, %.1f) to (%.1f, %.1f)", a.x, a.z, b.x, b.z))
        end
        return real(self, ck)
    end
end
ADFlyoverEditor.junctionLastCheck = nil
local ok, log = pcall(H.apply)
if not ok then
    -- Escaped the clear: the very thing THROW is there to rule out.
    print("CLEAR STOPPED: " .. tostring(log))
    log = LOG
end
if (THROW ~= nil and THROW ~= "") or os.getenv("NET") == "1" then
    for _, line in ipairs(log) do
        local took = line:match("took %d+ point%(s%) in all, the farthest %d+ m out")
        if took ~= nil then print("TOOK " .. took) end
    end
    local h, n = 0, 0
    for _, w in ipairs(ADGraphManager:getWayPoints()) do
        n = n + 1
        local s = string.format("%d %.3f %.3f %.3f>%s<%s|", w.id, w.x, w.y or 0, w.z,
            table.concat(w.out or {}, ","), table.concat(w.incoming or {}, ","))
        for i = 1, #s do h = (h * 31 + s:byte(i)) % 2147483647 end
    end
    print(string.format("NET %d points, checksum %.0f", n, h))
    print(string.format("ENDED %s", tostring(ADFlyoverEditor.junctionArmed == nil and ADFlyoverEditor.junctionPreview == nil)))
end
local said = false
for _, line in ipairs(log) do
    -- "check parts" too: an error in the read made before the clear ("junction check parts failed")
    -- must reach reg75check.sh's error count like any other.
    if os.getenv("ALL") == "1" or line:find("junction %- check") or line:find("clear check")
        or line:find("check parts") then
        print(line)
        said = true
    end
end
if not said then print("NO CHECK RAN") end
local r = ADFlyoverEditor.junctionLastCheck
if r == nil then return end
for _, c in ipairs(r.card or {}) do print("CARD " .. c) end
-- A check that could not run, or stopped with an error, leaves only its card line: no counts, so
-- reg75check.sh shows it as NO CHECK rather than as a clean pass.
if r.joins == nil then return end
print(string.format("MIDDLE %.2f %.2f %.1f", r.x, r.z, r.middleR or 0))

-- Counts by reason, in a fixed order so two runs can be compared line for line.
local function tally(list, field)
    local n, by = 0, {}
    for _, it in ipairs(list) do
        n = n + 1
        local k = it[field] or "?"
        by[k] = (by[k] or 0) + 1
    end
    local keys = {}
    for k in pairs(by) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = string.format("%s:%d", k, by[k]) end
    return string.format("%d%s", n, (#parts > 0) and (" " .. table.concat(parts, " ")) or "")
end
print(string.format("COUNTS joins %s | dots %s | other %s | wrongBefore %d | notes %d",
    tally(r.joins or {}, "why"), tally(r.dots or {}, "why"), tally(r.issues or {}, "kind"), #(r.wrongBefore or {}),
    #(r.notes or {})))

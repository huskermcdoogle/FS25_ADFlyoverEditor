-- Is a numbered junction really more than one? What the card would suggest, for every junction in the
-- savegame's numbers file, by the game's own numbers.
--   GRAPH=<network .lua> RIG_TRAILER=11 lua dbgparts.lua [ADFlyoverEditor_junctions.xml] [numbers...]
-- (the file defaults to REG, else savegame6 under the user's OneDrive Documents; MODE=build locks
-- every site in build mode, at RADIUS, default 15 - build reads the kind and the parts of a cleared
-- site only, so a wired one shows its F1 note and "not read"; RADIUS=6,15,40 locks each site at every
-- radius given, in a fresh process each, and says where the reading changes with the wheel - it must
-- not: build reads a cleared site at a fixed radius, whatever the wheel says.
-- MODE=clearbuild [LEAVE=0|1] runs the real clear on each wired site first - through paths cleared
-- too with LEAVE=0 - and then locks build where the clear locked, the way the user comes back to
-- build a junction just cleared. The survey map has only seven cleared sites (69-75), so this is
-- where the cleared-site reading meets the other sixty-eight: plain T's (8, 27, 37) once read as
-- two junctions here and nowhere else.)
-- One line per junction:
--   F1    two or more road-meeting points (junctionCentres) whose nearest number within 30 m is this
--         one - the one number stands for places the roads say are separate (junctionMeetingPointsOf;
--         a road's own bend, a meeting point with no fork of its own, is not counted)
--   parts the part reader (junctionParts) at the site a click on the number locks: clear mode, or
--         build where the clear refuses the site as already cleared. Each road is side (L/R of the
--         main road), angle to it, where along it, and which ways its lanes run: R44@0.8[out+1w]
--         (1w: one flow read and no lane back beside it - a one-way road)
--   card  the lines the card would show (junctionPartsNote), with the FILE's numbers - the harness has
--         no savegame, so the editor's own registry numbers its junctions afresh
--   ERR   any error the editor logged while locking (and clearing): the preview runs the classifier,
--         the part reader and the note inside tryCall, which logs a failure and carries on, so without
--         this a failing reader showed as an ordinary "not read" row
-- Then which numbers F1 flags and which the reader splits. Each junction is read in a fresh process
-- (the harness re-reads the network), like dbgtypes.lua, so one lock never leaks into the next.
-- Run it twice and diff: nothing here may depend on pairs() order.

local function readRegistry(path)
    local f = assert(io.open(path, "r"))
    local txt = f:read("*a")
    f:close()
    local reg = {}
    for n, x, z in txt:gmatch('n="(%d+)"%s+x="(%-?[%d.]+)"%s+z="(%-?[%d.]+)"') do
        reg[#reg + 1] = { n = tonumber(n), x = tonumber(x), z = tonumber(z) }
    end
    return reg
end

if arg[1] == "--one" then
    -- ONE junction: --one <file> n x z [radius]
    local path, n, x, z = arg[2], tonumber(arg[3]), tonumber(arg[4]), tonumber(arg[5])
    local H = dofile("harness.lua")
    local E = ADFlyoverEditor
    local reg = readRegistry(path)

    local mine = E:junctionMeetingPointsOf(n, reg)
    local f1 = ""
    if #mine >= 2 then
        local pts, far = {}, 0
        for i, m in ipairs(mine) do
            pts[#pts + 1] = string.format("(%.1f,%.1f)", m.x, m.z)
            for j = i + 1, #mine do
                far = math.max(far, math.sqrt((m.x - mine[j].x) ^ 2 + (m.z - mine[j].z) ^ 2))
            end
        end
        f1 = string.format("F1 %d meeting points %s, up to %.1f m apart", #mine, table.concat(pts, " "), far)
    end

    -- every ERR line the editor logs (tryCall's "... failed: ...") while locking and clearing
    local errs = {}
    local function keepErrs(log)
        for _, l in ipairs(log or {}) do
            if l:find("^ERR") then errs[#errs + 1] = l end
        end
    end
    local jp, mode, log = nil, "clear", nil
    if os.getenv("MODE") == "build" then
        -- MODE=build [RADIUS=15]: every site as build mode reads it (from the lane ends alone)
        mode = "build"
        jp, log = H.lock(x, z, { mode = "build", radius = tonumber(arg[6] or "15"), leaveThrough = false })
        keepErrs(log)
    else
        local cleared = false
        if os.getenv("MODE") == "clearbuild" then
            -- MODE=clearbuild: the real clear, then build locked where the clear locked
            local cp, clog = H.lock(x, z, { mode = "clear", radius = 12, leaveThrough = (os.getenv("LEAVE") ~= "0") })
            keepErrs(clog)
            if cp ~= nil and E.junctionSite ~= nil then
                local sx, sz = E.junctionSite.x, E.junctionSite.z
                keepErrs(H.apply())
                jp, log = H.lock(sx, sz, { mode = "build", radius = tonumber(arg[6] or "15"), leaveThrough = false })
                keepErrs(log)
                mode, cleared = "cleared, then build", true
            end
        end
        if not cleared then
            jp, log = H.lock(x, z, { mode = "clear", radius = 12, leaveThrough = false })
            keepErrs(log)
            if jp == nil and tostring(E.junctionRefused):find("already clear") then
                jp, log = H.lock(x, z, { mode = "build", radius = 15, leaveThrough = false })
                keepErrs(log)
                mode = "build"
            end
        end
    end
    local site = E.junctionSite
    local cols = { string.format("j%d (%.1f,%.1f)", n, x, z) }
    if f1 ~= "" then cols[#cols + 1] = f1 end
    local split = false
    if jp == nil then
        cols[#cols + 1] = "no site: " .. tostring(E.junctionRefused)
    else
        -- (build reads the kind and the parts on a cleared site only; a wired one shows as not read)
        cols[#cols + 1] = string.format("site (%.1f,%.1f) %s: %s", site and site.x or 0, site and site.z or 0, mode,
            tostring(jp.junctionType or "kind not read"))
        local r = jp.junctionParts
        if r == nil then
            cols[#cols + 1] = "not read for parts: " .. tostring(jp.junctionPartsWhy or "not read in this mode")
        else
            local bits = {}
            for _, p in ipairs(r.parts) do
                local rs = {}
                for _, rd in ipairs(p.roads) do
                    local fl = {}
                    if rd.hasIn then fl[#fl + 1] = "in" end
                    if rd.hasOut then fl[#fl + 1] = "out" end
                    -- "1w": read with one flow and no lane back beside it, so one-way
                    if rd.oneWay then fl[#fl + 1] = "1w" end
                    rs[#rs + 1] = string.format("%s%.0f@%.1f[%s]", rd.side, rd.angle, rd.along, table.concat(fl, "+"))
                end
                -- "-" the bare number, "?" no name (no rule from the user for it)
                local name = p.letter or "?"
                if name == "" then name = "-" end
                bits[#bits + 1] = string.format("%s (%.1f,%.1f) %s {%s}", name, p.x, p.z, p.kind, table.concat(rs, " "))
            end
            cols[#cols + 1] = string.format("%d part%s: %s", #r.parts, (#r.parts == 1) and "" or "s", table.concat(bits, " || "))
            split = #r.parts >= 2
        end
        local note = E:junctionPartsNote(jp, n, site and site.x, site and site.z, reg)
        if note ~= nil then cols[#cols + 1] = "card: " .. table.concat(note, " / ") end
    end
    if #errs > 0 then cols[#cols + 1] = string.format("ERR %d: %s", #errs, table.concat(errs, " // ")) end
    print("ROW " .. table.concat(cols, " | "))
    print(string.format("FLAGS %d %s %s %d", n, (f1 ~= "") and "1" or "0", split and "1" or "0", #errs))
    return
end

-- ALL of them (or the numbers given), each in its own process.
local path = arg[1] or os.getenv("REG")
    or ((os.getenv("USERPROFILE") or "") .. "/OneDrive/Documents/My Games/FarmingSimulator2025/savegame6/ADFlyoverEditor_junctions.xml")
local want = {}
for i = 2, #arg do want[tonumber(arg[i])] = true end
local L = os.getenv("LUA") or arg[-1] or "lua"
-- RADIUS=a,b,c (build mode): every site at each radius
local radii = {}
if os.getenv("MODE") == "build" then
    for v in (os.getenv("RADIUS") or "15"):gmatch("[%d.]+") do radii[#radii + 1] = v end
end
if #radii == 0 then radii = { "" } end
local flagged, splits, moved, failed = {}, {}, {}, {}
for _, r in ipairs(readRegistry(path)) do
    if next(want) == nil or want[r.n] then
        local rows = {}
        for _, rad in ipairs(radii) do
            -- the whole command in one more pair of quotes: cmd.exe strips the outer pair when the line
            -- holds more than two
            local p = io.popen(string.format('""%s" dbgparts.lua --one "%s" %d %s %s %s 2>&1"', L, path, r.n,
                tostring(r.x), tostring(r.z), rad))
            local out = p:read("*a")
            p:close()
            local row = out:match("ROW ([^\n]*)")
            if row == nil then
                row = string.format("j%d ERROR %s", r.n, out:match("[^\n]*error[^\n]*") or out:match("[^\n]*attempt to[^\n]*") or "no result")
            end
            if #radii > 1 then print(string.format("R%s %s", rad, row)) else print(row) end
            rows[#rows + 1] = row
            if rad == radii[1] then
                local f1, sp = out:match("FLAGS %d+ (%d) (%d)")
                if f1 == "1" then flagged[#flagged + 1] = "j" .. r.n end
                if sp == "1" then splits[#splits + 1] = "j" .. r.n end
            end
            -- no FLAGS line at all is a failure too (the process died before it could say)
            local ne = out:match("FLAGS %d+ %d %d (%d+)")
            if (ne == nil or ne ~= "0") and failed[#failed] ~= "j" .. r.n then failed[#failed + 1] = "j" .. r.n end
            io.stdout:flush()
        end
        for k = 2, #rows do
            if rows[k] ~= rows[1] then moved[#moved + 1] = "j" .. r.n break end
        end
    end
end
print("-- F1 (one number, several meeting points): " .. ((#flagged > 0) and table.concat(flagged, " ") or "none"))
print("-- the part reader splits: " .. ((#splits > 0) and table.concat(splits, " ") or "none"))
print("-- errors logged at: " .. ((#failed > 0) and table.concat(failed, " ") or "none"))
if #radii > 1 then
    print(string.format("-- the reading changes with the wheel (%s) at: %s", table.concat(radii, ","),
        (#moved > 0) and table.concat(moved, " ") or "none"))
end

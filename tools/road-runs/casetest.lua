-- Test cases saved in game (detection view "paint area" -> roadPaint_N.xml, kept in cases/):
-- each walks its track from several mouse spots and checks the line against the case's own ruler.
--   lua casetest.lua         (runs every case below; each in its own Lua so the AREA ground loads)
local HERE = (arg[0]:match("^(.*)[/\]") or ".") .. "/"
local L = '"C:/Program Files (x86)/Lua/5.1/lua.exe"'
local CASES = {
    -- the x~579 field track to the road at (575,-397): a 3 m painted strip, straight, then a ~35 deg
    -- bend into the road's shoulder (user, 2026-10-13: "one straight track end to end, except for
    -- the turn in the track to hit the road")
    { file = "cases/track579_bend.xml", spots = { { 579.5, -500 }, { 579.5, -650 }, { 579.6, -420 } },
      straight = { x = 579.5, z0 = -690, z1 = -410, mean = 0.2, worst = 0.5 },
      bend = { { -400, 575.0, 578.0 }, { -398.5, 574.5, 577.5 } },   -- z, the strip's x range: the line within it
      ends = { -389, 1.5 } },                                       -- the line reaches the asphalt (z ~-389) across the shoulder
}
local fails = 0
for _, c in ipairs(CASES) do
    for _, sp in ipairs(c.spots) do
        local cmd = string.format('cd /d "%s" && set AREA=%s && %s bendplot.lua %s %s 0 0 0 0', HERE, c.file, L, sp[1], sp[2])
        local p = io.popen(cmd .. " 2>&1"); local out = p:read("*a"); p:close()
        local line = {}
        for x, z in out:gmatch("l (%S+) (%S+)") do line[#line + 1] = { x = tonumber(x), z = tonumber(z) } end
        local function xAt(z)
            for i = 2, #line do
                local a, b = line[i - 1], line[i]
                if (a.z - z) * (b.z - z) <= 0 and a.z ~= b.z then return a.x + (b.x - a.x) * (z - a.z) / (b.z - a.z) end
            end
        end
        local sum, n, worst = 0, 0, 0
        for z = c.straight.z0, c.straight.z1, 2 do
            local x = xAt(z)
            if x then local d = math.abs(x - c.straight.x) sum, n, worst = sum + d, n + 1, math.max(worst, d) end
        end
        local ok = n > 0 and sum / n <= c.straight.mean and worst <= c.straight.worst
        local notes = { string.format("straight %.2f/%.2f m", n > 0 and sum / n or -1, worst) }
        for _, b in ipairs(c.bend) do
            local x = xAt(b[1])
            local inside = x ~= nil and x >= b[2] and x <= b[3]
            ok = ok and inside
            notes[#notes + 1] = string.format("z %.1f at x %s", b[1], x and string.format("%.1f", x) or "-")
        end
        local reach = false
        for _, q in ipairs(line) do if math.abs(q.z - c.ends[1]) <= c.ends[2] then reach = true end end
        ok = ok and reach
        notes[#notes + 1] = reach and "reaches the asphalt" or "STOPS SHORT"
        print(string.format("%s %s from (%.1f,%.1f): %s", ok and "ok  " or "FAIL", c.file, sp[1], sp[2], table.concat(notes, ", ")))
        if not ok then fails = fails + 1 end
    end
end
print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))

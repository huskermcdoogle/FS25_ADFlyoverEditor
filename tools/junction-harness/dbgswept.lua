-- The junction preview's swept-path prediction, with the twin ON. reg75.sh runs with it off - it
-- tests the clear, which never drives the twin - so a SweptSim change needs this instead.
--   [TERRAIN=1] [SWEPT_SRC=<SweptSim.lua>] lua dbgswept.lua X Z
-- Build mode with rebuild on, so every turn the junction already has is re-solved and driven by the
-- design rig (SweptSim.EXAMPLE_RIG). With TERRAIN=1 the road-surface check is live as well, so the
-- swept gate (trailer off the road) can refuse a radius and the sweep-wide reshape runs; without it
-- only the prediction itself is measured. Prints one line per turn, sorted, then a summary.
--   RIGS=small,big,semi picks which rigs of the vehicle set (SweptSim.RIGS) must fit; unset, the
--   editor's default (the two tractor rigs). RIGS=semi is the old single design rig.
local H = dofile("harness.lua")
dofile(os.getenv("SWEPT_SRC") or "../../scripts/editor/SweptSim.lua")
if os.getenv("RIGS") then
    local want = {}
    for k in os.getenv("RIGS"):gmatch("[^,]+") do want[k] = true end
    ADFlyoverEditor.junctionRigs = {}
    for _, g in ipairs(SweptSim.RIGS) do ADFlyoverEditor.junctionRigs[g.key] = want[g.key] == true end
end

-- Every twin run: how many, how many ran out of time before the route ended, the slowest speed.
local runs, outOfTime, slowest = 0, 0, math.huge
local simulate = SweptSim.simulate
SweptSim.simulate = function(path, rig, driver, start, opts)
    local out = simulate(path, rig, driver, start, opts)
    runs = runs + 1
    local last = out[#out]
    if last ~= nil and last.t >= ((opts and opts.maxTime) or 240) - 0.05 then outOfTime = outOfTime + 1 end
    for _, s in ipairs(out) do slowest = math.min(slowest, s.v) end
    return out
end

local E = ADFlyoverEditor
local cx, cz = tonumber(arg[1]), tonumber(arg[2])
LOG = {}
E.tool = E.TOOL.JUNCTION
E.junctionMode = "build"
E.junctionLeaveThrough = (os.getenv("LEAVE") ~= "0")
E.junctionRadius = 12
E.junctionTurnRadius = 12
E.junctionRebuild = true
E.junctionCheckSurface = (os.getenv("TERRAIN") == "1")
E.junctionCheckObstacles = false   -- engine overlapBox, no offline stand-in
E.junctionSwept = true
E.junctionExtendTrim = true
E.junctionUseDubins = true
E.cursorX, E.cursorZ, E.cursorY = cx, cz, 0
E.junctionArmed = { cx = cx, cz = cz, cy = 0 }
E.junctionPreviewKey = nil
E.junctionPreview = nil
E:updateJunctionPreview()
local jp = E.junctionPreview or {}

local rows = {}
for _, m in ipairs(jp.movements or {}) do
    if m.connector ~= nil and (not m.exists or m.rebuild) then
        local sw, c = m.swept, m.connector
        rows[#rows + 1] = string.format("  %d->%d r=%s %s%s | %s",
            m.from.wp.id, m.to.wp.id, m.usedRadius and string.format("%.0f", m.usedRadius) or "-",
            m.refused and ("REFUSED " .. m.refused) or "laid",
            c.sweep and string.format(" sweep %.1f m%s", c.sweep, c.kickEarly and " kickout" or " inside") or "",
            sw and string.format("%s tow in %.2f, trailer in %.2f out %.2f -> %s", sw.leftTurn and "L" or "R",
                sw.towIn, sw.trailerIn, sw.trailerOut, sw.wide and "PAST CORRIDOR" or "fits") or "no prediction")
    elseif m.refused ~= nil and (not m.exists or m.rebuild) then
        -- Refused with nothing to show (the last radius tried laid no curve at all) - still a turn.
        rows[#rows + 1] = string.format("  %d->%d r=%s REFUSED %s | no connector",
            m.from.wp.id, m.to.wp.id, m.usedRadius and string.format("%.0f", m.usedRadius) or "-", m.refused)
    end
end
table.sort(rows)
if os.getenv("SHOWLOG") then for _, l in ipairs(LOG or {}) do if l:find(os.getenv("SHOWLOG"), 1, true) then print("LOG " .. l) end end end
for _, r in ipairs(rows) do print(r) end
for k, f in pairs(jp.rigFits or {}) do print(string.format("RIGFIT %s %d/%d", k, f.fit, f.total)) end
print(string.format("SUMMARY turns %d | new %d rebuild %d | refused: tight %d offroad %d trailerRoad %d | swept wide %d, worst trailer cut %.2f m, sweeps %d | twin runs %d, out of time %d, slowest %.1f km/h",
    #rows, jp.nNew or 0, jp.nRebuild or 0, jp.nTight or 0, jp.nOffRoad or 0, jp.nTrailerRoad or 0,
    jp.nSweptWide or 0, jp.sweptMax or 0, jp.nSweep or 0, runs, outOfTime, runs > 0 and slowest or -1))

-- The junction preview's swept-path prediction, with the twin ON. reg75.sh runs with it off - it
-- tests the clear, which never drives the twin - so a SweptSim change needs this instead.
--   [TERRAIN=1] [SWEPT_SRC=<SweptSim.lua>] lua dbgswept.lua X Z
-- Build mode with rebuild on, so every turn the junction already has is re-solved and driven by the
-- design rig (SweptSim.EXAMPLE_RIG). With TERRAIN=1 the road-surface check is live as well, so the
-- swept gate (trailer off the road) can refuse a radius and the sweep-wide reshape runs; without it
-- only the prediction itself is measured. Prints one line per turn, sorted, then a summary.
local H = dofile("harness.lua")
dofile(os.getenv("SWEPT_SRC") or "../../scripts/editor/SweptSim.lua")
ADFlyoverSweptPath = { rig = SweptSim.EXAMPLE_RIG }

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
    end
end
table.sort(rows)
for _, r in ipairs(rows) do print(r) end
print(string.format("SUMMARY turns %d | new %d rebuild %d | refused: tight %d offroad %d trailerRoad %d | swept wide %d, worst trailer cut %.2f m, sweeps %d | twin runs %d, out of time %d, slowest %.1f km/h",
    #rows, jp.nNew or 0, jp.nRebuild or 0, jp.nTight or 0, jp.nOffRoad or 0, jp.nTrailerRoad or 0,
    jp.nSweptWide or 0, jp.sweptMax or 0, jp.nSweep or 0, runs, outOfTime, runs > 0 and slowest or -1))

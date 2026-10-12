# Road runs tool

*Branch `claude/road-track-autodrive-tool-62eb44`, off main (1.0.2.2). Started 2026-10-12. Not yet tried in game.*

## What it does

Lays AutoDrive runs along map roads and farm tracks that have no path yet.

- **Hover** a road: the stretch from one fork to the next lights up, with the lanes it would lay.
- **Click** picks it. Click a picked road again to drop it.
- **Double-click** picks the whole road, carrying straight on through forks.
- **Right-click** builds everything picked. One undo takes it all back.
- For a **one-way** run, click on the side you'd drive on (keep right). The arrows show the direction while you hover.

## The card

| Row | Choices |
|---|---|
| lay as | **auto** (two lanes on paved, one two-way line on tracks), one-way, two-way, two lanes |
| priority | primary / secondary |
| roads to find | paved, gravel, dirt (all on) |
| light up | under mouse / **all nearby** (faint) |
| lane gap | **from road** / set (typed). The card shows this road's width and the map's own lane gap |
| fork gap | 15 m, the room left at forks for the junction tool |

Agreed with you on 2026-10-12: P/S = primary/secondary; stop short at forks; join a path the road runs into; click and double-click (no box); highlight toggle; all three road kinds on.

## How it finds roads

- It reads the ground paint in a 384 m square round the mouse. This takes about 4 ms a frame, so you can keep working while it reads.
- Asphalt and concrete count as **paved**. Gravel and dirt count as **track**. The two are worked out apart, so a paved road's gravel shoulder doesn't widen it.
- Rock and fields don't count as road. This uses the junction branch's fixes. The rock check needs the host. If you're not the host, the card says so.
- Farm tracks painted as two wheel ruts are read as one track.
- Each road is thinned down to its middle line. Forks are found where lines meet.
- Yards, parking lots, short scraps and kerb strips are dropped.

## Measured on Riverbend (offline, real ground and your network)

- **Centre line:** on roads that already have two lanes, the found middle sits within 0.1 m of the middle between them.
- **Lane gap:** those lanes are about **0.6 × the road's width** apart (a 6 m road has lanes 3.8 m apart). "From road" uses that rule, and never goes under 3.3 m.
- **Map road lines (step 4):** every one of the map's 1,094 road lines (76 km) already has an AutoDrive path on your save. So reading them would add nothing to finding roads without paths. **I skipped this step.** Your call whether to do it anyway.
- **Error sweep:** I ran the tool on 25 spots across the map (hover, click, double-click, build, join) with no errors.

## Test in game (4 items, pass/fail)

1. Pick the road runs tool (Create group). Within a few seconds, roads with no path light up faintly near the mouse.
2. Hover a farm track, click it, then right-click. A two-way line is laid down the middle, stopping short of the forks. Q undoes it in one step.
3. Set "lay as: two lanes" on a paved road with no path, then build. You get two lanes, keeping right, about as far apart as the map's own.
4. Double-click a long road. It carries on through the forks, with gaps left at each one.

## Not done or known limits

- Roads on **bridges** aren't found. The paint under a bridge is the river, so the road ends at each side.
- No **icon** yet. The icon sheet is full, so it shows as text only.
- The card settings last only for the session (not saved).
- When the junction builder ties these runs in automatically later, it will need the run ends marked. That isn't recorded yet.

## Files

- `scripts/editor/RoadFinder.lua`: finds the roads. Pure Lua; the same code runs offline.
- `scripts/editor/RoadRunsTool.lua`: the tool (card, hover, picks, build, draw).
- `tools/road-runs/`:
  - `bench.lua` + `view.py`: draw any spot as a pan/zoom page.
  - `tooltest.lua`: drives the tool offline.
  - `widthstudy.lua`: road width vs lane gap.
  - `splinecheck.lua`: the map road lines check.
  - `sync_help.py`: updates only this tool's help.
  - The data comes from the junction branch's harness (`terrain_data/`, `graph_data.lua`).

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
| lay as | **auto** (two lanes on paved roads 4.5 m+ wide, else one two-way line), one-way, two-way, two lanes |
| priority | primary / secondary |
| roads to find | paved, gravel, dirt (all on) |
| light up | under mouse / **all nearby** (faint) |
| lane gap | **from road** / set (typed). The card shows this road's width and the map's own lane gap |
| side check | **bridges** / everywhere: lanes move in to clear railings (and walls, posts, trees, banks) |
| rig width | 3.0 m: the widest rig to pass. Lanes stay at least this + 0.3 m apart |
| fork gap | 7.5 m, the room left at forks for the junction tool (its clear trims or extends to its own box) |

Agreed with you on 2026-10-12: P/S = primary/secondary; stop short at forks; join a path the road runs into; click and double-click (no box); highlight toggle; all three road kinds on.

## How it finds roads

- It reads the ground paint in a 384 m square round the mouse. This takes about 4 ms a frame, so you can keep working while it reads.
- Asphalt and concrete count as **paved**. Gravel and dirt count as **track**. The two are worked out apart, so a paved road's gravel shoulder doesn't widen it.
- Rock and fields don't count as road. This uses the junction branch's fixes. The rock check needs the host. If you're not the host, the card says so.
- Farm tracks painted as two wheel ruts are read as one track.
- Each road is thinned down to its middle line. Forks are found where lines meet.
- **At a fork the road that carries straight on goes straight through** (one run); only the side road stops short. At a crossing the straighter road goes through.
- A patch beside a track (bare ground at a tree's foot) no longer splits it into a loop with two false forks.
- Farm tracks are two ruts with grass between: the line runs halfway between the ruts.
- Yards, parking lots, short scraps and kerb strips are dropped.

## Bridges and ramps (added 2026-10-12, your ask)

- **Finding them:** bridge decks and ramps are road meshes with the game's "road" collision flag (`ROAD`). A downward ray finds them and their height. It checks every 4 m first, then every 1 m where it hits one.
- **Raised decks:** these are their own road lines, joined to the ground road at each end. So a road carries straight across a river, and a flyover never makes a false crossing with the road under it.
- **Ground level:** a ramp's foot or a level crossing counts as paved road.
- **Side check:** on bridges, or on every road with "everywhere", the tool looks out from the middle on each side. It stops at the first thing in the way:
  - a railing, wall, post or tree, 0.8–2.8 m up
  - the edge of the deck
  - on the ground, a bank rising over 1 m or a drop of over 1.5 m
- **Two lanes:** each lane moves in as far as it needs to, keeping half a rig (1.5 m) plus 0.3 m from the side. The lanes stay at least 3.3 m apart.
- **Too narrow for two:** that part becomes **one two-way line** down the middle, with the lanes easing into it and out of it over about 12 m.
- **One-line modes:** the line just moves off the middle if one side is tight.
- **Tested on made-up bridges** (railings at the deck edge, 3.0 m rig):

  | Deck width | Result |
  |---|---|
  | 9 m | two lanes as normal |
  | 8 m | lanes move in to 3.55 m apart, then back to 4.2 m on the road |
  | 7 m | one two-way line (two rigs need 6.9 m between railings) |
  | 5 m | one two-way line |

  The built network can be driven end to end both ways.
- **Not proven yet:** that the real bridges on Riverbend carry the road flag, and that their railings get hit by the side check. The log line "N bridge/ramp landing(s) joined" will tell us.
- **Ramps that aren't road meshes are not found.** That means yard loading ramps and some placeables. Those are plain static objects, and so are roofs and walls, so I left them out.

## Measured on Riverbend (offline, real ground and your network)

- **Centre line:** on roads that already have two lanes, the found middle sits within 0.1 m of the middle between them.
- **Lane gap:** those lanes are about **0.6 × the road's width** apart (a 6 m road has lanes 3.8 m apart). "From road" uses that rule, and never goes under 3.3 m.
- **Map road lines (step 4):** every one of the map's 1,094 road lines (76 km) already has an AutoDrive path on your save. So reading them would add nothing to finding roads without paths. **I skipped this step.** Your call whether to do it anyway.
- **Error sweep:** I ran the tool on 25 spots across the map (hover, click, double-click, build, join) with no errors.

## Test in game (5 items, pass/fail)

1. Pick the road runs tool (Create group). Within a few seconds, roads with no path light up faintly near the mouse.
2. Hover a farm track, click it, then right-click. A two-way line is laid down the middle, stopping short of the forks. Q undoes it in one step.
3. Set "lay as: two lanes" on a paved road with no path, then build. You get two lanes, keeping right, about as far apart as the map's own.
4. Double-click a long road. It carries on through the forks, with gaps left at each one.
5. Hover a road that crosses a river. It lights up straight across the bridge. Built as two lanes, a narrow bridge gets one two-way line. Check on a wide bridge that a big rig passes the railings.

## Not done or known limits

- While you only hover, the side check runs on bridges only. The full "everywhere" check runs once you pick the road, to avoid stutter.
- Card settings are saved between sessions.
- No **icon** yet. The icon sheet is full, so it shows as text only.
- When the junction builder ties these runs in automatically later, it will need the run ends marked. That isn't recorded yet.

## Files

- `scripts/editor/RoadFinder.lua`: finds the roads. Pure Lua; the same code runs offline.
- `scripts/editor/RoadRunsTool.lua`: the tool (card, hover, picks, build, draw).
- `tools/road-runs/`:
  - `bench.lua` + `view.py`: draw any spot as a pan/zoom page.
  - `tooltest.lua`: drives the tool offline (`SYNTH=bridge` runs it over a made-up bridge).
  - `bridgetest.lua`: made-up bridges and a wall, for the lane fitting.
  - `widthstudy.lua`: road width vs lane gap.
  - `splinecheck.lua`: the map road lines check.
  - `sync_help.py`: updates only this tool's help.
  - The data comes from the junction branch's harness (`terrain_data/`, `graph_data.lua`).

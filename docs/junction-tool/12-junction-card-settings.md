# The junction card: every setting, and what to do with it (2026-10-11)

The user, 2026-10-11: "we need to tighten up the junction tool as the menu has become very busy, so we
need to research that, and discuss and come up with a plan to make it smarter and decide for us, and
be the best it can be at this time." This is the research. The proposal at the end is **for
discussion** - nothing is changed yet.

Sources: the card code (`FlyoverHud.lua` 757-1115), the switches (`TypedEntry.lua` 337-480), the saved
settings (`modSettings/FS25_ADFlyoverEditor/settings.xml`), and what the logs show being used: the game
log plus the 41 debug captures' tool logs, 60 junction locks in all. Some switches only write a log
line when debug logging is on, and the number steppers write none, so "seen used" is a floor.

## What is on the card today

### Settings you can change

| Card row | Mode | What it does | Default | Kept after restart | Seen used |
|---|---|---|---|---|---|
| action | all | Build, clear or place. | build | no | 35 builds, 20 clears, 5 places |
| junction numbers | all | Numbers over the junctions. | on | yes | - |
| search radius | build, place | How far from the click it looks for the junction's lanes. Clear ignores it (the junction sets its own). Build also grows it to the lane ends a clear cut, up to 30 m. | 15 m | yes | 11 m most (15x), 15 (9x), 14 (7x), 30 (3x), 8 (1x); saved now: 22 m |
| turn radius | build, place | The size the turns start at; each turn steps down from it until it fits. | 12 m | saved, but never read back until 2026-10-11: it started at 12 m every session | 6 m most (18x), 5 (9x), 4 (4x), 3 and 7 (2x each); saved now: 11 m |
| road check | build | Refuses turns that leave the road surface (asphalt, gravel, dirt). Off: only the radius limits a turn. | on | no | off 2x |
| trim/extend | build | Lets a turn reach past where a stem was cut back. Off: it stops at the cut. | on | no | off once, on once |
| existing turns | build | Keep turns already there, or rebuild them. | keep | no | once |
| curve | build | Dubins or biarc curves. With Dubins on, the shorter of the two is used anyway. | dubins | no | biarc once |
| obstacles | build | Refuses turns that run through a tree, fence or building. | on | no | off 3x, on 2x |
| swept path | build | Drives the vehicle set through each turn and refuses it if the rig leaves the road or hits something. | on | no | off 4x, on 4x |
| small / big / semi | build | Which rigs every turn must fit. | small, big | no | toggled 15x |
| corridor | build | How wide a strip along the turn must be road (road check). | 4 m | no | no record |
| clearance | build | How wide a strip along the turn must be free of obstacles. | 5 m | no | no record |
| leave through paths | clear | Keep the through roads, or clear them too. | on | no | off once, on once |
| debug capture | clear | Saves the network before and after every change. | off | no | on 3x |
| shape | place | The mod's shape or the smooth one. | mod | no | no record |

### Lines that only report

About 30 more lines appear depending on the mode. A few say what matters - which junction, what kind,
what was decided, the last build's route check. Most are counters (approaches, new movements, radius
used, refused as tight, off road, no curve, U-turn, too far, redundant lane, blocked, laid wide, rig off
road, rig hits, already there, trailer cut-in, past corridor, confidence) that only help while
debugging. Clear adds its own (approaches found, will clear, through points kept, lane ends to box
edge).

### You can't type into the numbers

Every other tool's numbers are boxes you can click and type into (`getEditableNumbers`,
`TypedEntry.lua` 26). The junction tool's four - search radius, turn radius, corridor, clearance - were
never added to that list, so they can only be stepped. **Fixed 2026-10-11:** all four are typed boxes now
(the radii in whole metres), and the saved turn radius is read back when the tool opens.

### What the tool already decides by itself

61 internal values, 27 of them on/off switches (`AutoDrive.FLYOVER_JUNCTION_*`): lay the mod's pattern
where it fits, two-way turns on two-way roads, share crossings, clean the site first, grow the circle to
the cut lane ends, space the turn points, and so on. None of them is on the card. The card's own
switches are mostly the same kind of thing - checks and engine choices that came in while the tool was
being built.

## Proposal - for discussion

**One idea first:** you pick a junction, the card says what the tool found and what it will do, you
press Build. Everything else goes under "advanced", closed by default.

| Card row | Proposal | Why |
|---|---|---|
| action | **Build** clears and builds in one go; Clear only and Place go under advanced | You nearly always clear and then build. Build already lays the mod's pattern where it fits, which is most of what Place does. |
| junction numbers | stays | Display only. |
| search radius | **tool decides**, override under advanced | The junction's number already says where it is and how big; clear already sets its own. |
| turn radius | **tool decides**, override under advanced | It already steps down until a turn fits. Start from the road type (farm track small, two-lane road larger) and show "radius used". |
| road check, obstacles, swept path | **always on**, switches under advanced | They keep trucks on the road and out of trees. Turning them off was for testing. |
| trim/extend, curve | **remove** (keep the current behaviour) | Engine choices; nobody should need them. |
| existing turns | under advanced | Clear-then-build replaces the old turns anyway. |
| vehicle set | one line: "fits: small, big" - click to change | It is a real choice, but rarely changed once set. Saved between sessions. |
| corridor, clearance | **tool decides** from the vehicle set's width | They are a vehicle's width plus a margin. |
| leave through paths | one line: "through roads: kept" - click to change | A real choice per junction. |
| debug capture | under advanced | For finding faults. |
| shape | **tool decides** (mod's shape where it fits, smooth where it doesn't) | Same as Build already does. |
| report lines | junction, kind, what it will do, warnings only when something is refused | The counters go to the log and to advanced. |

**The short card might read:**

```
JUNCTION           j07 - T, two-lane roads
WILL DO            clear 14 points, lay the mod's T
TURNS              radius 10 m, fit small and big
THROUGH ROADS      kept                      (click)
LAST BUILD         all 6 routes as meant
                   [ Build ]
advanced  >
```

## To settle with the user

1. Build = clear and build in one go, with Clear only and Place under advanced?
2. Which rows stay on the short card, which go under advanced, and which go entirely?
3. The vehicle set's default (today: small and big must fit).
4. Through roads kept by default?
5. Typing into the numbers: fix it now, whatever else is decided.

## Decided (2026-10-11)

- **Typing into the numbers:** done (c400220), with the saved turn radius read back.
- **The action row:** clear | build | clear + build, starting on clear + build. The user wants the choice
  kept; one row of three adds nothing over today's build | clear | place.
- **Place:** the user wants to discuss whether it goes. Proposed: once build lays the mod's pattern
  wherever it fits, place does the same job and goes; the mod / smooth shape choice moves under advanced.
- **The pattern:** the user leans to a mod-like pattern for every built or placed junction. Why it was not
  used on the test course: the mod's pattern anchors to a road whose lanes run through the middle, and
  every course junction had its middle emptied (J2 got the plain X: "no main-road lane runs past the side
  road the right way"; J4 none: "it would leave 6 lane ends loose"). Chosen: **A now** - fit the mod's
  pieces in more cases (empty middles, other lane gaps, skewed angles) for the release; **B after** - a
  pattern recipe for every junction kind (T, X, Y, farm tracks, two-way roads), designed together.
- **The short card (from two clickable mocks):**
  - Each action's options sit right under the action row: clear has "through roads"; build has
    "shape: pattern | smooth" and "must fit"; clear + build has all three. The user: "through roads kept
    is a dependent for clear, must fit is a dependent for clear+build and build".
  - **Shape is on the short card,** not under advanced: "smooth/pattern ... needs to be at this level".
  - Then: junction, will do, turns (radius the tool picked, or yours), last build, and the go button.
  - **Advanced:** search radius and turn radius (blank = the tool picks), road check, obstacles, swept
    path, old turns, corridor (from the rigs), debug capture, counters, and **"if the pattern won't fit:
    smooth | refuse"** - the user: "fallback or refuse should be an advanced setting". Default: smooth.
  - Gone: curve type, trim/extend, the report counters on the card face.
- **Built (2026-10-11):** the short card as above. Shape reuses place's two shapes ("mod", "smooth" -
  both the X/T pattern), and "pattern won't fit" chooses between the turn-by-turn build (default) and
  refuse. Clear + build is one right-click and one undo; on a junction with nothing wired it goes straight
  to the build. The card says before the right-click what the build will lay (the pattern fit is checked
  dry on a locked site). Not built yet: "blank = the tool picks" for the two radii (they stay typed
  numbers under advanced), corridor and clearance from the rigs, and the mouse wheel turns the search
  radius only while advanced is open. Place is off the action row; its code stays until step A is done.
  Offline: `tools/junction-harness/dbgcard.lua` prints the card's rows for any junction and action.

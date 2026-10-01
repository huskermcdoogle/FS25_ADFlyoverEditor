# Fit methods: reference

*Draft 1, 2026-09-30. Companion to [Fit methods and the grade](04-fit-methods-and-grade.md): the details
for whoever builds it.*

## Code

Lines are for the working tree of `scripts/editor/FlyoverEditor.lua`, with the uncommitted meeting point
and rock fix. Against `c7dfb02`: the same up to `:9171`; 38 higher from `:9172`; 54 higher from `:9262`
to about `:18140`; 60-500 higher inside `junctionClassify` (`:18141-19067`); 500 higher from `:19068` to
the end (`junctionParts` 19258 against 18758). They will shift.

- **Centres:** fork average `junctionRegistry` `:11103-11264` (4+ forks chained within 15 m). The
  arm-length test `:10544-10557`: under 3 arms of `MIN_ARM` (15 m, `:385`) is refused only when the site
  is not a proper cluster (4+ forks) and not from turn corners. Turn corners `junctionCentres`
  `:10322-10404` (turns of 30-150° under 60 m; merge 10 m; 1.0 m typical from the box; 7 m off at 26
  and 53). Lane-end ring `junctionVirginCentres` `:10267-10320`.
- **Box:** `junctionTidyLaneEnds` `:14803`. Side road line: stops 8 m short of the centre, heading over
  the 10 m before that, carried straight `:15100-15127`. Width = 80th percentile of lane gaps 8-30 m out
  `:15244-15315`, minimum 2.5 m `:15186`. Crossing `:15359-15392`: within 25 m, only `|cos| <= 0.85`
  (`:15368`), so roads under about 32° apart get no box.
- **The centre only sets reach:** 25 m `:15383`, `:15389`; 18 m `:15794`; 16 m `:15937`; 40 m in
  `inOther`. The cut itself is by strips: `inBox` / `inOther` `:16748-16771` (within a road's offset of
  its middle line).
- **Preview dry run:** `junctionTidyLaneEnds(self.junctionPreview, true)` `:13535`; dry branch
  `:16267-16302`. Returns ends, strips, sweep, roads and box centre. Writes no deletion record.
- **Respacing:** `FLYOVER_JUNCTION_RESPACE_LEN = 50` `:391`, step 5 m. Removals go through `jxRemove`
  as "junction respace surplus" `:16638`.
- **Classifier:** `junctionClassify` `:18062`; `mainLineAt` `:18147` (8 m either side); `SIDE_LEN`
  `:18267`; why 6 m `:18310-18320` (42 reads 64.7° at 6 m); `roadStart` `:18442`; `roadReading`
  `:18486`; held at the mouth `:18675`; 38/62° `:19070`; crossroads `cross()` `:18923-18936`;
  `junctionParts` `:19258`. Meeting point against the map's lines: angle error 0.88° to 0.60°.
- **Stubs:** `junctionTidyByPaths` `:16726`; `inOther` `:16754-16771`; carry `:17202-17591`. Builder
  turn start `junctionTrackConnector` `:13878-14041`: R·tan(turn/2) back, R = 12 m (`:13946`).
- **Reusable for the grade:** lane-level warning `:20048-20108` (it measures from the middle, which on a
  skewed road differs by lane gap × skew, about 4 m at 45°; maybe why it fired at 24 of 60, a guess);
  deletion record `jxRemove` `:9992-10016`; taken-by-stage log `:20209-20224`; undo snapshot `:19977`;
  obstacle test `junctionObstacleHitsAlong` `:14127-14180`; `isRoadAt` `:9234-9282`; recorder
  `scripts/Prelude.lua:643-648`; offline teal rule `tools/junction-harness/dbgrow.lua`.
- **Paint in game:** `getTerrainAttributesAtWorldPos` (see 03b), asphalt by colour. Find an edge by
  halving the step: 15-20 reads per edge.
- **Cost (estimate):** grade once on pick, never per frame (the preview redraws every frame,
  `:19838-19840`). Per fit a few hundred paint reads and 2-4 extra previews; a few hundred obstacle boxes
  shared. Log the time; spread over frames above about 2 ms.
- **Follow the curve:** circle fit over 20 m past `roadStart`; only below a radius of about 100 m.
  Stopping at the asphalt edge and going straight gives the same point within 0.3 m. To try it in the
  tool: a patched copy run with `FE_SRC` through `dbgtypes MEETS=` and `exact.py`.
- **Offline grade:** the harness has no terrain (`harness.lua:29-37, 164-165`). Feed it paint and heights
  per junction as small Lua tables, switched on per test so stray engine calls still fail. For edge from
  paint alone, a file of asphalt half-widths per junction is enough. Add grade columns to `reg75.sh`, both
  modes, run twice.

## How each check could lie

| Check | How it could lie | Offline test |
|---|---|---|
| 1. Middle empty | Teal dots miss a crossing with no merge. A route walk not stopped at the stubs finds the long way round. | Exact; the teal rule runs offline today. |
| 2. Nothing else touched | A before/after diff once read 399 points out to 75 m; the truth was 30-110 inside 44 m (moved points counted as deleted). The respacing removes and re-lays points out to 50 m by design (45-91 removed, 34-80 added within 60 m). The record alone misses a deletion that bypasses `jxRemove`. So use both, and allow respacing its own reach and a kept-lane tolerance measured from how far respacing moves a lane. | Exact. |
| 3. Stubs in their own road | A narrow track needs paint finer than 1 m. | 1 m paint. |
| 4. Stubs reach the edge, level | Edge from paint passes by construction if the check reads the same stations, and a tip beside the mouth passes on distance alone (66: on gravel 9 m before the asphalt, yet 0.3-0.9 m past the edge line). Read the edge at the tip's own spot, corner to corner across the mouth. A paved yard has no edge: "can't tell". A single lane has no partner. | 1 m paint, about 0.5 m either way. |
| 5. Stub direction | Against the same road 20-30 m out it fails a correct stub on a curving road (27: the road runs about 59° out there, the mouth square, today's stubs about 72°). Bridges. | Height map matches AutoDrive to 0.4 mm. |
| 6. Side road's middle | Corners widen the paving near the mouth; further out misses a curve-in. Borrowing the fit's own heading makes it agree with the fit. | See below: no reader is ready. |
| 7. Same answer | Stable is not right. | The old pick-test scripts (`vary.lua`, `lockpt.lua`) are gone. Rewrite as a harness script beside `dbgstages.lua`. |
| Road reading | A bend (then "unsure"); a driveway under a reading. | Within 1 m at 37 of 48. |

**Which checks can fail each fit:** follow the curve passes at 34 and 42 only on checks that can't see
it today: the stub checks (stubs don't follow the fit yet), the road reading (the same for every fit) and
check 6 (no answer or "unsure" there). The paint mouth is close kin to check 6's paint reading. The
agreement of today's point and follow the curve on straight roads is not independent: both come from
the lanes.

## Where each number comes from

**Paint.** `inv/trial.py`, `pave/mouth2.py` and `pave/jsite.py` (largest circle) counted any paint with
drive cost 4: asphalt, concrete and `rockFloorTiles`. `grade/paint_offsets.py`, `grade/side_v2.py` and
the reruns in `fix04/` count asphalt only, the decided edge. Rerun on asphalt only: the straight-across
paint mouth is unchanged within 0.6 m at 44 of 48 T's and Y's, but moves 7-18 m at 35, 46, 50 and 52,
where concrete or a paved yard touches the mouth. Stub counts and `mouth2.py` at the weak five are
unchanged. The largest circle was not rerun.

**Situations and kinds.**

- Kinds: `cl/tooltypes_final.txt` against `truth_types.txt`. Cleared: 69 "no main road found" (you: T
  skew), 70 T square (Y merge ?), 71 4W square (T square), 74 T skew (T square), 75 Corner T (T square).
- No box: `inv/all.txt` has no road lines at 31, 36 and 53. 35 (37.4°) and 50 (36.5°) have a box.
- Single lane: `inv/all.txt` road b at 2.50 m with one track at 20 and 25; one side lane at 26.
- Main road fixes: `d525100` (22's hairpin: the turn judged 8 m either side; 65's turnaround: a
  loop-back is not an arm), `e6e0d08` (50's S-bend: arms grouped by place), `c8feb5a` (main road read 8 m
  along each lane: 12, 22, 51, 63; not addressed 40, 46, 58, 65). 62 is from the earlier draft.
- Cleared sites have asphalt: 10 m round each registry point, 189, 205 and 104 of 317 cells at 70, 71 and
  75. What is missing there is the painted masks (03).
- Asphalt per map (`critic04/cover.py`, each map's paint file): here 6.6%, Genesee 3.8%, Alma 1.2%
  (gravel-type paints 4-5%), Welker 0.07% (grass 92%). Welker's roads may not be painted at all.
- Decks (`fix04/deck_box.py`): AutoDrive points over 1.5 m above the save's height map, within 50 m of
  the box: 46 22 m, 25 23 m, 34 26 m, 42 29 m, 37 34 m, 74 37 m, 26 40 m, 44 41 m, and one at 71 (47 m).
  The old 21-27 m were measured from the fork average.
- Meeting point to box (`inv/all.txt`): typically 0.37 m over 51 sites; 2 6.4 m, 26 5.9 m, 66 2.7 m, 27
  1.9 m.

**Why curving roads are off.**

- Where each side road starts (`inv/trial.json`): 27 13.3 m, 34 13.6 m, 42 6.7 m, 51 7.8 m, 66 9.7 m.
- Skew shift of the straight-across mouth, from geometry: (half-width + 0.5) × cot(angle) = 3.2, 6.3,
  3.5, 2.0 m at 3, 7, 41, 61; measured 6.1, 6.9, 2.7, 2.2 m. Leftover about 3 m at 3 and 27; 2.3-2.6 m at
  4, 26, 35, 37, 52, 63; under 1 m at 34, 42, 51, 66 (`fix04/mouthfix.out`, column M1a-skew).
- Curving table, paint mouth: `fix04/mouthfix.py` (column MC: gap middles on lines 0.5-8 m outside the
  main road's asphalt edge, a straight line fitted, carried to the main road's middle line; the main road
  is the box's road line) and `fix04/mouth2_asph.py` (`pave/mouth2.py` on asphalt: the same, but on a
  straight line through the meeting point at the main road's bearing). They agree at 27, 51 and 66, and
  differ at 34 (1.9 against 0.4 m; 88° against 78°) and 42 (0.3 against 1.6 m; 66° against 73°),
  probably because a straight frame drifts off a bending main road.
- `mouth2.py`'s "along" follows the main road's bearing, so its sign flips from site to site.
  `trial.py`, `mouthfix.py` and `board.py` use + = toward where the side road comes from.

**Fits.**

- Arrow board (`fc04/board.py`): the far-side two-way board within 16 m of the box, dropped onto the main
  road's middle line, against the meeting point. 35 T's: typically 0.43 m, 1 in 10 over 2.1 m, 23 within
  1 m; boards stand typically 5.2 m off the main road's middle. Straight side roads (25): typically
  0.40 m; 3 +3.6, 8 -2.0, 54 -1.5, 22 +1.4, 62 +1.4, 52 -1.3 m. Weak five: 27 +4.0, 34 +2.2, 42 +2.1,
  51 +0.8, 66 +6.0 m.
- Follow the curve (`inv/trial.py` A; `critic04/prop.py` applies the first plan). Curving below 100 m:
  2, 7, 23, 26, 27, 34, 35, 37, 42, 49, 50, 63, 66; 51 is 162 m. Moves from today's point: 34 +2.2
  (board +2.2), 42 +1.3 (+2.1), 27 +1.7 (+4.0), 66 +0.3 (+6.0), 23 -0.9 (+0.4), 49 +1.3 (+0.1). Angle
  (`A_turn`): 42 63.1° to 78°, 35 37.4° to 52°. The first plan asked at 26, 27, 35, 37, 63, 66.
- Paint mouth, skew fixed (`fix04/mouthfix.py` MC): weak five 27 +5.5, 34 +1.9, 42 +0.3, 51 +1.5,
  66 +2.4 m; skew T's 3 +4.3, 7 +0.9, 41 +0.6, 61 -0.8, 52 +2.7 m. Against the board on 34 T's: typically
  0.9 m, against 0.4 m for today's point. Wild at 29 and 32 (yards), 44 and 46.
- Paint mouth, first trial (`inv/trial.py` M1, straight across, drive cost 4): from today's point 27
  +5.0, 34 +2.1, 42 +2.7, 51 +3.1, 66 +4.8 m. The earlier draft's "1.1-3.1 m" was measured from the box.
- Read 8-16 m outside the edge instead (`mouthfix.py` MF), the reading goes wrong on curving roads: 42
  -4.9, 66 -8.1 m.
- 27 squaring up: `mouth2.py`'s middles 6-16 m from the main road's middle sit +4.4 to +4.9 m from
  today's point; board +4.0 m.
- Stub tips at 27 and 66 (`critic04/tips.py`, `read.py`): at 27 the side tips sit -2.1 and +2.2 m along
  the main road from the box, while the paving 8-16 m out is centred +3.1 m; their last pieces run 70-74°
  to the main road where the paint runs square for 16 m. At 66 the one tip is on
  `gravelPebblesMossPatchy01`.

**Stubs** (`fix04/mouthfix.py`, asphalt; `inv/trial.json` agrees): 93 side tips at T's within 25 m of the
box; typically 0.48 m short of the edge; 38 over 0.75 m short; 16 past (29 and 32, yards, the furthest).
One T's tips more than 1.5 m apart against the edge: 5 (2.5 / 0.0 m short), 6 (3.5 / 1.3), 8
(2.3 / -0.1), 13 (3.4 / 1.4), 37 (-1.9 / 0.2), 59 (3.0 / 1.0), 63 (16.0 / 0.5 / 0.6). Not yet confirmed
as the two lanes of one road.

**Grade trials.**

- Road reading (`grade/paint_offsets.py`, main-off): within 1 m at 37 of 48; over 1.5 m at 6, 12, 33,
  40, 46, 50, 63, 65.
- Check 6 read two ways (`paint_offsets.py`: just past the edge, and 4 m further out): of 48 T's and Y's
  with the main road read, no answer at 14 (34 and 66 among them) and over 2 m apart at 19 (27 6.0, 42
  9.4, 51 6.8 m).
- Check 6 read outside the wider paving (`grade/side_v2.py`): today's point within 1 m at 27 (0.9), 34
  (1.0) and 42 (0.5); 51 2.9, 66 5.4 m. Weak five typically 1.0 m, the rest 1.6 m. 14 of 37 others over
  2 m: 1, 2, 7, 9, 12, 21, 33, 37, 41, 45, 50, 62, 63, 65.
- Spread over four readings (`grade/mouth.py`: three straight-across lines plus `side_v2`): over 2 m at
  24 of 46, square T's 1, 2, 4, 6, 12, 19, 21, 45 among them. Its 3-7 m at 3, 7, 41, 52 is really
  3.4-8.2 m, and has no skew fix.
- Ask rate under the first plan: yards (29, 32), road reading over 1.5 m (8) and the plan's asks (6)
  cover 15 of 51 T's and Y's. Counting check 6 "no answer or unsure" as an ask: 33 of 48.

**Other:** on a shallow Y, 1 m across at 20° is 1 / sin 20° ≈ 2.9 m along.

## Rules learned the hard way

- A fit can't pass only on checks built from the same lines or heading it used.
- Near the mouth, drop paint readings wider than the road further out (at 62 the wider paving read 6 m
  off, outside it 2.6 m).
- Draw every graded junction: at 37 every count said perfect while one lane was cut 13 m deeper than its
  twin.
- Run with through roads kept and off, twice.

## Research files

Session scratchpad, temporary:

- `inv/`: `cprobe_one.lua` → `all.txt` (the harness probe per junction), `parse.py`, `centres.py`,
  `trial.py` (every method per junction → `trial.json`), `sitepic.py`, `pics/`.
- `grade/`: `paint_offsets.py`, `side_v2.py`, `mouth.py`, pictures.
- `pave/`: `mouth2.py`, `jsite.py` (largest circle), `typecache.py`.
- `sit/`: `curve.lua`, `L27`/`L34`/`L42`/`L51`/`L66.png`.
- `cl/`: `meets_final.txt`, `tooltypes_final.txt`.
- `fc04/`: `board.py` (the arrow board check), `deck.py` (raised points).
- `critic04/`: `prop.py` (the first plan applied), `tips.py` and `read.py` (stub tips and paint at one
  site), `cover.py` (asphalt per map).
- `fix04/`: `mouthfix.py` (asphalt-only rerun: paint mouth with and without the skew fix, stubs against
  the edge; `.out` and `.json`), `mouth2_asph.py`, `deck_box.py` (decks from the box, to 50 m), and the
  outputs of the scripts above.

## Traps

- The angle work ran on scratchpad `live.lua` (15:56). The harness default `graph_data.lua` (12:46)
  agrees at 27, 34, 42 and 51, but 66's side track is unwired there, so no junction.
- The red X in `pave/*.png` is the fork average, not today's centre (9 m apart at 34).
- Notes dated 2026-09-19/20 use old j-numbers: j01-j03 = 1-3, j04-j22 = 5-23, j23 = 26, j24 = 27,
  j25 = 28, j26 = 29, j27 = 30, j28-j60 = 32-64. So j13 = 14, j19 = 20 (j19 north and south are 20n and
  20s), J30 = 34, j33 = 37, J38 = 42, J47 = 51, j60 = 64.

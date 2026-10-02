# Placeable junctions: reference

*Draft 1, 2026-10-01. Sources and numbers behind [Placeable X and T junctions](05-placeable-junctions.md).*

## Sources

- **The mod:** `FS25_AutoDrive_XT_Intersection.zip` 3.0.1.0, by Willi Willswissen, from the user's mods
  folder. Repo: github.com/Williwillswisse/AD_XandT-intersections. The older separate mods
  (`AD_T_intersection`, `AD_xCrossing`, both 1.0.0.1) were not studied.
- **AutoDrive:** `FS25_AutoDrive.zip` **3.0.1.2**, from the same folder. Paths below are inside its
  `scripts/`.
- **Our save:** `savegame6/AutoDrive_config.xml` (12,873 nodes) and `placeables.xml` lines 2475-2476.
- **Scripts:** `tools/xt-study/` (see its README).

## The pieces

- Each `*crossing-Nm-line.xml` carries an `<AutoDrive><waypoints>` block (id, x, y, z, out, incoming,
  flags) and one `<mapmarker>` on node 1. All flags are 0.
- Node layout at size L, in the piece's own x/z (z south): centre (0,0); lanes at ±L/2; arm ends at
  ±1.5L; right-turn cuts from (−0.75L, 0.5L) to (−0.5L, 0.75L). T: 13 nodes. X: 21 nodes.
- T westbound through is one 18 m link (12→13 at 6 m), with no points between.
- `.i3d`: everything hangs under `groundStain` scaled by L. The clear area is one L×L square. The level
  area has zero size, so no paint and no levelling. Visuals are cylinders and green arrows.
- Destination names: 3 m and 4 m T say `T-intersection-Nm-line`. 5 m and 6 m T say `xcrossing-Nm-line`.
- `tcrossing-0m-line.i3d` and `xcrossing-0m-line.i3d` ship with no XML using them.

## Placeable import

- Runs on `onFinalizePlacement` only (`Utils/AutoDrivePlaceableData.lua:24-32, 151-184`), on the
  server. It does not run on savegame load.
- `readGraphFromXml` (`:186`) shifts the piece's ids by the current node count (`:351, 360, 372`). It
  applies only the Y rotation and snaps heights to the ground.
- No search for nearby nodes. Nothing joins the piece to the network.
- Destination name gets a running number: `(#markers + 1) .. "_" .. name` (`:307`).
- **A destination is required to import at all:** `createPlaceable` runs only when the piece has at
  least one marker and one waypoint (`:382-385`). Without a marker it returns 0 and imports nothing.
- The mod's README asks users to delete the destinations once the routes are done, "otherwise they will
  influence the route calculation". They are there to let a driver go straight to the junction while
  building.
- Destinations are never read while driving, waiting or routing, except for the detour setting
  (`PathCalculation.lua:189`, `GraphManager.lua:768, 840`; default 0). They are also read when finding
  a stop by distance:
  - fuel: nearest destination within 15 m of the trigger (`Manager/TriggerManager.lua:240-285`,
    `AutoDrive.MAX_REFUEL_TRIGGER_DISTANCE = 15`);
  - selling: a destination on the path near the station, adopted before a new one is made (`:472-487`);
  - repair: nearest within 15 m (`:741-747`).
- `onFinalizePlacement_TODO` (`:88`) is an unused confirm-dialog version, not an auto-join.
- Selling: `Placeable.onSell` only calls `ADTriggerManager.onPlaceableSell` (`AutoDrive.lua:251`,
  `Manager/TriggerManager.lua:343`), which reloads triggers. Nothing removes the paths.
- In our save (`placed.py`): T at (−741.6, 262.3), rotation 0, all 6 ends joined to nodes 5-6 m out
  (12457-12462). X at (−783.1, 267.6): all 8 ends loose.

## Who waits

`Modules/CollisionDetectionModule.lua:89-194`, `detectAdTrafficOnRoute`:

- Runs every 20 frames (`AutoDrive.PERF_FRAMES = 20`, `AutoDrive.lua:69`), on the same frame for every
  vehicle.
- Skipped when the vehicle's current link is two-way (`:95-100`).
- Gathers my next points: the first 5, plus more while the links stay two-way (`:104-121`). So
  approaching a two-way stretch, the check covers the whole stretch.
- This is intended. Commit e44458fb4 (Axel32019, 2025-12-30, "extend right-of-way to all route
  Y-connections") states the rules:
  - several vehicles over a common waypoint from different directions: priority is given;
  - ±4 waypoints around the common waypoint;
  - "On two-way routes, priority is granted proactively along the entire two-way route".
- No issue was found about two two-way roads meeting. Issue #252 (crossroad pile-up): the AutoDrive team
  suggested "adding a small zigzag line" to slow vehicles before a junction, which is the deliberate-bend
  lever.
- For each other active AutoDrive vehicle, scans its points from 4 behind to 4 ahead of its current one
  (`:132-167`).
- A matching id counts only if the point before it differs between the two routes, "Y right-of-way"
  (`:150-161`).
- I wait if they match, the points before differ, and the other is not already waiting (`:169`).
- No geometry test anywhere. Two paths crossing without a shared id are never compared.
- Bumper sensors (`detectObstacle`, `:42-87`, `Utils/CollisionDetectionUtils.lua`) are separate:
  physical boxes in front of the vehicle.

## Teal dots

- `point.isRightOfWayCenter` is set in `Specialization.lua:1641-1677`: `#out >= 1 and #incoming >= 2`,
  minus three pass-through patterns.
- It is read only to draw (`Specialization.lua:909, 936`). Colour `{0, 0.65, 0.7, 1}`
  (`AutoDrive.lua:130`).

## Routing

- 80° rule: `Manager/GraphManager.lua:994-1038`, `prepareWayPoints`. An in→out pair through a point is
  kept only if the bend is ≤ 80°, or it starts or ends a reverse section.
- `legal.py` results: every straight, right and left turn is allowed. U-turns are refused in both
  pieces. X left turns go only through the centre (`2,9,14` is 90°).
- Cost: drive time (`PathCalculation.lua:36`, `GraphManager.lua:784`), slower for bigger bends.
  Sub-priority flag ×20 (`GraphManager.lua:4`).
- Destination detour: the `mapMarkerDetour` setting (`Settings.lua:382`) defaults to 0 m, so no penalty.

## Steering

- Look-ahead target: `Modules/DrivePathModule.lua:693`. Minimum look-ahead per vehicle:
  `Utils/AutoDriveUtilFuncs.lua:92` (at least 2 m).
- Corner speed: `DrivePathModule.lua:570`, `getMaxSpeedForAngle`: under 5° no limit, then 60 km/h falling
  to 12 km/h at 30°, 12 km/h to 50°, 3 km/h past 50°. Times the `cornerSpeed` setting.

## Speed from point spacing

- `getHighestApproachingAngle` (`DrivePathModule.lua:450-501`) scans up to 20 points ahead
  (`MAXLOOKAHEADPOINTS`). At each point it takes the angle between the incoming and outgoing links, and
  keeps the largest within the look-ahead distance.
- Look-ahead distance (`:440-448`): 20 m × mass factor (1-3, (mass + 20) / 30) × speed factor (0.25-4,
  (km/h + 10) / 20), capped at 150 m.
- The cap is applied every 4 frames (`:279-293`). Off the network (pathfinder paths) it is doubled and
  at least 12.
- `getMaxSpeedForAngle` (`:570-585`), times `cornerSpeed`. The full-lock clamp (`:587-605`) gives
  10 km/h past 95% lock.
- Bend for a target speed V between 12 and 60 km/h: θ = 5° + 25° × (60 − V) / 48. Spacing = R × θ
  (radians).
- For a right-angle arc in n equal pieces, the sharpest bend is 90°/n. The tangent joins at each end
  bend only half that.
- Checked against `curves.lua`: R = 12 with 5 m spacing makes 4 pieces, 22.5°, so 26.4 km/h, the same as
  the twin.
- Even pieces on a right angle give only steps: 3, 12, 12, 26.4, 35.0, 40.8, 44.9, 48.0 km/h for 1-8
  pieces. That is why the builder sets the speed with one deliberate bend instead.
- Who-waits reach in points: my next 5 points (`CollisionDetectionModule.lua:104-121`), the other's
  ±4 (`:132`).

## Drive test

`drive.lua`, `SweptSim.EXAMPLE_RIG` (Transtar II + SKS 30/1050 semi, look-ahead 10.32 m) and
`STOCK_DRIVER`, 40 km/h limit, a 45 m straight lead in and out along each arm. Offsets are from the
driven path, judged within 1.5L + 12 m of the centre.

| Piece | Move | Truck axle out / in | Trailer wheel edge out / in | Slowest |
|---|---|---|---|---|
| X 6 m | right | 2.7 / 2.0 m | 2.9 / 4.6 m | 26.9 km/h |
| X 6 m | left via centre | 2.3 / 1.3 m | 2.6 / 3.6 m | 21.3 km/h |
| X 3 m | right | 2.8 / 2.0 m | 2.9 / 4.5 m | 27.0 km/h |
| X 3 m | left via centre | 2.5 / 1.6 m | 2.8 / 4.4 m | 24.6 km/h |
| T 6 m | side, left onto main | 2.0 / 1.5 m | 2.5 / 3.9 m | 26.9 km/h |
| T 6 m | main, left into side | 2.3 / 0.8 m | 2.6 / 3.6 m | 21.7 km/h |

"Out" is the outside of the turn and "in" the inside. Straight moves: 0. Full table: `drive_results.txt`
from `drive.lua`.

**The "Slowest" column is wrong for AutoDrive 3.0.1.2.** `SweptSim` scans a fixed 20 m for bends
(`speedScanMetres`, from 3.0.0.8). 3.0.1.2 scans a distance that grows with speed and mass, up to 20
points. With a 50 m or 100 m scan the mod's right turn takes 12 km/h (the cap for its 45° bends), not
27. The offsets barely change (1.4 / 2.2 m against 1.3 / 2.3 m).

## Curve test

`curves.lua`, same rig, driver and lead in/out.

- **Road model:** middle lines on x = 0 and z = 0, lanes at ±L/2, edges at ±L, square corners.
  Eastbound approach on z = +L/2. The right turn exits south on x = −L/2, the left north on x = +L/2.
- **Curve:** a radius-R arc tangent to both lanes, points every 2 m. This is the shape our builder lays
  (`FlyoverEditor.lua`, "lay the radius-R arc one-way from entry to exit"; default
  `junctionTurnRadius = 12`).
- **Columns:**
  - "line": the laid line itself, off road or across the middle line.
  - "truck off line": the axle centres' distance from the line.
  - "wheels": truck front corners, truck rear wheels, trailer wheels and trailer front corners against
    the roads. Into-oncoming tops out at L, because past it a wheel counts as off road.
- **Geometry:**
  - A right arc's middle sits at (−L/2 − 0.293R, L/2 + 0.293R), so it leaves a square corner when
    R > L / (2 × 0.293) ≈ 1.71L.
  - A left arc's centre is at (L/2 − R, L/2 − R). It passes through (0, 0) when R = L / (2 − √2) ≈ 1.71L,
    and by symmetry the opposite left arc does too.
- **Speed:** with 1-3 m spacing the slowest is unchanged. It drops at 4 m (35 km/h) and 5 m (26 km/h).
  The swing-wide figure stays 2.1 m throughout. The table below uses the twin's 20 m bend scan, so the
  "mod corner" slowest figures should read 12 km/h (see the drive-test note).
- **One deliberate bend** (`speedArcPath`): the arc's last two pieces each subtend θ(V). Every point
  stays on the arc. Slowest speed by bend-scan window:

  | Curve | Aim | 20 m scan | 50 m scan | 100 m scan |
  |---|---|---|---|---|
  | right R=8 | 20 | 26.9 | 20.0 | 20.0 |
  | right R=10 | 20 | 27.0 | 20.0 | 20.0 |
  | right R=12 | 20 | 29.4 | 20.0 | 20.0 |
  | left R=10 | 22 | 27.2 | 22.0 | 22.0 |
  | left R=12 | 23 | 30.1 | 23.0 | 23.0 |
  | left R=15 | 25 | 33.2 | 25.0 | 25.0 |
  | right R=12, even 2 m | none | 39.1 | 39.1 | 39.1 |
  | right, mod corner | none | 26.9 | 12.0 | 12.0 |

  Wheel offsets match the plain arcs within 0.1 m. Not modelled: AutoDrive's 6 km/h braking dead band
  (`MAX_SPEED_DEVIATION = 6`, `DrivePathModule.lua:5, 354-363`).

    right L=6m  mod corner  | line: off 0.0 wrong 0.0 | truck off line: out 2.7 in 2.0, trailer 3.3 | wheels: off road 1.3 into oncoming 2.3 | slowest 26.9
    right L=6m  arc R=8     | line: off 0.0 wrong 0.0 | truck off line: out 2.3 in 1.0, trailer 2.4 | wheels: off road 2.0 into oncoming 1.8 | slowest 37.4
    right L=6m  arc R=10    | line: off 0.0 wrong 0.0 | truck off line: out 2.2 in 0.8, trailer 2.0 | wheels: off road 2.3 into oncoming 1.6 | slowest 38.2
    right L=6m  arc R=12    | line: off 0.5 wrong 0.0 | truck off line: out 2.1 in 0.7, trailer 1.7 | wheels: off road 2.6 into oncoming 1.5 | slowest 39.1
    right L=6m  arc R=15    | line: off 1.4 wrong 0.0 | truck off line: out 1.9 in 0.5, trailer 1.4 | wheels: off road 3.1 into oncoming 1.2 | slowest 40.0
    right L=6m  arc R=20    | line: off 2.9 wrong 0.0 | truck off line: out 1.6 in 0.4, trailer 1.0 | wheels: off road 4.2 into oncoming 0.7 | slowest 40.0
    left  L=6m  mod corner  | line: off 0.0 wrong 0.0 | truck off line: out 2.3 in 1.3, trailer 2.3 | wheels: off road 1.7 into oncoming 0.0 | slowest 21.3
    left  L=6m  arc R=8     | line: off 0.0 wrong 0.0 | truck off line: out 2.3 in 1.0, trailer 2.4 | wheels: off road 1.8 into oncoming 0.0 | slowest 34.8
    left  L=6m  arc R=10    | line: off 0.0 wrong 0.0 | truck off line: out 2.2 in 0.8, trailer 2.0 | wheels: off road 1.6 into oncoming 0.0 | slowest 35.7
    left  L=6m  arc R=12    | line: off 0.0 wrong 0.0 | truck off line: out 2.1 in 0.7, trailer 1.7 | wheels: off road 1.5 into oncoming 0.4 | slowest 36.6
    left  L=6m  arc R=15    | line: off 0.0 wrong 0.0 | truck off line: out 1.9 in 0.5, trailer 1.4 | wheels: off road 1.2 into oncoming 1.1 | slowest 37.8
    left  L=6m  arc R=20    | line: off 0.0 wrong 0.2 | truck off line: out 1.6 in 0.4, trailer 1.0 | wheels: off road 0.7 into oncoming 2.9 | slowest 39.8

The 3 m and 4 m rows are in `curves_results.txt`. Same pattern, but every arc of 8 m or more already
leaves the road on a right turn (3 m: 0.9-4.4 m; 4 m: 0.4-3.9 m).

**Not modelled:** rounded corners, real paint, other rigs, the truck's own turning limit beyond the
twin's full lock.

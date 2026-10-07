# Swept-path clearance — design & implementation spec

**Status:** spec (interviewed 2026-09-18). Not yet built. Follows on from `junction-plan.md` §7.

Goal: make the junction tool lay only turns that the network's **design vehicle** can physically
drive — with the tractor's real driven line and the trailer's real offtracking staying inside the
corridor and clear of obstacles — and refuse, loudly, anything it cannot. Today the tool judges a
turn by the *geometry of the waypoint line*. AutoDrive does not drive that line; it drives *inside*
it. This spec closes that gap.

---

## 1. Principle: the design vehicle

Borrowed straight from road engineering. You pick the **largest rig the network must serve** — for
this network, a truck + trailer combination — and every geometry decision is tested against *it*,
not against whatever happens to be driving today.

- The design vehicle is a first-class setting: a named preset of the parameters in §4.
- The tool **never lays a turn the design vehicle cannot take.** Refusal is authoritative (§6).
  Smaller vehicles inherit a network that is safe by construction.
- The current "tight" heuristic in `junctionSolveMovement` (`minRadius < 0.7 × r`) was a guess. It
  is **replaced** by the kinematic feasibility gate in §6.

**Changed 2026-10-07: a vehicle set, not one design vehicle.** Judging every turn by the largest rig
(the Transtar + SKS semi) refused turns a farm tractor and trailer take easily, and kept the builder's
own swing-wide from ever helping. Now the build card lists a set of rigs and you tick which must fit
(`SweptSim.RIGS`, `junctionRigs`): a small rig (Fendt 700 Vario + Krampe Halfpipe HP 20) and a big
rig (Fendt 900 Vario + Krampe Big Body 750 S), read from the game's own vehicle files, both ticked
by default; the semi, not checked by default; a rig measured in game (FlyoverSweptRig) joins as
"measured". Each card row shows how many of the build's turns that rig fits. Every ticked rig must
pass the swept gate; the floor is the largest full lock among them. A line that runs off the road at
every radius is tried swung wide (the kickout) before it is refused; a plain line always wins. The
turn's line stays on the paving where it joins two paved lanes, while the trailer's inside wheels
may cut over the gravel shoulder (Ground.lua `isPavedAt`). The tractor numbers still need measuring
in game.

Decisions locked in the interview:

| | Decision |
|---|---|
| Forward driving only | Reverse roads (`ADGraphManager:isReverseRoad`) are out of scope; the predictor refuses rather than guesses on them. |
| Articulated / crab-steer vehicles | Out of scope for V1. **Follow-up eval needed** (§9): their fixed 3 m look-ahead and the `distFromCompJointToCenterOfBackWheels` term when the axis is locked are a different geometry, not a constant. |
| Driver rewrite | A **separate, later project**, done as an AutoDrive fork submitted upstream (or maintained privately). This spec predicts against the **stock driver only**, behind a profile (§3) so the fork's driver can be described later. |
| Speed control | Not fixed here (belongs to the driver rewrite). This spec only *accounts for* stock speed behaviour where it affects the path, and documents the point-spacing coupling (§7). |
| Hitch model | Both fifth-wheel and drawbar, via one signed parameter (§4). |
| Reshape rule | Yes: sweep the waypoint line *wide on purpose* (e.g. swing left to make a wider right turn) so the driven line lands where it should (§6). |

---

## 2. Baseline: how AutoDrive actually follows waypoints

Read from stock AutoDrive 3.0.0.8 source (`scripts/Modules/DrivePathModule.lua`,
`scripts/Utils/AutoDriveUtilFuncs.lua`). This is the "framework for understanding" the model is
built on; every number here is a fact of that code, not an assumption. Re-read against 3.0.1.2,
the installed version, on 2026-10-01: `DrivePathModule.lua` differs from 3.0.0.8 only in
debug-print guards.

**Pure pursuit** (`ADDrivePathModule:getLookAheadTarget`, ~L693). AutoDrive does not drive *on* the
waypoints. From the vehicle's **steering node** it walks the polyline forward until it has covered
`min_lookAhead` metres, and steers toward that point. The waypoints are a *reference curve*; the
vehicle's own path is what pure pursuit makes of it.

`min_lookAhead` (`AutoDrive.getMinLookaheadByVehicleType`, ~L92) depends on the rig:
- default: `vehicle.size.length / 2`
- articulated axis / crab steer: 3 m fixed (+ `distFromCompJointToCenterOfBackWheels` when the
  articulated axis is locked)
- front-steered with an AI steering node: `2 × (largest wheel offset behind the steering node)`, else
  `vehicle.size.length`, else 4 m

**Consequence — cut-in.** On a circular arc, pure pursuit tracks the circle with *zero* steady-state
error (curvature `2·sin(α)/L` with `α = asin(L/2R)` gives exactly `1/R`). The deviation happens at
the **transitions**: entering a bend the look-ahead point is already on the curve while the vehicle is
still on the straight, so it starts turning early and cuts the entry; leaving, it straightens early
and cuts the exit. On a polyline of straight segments it cuts every vertex. **The waypoint line is the
outer envelope of where the tractor goes, never its track.** The trailer then offtracks *inside that*
— two stacked cut-ins.

**Steering law.** `AutoDrive.driveInDirection` (`Utils/UtilFuncs.lua` L1326) passes the local target
`(lx, lz)` to the game's `AIVehicleUtil.driveInDirection` with a steering-angle cap of 60° or the
vehicle's `maxRotation` (`DrivePathModule` ~L331). Read from `dataS/scripts/vehicles/AIVehicleUtil.lua`
(L144): it is **not** pure-pursuit curvature. The bearing to the target, `angle = acos(lz)`, sets a
steering demand **proportional to the bearing angle**, `targetRotTime = maxRotTime × min(angle /
steeringAngleLimit, 1)` (left) or `minRotTime × …` (right), and `rotatedTime` slews toward it at
`getAISteeringSpeed()` per ms. So the wheel angle is a P-controller on bearing with a rate limit,
saturating at full lock once the target is `steeringAngleLimit` degrees off the nose. A corner the
vehicle cannot make at its look-ahead is not refused by the driver — it is **understeered into the
inside**. The recorder logs `rotatedTime` (±0.9 = full lock on the MT635) precisely because it is
the term this law is calibrated on.

**Speed** (`getMaxSpeedForAngle`, ~L570). Speed is set by the **sharpest angle between consecutive
segments visible ahead**. The scan (`getHighestApproachingAngle`) takes up to `MAXLOOKAHEADPOINTS =
20` points, none further (straight line, from the current waypoint) than `getCurrentLookAheadDistance`:
`LOOKAHEADDISTANCE` (20 m) × mass factor `clamp((t + 20) / 30, 1, 3)` × speed factor
`clamp((km/h + 10) / 20, 0.25, 4)`, capped 150 m, where `t` is `getTotalMass(false)` - tow,
trailer and load - and below 10 km/h the mass factor drops to the speed factor. For the loaded
semi (57.5 t) that is ~100 m at 30 km/h and 20 m at 10 km/h; empty (12 t), 43 m at 30 km/h. The
caps are recomputed every 4th frame. The limit by angle:

| max angle ahead | speed limit |
|---|---|
| < 5° | unlimited |
| 5° → 30° | linear 60 → 12 km/h |
| 30° → 50° | 12 km/h |
| ≥ 50° | 3 km/h |

times the `cornerSpeed` setting. Speed depends on **point spacing**, not radius: the same arc sampled
at 1 m vs 4 m shows different per-segment angles (§7).

**Trailers are not modelled** anywhere in path following. Offtracking is purely emergent physics.

---

## 3. Driver profile (the pluggable part)

The predictor never hardcodes driver behaviour. It reads a profile:

```
DriverProfile = {
  name             = "stock-3.0.1.2",
  lookAhead        = function(rig) -> metres   -- transcribed getMinLookaheadByVehicleType
  steeringLaw      = function(lx, lz, cap) -> steer angle  -- transcribed AIVehicleUtil law
  steerCapDeg      = 60 (or rig.maxRotation),
  speedRule        = function(maxAngleAhead) -> km/h        -- transcribed getMaxSpeedForAngle
  speedScanPoints  = 20,
  scanDistance     = function(totalMassT, km/h) -> metres   -- transcribed getCurrentLookAheadDistance
}
```

V1 ships exactly one profile, transcribed from stock. When the driver rewrite lands as a fork, it
gets a second profile; the model and the gate are unchanged.

---

## 4. Design vehicle model

Parameters (per preset; the user named these as what models the system):

| parameter | meaning |
|---|---|
| `towWheelbase` | tow vehicle wheelbase (front axle ↔ rear axle) |
| `towSteerCapDeg` | max front-wheel steering angle (from `maxRotation`) |
| `towLength`, `towWidth` | body envelope for clearance |
| `hitchOffset` | **signed** distance from the tow's rear axle to the hitch point along the body axis. `≈ 0` for a fifth-wheel/semi (kingpin over the axle); **negative** (behind the axle) for a drawbar trailer. |
| `trailerLength` | hitch point ↔ trailer axle (or bogie centre) |
| `trailerWidth` | body envelope |
| `totalMass` | tow + trailer + load, tonnes. Not geometry: it sets how far ahead the driver looks for bends (§2), so how early it slows. Captured as it stands; the preset is the semi loaded (57.5 t) - slowest, so most cut-in. |
| *(multi-trailer)* | **Not in V1.** A dolly + second trailer would be a repeated (`hitchOffset`, `trailerLength`) pair; the tractrix chains naturally, so nothing in the model forbids it — but no preset, no capture, no UI until there is a reason. Parked (jokingly, ~V5). |

Why the signed hitch offset matters: a fifth-wheel trailer is a single-pivot tractrix — it tracks
purely inside the tractor. A drawbar hitch behind the rear axle **swings outward first**, then the
trailer cuts in — a lead-then-lag S-motion. Same equations, one extra term; both must be right or the
clearance check is wrong for half the fleet.

**Presets.** Ship 2–3 named presets. Plus a **capture** helper: with a vehicle (and trailer) entered,
the editor reads `size.length/width`, wheel positions (wheelbase), the attacher/hitch node offsets and
the trailer's axle position, and fills a preset. Hard-to-predict numbers should be *measured*, not
typed.

---

## 5. Prediction model: a digital twin of the follower

Closed forms exist (`L² / 2R` offtracking, cut-in vs look-ahead) but they only describe the
steady state, and everything that matters here happens at the transitions. So the model is a
**forward simulation** of the stock follower over the candidate connector:

1. **Input:** the connector polyline exactly as it would be laid (tie-in → sampled points → tie-in),
   plus a run-in of the real approach chain before it and a run-out after it (the transitions are
   the point, so the sim must start on the straight).
2. **Tow vehicle:** kinematic bicycle model, rear axle as reference, integrated at a fixed step
   (≈ 0.1 m of travel). Each step: compute the pure-pursuit target from the steering node using the
   profile's look-ahead; apply the profile's steering law with its cap; advance. Speed from the
   profile's speed rule (it affects the game's steering-rate limits only marginally — V1 may treat
   steering as instantaneous-within-cap and note it as a calibration item).
3. **Trailer(s):** hitch point = rear axle + `hitchOffset` along the body axis. Trailer axle follows
   the tractrix: heading rate `= v·sin(θ_hitch − θ_trailer) / trailerLength` (with the drawbar lead
   term appearing naturally through the hitch offset). Chain for a dolly.
4. **Output:** per-step world positions of the tow's rear axle, front axle, hitch, each trailer axle;
   the tow and trailer **body envelopes** (width offsets); and the **swept region** = union of
   envelopes. Plus the derived scalars the gate needs: max steering demand, inner-most and outer-most
   lateral excursion from the reference line.

Closed forms stay in as **sanity checks** (unit tests): on a pure circular arc of radius `R` the
simulated trailer offtracking must converge to `trailerLength² / (2R)` within tolerance; on a
straight both tracks must sit on the line.

---

## 6. Using the prediction: visualise → reshape → refuse

Integrated into the existing per-turn solve (`junctionSolveMovement`), replacing the `0.7 × r` guess.

**Gate (refusal criteria)** — evaluated per candidate radius, in this order, each with its own
verbose reason (red in the preview, counted on the card, logged by waypoint id like today):

1. **steering** — required curvature anywhere on the connector exceeds the design vehicle's
   maximum (`tan(steerCap) / towWheelbase`). The driver would understeer into the inside; refuse.
2. **tractor clearance** — the simulated tow envelope leaves the corridor or overlaps a static
   obstacle (§6 of `junction-plan.md`; the existing `overlapBox` probe, now run on the *swept*
   region rather than the waypoint line).
3. **trailer clearance** — same test on the trailer envelope.
4. **reverse road** — any reverse segment in the approach chains: unsupported, refuse.

**Reshape (compensation)** — before refusing, one attempt to fix: offset the connector's sampled
points *outward* (away from the inside of the turn) by the predicted inner deviation at each point
— the waypoint line is deliberately laid **wider than the road's true driving line** so that pure
pursuit's cut-in lands the vehicle where the line used to be. Re-simulate; two or three passes
converge. Bounded by the *outer* corridor edge: the line may not be swept off the outside of the
road either. If the bounded reshape still fails a gate, refuse.

**Kickout shape (decided 2026-09-18, from the first driven reshape).** The outward push must **start
early and end late** — on the entry lane before the tie-in and back onto the exit lane well after it —
and it is **asymmetric**: the return is longer than the setup, because the trailer is still cutting
inside a full rig-length after the tow has left the curve. A push blended *inside* the connector (the
first implementation) is the wrong shape twice over: on a ~16 m connector a 2 m push produced 30°
kinks at both ends, and it recovers little. Offline, Transtar rig, 90° turn, 2 m push:

| kickout | R 8: trailer inside original line | R 12 | max kink |
|---|---|---|---|
| none | 3.36 m | 2.60 m | 8° / 5° |
| blended inside the curve | 2.71 m | 1.44 m | 36° / 12° |
| early 10 m / late 10 m | 1.36 m | 0.44 m | 9° |
| **early 12 m / late 20 m** | **1.21 m** | **0.39 m** | **8° / 7°** |
| 3 m, early 12 / late 20 | 0.10 m | 0.10 m | 10° |

The early/late form recovers ~3× as much per metre of push, with no kinks. Its cost is the tow's
front swinging further to the *outside* (3.5–3.8 m vs 2.1 m) — the oncoming-lane side — which is
exactly what the tow-body road and obstacle probes are there to bound. Defaults derive from the rig:
`early ≈ lookAhead + 2`, `late ≈ lookAhead + trailerLength`. Consequence: the reshape **moves the
tie-ins** outward along the lanes (this answers the open question in §11), so placement must be able
to splice a tie-in on the lane *outside* the scope circle, and a later rebuild must clear a kickout's
points beyond its usual 1.3 R debris sweep.

**Visualise** — in the locked preview, draw the predicted tow line and trailer line (thin, distinct
colours) under the white connector, and tint the swept region where it leaves the corridor. This is
the first deliverable (§8): it makes the model's claims *visible* before any gate trusts them.

The solve order stays: per candidate radius, geometry → surface → obstacle → **kinematic gate** →
accept, else step the radius down as today.

---

## 7. Point spacing and speed (documented, not fixed here)

Because stock speed is set by per-segment angle, the sagitta-based spacing (`JUNCTION_SAG = 0.05`)
changes what speed AutoDrive will take a turn at. Denser points → smaller per-segment angles → faster
cornering, *independent of the actual radius*. Two consequences the implementer must keep in mind:

- The simulation in §5 must sample the candidate connector **exactly as it will be laid**, so the
  speed rule sees the same angles the driver will.
- Fixing the coupling (radius-based speed) is the driver rewrite's job, not this spec's. Until then,
  a card note showing the predicted stock cornering speed for each turn is cheap and honest.

---

## 8. Validation & calibration

The model is only as good as the design-vehicle numbers and the transcribed driver law, so
validation is not optional — it is how the gate earns the right to refuse.

**Swept-path recorder** (first deliverable). A debug toggle in the editor: while an AutoDrive vehicle
drives, record per frame the world position of the steering node, rear axle, hitch, and every trailer
axle, plus the current waypoint index and speed. Dump to a log/CSV. The editor can then draw a
recorded run over the network, and overlay the *predicted* lines for the same connector.

**Test rig.** One canonical "if this fits, everything fits" combination on Riverbend — the truck +
trailer the design-vehicle preset is captured from.

**Classified example routes.** Hand-built reference routes, one per turn class, each driven with the
rig and the recorder on. The classes (extend as the field reports come in):

1. shallow merge (≤ 30°)
2. 90° inside corner, obstacle-free
3. 90° inside corner with a pole / fence at the apex
4. hook (> 120°)
5. T-junction with a trimmed stem
6. straight-through across a trimmed gap
7. two-lane road, left turn crossing the oncoming lane

**First recorded case (2026-09-18, run `trucktrail`, Transtar II + trailer).** Measured by the
recorder: tow wheelbase 5.82 m, steering node 0.65 m ahead of the rear axle, hitch **0.94 m behind**
the rear axle (drawbar), trailer hitch→axle 8.39 m, AD look-ahead 10.32 m. Two right turns through
freshly-laid junction connectors (59° at rear-axle R 4.3 m; 76° at R 5.6 m) each ended in a stall
just past the exit tie-in with the wheels still hard right: the **trailer clipped an obstacle on the
inside** of the turn. Overlaid on the saved network (matched by position — ids had been renumbered
by a rebuild in between): turn 1, tow rear axle 1.24 m inside the laid line and trailer axle
**2.85 m** inside; turn 3, tow rear axle 0.4 m *outside* the line (on it, in effect) and trailer axle
**3.71 m** inside. Add half a trailer width and the inside trailer edge ran 4–5 m inside a line whose
corridor check probes 2 m either side. Both are transients (steady state for 8.39 m at R≈6 would be
~5 m), which is why the model is a simulation and not a closed form. This is the reference case for
gate 3 (trailer clearance): the predictor must flag both turns; the connector geometry alone
passed them. Lesson for the recorder, already applied: store the current waypoint's position, not
only its id.

**First calibration (2026-09-18, run `clean90`, Transtar II + trailer, six clean corners on freshly
laid junction connectors, R 6–14 m, no stalls).** `SweptSim.lua` with the stock profile and the
recorder's numbers, before any tuning:

| corner | rear axle inside cut, rec / sim | trailer axle inside cut, rec / sim |
|---|---|---|
| c1 73° R, R≈6 | 1.39 / 1.66 | **3.43 / 3.67** |
| c2 77° L, R≈7 | 1.26 / 1.35 | 2.45 / 2.80 |
| c3 74° L, R≈9 | 1.51 / 1.52 | 2.02 / 2.50 |
| c4 105° L, R≈14 | 0.83 / 0.99 | 1.30 / 1.80 |
| c5 88° L, R≈10 | 1.12 / 1.26 | 1.82 / 2.52 |
| c6 74° L, R≈10 | 1.49 / 1.52 | 2.00 / 2.50 |

Tow rear axle within 0.35 m on every corner; the drawbar swing-out (outside excursion) matches to
0.1–0.3 m. The trailer cut-in is **over-predicted by 0.25–0.7 m, always on the safe side** — a fit
over full-lock radius and effective trailer length moved it only ~0.06 m (the trailer is a tandem;
the centroid, now also recorded, is the better pivot) and the residual is likely tyre slip the
kinematic tractrix has no term for. Accepted for V1 as a built-in margin. Cornering speed matched
where AD was actually cornering (c1 9.0 vs 8.9 km/h, c5 31.4 vs 31.4); the other lows in the record
were route start/end slowdowns, not the corner rule. One diagnostic-only mismatch remains: the sim
reaches the same curvature at ~0.68× the recorded `rotatedTime`, i.e. the rotatedTime→wheel-angle
mapping is not the linear full-lock scale assumed; it does not affect the driven line and is left as
an open item.

**Correction (same day, from the in-game rig capture).** `FlyoverSweptRig` measured the rig the
recordings came from - Transtar II + SKS 30/1050 - and overturned two hand-copied numbers:

- the hitch is a **fifth wheel 0.93 m AHEAD of the rear axle**, not a drawbar 0.94 m behind it (the
  recorder stores an unsigned distance; the sign was my assumption). The whole 0.25–0.7 m
  "conservative over-prediction" attributed above to tyre slip was that sign;
- the trailer's kinematic pivot is the centroid of its axle group, **7.08 m** from the hitch, not its
  rearmost axle at 8.39 m.

**Second correction, same day: full lock.** Two independent geometric derivations were tried and both
were wrong the same way. First `wheel.physics.rotMax` (45°, R = 5.84 m); when a later fix changed
nothing, it turned out `vehicle.maxRotation` - the field `DrivePathModule` itself reads as the
steering-angle limit - is the *same* 45° on this truck, so the second attempt reached the identical
wrong number by a different door. What settled it was a **clean recording** (`looptest.xml`: the
Transtar held hard over for 15 s with nothing to hit - the earlier "4.3–5.0 m" figure had come from
`clip1`/`trucktrail`, both stalled against an obstacle, not a real measurement). A least-squares
circle fit over the sustained-lock samples (`rotatedTime` ≥ 1.15, 66 points, mean residual 4 cm)
converges to **R = 6.26 m** for the rear axle as the window tightens toward peak lock. That matches
`vehicle.maxTurningRadius` (6.1 m) within 0.15 m - the field earlier dismissed as "a nominal AI
figure" was right, and both wheel-angle formulas undershot it by ~0.4 m for a reason not yet
understood (Ackermann geometry between inner/outer wheel angles is the leading guess). `captureRig`
now trusts `maxTurningRadius` as primary, falling back to the wheel-angle estimate only when a
vehicle has none set. `maxRotTime` was corrected the same way: the clean recording shows
`rotatedTime` reaching 1.18, not the assumed 1.05 - read as whatever unit the game itself uses,
never normalized.

Re-run on the same six corners with the corrected geometry: trailer inside-cut error **0.03–0.51 m**
(mean 0.23 m, still biased toward under-predicting - the unsafe side, now smaller in absolute terms
but worth the gate keeping its margin). Tow rear axle mean error **0.53 m**, worse than the 0.18–0.30 m
measured against the wrong (tighter) full-lock radius - and the per-corner detail exposes why: the
**inside** track matches well (within ~0.2 m on every corner) but the tow's **outside swing is
over-predicted by ~0.9–1.0 m on every single corner**, both turn directions. That is a new,
previously-invisible finding (the old aggregate error metric averaged it away) and is now the open
item: something in the steering law's approach to a corner - most likely the look-ahead target
sweeping across the apex before the vehicle has turned in, producing more outward swing in the model
than the real rate-limited steering produces - is not yet right. Flagged, not yet fixed. It is NOT
harmless to the gate: the body-edge probe (§6) samples both sides of the tow, so an over-wide outside
swing can refuse a turn over a phantom outside obstacle/off-road risk that a real driver would clear.
Conservative-direction, so it fails safe rather than unsafe - but a turn refused for the wrong reason
still needs the sweep-wide reshape's search budget, or is refused when it should not be.

"Both hitch types via one signed offset" (§4) has now been exercised for real - by getting the sign
wrong and measuring the cost.

**Speed re-check (2026-10-01, AutoDrive 3.0.1.2).** The bend scan had been transcribed as a fixed
20 m; AutoDrive scales it with mass and speed (§2), in 3.0.0.8 as much as in 3.0.1.2. `SweptSim` now
does too (`STOCK_DRIVER.scanDistance`, rig `totalMass`): a corner of 45° bends, capped at 12 km/h and
driven at ~27 km/h with 20 m, is driven at 12. Where the wheels go hardly moves - 0.2 m at most in
`tools/xt-study/curves.lua`, 0.08 m on any turn the preview lays across the 75 registry junctions
(`tools/junction-harness/sweptreg.sh`). One turn of 281 changed: j74's 5894 → 9857 is laid at 10 m,
not 11, because the road gate probes the body edges per time step, so a slower corner gets more of
the probes (104 against 58) and the off-road share crossed 15%.
`tools/swept-replay/replay.lua` (new) rebuilds the followed line from a recording and drives the twin
over it. Mean speed error, recorded vs twin: `clean90` 10.1 → 5.9 km/h, `looptest` 11.3 → 6.9,
`clip1` 5.0 → 2.0. What the replay shows:

- **The cornering-speed match above does not reproduce.** c1 is recorded at 10.3 km/h, the twin
  takes it at 16; c2 at 15 vs 31 - old twin and new alike. The lock clamp is the cause:
  `getSpeedLimitBySteeringAngle` tests `deg(|rotatedTime|) > 0.95 × deg(maxRotation)`, reading
  rotatedTime as radians, so on the Transtar (maxRotation 45°, lock 1.18) it fires at rotatedTime
  0.746 - 63% of lock - not at 95%. The recording holds 10 km/h exactly while rot > 0.746. With that
  rule (now in the twin - see the follow-up below) c1 is 10.0, c2 21.4, and the clean90 error 5.0 km/h.
- **The other low speeds are arrivals.** Once the destination is nearer than the scan reaches,
  AutoDrive holds the limit near `max(8, 2 + metres left)` km/h. Modelled as `opts.routeEnds`, for
  replays only - a preview's run-out is not a destination. With it the second clean90 piece matches
  within 1.2 km/h.
- **No braking dead band, and the cap holds.** AutoDrive brakes actively only beyond 6 km/h over
  (`MAX_SPEED_DEVIATION`) and puts the plain speed setting back on three frames in four, but the
  game's own limiter (`WheelsUtil.updateWheelsPhysics`) brakes on any overspeed: c1 braked 21.7 →
  10.3 km/h at ~5 m/s² and held 10.3-10.7. Neither is modelled. Braking ~5 m/s² and acceleration
  1.3-2.0 m/s² against the twin's 2.5 and 1.2 change the clean90 error by 0.1 km/h; left as they are.
- **Steering speed.** `DrivePathModule:reset` sets `aiSteeringSpeed` to 0.004/ms (4/s); the twin has
  1/s. Replaying at 4/s changes nothing measurable - the rate is not what limits these corners.
- **The outside swing is still over-predicted**, by 0.5-0.8 m at the rear axle on every clean90 corner.
  The preset rig has no `steerLimitDeg`, so it steers with the generic 60° where the captured Transtar
  has 45° (`maxRotation`). With 45° the swing turns into a ~0.4 m under-prediction and the gentle
  corners cut ~0.4 m too far inside. The preset now has the 45° (follow-up below); the remaining
  ~0.4 m either way is still open.

**Follow-up (2026-10-02): three fixes from the re-check.**

1. **Lock clamp as AutoDrive tests it** (`SweptSim.simulate`): `deg(|rotatedTime|) > 0.95 ×` the
   rig's steering limit. It only bites with a real limit - with the generic 60° it fires at
   rotatedTime 0.995 and clean90 is unchanged - so:
2. **The preset has the Transtar's 45°** (`EXAMPLE_RIG.steerLimitDeg`), as a capture records it.
   Mean speed error with both: clean90 5.9 → 5.0 km/h, looptest 6.9 → 3.5, clip1 2.0 → 1.9.
3. **The swept road gate probes by distance, and every body edge.** `junctionSweptPredict` kept every
   18th point of sets of six, so the gate had only ever probed the tow's **rear-left** corner -
   never the trailer, never the right side (the "samples both sides of the tow" above was the
   intent, not the code). Now all six edges, once per `FLYOVER_JUNCTION_SWEPT_PROBE_STEP` (1 m) of
   travel, so the corner speed cannot shift the off-road share either.

Across the 75 registry junctions (`sweptreg.sh`, real ground) 13 of 281 turns change: six take a
1 m sweep, one no longer needs one, three are laid 1-2 m tighter, j24's 9175 → 1522 is laid (was
refused, trailer off the road) and j59's 5279 → 5241 is refused (was laid). Laid 179, refused 102,
as before. j59 shows what the full probe set exposes: its "turn" is a 2-3 point link, and the
window also covers ~30 m of the existing lane either side, along which the truck's right-hand
edges sit off the asphalt 40% of the time and its left never. The gate is judging the LANE there,
not the turn - a lane laid along a road edge gets a turn refused.

**Second follow-up (2026-10-02): the gate judges only the ground the turn adds.** A body edge no
further from the route line than its body's half-width plus `FLYOVER_JUNCTION_SWEPT_LINE_MARGIN`
(0.3 m) is where the rig would be driving the line exactly: on the lanes that is the existing road,
on the connector it is the strip the corridor check already covers. Those edges are now neither
probed nor counted, and the off-road share is taken over the rest - the ground the rig reaches only
because of how it takes the turn. j59's link passes again (192 of 192 probes on the line).

Counting the on-line edges as "on the road" instead (tried first) is wrong: it dilutes real
excursions away. j74's 9857 → 3156, trailer 6 m inside, had 73 of its 167 own probes off the road
(44%) and passed at 73 of 564. With the share over the turn's own ground, it stays refused.

What the gate now sees for the first time is the tow's front swinging out and the trailer cutting
in. Across the 75 junctions, 45 of 348 listed turns change (`sweptreg.sh` now also lists turns
refused with no connector): 30 are laid with a sweep, mostly a 1 m kickout - j3's four turns, for
one, whose trailers cut 2.5 m inside onto the verge (20 of 74 own probes off the road) - 5 laid
turns are refused (j21, j24, j45, j65, j74), j59's link is laid, and 9 change radius. reg75 unchanged.

**Calibration loop.** For each class: simulate → record → compare (max lateral error of the tow and
trailer lines, and the cut-in depth at entry/exit). Tune the profile's effective look-ahead and
steering-gain terms until error is under a stated tolerance (proposal: 0.3 m) across all classes.
Only then does the gate move from "visualise" to "refuse".

---

## 9. Out of scope / later

- **Driver rewrite** (radius-based dynamic look-ahead, real-physics speed): separate project, as an
  AutoDrive fork submitted upstream. Gets its own `DriverProfile` when it lands.
- **Articulated / crab-steer vehicles**: needs its own eval — different look-ahead rule, different
  pivot geometry. Note kept so it is not forgotten.
- **Reverse driving**: refused, not modelled.
- **Connector-vs-connector deconfliction** at dense sites (already deferred in `junction-plan.md`).
- **Common-node convergence** (ditto).

---

## 10. Implementation phases

1. **Recorder + overlay.** Debug toggle, per-frame capture, draw recorded runs. No model yet.
   Ships value immediately: every drive test becomes data.
2. **Design-vehicle presets + capture helper.** Settings surface, `capture from vehicle`.
3. **Simulator (§5) + visualise (§6).** Predicted lines in the locked preview. Unit tests against
   the closed forms.
4. **Calibration** against the seven classes (§8). Tolerance met → proceed.
5. **Gate + reshape (§6).** Replace `0.7 × r`; sweep-wide compensation; new refusal buckets.
6. **Card + manual + German** for the new settings and buckets (`tools/make_help.py`, `Locale.lua`).

---

## 11. Open questions

- Steering-rate dynamics: the game limits how fast the wheels turn; V1 treats steering as
  instantaneous within the cap. If calibration shows entry cut-in consistently under-predicted,
  that is the first term to add.
- Should the reshape offset be applied to the connector only, or may it also move the **tie-in
  points** along the approach chains (the natural way to widen an entry)?

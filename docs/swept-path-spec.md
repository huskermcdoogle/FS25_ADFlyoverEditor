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
built on; every number here is a fact of that code, not an assumption.

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
segments visible ahead** (scan up to `MAXLOOKAHEADPOINTS = 20` points / `LOOKAHEADDISTANCE = 20 m`,
scaled by mass and speed, capped 150 m):

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
  name             = "stock-3.0.0.8",
  lookAhead        = function(rig) -> metres   -- transcribed getMinLookaheadByVehicleType
  steeringLaw      = function(lx, lz, cap) -> steer angle  -- transcribed AIVehicleUtil law
  steerCapDeg      = 60 (or rig.maxRotation),
  speedRule        = function(maxAngleAhead) -> km/h        -- transcribed getMaxSpeedForAngle
  speedScanPoints  = 20, speedScanMetres = 20,
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

# Known bugs — flyover editor

> **The editor is no longer developed in this repo.** Development moved to `FS25_ADFlyoverEditor`
> (sibling folder, its own local repo) once the companion mod was working. Fix bugs **there**, in
> `scripts/editor/`. Nothing needs copying back — this fork is kept as history, not as a source.

Bugs in the editor itself. Listed here because this is where they were found; the code they live in
is now in the companion mod.

Not a backlog of ideas — only things observed to be wrong.

---

## 1. Divide changes direction and connects the ends — FIXED

**Fixed** in `FS25_ADFlyoverEditor` build 0.7.0.0 (commit `ba6a768`), verified in game 2026-09-08.

Two independent faults, as suspected:

- **The fork.** `toggleConnectionBetween` is a true toggle — it *removes* an existing connection
  rather than ensuring one. A span with no interior waypoints has nothing to delete, so its ends
  stayed directly connected and the rebuild added a *second* path between them. The ends are now
  severed before the rebuild, so the new chain replaces the connection instead of joining it.
- **The direction.** The rebuild always laid connections in `chainIds` order, which is
  `runPathBetween`'s traversal order, not the direction the connection was drawn in. `spanStyle`
  captured dual-ness and flags but never direction. Both arrays are now reversed up front when the
  span runs backwards.

The degenerate 2-waypoint span turned out to exercise both at once, which is why it was the case
that got reported.

<details><summary>Original report</summary>

**Reported:** 2026-09-08, against build 0.6.3.0 of the companion mod (same editor source as the
fork). **Status:** open, deferred deliberately.

Using the DIVIDE tool on a span appears to do two things it should not:

- **changes the direction** of the affected connection(s)
- **connects the ends** of the span

Expected behaviour is that divide only inserts intermediate points along the existing span, leaving
the direction and the endpoint connectivity exactly as they were.

Context from the session log, which may or may not be the failing case — it is the closest capture:

```
15:57:38  dividing from id=11807; click the far end of the span.
15:57:40  span of 2 waypoint(s), 0 between the ends. Wheel to change, right-click to apply.
15:57:40  span far end moved to id=11808, 0 point(s) between the ends. Right-click to clear and start again.
15:57:48  divided 1 piece(s) into 1 point(s) total, 0 intersection anchor(s) kept in place.
```

Note the span there was two adjacent waypoints with nothing between them, which is the degenerate
case — worth checking whether the fault is specific to that or general.

They were two independent faults, as the note here guessed they might be.

</details>

---

## 2. Input system occasionally does not restore on exit — NOT A BUG

**Resolved 2026-09-08**: the detector was wrong, not the input handling. Fixed in
`FS25_ADFlyoverEditor` 0.7.2.0.

The before/after, captured on the third occurrence:

```
before: contexts=5 events=173 nameActions=408 cursor=false
after:  contexts=7 events=173 nameActions=408 cursor=true
```

`events` and `nameActions` identical, context and stack depth restored — nothing destroyed. Input
contexts are created and never destroyed so that count only grows, and the cursor ends where
AutoDrive's `showHUD` wants it, which the exit deliberately sets.

The check compared the whole state string, so it warned on every clean exit. That is worse than no
check: a real occurrence would have been lost in the noise. It now compares only the fields that can
indicate damage.

<details><summary>Original report</summary>

**Observed:** 2026-09-08, once, at 15:50:27. **Status:** open, intermittent, low confidence.

```
Warning: [FlyoverEditor]: the input system did not come back as it was found.
```

That is the editor's own before/after check — the detector built during the four input-context bugs
(see [`flyover-input-context.md`](flyover-input-context.md)).

It did **not** fire on the clean exit at 15:58:19 in the same session, and the player's keys were not
reported as broken either time. So this is either a benign difference the check is too strict about,
or an intermittent version of the bug that document describes.

**Worth knowing before chasing it:** the four bugs in that document were all found by measuring each
call individually rather than the cycle as a whole, because a conserved event total is not evidence
of no damage. If this recurs, go straight to per-call deltas rather than trusting the summary line.

If it turns out to be real, the symptom to watch for is WASD dead after Escape, recoverable with
`FlyoverResetInput`.

</details>

## Editing requires being in a vehicle

Reported 2026-09-09. Routes cannot be written unless the player is seated in a vehicle.

What has been ruled out: `Proxy.findHostVehicle` already falls back to any vehicle carrying
`ad.stateModule`, not only the controlled one, so the stand-in `self` should be available with the
player on foot. The remaining `AutoDrive.getControlledVehicle()` calls on our side are a diagnostic
string (`describeInputState`), the camera's opening position (which falls back to `g_localPlayer`),
and two console commands - none of them gate waypoint creation.

So the requirement most likely lives inside AutoDrive: the graph-writing path, its network events, or
whatever decides the editor may run at all. Worth confirming which, because the answer decides
whether this is fixable from a companion or is a limit of editing someone else's mod from outside.

Related: the `name` tool had the same shape of problem and turned out to be `ADEnterTargetNameGui`
acting on the vehicle's nearest waypoint - fixed with a wrapper. A second wrapper may well be the
answer here too.

# The flyover editor and the player's key bindings

**Status: fixed and confirmed in game.** The `setContext` root cause below was the last of the four,
and repeated editor activations no longer destroy the player's bindings.

Keep reading anyway if you touch this area — the four bugs are still the map of how it can go wrong,
and the two general lessons at the end cost four debugging rounds to learn.

The symptom, seen repeatedly: after using the flyover editor, the player's **W** (movement) and
**Q** (attach/detach) stop responding. Tab-ing into a vehicle brings them back.

That last detail is the whole diagnostic key. Entering a vehicle is precisely what re-registers the
gameplay action events. So the bindings were being **destroyed**, not shadowed by a context sitting
on top of them. Everything below follows from taking that seriously.

---

## What actually went wrong — four separate bugs, found in this order

Four different things were wrong, and each one was hidden behind the next. That is why this took so
many passes: every fix was real, and every fix left the symptom in place.

### 1. `revertContext(true)` cleared the wrong context's events (`1afc22f`)

The argument was assumed to mean "clean up the events of the context being *left*". The evidence says
it clears the events of the context being **restored** — i.e. the player's own.

Passing `false` leaks nothing, because the editor already removes everything it registered.

### 2. `camera:removeActionEvents()` removed by action, not by id (`3580f1e`)

It appears to remove bindings **by action** rather than by the ids the camera itself created. So
asking the camera to drop its movement-shaped bindings took the player's bindings for those same
actions with them.

The call was redundant as well as harmful — those events were registered into our own pushed context,
which reverting already drops. It is now called *only* in the diagnostic mode that pushes no context,
where there is nothing to revert (`FlyoverEditor.lua:625`).

This fixed **Q**. **W** still died — which was the useful half of a result, because it proved the two
keys were dying for different reasons.

### 3. The camera was activated before the context was pushed (`82ea5cc`)

An action event lands in whatever context is **current when it is created**. `camera:activate()` was
being called *before* the context push, while the gameplay context was still current — so everything
the camera registered for itself during activation, movement axes included, was created in the
**gameplay** context.

Reverting our own context cannot remove those. The camera is then deleted, and the player's movement
is left bound to an object that no longer exists. Exactly the symptom: W dead until Tab re-registers,
while Q — registered elsewhere — was unaffected.

Activation and positioning now happen after the push, alongside `registerActionEvents`.

### 4. The root cause: `setContext` was creating a context that already existed (`75c33c8`)

`setContext` was called with `createNew = true` on **every** activation. Creating a context that
already exists is destructive. Measured with per-call counters:

```
cycle 1   setContext left the event count at 221
cycle 2   setContext changed the event count 221 -> 210   (-11)
```

The second activation destroyed **eleven** of the player's own bindings, movement among them.

The context is now created once and switched to thereafter, guarded by `self.contextCreated`
(`FlyoverEditor.lua:508-513`).

---

## Why short tests passed for so long

**The first activation was always clean.** Only the second and later ones destroyed anything. So a
quick test worked, and "extended use breaks it" was read as *duration* when it actually meant
*repetition*. Four separate attempts went looking at teardown, because that is where a
duration-shaped bug would live.

If you are testing this: **open and close the editor at least twice.** A single cycle proves nothing.

## Why the measurements looked clean while W was dead

Whole-cycle event totals balanced, because the camera's own events replaced the destroyed player
events **numerically**. A cycle that swapped four of the player's bindings for four of the camera's
reads as a perfectly clean cycle.

This is what made the bug survive three rounds of measurement. The fix was to stop measuring the
cycle and start measuring each call: the count is now taken either side of `setContext`,
`setTerrainRootNode`, `camera:activate`, `cursor:activate` and `registerActionEvents` individually,
and any change is logged as a warning naming the call (`e56bfcf`).

**The general lesson: a conserved total is not evidence of no damage.** Only per-call deltas can say
which call did it.

## The other general lesson: two booleans, two bugs

Bugs 1 and 4 are the same mistake made twice — a boolean argument whose meaning was *assumed* rather
than verified, quietly wiping the player's bindings while reporting success:

- `revertContext(true)` — assumed "clean up what I'm leaving", actually "clear what I'm restoring"
- `setContext(name, createNew, ...)` — assumed idempotent, actually destructive when the context exists

Both are now `false`, and both carry the reasoning inline so the next person does not re-derive it.

---

## Diagnostics that exist, and are worth keeping

| Command / behaviour | What it is for |
|---|---|
| `ADFlyoverResetInput` | Recovery. Shuts the editor down and reverts contexts until none are left. Reverting more than once is normally wrong, which is why it is a deliberate command — but the alternative had twice been restarting the game. Says plainly when it cannot help, i.e. when the gameplay events are gone rather than shadowed. |
| `ADFlyoverNoContext` | Runs the editor without pushing its own context. Clumsy (WASD reaches player and camera at once) but it halves the search: if movement survives, the context machinery is the cause; if it still dies, the camera action events are. |
| before/after `describeInputState()` | Enable and disable each log the input state twice. Only the BEFORE-enable / AFTER-disable pair can say whether a cycle put things back — logging after the push made a clean cycle indistinguishable from a lossy one (`b3551df`). |
| per-call event deltas | The measurement that actually found it. Keep it. |

---

## Why this matters for the companion mod

Input handling is one of the open port blockers in
`companion-mod-investigation.md` (in the AutoDrive fork repo), and **every lesson here transfers
verbatim** — a companion does exactly the same things: pushes an input context, registers action
events, activates and later deletes a `GuiTopDownCamera`.

Two things are specifically worse in a companion:

1. **Blast radius.** Damaging the player's bindings from inside a fork of AutoDrive is bad. Doing it
   from a third-party mod that sits beside *stock* AutoDrive is worse — the user will reasonably
   blame AutoDrive, and the fault will not be in AutoDrive's code.
2. **The bindings themselves — and this document was wrong about them.** An earlier version said
   the editor's keys are declared in AutoDrive's `modDesc.xml` and that a companion therefore needs
   its own `<actions>` block. Both halves are false. `grep -ic flyover modDesc.xml` returns **0**:
   the editor declares no bindings at all. It reads raw key symbols through its own `isKey` helper
   (`FlyoverEditor.lua:772-774`, `:786`, `:800`, `:808`) and registers only the base-game
   `InputAction.MENU_CANCEL` / `MENU_BACK` (`:560-568`). The `AD_FLYOVER_EDITOR` context is created
   at runtime by `g_inputBinding:setContext` (`:509-511`) and needs no `modDesc` entry.

   So a companion needs **no** `<actions>` block, and adding one would create exactly the action-name
   collision this document exists to warn about.

Carry the `contextCreated` guard, the `false` booleans, the per-call deltas and both console commands
across with the editor. They are not scaffolding to be tidied away — they are the only reason this
bug is understood.

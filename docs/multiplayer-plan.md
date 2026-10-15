# Multiplayer support — research & implementation spec

**Status:** research complete, design agreed, **not yet built**. This is the brief the build works
from. Nothing in the mod is changed yet; `modDesc.xml:22` still says
`<multiplayer supported="false" />` and that stays until the test matrix in §10 passes.

Agreed scope, settled before writing:

| Decision | Choice |
|---|---|
| Who may edit | **Any player, one at a time** — a server-granted exclusive lease |
| When others see it | **After every completed action**, shipped as a replayable op log |
| Graph changed underneath | **Detect and resync** — a graph fingerprint the server validates, then pushes truth back |

---

## 1. Where the mod stands today

The editor is single-player in three independent ways, and only one of them is a deliberate design
decision.

**1. The mod cannot load in a multiplayer session at all.** `modDesc.xml:22` declares
`<multiplayer supported="false" />`. The engine reads this as
`getBool("modDesc.multiplayer#supported", false)`; a mod declaring `false` is greyed out and cannot
be selected when hosting or joining. So every other multiplayer consideration in the codebase is
currently unreachable.

**2. `enable()` refuses when there is no server.** `scripts/editor/FlyoverEditor.lua:792-801`:

```lua
if g_server == nil then
    Logging.warning("[FlyoverEditor] refusing to open on a multiplayer client: edits here are "
        .. "not sent to the server and would be lost. Host or single-player only.")
    return false
end
```

Two tools guard again on their own — `placeWaypointAtCursor` (`:5205`) and
`generateFieldLoopAtCursor` (`:10377`), plus `AutoDrive:generateFieldLoop`
(`scripts/editor/FieldLoopGenerator.lua:554`). Given (1) these are belt-and-braces, not load-bearing.

**3. Every graph write is deliberately local.** All 40-odd mutating calls into AutoDrive pass
`sendEvent = false`. That is what makes the editor fast and undoable, and it is also exactly why
nothing propagates. The one exception is the name tool: `scripts/Wrappers.lua:329` calls
`ADGraphManager:createMapMarker(overrideId, text)` with no `sendEvent` argument, so it defaults to
`true` and **already** fires `AutoDriveCreateMapMarkerEvent`. One tool out of fifteen syncs, by
accident.

**A documentation discrepancy worth fixing either way.** `docs/companion-build-plan.md:114` says
"Single-player and listen-server host only", and §5.6 treats the host as a supported configuration.
It is not — `supported="false"` stops the mod loading in multiplayer, host included. Whichever way
this spec goes, that line is wrong today.

### Why persistence forces the design

`AutoDrive:saveSavegame` (`AutoDrive.lua:542-551`) writes the route network **only when
`g_server ~= nil`**:

```lua
function AutoDrive:saveSavegame()
    if g_server ~= nil then
        AutoDrive.saveToXML()
        ADUserDataManager:saveToXml()
    end
end
```

The server's copy of the graph is the only copy that is ever persisted. A client's local edits are
not merely invisible to others — they are erased on the next join. Any design where a client's edits
do not reach the server is not a degraded design, it is a data-loss bug. That is the correct
reasoning behind the existing refusal, and it is what makes "just let clients edit locally"
unavailable as an option.

---

## 2. What AutoDrive already gives us

AutoDrive 3.0.1.2 declares `<multiplayer supported="true" />` and has a complete, working
multiplayer graph model. Reading it settles most of our design.

### 2.1 The join-time snapshot

`scripts/Sync.lua` registers an `AutoDriveSync` object whose `writeStream`/`readStream` ship the
entire graph — waypoints, markers, groups — to each joining client, bit-packed
(`AutoDriveSync.streamWriteGraph` / `.streamReadGraph`). A client therefore starts with the server's
exact graph. Two consequences:

- Anything we break mid-session is repaired by a rejoin.
- `streamWriteGraph` is a ready-made whole-graph codec we can reuse, and it **already logs its own
  size** (`"[AutoDriveSync] Written %s bits (%s bytes) in %s ms"`), which is how we measure §6.

### 2.2 The `sendEvent` convention

Every mutator on `ADGraphManager` takes a trailing `sendEvent`. With `sendEvent` true or nil it
raises an Event and **does nothing else**; with `false` it performs the mutation. Every event's `run`
follows the same shape (`CreateWayPointEvent.lua:78-87`):

```lua
if g_server ~= nil and connection:getIsServer() == false then
    -- from a client: the server only rebroadcasts
    AutoDriveCreateWayPointEvent.sendEvent(...)
else
    -- from the server: server and clients both apply
    ADGraphManager:createWayPointWithConnections(..., false)
end
```

So AutoDrive's model is: **clients propose, the server broadcasts to everyone including itself, all
peers apply identically.** Notably AutoDrive does *not* restrict graph editing to admins — the only
`isMasterUser` gates in the mod are in `RoutesManager.lua`, for route file import/export.

### 2.3 The events that exist

`scripts/Events/Graph/` has fourteen: `CreateWayPoint`, `DeleteWayPoints`, `MoveWayPoint`,
`RecordWayPoint`, `ToggleConnection`, `SetConnection`, `CreateSplineConnection`, `Section`,
`CreatePlaceable`, `RoutesUpload`, and four marker/group ones.

Two are directly useful to us:

- **`AutoDriveRoutesUploadEvent`** — a whole-graph push, usable in both directions, built on
  `AutoDriveSync.streamWriteGraph`. Its `run` does the six things a full graph swap needs (waypoints,
  markers, destination listeners, groups, `resetMarkersOnReload` on the server, HUD invalidation).
  AutoDrive uses it for route import (`RoutesManager.lua:101`). **This is our undo/resync primitive
  and we should not reimplement it.**
- **`CreatePlaceableEvent`** — appends a whole sub-graph of waypoints with connections in one event.
  Proof that batch graph events are within the engine's means, and a useful size reference.

### 2.4 Why we cannot simply pass `sendEvent = true`

Tempting, and wrong, for four reasons.

1. **The return value disappears.** `createWayPointWithConnections` returns the new waypoint only on
   the `sendEvent == false` branch (`GraphManager.lua:640-663`). Nine of our call sites use the
   returned waypoint immediately to connect it to something else. With `sendEvent = true` they get
   `nil`.
2. **Events are asynchronous, even locally.** The mutation happens inside the broadcast, not at the
   call site. Compound tools that read back what they just wrote — which is most of them — break.
3. **Our connection primitives are not AutoDrive's.** The editor deliberately does direct list
   surgery in ten places (`FlyoverEditor.lua:583-592`, `8106-8120`, `9169-9170`, `9686-9700`,
   `10285-10288`) because `toggleConnectionBetween` *flips* whatever is there, which is the wrong
   tool for "make this unconditionally true". The file says so at `:569` and again at `:8100`. There
   is no AutoDrive event with idempotent set/clear semantics: `SetConnectionEvent` clears **all**
   links between a pair first, which is not what `setLink` does.
4. **One user action is dozens of primitives.** A junction build is on the order of 60 creates, 120
   link changes and 40 deletes. As individual events that is 220 network round trips for one click,
   each one renumbering ids underneath the next.

The conclusion is decisive and shapes everything below: **we ship one custom event carrying our own
op vocabulary, and we do not route through AutoDrive's events** — except `RoutesUploadEvent` for
whole-graph pushes.

---

## 3. The id problem, and why replay is the answer

`ADGraphManager:removeWayPoint` renumbers every id above the deleted one
(`GraphManager.lua:288-306`, complete with the author's own `:(`). `EditorHistory.lua:6` already
documents the consequence for undo:

> waypoint ids in this mod are POSITIONAL, not stable […] Any stored id is therefore invalidated by
> an unrelated later delete, and the corruption is silent.

This rules out the obvious wire format. A **state patch** — "here are the waypoints that changed" —
is cheap when nothing is deleted and catastrophic when something is: deleting waypoint 100 in a
17,174-waypoint graph changes the id of 17,074 waypoints and every reference to them. The patch is
bigger than the graph.

What *does* work is **replay**. If two peers hold an identical graph and apply an identical ordered
sequence of primitives, they end up identical — renumbering included, because the renumbering is
deterministic. So the wire format is an **ordered op log**, and the correctness condition is
"identical starting graph", which §7 enforces with a fingerprint.

This is not a new burden on the editor. It already has exactly the right structure: 23 user-visible
actions, each bracketed by `ADEditorHistory:snapshot(label)` before the mutation and
`invalidateIdReferences()` + `ADGraphManager:markChanges()` after it. The op log is just a recording
of what happens between those two points.

---

## 4. Architecture

Four new files, all in the **deterministically sourced** set (see §4.5), plus a shim the editor
calls instead of `ADGraphManager` directly.

```
scripts/net/FlyoverNet.lua       state: mode, lease, fingerprint, revision; the frame flush
scripts/net/GraphOps.lua         the op vocabulary: apply(), and the codec for each op
scripts/net/TransactionEvent.lua ADFlyoverTransactionEvent  — an op log, chunked
scripts/net/LeaseEvent.lua       ADFlyoverLeaseEvent        — request / grant / deny / release
```

### 4.1 The shim: `ADFlyoverGraphOps`

Every mutating call the editor makes today goes through a shim function instead. Each shim does two
things and nothing more:

1. **Applies locally, exactly as today** — the same `ADGraphManager` call with `sendEvent = false`,
   returning the same value. Behaviour in single-player is unchanged.
2. **Appends the op to the open transaction**, if one is open.

The vocabulary, derived from what the editor actually calls (counts are call sites in
`scripts/editor/`):

| Op | Shim | Applies as | Sites |
|---|---|---|---|
| `WP_ADD` | `addWaypoint(x,y,z,flags)` | `recordWayPoint(..., false)` | 9 |
| `WP_DEL` | `deleteWaypoint(id)` | `removeWayPoint(id, false)` | 11 |
| `WP_MOVE` | `moveWaypoint(id,x,y,z,flags)` | `moveWayPoint(..., false)` | 3 + flags |
| `WP_FLAGS` | `setFlags(id,flags)` | `setWayPointFlags(..., false)` | 3 |
| `LINK_TOGGLE` | `toggleLink(aId,bId,reverse,dual)` | `toggleConnectionBetween(..., false)` | 14 |
| `LINK_SET` | `setLink(aId,bId,dual)` | idempotent insert, our own | 5 |
| `LINK_CLEAR` | `clearLink(aId,bId,both)` | idempotent remove, our own | 5 |
| `MARKER_ADD` | `addMarker(id,name)` | `createMapMarker(..., false)` | 1 |

Notes on the table:

- `setWayPointFlags` delegates to `moveWayPoint` internally (`GraphManager.lua:1458-1465`), so
  `WP_FLAGS` could fold into `WP_MOVE`. Keep it separate on the wire — it is 5 bits of payload
  instead of 101, and flag changes are common (the convert tool).
- `LINK_SET` / `LINK_CLEAR` are the ten direct-surgery sites, promoted from local helpers
  (`junctionConnect`, `junctionDisconnect`, `setLink`, `removeLink`, `disconnectExternal`) into
  named ops. **This is the only part of the editor that has to change semantically** — those helpers
  currently mutate `wp.out` / `wp.incoming` directly and must route through the shim so their effect
  is recorded. Their bodies move into `GraphOps.lua` unchanged.
- `createSplineConnection` is **not** an op. It is a loop over `createWayPointWithConnections` and
  `toggleConnectionBetween` (`GraphManager.lua:1796-1830`), so it decomposes into `WP_ADD` +
  `LINK_TOGGLE` ops for free. Two of our four call sites already build the interpolation themselves.
- `absorbTrack` (the merge tool, `FlyoverEditor.lua:10251-10257`) writes `a.x`, `a.z`, `a.y`
  **directly** into live waypoints. It must become `WP_MOVE`. This is the only direct coordinate
  write on a live waypoint in the codebase — the other four `.y =` assignments (`:5743`, `:6339`,
  `:9617`, `OffsetGeometry.lua:1060`) are on temporary preview tables and are fine as they are.
- `ADEditorHistory:restoreState` (`EditorHistory.lua:98-125`) is **not** ops. See §5.

### 4.2 Coordinate determinism — quantize in the shim

A detail that will silently corrupt this design if missed.

Coordinates are Lua doubles. If the originator applies its exact doubles locally and the wire carries
a lossy encoding — `NetworkUtil.writeCompressedWorldPosition` as `AutoDriveSync` uses, or
`streamWriteFloat32` as `CreateWayPointEvent` uses — then after the very first transaction the
originator's graph and its peers' graphs differ in the low bits of every point touched. The
fingerprint in §7 then never matches, and every subsequent action is rejected as stale.

The fix is to make the encoding lossless by agreement rather than trying to make it lossless:

> **The shim quantizes every coordinate to millimetres on the way in, in both single-player and
> multiplayer, and the wire carries the quantized integer.**
>
> `q(v) = math.floor(v * 1000 + 0.5)` written as `streamWriteInt32`; applied everywhere as
> `q(v) / 1000`.

Int32 millimetres covers ±2,147 km, against a 2–4 km map. 1 mm is four thousand times finer than the
network's own ~4 m point spacing (measured in `docs/junction-plan.md:20`), so nothing visible
changes. Quantizing in single-player too, rather than only in multiplayer, means one behaviour to
test instead of two.

### 4.3 Transaction boundaries

A transaction opens on the first op after a quiet frame and closes at the **frame flush**. The flush
lives in `ADFlyoverPrelude:update` (`Prelude.lua:172`), deliberately **not** in
`ADFlyoverEditor:update` — the latter returns early when a GUI or modal has the screen
(`FlyoverEditor.lua:1334-1357`), and the name tool's edits happen with a dialog open.

The flush sends when all of:

- a transaction has ops in it, and
- `self.dragId == nil` — a drag in flight would otherwise emit a transaction per frame per point, and
  a 2,000-point falloff drag would emit 2,000 of them. Drag commits arrive via `finishDrag`
  (`FlyoverEditor.lua:4041-4154`), which already ends in `markChanges()`.

This is one hook, not 23. It is also robust against a tool that forgets to announce itself: if ops
were recorded, they ship.

### 4.4 Flow

**Single-player** (`not g_currentMission.missionDynamicInfo.isMultiplayer`): no transaction is
opened, no event is built, nothing is serialized. The shim is a direct pass-through. Today's code
path, byte for byte, minus the millimetre quantization.

**Multiplayer host** (`g_server ~= nil`): apply locally as the ops are recorded, then at the flush
`g_server:broadcastEvent(event, false)` — `false` because the host has already applied. Clients
apply on receipt.

**Multiplayer client** (`g_server == nil`): apply locally as the ops are recorded — the tools need
their return values, and the exclusive lease makes this safe — then at the flush
`g_client:getServerConnection():sendEvent(event)`. The server validates the fingerprint (§7), applies,
and rebroadcasts to every *other* client. The originating client is skipped, since it already
applied; the transaction carries the originator's user id so the server can exclude it.

**Dedicated server**: never opens an editor (no client, no cursor, no HUD), but must apply
transactions and hold the lease. The apply path touches nothing but `ADGraphManager`, so this is
sound in principle — §10 tests it for real.

### 4.5 Registration timing — the one thing that must not be got wrong

`InitEventClass` registers an event class **by name**, and the server sends each joining client the
id↔name mapping at connection time. Load order across peers therefore does not have to match. But a
class registered *after* a client has connected is not in that client's mapping, and every send
fails with an invalid event id.

Our editor files are sourced **lazily, from an update tick, after AutoDrive resolves** —
`Prelude.lua:11-23` explains why, and the probe measured a 54-second gap between mod source and
successful resolution. That timing is not just non-deterministic, it can be *after join*.

So: **the four files in §4 go into `<extraSourceFiles>` via `Prelude.lua`'s eager `source()` block
(`Prelude.lua:38-44`), never into `P.EDITOR_FILES`.** They must not reference `ADGraphManager` at
source time — only inside functions, where arming has long since republished it.

A related limitation to state rather than solve: if arming fails on one peer and succeeds on another,
that peer cannot apply transactions and its graph goes stale until it rejoins. Since AutoDrive is a
hard dependency and multiplayer requires identical mod lists on all peers, the realistic cause is a
future AutoDrive that this mod refuses to attach to — in which case the mod is inert there anyway.
Log it loudly at `Logging.error` and move on.

---

## 5. Undo and redo

`ADEditorHistory` is snapshot-based, for the id-instability reason quoted in §3, and
`restoreState` swaps the whole graph (`EditorHistory.lua:98-125`).

There is no sensible op log for that, and there does not need to be one, because AutoDrive already
has exactly the right event:

```lua
AutoDriveRoutesUploadEvent.sendEvent(entry.wayPoints, entry.mapMarkers, entry.groups)
```

From a client it goes to the server, which rebroadcasts to everyone including itself; from the host
it broadcasts directly. Its `run` performs the same six steps `restoreState` does, which is where
`restoreState`'s own comments say they came from. **In multiplayer, undo and redo are one extra call
each.**

This also hands us the **resync primitive** for free: a forced whole-graph push from the server is
how §7 repairs divergence, and how a future manual "publish" button would work if one is ever wanted.

The cost is size, and it is the one real unknown — see §6. Undo is rare and user-initiated, so a
one-off quarter-megabyte push is a tolerable price where a per-action one would not be.

Two existing limitations get worse in multiplayer and should be written down:

- **Nothing clears the history stack when the graph is replaced underneath it.**
  `docs/companion-build-plan.md:970` defers this on the grounds that single-player makes it nearly
  unreachable. Multiplayer makes it routine — any resync, route import, or another player's upload
  replaces the graph. Fix properly: on applying a resync or on a rejected transaction, call
  `ADEditorHistory:clear()`. The reentrancy guard that doc worries about is unnecessary if we clear
  from the *net* layer rather than by wrapping `setWayPoints`.
- **Undo is only meaningful for the lease holder.** Nobody else can reach it, since the editor will
  not open without the lease. Nothing to do, but say so in the manual.

---

## 6. Wire format and size

### 6.1 Measured graph sizes

From the user's own savegames (`.../FarmingSimulator2025/savegameN/AutoDrive_config.xml`):

| Savegame | Waypoints | Mean out-degree |
|---|---|---|
| savegame2 | **17,174** | 1.24 |
| savegame4 | 12,479 | 1.24 |
| savegame6 | 12,563 | 1.23 |

These are large, real networks — the design must hold at 17k, not at 500.

### 6.2 Transaction encoding

Header, once per chunk:

| Field | Bits |
|---|---|
| protocol version | 4 |
| transaction id | 16 |
| chunk index / count | 8 / 8 |
| originator user id | 8 |
| base fingerprint | 32 |
| `idBits` | 5 |
| op count in this chunk | 12 |

`idBits = ceil(log2(max(preCount, postCount) + 1))`, so 15 bits per id at 17k waypoints — the same
trick `AutoDriveSync.MWPC_SEND_NUM_BITS` uses. Ops then pack as a 4-bit opcode plus operands, with
coordinates as three `Int32` millimetre values and flags in 5 bits (matching
`AutoDriveSync.FLAG_SEND_NUM_BITS`).

Per-op cost at 17k waypoints:

| Op | Bits | ≈ Bytes |
|---|---|---|
| `WP_ADD` | 105 | 13 |
| `WP_MOVE` | 120 | 15 |
| `WP_DEL` | 19 | 2.4 |
| `LINK_SET` / `LINK_CLEAR` / `LINK_TOGGLE` | 35–37 | 4.5 |

### 6.3 Which actions fit, and which need chunking

| Action | Ops | ≈ Size |
|---|---|---|
| Place a waypoint, toggle a connection, name a point | 1–3 | < 50 B |
| Drag one point with falloff over 20 neighbours | 21 × `WP_MOVE` | ~320 B |
| Junction build (60 add, 120 link, 40 delete) | 220 | **~1.4 KB** |
| Delete a run of 300 points | 300 × `WP_DEL` | ~750 B |
| Field loop round a large field (800 points) | ~1,600 | **~14 KB** |
| Box-grab move of 2,000 points | 2,000 × `WP_MOVE` | **~30 KB** |
| Whole-graph push (17k waypoints, undo/resync) | — | **~250–330 KB** |

The community convention for a per-event budget is around **8 KB**, with chunking above it — that is
what `FS25_NetworkSync` does, and its protocol exists specifically to chunk across that boundary. We
have found no authoritative Giants figure for a hard maximum, and should not pretend to one.

So: **chunking is required, not optional.** Chunk payloads at 6 KB to leave headroom; peers buffer by
transaction id and apply **only when the last chunk arrives**, atomically, so a partial transaction is
never visible. Events from one connection arrive in order, so no reordering logic is needed — but a
missing chunk must time out (2 s) and trigger a resync rather than wait forever.

### 6.4 The measurement that must happen first

Whether `AutoDriveRoutesUploadEvent` survives a 17k-waypoint graph is the single open technical
question in this spec, and it decides how much of §5 is one line and how much is a new chunked
codec.

It is cheap to answer, because `AutoDriveSync` already logs its own size:

```
[AutoDriveSync] Written %s bits (%s bytes) in %s ms
```

**Test:** two peers, savegame2's 17,174-waypoint network, call
`AutoDriveRoutesUploadEvent.sendEvent(ADGraphManager:getWayPoints(), ...)` from the client, and read
the log on both ends plus the resulting waypoint count.

- **If it arrives** — undo, redo and resync are one line each, and §5 is done.
- **If it truncates, errors or silently drops** — we need `ADFlyoverGraphSyncEvent`: the same
  `AutoDriveSync.streamWriteGraph` payload, sliced into 6 KB chunks, reassembled and handed to the
  same six steps `RoutesUploadEvent:run` performs. That is perhaps 120 lines, and it is the honest
  fallback rather than a graph-size limit nobody documented.

Do this measurement before writing anything else. It is the only fact in this spec that is guessed
rather than read.

---

## 7. Divergence: the fingerprint

The agreed policy is detect-and-resync. Two peers can drift for reasons the lease cannot prevent —
another player recording waypoints in a vehicle, a route import, AutoDrive's own debug markers, a
dropped chunk.

### 7.1 A fingerprint, not a counter

The obvious mechanism is a revision counter bumped on every mutation. It is fragile: it only stays in
step if every peer executes the same number of bumps, and there are paths that mutate on one peer
only (`checkYPositionIntegrity`, `createDebugMarkers` / `removeDebugMarkers`).

Use a **fingerprint of the graph itself** instead. It catches divergence from *any* cause, including
ones we have not thought of:

```lua
-- 32-bit, order-fixed (1..n, never pairs()), coordinates quantized to 0.1 m so the
-- low bits of a compressed position cannot register as a difference.
function F.fingerprint()
    local h = 2166136261
    local wps = ADGraphManager:getWayPoints()
    local n = #wps
    h = mix(h, n)
    for i = 1, n do
        local wp = wps[i]
        h = mix(h, math.floor(wp.x * 10)); h = mix(h, math.floor(wp.z * 10))
        h = mix(h, wp.flags or 0)
        h = mix(h, #wp.out * 64 + #wp.incoming)
        for j = 1, #wp.out do h = mix(h, wp.out[j]) end
    end
    return h
end
```

Two deliberate choices. **`y` is excluded** — it is derived from terrain and is the field most likely
to differ harmlessly between peers. **Iteration is `1..n`, never `pairs()`** — sets keyed by waypoint
tables iterate in address order, which is not stable across peers, and this project has been bitten
by that before.

Cost at 17,174 waypoints: roughly 40k arithmetic operations in Lua, a low single-digit number of
milliseconds. Computed once per transaction, at human click rate. Cache it and invalidate on any
apply.

### 7.2 The protocol

1. The client stamps each transaction with the fingerprint of the graph **before** its ops.
2. The server recomputes its own. Match → apply, rebroadcast to the other clients, done.
3. Mismatch → **reject**. The server sends the rejection to the originator and pushes the whole graph
   to it (§5's resync primitive). The client applies the truth, clears `ADEditorHistory`, and the
   panel says so:

   > *The route network changed while you were editing. Your last action was not applied and the
   > editor has reloaded the server's copy.*

   The rejected action is lost. That is the honest outcome: it was computed against a graph that no
   longer exists, and replaying it would put points in the wrong places.
4. On the host, steps 1–3 collapse to a local comparison that always passes.

The lease makes rejection rare — it can only fire when AutoDrive's own editing races us, which needs
a second player actively recording while someone is in the flyover editor.

---

## 8. The lease

Exclusive, server-held, one holder:

```
ADFlyoverLeaseEvent  REQUEST | GRANT | DENY | RELEASE | REVOKE
```

- **REQUEST** on `enable()`. On the host this resolves locally with no round trip. On a client the
  editor shows "requesting edit lease…" and opens on GRANT.
- **GRANT** carries the server's current fingerprint, so the client starts from a known base.
- **DENY** carries the current holder's nickname, resolved via
  `g_currentMission.userManager:getUserIdByConnection(connection)` — the same call AutoDrive uses in
  `UserDataManager.lua:7` and `AutoDrivePlaceableData.lua:114`. The refusal reads:

  > *`<nickname>` is editing the route network. Only one player can use the flyover editor at a time.*

- **RELEASE** on `disable()`, on mission teardown, and on `deleteMap`.
- **REVOKE** when the server drops a stale lease.

**Expiry by heartbeat, not by connection hooks.** The holder's client sends a keepalive every 5
seconds while the editor is open; the server drops the lease after 15 seconds of silence. This
survives a crash, an alt-tab freeze and a hard disconnect without hooking connection teardown, which
is base-game internals this mod has a standing policy of not reaching into.

Single-player takes none of this path: `not missionDynamicInfo.isMultiplayer` short-circuits to
"lease held" without an event.

---

## 9. Build phases

Ordered so that each phase is independently verifiable and nothing ships half-wired. `modDesc.xml`
stays at `supported="false"` until Phase 6.

**Phase 0 — measure.** §6.4 only. Establish whether a 17k-waypoint `RoutesUploadEvent` arrives
intact. Also fix `docs/companion-build-plan.md:114`, which claims listen-server support the mod does
not have. *Deliverable: a number in `docs/probe-results.md`.*

**Phase 1 — the shim, single-player only.** `GraphOps.lua` with all eight ops. Every mutating call
site in `scripts/editor/` moved onto it, including the ten direct-surgery sites and `absorbTrack`.
Millimetre quantization on. No events, no transactions, no `modDesc` change. *This is the largest
and least glamorous phase, and the only one that touches the editor's 10,407 lines.* Verified by the
existing offline harness: every junction regression must produce byte-identical output to today,
modulo millimetre rounding.

**Phase 2 — transactions and the frame flush.** `FlyoverNet.lua`, `TransactionEvent.lua`, chunking,
the fingerprint. Still single-player, but with transactions built and serialized to a log rather than
sent, so the codec can be tested and sized against real actions before any network is involved.

**Phase 3 — host to clients.** `supported="true"` in a local build only. Host edits, one client
watching. The whole §10 matrix except the client-edit rows.

**Phase 4 — clients to server.** The client→server direction, the lease, rejection and resync.

**Phase 5 — dedicated server.** The configuration most multiplayer games actually use, and the one
this mod has never run in. Headless apply, headless lease, no editor.

**Phase 6 — ship.** `modDesc.xml:22` to `supported="true"`. README and `docs/manual.md` updated:
"Single player only" becomes a description of the lease and of what the other players see. German
strings for the four or five new panel messages, following `scripts/editor/Locale.lua`. A release
version decided — note that `docs/` records 1.0.1.0 as the move tool and that the junction rework
branch also carries 1.0.1.0, so the number needs settling at merge, not here.

---

## 10. Test matrix

Every row is two machines minimum. "Converged" means equal fingerprints on all peers *and* an equal
waypoint count in the server's saved `AutoDrive_config.xml` after a save.

| # | Scenario | Expected |
|---|---|---|
| 1 | Host places one waypoint | Client sees it within a frame; converged |
| 2 | Client places one waypoint | Host and every other client see it; converged; survives a server save/reload |
| 3 | Client builds a junction (~220 ops) | One transaction, ~1.4 KB, converged |
| 4 | Client field-loops a large field | Chunked; applied atomically — no partial loop ever visible |
| 5 | Client box-moves 2,000 points | Chunked; one transaction on drop, not per frame |
| 6 | Client drags a point with falloff | **One** transaction at drop, not one per frame |
| 7 | Client undo, then redo | Converged both ways; `ADEditorHistory` consistent |
| 8 | Second player requests the lease | Denied by name; editor does not open |
| 9 | Lease holder alt-F4s | Lease expires within 15 s; another player can open |
| 10 | Another player records waypoints in a vehicle mid-edit | Transaction rejected, editor resynced, message shown, nothing corrupted |
| 11 | Client joins mid-edit | Gets the current graph via `AutoDriveSync`; converged |
| 12 | Dedicated server, two clients, one editing | Converged; server persists; no Lua errors in the dedi log |
| 13 | Dedicated server, nobody in the editor | Mod sources cleanly headless; no overlay or i18n errors at load |
| 14 | AutoDrive vehicle driving a route being edited | No crash; route recalculates or the vehicle stops cleanly |
| 15 | Single-player, every tool | Identical to today modulo millimetre rounding — the offline harness |
| 16 | Name a waypoint in multiplayer | One marker, not two — `Wrappers.lua:329` currently fires AutoDrive's own event **as well as** ours |

Row 16 is a real bug the shim introduces if `Wrappers.lua:329` is left as it is: it would create the
marker through AutoDrive's event *and* record a `MARKER_ADD` op. Pass `false` there when moving it
onto the shim.

Row 14 deserves emphasis. Everything above concerns the graph; AutoDrive *vehicles* hold live paths
into it. `ADGraphManager:checkResetVehicleDestinations` and `resetMarkersOnReload` exist for this,
and `RoutesUploadEvent:run` calls the latter on the server. Whether a vehicle mid-route survives its
waypoints being renumbered underneath it is an AutoDrive question that single-player has already been
asking — but in multiplayer it is asked on every peer at once, and a Lua error on a dedicated server
is much more expensive than one in single-player.

---

## 11. Risks, honestly

| Risk | Reality | Mitigation |
|---|---|---|
| `RoutesUploadEvent` cannot carry a 17k graph | Unknown; the one guessed fact here | Phase 0 measures it; §6.4 has the fallback |
| Event-class registration lands after a client connects | Real and fatal if got wrong | §4.5 — eager `source()`, never `P.EDITOR_FILES` |
| Coordinate drift defeats the fingerprint | Certain, if not handled | §4.2 — millimetre quantization in the shim |
| Phase 1 breaks single-player | The largest edit in the plan | The offline junction harness is the regression gate; Phase 1 ships alone |
| Direct list surgery missed at one site | Silent divergence — the worst failure mode | The ten sites are enumerated in §4.1; grep for `%.out` / `%.incoming` writes in CI |
| Source-time work fails headless | Untested — the mod has never run on a dedi | Row 13; source-time code is table definitions only, which is promising, not proof |
| A dedicated server with no client holds a lease nobody can use | Design gap if unhandled | The server never requests a lease for itself |
| Mod and AutoDrive versions differ across peers | Multiplayer requires identical mod lists, so mostly moot | Include the protocol version in the transaction header and refuse a mismatch loudly |

---

## 12. What this does not attempt

- **Concurrent editing.** One editor at a time, by design. Merging two people's geometry is a
  research project, not a feature.
- **Making AutoDrive's own editing safe against ours.** We detect the collision and resync; we do not
  suppress other players' edits, which would mean interfering with AutoDrive's event handling — a
  line this mod has not crossed and should not cross for this.
- **Console multiplayer.** Script mods do not run there.
- **Syncing editor preferences.** Theme, scale, panel position and the launch button are per-player
  local settings under `modSettings/FS25_ADFlyoverEditor/` and stay that way.
- **Placeable junctions as objects.** The `AD_XandT-intersections` support the README describes
  operates on the waypoints that mod lays down, which are ordinary AutoDrive waypoints and sync like
  any others. No placeable object is moved, so no placeable sync is needed — **confirm this before
  Phase 6**; if the move tool ever repositions the placeable itself, that is server-owned state and
  needs its own event.

---

## Appendix — sources

AutoDrive 3.0.1.2, read from `mods/FS25_AutoDrive.zip`: `scripts/Sync.lua`,
`scripts/Manager/GraphManager.lua`, `scripts/Manager/RoutesManager.lua`, `scripts/AutoDrive.lua`,
`scripts/Events/Graph/*.lua`, `scripts/Utils/AutoDrivePlaceableData.lua`.

Waypoint counts measured from `savegame2`, `savegame4` and `savegame6`
`AutoDrive_config.xml`.

On `<multiplayer supported="false" />` excluding a mod from multiplayer:
[GIANTS forum — mods not working in multiplayer](https://forum.giants-software.com/viewtopic.php?t=208849),
[GIANTS forum — FS25 multiplayer mods not working](https://forum.giants-software.com/viewtopic.php?t=209289).

On event-id negotiation by name and the per-event size budget:
[FS25_NetworkSync PR #7](https://github.com/Realistic-Farming/FS25_NetworkSync/pull/7),
[FS25_SeasonalCropStress PR #202](https://github.com/Realistic-Farming/FS25_SeasonalCropStress/pull/202),
[FS25_RandomWorldEvents PR #48](https://github.com/Realistic-Farming/FS25_RandomWorldEvents/pull/48).
No authoritative Giants figure for a hard maximum event size was found; §6.3 treats 8 KB as a
convention and chunks regardless.

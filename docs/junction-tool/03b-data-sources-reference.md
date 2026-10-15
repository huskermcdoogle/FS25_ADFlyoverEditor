# Data sources: reference

*Draft 2, 2026-09-30. Companion to [What the tool can read](03-data-sources.md): the details for whoever
builds it.*

## How to read it

For whoever builds it. None of the new reads has run in game yet. These calls are missing from the
engine function list, so the game's own Lua is the evidence: `getInfoLayerFromTerrain`,
`getBitVectorMapSize`, `getBitVectorMapPoint`, `loadBitVectorMapFromFile`,
`getVehicleNavigationMapCostAtWorldPos`, `DensityMapModifier`.

- **Ground paint:** `getTerrainAttributesAtWorldPos(terrainRootNode, x, y, z, true, true, true, true,
  false)` returns r, g, b, softness, materialId (as `WheelPhysics.lua:880`). Attribute names at
  `mapUS.i3d:9164-9169` (color, softness, materialId, aiDriveCost); the 86 layers at `:9170-9255`, each
  with one `attributes` string in that order (asphalt01: `0.071 0.063 0.063 0 7 4`). Our check:
  `isRoadAt`, `FlyoverEditor.lua:9196`, `ROAD_MATERIALS` at `:9171`. Wheel rule: `WheelsUtil.lua:519-535`.
  Placeables paint through `groundType` (`PlaceableLeveling.lua:190-223`).
- **Drive-cost map (host):** `g_currentMission.aiSystem:getNavigationMap()`, then
  `getVehicleNavigationMapCostAtWorldPos(map, x, y, z)` returns cost, isBlocking (`AISystem.lua:447,
  706, 1154`). Built only when `isServer` (`AISystem.lua:341-343`). Offline:
  `savegame6/vehicleNavigationCostmap.dat` ("VNCM", zlib, 1032-byte header, 2048 x 2048 bytes; value =
  17 x (cost - 1) + penalty, measured on road-line cells; 255 = blocked).
- **Road lines and groups:** the game's list `g_currentMission.aiSystem.roadSplines` is filled only on
  the server (`AISystem.lua:218`, `if self.isServer`). The lines are also map scene nodes under
  `splines/trafficSplines` (`mapUS.i3d:23971`), which every machine loads; walking them on a joined
  machine is untested. Group = `getName(getParent(spline))`; 105 `crossroadsN` (Alma: `crossroadN`).
  Road names (`dirtway...TwoDirections`, `fields...TwoDirections`, `...OneDirection`) under the `ai`
  group (`mapUS.i3d:25287`). Also `getSplineCurvature`, `getUserAttribute(spline, "maxWidth")`. Our file:
  `dumpRoadSplines`, `FlyoverEditor.lua:10697` (console `FlyoverRoadSplines`); height dropped at
  `:10713-10714`; the group needs one more `setXMLString`.
- **Signs:** a group holding a joint (`breakableJoint="true" jointBreakForce="25"`) and a dynamic
  `colMain` (stop at `mapUS.i3d:205729`), all under `map/trafficSigns` (`mapUS.i3d:204552`, nodeId
  201735). `colMain` has no collision group in the file; in game it reports 255 (bits 0-7, no
  DYNAMIC_OBJECT). Our probe hits signs through DEFAULT (`FlyoverEditor.lua:14084`). From a hit:
  `getName(getParent(getParent(id)))`. Map-wide: `overlapSphere` with DEFAULT and includeDynamics=true,
  keeping hits whose rigid body type is 2 or whose parent is the breakable joint.
- **Painted masks and blocked-area maps:** `getInfoLayerFromTerrain(g_terrainNode, "tipCollision")`
  (also `placementCollision`, `tipCollisionGenerated`, `placementCollisionGenerated`),
  `getBitVectorMapSize`, `getBitVectorMapPoint(map, px, pz, 0, bits)`, as `FarmlandManager.lua:76,
  110-111, 427, 543-547`. Declared at `mapUS.i3d:9483, 9496` (generated 9489, 9502) with
  `runtime="true"` like `farmlands`, which `FarmlandManager.lua:69-111` reads with no server check; so
  joined players probably have the masks. Offline: `data/maps/mapUS/data/infoLayer_*.grle`,
  `savegame6/infoLayer_*Generated.grle`.
- **Painted area in one call:** `DensityMapModifier.new(layer, firstChannel, numChannels,
  g_terrainNode)`, `addPolygonPointWorldCoords`, then `executeGet(filter)` returns a pixel count; works
  on info layers (`FieldManager.lua:120-150`).
- **Slope:** `getTerrainHeightAtWorldPos(terrainRootNode, x, 0, z)`; `getTerrainNormalAtWorldPos` returns
  nx, ny, nz; slope = acos(ny), downhill = (nx, nz). Offline: `savegame6/terrain.heightmap.png` (2049 x
  2049, 16-bit, height = value / 65535 x 255 m). Stub heights today: `splitAt` averages its neighbours
  (`FlyoverEditor.lua:16835`), tidy-extend copies the last point (`:16029`), the carry-on copies the tip
  (`:17517`).
- **Obstacles:** `junctionObstacleHitsAlong`, `FlyoverEditor.lua:14073` (`overlapBox`, mask DEFAULT +
  STATIC_OBJECT + DYNAMIC_OBJECT + TREE + BUILDING); callback at `:14037`. The log writes one line per
  object name and 4 m spot (`:14118`), so log counts are spots, not objects. Type: `getSplitType`
  (tree), `getRigidBodyType` (1 fixed, 2 knock-over), `getCollisionFilterGroup`, `getName`/`getParent`
  walking up as MapObjectsHider does (`EntityUtility.lua:40-61`). Bits: `shared/collisionMaskFlags.xml`
  (ROAD is bit 13). Names: `fence`, `ropeFence`, `fenceGeneration*`, `mailDropBox`, `streetLight*`.
- **Solid road pieces:** 17 shapes in `mapUS.i3d` have the ROAD bit; `infrastucture.i3d` adds 14
  (bridge decks, `freeway05`, `mainRoadSecondaryNew15`), `railroadCrossings.i3d` 19, about 20 other
  referenced files 1 or 2 each. Plain road meshes are `terrainDecal="true"`, no collision.
- **Field, farmland, stacked surfaces, placed objects:** `FSDensityMapUtil.getFieldDataAtWorldPosition`
  (`FieldLoopGenerator.lua:80`); `g_farmlandManager:getFarmlandAtWorldPosition`; `columnSurfaces`
  (`FlyoverEditor.lua:9133`) or `raycastAll`; `g_currentMission.placeableSystem.placeables`, offline
  `savegame6/placeables.xml` lines 2475-2476: a T at (-741.6, 262.3), a crossroads at (-783.1, 267.6).
- **Offline files:** `data/maps/mapUS/data/masks/GEN_roads.png` (also `GEN_paths`, `GEN_roadsBorders`,
  `GEN_slopeMask`). Paint pictures `data/maps/mapUS/data/*_weight.png`: match a layer's `weightMapId` to
  a `<File fileId>`; `mudGravel01/02` use `gravel01/02_weight.png`, `gravel01/02` use
  `asphaltGravel01/02_weight.png`, `concreteDirt01/02` use `asphaltDirt01/02_weight.png`. In game maybe
  `loadBitVectorMapFromFile` (`FarmlandManager.lua:93-94`, untested). Main paint per metre:
  `savegame6/terrain.lod.type.cache` (12-byte header, then 2048 x 2048 x 2 bytes; the even byte is the
  layer index); the map's own `mapUS.i3d.terrain.lod.type.cache` differs at 13,848 cells. All 1 m,
  pixel = x + 1024, north is small z.
- **Research files** (session scratchpad `ds/`, temporary): `research3.json` (our code, past findings,
  first pass), `game_api_report.md` (game survey), `new_ideas_report2.md` (measured pass), `netvsmap.py`
  (network against map lines). Scripts and pictures in `pave/`, `srcprobe/`, `src/` and `chk03/` (mask
  cover near road lines) beside it. The mod maps are unpacked in `ds/`. Game log:
  `logs/log_2026-09-27_15-41-28.txt`. Map files are under the game install; `savegame6` is our test
  save.


## Where the research disagreed

We took the measured answer each time.

- **Painted masks:** early, a clean pavement map; measured, half the paved ground (the rest is yards
  and tracks), 0.5 to 1 m outside the asphalt. Early put the asphalt 1.5 m inside the mask.
- **Flat areas at junctions:** early, yes; measured, none as a rule.
- **How level roads are:** early, 1 to 2 cm; measured, 5 mm.
- **Signs:** early, a stop or yield sign within 12 m at 63 of 73; measured, a stop sign within 35 m at
  65 of 75 (used here). Their place in the map file: the game survey was wrong, the first pass right.
- **AutoDrive junction pieces:** one pass found none; the save holds two (checked).
- **Mailboxes:** one pass found none by name; another found 7.
- **Road surface hits** in one log: we think bridges or railroad crossings; the log gives no place.
- **The drive-cost file:** early, unreadable; two later passes read it.


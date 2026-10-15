# What the tool can read

*Draft 2, 2026-09-30. Working notes for us.*

The clear must hand the builder a centre, stubs that reach the other road's pavement, and the shape of
each mouth ([What the builder needs](02-what-the-builder-needs.md)). Then it grades its own fit, in game,
on any map, and asks you only when no fit passes.

Decided 2026-09-30: **the centre is roughly the middle of the paved overlap.**

So the tool must know where the pavement is and what stands on it. This page lists every place it could
look. The next page builds the fit methods and the grade on it.

Numbers are for Riverbend Springs and our test save, by card number. "We think" and "untested" mark
guesses. Three words used below:

- **Drive cost:** the game's number for how hard a surface is to drive. Lower is easier.
- **Sound type:** the game's surface class for tyre sounds: asphalt, gravel, dirt, grass or sand.
- **Painted masks:** two maps the map maker paints by hand, "no tipping" and "no building". Here they
  are painted mostly over roads.

## The big finds

- **Roads here have nothing solid to hit.** Plain road surfaces are decoration only. The solid road
  pieces are bridges, railroad crossings and a few others (about 70 once the map's referenced files are
  counted). So our "is this road" check falls back to the paint, and reads rock as road (see Bugs).
- **Every ground paint carries a drive cost.** Colour splits asphalt from rock and concrete. Only the
  drive cost splits concrete from rock.
- **The game keeps a 1 m drive-cost map** for its AI workers. Only the host has it. It is built from the
  paint, so it matches the paint. It adds slope, blocked spots, and concrete told apart from rock.
- **Road signs mark junctions.** On your labelled T's, a stop sign stands on the side road's half at 35
  of 41. The two-way arrow board stands opposite at 29 of 31.
- **The map maker grouped the turn lines at 61 of 75 junctions.** But our centre already comes from
  these lines, so they can't check it.

## What we read today

- **The clear reads almost nothing from the world:** AutoDrive's lanes and directions, named
  destinations (in one step), and ground height when it evens out lane spacing. New stub points copy
  their neighbours' heights; none is read from the ground.
- **The builder tests each turn, spot by spot:** a road surface under it, or else the paint's sound
  type; anything solid in the way. Every hit refuses the same way.
- **The map's road lines** are only written to a file on request, for our offline tests.
- **Nothing reads** slope, the drive-cost map, signs, the painted masks or placed objects.
- **Our offline tests** see road everywhere and no obstacles.

## Sources for the in-game grade

"Other maps" are the three mod maps installed here (see Still open 6).

| Source | Tells us | Other maps, and multiplayer |
|---|---|---|
| Ground paint | Pavement, shoulder, dirt, grass or rock; the edge; the mouth's shape. | Same paint settings on all three. Every player (we think). |
| Drive-cost map | Cost per metre, steep ground, blocked spots. | Any map. Host only. |
| Road signs | The side road, the mouth, the kind; an outer limit for the edge. | Only Alma has signs by the Giants names. Every player (we think). |
| Painted masks | A hand-drawn "road here"; an outer limit. | Blank or almost blank on all three. Probably every player (untested). |
| Ground slope | Which way a road runs; banks; stub heights. | Any map. Every player (we think). |
| Map road lines and groups | The kind, splits, where the map's turns start. | Only Alma has groups, named a little differently. The game's list is host only; every player may read the lines from the map (untested). |
| Obstacle test, with type | What stands in a turn, and what it is. | Any map; names vary. Every player (we think). |
| AutoDrive lanes | Lanes, direction, width from the gap between lanes (not on single-lane or two-way roads). | Any map. Every player. |

### Ground paint and its drive cost

One quick lookup gives a spot's paint colour, whether it is hard or soft, and its sound type. Not its
drive cost.

| Paint | Hard or soft | Sounds like | Drive cost |
|---|---|---|---|
| Asphalt | hard | asphalt | 4 |
| Concrete | hard | asphalt | 4 |
| Rock | hard | asphalt | 12 |
| Gravel | hard | gravel | 6 or 8 |
| Mud and dirt | soft | dirt | 6 |
| Grass | soft | grass | 8 |
| Sand | soft | sand | 12 |

- Asphalt is much darker than any other paint, so the map's paint table gives its drive cost. Concrete
  and rock share colour, hardness and sound; only the host's drive-cost map splits them.
- A brown dirt or gravel shoulder runs round every paved road we plotted. It marks the edge.
- Fields are painted with dark mud underneath (about 37% of the map), so dirt tracks and fields look
  alike.
- The game's own "is this road" rule for wheels takes any hard paint, rock included. We can't borrow it.
- Players (landscaping) and placed objects can change the paint. The two AutoDrive add-on junction
  pieces in this save paint asphalt. The painted masks don't follow either.

**The drive-cost map** copies each paint's drive cost per metre, adds extra cost on slopes and near
obstacles, and marks blocked spots. So its edge matching the paint (98% within half a metre) is
expected, not a second opinion. Its lowest-cost part also takes in yards and concrete: 70% road, 8%
paths, 21% elsewhere.

### The map's road lines and junction groups

- The turn lines sit in 105 groups. Six lines is usually a T and twelve a crossroads. Other sizes (1, 2,
  3, 4, 13) are not matched to a kind yet; 26's two T parts have 4 lines each.
- No group at 4, 24, 25, 31, 54 and most of 65 to 75 (we think hand-made or farm roads).
- Groups close together mean a split junction. They match your splits at 14, 20, 26 and 39. They miss
  40, 72 and 73, and suggest a split at 2 that you haven't decided.
- Where the map's turns leave each lane is a natural place for the builder to trim a stub back to. The
  inner curve traces the paved corner. (Both untested.)
- **Not independent.** Our centre equals the group's centre to 0.0 m at 46 junctions, and 95% of
  AutoDrive's points lie within 0.3 m of a map line. Agreement proves nothing.
- **Misread kinds:** an arm missing or short at 25, 53, 63, 66 and 69; a Corner T unseen at 24 and 31;
  the next junction inside the circle at 2, 14, 20 and 40.
- **Other groups name the road:** dirt track, field track, one-way or two-way. That could tell a dirt
  track from a road (untested).
- **Who made each road:** 651 of 12,873 AutoDrive points lie more than 0.3 m from any map line, so a
  player or our tool added them. The 0.3 m line is not checked against your labels.
- Our file of the lines drops each line's group and height. Keeping both is a small change.

### Road signs

- 170 stop signs, 6 yield signs, 84 two-way arrow boards. Warning signs 20 to 250 m out name the kind:
  crossroads, side road left or right, offset crossroads, two side roads, merge, Y.
- A stop sign within 35 m at 65 of 75 junctions, usually 6 to 9 m from the centre. None at 4, 25, 31,
  53, 65, 69, 74 or 75 (67 and 68 are test sites). Wrong-side signs are mostly at split junctions (14,
  20) or on a corner.
- Stop signs stand about 2 m outside the asphalt (1.4 to 2.8 m): they limit the edge, not place it. The
  halfway point between a stop sign and its arrow board sits about 3 m off the centre.
- Farm-vehicle crossing signs (15) mark field entrances, not junctions.

### The painted masks

- On a road, a solid band a little wider than the paint, 7 to 10 m across. The edge sits typically 0.5
  to 1 m outside the paint, with a wide spread. They carry on across a mouth with no gap.
- They cover about half of all paved ground: about 85% within 5 m of the map's road lines, but little of
  the yards, concrete and tracks away from them (checked 2026-09-30). They cover about 1% of grass.
- Missing at 6 to 7% of places across a road, and at 70, 71 and 75 (farm tracks and paths).
- Best use: a hand-drawn "this is road" label and an outer limit. Not sharper than the paint.

### Ground slope (your idea)

- **Good for road direction.** Roads are level side to side, within 5 mm. Downhill runs along the road at
  62% of sloped road spots, against 8% off the road. So slope says "a road runs this way", even with no
  lanes. Also good for banks, cuttings and stub heights.
- **Poor for the edge.** The levelled ground runs about 1 m past the paint; only a quarter of edges come
  within 1 m.
- **Poor on flat land.** The level strip is 1 to 32 m wide (typically 11.6 m), against 7 to 10 m of
  painted mask.
- **No flat area at junctions** as a rule; slope at the centre runs 0 to 12%. **Bridges:** slope reads
  the ground, not the deck.

### Obstacles and their type

Your decision: signs count, with their own on/off setting. Trees, fences and mailboxes stop a vehicle or
catch a trailer.

- The builder's obstacle test looks 0.6 to 2.8 m above the ground and skips vehicles, bales and pallets.
  No kerbs here, but on other maps it would miss kerbs and low walls.
- It already hits signs but never reads what they are. One day's log has knock-over objects (most
  likely signs) at 47 spots, fixed objects at 24 and trees at 2. Names are mostly generic, so the type
  has to come from how the object behaves.

| Type | How to tell | On this map |
|---|---|---|
| Sign | knocks over; its name is on a part above it | 765 signs |
| Tree | can be cut | many |
| Fence | fence names and settings | 161 fence lines |
| Building | marked as a building | - |
| Mailbox | name only | 7 |
| Street light, pole | name only | 412 lights; one within 10 m at 46 of 75 junctions |
| Other fixed object | fixed, not a building: billboards, railroad barriers and the like | 24 spots in one day's log |

- A tree canopy over the road may give a false hit (suspected).
- Objects hidden with a hiding mod are skipped by a test run in game, not by a list read from the map.
- The drive-cost map marks fixed objects map-wide, but not signs (checked at all 170 stop signs). The
  game's maps of where tipping and building are blocked hold fixed objects too; whether they mark signs
  is unknown.

### Other clues

- **Field ground.** A field is never pavement. A field beside a mouth marks an entrance. The paved area
  in front of an entrance is probably not field (guess).
- **Farmland.** 82% of asphalt is not buyable land, against 35 to 38% of grass.
- **Placed objects.** Player buildings, and junction pieces from an AutoDrive add-on mod (this save has
  two). They give an exact centre, kind and lane width.
- **Surfaces stacked at one spot:** a bridge deck and the road under it. The Ground tool reads this.
- **Loose pieces.** A piece under 20 m end to end is a scrap and must not count as a road.
- **Painted area in one call.** The game can count the painted metres inside any shape in one call:
  fits a grade like "how much of this corridor is paved" (untested by us).
- **Our own record of what we laid.** Not built. The cheapest way to know a junction is ours.

### A centre trial, for the next page

Your decision puts the centre in the middle of the paved overlap. One way to find it: the spot on
pavement farthest from any edge (the largest circle that fits). It landed within 2 m of today's centre at
45 of 72 junctions, but wanders into paved yards and wide paved mouths (10, 22, 29, 46).

## Offline only

**Answer keys** (truth to check the tool against):

- **The map generator's road masks:** crisp 1 m roads and paths. Base maps only, not loaded by the game,
  and can be stale (at 66 the paint shows a side track the mask lacks).
- **Your answers:** kind, main road and splits.
- **Another save on this map:** shares only 63% of its points with ours.
- **No answer key yet** for centres, stub ends or obstacles. For pavement, only the generator masks, on
  base maps.

**Offline copies of what the tool reads in game:**

- **Paint-strength pictures,** one per paint, 1 m. Every map ships them, mod maps included; the tool
  might load them in game (untested). Match each to its paint through the map file, not by file name:
  six are named after a different paint.
- **The save's file of the main paint per metre.** 78% of road-line points land on asphalt or concrete.
  Use the save's copy, not the map's own; they differ at about 13,800 metres.
- **The save's copies** of the drive-cost map, height map, painted masks and blocked-area maps. The
  height map matches AutoDrive's heights to 0.4 mm.
- **Signs and junction groups** from the map's main file (about 20 s).

## We think these are low value

You asked for every source. We would drop these; please confirm.

- Road surface objects (not solid here), the overview map picture (roads drawn 10 to 20 m off), the
  map's height before shaping (broad shaping only).
- Speed limits (87 on 1,060 of 1,084 lines), AI traffic cars (same lines), tyre tracks (they fade).
- AutoDrive's point spacing (marks turns, lost after edits), where grass doesn't grow (repeats the
  paint), road markings (towns only).
- Street lights and poles as markers (beside the road; still obstacles).
- The game's road-line obstacle check (developer console, host only, follows the lines).
- **AutoDrive's "made from the map" mark:** on 12,319 of 12,873 points. An old bug of ours copied it
  onto about 5,300, so here it can't tell who made a road. It should work on saves our old versions
  never touched.

Left for the grade page: **a test drive.** It checks a built junction in game, and it is the calibration
the truck and trailer test still lacks.

## Bugs found on the way

1. **"Is this road" counted rock as road. Fixed 2026-09-30, not yet tried in game.** The builder's
   check falls back to the paint's sound type, and every rock paint has the asphalt sound. Fields have
   the dirt sound, because of the dark mud painted under them. Now:
   - a spot on a field is never road;
   - an asphalt-sound spot is road only if the game's drive-cost map reads it under 150. Asphalt and
     concrete read about 51; rock reads 186 or more.

   Without the drive-cost map (it is host only), rock still counts as road, as before.
2. **Anything solid over a spot makes it "not road".** A sign arm or a tree canopy can do it. Flagged,
   not fixed.

## Decided 2026-09-30

1. **The pavement edge is the asphalt edge:** where the dark road paint ends. Stubs reach in to it.
2. **Multiplayer: later.**
3. **Maps with fewer sources get the same pass mark.** Paint, slope and lanes are on every map. Signs
   and junction groups only add confidence where a map has them.
4. **The map's junction groups:** a vote for the kind and for splits, and where their turns start is a
   hint for trimming stubs. Never the only vote.
5. **The rock-as-road bug: fix it now.**
6. **First other map to try: Alma, Missouri.**
7. **Cones and anything else that knocks over share the signs' on/off setting.**
8. **Add a low obstacle test** for kerbs and low walls.

## Sources

- [Data sources: reference](03b-data-sources-reference.md): how to read each source, research files, and where the research disagreed

- [Why a clear tool](01-why-a-clear-tool.md) and [What the builder needs](02-what-the-builder-needs.md)
- Research of 2026-09-30: three reports and two measured passes (files in How to read it)
- Game log of 2026-09-27 (obstacle hits, paint types)
- Our test save, the Riverbend Springs map files, and the mod maps Alma, Welker and Genesee
- scripts/editor/FlyoverEditor.lua

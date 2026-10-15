# XT junction study

Scripts behind `docs/junction-tool/05-placeable-junctions.md`. They study Willi Willswissen's
FS25_AutoDrive_XT_Intersection pieces. Nothing here loads in game. Python 3 and Lua 5.1, as in
`tools/junction-harness`.

    python decode.py <unzipped mod folder>                  # every node and link of the 8 pieces
    python legal.py                                         # routes AutoDrive allows (80-degree rule)
    python layout_svg.py ../../docs/junction-tool/05-img    # the T and X layout pictures
    python placed.py "<profile>/savegame6/AutoDrive_config.xml"   # how the two placed pieces are wired
    lua drive.lua ../../scripts/editor <out folder>         # drive the truck+semi through every move

    lua curves.lua ../../scripts/editor <out folder>        # builder-style arcs vs the mod's corners

`curves.lua` writes `curves_results.txt` and four `curve-*.svg` pictures (6 m lanes). Its last
section re-runs the speed cases with the twin's own bend scan (AutoDrive's: 20 m x mass x speed factor,
up to 20 points), then with fixed 20, 50 and 100 m windows to bracket it. The first twin used a bare
20 m, a transcription shortcut rather than AutoDrive 3.0.0.8's behaviour. It was corrected in a008a46.
    lua splitdist.lua ../../scripts/editor                  # how far back a two-way road must split

    lua throughdist.lua ../../scripts/editor                # one-way lanes: stopping vs speed and spacing

    lua twowidth.lua ../../scripts/editor                   # side-road width for two trucks at the mouth

    lua overlap.lua ../../scripts/editor                    # two close junctions: guarded lanes vs two-way
    lua splitpair.lua ../../scripts/editor                  # one junction: narrow split vs two-way to the mouth

`overlap.lua` and `splitpair.lua` replay the check for TWO trucks at once (straight-line motion with the
twin's truck numbers). `ONE="D s mid delay" lua overlap.lua ...` traces a single run.
`splitdist.lua` replays AutoDrive's "who waits" check on the twin's track and prints where the truck's
front stops, for each split distance, point spacing and braking strength.
`drive.lua` writes `drive_results.txt`, `drive.html` (every panel) and one `panel_*.svg` per move.
The doc's drive pictures are copies of three of those panels.

## Traffic through a whole junction (2026-10-07)

`adtraffic.lua` is a small 2-D traffic sim: trucks follow their routes through a network, with
AutoDrive 3.0.1.4's "who waits" check replayed line for line (CollisionDetectionModule.lua 88-195) and
its bumper box, and every run ends ok, MEET (two bodies overlap) or STUCK (everyone stopped for good).
Routes come from AutoDrive's own rules (80 degree rule, drive-time cost).

    lua farmtrack.lua ../../scripts/editor [small|big|semi] [kmh] [turn radius]   # a T of single-track roads
    python synthjunction.py T|X <net.lua>                                        # a clean two-lane T or X
    (in ../junction-harness) GRAPH=<net.lua> [WIREFIRST=1] [PATTERN=exact|smooth] lua simexport.lua 0 0 place|build <out.lua>
    STEP=2 lua junctionsim.lua ../../scripts/editor <out.lua> [rig] [kmh] [variant]

`junctionsim.lua` runs two trucks through every pair of movements at start offsets -10..+10 s and both
check orders. Variants: `as laid`, `main two-way R`, `box two-way R`, `spaced` (junction points at
least 3.5 m apart), combinable.

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

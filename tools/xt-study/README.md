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
section re-runs the speed cases with 20, 50 and 100 m bend-scan windows. SweptSim's fixed 20 m comes from
AutoDrive 3.0.0.8. 3.0.1.2 scans further, so use the 50/100 m rows for speed.
    lua splitdist.lua ../../scripts/editor                  # how far back a two-way road must split

    lua throughdist.lua ../../scripts/editor                # one-way lanes: stopping vs speed and spacing

    lua twowidth.lua ../../scripts/editor                   # side-road width for two trucks at the mouth

`splitdist.lua` replays AutoDrive's "who waits" check on the twin's track and prints where the truck's
front stops, for each split distance, point spacing and braking strength.
`drive.lua` writes `drive_results.txt`, `drive.html` (every panel) and one `panel_*.svg` per move.
The doc's drive pictures are copies of three of those panels.

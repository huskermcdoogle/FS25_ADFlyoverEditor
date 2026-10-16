# Multiplayer probe

Step 0 of `docs/multiplayer-beta-plan.md`. Results: `docs/multiplayer-probe-results.md`.
Nothing here ships (`tools/` is not in the mod zip).

## Offline (Lua 5.1, Python 3)

Get AutoDrive's real graph code out of the installed zip into a scratch folder (not this repo):

    unzip <mods>/FS25_AutoDrive.zip scripts/Manager/GraphManager.lua -d <scratch>/ad

Export a network with both link lists (the junction harness exporter drops incoming):

    python export_full.py "<profile>/savegame2/AutoDrive_config.xml" <scratch>/sg2_full.lua

Then:

    lua tag_survival.lua <scratch>/ad/scripts/Manager/GraphManager.lua <scratch>/sg2_full.lua 5000 7
    lua size_estimate.lua <scratch>/sg2_full.lua 2048

`tag_survival` exits 1 on any failure.

## In game: FS25_MPProbe

    python build_probe.py

Copy `FS25_MPProbe.zip` into the mods folder of **both** peers with the game closed. Start a
multiplayer game with the mod on (it needs nothing else), join it as a client, open the console and run
`mpProbe all`. Then read `[MPProbe]` and `[AutoDriveSync] Written` in both logs.

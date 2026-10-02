# Swept-path replay

Checks SweptSim, the twin of AutoDrive's driver, against a run the truck really drove.
Nothing here ships (`tools/` is not in the mod zip). Lua 5.1.

    lua replay.lua ../../scripts/editor/SweptSim.lua "<profile>/modSettings/FS25_ADFlyoverEditor/swept/clean90.xml" 40

Record a run in game with `FlyoverSweptRecord`, drive it with AutoDrive, `FlyoverSweptSave name`.
The last argument is AutoDrive's speed setting for that drive. The rig is the preset
(`SweptSim.EXAMPLE_RIG`, the Transtar II + SKS 30/1050 the September recordings were made with).

The line the truck followed is rebuilt from the recording itself (each sample stores the
current waypoint's position), so no saved network is needed. The run is cut at every stop.
Each piece is driven by the twin from the recorded start, and the twin is read back at the
same distance along the line. Per corner it prints the slowest speed, recorded and twin, and
how far the rear axle went inside and outside the line.

Variants test a change without editing SweptSim: `scan=20` (the first twin's fixed bend scan),
`mass=12`, `decel=5`, `accel=2`, `slew=4`, `steerlimit=45`. Recordings made before the recorder
stored waypoint positions (`trucktrail.xml`) cannot be replayed.

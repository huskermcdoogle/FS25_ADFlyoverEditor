# Flyover Editor — Multiplayer BETA: tester guide

Thank you for helping. This BETA lets several players use the flyover editor **at the same time** in one
game. It is new and has only been tested on one PC so far, so expect rough edges. Your logs are what
make it better.

## Before you start

- **Everyone needs the exact same zip** — the host and every player. It is not on ModHub, so the game
  will not hand it out. Download it from the GitHub pre-release, put it in your `mods` folder, and
  **remove any other copy** of `FS25_ADFlyoverEditor` (the normal release included).
- You also need **FS25_AutoDrive** (same version on every PC).
- **Hosted games only for now.** One of you hosts from the game. A rented/dedicated server is not
  supported yet.
- Copy the zip in only while the game is **closed**.

## What to try

The editor shows a small test card. Each of you runs it on your own PC; most lines tick themselves.

1. Host a game with the mod on; the other player joins.
2. Both open the editor (Left Alt + V). Wait a moment after joining: the player's PC first loads the
   route network from the host.
3. One of you moves or adds points. The other should see it within a second.
4. Both edit the **same** few points at the same moment. One edit goes through; the other gets
   "*Not applied: … — <name> is working there.*"
5. You move a point, the other moves it again, then **you** press undo. Your undo skips that move and
   says "*<name> changed that spot*". When they undo theirs, yours works again.

Undo only ever takes back **your own** edits.

## Known limits in this BETA

- If someone **records a route with AutoDrive itself** (in a vehicle) while others use the editor, the
  other players' editors reload the network a few seconds later. Edits they had not had confirmed yet at
  that moment can be lost (they are told).
- The **junction tool's** numbers are kept per PC, not shared.
- No zone tints or name legend on screen yet; you only learn about a busy spot when an edit is refused.
- Dedicated servers: not yet.

## When something goes wrong — what to send

Open an issue on GitHub with the **MP BETA** form and attach:

- `log.txt` from **every** PC (host and players):
  `Documents/My Games/FarmingSimulator2025/log.txt` — copy it **before** starting the game again
  (the game overwrites it).
- `testresults.xml` from each PC:
  `Documents/My Games/FarmingSimulator2025/modSettings/FS25_ADFlyoverEditor/testresults.xml`
- What you did, roughly when, and who was where.

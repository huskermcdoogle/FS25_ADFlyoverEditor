# Flyover Editor — Multiplayer BETA: tester guide

Thank you for helping! This BETA lets several players use the flyover editor **at the same time** in one
game. It is new and has only been tested on one PC so far, so expect rough edges. Your logs are what
make it better.

About 20 minutes for two people. You need **at least two players**: one hosts, the other joins.

---

## 1. Before you start (everyone)

1. **Back up your savegame.** Copy the savegame folder you will play on
   (`Documents/My Games/FarmingSimulator2025/savegameN`) somewhere safe. This is a beta that changes the
   AutoDrive route network on every PC; a copy means nothing can be lost. Better still: test on a spare
   savegame.
2. **Close the game.** Only add or remove mods while FS25 is closed.
3. **Download the zip** from the BETA release page:
   https://github.com/huskermcdoogle/FS25_ADFlyoverEditor/releases (the one marked *Pre-release*,
   "1.0.4.0 MP BETA").
4. **The file must be called exactly `FS25_ADFlyoverEditor.zip`.** If your browser saved it as
   `FS25_ADFlyoverEditor (1).zip` or similar, rename it. Do not unpack it.
5. **Put it in your mods folder** and **remove any other copy** of `FS25_ADFlyoverEditor` there (the
   normal release too). The mods folder is
   `Documents/My Games/FarmingSimulator2025/mods` - on many PCs that is under OneDrive:
   `OneDrive/Documents/My Games/FarmingSimulator2025/mods`.
6. **AutoDrive 3.0.1.4** (`FS25_AutoDrive.zip`) must be in everyone's mods folder - the same version on
   every PC.

The game checks that everyone has the same mods. If joining fails with a "missing mod" or "different
version" message, someone has a different zip - compare file names and sizes.

## 2. Start the game

1. **Host:** start a multiplayer game ("Host game" / self-hosted). Tick **AutoDrive** and
   **Flyover Editor for AutoDrive (MP BETA)** in the mod list. Dedicated or rented servers are **not**
   supported yet - host from the game.
2. **Player:** join the host's game.
3. **Turn on verbose logging** (both of you, once): open the editor with **Left Alt + V**, click the
   **gear** at the right of the tool panel's header, find **DEBUG → verbose logging**, set it **on**.
   This makes your log much more useful to us.
4. **Player only:** after joining, your PC first loads the route network from the host. If you press
   Left Alt + V too early you will see *"Loading the route network from the host - try again in a
   moment."* When it is ready you see *"Route network loaded from the host - the flyover editor is
   ready."*

## 3. The test card

While the editor is open, a small **test card** shows a list of checks. Each of you has your own card.

- Some lines **tick themselves** when they see the right thing happen.
- The others you mark yourself: click **pass**, **fail** or **skip** next to the line.
- Your ticks are saved on your PC (see section 6).

## 4. What to try

Do these in order. Talk to each other (voice chat helps a lot).

1. **Started:** the card's "Multiplayer side started" ticks itself on both PCs.
2. **Edits travel:** one of you moves or adds a few points. The other should see them within about a
   second. Swap and do it the other way. Mark the line pass or fail.
3. **Same spot:** both drag points **in the same small area at the same time**, for a few seconds. Some
   edits go through; the other player gets *"Not applied: … - <name> is working there."* (it ticks
   itself). It can take a couple of tries to hit the same moment.
4. **Undo after the other changed your spot:** you move a point. The other player moves **the same
   point** again. Now **you** press undo (**Q** in the editor; redo is **E**). Your undo skips that move
   and says *"Skipped 1: <name> changed that spot"* (it ticks itself). Then the other player undoes
   their move - and now your undo works.
5. **Play normally** for a while: lay a spline, a field loop, clear a junction, name a point. Watch for
   anything odd on the other PC.

Undo only ever takes back **your own** edits.

## 5. Known limits in this BETA

- If someone **records a route with AutoDrive itself** (driving a vehicle) while others use the editor,
  the other players' editors reload the network a few seconds later. Edits not yet confirmed at that
  moment can be lost (you are told).
- The **junction tool's** numbers are kept per PC, not shared.
- No colour tint or name list on screen yet for where others are working; you only find out when an
  edit is refused.
- Dedicated / rented servers: not yet.

## 6. What to send us

Open an issue at https://github.com/huskermcdoogle/FS25_ADFlyoverEditor/issues with a title starting
**[MP BETA]** - even if everything worked. Attach, **from every PC (host and players)**:

- **The log.** `Documents/My Games/FarmingSimulator2025/log.txt` is the current game's log. The game
  overwrites it on the next start, but keeps older ones in the `logs` folder beside it
  (`log_<date>_<time>.txt`) - pick the one from your test session.
- **The test card results:**
  `Documents/My Games/FarmingSimulator2025/modSettings/FS25_ADFlyoverEditor/testresults.xml`
- In words: what you did, roughly when, who was host, and anything that looked wrong.

## 7. Going back to normal

Close the game, remove the BETA `FS25_ADFlyoverEditor.zip` from your mods folder, and put the normal
release back (the release marked *Latest* on the releases page). If anything looks wrong in your routes,
put your savegame backup back.

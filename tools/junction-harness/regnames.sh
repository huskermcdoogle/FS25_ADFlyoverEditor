# THE NAMES OF SPLIT JUNCTIONS' PARTS, against a fixed answer key - the user's decisions in
# split_decisions.txt, put into a junction file by split_registry.lua and read by the editor as the
# game reads it (REGDIR). Nothing is written outside regnames_out/ (OUT= puts it elsewhere), and the
# savegame's file is only read.
#   GRAPH=<network .lua> REG=<ADFlyoverEditor_junctions.xml> bash regnames.sh
# Prints ok / FAIL per case and the total; exits 1 on any FAIL. The cases:
# - every part the user named names itself when locked; cleared 72 and 73, whose halves share one
#   middle, read as the bare number with what the lock covers (picking a half is a later step)
# - the junctions kept whole stay the bare number
# - a part gone: 39se cleared, then 39 and 39nw still read j39 and j39nw (not j39e / j39w by the
#   two-part rule), and the cleared 39se is not handed a new number
# - a part moved: 3 m from where it was saved it is still j39se; 6 m off, the lock is "not at one
#   of j39's parts"
# - a part claims only what is near it: the Y beside 39se that belongs to 30 stays j30
# - a cleared part covers a neighbour only when a click on the neighbour locks the same cleared
#   site: never a part still wired (20n), however near; 26n, whose wiring went with 26s's clear,
#   within the 15 m a cleared site is read out to
# - the decision buttons are on the card only once a click has locked the junction
# - a decision made before the career was ever saved is written by the game's first save
# - ...but only into that career's folder: another game loaded first (or the folder changed under
#   it), and what was waiting is dropped - the other career's file is left byte for byte as it was
# - "keep whole" and "not decided" keep the parts' names (set aside, in the file), and "split" then
#   brings back exactly those names at exactly those places - also after a restart; only "forget
#   these names" lets them go, and only then does a split take the card's fresh letters
# - the file: written, read and written again, comes out the same; the savegame's own file read
#   and written comes out byte for byte as it was
# - split_registry.lua refuses what it must, and the reader leaves out what is not whole
export RIG_TRAILER="${RIG_TRAILER:-11}"
L="${LUA:-/c/Program Files (x86)/Lua/5.1/lua.exe}"
REG="${REG:-$HOME/OneDrive/Documents/My Games/FarmingSimulator2025/savegame6/ADFlyoverEditor_junctions.xml}"
OUT="${OUT:-regnames_out}"
# What the last run left, not the folders themselves: a synced folder (Dropbox) can hold on to a
# folder, or a file it is still uploading, and refuse to let it go for a while.
mkdir -p "$OUT/A" "$OUT/save" "$OUT/first/savegame7" "$OUT/switch/A" "$OUT/switch/B" "$OUT/switch/C" "$OUT/decide"
rm -f "$OUT/A/"* "$OUT/save/"* "$OUT/first/"*.xml "$OUT/first/savegame7/"* "$OUT/switch/A/"* "$OUT/switch/B/"* \
  "$OUT/switch/C/"* "$OUT/decide/"* "$OUT"/*.xml "$OUT/dec.txt" 2>/dev/null
pass=0
fails=0
check() {   # what, expected, actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf "ok    %-34s %s\n" "$1" "$3"
  else
    fails=$((fails + 1)); printf "FAIL  %-34s expected [%s] got [%s]\n" "$1" "$2" "$3"
  fi
}

# The decisions into a copy of the savegame's numbers.
"$L" split_registry.lua "$REG" split_decisions.txt "$OUT/A/ADFlyoverEditor_junctions.xml" >/dev/null ||
  { echo "split_registry.lua failed"; exit 1; }
export REGDIR="$OUT/A"

# Every part the user named, where the roads meet there, and the name it must read as.
while read -r part x z want; do
  got=$("$L" regnames.lua lock "$x" "$z" </dev/null 2>&1 | grep "^NAME" | sed 's/^NAME //')
  check "part $part ($x, $z)" "$want" "$got"
done <<'KEY'
20n  -947.1   32.4 j20n
20s  -947.0   46.0 j20s
72w  -860.3  445.7 j72 | covers j72w and j72e
72e  -849.5  445.9 j72 | covers j72w and j72e
73nw -757.4  481.1 j73 | covers j73nw and j73se
73se -749.4  489.9 j73 | covers j73nw and j73se
26n  -933.0  481.4 j26n
26s  -933.8  493.3 j26s
14nw -816.2   42.1 j14nw
14se -806.0   60.8 j14se
39      6.9  -13.6 j39
39se   22.5    0.1 j39se
39nw  -15.0  -24.5 j39nw
40w   -71.7  -47.8 j40w
40e   -51.8  -42.5 j40e
KEY

# Kept whole: locked at the junction's own point, the bare number.
for n in 24 30 31 35 36 70 71 74 75; do
  xz=$(grep -oE "n=\"$n\" x=\"-?[0-9.]+\" z=\"-?[0-9.]+\"" "$OUT/A/ADFlyoverEditor_junctions.xml" | sed -E 's/.*x="([^"]+)" z="([^"]+)"/\1 \2/')
  got=$("$L" regnames.lua lock $xz </dev/null 2>&1 | grep "^NAME" | sed 's/^NAME //')
  check "kept whole j$n" "$(printf 'j%02d' $n)" "$got"
done

# A part gone.
o=$("$L" regnames.lua gone </dev/null 2>&1)
check "gone: the part cleared" "j39se" "$(echo "$o" | grep '^NAME cleared' | sed 's/^NAME cleared //')"
check "gone: then 39" "j39" "$(echo "$o" | grep '^NAME 39 ' | sed 's/^NAME 39 //')"
check "gone: then 39nw" "j39nw" "$(echo "$o" | grep '^NAME 39nw ' | sed 's/^NAME 39nw //')"
check "gone: no new number" "0 75" "$(echo "$o" | grep -c '^NEW') $(echo "$o" | grep '^MAXN' | sed 's/^MAXN //')"
check "gone: no Lua error" "0" "$(echo "$o" | grep -ciE 'attempt to|stack traceback|failed:')"
# ...and the check after the clear: with 39nw gone, 39se's check names what is left at 39 "j39".
o=$("$L" regnames.lua gonecheck </dev/null 2>&1)
check "gone: check of 39nw" "CHECK j39nw (j39nw) parts: j39" "$(echo "$o" | grep '^CHECK j39nw')"
check "gone: then check of 39se" "CHECK j39se (j39se) parts: j39, j39" "$(echo "$o" | grep '^CHECK j39se')"

# A part moved.
check "moved 3 m" "j39se" "$("$L" regnames.lua moved 3 </dev/null 2>&1 | grep '^NAME' | sed 's/^NAME //')"
check "moved 6 m" "j39 | not at one of j39's parts" "$("$L" regnames.lua moved 6 </dev/null 2>&1 | grep '^NAME' | sed 's/^NAME //')"

# A part claims only what is near it: the Y 13.7 m from 39se, 21 m from 30's own point, is 30's
# (the user's j30.1). Counting 39se's part out to 30 m, it was called j39 and offered 39's buttons.
check "the Y beside 39se is 30's" "j30" "$("$L" regnames.lua lock 45.6 0.8 </dev/null 2>&1 | grep '^NAME' | sed 's/^NAME //')"

# A cleared part and its neighbour (DIST: how far the neighbour's saved point is from the lock).
o=$("$L" regnames.lua near 0 </dev/null 2>&1)
check "cleared 20s, 20n wired" "j20s 16.79" "$(echo "$o" | grep '^NAME' | sed 's/^NAME //') $(echo "$o" | grep '^DIST' | sed 's/^DIST //')"
o=$("$L" regnames.lua near 3 </dev/null 2>&1)
check "cleared 20s, wired 20n inside 15 m" "j20s 13.79" "$(echo "$o" | grep '^NAME' | sed 's/^NAME //') $(echo "$o" | grep '^DIST' | sed 's/^DIST //')"
# Since 2026-10-05 (the user's split rules) 26s's clear leaves 26n's turns working, so 26n stays wired
# and is never covered by cleared 26s, however near; a click on 26s locks cleared 26s's own site (its
# lane ends within 15 m of its saved point), not 26n. Before, 26s's clear took 26n's wiring with it and
# a click on 26s locked their shared cleared middle: "j26s 15.06", and "j26 | covers j26n and j26s
# 14.86" with 26n's point moved 0.2 m closer.
o=$("$L" regnames.lua clear26 0 </dev/null 2>&1)
check "cleared 26s, 26n wired" "j26s 12.71" "$(echo "$o" | grep '^NAME' | sed 's/^NAME //') $(echo "$o" | grep '^DIST' | sed 's/^DIST //')"
o=$("$L" regnames.lua clear26 0.2 </dev/null 2>&1)
check "cleared 26s, wired 26n moved closer" "j26s 12.51" "$(echo "$o" | grep '^NAME' | sed 's/^NAME //') $(echo "$o" | grep '^DIST' | sed 's/^DIST //')"

# The decision buttons, pointed at and then locked.
o=$("$L" regnames.lua hover </dev/null 2>&1)
check "card, only pointed at" "ROW pointed j20s | no decision buttons | split: j20n, j20s" "$(echo "$o" | grep '^ROW pointed ')"
check "card, locked" "ROW locked j20s | decision buttons: not decided, keep whole | split: j20n, j20s" "$(echo "$o" | grep '^ROW locked')"
check "card, kept whole, pointed at" "ROW pointed30 j30 | no decision buttons | kept whole" "$(echo "$o" | grep '^ROW pointed30')"
check "card: no Lua error" "0" "$(echo "$o" | grep -ciE 'attempt to|stack traceback|failed:')"

# A decision before the career's first save: kept, then written by that save.
o=$("$L" regnames.lua firstsave "$OUT/first" </dev/null 2>&1)
check "first save: kept until then" "SAVED before the first save: false" "$(echo "$o" | grep '^SAVED before')"
check "first save: then written" "SAVED after the first save: true" "$(echo "$o" | grep '^SAVED after')"
check "first save: the decision in it" "FILE the locked junction whole" "$(echo "$o" | grep '^FILE ')"
check "first save: no Lua error" "0" "$(echo "$o" | grep -ciE 'attempt to|stack traceback|failed:')"

# ...and only into that career's folder. B and C are saved careers holding the user's file.
for d in B C; do
  cp "$OUT/A/ADFlyoverEditor_junctions.xml" "$OUT/switch/$d/"
  printf '<careerSavegame/>\n' > "$OUT/switch/$d/careerSavegame.xml"
done
o=$("$L" regnames.lua switch "$OUT/switch" </dev/null 2>&1)
check "another game: A's decision waiting" "SWITCH waiting for A's first save: true" "$(echo "$o" | grep '^SWITCH waiting')"
check "another game: B's file untouched" "SWITCH other file unchanged: true" "$(echo "$o" | grep '^SWITCH other file')"
check "another game: nothing into A" "SWITCH written into A: false" "$(echo "$o" | grep '^SWITCH written')"
check "another game: said it was dropped" "SWITCH said it was dropped: true" "$(echo "$o" | grep '^SWITCH said')"
check "another game: B's own names" "SWITCH name at 39se: j39se" "$(echo "$o" | grep '^SWITCH name')"
check "another game: B decides as B" "SWITCH other keeps its numbers and decisions: true" "$(echo "$o" | grep '^SWITCH other keeps')"
check "another game: no Lua error" "0" "$(echo "$o" | grep -ciE 'attempt to|stack traceback|failed:')"
rm -f "$OUT/switch/A/"* 2>/dev/null
o=$("$L" regnames.lua switchfolder "$OUT/switch" </dev/null 2>&1)
check "folder changed: C's file untouched" "SWITCH other file unchanged: true" "$(echo "$o" | grep '^SWITCH other file')"
check "folder changed: nothing into A" "SWITCH written into A: false" "$(echo "$o" | grep '^SWITCH written')"
check "folder changed: said it was dropped" "SWITCH said it was dropped: true" "$(echo "$o" | grep '^SWITCH said')"
check "folder changed: C's own names" "SWITCH name at 39se: j39se" "$(echo "$o" | grep '^SWITCH name')"
check "folder changed: C decides as C" "SWITCH other keeps its numbers and decisions: true" "$(echo "$o" | grep '^SWITCH other keeps')"
check "folder changed: no Lua error" "0" "$(echo "$o" | grep -ciE 'attempt to|stack traceback|failed:')"

# A change of mind keeps the names: 39 (split by the user into j39nw, j39, j39se), with 39se
# cleared - so the roads alone would now letter what is left by the two-part rule.
D="$OUT/decide"
cp "$OUT/A/ADFlyoverEditor_junctions.xml" "$D/"
printf '<careerSavegame/>\n' > "$D/careerSavegame.xml"
o=$("$L" regnames.lua decide1 "$D" </dev/null 2>&1)
check "decide: as saved" "FILE as saved split | in use: 39 39se 39nw | aside: " "$(echo "$o" | grep '^FILE as saved')"
check "decide: keep whole keeps the names" "FILE kept whole whole | in use:  | aside: 39 39se 39nw" "$(echo "$o" | grep '^FILE kept whole whole')"
check "decide: card, kept whole" "ROW kept whole j39 | decision buttons: not decided, split | kept whole / split brings back j39nw, j39, j39se | button: forget these names" "$(echo "$o" | grep '^ROW kept whole')"
check "decide: not decided keeps them" "FILE not decided not decided | in use:  | aside: 39 39se 39nw" "$(echo "$o" | grep '^FILE not decided')"
check "decide: card, not decided" "ROW not decided j39 | decision buttons: split, keep whole | split brings back j39nw, j39, j39se | button: forget these names" "$(echo "$o" | grep '^ROW not decided')"
check "decide: split brings them back" "FILE split again split | in use: 39 39se 39nw | aside: " "$(echo "$o" | grep '^FILE split again')"
check "decide: at the same places" "SAME split again true" "$(echo "$o" | grep '^SAME split again')"
check "decide: 39 is j39 again" "NAME 39 split again j39" "$(echo "$o" | grep '^NAME 39 split again')"
check "decide: 39nw is j39nw" "NAME 39nw split again j39nw" "$(echo "$o" | grep '^NAME 39nw split again')"
check "decide: no Lua error" "0" "$(echo "$o" | grep -ciE 'attempt to|stack traceback|failed:')"
"$L" regnames.lua copy "$D/ADFlyoverEditor_junctions.xml" "$OUT/D2.xml"
check "round trip, names set aside" "same" "$(cmp -s "$D/ADFlyoverEditor_junctions.xml" "$OUT/D2.xml" && echo same || echo differs)"
# A restart on what that left (39 kept whole, its names set aside), then forget them on purpose.
o=$("$L" regnames.lua decide2 "$D" </dev/null 2>&1)
check "restart: the names still kept" "FILE after the restart whole | in use:  | aside: 39 39se 39nw" "$(echo "$o" | grep '^FILE after the restart')"
check "restart: card" "ROW restart j39 | decision buttons: not decided, split | kept whole / split brings back j39nw, j39, j39se | button: forget these names" "$(echo "$o" | grep '^ROW restart')"
check "restart: split brings them back" "FILE split after the restart split | in use: 39 39se 39nw | aside: " "$(echo "$o" | grep '^FILE split after')"
check "restart: at the same places" "SAME split after the restart true" "$(echo "$o" | grep '^SAME split after')"
check "forget: done on purpose" "FORGOT true" "$(echo "$o" | grep '^FORGOT')"
check "forget: gone from the file" "FILE forgotten whole | in use:  | aside: " "$(echo "$o" | grep '^FILE forgotten')"
check "forget: card, no names to bring back" "ROW forgotten j39 | decision buttons: not decided, split | kept whole" "$(echo "$o" | grep '^ROW forgotten')"
check "forget: then split as the card offers" "FILE split as offered split | in use: 39se 39nw | aside: " "$(echo "$o" | grep '^FILE split as offered')"
check "restart: no Lua error" "0" "$(echo "$o" | grep -ciE 'attempt to|stack traceback|failed:')"
unset REGDIR

# The file round trip: A (from split_registry.lua) -> B -> C, all the same; and the savegame's own
# file read and written, byte for byte the same - byte-order mark and line ends included, since
# xmlstub.lua writes both as the engine does.
"$L" regnames.lua copy "$OUT/A/ADFlyoverEditor_junctions.xml" "$OUT/B.xml" &&
  "$L" regnames.lua copy "$OUT/B.xml" "$OUT/C.xml"
check "round trip A = B" "same" "$(cmp -s "$OUT/A/ADFlyoverEditor_junctions.xml" "$OUT/B.xml" && echo same || echo differs)"
check "round trip B = C" "same" "$(cmp -s "$OUT/B.xml" "$OUT/C.xml" && echo same || echo differs)"
"$L" regnames.lua copy "$REG" "$OUT/R.xml"
check "savegame file read+written" "same" "$(cmp -s "$REG" "$OUT/R.xml" && echo same || echo differs)"

# split_registry.lua refuses, writing nothing.
n_refuse=0
refuse() {   # what, decisions text, output path
  printf '%s\n' "$2" > "$OUT/dec.txt"
  # A name of its own for each try (but the input's own path, which is the point of that case), so
  # "file left" can only be this try's file - never one the synced folder would not let go of.
  out="$3"
  n_refuse=$((n_refuse + 1))
  if [ "$out" != "$OUT/A/ADFlyoverEditor_junctions.xml" ]; then out="${out%.xml}_$$_$n_refuse.xml"; fi
  if "$L" split_registry.lua "$OUT/A/ADFlyoverEditor_junctions.xml" "$OUT/dec.txt" "$out" >/dev/null 2>&1; then r=wrote; else r=refused; fi
  if [ -f "$out" ] && [ "$out" != "$OUT/A/ADFlyoverEditor_junctions.xml" ]; then r="$r, file left"; rm -f "$out"; fi
  check "refuses: $1" "refused" "$r"
}
refuse "a number not in the file" "99n 0 0
99s 0 10" "$OUT/r.xml"
refuse "split and kept whole" "30n 0 0
30s 0 10
whole 30" "$OUT/r.xml"
refuse "fewer than two parts" "30n 0 0" "$OUT/r.xml"
refuse "a name used twice" "30n 0 0
30n 0 10" "$OUT/r.xml"
refuse "a letter not on the compass" "30up 0 0
30s 0 10" "$OUT/r.xml"
refuse "the output is the input" "30n 0 0
30s 0 10" "$OUT/A/ADFlyoverEditor_junctions.xml"
: > "$OUT/save/careerSavegame.xml"
refuse "a savegame folder" "30n 0 0
30s 0 10" "$OUT/save/ADFlyoverEditor_junctions.xml"
check "A untouched by the refusals" "same" "$(cmp -s "$OUT/A/ADFlyoverEditor_junctions.xml" "$OUT/B.xml" && echo same || echo differs)"

# The harness will not read a real savegame folder either.
cp "$OUT/A/ADFlyoverEditor_junctions.xml" "$OUT/save/"
r=$(REGDIR="$OUT/save" "$L" regnames.lua lock 22.5 0.1 </dev/null 2>&1 | grep -c "is a real savegame")
check "harness refuses a savegame REGDIR" "1" "$r"

# The reader: what is not whole is left out, with one warning each.
o=$("$L" regnames.lua badfile "$OUT" </dev/null 2>&1)
check "bad file: whole split read" "READ j1 split 1@0,0 1se@10,10 1nw@-10,-10" "$(echo "$o" | grep '^READ j1 ')"
check "bad file: bad parts left out" "READ j2 split 2n@100,-10 2s@100,10" "$(echo "$o" | grep '^READ j2 ')"
check "bad file: one good part" "READ j3 nil " "$(echo "$o" | grep '^READ j3 ')"
check "bad file: unknown decision" "READ j4 nil " "$(echo "$o" | grep '^READ j4 ')"
check "bad file: whole" "READ j5 whole " "$(echo "$o" | grep '^READ j5 ')"
check "bad file: whole, names aside" "READ j7 whole  | aside 7n@600,-10 7s@600,10" "$(echo "$o" | grep '^READ j7 ')"
check "bad file: not decided, names aside" "READ j8 nil  | aside 8e@710,0 8w@690,0" "$(echo "$o" | grep '^READ j8 ')"
check "bad file: warnings" "WARNINGS 8" "$(echo "$o" | grep '^WARNINGS')"

echo "$pass ok, $fails failed"
[ "$fails" = 0 ]

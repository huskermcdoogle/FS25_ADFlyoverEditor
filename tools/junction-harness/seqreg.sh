# THE SEQUENCE REGRESSION: for every pair of registry junctions A, B within 90 m of each other, clear
# A then B, and compare B's result with B cleared on the fresh network. Both through modes.
#   GRAPH=<network .lua> REG=<ADFlyoverEditor_junctions.xml> bash seqreg.sh TAG
# Writes seq<TAG>/ : fresh_<B>_<mode>.txt, <A>_<B>_<mode>.txt (dbgseq.lua output), and
# seq<TAG>_<mode>.txt: one line per pair, "jA then jB | same" or "| DIFFERS (N lines) | A's edits
# within D m of B". A difference with A's edits near B may be fair (A changed B's ground); one with
# A's edits far away is the clear depending on point numbering. Skips 67 and 68 (test junk) and the
# already-cleared 69-75 (SKIP= to change). Run it twice, and once with SHUFFLE=7: every run must
# be byte-identical.
export RIG_TRAILER=11
L="${LUA:-/c/Program Files (x86)/Lua/5.1/lua.exe}"
TAG=$1
REG="${REG:-$HOME/OneDrive/Documents/My Games/FarmingSimulator2025/savegame6/ADFlyoverEditor_junctions.xml}"
SKIP="${SKIP:-67 68 69 70 71 72 73 74 75}"
NEAR="${NEAR:-90}"
JOBS="${JOBS:-16}"
D=seq$TAG
mkdir -p "$D"
grep -oE 'n="[0-9]+" x="-?[0-9.]+" z="-?[0-9.]+"' "$REG" | sed -E 's/n="([0-9]+)" x="([^"]+)" z="([^"]+)"/\1 \2 \3/' |
  awk -v skip="$SKIP" -v near="$NEAR" '
    BEGIN { n = split(skip, s, " "); for (i = 1; i <= n; i++) bad[s[i]] = 1 }
    !($1 in bad) { k++; N[k] = $1; X[k] = $2; Z[k] = $3 }
    END { for (i = 1; i <= k; i++) for (j = 1; j <= k; j++)
            if (i != j && (X[i] - X[j]) ^ 2 + (Z[i] - Z[j]) ^ 2 <= near * near)
              print N[i], X[i], Z[i], N[j], X[j], Z[j] }' > "$D/pairs.txt"
# One job per line: "fresh B bx bz mode" or "seq A ax az B bx bz mode".
{
  for mode in 1 0; do
    awk -v m=$mode '{ print "fresh", $4, $5, $6, m }' "$D/pairs.txt" | sort -u
    awk -v m=$mode '{ print "seq", $1, $2, $3, $4, $5, $6, m }' "$D/pairs.txt"
  done
} > "$D/jobs.txt"
run() {
  if [ "$1" = fresh ]; then
    LEAVE=$5 "$L" dbgseq.lua "$3" "$4" </dev/null > "$D/fresh_$2_$5.txt" 2>&1
  else
    LEAVE=$8 PRE="$3,$4" "$L" dbgseq.lua "$6" "$7" </dev/null > "$D/$2_$5_$8.txt" 2>&1
  fi
}
export -f run; export L D
xargs -P "$JOBS" -L 1 bash -c 'run "$@"' _ < "$D/jobs.txt"
for mode in 1 0; do
  out=seq${TAG}_$mode.txt
  : > "$out"
  while read -r a ax az b bx bz; do
    f="$D/fresh_${b}_$mode.txt"; s="$D/${a}_${b}_$mode.txt"
    near=$(grep -o "within [0-9.inf]* m" "$s" | head -1)
    pre=$(grep -E "^PRE (refused|STOPPED)" "$s" | head -1)
    n=$(diff <(grep -v "^APART\|^PRE" "$f") <(grep -v "^APART\|^PRE" "$s") | grep -c "^[<>]")
    if [ "$n" = 0 ]; then r="same"; else r="DIFFERS ($n lines)"; fi
    printf "j%s then j%s | %s | A's edits %s of B%s\n" "$a" "$b" "$r" "${near:-none}" "${pre:+ | $pre}" >> "$out"
  done < "$D/pairs.txt"
  if [ $mode = 1 ]; then printf "thru ON : "; else printf "thru OFF: "; fi
  awk '{ t++ } /DIFFERS/ { d++ } END { printf "%d pairs, %d differ\n", t, d + 0 }' "$out"
done

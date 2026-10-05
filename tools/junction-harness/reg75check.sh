# The check after a clear (FlyoverEditor.lua junctionClearCheck), over EVERY registry junction - the
# game's own numbers - in both through modes. Report only: the clear is run exactly as reg75.sh runs
# it, and nothing about it changes.
#   GRAPH=<network .lua> REG=<ADFlyoverEditor_junctions.xml> bash reg75check.sh TAG
# Writes reg75check<TAG>_1.txt (through roads kept) and _0.txt (not): one line per junction,
#   jN | joins N reason:n ... | dots N reason:n ... | other N kind:n ... | wrongBefore N | notes N | err=N
# followed by that junction's problem lines, indented, then the totals. A junction the clear refuses
# (already clear) shows as REFUSED; one whose check threw shows as NO CHECK, and its error is still
# counted in the totals. Run it twice and diff - see the README on pairs().
export RIG_TRAILER=11
L="${LUA:-/c/Program Files (x86)/Lua/5.1/lua.exe}"
TAG=$1
REG="${REG:-$HOME/OneDrive/Documents/My Games/FarmingSimulator2025/savegame6/ADFlyoverEditor_junctions.xml}"
export REG GRAPH FE_SRC REGDIR TERRAIN SHUFFLE LUA
. ./par_sites.sh   # PAR=1 runs one at a time; the output is the same either way
for mode in 1 0; do
  out=reg75check${TAG}_$mode.txt
  par_sites $mode reg75check_one.sh "$out"
  # The totals, from the junction lines alone.
  totals=$(awk -F' [|] ' '
    /^j[0-9]+ \| / {
      # Lua errors first, on every line: a check that threw prints no counts and shows as
      # NO CHECK, and must not drop out of the error total with it.
      if ($NF !~ /err=0/) errs++
      if ($2 ~ /REFUSED/) { refused++; next }
      if ($2 ~ /NO CHECK/) { nocheck++; next }
      checked++
      split($2, J, " "); split($3, D, " "); split($4, O, " "); split($6, N, " ")
      nj = J[2] + 0; nd = D[2] + 0; no = O[2] + 0
      joins += nj; dots += nd; other += no; notes += N[2]; if (N[2] + 0 > 0) noted++
      if (nj + nd == 0) empty++
      if (no == 0) untouched++
      if (nj + nd == 0 && no == 0) both++
      for (i = 3; i in J; i++) { split(J[i], kv, ":"); jr[kv[1]] += kv[2] }
      for (i = 3; i in D; i++) { split(D[i], kv, ":"); dr[kv[1]] += kv[2] }
      for (i = 3; i in O; i++) { split(O[i], kv, ":"); or_[kv[1]] += kv[2]; if (!seen[$1 kv[1]]++) oj[kv[1]]++ }
    }
    END {
      printf "%d checked, %d refused, %d with no check | middle empty at %d | nothing else touched at %d | both at %d | %d Lua errors\n", checked, refused + 0, nocheck + 0, empty + 0, untouched + 0, both + 0, errs + 0
      s = ""; n = asorti(jr, k); for (i = 1; i <= n; i++) s = s " " k[i] ":" jr[k[i]]
      printf "joins %d%s\n", joins, s
      s = ""; n = asorti(dr, k); for (i = 1; i <= n; i++) s = s " " k[i] ":" dr[k[i]]
      printf "teal dots %d%s\n", dots, s
      s = ""; n = asorti(or_, k); for (i = 1; i <= n; i++) s = s " " k[i] ":" or_[k[i]] " (at " oj[k[i]] ")"
      printf "other problems %d%s\n", other, s
      printf "notes %d (at %d)\n", notes + 0, noted + 0
    }' "$out")
  printf "\n== totals ==\n%s\n" "$totals" >> "$out"
  if [ $mode = 1 ]; then echo "thru ON :"; else echo "thru OFF:"; fi
  echo "$totals" | sed 's/^/  /'
done

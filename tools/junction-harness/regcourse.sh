# THE TEST COURSE, offline (pattern step A, doc 12): build every junction of the course's own network as
# it is made - every middle empty - and say whether the mod's pattern went in and what the route check
# found. course/course_init.lua is FS25_ADTestCourse's AutoDrive_init_config.xml through export_graph.py;
# course/ADFlyoverEditor_junctions.xml is slot 10's junction numbers (1 split into 1w and 1e).
#   bash regcourse.sh
L="${LUA:-/c/Program Files (x86)/Lua/5.1/lua.exe}"
for j in "1e -140 -200" "1w -160 -200" "2 0 -200" "3 115 -200" "4 0 21.324278" "5 77.547989 27.518103" "6 192.825623 26.163641" "7 75.135246 124.965935"; do
  set -- $j
  o=$(GRAPH=course/course_init.lua REGDIR=course CLICK=1 "$L" dbgcard.lua "$2" "$3" build </dev/null 2>&1)
  laid=$(echo "$o" | grep -oE "the mod's [a-z]+ [TX] fits" | head -1 | sed -E "s/the mod's ([a-z]+) ([TX]) fits/\1 \2/")
  why=$(echo "$o" | grep -oE "pattern did not fit: .*" | head -1 | sed 's/pattern did not fit: //')
  rc=$(echo "$o" | grep -oE "Route check: .*" | tail -1 | sed 's/Route check: //')
  er=$(echo "$o" | grep -ciE "attempt to|stack traceback")
  printf "J%-3s | pattern: %-10s | %s | err=%s%s\n" "$1" "${laid:-no}" "${rc:-no route check}" "$er" "${why:+ | $why}"
done

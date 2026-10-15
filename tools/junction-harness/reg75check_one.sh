# One junction for reg75check.sh: n x z mode -> the junction line, then its problem lines, indented.
L="${LUA:-/c/Program Files (x86)/Lua/5.1/lua.exe}"
o=$(LEAVE=$4 "$L" dbgcheck.lua "$2" "$3" </dev/null 2>&1)
er=$(echo "$o" | grep -ciE "attempt to|stack traceback|clear check[^:]* failed|check parts failed|clear stopped")
if echo "$o" | grep -q "^REFUSED"; then
  line="REFUSED"
else
  line=$(echo "$o" | grep "^COUNTS " | sed 's/^COUNTS //')
  line="${line:-NO CHECK}"
fi
printf "j%s | %s | err=%s\n" "$1" "$line" "$er"
echo "$o" | grep -E "junction - check: |junction - check \(|check after the clear could not run|check parts failed" | sed -E 's/^.*junction - check/    check/'

#!/usr/bin/env bash
# Checks that supervisor-preflight refuses to run on bash older than 4 and runs on bash 4+.
# Run from anywhere:  tests/bash-version.sh
# Uses only features that bash 3.2 has, so it also works when started with the macOS system bash.
set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/supervisor-preflight"
fail=0

check() { # name, expected exit, actual exit
  if [ "$2" -eq "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (expected exit $2, got $3)"; fail=1; fi
}

# 1. An old bash must be refused with exit 2 and a clear message.
OLD=""
for b in /bin/bash /usr/bin/bash; do
  [ -x "$b" ] && [ "$("$b" -c 'echo ${BASH_VERSINFO[0]}')" -lt 4 ] && { OLD=$b; break; }
done
if [ -n "$OLD" ]; then
  out=$("$OLD" "$SCRIPT" --help 2>&1); rc=$?
  check "bash < 4 ($OLD) exits 2" 2 "$rc"
  case $out in *"needs bash 4 or newer"*) echo "PASS  message names the requirement" ;; *) echo "FAIL  message missing: $out"; fail=1 ;; esac
else
  echo "SKIP  no bash older than 4 on this machine"
fi

# 2. A new bash must get past the version check (--help exits 2 by design, so look at the output).
NEW=""
for b in "$(command -v bash)" /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash /bin/bash; do
  [ -n "$b" ] && [ -x "$b" ] && [ "$("$b" -c 'echo ${BASH_VERSINFO[0]}')" -ge 4 ] && { NEW=$b; break; }
done
if [ -n "$NEW" ]; then
  out=$("$NEW" "$SCRIPT" --help 2>&1)
  case $out in
    *"needs bash 4 or newer"*) echo "FAIL  bash 4+ ($NEW) was refused"; fail=1 ;;
    *Usage:*) echo "PASS  bash 4+ ($NEW) passes the check and prints usage" ;;
    *) echo "FAIL  unexpected output: $out"; fail=1 ;;
  esac
else
  echo "SKIP  no bash 4+ found"
fi

exit $fail

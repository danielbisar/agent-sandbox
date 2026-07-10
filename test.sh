#!/bin/bash
set -eu
root=$(cd "$(dirname "$0")" && pwd)
fail=0
check() { if "$@"; then printf 'ok - %s\n' "$*"; else printf 'not ok - %s\n' "$*"; fail=$((fail + 1)); fi; }
if [ "${1:-}" = --integration ]; then
  shift; only=
  if [ "${1:-}" = --agent ]; then [ "$#" -ge 2 ] || { echo 'error: --agent requires a value' >&2; exit 1; }; only=$2; fi
  for a in codex claude pi; do [ -z "$only" ] || [ "$only" = "$a" ] || continue
    "$root/build.sh" --agent "$a"
    # The command substitution intentionally runs inside the container shell.
    # shellcheck disable=SC2016
    "$root/run.sh" --agent "$a" --shell "$root" -- -lc 'test "$(id -u)" != 0 && command -v git && command -v rg && command -v fdfind && command -v jq'
  done
  exit 0
fi
check bash -n "$root/build.sh" "$root/run.sh" "$root/auth.sh" "$root/lib.sh"
check sh -c "'$root/build.sh' --agent bad >/dev/null 2>&1; test \$? -ne 0"
check sh -c "'$root/build.sh' --agent codex --uid nope >/dev/null 2>&1; test \$? -ne 0"
check sh -c "'$root/build.sh' --agent codex --version 01.2.3 >/dev/null 2>&1; test \$? -ne 0"
check sh -c "'$root/build.sh' --agent codex --tools 'git,not a package' >/dev/null 2>&1; test \$? -ne 0"
check sh -c "'$root/run.sh' --agent codex >/dev/null 2>&1; test \$? -ne 0"
check sh -c "'$root/run.sh' --agent codex --extensions '$root' '$root' >/dev/null 2>&1; test \$? -ne 0"
[ "$fail" -eq 0 ]

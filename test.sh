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
tmp=$(mktemp -d "${TMPDIR:-/tmp}/agent-sandbox-test.XXXXXX")
trap 'rm -f "$tmp/docker" "$tmp/actual" "$tmp/expected"; rmdir "$tmp/state/skills" "$tmp/state" "$tmp"' EXIT
cat > "$tmp/docker" <<'EOF'
#!/bin/bash
set -eu
case "$1 $2" in
  "image ls") printf 'agent-sandbox:%s-1.2.3\n' "$TEST_AGENT";;
  "image inspect")
    case "$*" in
      *org.agent-sandbox.agent*) printf '%s\n' "$TEST_AGENT";;
      *org.agent-sandbox.version*) printf '1.2.3\n';;
      *org.agent-sandbox.suffix*) printf '\n';;
      *) echo "unexpected image inspection: $*" >&2; exit 1;;
    esac;;
  "run -it")
    while [ "$#" -gt 0 ] && [ "$1" != "agent-sandbox:$TEST_AGENT-1.2.3" ]; do shift; done
    [ "$#" -gt 0 ] || { echo "missing image in run command" >&2; exit 1; }
    shift
    printf '%s\n' "$@" > "$TEST_COMMAND_FILE";;
  *) echo "unexpected Docker command: $*" >&2; exit 1;;
esac
EOF
chmod +x "$tmp/docker"
check_launch() {
  test_agent=$1; shift
  TEST_AGENT="$test_agent" TEST_COMMAND_FILE="$tmp/actual" PATH="$tmp:$PATH" \
    "$root/run.sh" --agent "$test_agent" --state-dir "$tmp/state" "$root" "$@" \
    && diff -u "$tmp/expected" "$tmp/actual"
}
for a in codex claude pi; do
  printf '%s\n' "$a" > "$tmp/expected"
  check check_launch "$a" --safe
  printf '%s\n' "$a" --model 'model with spaces' > "$tmp/expected"
  check check_launch "$a" --safe -- --model 'model with spaces'
  case "$a" in
    codex) printf '%s\n' codex --sandbox danger-full-access --ask-for-approval never > "$tmp/expected";;
    claude) printf '%s\n' claude --dangerously-skip-permissions > "$tmp/expected";;
    pi) printf '%s\n' pi --yolo > "$tmp/expected";;
  esac
  check check_launch "$a"
  printf '%s\n' --model 'model with spaces' >> "$tmp/expected"
  check check_launch "$a" -- --model 'model with spaces'
done
printf '%s\n' /bin/bash -lc 'git status' > "$tmp/expected"
check check_launch codex --safe --shell -- -lc 'git status'
[ "$fail" -eq 0 ]

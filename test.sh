#!/bin/bash
set -eu

root=$(cd "$(dirname "$0")" && pwd)
. "$root/lib.sh"
fail=0

check() {
  if "$@"; then
    printf 'ok - %s\n' "$*"
  else
    printf 'not ok - %s\n' "$*"
    fail=$((fail + 1))
  fi
}

check_failure() {
  expected_error=$1
  shift
  if failure_output=$("$@" 2>&1); then
    echo "expected failure, but command succeeded: $*" >&2
    return 1
  fi
  case "$failure_output" in
    *"$expected_error"*)
      ;;
    *)
      printf 'unexpected error: %s\n' "$failure_output" >&2
      return 1
      ;;
  esac
}

if [ "${1:-}" = --integration ]; then
  shift
  only=
  if [ "${1:-}" = --agent ]; then
    need_value "$@"
    only=$2
    validate_agent "$only"
    shift 2
  fi
  [ "$#" -eq 0 ] || die "unknown integration argument: $1"

  # Smoke tests must not mount the user's real authentication state.
  integration_state=$(mktemp -d "${TMPDIR:-/tmp}/agent-sandbox-integration.XXXXXX")
  trap 'rmdir "$integration_state/skills" "$integration_state"' EXIT
  mkdir "$integration_state/skills"
  for a in codex claude pi; do
    [ -z "$only" ] || [ "$only" = "$a" ] || continue
    "$root/build.sh" --agent "$a"
    # The command substitution intentionally runs inside the container shell.
    # shellcheck disable=SC2016
    "$root/run.sh" --agent "$a" --state-dir "$integration_state" --shell "$root" -- -lc 'test "$(id -u)" != 0 && command -v git && command -v rg && command -v fdfind && command -v jq'
  done
  exit 0
fi

check bash -n "$root/build.sh" "$root/run.sh" "$root/auth.sh" "$root/lib.sh" "$root/test-ca.sh"
check check_failure "--agent must be codex, claude, or pi" "$root/test.sh" --integration --agent invalid
check check_failure "--agent must be codex, claude, or pi" "$root/test.sh" --integration --agent ''
check check_failure "--agent requires a value" "$root/test.sh" --integration --agent
check check_failure "unknown integration argument: --unknown" "$root/test.sh" --integration --unknown
check check_failure "unknown integration argument: extra" "$root/test.sh" --integration --agent codex extra
check sh -c "
  '$root/build.sh' --agent bad >/dev/null 2>&1
  test \$? -ne 0
"
check sh -c "
  '$root/build.sh' --agent codex --uid nope >/dev/null 2>&1
  test \$? -ne 0
"
check sh -c "
  '$root/build.sh' --agent codex --version 01.2.3 >/dev/null 2>&1
  test \$? -ne 0
"
check sh -c "
  '$root/build.sh' --agent codex --tools 'git,not a package' >/dev/null 2>&1
  test \$? -ne 0
"
check sh -c "
  '$root/run.sh' --agent codex >/dev/null 2>&1
  test \$? -ne 0
"
check sh -c "
  '$root/run.sh' --agent codex --extensions '$root' '$root' >/dev/null 2>&1
  test \$? -ne 0
"

# Capture Docker's launch arguments without a daemon or installed agent CLIs.
tmp=$(mktemp -d "${TMPDIR:-/tmp}/agent-sandbox-test.XXXXXX")
trap '
  rm -f "$tmp/docker" "$tmp/podman" "$tmp/podman-bin/podman" "$tmp/actual" "$tmp/expected" "$tmp/docker-log" "$tmp/version-count" "$tmp/run-options" "$tmp/engine-log"
  rmdir "$tmp/state/skills" "$tmp/state" "$tmp/podman-bin" "$tmp"
' EXIT
cat > "$tmp/docker" << 'EOF'
#!/bin/bash
set -eu

if [ -n "${TEST_DOCKER_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$TEST_DOCKER_LOG"
fi
engine_name=$(basename "$0")
if [ -n "${TEST_ENGINE_LOG:-}" ]; then
  printf '%s\n' "$engine_name" >> "$TEST_ENGINE_LOG"
fi
label_version=${TEST_LABEL_VERSION-1.2.3}
image_version=${label_version//+/_}
image_prefix=''
[ "$engine_name" != podman ] || image_prefix=localhost/
image_ref="$image_prefix""agent-sandbox:$TEST_AGENT-$image_version"

case "$1 $2" in
  "image ls")
    printf '%s\n' "$image_ref"
    exit "${TEST_DISCOVERY_STATUS:-0}"
    ;;
  "image inspect")
    case "$*" in
      *org.agent-sandbox.agent*)
        printf '%s\n' "$TEST_AGENT"
        ;;
      *org.agent-sandbox.version*)
        printf '%s\n' "$label_version"
        ;;
      *org.agent-sandbox.suffix*)
        printf '\n'
        ;;
      *org.agent-sandbox.uid*)
        printf '%s\n' "${TEST_IMAGE_UID-1000}"
        ;;
      *org.agent-sandbox.gid*)
        printf '%s\n' "${TEST_IMAGE_GID-1000}"
        ;;
      *)
        echo "unexpected image inspection: $*" >&2
        exit 1
        ;;
    esac
    ;;
  "run -it")
    if [ -n "${TEST_RUN_OPTIONS_FILE:-}" ]; then
      printf '%s\n' "$@" > "$TEST_RUN_OPTIONS_FILE"
    fi
    while [ "$#" -gt 0 ] && [ "$1" != "$image_ref" ]; do
      shift
    done
    [ "$#" -gt 0 ] || {
      echo "missing image in run command" >&2
      exit 1
    }
    shift
    printf '%s\n' "$@" > "$TEST_COMMAND_FILE"
    ;;
  "build --target" | "image rm" | "tag "*)
    ;;
  "info --format")
    printf '%s\n' "${TEST_ROOTLESS:-true}"
    exit "${TEST_INFO_STATUS:-0}"
    ;;
  "run --rm")
    run_count=0
    [ ! -s "$TEST_VERSION_COUNT" ] || run_count=$(cat "$TEST_VERSION_COUNT")
    run_count=$((run_count + 1))
    printf '%s\n' "$run_count" > "$TEST_VERSION_COUNT"
    if [ "$run_count" -eq 1 ]; then
      printf '%s\n' "$TEST_PROBE_OUTPUT"
    else
      printf '%s\n' "$TEST_FINAL_OUTPUT"
      exit "${TEST_FINAL_STATUS:-0}"
    fi
    ;;
  *)
    echo "unexpected Docker command: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$tmp/docker"
cp "$tmp/docker" "$tmp/podman"
mkdir "$tmp/podman-bin"
ln -s "$tmp/podman" "$tmp/podman-bin/podman"

check_launch() {
  test_agent=$1
  shift
  TEST_AGENT="$test_agent" \
    TEST_COMMAND_FILE="$tmp/actual" \
    CONTAINER_ENGINE="${TEST_ENGINE:-docker}" \
    PATH="$tmp:$PATH" \
    "$root/run.sh" --agent "$test_agent" --state-dir "$tmp/state" "$root" "$@" &&
    diff -u "$tmp/expected" "$tmp/actual"
}

for a in codex claude pi; do
  printf '%s\n' "$a" > "$tmp/expected"
  check check_launch "$a" --safe
  printf '%s\n' "$a" --model 'model with spaces' > "$tmp/expected"
  check check_launch "$a" --safe -- --model 'model with spaces'
  case "$a" in
    codex)
      printf '%s\n' codex --sandbox danger-full-access --ask-for-approval never > "$tmp/expected"
      ;;
    claude)
      printf '%s\n' claude --dangerously-skip-permissions > "$tmp/expected"
      ;;
    pi)
      printf '%s\n' pi --yolo > "$tmp/expected"
      ;;
  esac
  check check_launch "$a"
  printf '%s\n' --model 'model with spaces' >> "$tmp/expected"
  check check_launch "$a" -- --model 'model with spaces'
done

printf '%s\n' /bin/bash -lc 'git status' > "$tmp/expected"
check check_launch codex --safe --shell -- -lc 'git status'

rejects_version() {
  if is_valid_version "$1"; then
    echo "accepted invalid version: $1" >&2
    return 1
  fi
}

for v in 0.0.0 12.34.56 1.2.3-alpha.0 1.2.3-alpha-beta 1.2.3+001 1.2.3-rc.1+build.2; do
  check is_valid_version "$v"
done
for v in '' latest nonsense 01.2.3 1.02.3 1.2.03 1.2 1.2.3- 1.2.3-alpha..1 1.2.3-01 1.2.3+ 1.2.3+build..1; do
  check rejects_version "$v"
done
check rejects_version $'1.2.3\n4.5.6'

check_parsed_version() {
  local parsed
  parsed=$(parse_agent_version "$1" "$2") || return 1
  [ "$parsed" = "$3" ]
}

rejects_agent_version() {
  if parse_agent_version "$1" "$2" > /dev/null; then
    echo "accepted invalid version output for $1: $2" >&2
    return 1
  fi
}

check check_parsed_version codex 'codex-cli 12.34.56' 12.34.56
check check_parsed_version claude '12.34.56 (Claude Code)' 12.34.56
check check_parsed_version claude 12.34.56 12.34.56
check check_parsed_version pi 12.34.56 12.34.56
check check_parsed_version codex 'codex-cli 1.2.3-rc.1+build.2' 1.2.3-rc.1+build.2
check rejects_agent_version codex 'notice: codex-cli 1.2.3'
check rejects_agent_version claude '1.2.3 (Unexpected Product)'
check rejects_agent_version pi 'version 1.2.3'
check rejects_agent_version pi $'1.2.3\n4.5.6'

run_build() {
  local build_agent=$1
  local probe_output=$2
  local final_output=$3
  shift 3
  : > "$tmp/docker-log"
  : > "$tmp/version-count"
  TEST_AGENT="$build_agent" \
    TEST_PROBE_OUTPUT="$probe_output" \
    TEST_FINAL_OUTPUT="$final_output" \
    TEST_DOCKER_LOG="$tmp/docker-log" \
    TEST_VERSION_COUNT="$tmp/version-count" \
    CONTAINER_ENGINE="${TEST_ENGINE:-docker}" \
    PATH="$tmp:$PATH" \
    "$root/build.sh" --agent "$build_agent" --no-pull "$@"
}

check_build() {
  local build_output
  local expected_ref=$5
  build_output=$(run_build "$1" "$3" "$4" --version "$2") || return 1
  [ "$build_output" = "Built $expected_ref" ] || return 1
  check_build_log "$expected_ref" 1
}

check_build_log() {
  # The second version check must precede the only publication of a versioned tag.
  awk -v expected="$1" -v expected_tags="$2" '
    $1 == "build" {
      for (i = 2; i < NF; i++) {
        if ($i == "-t" && $(i + 1) !~ /^agent-sandbox-build-[0-9]+$/) exit 1
      }
    }
    $1 == "run" && $2 == "--rm" { verifications++ }
    $1 == "tag" {
      if (verifications != 2 || $3 != expected) exit 1
      tags++
    }
    END { if (tags + 0 != expected_tags) exit 1 }
  ' "$tmp/docker-log"
}

check_build_failure() {
  check_failure "$@" || return 1
  check_build_log '' 0
}

check check_build codex 12.34.56 'codex-cli 12.34.56' 'codex-cli 12.34.56' agent-sandbox:codex-12.34.56
check check_build claude 12.34.56 '12.34.56 (Claude Code)' '12.34.56 (Claude Code)' agent-sandbox:claude-12.34.56
check check_build pi 12.34.56 12.34.56 12.34.56 agent-sandbox:pi-12.34.56
check check_build codex 1.2.3-rc.1 'codex-cli 1.2.3-rc.1' 'codex-cli 1.2.3-rc.1' agent-sandbox:codex-1.2.3-rc.1
check check_build pi 1.2.3+build.1 1.2.3+build.1 1.2.3+build.1 agent-sandbox:pi-1.2.3_build.1
check check_build pi latest 1.2.3+build-test 1.2.3+build-test agent-sandbox:pi-1.2.3_build-test
check check_build_failure "invalid semantic version" run_build pi 1.2.3 1.2.3 --version 1.2.3-01
check check_build_failure "installed version 1.2.3 does not match requested 2.0.0" run_build pi 1.2.3 1.2.3 --version 2.0.0
check check_build_failure "latest resolved to prerelease" run_build pi 1.2.3-rc.1 1.2.3-rc.1
check check_build_failure "could not determine installed pi version" run_build pi nonsense 1.2.3
check check_build_failure "final image version 1.2.30 does not match expected 1.2.3" run_build pi 1.2.3 1.2.30
check check_build_failure "final image version 11.2.3 does not match expected 1.2.3" run_build pi 1.2.3 11.2.3
check check_build_failure "final image version 1.2.3-rc.1 does not match expected 1.2.3" run_build pi 1.2.3 1.2.3-rc.1
check check_build_failure "final image version 1.2.3+build.2 does not match expected 1.2.3+build.1" run_build pi 1.2.3+build.1 1.2.3+build.2
check check_build_failure "could not determine installed pi version" run_build pi 1.2.3 'version 1.2.3'
TEST_FINAL_STATUS=1 check check_build_failure "could not run pi --version" run_build pi 1.2.3 1.2.3

check_selection() (
  local container_engine="$tmp/docker"
  agent=codex
  requested_version=$2
  suffix=''
  suffix_set=false
  TEST_AGENT=codex
  TEST_LABEL_VERSION=$1
  export TEST_AGENT TEST_LABEL_VERSION
  select_image
  [ "$selected_version" = "$3" ]
)

check check_selection 1.2.3 '' 1.2.3
check check_selection 1.2.3+build-test '' 1.2.3+build-test
check check_selection 1.2.3-rc.1 1.2.3-rc.1 1.2.3-rc.1
check check_failure "no matching image" check_selection 1.2.3-rc.1 '' ''
check check_failure "invalid version label: nonsense" check_selection nonsense '' ''
check check_failure "invalid version label: 01.2.3" check_selection 01.2.3 '' ''
check check_failure "invalid version label:" check_selection '' '' ''
check check_failure "invalid semantic version: nonsense" check_selection 1.2.3 nonsense ''

check_engine_selection() {
  local CONTAINER_ENGINE=$1
  local PATH=$2
  local container_engine=''
  select_container_engine
  [ "$container_engine" = "$3" ]
}

check check_engine_selection '' "$tmp" docker
check check_engine_selection '' "$tmp/podman-bin" podman
check check_engine_selection podman "$tmp" podman
check check_engine_selection docker "$tmp" docker
check check_failure "Docker or Podman is required" check_engine_selection '' "$tmp/no-engines" ''
check check_failure "docker is not installed" check_engine_selection docker "$tmp/podman-bin" ''
check check_failure "CONTAINER_ENGINE must be docker or podman" check_engine_selection invalid "$tmp" ''

check_podman_launch() {
  printf '%s\n' "$1" --model 'model with spaces' > "$tmp/expected"
  TEST_ENGINE=podman \
    TEST_IMAGE_UID="$2" \
    TEST_IMAGE_GID="$3" \
    TEST_ROOTLESS="$4" \
    TEST_RUN_OPTIONS_FILE="$tmp/run-options" \
    check_launch "$1" --safe -- --model 'model with spaces' || return 1
  if [ "$4" = true ]; then
    grep -Fqx -- "--userns=keep-id:uid=$2,gid=$3" "$tmp/run-options" &&
      grep -Fqx -- "--user" "$tmp/run-options"
  else
    if grep -q -- '--userns=' "$tmp/run-options"; then
      echo "unexpected user namespace mapping for rootful Podman" >&2
      return 1
    fi
  fi
}

for a in codex claude pi; do
  check check_podman_launch "$a" 1000 1000 true
done
check check_podman_launch codex 2000 3000 true
check check_podman_launch codex 1000 1000 false
TEST_INFO_STATUS=1 check check_failure "cannot inspect Podman rootless mode" check_podman_launch codex 1000 1000 true
check check_failure "image UID and GID labels must be positive integers" check_podman_launch codex '' 1000 true
check check_failure "image UID and GID labels must be positive integers" check_podman_launch codex 0 1000 true
check check_failure "unexpected Podman rootless mode" check_podman_launch codex 1000 1000 unexpected
TEST_ENGINE=podman TEST_DISCOVERY_STATUS=1 check check_failure "podman image discovery failed" check_launch codex --safe

check_auth() {
  local auth_engine=$1
  local auth_agent=$2
  case "$auth_agent" in
    codex)
      printf '%s\n' codex login --device-auth --example 'value with spaces' > "$tmp/expected"
      ;;
    *)
      printf '%s\n' "$auth_agent" --example 'value with spaces' > "$tmp/expected"
      ;;
  esac
  TEST_AGENT="$auth_agent" \
    TEST_COMMAND_FILE="$tmp/actual" \
    CONTAINER_ENGINE="$auth_engine" \
    PATH="$tmp:$PATH" \
    "$root/auth.sh" --agent "$auth_agent" --state-dir "$tmp/state" -- --example 'value with spaces' &&
    diff -u "$tmp/expected" "$tmp/actual"
}

for engine in docker podman; do
  for a in codex claude pi; do
    check check_auth "$engine" "$a"
  done
done

check_podman_build() {
  : > "$tmp/engine-log"
  TEST_ENGINE=podman \
    TEST_ENGINE_LOG="$tmp/engine-log" \
    check_build pi 12.34.56 12.34.56 12.34.56 agent-sandbox:pi-12.34.56 || return 1
  if grep -qv '^podman$' "$tmp/engine-log"; then
    echo "Podman build invoked another engine" >&2
    return 1
  fi
}
check check_podman_build

if command -v openssl > /dev/null 2>&1; then
  check "$root/test-ca.sh"
else
  printf 'skip - CA tests require OpenSSL\n'
fi

[ "$fail" -eq 0 ]

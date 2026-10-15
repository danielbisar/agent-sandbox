#!/bin/bash

die() {
  echo "error: $*" >&2
  exit 1
}

need_value() {
  [ "$#" -ge 2 ] || die "$1 requires a value"
}

validate_agent() {
  case "$1" in
    codex | claude | pi)
      ;;
    *)
      die "--agent must be codex, claude, or pi"
      ;;
  esac
}

is_valid_version() {
  case "$1" in
    *$'\n'* | *$'\r'*)
      return 1
      ;;
  esac
  printf '%s\n' "$1" |
    grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$' || return 1

  # SemVer forbids leading zeros in numeric prerelease identifiers, but not metadata.
  awk -v version="$1" 'BEGIN {
    sub(/[+].*$/, "", version)
    separator = index(version, "-")
    if (separator == 0) exit 0
    count = split(substr(version, separator + 1), identifiers, ".")
    for (i = 1; i <= count; i++) {
      if (identifiers[i] ~ /^0[0-9]+$/) exit 1
    }
  }'
}

validate_version() {
  is_valid_version "$1" || die "invalid semantic version: $1"
}

parse_agent_version() {
  local parsed
  case "$2" in
    *$'\n'* | *$'\r'*)
      return 1
      ;;
  esac

  # Match the complete vendor output, not an arbitrary version-looking substring.
  case "$1" in
    codex)
      parsed=$(printf '%s\n' "$2" | sed -nE 's/^codex-cli ([^[:space:]]+)$/\1/p')
      ;;
    claude)
      parsed=$(printf '%s\n' "$2" | sed -nE 's/^([^[:space:]]+)( \(Claude Code\))?$/\1/p')
      ;;
    pi)
      parsed=$2
      ;;
    *)
      return 1
      ;;
  esac
  is_valid_version "$parsed" || return 1
  printf '%s\n' "$parsed"
}

read_agent_version() {
  local output
  local parsed
  output=$(docker run --rm "$2" "$1" --version) || die "could not run $1 --version in image $2"
  parsed=$(parse_agent_version "$1" "$output") || die "could not determine installed $1 version in image $2: $output"
  printf '%s\n' "$parsed"
}

absolute_dir() {
  [ -d "$1" ] || die "directory does not exist: $1"
  (cd "$1" && pwd -P)
}

prepare_state() {
  if [ ! -d "$1" ]; then
    mkdir -p "$1" || die "cannot create state directory: $1"
    chmod 700 "$1"
  fi
  absolute_dir "$1"
}

select_image() {
  [ -z "$requested_version" ] || validate_version "$requested_version"
  # These globals are initialized by each public wrapper before this function is called.
  # shellcheck disable=SC2154
  filter="label=org.agent-sandbox.agent=$agent"
  refs=$(
    docker image ls --format '{{.Repository}}:{{.Tag}}' --filter "$filter" 2> /dev/null |
      grep '^agent-sandbox:' || true
  )
  candidates=
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    a=$(docker image inspect --format '{{index .Config.Labels "org.agent-sandbox.agent"}}' "$ref" 2> /dev/null || true)
    v=$(docker image inspect --format '{{index .Config.Labels "org.agent-sandbox.version"}}' "$ref" 2> /dev/null || true)
    s=$(docker image inspect --format '{{index .Config.Labels "org.agent-sandbox.suffix"}}' "$ref" 2> /dev/null || true)
    [ "$a" = "$agent" ] || continue
    if ! is_valid_version "$v"; then
      printf 'warning: ignoring image %s with invalid version label: %s\n' "$ref" "$v" >&2
      continue
    fi
    if [ -n "$requested_version" ]; then
      [ "$v" = "$requested_version" ] || continue
    else
      case "${v%%+*}" in
        *-*)
          continue
          ;;
      esac
    fi
    # shellcheck disable=SC2154
    if [ "$suffix_set" = true ]; then
      [ "$s" = "$suffix" ] || continue
    else
      [ -z "$s" ] || continue
    fi
    # Rows are version<TAB>reference; add a newline only between candidates.
    candidates="${candidates}${candidates:+
}$v$(printf '\t')$ref"
  done << EOF
$refs
EOF

  # Compare major, minor, and patch numerically rather than sorting version strings.
  chosen=$(printf '%s\n' "$candidates" | awk -F '\t' '
    NF == 2 {
      split($1, current, ".")
      split(best_version, best, ".")
      if (best_version == "" || current[1] + 0 > best[1] + 0 ||
          (current[1] + 0 == best[1] + 0 && current[2] + 0 > best[2] + 0) ||
          (current[1] + 0 == best[1] + 0 && current[2] + 0 == best[2] + 0 && current[3] + 0 > best[3] + 0)) {
        best_version=$1
        best_line=$0
      }
    }
    END {
      if (best_line != "") print best_line
    }
  ')

  [ -n "$chosen" ] || {
    cmd="./build.sh --agent $agent${requested_version:+ --version $requested_version}"
    [ "$suffix_set" = false ] || cmd="$cmd --suffix $suffix"
    die "no matching image; build it with: $cmd"
  }

  tab=$(printf '\t')
  # Outputs consumed by the wrapper that sourced this library.
  # shellcheck disable=SC2034
  image=${chosen#*"$tab"}
  # shellcheck disable=SC2034
  selected_version=${chosen%%"$tab"*}
}

add_skill_mounts() {
  mode=$1
  shift
  for path in "$@"; do
    full=$(absolute_dir "$path")
    base=$(basename "$full")
    name=$base
    n=2
    # state_dir and skill_names are initialized by run.sh before this call.
    # shellcheck disable=SC2154
    # Avoid both existing state entries and names assigned earlier in this launch.
    while [ -e "$state_dir/skills/$name" ] || {
      case " $skill_names " in
        *" $name "*)
          true
          ;;
        *)
          false
          ;;
      esac
    } do
      name="$base-$n"
      n=$((n + 1))
    done
    skill_names="$skill_names $name"
    mounts+=("-v" "$full:/home/agent/.agent-state/skills/$name:$mode")
  done
}

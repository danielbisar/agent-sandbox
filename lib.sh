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

select_container_engine() {
  case "${CONTAINER_ENGINE:-}" in
    docker | podman)
      container_engine=$CONTAINER_ENGINE
      command -v "$container_engine" > /dev/null 2>&1 || die "$container_engine is not installed"
      ;;
    '')
      if command -v docker > /dev/null 2>&1; then
        container_engine=docker
      elif command -v podman > /dev/null 2>&1; then
        container_engine=podman
      else
        die "Docker or Podman is required"
      fi
      ;;
    *)
      die "CONTAINER_ENGINE must be docker or podman"
      ;;
  esac
}

prepare_run_options() {
  local rootless
  local uid
  local gid
  run_options=(-it --rm)
  [ "$container_engine" = podman ] || return 0

  rootless=$("$container_engine" info --format '{{.Host.Security.Rootless}}') || die "cannot inspect Podman rootless mode"
  case "$rootless" in
    true)
      uid=$("$container_engine" image inspect --format '{{index .Config.Labels "org.agent-sandbox.uid"}}' "$image") || die "cannot inspect image UID"
      gid=$("$container_engine" image inspect --format '{{index .Config.Labels "org.agent-sandbox.gid"}}' "$image") || die "cannot inspect image GID"
      if printf '%s\n%s\n' "$uid" "$gid" | grep -Eqv '^[1-9][0-9]*$'; then
        die "image UID and GID labels must be positive integers for rootless Podman"
      fi
      # Map the host owner to agent, preserving access to mode-0700 state without chown.
      run_options+=("--userns=keep-id:uid=$uid,gid=$gid" "--user" agent)
      ;;
    false)
      ;;
    *)
      die "unexpected Podman rootless mode: $rootless"
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
  output=$("$container_engine" run --rm "$2" "$1" --version) || die "could not run $1 --version in image $2"
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
  refs=$("$container_engine" image ls --format '{{.Repository}}:{{.Tag}}' --filter "$filter") || die "$container_engine image discovery failed"
  # Podman qualifies locally built image names with localhost/.
  refs=$(printf '%s\n' "$refs" | grep -E '^(localhost/)?agent-sandbox:' || true)
  candidates=
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    a=$("$container_engine" image inspect --format '{{index .Config.Labels "org.agent-sandbox.agent"}}' "$ref") || die "cannot inspect image agent: $ref"
    v=$("$container_engine" image inspect --format '{{index .Config.Labels "org.agent-sandbox.version"}}' "$ref") || die "cannot inspect image version: $ref"
    s=$("$container_engine" image inspect --format '{{index .Config.Labels "org.agent-sandbox.suffix"}}' "$ref") || die "cannot inspect image suffix: $ref"
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
    cmd="CONTAINER_ENGINE=$container_engine ./build.sh --agent $agent${requested_version:+ --version $requested_version}"
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

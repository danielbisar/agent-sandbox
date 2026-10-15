#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$script_dir/lib.sh"

agent=''
requested_version=''
suffix=''
suffix_set=false
state=''
selinux=false
forwarded=()

usage() {
  echo "Usage: $0 --agent codex|claude|pi [--version VERSION] [--suffix VALUE] [--state-dir PATH] [--selinux] [-- AUTH_ARGS...]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --)
      shift
      forwarded=("$@")
      break
      ;;
    --agent)
      need_value "$@"
      agent=$2
      shift
      ;;
    --version)
      need_value "$@"
      requested_version=$2
      shift
      ;;
    --suffix)
      need_value "$@"
      suffix=$2
      suffix_set=true
      shift
      ;;
    --state-dir)
      need_value "$@"
      state=$2
      shift
      ;;
    --selinux)
      selinux=true
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

validate_agent "$agent"
select_container_engine
state=${state:-$script_dir/state/$agent}
state_dir=$(prepare_state "$state")
select_image
prepare_run_options

z=
[ "$selinux" = false ] || z=,Z

# Claude and Pi handle provider setup through their interactive CLI.
case "$agent" in
  codex)
    cmd=(codex login --device-auth)
    ;;
  claude)
    cmd=(claude)
    ;;
  pi)
    cmd=(pi)
    ;;
esac

[ "${#forwarded[@]}" -eq 0 ] || cmd+=("${forwarded[@]}")
exec "$container_engine" run "${run_options[@]}" -v "$state_dir:/home/agent/.agent-state:rw$z" "$image" "${cmd[@]}"

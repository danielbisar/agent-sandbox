#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$script_dir/lib.sh"

agent=''
requested_version=''
suffix=''
suffix_set=false
state=''
workspace=''
read_only=false
safe=false
shell=false
selinux=false
extensions=''
extensions_mode=ro
skills_ro=()
skills_rw=()
forwarded=()

usage() {
  echo "Usage: $0 --agent codex|claude|pi [OPTIONS] WORKSPACE [-- AGENT_ARGS...]" >&2
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
    --skills)
      need_value "$@"
      skills_ro+=("$2")
      shift
      ;;
    --skills-rw)
      need_value "$@"
      skills_rw+=("$2")
      shift
      ;;
    --extensions)
      need_value "$@"
      extensions=$2
      extensions_mode=ro
      shift
      ;;
    --extensions-rw)
      need_value "$@"
      extensions=$2
      extensions_mode=rw
      shift
      ;;
    --read-only)
      read_only=true
      ;;
    --safe)
      safe=true
      ;;
    --shell)
      shell=true
      ;;
    --selinux)
      selinux=true
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      [ -z "$workspace" ] || die "multiple workspaces provided"
      workspace=$1
      ;;
  esac
  shift
done

validate_agent "$agent"
[ -n "$workspace" ] || {
  usage
  die "WORKSPACE is required"
}
[ -z "$extensions" ] || [ "$agent" = pi ] || die "extensions are supported only for pi"

select_container_engine
workspace=$(absolute_dir "$workspace")
state=${state:-$script_dir/state/$agent}
state_dir=$(prepare_state "$state")
mkdir -p "$state_dir/skills"
select_image
prepare_run_options

# Private SELinux relabeling applies to every managed mount.
z=
[ "$selinux" = false ] || z=,Z
wm=rw
[ "$read_only" = false ] || wm=ro
mounts=(
  "-v" "$state_dir:/home/agent/.agent-state:rw$z"
  "-v" "$workspace:/home/agent/src:$wm$z"
)
skill_names=
# Bash 3.2 treats empty array expansions as unset under nounset.
[ "${#skills_ro[@]}" -eq 0 ] || add_skill_mounts "ro$z" "${skills_ro[@]}"
[ "${#skills_rw[@]}" -eq 0 ] || add_skill_mounts "rw$z" "${skills_rw[@]}"
if [ -n "$extensions" ]; then
  ext=$(absolute_dir "$extensions")
  mounts+=("-v" "$ext:/home/agent/.agent-state/extensions:$extensions_mode$z")
fi

cmd=()
if [ "$shell" = true ]; then
  cmd=(/bin/bash)
else
  if [ "$safe" = true ]; then
    # An explicit CLI command overrides the image's unrestricted default CMD.
    cmd=("$agent")
  else
    case "$agent" in
      codex)
        cmd=(codex --sandbox danger-full-access --ask-for-approval never)
        ;;
      claude)
        cmd=(claude --dangerously-skip-permissions)
        ;;
      pi)
        cmd=(pi --yolo)
        ;;
    esac
  fi
fi
[ "${#forwarded[@]}" -eq 0 ] || cmd+=("${forwarded[@]}")

exec "$container_engine" run "${run_options[@]}" "${mounts[@]}" "$image" "${cmd[@]}"

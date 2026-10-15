#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$script_dir/lib.sh"

agent=''
version=latest
base_image=node:24-slim
pull=true
uid=1000
gid=1000
suffix=''
tools=()

usage() {
  echo "Usage: $0 --agent codex|claude|pi [--version VERSION] [--base-image IMAGE] [--no-pull] [--uid UID] [--gid GID] [--tools pkg1,pkg2] [--suffix VALUE]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent)
      need_value "$@"
      agent=$2
      shift
      ;;
    --version)
      need_value "$@"
      version=$2
      shift
      ;;
    --base-image)
      need_value "$@"
      base_image=$2
      shift
      ;;
    --no-pull)
      pull=false
      ;;
    --uid)
      need_value "$@"
      uid=$2
      shift
      ;;
    --gid)
      need_value "$@"
      gid=$2
      shift
      ;;
    --tools)
      need_value "$@"
      tools+=("$2")
      shift
      ;;
    --suffix)
      need_value "$@"
      suffix=$2
      shift
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

case "$agent" in
  codex | claude | pi)
    ;;
  *)
    usage
    die "--agent must be codex, claude, or pi"
    ;;
esac

printf '%s\n%s\n' "$uid" "$gid" | grep -Eqv '^[0-9]+$' && die "UID and GID must be non-negative integers"
[ "$version" = latest ] || validate_version "$version"

# Split repeated comma-separated lists and deduplicate exact package specifications.
packages=
old_ifs=$IFS
IFS=,
# Avoid expanding an empty array under Bash 3.2's nounset behavior.
if [ "${#tools[@]}" -gt 0 ]; then
  for list in "${tools[@]}"; do
    for pkg in $list; do
      printf '%s\n' "$pkg" | grep -Eq '^[a-z0-9][a-z0-9+.-]*(:[a-z0-9-]+)?(=[A-Za-z0-9.+:~_-]+)?$' || die "invalid Debian package: $pkg"
      case " $packages " in
        *" $pkg "*)
          ;;
        *)
          packages="${packages:+$packages }$pkg"
          ;;
      esac
    done
  done
fi
IFS=$old_ifs

[ "$pull" = false ] || docker pull "$base_image"

# Resolve an unpinned request in a temporary image before building the versioned image.
tmp="agent-sandbox-build-$$"
trap 'docker image rm -f "$tmp" >/dev/null 2>&1 || true' EXIT INT TERM
docker build --target "$agent" -t "$tmp" \
  --build-arg "BASE_IMAGE=$base_image" \
  --build-arg "AGENT_VERSION=$version" \
  --build-arg "AGENT_UID=$uid" \
  --build-arg "AGENT_GID=$gid" \
  --build-arg "EXTRA_PACKAGES=$packages" .

reported=$(read_agent_version "$agent" "$tmp")
[ "$version" = latest ] || [ "$reported" = "$version" ] || die "installed version $reported does not match requested $version"
case "${reported%%+*}" in
  *-*)
    [ "$version" != latest ] || die "latest resolved to prerelease $reported"
    ;;
esac

# Docker tags cannot contain '+'. Labels retain the exact SemVer, including metadata.
tag_version=${reported//+/_}
tag="agent-sandbox:$agent-$tag_version${suffix:+-$suffix}"
commit=$(git rev-parse HEAD 2> /dev/null || echo unknown)
dirty=false
[ -z "$(git status --porcelain 2> /dev/null)" ] || dirty=true
created=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
docker build --target "$agent" -t "$tmp" \
  --build-arg "BASE_IMAGE=$base_image" \
  --build-arg "AGENT_VERSION=$reported" \
  --build-arg "AGENT_UID=$uid" \
  --build-arg "AGENT_GID=$gid" \
  --build-arg "EXTRA_PACKAGES=$packages" \
  --label "org.agent-sandbox.agent=$agent" \
  --label "org.agent-sandbox.version=$reported" \
  --label "org.agent-sandbox.suffix=$suffix" \
  --label "org.agent-sandbox.base-image=$base_image" \
  --label "org.agent-sandbox.uid=$uid" \
  --label "org.agent-sandbox.gid=$gid" \
  --label "org.agent-sandbox.extra-packages=$packages" \
  --label "org.agent-sandbox.git-commit=$commit" \
  --label "org.agent-sandbox.git-dirty=$dirty" \
  --label "org.agent-sandbox.built-at=$created" .

check=$(read_agent_version "$agent" "$tmp")
[ "$check" = "$reported" ] || die "final image version $check does not match expected $reported"
# Publish the local versioned tag only after verifying the final image exactly.
docker tag "$tmp" "$tag"
echo "Built $tag"

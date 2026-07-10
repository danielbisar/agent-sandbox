#!/bin/bash
set -euo pipefail

agent='' version=latest base_image=node:24-slim pull=true uid=1000 gid=1000 suffix=''
tools=()
usage() { echo "Usage: $0 --agent codex|claude|pi [--version VERSION] [--base-image IMAGE] [--no-pull] [--uid UID] [--gid GID] [--tools pkg1,pkg2] [--suffix VALUE]" >&2; }
die() { echo "error: $*" >&2; exit 1; }
need() { [ "$#" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent) need "$@"; agent=$2; shift;; --version) need "$@"; version=$2; shift;;
    --base-image) need "$@"; base_image=$2; shift;; --no-pull) pull=false;;
    --uid) need "$@"; uid=$2; shift;; --gid) need "$@"; gid=$2; shift;;
    --tools) need "$@"; tools+=("$2"); shift;; --suffix) need "$@"; suffix=$2; shift;;
    -h|--help) usage; exit 0;; *) die "unknown argument: $1";;
  esac; shift
done
case "$agent" in codex|claude|pi) ;; *) usage; die "--agent must be codex, claude, or pi";; esac
printf '%s\n%s\n' "$uid" "$gid" | grep -Eqv '^[0-9]+$' && die "UID and GID must be non-negative integers"
if [ "$version" != latest ] && ! printf '%s\n' "$version" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'; then die "invalid semantic version: $version"; fi
packages=
old_ifs=$IFS; IFS=,
for list in "${tools[@]}"; do for pkg in $list; do
  printf '%s\n' "$pkg" | grep -Eq '^[a-z0-9][a-z0-9+.-]*(:[a-z0-9-]+)?(=[A-Za-z0-9.+:~_-]+)?$' || die "invalid Debian package: $pkg"
  case " $packages " in *" $pkg "*) ;; *) packages="${packages:+$packages }$pkg";; esac
done; done; IFS=$old_ifs
[ "$pull" = false ] || docker pull "$base_image"
tmp="agent-sandbox-build-$$"
trap 'docker image rm -f "$tmp" >/dev/null 2>&1 || true' EXIT INT TERM
docker build --target "$agent" -t "$tmp" \
  --build-arg "BASE_IMAGE=$base_image" --build-arg "AGENT_VERSION=$version" \
  --build-arg "AGENT_UID=$uid" --build-arg "AGENT_GID=$gid" --build-arg "EXTRA_PACKAGES=$packages" .
case "$agent" in
  codex) reported=$(docker run --rm "$tmp" codex --version | sed -nE 's/.* ([0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?).*/\1/p' | head -1);;
  claude) reported=$(docker run --rm "$tmp" claude --version | sed -nE 's/.*([0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?).*/\1/p' | head -1);;
  pi) reported=$(docker run --rm "$tmp" pi --version | sed -nE 's/.*([0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?).*/\1/p' | head -1);;
esac
[ -n "$reported" ] || die "could not determine installed $agent version"
[ "$version" = latest ] || [ "$reported" = "$version" ] || die "installed version $reported does not match requested $version"
case "$reported" in *-*) [ "$version" != latest ] || die "latest resolved to prerelease $reported";; esac
tag="agent-sandbox:$agent-$reported${suffix:+-$suffix}"
commit=$(git rev-parse HEAD 2>/dev/null || echo unknown); dirty=false; [ -z "$(git status --porcelain 2>/dev/null)" ] || dirty=true
created=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
docker build --target "$agent" -t "$tag" \
  --build-arg "BASE_IMAGE=$base_image" --build-arg "AGENT_VERSION=$reported" \
  --build-arg "AGENT_UID=$uid" --build-arg "AGENT_GID=$gid" --build-arg "EXTRA_PACKAGES=$packages" \
  --label "org.agent-sandbox.agent=$agent" --label "org.agent-sandbox.version=$reported" \
  --label "org.agent-sandbox.suffix=$suffix" --label "org.agent-sandbox.base-image=$base_image" \
  --label "org.agent-sandbox.uid=$uid" --label "org.agent-sandbox.gid=$gid" \
  --label "org.agent-sandbox.extra-packages=$packages" --label "org.agent-sandbox.git-commit=$commit" \
  --label "org.agent-sandbox.git-dirty=$dirty" --label "org.agent-sandbox.built-at=$created" .
check=$(docker run --rm "$tag" "$agent" --version 2>/dev/null || true)
printf '%s\n' "$check" | grep -F "$reported" >/dev/null || die "final image version verification failed"
echo "Built $tag"

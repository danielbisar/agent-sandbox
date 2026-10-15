#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$script_dir/lib.sh"

agent=''
version=latest
base_image=docker.io/library/node:24-slim
pull=true
uid=1000
gid=1000
suffix=''
tools=()
ca_certs=()
build_context=.
trust_stage=base
tmp=''
context_dir=''

cleanup() {
  if [ -n "$tmp" ]; then
    "$container_engine" image rm -f "$tmp" > /dev/null 2>&1 || true
  fi
  if [ -n "$context_dir" ]; then
    # Only generated files in the private context are removed, never caller inputs.
    for cert in "$context_dir"/ca-certificates/*.crt; do
      [ ! -f "$cert" ] || rm -f "$cert"
    done
    rm -f "$context_dir/Dockerfile" "$context_dir/.dockerignore"
    rmdir "$context_dir/ca-certificates" "$context_dir"
  fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
  echo "Usage: $0 --agent codex|claude|pi [--version VERSION] [--base-image IMAGE] [--no-pull] [--uid UID] [--gid GID] [--tools pkg1,pkg2] [--ca-cert PATH] [--suffix VALUE]" >&2
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
    --ca-cert)
      need_value "$@"
      ca_certs+=("$2")
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

# Keep external certificates and the rest of the checkout out of the normal context.
if [ "${#ca_certs[@]}" -gt 0 ]; then
  command -v openssl > /dev/null 2>&1 || die "--ca-cert requires OpenSSL"
  context_dir=$(mktemp -d "${TMPDIR:-/tmp}/agent-sandbox-context.XXXXXX")
  mkdir "$context_dir/ca-certificates"
  cp "$script_dir/Dockerfile" "$context_dir/Dockerfile"
  printf '%s\n' '**' '!Dockerfile' '!ca-certificates/' '!ca-certificates/*.crt' > "$context_dir/.dockerignore"
  cert_index=0
  for cert in "${ca_certs[@]}"; do
    validate_ca_cert "$cert"
    cert_index=$((cert_index + 1))
    # Normalize PEM encoding and filenames; never embed the caller's path.
    openssl x509 -in "$cert" -out "$context_dir/ca-certificates/ca-$cert_index.crt" ||
      die "cannot prepare CA certificate: $cert"
  done
  build_context=$context_dir
  trust_stage=custom-ca
fi

select_container_engine
[ "$pull" = false ] || "$container_engine" pull "$base_image"

# Resolve an unpinned request in a temporary image before building the versioned image.
tmp="agent-sandbox-build-$$"
"$container_engine" build --target "$agent" -t "$tmp" \
  --build-arg "TRUST_STAGE=$trust_stage" \
  --build-arg "BASE_IMAGE=$base_image" \
  --build-arg "AGENT_VERSION=$version" \
  --build-arg "AGENT_UID=$uid" \
  --build-arg "AGENT_GID=$gid" \
  --build-arg "EXTRA_PACKAGES=$packages" "$build_context"

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
"$container_engine" build --target "$agent" -t "$tmp" \
  --build-arg "TRUST_STAGE=$trust_stage" \
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
  --label "org.agent-sandbox.built-at=$created" "$build_context"

check=$(read_agent_version "$agent" "$tmp")
[ "$check" = "$reported" ] || die "final image version $check does not match expected $reported"
# Publish the local versioned tag only after verifying the final image exactly.
"$container_engine" tag "$tmp" "$tag"
echo "Built $tag"

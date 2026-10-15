#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")" && pwd)
. "$root/lib.sh"
command -v openssl > /dev/null 2>&1 || die "CA tests require OpenSSL"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/agent-sandbox-ca-test.XXXXXX")
server_pid=''
fixture_image=''
context=''

cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid"
    wait "$server_pid" 2> /dev/null || true
  fi
  if [ -n "$fixture_image" ]; then
    "$container_engine" image rm "$fixture_image" > /dev/null
  fi
  if [ -n "$context" ]; then
    rm -f "$context/ca-certificates/ca-1.crt" "$context/Dockerfile" "$context/.dockerignore"
    rmdir "$context/ca-certificates" "$context"
  fi
  for file in "$tmp"/*; do
    [ ! -f "$file" ] || rm -f "$file"
  done
  rmdir "$tmp"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cat > "$tmp/ca.conf" << 'EOF'
[req]
distinguished_name = name
x509_extensions = ca
prompt = no
[name]
CN = Agent Sandbox disposable test CA
[ca]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -config "$tmp/ca.conf" -keyout "$tmp/ca.key" -out "$tmp/ca.pem" > /dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -config "$tmp/ca.conf" -keyout "$tmp/other.key" -out "$tmp/other.pem" > /dev/null 2>&1

cat > "$tmp/server.conf" << 'EOF'
[req]
distinguished_name = name
prompt = no
[name]
CN = localhost
[server]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost,IP:127.0.0.1
EOF
openssl req -new -newkey rsa:2048 -nodes -config "$tmp/server.conf" \
  -keyout "$tmp/server.key" -out "$tmp/server.csr" > /dev/null 2>&1
openssl x509 -req -in "$tmp/server.csr" -CA "$tmp/ca.pem" -CAkey "$tmp/ca.key" \
  -set_serial 2 -days 1 -extfile "$tmp/server.conf" -extensions server \
  -out "$tmp/server.pem" > /dev/null 2>&1

expect_failure() {
  local message=$1
  local output
  shift
  if output=$("$@" 2>&1); then
    die "expected failure: $*"
  fi
  case "$output" in
    *"$message"*)
      ;;
    *)
      die "unexpected failure: $output"
      ;;
  esac
}

validate_ca_cert "$tmp/ca.pem"
expect_failure "not a CA" validate_ca_cert "$tmp/server.pem"
expect_failure "readable, nonempty regular file" validate_ca_cert "$tmp/missing"
expect_failure "readable, nonempty regular file" validate_ca_cert "$tmp"
: > "$tmp/empty.pem"
expect_failure "readable, nonempty regular file" validate_ca_cert "$tmp/empty.pem"
expect_failure "exactly one PEM certificate" validate_ca_cert "$tmp/ca.key"
cat "$tmp/ca.pem" "$tmp/ca.key" > "$tmp/mixed.pem"
expect_failure "exactly one PEM certificate" validate_ca_cert "$tmp/mixed.pem"
cat "$tmp/ca.pem" "$tmp/other.pem" > "$tmp/bundle.pem"
expect_failure "exactly one PEM certificate" validate_ca_cert "$tmp/bundle.pem"
printf '%s\n' '-----BEGIN CERTIFICATE-----' 'invalid' '-----END CERTIFICATE-----' > "$tmp/invalid.pem"
expect_failure "invalid X.509" validate_ca_cert "$tmp/invalid.pem"

# Inspect the actual staged context in both build passes, without a container engine.
cat > "$tmp/docker" << 'EOF'
#!/bin/bash
set -euo pipefail

case "$1" in
  build)
    for arg in "$@"; do
      context=$arg
    done
    [ "$context" != . ]
    [ -f "$context/Dockerfile" ]
    [ -f "$context/.dockerignore" ]
    [ "$(find "$context" -type f | wc -l | tr -d ' ')" = 4 ]
    cmp "$context/ca-certificates/ca-1.crt" "$TEST_CA_ONE"
    cmp "$context/ca-certificates/ca-2.crt" "$TEST_CA_TWO"
    printf '%s\n' "$context" >> "$TEST_CONTEXT_LOG"
    if [ "${TEST_FAIL_BUILD:-false}" = true ]; then
      echo "simulated build failure" >&2
      exit 1
    fi
    case "$*" in
      *TRUST_STAGE=custom-ca*)
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  run)
    printf 'codex-cli 1.2.3\n'
    ;;
  tag | image)
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$tmp/docker"
for engine in docker podman; do
  [ "$engine" = docker ] || cp "$tmp/docker" "$tmp/podman"
  cp "$tmp/ca.pem" "$tmp/CA with spaces.pem"
  TEST_CA_ONE="$tmp/ca.pem" \
    TEST_CA_TWO="$tmp/other.pem" \
    TEST_CONTEXT_LOG="$tmp/context.log" \
    PATH="$tmp:$PATH" \
    CONTAINER_ENGINE="$engine" \
    "$root/build.sh" --agent codex --no-pull --ca-cert "$tmp/ca.pem" \
    --ca-cert "$tmp/other.pem" > "$tmp/build.log"
done
[ "$(wc -l < "$tmp/context.log" | tr -d ' ')" = 4 ]
TEST_CA_ONE="$tmp/ca.pem" \
  TEST_CA_TWO="$tmp/other.pem" \
  TEST_CONTEXT_LOG="$tmp/context.log" \
  TEST_FAIL_BUILD=true \
  PATH="$tmp:$PATH" \
  CONTAINER_ENGINE=docker \
  expect_failure "simulated build failure" "$root/build.sh" --agent codex --no-pull \
  --ca-cert "$tmp/ca.pem" --ca-cert "$tmp/other.pem"
(
  cd "$tmp"
  TEST_CA_ONE="$tmp/ca.pem" \
    TEST_CA_TWO="$tmp/other.pem" \
    TEST_CONTEXT_LOG="$tmp/context.log" \
    PATH="$tmp:$PATH" \
    CONTAINER_ENGINE=docker \
    "$root/build.sh" --agent codex --no-pull --ca-cert 'CA with spaces.pem' \
    --ca-cert other.pem > "$tmp/build.log"
)
while IFS= read -r staged_context; do
  [ ! -e "$staged_context" ] || die "temporary CA context was not cleaned"
done < "$tmp/context.log"
expect_failure "--ca-cert requires a value" "$root/build.sh" --agent codex --ca-cert
expect_failure "exactly one PEM certificate" "$root/build.sh" --agent codex --ca-cert "$tmp/mixed.pem"
printf 'ok - CA validation and minimal Docker/Podman build contexts\n'

if [ "${1:-}" != --integration ]; then
  [ "$#" -eq 0 ] || die "unknown CA test argument: $1"
  exit 0
fi
[ "$#" -eq 1 ] || die "unexpected CA integration arguments"

# Use the real engine, not the temporary stand-ins.
select_container_engine
fixture_image="agent-sandbox-ca-test:$$"
context=$(mktemp -d "${TMPDIR:-/tmp}/agent-sandbox-ca-context.XXXXXX")
mkdir "$context/ca-certificates"
cp "$root/Dockerfile" "$context/Dockerfile"
cp "$tmp/ca.pem" "$context/ca-certificates/ca-1.crt"
printf '%s\n' '**' '!Dockerfile' '!ca-certificates/' '!ca-certificates/*.crt' > "$context/.dockerignore"

# A random loopback port avoids publishing the test service on the LAN.
command -v python3 > /dev/null 2>&1 || die "CA integration tests require Python 3"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
openssl s_server -accept "127.0.0.1:$port" -cert "$tmp/server.pem" \
  -key "$tmp/server.key" -www > "$tmp/server.log" 2>&1 &
server_pid=$!
for _ in 1 2 3 4 5; do
  if python3 -c 'import socket,sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 1).close()' "$port" 2> /dev/null; then
    break
  fi
  sleep 1
done
kill -0 "$server_pid"
python3 -c 'import socket,sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 1).close()' "$port"

check_https() {
  # Shell/Node variables below are evaluated inside the container, not on the host.
  # shellcheck disable=SC2016
  "$container_engine" run --rm --network host "$fixture_image" \
    /bin/bash -ec '
      test "$(id -un)" = agent
      curl_status=0
      curl --noproxy "*" --fail --silent --show-error "$1" >/dev/null || curl_status=$?
      if [ "$2" = trusted ]; then
        test "$curl_status" -eq 0
      else
        test "$curl_status" -eq 60
      fi
      HTTPS_PROXY= HTTP_PROXY= ALL_PROXY= node -e '\''
        require("https").get(process.argv[1], res => {
          res.resume();
          res.on("end", () => process.exit(
            process.argv[2] === "trusted" && res.statusCode === 200 ? 0 : 1));
        }).on("error", err => {
          console.error(err.message);
          process.exit(process.argv[2] === "untrusted" &&
            /CERT|SELF_SIGNED|UNABLE_TO_VERIFY/.test(err.code) ? 0 : 1);
        });
      '\'' "$1" "$2"
    ' bash "https://127.0.0.1:$port" "$1"
}

build_trust_image() {
  if ! "$container_engine" build --target common --build-arg "TRUST_STAGE=$1" \
    -t "$fixture_image" "$context" > "$tmp/image-build.log" 2>&1; then
    cat "$tmp/image-build.log" >&2
    die "CA integration image build failed"
  fi
}

build_trust_image base
check_https untrusted
build_trust_image custom-ca
check_https trusted
cp "$tmp/other.pem" "$context/ca-certificates/ca-1.crt"
build_trust_image custom-ca
check_https untrusted
printf 'ok - system and Node HTTPS trust, non-root access, and CA cache invalidation\n'

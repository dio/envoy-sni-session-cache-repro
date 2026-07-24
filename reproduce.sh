#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 /path/to/upstream-envoy /path/to/candidate-envoy" >&2
  exit 2
fi

UPSTREAM_BIN=$(realpath "$1")
CANDIDATE_BIN=$(realpath "$2")
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK_DIR=$(mktemp -d /tmp/envoy-sni-cache-repro.XXXXXX)
PIDS=()

cleanup() {
  status=$?
  trap - EXIT INT TERM
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in "${PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  if [[ "${KEEP_WORKDIR:-0}" == "1" ]]; then
    echo "work directory retained at $WORK_DIR"
  elif [[ "$WORK_DIR" == /tmp/envoy-sni-cache-repro.* ]]; then
    rm -r -- "$WORK_DIR"
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

for command in curl grep openssl python3 realpath sed tail; do
  command -v "$command" >/dev/null || {
    echo "required command not found: $command" >&2
    exit 2
  }
done

for binary in "$UPSTREAM_BIN" "$CANDIDATE_BIN"; do
  if [[ ! -x "$binary" ]]; then
    echo "Envoy binary is not executable: $binary" >&2
    exit 2
  fi
done

mkdir -p "$WORK_DIR/certs" "$WORK_DIR/config" "$WORK_DIR/logs"

openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
  -subj "/CN=Envoy SNI Repro CA" \
  -keyout "$WORK_DIR/certs/ca-key.pem" \
  -out "$WORK_DIR/certs/ca-cert.pem" >/dev/null 2>&1

for number in 1 2; do
  hostname="server${number}.example.com"
  openssl req -newkey rsa:2048 -nodes -sha256 \
    -subj "/CN=$hostname" \
    -keyout "$WORK_DIR/certs/server${number}-key.pem" \
    -out "$WORK_DIR/certs/server${number}.csr" >/dev/null 2>&1

  serial_args=(-CAserial "$WORK_DIR/certs/ca-cert.srl")
  if [[ ! -f "$WORK_DIR/certs/ca-cert.srl" ]]; then
    serial_args=(-CAcreateserial)
  fi

  openssl x509 -req -sha256 -days 1 \
    -in "$WORK_DIR/certs/server${number}.csr" \
    -CA "$WORK_DIR/certs/ca-cert.pem" \
    -CAkey "$WORK_DIR/certs/ca-key.pem" \
    "${serial_args[@]}" \
    -extfile <(
      printf '%s\n' \
        "subjectAltName=DNS:$hostname" \
        "extendedKeyUsage=serverAuth" \
        "keyUsage=digitalSignature,keyEncipherment"
    ) \
    -out "$WORK_DIR/certs/server${number}-cert.pem" >/dev/null 2>&1
done

render_config() {
  local proxy_port=$1
  local output=$2
  sed \
    -e "s|@WORKDIR@|$WORK_DIR|g" \
    -e "s|@PROXY_PORT@|$proxy_port|g" \
    "$REPO_DIR/config/proxy.yaml.in" >"$output"
}

render_config 10001 "$WORK_DIR/config/proxy-upstream.yaml"
render_config 10000 "$WORK_DIR/config/proxy-candidate.yaml"

"$UPSTREAM_BIN" --mode validate \
  --config-path "$WORK_DIR/config/proxy-upstream.yaml" \
  --log-level error
"$CANDIDATE_BIN" --mode validate \
  --config-path "$WORK_DIR/config/proxy-candidate.yaml" \
  --log-level error

python3 "$REPO_DIR/dns_server.py" --port 1053 >"$WORK_DIR/logs/dns.log" 2>&1 &
PIDS+=("$!")

openssl s_server \
  -accept 127.0.0.1:9443 \
  -tls1_2 \
  -cert "$WORK_DIR/certs/server1-cert.pem" \
  -key "$WORK_DIR/certs/server1-key.pem" \
  -cert2 "$WORK_DIR/certs/server2-cert.pem" \
  -key2 "$WORK_DIR/certs/server2-key.pem" \
  -servername server2.example.com \
  -context envoy-cross-sni \
  -www >"$WORK_DIR/logs/tls-server.log" 2>&1 &
PIDS+=("$!")

"$UPSTREAM_BIN" --disable-hot-restart \
  --config-path "$WORK_DIR/config/proxy-upstream.yaml" \
  --log-level debug >"$WORK_DIR/logs/proxy-upstream.log" 2>&1 &
PIDS+=("$!")

"$CANDIDATE_BIN" --disable-hot-restart \
  --config-path "$WORK_DIR/config/proxy-candidate.yaml" \
  --log-level debug >"$WORK_DIR/logs/proxy-candidate.log" 2>&1 &
PIDS+=("$!")

sleep 2
for pid in "${PIDS[@]}"; do
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "a validation process failed to start; logs follow" >&2
    tail -n 80 "$WORK_DIR"/logs/*.log >&2
    exit 1
  fi
done

request() {
  local proxy_port=$1
  local hostname=$2
  local output=$3
  curl --noproxy "*" --silent --show-error \
    --output "$output" \
    --write-out "%{http_code}" \
    --header "Host: $hostname:9443" \
    "http://127.0.0.1:$proxy_port/"
}

upstream_a=$(request 10001 server1.example.com "$WORK_DIR/upstream-a.body")
upstream_b=$(request 10001 server2.example.com "$WORK_DIR/upstream-b.body")
candidate_a=$(request 10000 server1.example.com "$WORK_DIR/candidate-a.body")
candidate_b=$(request 10000 server2.example.com "$WORK_DIR/candidate-b.body")

printf 'upstream:  server1=%s server2=%s\n' "$upstream_a" "$upstream_b"
printf 'candidate: server1=%s server2=%s\n' "$candidate_a" "$candidate_b"

if [[ "$upstream_a" != "200" || "$upstream_b" != "503" ]]; then
  echo "upstream did not reproduce the expected cross-SNI failure" >&2
  tail -n 80 "$WORK_DIR/logs/proxy-upstream.log" >&2
  exit 1
fi

if [[ "$candidate_a" != "200" || "$candidate_b" != "200" ]]; then
  echo "candidate did not keep both host requests successful" >&2
  tail -n 80 "$WORK_DIR/logs/proxy-candidate.log" >&2
  exit 1
fi

if ! grep -q "CERTIFICATE_VERIFY_FAILED" "$WORK_DIR/logs/proxy-upstream.log"; then
  echo "upstream request failed, but the expected certificate error was absent" >&2
  exit 1
fi

echo "PASS: upstream reproduces #46243 and the candidate prevents it"

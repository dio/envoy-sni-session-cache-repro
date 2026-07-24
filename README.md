# Envoy cross-SNI TLS session cache reproducer

This repository reproduces
[envoyproxy/envoy#46243](https://github.com/envoyproxy/envoy/issues/46243)
and verifies the fix proposed in
[envoyproxy/envoy#45982](https://github.com/envoyproxy/envoy/pull/45982).

The test makes two requests through an Envoy dynamic forward proxy:

1. `server1.example.com`, which seeds the upstream TLS session cache.
2. `server2.example.com`, which resolves to the same IP address but presents a
   different certificate.

The affected upstream binary incorrectly offers the first hostname's cached
session to the second hostname. The server accepts it, and certificate
validation then sees the `server1.example.com` certificate while expecting
`server2.example.com`.

The candidate binary scopes cached sessions by SNI. It performs a full
handshake for the second hostname and receives the correct certificate.

## Verified versions

| Role | Envoy commit | Expected result |
| --- | --- | --- |
| Affected upstream baseline | `8cac4c63` | `server1=200 server2=503` |
| PR candidate | `f5ed8537` | `server1=200 server2=200` |

The upstream commit is the exact Envoy main commit merged into the PR branch,
so the comparison isolates the PR changes.

- Upstream: `8cac4c63e8a905baa1f53020dd69f5914777a506`
- Candidate: `f5ed853725477db07c606a44a0cebce57ea8d1ed`

## Requirements

- macOS arm64 or Linux amd64
- Bash
- Python 3
- OpenSSL
- curl
- `realpath`

Both Envoy binaries must target the platform where the script is run.

## Download the binaries

> [!CAUTION]
> The candidate binaries are unofficial test artifacts downloaded from the
> internet. Do not use them in production. Verify the archive checksum before
> extracting it, inspect its contents, and run it only in an isolated test
> environment. Building the candidate yourself from the PR commit provides
> the strongest assurance.

The upstream baseline is the official Tetrate Envoy dev archive. The candidate
is an unofficial, one-off validation build attached to this repository's
[`pr45982-f5ed8537` release](https://github.com/dio/envoy-sni-session-cache-repro/releases/tag/pr45982-f5ed8537).

### macOS arm64

```sh
mkdir -p binaries

curl -fL \
  https://archive.tetratelabs.io/envoy/download/dev/envoy-dev-darwin-arm64.tar.xz \
  -o binaries/envoy-dev-darwin-arm64.tar.xz

curl -fL \
  https://github.com/dio/envoy-sni-session-cache-repro/releases/download/pr45982-f5ed8537/envoy-pr45982-f5ed8537-darwin-arm64.tar.xz \
  -o binaries/envoy-pr45982-f5ed8537-darwin-arm64.tar.xz
curl -fL \
  https://github.com/dio/envoy-sni-session-cache-repro/releases/download/pr45982-f5ed8537/SHA256SUMS \
  -o binaries/SHA256SUMS

(
  cd binaries
  grep 'darwin-arm64' SHA256SUMS | shasum -a 256 -c -
  tar -tJf envoy-pr45982-f5ed8537-darwin-arm64.tar.xz
)

tar -xJf binaries/envoy-dev-darwin-arm64.tar.xz -C binaries
tar -xJf binaries/envoy-pr45982-f5ed8537-darwin-arm64.tar.xz -C binaries
chmod +x binaries/envoy-dev-darwin-arm64/bin/envoy
chmod +x binaries/envoy-pr45982-f5ed8537-darwin-arm64/bin/envoy
```

### Linux amd64

```sh
mkdir -p binaries

curl -fL \
  https://archive.tetratelabs.io/envoy/download/dev/envoy-dev-linux-amd64.tar.xz \
  -o binaries/envoy-dev-linux-amd64.tar.xz

curl -fL \
  https://github.com/dio/envoy-sni-session-cache-repro/releases/download/pr45982-f5ed8537/envoy-pr45982-f5ed8537-linux-amd64.tar.xz \
  -o binaries/envoy-pr45982-f5ed8537-linux-amd64.tar.xz
curl -fL \
  https://github.com/dio/envoy-sni-session-cache-repro/releases/download/pr45982-f5ed8537/SHA256SUMS \
  -o binaries/SHA256SUMS

(
  cd binaries
  grep 'linux-amd64' SHA256SUMS | sha256sum -c -
  tar -tJf envoy-pr45982-f5ed8537-linux-amd64.tar.xz
)

tar -xJf binaries/envoy-dev-linux-amd64.tar.xz -C binaries
tar -xJf binaries/envoy-pr45982-f5ed8537-linux-amd64.tar.xz -C binaries
chmod +x binaries/envoy-dev-linux-amd64/bin/envoy
chmod +x binaries/envoy-pr45982-f5ed8537-linux-amd64/bin/envoy
```

The candidate archives also contain Envoy's `LICENSE`, `NOTICE`, and build
metadata. They are test artifacts, not official Envoy releases.

Checksums detect an incomplete or mismatched download. Because the checksum
file is distributed with the release, it is not a substitute for independently
building and reviewing the source when stronger provenance is required.

## Run the comparison

On macOS arm64:

```sh
./reproduce.sh \
  binaries/envoy-dev-darwin-arm64/bin/envoy \
  binaries/envoy-pr45982-f5ed8537-darwin-arm64/bin/envoy
```

On Linux amd64, replace both `darwin-arm64` path components with
`linux-amd64`.

Expected output:

```text
upstream:  server1=200 server2=503
candidate: server1=200 server2=200
PASS: upstream reproduces #46243 and the candidate prevents it
```

The upstream `503` is intentional. The script also checks the upstream debug
log for `CERTIFICATE_VERIFY_FAILED`; a different failure does not count as a
successful reproduction.

## How the test works

- A small local DNS server resolves both hostnames to `127.0.0.1`.
- The script generates a temporary CA and distinct certificates for the two
  hostnames.
- One OpenSSL TLS 1.2 server selects certificates by SNI while sharing its TLS
  session context across both names.
- The upstream and candidate Envoy processes use configuration rendered from
  the same [template](config/proxy.yaml.in). Only their listener ports differ
  so both can run concurrently.
- The TLS server closes each HTTP response, forcing the next request to create
  a new TLS connection where session resumption can occur.

Everything listens on loopback. The script does not modify `/etc/hosts` or use
external DNS. Temporary files are deleted after a successful run.

Set `KEEP_WORKDIR=1` to retain generated certificates, rendered
configurations, response bodies, and Envoy logs:

```sh
KEEP_WORKDIR=1 ./reproduce.sh /path/to/upstream-envoy /path/to/candidate-envoy
```

## Scope

This is a focused regression reproducer for TLS 1.2 session resumption across
SNI names in an Envoy dynamic forward proxy cluster. It is not a general TLS
interoperability or performance test.

#!/usr/bin/env bash
# run_e2e.sh — APISIX plugin e2e total entry
#
# Scenario 1: PHP Yar → APISIX (yar2grpc) → Go gRPC
# Scenario 2: Go gRPC → APISIX (grpc2yar) → PHP Yar
#
# All runtime artifacts in .run/ directory.
set -euo pipefail

D="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$D/../.." && pwd)"
RUN="$D/.run"
LOG="$RUN/logs"
BIN="$RUN/bin"
mkdir -p "$RUN" "$LOG" "$BIN"

# e2e ports
export E2E_PORT_PHP="${E2E_PORT_PHP:-8888}"
export E2E_PORT_APISIX_GRPC2YAR="${E2E_PORT_APISIX_GRPC2YAR:-1994}"
export E2E_PORT_APISIX_YAR2GRPC="${E2E_PORT_APISIX_YAR2GRPC:-1995}"
export E2E_PORT_GO_GRPC="${E2E_PORT_GO_GRPC:-50051}"
export E2E_PORT_GO_HTTP="${E2E_PORT_GO_HTTP:-50052}"

C() { printf '\033[0;36m[apisix-e2e]\033[0m %s\n' "$1"; }
P() { printf '\033[0;32m[PASS]\033[0m %s\n' "$1"; }
F() { printf '\033[0;31m[FAIL]\033[0m %s\n' "$1"; exit 1; }

# ── Dependency checks ──
C "checking deps..."
command -v apisix >/dev/null || F "apisix not found"
command -v php >/dev/null || F "php not found"
php -m 2>/dev/null | grep -qx "yar" \
    || F "php-yar ext missing (install: pecl install yar)"
php -m 2>/dev/null | grep -qx "msgpack" \
    || F "php-msgpack ext missing (required for msgpack scenario)"

# Assertions must be live: with zend.assertions=-1 PHP compiles assert()
# out entirely, so the Yar client's result checks would silently no-op
# and e2e would pass without verifying anything.
php -r 'exit(ini_get("zend.assertions") === "1" ? 0 : 1);' \
    || F "zend.assertions != 1 (assert() would be a no-op; set zend.assertions=1)"
php -r 'try { assert(false); exit(1); } catch (AssertionError $e) { exit(0); }' \
    || F "assert(false) did not throw AssertionError (assertions ineffective)"

# ── Dependency versions ──
C "dependency versions:"
apisix version 2>&1 | head -1
php -v 2>/dev/null | head -1
php -r 'echo "zend.assertions=" . ini_get("zend.assertions") . ", assert.exception=" . ini_get("assert.exception") . "\n";'

# ── proto generation (skipped when pre-built in Docker image) ──
if [ ! -f "$D/proto/calculator.pb" ]; then
    command -v protoc >/dev/null || F "protoc not found (needed for proto generation)"
    C "generating proto..."
    bash "$D/proto/gen.sh"
fi

# ── Go compilation (skipped when pre-built in Docker image) ──
if [ ! -f "$BIN/grpc_server" ] || [ ! -f "$BIN/grpc_client" ]; then
    command -v go >/dev/null || F "go not found (needed for building grpc binaries)"
    C "building Go binaries -> $BIN/ ..."
    cd "$D/go"
    go build -buildvcs=false -o "$BIN/grpc_server" ./grpc_server || F "server build failed"
    go build -buildvcs=false -o "$BIN/grpc_client" ./grpc_client || F "client build failed"
    cd "$ROOT"
fi

# ── Loop over both YAR packagers ──
for PACKAGER in json msgpack; do
    export YAR_PACKAGER="$PACKAGER"

    echo ""
    C "=== Scenario 2: Go gRPC → APISIX → PHP Yar ($PACKAGER) ==="
    bash "$D/scenario2_grpc2yar.sh"

    echo ""
    C "=== Scenario 1: PHP Yar → APISIX → Go gRPC ($PACKAGER) ==="
    bash "$D/scenario1_yar2grpc.sh"
done

echo ""
P "All APISIX plugin e2e tests completed."
echo "  logs:      $LOG/"
echo "  binaries:  $BIN/"

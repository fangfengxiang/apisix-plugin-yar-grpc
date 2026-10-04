#!/usr/bin/env bash
# run_e2e.sh — APISIX plugin e2e total entry
#
# Responsibility: dep checks + proto gen + Go compile → start scenarios
#
# Scenario 1: PHP Yar → APISIX (yar2grpc) → Go gRPC
# Scenario 2: Go gRPC → APISIX (grpc2yar) → PHP Yar
#
# All runtime artifacts in .run/ directory.
set -euo pipefail

D="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$D/../.." && pwd)"
OR="${OPENRESTY_PREFIX:-/usr/local/openresty}"
NGINX="$OR/nginx/sbin/nginx"
RUN="$D/.run"
LOG="$RUN/logs"
BIN="$RUN/bin"
BRIDGE_LIB="${BRIDGE_LIB:-$(cd "$ROOT/../lua-resty-yar-grpc-bridge/lib" 2>/dev/null && pwd || echo "/bridge/lib")}"
export BRIDGE_LIB
mkdir -p "$RUN" "$LOG" "$BIN"

# e2e ports (different from Kong plugin e2e to allow parallel runs)
export E2E_PORT_PHP="${E2E_PORT_PHP:-8888}"
export E2E_PORT_APISIX_GRPC2YAR="${E2E_PORT_APISIX_GRPC2YAR:-1994}"
export E2E_PORT_APISIX_YAR2GRPC="${E2E_PORT_APISIX_YAR2GRPC:-1995}"
export E2E_PORT_GO_GRPC="${E2E_PORT_GO_GRPC:-50051}"
export E2E_PORT_GO_HTTP="${E2E_PORT_GO_HTTP:-50052}"

C() { printf '\033[0;36m[apisix-e2e]\033[0m %s\n' "$1"; }
P() { printf '\033[0;32m[PASS]\033[0m %s\n' "$1"; }
F() { printf '\033[0;31m[FAIL]\033[0m %s\n' "$1"; exit 1; }

# ── Dependency checks (strict) ──
C "checking deps (strict)..."
[ -x "$NGINX" ] || F "OpenResty not found at $NGINX"
command -v php >/dev/null || F "php not found"
command -v go >/dev/null || F "go not found"
command -v protoc >/dev/null || F "protoc not found"
php -m 2>/dev/null | grep -qx "yar" \
    || F "php-yar ext missing (install: pecl install yar -- --enable-msgpack)"
php -m 2>/dev/null | grep -qx "msgpack" \
    || F "php-msgpack ext missing (required for msgpack scenario)"

# ── Dependency versions ──
C "dependency versions:"
"$NGINX" -v 2>&1 | head -1
php -v 2>/dev/null | head -1
go version
protoc --version

# ── proto generation ──
C "generating proto..."
bash "$D/proto/gen.sh"

# ── Go compilation ──
C "building Go binaries -> $BIN/ ..."
cd "$D/go"
go build -buildvcs=false -o "$BIN/grpc_server" ./grpc_server || F "server build failed"
go build -buildvcs=false -o "$BIN/grpc_client" ./grpc_client || F "client build failed"

# ── Loop over both YAR packagers ──
for PACKAGER in json msgpack; do
    export YAR_PACKAGER="$PACKAGER"

    # Scenario 2: Go gRPC → APISIX → PHP Yar
    echo ""
    C "=== Scenario 2: Go gRPC → APISIX → PHP Yar ($PACKAGER) ==="
    bash "$D/scenario2_grpc2yar.sh"

    # Scenario 1: PHP Yar → APISIX → Go gRPC
    echo ""
    C "=== Scenario 1: PHP Yar → APISIX → Go gRPC ($PACKAGER) ==="
    bash "$D/scenario1_yar2grpc.sh"
done

echo ""
P "All APISIX plugin e2e tests completed."
echo "  logs:      $LOG/"
echo "  binaries:  $BIN/"

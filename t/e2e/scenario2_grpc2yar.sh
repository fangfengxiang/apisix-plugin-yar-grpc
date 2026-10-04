#!/usr/bin/env bash
# scenario2_grpc2yar.sh — Scenario 2: Go gRPC → APISIX (grpc2yar) → PHP Yar
set -euo pipefail

D="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$D/../.." && pwd)"
RUN="$D/.run"
LOG="$RUN/logs"
BIN="$RUN/bin"
PACKAGER="${YAR_PACKAGER:-json}"
APISIX_CONF="/usr/local/apisix/conf"
mkdir -p "$RUN" "$LOG" "$BIN"

C() { printf '\033[0;36m[apisix-e2e-s2/%s]\033[0m %s\n' "$PACKAGER" "$1"; }
P() { printf '\033[0;32m[PASS]\033[0m %s\n' "$1"; }
F() { printf '\033[0;31m[FAIL]\033[0m %s\n' "$1"; exit 1; }

cleanup() {
    C "cleaning up scenario 2..."
    [ -f "$RUN/php_s2_${PACKAGER}.pid" ] && kill "$(cat "$RUN/php_s2_${PACKAGER}.pid")" 2>/dev/null || true
    apisix stop 2>/dev/null || true
    sleep 1
}
trap cleanup EXIT

# ── Dep checks ──
command -v apisix >/dev/null || F "apisix not found"
command -v php >/dev/null || F "php not found"
[ -f "$BIN/grpc_client" ] || F "grpc_client not built (run run_e2e.sh first)"

# ── Generate APISIX config + routes ──
C "preparing APISIX config (port=${E2E_PORT_APISIX_GRPC2YAR}, http2=true, packager=$PACKAGER)..."
sed -e "s|@PORT@|${E2E_PORT_APISIX_GRPC2YAR}|g" \
    -e "s|@HTTP2@|true|g" \
    "$D/conf/config.yaml" > "$APISIX_CONF/config.yaml"

sed -e "s|@PHP_PORT@|${E2E_PORT_PHP}|g" \
    -e "s|@PACKAGER@|${PACKAGER}|g" \
    "$D/conf/apisix_grpc2yar.yaml" > "$APISIX_CONF/apisix.yaml"

# ── Start PHP Yar server ──
C "starting PHP Yar server (port ${E2E_PORT_PHP}, packager=$PACKAGER)..."
php -d yar.packager="$PACKAGER" -S 127.0.0.1:${E2E_PORT_PHP} -t "$D/php/yar_server" >"$LOG/php_s2_${PACKAGER}.log" 2>&1 &
echo $! > "$RUN/php_s2_${PACKAGER}.pid"

# ── Start APISIX (standalone, grpc2yar route) ──
C "starting APISIX (grpc2yar, port ${E2E_PORT_APISIX_GRPC2YAR})..."
apisix init 2>&1 | tail -1
apisix start 2>&1 | tail -1

# ── Readiness probe: poll PHP server then APISIX port instead of fixed sleep ──
READY=0
for _ in $(seq 1 30); do
    if curl -s -o /dev/null "http://127.0.0.1:${E2E_PORT_PHP}/api.php"; then
        READY=1
        break
    fi
    sleep 0.5
done
[ "$READY" = "1" ] || F "PHP Yar server not ready on 127.0.0.1:${E2E_PORT_PHP} after 15s"

READY=0
for _ in $(seq 1 30); do
    if curl -s -o /dev/null "http://127.0.0.1:${E2E_PORT_APISIX_GRPC2YAR}/probe"; then
        READY=1
        break
    fi
    sleep 0.5
done
[ "$READY" = "1" ] || F "APISIX not ready on 127.0.0.1:${E2E_PORT_APISIX_GRPC2YAR} after 15s"

# ── Run Go gRPC client ──
C "running Go gRPC client..."
OUT="$LOG/s2_${PACKAGER}_result.log"
if "$BIN/grpc_client" -addr 127.0.0.1:${E2E_PORT_APISIX_GRPC2YAR} 2>&1 | tee "$OUT"; then
    if grep -q "Add: PASS" "$OUT" && grep -q "Subtract: PASS" "$OUT"; then
        P "Scenario 2 ($PACKAGER): PASS"
    else
        F "Scenario 2 ($PACKAGER): FAIL (assertion markers not found in output)"
    fi
else
    F "Scenario 2 ($PACKAGER): FAIL (client exited non-zero)"
fi

# ── Error path: registered service + unregistered method → grpc-status 3 ──
# 已实测：HTTP/2 200 + grpc-status: 3 (INVALID_ARGUMENT) trailer
# 注意必须走已注册服务 + 未注册方法；未注册服务路径命中的是 APISIX 路由 404，不是插件
C "checking unregistered gRPC method path..."
printf '\x00\x00\x00\x00\x00' > "$RUN/empty_frame.bin"
GRPC_HDRS=$(curl -s --http2-prior-knowledge -o /dev/null -D - -X POST \
    -H "Content-Type: application/grpc" -H "TE: trailers" \
    --data-binary @"$RUN/empty_frame.bin" \
    "http://127.0.0.1:${E2E_PORT_APISIX_GRPC2YAR}/calculator.Calculator/Nonexistent" | tr -d '\r')
if echo "$GRPC_HDRS" | grep -q "grpc-status: 3"; then
    P "unregistered gRPC method: PASS (grpc-status 3 INVALID_ARGUMENT)"
else
    F "unregistered gRPC method: FAIL (expected grpc-status 3, got: $GRPC_HDRS)"
fi

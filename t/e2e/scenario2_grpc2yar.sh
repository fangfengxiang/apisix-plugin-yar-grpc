#!/usr/bin/env bash
# scenario2_grpc2yar.sh — Scenario 2: Go gRPC → APISIX (grpc2yar) → PHP Yar
#
# Starts PHP Yar server + OpenResty (with APISIX plugin), runs Go gRPC client.
set -euo pipefail

D="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$D/../.." && pwd)"
OR="${OPENRESTY_PREFIX:-/usr/local/openresty}"
NGINX="$OR/nginx/sbin/nginx"
RUN="$D/.run"
LOG="$RUN/logs"
BIN="$RUN/bin"
PACKAGER="${YAR_PACKAGER:-json}"
mkdir -p "$RUN" "$LOG" "$BIN"

C() { printf '\033[0;36m[apisix-e2e-s2/%s]\033[0m %s\n' "$PACKAGER" "$1"; }
P() { printf '\033[0;32m[PASS]\033[0m %s\n' "$1"; }
F() { printf '\033[0;31m[FAIL]\033[0m %s\n' "$1"; exit 1; }

cleanup() {
    C "cleaning up scenario 2..."
    [ -f "$RUN/php_s2_${PACKAGER}.pid" ] && kill "$(cat "$RUN/php_s2_${PACKAGER}.pid")" 2>/dev/null || true
    [ -f "$RUN/nginx_grpc2yar_${PACKAGER}.conf" ] && "$NGINX" -c "$RUN/nginx_grpc2yar_${PACKAGER}.conf" -s stop 2>/dev/null || true
    sleep 1
}
trap cleanup EXIT

# ── Dep checks ──
[ -x "$NGINX" ] || F "OpenResty not found at $NGINX"
command -v php >/dev/null || F "php not found"
[ -f "$BIN/grpc_client" ] || F "grpc_client not built (run run_e2e.sh first)"

# ── Generate nginx conf ──
C "preparing nginx config (packager=$PACKAGER)..."
sed -e "s|@RUN@|$RUN|g" -e "s|@PREFIX@|$ROOT|g" -e "s|@PACKAGER@|$PACKAGER|g" \
    -e "s|@PORT_APISIX_GRPC2YAR@|$E2E_PORT_APISIX_GRPC2YAR|g" \
    -e "s|@PORT_PHP@|$E2E_PORT_PHP|g" \
    -e "s|@BRIDGE_LIB@|${BRIDGE_LIB:-/bridge/lib}|g" \
    "$D/nginx_grpc2yar.conf" > "$RUN/nginx_grpc2yar_${PACKAGER}.conf"

# ── Start PHP Yar server ──
C "starting PHP Yar server (port ${E2E_PORT_PHP}, packager=$PACKAGER)..."
php -d yar.packager="$PACKAGER" -S 127.0.0.1:${E2E_PORT_PHP} -t "$D/php/yar_server" >"$LOG/php_s2_${PACKAGER}.log" 2>&1 &
echo $! > "$RUN/php_s2_${PACKAGER}.pid"
sleep 1

# ── Start OpenResty (grpc2yar, port 1994) ──
C "starting OpenResty (grpc2yar, port ${E2E_PORT_APISIX_GRPC2YAR})..."
"$NGINX" -c "$RUN/nginx_grpc2yar_${PACKAGER}.conf" -p "$ROOT" >>"$LOG/nginx_s2_${PACKAGER}.log" 2>&1 &
echo $! > "$RUN/nginx_s2_${PACKAGER}_ng.pid"
sleep 1

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

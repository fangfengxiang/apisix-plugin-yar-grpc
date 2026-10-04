#!/usr/bin/env bash
# scenario1_yar2grpc.sh — Scenario 1: PHP Yar → APISIX (yar2grpc) → Go gRPC
set -euo pipefail

D="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$D/../.." && pwd)"
RUN="$D/.run"
LOG="$RUN/logs"
BIN="$RUN/bin"
PACKAGER="${YAR_PACKAGER:-json}"
APISIX_CONF="/usr/local/apisix/conf"
mkdir -p "$RUN" "$LOG" "$BIN"

C() { printf '\033[0;36m[apisix-e2e-s1/%s]\033[0m %s\n' "$PACKAGER" "$1"; }
P() { printf '\033[0;32m[PASS]\033[0m %s\n' "$1"; }
F() { printf '\033[0;31m[FAIL]\033[0m %s\n' "$1"; exit 1; }

cleanup() {
    C "cleaning up scenario 1..."
    [ -f "$RUN/go_s1_${PACKAGER}.pid" ] && kill "$(cat "$RUN/go_s1_${PACKAGER}.pid")" 2>/dev/null || true
    apisix stop 2>/dev/null || true
    sleep 1
}
trap cleanup EXIT

# ── Dep checks ──
command -v apisix >/dev/null || F "apisix not found"
command -v php >/dev/null || F "php not found"
php -m 2>/dev/null | grep -qx "yar" || C "WARN: php-yar ext missing"
[ -f "$BIN/grpc_server" ] || F "grpc_server not built (run run_e2e.sh first)"

# ── Generate APISIX config + routes ──
C "preparing APISIX config (port=${E2E_PORT_APISIX_YAR2GRPC}, packager=$PACKAGER)..."
sed -e "s|@PORT@|${E2E_PORT_APISIX_YAR2GRPC}|g" \
    -e "s|@HTTP2@|false|g" \
    "$D/conf/config.yaml" > "$APISIX_CONF/config.yaml"

sed -e "s|@GO_HTTP_PORT@|${E2E_PORT_GO_HTTP}|g" \
    "$D/conf/apisix_yar2grpc.yaml" > "$APISIX_CONF/apisix.yaml"

# ── Start Go gRPC server (gRPC :50051, HTTP bridge :50052) ──
C "starting Go gRPC server (gRPC :${E2E_PORT_GO_GRPC}, HTTP bridge :${E2E_PORT_GO_HTTP})..."
"$BIN/grpc_server" -addr 127.0.0.1:${E2E_PORT_GO_GRPC} -http-addr 127.0.0.1:${E2E_PORT_GO_HTTP} >"$LOG/go_s1_${PACKAGER}.log" 2>&1 &
echo $! > "$RUN/go_s1_${PACKAGER}.pid"
sleep 1

# ── Start APISIX (standalone, yar2grpc route) ──
C "starting APISIX (yar2grpc, port ${E2E_PORT_APISIX_YAR2GRPC})..."
apisix init 2>&1 | tail -1
apisix start 2>&1 | tail -1
sleep 2

# ── Run PHP Yar client ──
C "running PHP Yar client (packager=$PACKAGER)..."
OUT="$LOG/s1_${PACKAGER}_result.log"
if php -d yar.packager="$PACKAGER" -d zend.assertions=1 -d assert.exception=1 \
    "$D/php/yar_client/client.php" 2>&1 | tee "$OUT"; then
    if grep -q "Scenario 1.*PASS" "$OUT"; then
        P "Scenario 1 ($PACKAGER): PASS"
    else
        F "Scenario 1 ($PACKAGER): FAIL (assertion markers not found in output)"
    fi
else
    F "Scenario 1 ($PACKAGER): FAIL (client exited non-zero)"
fi

# ── Error path: unregistered service → 404 ──
C "checking 404 path (unregistered service)..."
ERR_FILE="$LOG/s1_${PACKAGER}_404_body.txt"
HTTP_CODE=$(curl -s -o "$ERR_FILE" -w "%{http_code}" -X POST http://127.0.0.1:${E2E_PORT_APISIX_YAR2GRPC}/api/nonexistent.Service)
ERR_BODY="$(cat "$ERR_FILE")"
if [ "$HTTP_CODE" = "404" ] && echo "$ERR_BODY" | grep -q "service not registered: nonexistent.Service"; then
    P "404 path: PASS (unregistered service returns 404 + correct message)"
else
    F "404 path: FAIL (expected 404 + 'service not registered', got $HTTP_CODE: $ERR_BODY)"
fi

# ── Concurrency isolation ──
N_CONC="${N_CONC:-5}"
C "checking concurrency isolation (N=$N_CONC)..."
rm -f "$LOG"/s1_${PACKAGER}_conc_php_*.log "$LOG"/s1_${PACKAGER}_conc_curl_*.log
CONC_PIDS=""
for i in $(seq 1 "$N_CONC"); do
    php -d yar.packager="$PACKAGER" -d zend.assertions=1 -d assert.exception=1 \
        "$D/php/yar_client/client.php" >"$LOG/s1_${PACKAGER}_conc_php_$i.log" 2>&1 &
    CONC_PIDS="$CONC_PIDS $!"
done
for i in $(seq 1 "$N_CONC"); do
    curl -s -o /dev/null -w "%{http_code}\n" -X POST \
        http://127.0.0.1:${E2E_PORT_APISIX_YAR2GRPC}/api/nonexistent.Service >"$LOG/s1_${PACKAGER}_conc_curl_$i.log" &
    CONC_PIDS="$CONC_PIDS $!"
done
wait $CONC_PIDS

PHP_FAIL=0; CURL_FAIL=0; CURL_BAD=""
for i in $(seq 1 "$N_CONC"); do
    grep -q "Scenario 1.*PASS" "$LOG/s1_${PACKAGER}_conc_php_$i.log" || PHP_FAIL=$((PHP_FAIL+1))
    CODE="$(cat "$LOG/s1_${PACKAGER}_conc_curl_$i.log")"
    [ "$CODE" = "404" ] || { CURL_FAIL=$((CURL_FAIL+1)); CURL_BAD="$CURL_BAD $CODE"; }
done
if [ "$PHP_FAIL" -eq 0 ] && [ "$CURL_FAIL" -eq 0 ]; then
    P "concurrency isolation: PASS ($N_CONC PHP + $N_CONC curl)"
else
    F "concurrency isolation: FAIL (php_fail=$PHP_FAIL curl_fail=$CURL_FAIL codes=[$CURL_BAD ])"
fi

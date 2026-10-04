#!/usr/bin/env bash
# gen.sh — 从 calculator.proto 生成 Go 代码 + .pb 文件
# (adapted from lua-resty-yar-grpc-bridge t/e2e/proto/gen.sh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GO_PROTO_DIR="$SCRIPT_DIR/../go/proto"

mkdir -p "$GO_PROTO_DIR"

echo "[gen] generating Go code from calculator.proto..."
cd "$SCRIPT_DIR"
protoc \
    -I . \
    --go_out="$GO_PROTO_DIR" \
    --go_opt=paths=source_relative \
    --go-grpc_out="$GO_PROTO_DIR" \
    --go-grpc_opt=paths=source_relative \
    calculator.proto

echo "[gen] Go code generated in $GO_PROTO_DIR/"

echo "[gen] generating .pb file for proxy..."
protoc \
    -I . \
    --descriptor_set_out="$SCRIPT_DIR/calculator.pb" \
    --include_imports \
    calculator.proto

echo "[gen] .pb file generated at $SCRIPT_DIR/calculator.pb"
echo "[gen] done"

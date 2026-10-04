# Makefile — apisix-plugin-yar-grpc
#
# Common targets:
#   make lint        — luacheck + stylua --check (static analysis + format)
#   make test        — unit tests (busted, mocked — no APISIX binary needed)
#   make e2e         — end-to-end interop (local: APISIX + PHP + Go)
#   make docker-e2e  — end-to-end in Docker (self-contained, no local deps)
#   make clean       — remove test artifacts

ROOT := $(shell pwd)

# Lua source dirs for lint (config in .luacheckrc + .stylua.toml)
LUA_SRC := apisix/

.PHONY: lint test unit e2e docker-build docker-e2e clean help

# ── Lint: luacheck (static analysis) + stylua --check (format) ──
lint:
	luacheck $(LUA_SRC)
	stylua --check $(LUA_SRC)

# ── Unit tests (BDD with busted, mocked) ──
test: unit

unit:
	busted -v t/00-unit/

# ── E2E interop tests (local: requires APISIX + PHP + Go + protoc) ──
# Scenario 1: PHP Yar → APISIX (yar2grpc) → Go gRPC
# Scenario 2: Go gRPC → APISIX (grpc2yar) → PHP Yar
e2e:
	bash t/e2e/run_e2e.sh

# ── Docker e2e (self-contained: builds image, no local deps needed) ──
# Uses apache/apisix base image with PHP + Go + protoc installed.
docker-build:
	docker build -t apisix-yar-grpc-plugin-e2e -f t/e2e/Dockerfile .

docker-e2e: docker-build
	docker run --rm apisix-yar-grpc-plugin-e2e

# ── Clean: remove test artifacts ──
clean:
	rm -rf t/e2e/.run

# ── Help ──
help:
	@echo "apisix-plugin-yar-grpc — Makefile targets"
	@echo ""
	@echo "  make lint         luacheck + stylua --check"
	@echo "  make test         unit tests (busted, mocked)"
	@echo "  make e2e          e2e interop tests (local: APISIX + PHP + Go)"
	@echo "  make docker-e2e   e2e in Docker (self-contained)"
	@echo "  make docker-build build APISIX plugin e2e image"
	@echo "  make clean        remove test artifacts"
	@echo "  make help         show this help"

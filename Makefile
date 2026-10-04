# Makefile — apisix-plugin-yar-grpc
#
# Common targets:
#   make lint        — luacheck + stylua --check (static analysis + format)
#   make test        — unit tests (busted, mocked — no APISIX binary needed)
#   make e2e         — end-to-end interop (local: OpenResty + PHP + Go)
#   make docker-e2e  — end-to-end in Docker (self-contained, no local deps)
#   make clean       — remove test artifacts + nginx temp dirs
#
# Docker helpers:
#   make docker-base  — build bridge base image from GitHub (first time only)
#   make docker-build — build APISIX plugin e2e image on top of base

ROOT := $(shell pwd)
OR ?= /opt/homebrew/opt/openresty
OPENRESTY_PREFIX ?= $(OR)
NGINX := $(OR)/nginx/sbin/nginx
LUAROCKS := $(OR)/luajit/bin/luarocks

# Bridge dependency — installed remotely from GitHub into the Docker image
BRIDGE_REPO ?= https://github.com/fangfengxiang/lua-resty-yar-grpc-bridge.git
BRIDGE_VERSION ?= v0.1.1

# Lua source dirs for lint (config in .luacheckrc + .stylua.toml)
LUA_SRC := apisix/

.PHONY: lint test unit e2e docker-base docker-build docker-e2e clean help

# ── Lint: luacheck (static analysis) + stylua --check (format) ──
# luacheck reads .luacheckrc (globals ngx, max_line_length 120)
# stylua reads .stylua.toml (4-space indent, 120-col, NoSingleTable)
lint:
	luacheck $(LUA_SRC)
	stylua --check $(LUA_SRC)

# ── Unit tests (BDD with busted, mocked — no OpenResty/APISIX binary) ──
# Tests plugin logic: schema validation, access routing, URI parsing,
# config change detection, transport injection, error paths.
test: unit

unit:
	busted -v t/00-unit/

# ── E2E interop tests (local: requires OpenResty + PHP + Go + protoc) ──
# Scenario 1: PHP Yar → APISIX (yar2grpc) → Go gRPC
# Scenario 2: Go gRPC → APISIX (grpc2yar) → PHP Yar
# Both scenarios run with json + msgpack packagers.
e2e:
	OPENRESTY_PREFIX=$(OPENRESTY_PREFIX) bash t/e2e/run_e2e.sh

# ── Docker e2e (self-contained: builds images, no local deps needed) ──
# Base image provides OpenResty + PHP + Go + protoc + lua-yar-grpc runtime.
# Built once from GitHub and cached locally; subsequent runs skip the clone.
docker-base:
	@docker image inspect yar-grpc-bridge-e2e >/dev/null 2>&1 || { \
		echo "Building bridge base image from $(BRIDGE_REPO) @ $(BRIDGE_VERSION)..."; \
		tmpdir=$$(mktemp -d); \
		git clone --branch $(BRIDGE_VERSION) --depth 1 $(BRIDGE_REPO) $$tmpdir/bridge; \
		docker build -t yar-grpc-bridge-e2e -f $$tmpdir/bridge/t/e2e/Dockerfile $$tmpdir/bridge/t/e2e/; \
		rm -rf $$tmpdir; \
	}

docker-build: docker-base
	docker build -t apisix-yar-grpc-plugin-e2e -f t/e2e/Dockerfile t/e2e/

docker-e2e: docker-build
	docker run --rm -v "$(ROOT):/app" -w /app apisix-yar-grpc-plugin-e2e bash t/e2e/run_e2e.sh

# ── Clean: remove test artifacts + nginx temp directories ──
# *_temp: fastcgi_temp, scgi_temp, proxy_temp, uwsgi_temp, client_body_temp
clean:
	rm -rf t/e2e/.run *_temp

# ── Help: list available targets ──
help:
	@echo "apisix-plugin-yar-grpc — Makefile targets"
	@echo ""
	@echo "  make lint         luacheck + stylua --check (static analysis + format)"
	@echo "  make test         unit tests (busted, mocked — no APISIX binary)"
	@echo "  make unit         alias for 'test'"
	@echo "  make e2e          e2e interop tests (local: OpenResty + PHP + Go)"
	@echo "  make docker-e2e   e2e in Docker (self-contained, no local deps)"
	@echo "  make docker-base  build bridge base image from GitHub (cached)"
	@echo "  make docker-build build APISIX plugin e2e image"
	@echo "  make clean        remove test artifacts + nginx temp dirs"
	@echo "  make help         show this help"

# Makefile — apisix-plugin-yar-grpc
#
# Targets:
#   unit        — run BDD unit tests (busted)
#   e2e         — run e2e tests locally (requires OpenResty + PHP + Go)
#   docker-e2e  — run e2e tests in Docker (self-contained)
#   docker-build — build the e2e Docker image

ROOT := $(shell pwd)
OR ?= /opt/homebrew/opt/openresty
OPENRESTY_PREFIX ?= $(OR)
NGINX := $(OR)/nginx/sbin/nginx
LUAROCKS := $(OR)/luajit/bin/luarocks

.PHONY: unit e2e docker-e2e docker-build clean

# ── Unit tests (BDD with busted) ──
unit:
	busted -v t/00-unit/

# ── e2e tests (local: requires OpenResty + PHP + Go + protoc) ──
e2e:
	OPENRESTY_PREFIX=$(OPENRESTY_PREFIX) bash t/e2e/run_e2e.sh

# ── e2e tests (Docker: self-contained) ──
docker-build:
	docker build -t apisix-yar-grpc-plugin-e2e -f t/e2e/Dockerfile t/e2e/

docker-e2e: docker-build
	docker run --rm -v "$(ROOT):/app" -v "$(ROOT)/../lua-resty-yar-grpc-bridge:/bridge" -w /app apisix-yar-grpc-plugin-e2e bash t/e2e/run_e2e.sh

clean:
	rm -rf t/e2e/.run

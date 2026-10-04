# Dockerfile — e2e test image for APISIX plugin yar_grpc_bridge
#
# Extends the pre-built bridge e2e image (which has OpenResty + PHP + Go + protoc
# + lua-yar-grpc already installed). Installs the bridge via LuaRocks and
# lua-resty-http (needed by the plugin's yar2grpc transport).
#
# Prerequisite: build the bridge e2e base image first:
#   make docker-base
# or manually:
#   docker build -t yar-grpc-bridge-e2e -f ../lua-resty-yar-grpc-bridge/t/e2e/Dockerfile ../lua-resty-yar-grpc-bridge/t/e2e/
#
# Build: make docker-build
# Run:   make docker-e2e

FROM yar-grpc-bridge-e2e

# ── lua-resty-yar-grpc-bridge >= 0.1.2 (via LuaRocks, pulls lua-yar-grpc etc.) ──
# Installed into OpenResty's LuaJIT share path; require("resty.yar_grpc_bridge")
# resolves via the default lua_package_path ;; — no local mount needed.
RUN /usr/local/openresty/luajit/bin/luarocks install lua-resty-yar-grpc-bridge 0.1.2

# ── lua-resty-http (needed by handler.lua for yar2grpc grpc_transport) ──
RUN /usr/local/openresty/luajit/bin/luarocks install lua-resty-http

ENV OPENRESTY_PREFIX=/usr/local/openresty
# Bridge installed via LuaRocks into LuaJIT share path; BRIDGE_LIB points there
# so the nginx lua_package_path @BRIDGE_LIB@ entries resolve (also covered by ;;).
ENV BRIDGE_LIB=/usr/local/openresty/luajit/share/lua/5.1
# Go module proxy: goproxy.cn is globally accessible and faster in Asia-Pacific
# than proxy.golang.org (which is blocked/slow in some regions). Works in CI too.
ENV GOPROXY=https://goproxy.cn,direct

WORKDIR /app

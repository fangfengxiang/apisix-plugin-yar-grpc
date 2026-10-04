# Dockerfile — e2e test image for APISIX plugin yar_grpc_bridge
#
# Uses APISIX installed from APISEVEN deb repo (avoids Docker Hub image pull).
# The plugin source is copied into the image and loaded via extra_lua_path.
#
# Build:  docker build -t apisix-yar-grpc-plugin-e2e -f t/e2e/Dockerfile .
# Run:    docker run --rm apisix-yar-grpc-plugin-e2e

# ── Stage 1: Build Go binaries + generate proto descriptor ──
FROM golang:bookworm AS builder
ENV GOPROXY=https://goproxy.cn,direct
RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*
RUN go install google.golang.org/protobuf/cmd/protoc-gen-go@latest && \
    go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
ENV PATH="/root/go/bin:${PATH}"
WORKDIR /build
COPY t/e2e/proto/calculator.proto t/e2e/proto/gen.sh proto/
COPY t/e2e/go/ go/
RUN bash proto/gen.sh && \
    cd go && \
    go build -buildvcs=false -o /out/grpc_server ./grpc_server && \
    go build -buildvcs=false -o /out/grpc_client ./grpc_client

# ── Stage 2: APISIX runtime ──
FROM php:8.2-cli-bookworm

# Install APISIX from APISEVEN deb repo (includes patched OpenResty + all deps)
# Supports both amd64 and arm64 architectures.
ARG APISIX_VERSION=3.19.0
RUN set -ex; \
    arch=$(dpkg --print-architecture); \
    apt-get update && apt-get install -y --no-install-recommends curl gnupg ca-certificates; \
    curl -sL https://repos.apiseven.com/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/apisix.gpg; \
    if [ "$arch" = "amd64" ]; then \
        echo "deb [signed-by=/usr/share/keyrings/apisix.gpg] https://repos.apiseven.com/packages/debian debian12 main" \
            > /etc/apt/sources.list.d/apisix.list; \
    else \
        echo "deb [signed-by=/usr/share/keyrings/apisix.gpg] https://repos.apiseven.com/packages/arm64/debian debian12 main" \
            > /etc/apt/sources.list.d/apisix.list; \
    fi; \
    apt-get update \
    && apt-get install -y apisix=${APISIX_VERSION}-0 \
    && apt-get purge -y --auto-remove curl gnupg \
    && rm -rf /var/lib/apt/lists/*

# Install PHP extensions (yar with msgpack packager support + curl for e2e tests)
# yar must be compiled manually with --enable-msgpack:
#   pecl install -D doesn't pass configure flags correctly,
#   so download source, phpize, configure --enable-msgpack, make.
# Without it, yar.packager=msgpack silently falls back to PHP serialize.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libcurl4-openssl-dev curl \
    && pecl install msgpack && docker-php-ext-enable msgpack \
    && cd /tmp && pecl download yar && tar xf yar-*.tgz && cd yar-*/ \
    && phpize && ./configure --enable-msgpack \
    && make -j"$(nproc)" && make install \
    && docker-php-ext-enable yar \
    && cd /tmp && rm -rf yar-* \
    && echo "zend.assertions=1" > /usr/local/etc/php/conf.d/99-assertions.ini \
    && rm -rf /var/lib/apt/lists/*

# Install luarocks (not bundled in APISIX deb) + bridge deps
ENV PATH="/usr/local/openresty/luajit/bin:/usr/local/openresty/bin:/usr/local/openresty/nginx/sbin:${PATH}"
RUN apt-get update && apt-get install -y --no-install-recommends luarocks \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /root/.luarocks \
    && luarocks config variables.LUA_INCDIR /usr/local/openresty/luajit/include/luajit-2.1 \
    && luarocks install --tree /usr/local/apisix/deps lua-resty-http 0.17.2 \
    && luarocks install --tree /usr/local/apisix/deps lua-resty-yar-grpc-bridge 0.1.2

# Copy Go binaries + proto descriptor from builder
COPY --from=builder /out/grpc_server /out/grpc_client /app/t/e2e/.run/bin/
COPY --from=builder /build/proto/calculator.pb /app/t/e2e/proto/calculator.pb

# Copy e2e test files
COPY t/e2e/php/ /app/t/e2e/php/
COPY t/e2e/conf/ /app/t/e2e/conf/
COPY t/e2e/scenario1_yar2grpc.sh t/e2e/scenario2_grpc2yar.sh t/e2e/run_e2e.sh /app/t/e2e/

# Copy plugin source — loaded by APISIX via extra_lua_path
COPY apisix/plugins/yar_grpc_bridge.lua /app/apisix/plugins/yar_grpc_bridge.lua

WORKDIR /app
CMD ["bash", "t/e2e/run_e2e.sh"]

# Dockerfile — e2e test image for APISIX plugin yar_grpc_bridge
#
# Extends the pre-built bridge e2e image (which has OpenResty + PHP + Go + protoc
# + lua-yar-grpc already installed). Only adds lua-resty-http (needed by the
# plugin's yar2grpc grpc_transport implementation).
#
# Prerequisite: build the bridge e2e image first:
#   docker build -t yar-grpc-bridge-e2e -f ../lua-resty-yar-grpc-bridge/t/e2e/Dockerfile ../lua-resty-yar-grpc-bridge/t/e2e/
#
# Build: docker build -t apisix-yar-grpc-plugin-e2e -f t/e2e/Dockerfile t/e2e/
# Run:   docker run --rm -v "$(pwd):/app" -w /app apisix-yar-grpc-plugin-e2e bash t/e2e/run_e2e.sh

FROM yar-grpc-bridge-e2e

# lua-resty-http (needed by plugin for yar2grpc grpc_transport)
RUN /usr/local/openresty/luajit/bin/luarocks install lua-resty-http

ENV OPENRESTY_PREFIX=/usr/local/openresty
# Bridge source mounted at /bridge via docker run -v (see Makefile docker-e2e)
ENV BRIDGE_LIB=/bridge/lib

WORKDIR /app

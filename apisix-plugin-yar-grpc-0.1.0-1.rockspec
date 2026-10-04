package = "apisix-plugin-yar-grpc"
version = "0.1.0-1"

source = {
    url = "git://github.com/fangfengxiang/apisix-plugin-yar-grpc",
    branch = "main",
}

description = {
    summary = "APISIX custom plugin: YAR ↔ gRPC protocol bridge",
    detailed = [[
        APISIX custom plugin that bridges YAR RPC and gRPC protocols.
        Reuses the host-agnostic orchestration + HTTP entry layer from
        lua-resty-yar-grpc-bridge. Supports both directions:
        grpc2yar (gRPC client → PHP Yar) and yar2grpc (PHP Yar → gRPC).
    ]],
    homepage = "https://github.com/fangfengxiang/apisix-plugin-yar-grpc",
    license = "MIT",
    maintainer = "yar-group",
}

dependencies = {
    "lua-resty-yar-grpc-bridge",
    "lua-resty-http",
}

build = {
    type = "builtin",
    modules = {
        ["apisix.plugins.yar_grpc_bridge"] = "apisix/plugins/yar_grpc_bridge.lua",
    },
}

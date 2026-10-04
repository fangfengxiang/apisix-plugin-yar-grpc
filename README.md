# apisix-plugin-yar-grpc

[English](README.md) | [简体中文](README.zh.md)

[![CI](https://github.com/fangfengxiang/apisix-plugin-yar-grpc/actions/workflows/ci.yml/badge.svg)](https://github.com/fangfengxiang/apisix-plugin-yar-grpc/actions/workflows/ci.yml)
[![APISIX](https://img.shields.io/badge/APISIX-Gateway-blue.svg)](https://apisix.apache.org/)
[![License](https://img.shields.io/badge/license-Apache_2.0-blue.svg)](LICENSE)

APISIX custom plugin: YAR &harr; gRPC protocol bridge for Apache APISIX.

Reuses the host-agnostic orchestration + OpenResty HTTP entry from
[`lua-resty-yar-grpc-bridge`](https://github.com/fangfengxiang/lua-resty-yar-grpc-bridge).

## Dependencies

| Package | Version | Required when |
|---|---|---|
| `lua-resty-yar-grpc-bridge` | >= 0.1.2 | always |
| `lua-resty-http` | >= 0.17 | yar2grpc direction only (gRPC backend HTTP transport) |

## Quick Start

### Install

APISIX loads custom plugins via `extra_lua_path` + `plugins` list (no LuaRocks
integration). The plugin is a single `.lua` file — copy it into your deployment
and point APISIX at it.

```bash
# 1. Clone or download this repo
git clone https://github.com/fangfengxiang/apisix-plugin-yar-grpc.git

# 2. Install bridge dependencies (into APISIX's deps tree)
luarocks install --tree /usr/local/apisix/deps lua-resty-yar-grpc-bridge 0.1.2
luarocks install --tree /usr/local/apisix/deps lua-resty-http
```

```yaml
# conf/config.yaml
apisix:
    extra_lua_path: "/path/to/apisix-plugin-yar-grpc/?.lua"

plugins:                # defining plugins replaces the default list
    - router-defense    # keep built-in plugins you need
    - yar_grpc_bridge   # add this plugin

nginx_config:
    http_server_configuration_snippet: |
        set $service_name "";
        set $grpc_status "0";
        set $grpc_message "";
        add_trailer grpc-status $grpc_status always;
        add_trailer grpc-message $grpc_message always;
```

The `extra_lua_path` must point to the **repo root** so that
`require("apisix.plugins.yar_grpc_bridge")` resolves to
`<repo>/apisix/plugins/yar_grpc_bridge.lua`. The nginx snippet declares the
`$service_name` variable (yar2grpc URI parsing) and gRPC response trailers.

### grpc2yar: gRPC client &rarr; APISIX &rarr; PHP Yar server

```yaml
# apisix.yaml (standalone mode)
routes:
  - id: grpc2yar
    uri: /calculator.Calculator/*
    plugins:
      yar_grpc_bridge:
        direction: grpc2yar
        services:
          calculator.Calculator:
            proto: /etc/apisix/proto/calc.pb   # compiled protobuf descriptor (.pb)
            url: http://php-yar:8888/api.php    # PHP Yar server endpoint
            options:
              packager: json
              timeout: "5000"
        yar_options:
          timeout: "3000"
        max_payload_bytes: 8388608
    upstream:
      type: roundrobin
      nodes:
        127.0.0.1:9999: 1   # dummy — the plugin short-circuits upstream proxying
```

```bash
# gRPC client → APISIX → PHP Yar server
grpcurl -plaintext -d '{"a":15,"b":27}' localhost:9080 calculator.Calculator/Add
# → {"result":42}
```

### yar2grpc: PHP Yar client &rarr; APISIX &rarr; gRPC server

```yaml
# apisix.yaml (standalone mode)
routes:
  - id: yar2grpc
    uri: /api/*
    plugins:
      yar_grpc_bridge:
        direction: yar2grpc
        services:
          calculator.Calculator:
            proto: /etc/apisix/proto/calc.pb
            methods: ["Add", "Subtract"]
        grpc_backend_url: http://go-grpc:50052   # HTTP/gRPC bridge of Go backend
        yar_path_prefix: /api/                    # URI prefix for service extraction
    upstream:
      type: roundrobin
      nodes:
        127.0.0.1:9999: 1   # dummy — the plugin short-circuits upstream proxying
```

```php
<?php
// PHP Yar client → APISIX → Go gRPC server
$client = new Yar_Client("http://localhost:9080/api/calculator.Calculator");
echo $client->Add(15, 27);  // 42
```

### Docker / Kubernetes

```dockerfile
FROM apache/apisix:3.11.0
COPY apisix-plugin-yar-grpc/apisix/plugins/yar_grpc_bridge.lua /opt/apisix/plugins/yar_grpc_bridge.lua
RUN luarocks install lua-resty-yar-grpc-bridge 0.1.2 && \
    luarocks install lua-resty-http
```

```yaml
# config.yaml
apisix:
    extra_lua_path: "/opt/?.lua"
plugins:
    - yar_grpc_bridge
```

## Architecture

```
gRPC client ──HTTP/2──► APISIX (plugin:access) ──► grpc2yar_endpoint.serve()
                                                └─► grpc2yar.handle (orchestration)
                                                    └─► lua-yar client ──► PHP Yar Server

PHP Yar client ──HTTP/1.1──► APISIX (plugin:access) ──► yar2grpc_endpoint.handle()
                                                       └─► yar2grpc._dispatch (orchestration)
                                                           └─► grpc_transport ──► Go gRPC Server
```

APISIX runs on OpenResty &rarr; `ngx.*` available &rarr; bridge `host.lua` abstraction + entry modules
work as-is. Plugin wires APISIX's phase lifecycle (`access`) to the bridge entry modules.

## Config fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `direction` | string | yes | `grpc2yar` or `yar2grpc` |
| `services` | map | yes | service_name → { proto, url/methods, options } |
| `yar_options` | map | no | global YAR client options |
| `max_payload_bytes` | integer | no | request body size limit (default 8MB) |
| `grpc_backend_url` | string | yar2grpc only | HTTP bridge URL of gRPC backend |
| `yar_path_prefix` | string | no | URI prefix for service extraction (default `/api/`) |

> **Note**: bridge setup state is per-worker and single-slot — one active plugin
> config per worker process. Routing different plugin configs across routes
> causes re-setup on every switch; use one config (or identical configs) per
> deployment.

## Files

- `apisix/plugins/yar_grpc_bridge.lua` — plugin (JSON Schema + check_schema + access)
- `t/00-unit/` — BDD unit tests (busted)
- `t/e2e/` — e2e tests (Docker: APISIX + PHP Yar + Go gRPC)

## Development

```bash
# lint (luacheck + stylua --check)
make lint

# unit tests (busted, mocked — no APISIX binary needed)
make test

# e2e (local: requires APISIX + PHP + Go + protoc)
make e2e

# e2e (Docker: self-contained, no local deps)
make docker-e2e

# show all targets
make help
```

## Differences from kong-plugin-yar-grpc

| Aspect | Kong plugin | APISIX plugin |
|--------|------------|---------------|
| File structure | `handler.lua` + `schema.lua` | Single `yar_grpc_bridge.lua` |
| Schema format | Kong custom schema | JSON Schema |
| Plugin table | `PRIORITY`, `VERSION` | `priority`, `version`, `name` |
| Access method | `Plugin:access(conf)` | `_M.access(conf, ctx)` |
| Schema validation | Kong schema engine | `_M.check_schema(conf)` |

Core logic (`ensure_setup`, `config_signature`, `coerce_values`, URI parsing,
proto loading, transport injection) is identical between Kong and APISIX plugins.

## CI/CD

Three-stage pipeline (`.github/workflows/ci.yml`): `lint → unit → e2e`.

- **lint**: `luacheck` + `stylua --check` on `apisix/`
- **unit**: `busted -v t/00-unit/` (mocked ngx/bridge, no binary)
- **e2e**: self-contained Docker image (APISIX deb + PHP Yar + Go gRPC); runs both
  scenarios (grpc2yar / yar2grpc) with both packagers (json / msgpack)

## License

[Apache License 2.0](LICENSE)

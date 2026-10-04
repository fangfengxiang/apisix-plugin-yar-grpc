# apisix-plugin-yar-grpc

[![CI](https://github.com/fangfengxiang/apisix-plugin-yar-grpc/actions/workflows/ci.yml/badge.svg)](https://github.com/fangfengxiang/apisix-plugin-yar-grpc/actions/workflows/ci.yml)

APISIX custom plugin: YAR ↔ gRPC protocol bridge for Apache APISIX.

Reuses the host-agnostic orchestration + OpenResty HTTP entry from
[`lua-resty-yar-grpc-bridge`](../lua-resty-yar-grpc-bridge).

## Architecture

```
gRPC client ──HTTP/2──► APISIX (plugin:access) ──► grpc2yar_endpoint.serve()
                                                └─► grpc2yar.handle (编排)
                                                    └─► lua-yar client ──► PHP Yar Server

PHP Yar client ──HTTP/1.1──► APISIX (plugin:access) ──► yar2grpc_endpoint.handle()
                                                       └─► yar2grpc._dispatch (编排)
                                                           └─► grpc_transport ──► Go gRPC Server
```

## Installation

APISIX loads custom plugins via `extra_lua_path` + `plugins` list (no LuaRocks
integration). The plugin is a single `.lua` file — copy it into your deployment
and point APISIX at it.

### 1. Copy the plugin source

```bash
# Clone or download this repo
git clone https://github.com/fangfengxiang/apisix-plugin-yar-grpc.git
```

### 2. Install bridge dependencies

```bash
luarocks install lua-resty-yar-grpc-bridge >= 0.1.2
luarocks install lua-resty-http
```

### 3. Configure APISIX

Add to `conf/config.yaml`:

```yaml
apisix:
    extra_lua_path: "/path/to/apisix-plugin-yar-grpc/?.lua"

plugins:                # ⚠️ defining plugins replaces the default list
    - router-defense   # keep built-in plugins you need
    - yar_grpc_bridge  # add this plugin
```

The `extra_lua_path` must point to the **repo root** so that
`require("apisix.plugins.yar_grpc_bridge")` resolves to
`<repo>/apisix/plugins/yar_grpc_bridge.lua`.

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

## Config schema

```json
{
    "direction": "grpc2yar",
    "services": {
        "calculator.Calculator": {
            "proto": "/etc/apisix/proto/calc.pb",
            "url": "http://php-yar:8888/api.php",
            "options": { "timeout": "5000" }
        }
    },
    "yar_options": { "timeout": "3000" },
    "max_payload_bytes": 8388608
}
```

## Config fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `direction` | string | yes | `grpc2yar` or `yar2grpc` |
| `services` | map | yes | service_name → { proto, url/methods, options } |
| `yar_options` | map | no | global YAR client options |
| `max_payload_bytes` | integer | no | request body size limit (default 8MB) |
| `grpc_backend_url` | string | yar2grpc only | HTTP bridge URL of gRPC backend |
| `yar_path_prefix` | string | no | URI prefix for service extraction (default `/api/`) |

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

# clean test artifacts
make clean

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
- **e2e**: Docker image built from `apache/apisix` base; runs both
  scenarios (grpc2yar / yar2grpc) with both packagers (json / msgpack)

## License

MIT — see [LICENSE](LICENSE).

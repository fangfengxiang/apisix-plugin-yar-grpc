# apisix-plugin-yar-grpc

[![CI](https://github.com/fangfengxiang/apisix-plugin-yar-grpc/actions/workflows/ci.yml/badge.svg)](https://github.com/fangfengxiang/apisix-plugin-yar-grpc/actions/workflows/ci.yml)

APISIX custom plugin: YAR ↔ gRPC protocol bridge for Apache APISIX.

Reuses the host-agnostic orchestration + OpenResty HTTP entry from
[`lua-resty-yar-grpc-bridge`](../lua-resty-yar-grpc-bridge) (overview-5 职责拆分后，
编排层 `grpc2yar.handle` / `yar2grpc._dispatch` 与 HTTP 入口层已分离)。

## Architecture

```
gRPC client ──HTTP/2──► APISIX (plugin:access) ──► grpc2yar_endpoint.serve()
                                                └─► grpc2yar.handle (编排)
                                                    └─► lua-yar client ──► PHP Yar Server

PHP Yar client ──HTTP/1.1──► APISIX (plugin:access) ──► yar2grpc_endpoint.handle()
                                                       └─► yar2grpc._dispatch (编排)
                                                           └─► grpc_transport ──► Go gRPC Server
```

APISIX runs on OpenResty → `ngx.*` available → bridge entry modules work as-is.
Plugin wires APISIX's phase lifecycle (access) to the bridge endpoint modules.

## Installation

### Prerequisites

- [Apache APISIX](https://apisix.apache.org/) 3.x running on OpenResty
- [LuaRocks](https://luarocks.org/) (bundled with OpenResty)

### Install the plugin

```bash
luarocks install apisix-plugin-yar-grpc
```

This pulls `lua-resty-yar-grpc-bridge` (>= 0.1.2) and `lua-resty-http` as dependencies.

### Enable in APISIX

Add the plugin to `conf/config.yaml`:

```yaml
apisix:
    extra_lua_path: "/usr/local/share/lua/5.1/?.lua"   # LuaRocks install path

plugins:                # ⚠️ defining plugins replaces the default list
    - router-defense   # keep built-in plugins you need
    - yar_grpc_bridge  # add this plugin
```

> If APISIX is installed via LuaRocks (same prefix), the plugin is already in
> APISIX's default `lua_package_path` — `extra_lua_path` is not needed.

### Docker / Kubernetes

For the APISIX Docker image, build a custom image:

```dockerfile
FROM apache/apisix
RUN luarocks install apisix-plugin-yar-grpc
```

For Helm, set `extraLuaPath` and `plugins` in `values.yaml`:

```yaml
apisix:
    extraLuaPath: "/usr/local/share/lua/5.1/?.lua"
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
- `t/e2e/` — e2e tests (Docker: OpenResty + PHP Yar + Go gRPC)

## Development

```bash
# lint (luacheck + stylua --check)
make lint

# unit tests (busted, mocked — no APISIX binary needed)
make test

# e2e (local: requires OpenResty + PHP Yar + Go + protoc)
make e2e

# e2e (Docker: self-contained, no local deps)
make docker-e2e

# clean test artifacts + nginx temp dirs
make clean

# show all targets
make help
```

Local e2e prerequisites: the bridge must be findable via `lua_package_path`.
`run_e2e.sh` auto-detects the sibling dir `../lua-resty-yar-grpc-bridge/lib`;
alternatively install the bridge via LuaRocks:

```bash
luarocks install lua-resty-yar-grpc-bridge
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
- **e2e**: Docker image built from bridge base + plugin Dockerfile; runs both
  scenarios (grpc2yar / yar2grpc) with both packagers (json / msgpack)

Releases (`.github/workflows/release.yml`): push a `v*` tag → version-verified
LuaRocks `.src.rock` + source tarball + GitHub Release; optional LuaRocks upload.

## License

MIT — see [LICENSE](LICENSE).

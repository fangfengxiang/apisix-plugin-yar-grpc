# apisix-plugin-yar-grpc

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
# install bridge dep
luarocks make ../lua-resty-yar-grpc-bridge/*.rockspec

# unit tests (busted)
make unit

# e2e (Docker: self-contained)
make docker-e2e
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

# apisix-plugin-yar-grpc

[English](README.md) | [简体中文](README.zh.md)

[![CI](https://github.com/fangfengxiang/apisix-plugin-yar-grpc/actions/workflows/ci.yml/badge.svg)](https://github.com/fangfengxiang/apisix-plugin-yar-grpc/actions/workflows/ci.yml)
[![APISIX](https://img.shields.io/badge/APISIX-Gateway-blue.svg)](https://apisix.apache.org/)
[![License](https://img.shields.io/badge/license-Apache_2.0-blue.svg)](LICENSE)

APISIX 自定义插件：YAR &harr; gRPC 协议桥接，适用于 Apache APISIX。

复用
[`lua-resty-yar-grpc-bridge`](https://github.com/fangfengxiang/lua-resty-yar-grpc-bridge)
的协议无关编排层与 OpenResty HTTP 入口层。

## 依赖

| 包名 | 版本 | 适用场景 |
|---|---|---|
| `lua-resty-yar-grpc-bridge` | >= 0.1.2 | 始终需要 |
| `lua-resty-http` | >= 0.17 | 仅 yar2grpc 方向（gRPC 后端 HTTP 传输） |

## 快速开始

### 安装

APISIX 通过 `extra_lua_path` + `plugins` 列表加载自定义插件（不走 LuaRocks
集成）。插件是单个 `.lua` 文件——拷贝进部署目录并让 APISIX 指向它即可。

```bash
# 1. 克隆或下载本仓库
git clone https://github.com/fangfengxiang/apisix-plugin-yar-grpc.git

# 2. 安装桥接依赖（装进 APISIX 的 deps tree）
luarocks install --tree /usr/local/apisix/deps lua-resty-yar-grpc-bridge 0.1.2
luarocks install --tree /usr/local/apisix/deps lua-resty-http
```

```yaml
# conf/config.yaml
apisix:
    extra_lua_path: "/path/to/apisix-plugin-yar-grpc/?.lua"

plugins:                # 定义 plugins 会替换默认列表
    - router-defense    # 保留需要的内置插件
    - yar_grpc_bridge   # 添加本插件

nginx_config:
    http_server_configuration_snippet: |
        set $service_name "";
        set $grpc_status "0";
        set $grpc_message "";
        add_trailer grpc-status $grpc_status always;
        add_trailer grpc-message $grpc_message always;
```

`extra_lua_path` 必须指向**仓库根目录**，使
`require("apisix.plugins.yar_grpc_bridge")` 解析到
`<repo>/apisix/plugins/yar_grpc_bridge.lua`。nginx snippet 声明了
`$service_name` 变量（yar2grpc URI 解析用）与 gRPC 响应 trailer。

### grpc2yar：gRPC 客户端 &rarr; APISIX &rarr; PHP Yar 服务端

```yaml
# apisix.yaml（standalone 模式）
routes:
  - id: grpc2yar
    uri: /calculator.Calculator/*
    plugins:
      yar_grpc_bridge:
        direction: grpc2yar
        services:
          calculator.Calculator:
            proto: /etc/apisix/proto/calc.pb   # 编译后的 protobuf 描述符（.pb）
            url: http://php-yar:8888/api.php    # PHP Yar 服务端地址
            options:
              packager: json
              timeout: "5000"
        yar_options:
          timeout: "3000"
        max_payload_bytes: 8388608
    upstream:
      type: roundrobin
      nodes:
        127.0.0.1:9999: 1   # 占位——插件会短路上游代理
```

```bash
# gRPC 客户端 → APISIX → PHP Yar 服务端
grpcurl -plaintext -d '{"a":15,"b":27}' localhost:9080 calculator.Calculator/Add
# → {"result":42}
```

### yar2grpc：PHP Yar 客户端 &rarr; APISIX &rarr; gRPC 服务端

```yaml
# apisix.yaml（standalone 模式）
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
        grpc_backend_url: http://go-grpc:50052   # Go 后端的 HTTP/gRPC 桥接地址
        yar_path_prefix: /api/                    # 服务名提取的 URI 前缀
    upstream:
      type: roundrobin
      nodes:
        127.0.0.1:9999: 1   # 占位——插件会短路上游代理
```

```php
<?php
// PHP Yar 客户端 → APISIX → Go gRPC 服务端
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

## 架构

```
gRPC 客户端 ──HTTP/2──► APISIX (plugin:access) ──► grpc2yar_endpoint.serve()
                                                 └─► grpc2yar.handle (编排)
                                                     └─► lua-yar 客户端 ──► PHP Yar 服务端

PHP Yar 客户端 ──HTTP/1.1──► APISIX (plugin:access) ──► yar2grpc_endpoint.handle()
                                                        └─► yar2grpc._dispatch (编排)
                                                            └─► grpc_transport ──► Go gRPC 服务端
```

APISIX 运行于 OpenResty &rarr; `ngx.*` 可用 &rarr; 桥接库 `host.lua` 抽象层与入口模块
直接可用。插件将 APISIX 的生命周期阶段（`access`）接入桥接库入口模块。

## 配置字段

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `direction` | string | 是 | `grpc2yar` 或 `yar2grpc` |
| `services` | map | 是 | 服务名 → { proto, url/methods, options } |
| `yar_options` | map | 否 | 全局 YAR 客户端选项 |
| `max_payload_bytes` | integer | 否 | 请求体大小上限（默认 8MB） |
| `grpc_backend_url` | string | 仅 yar2grpc | gRPC 后端的 HTTP 桥接地址 |
| `yar_path_prefix` | string | 否 | 服务名提取的 URI 前缀（默认 `/api/`） |

## 文件结构

- `apisix/plugins/yar_grpc_bridge.lua` — 插件本体（JSON Schema + check_schema + access）
- `t/00-unit/` — BDD 单元测试（busted）
- `t/e2e/` — e2e 端到端测试（Docker：APISIX + PHP Yar + Go gRPC）

## 开发

```bash
# 代码检查（luacheck + stylua --check）
make lint

# 单元测试（busted，mock 环境——无需 APISIX 二进制）
make test

# e2e 端到端测试（本地：需要 APISIX + PHP + Go + protoc）
make e2e

# e2e 端到端测试（Docker：完全自包含，无本地依赖）
make docker-e2e

# 查看全部 target
make help
```

## 与 kong-plugin-yar-grpc 的差异

| 方面 | Kong 插件 | APISIX 插件 |
|------|----------|------------|
| 文件结构 | `handler.lua` + `schema.lua` | 单文件 `yar_grpc_bridge.lua` |
| Schema 格式 | Kong 自定义 schema | JSON Schema |
| 插件表 | `PRIORITY`、`VERSION` | `priority`、`version`、`name` |
| access 方法 | `Plugin:access(conf)` | `_M.access(conf, ctx)` |
| Schema 校验 | Kong schema 引擎 | `_M.check_schema(conf)` |

核心逻辑（`ensure_setup`、`config_signature`、`coerce_values`、URI 解析、
proto 加载、transport 注入）在 Kong 与 APISIX 插件间完全一致。

## CI/CD

三阶段流水线（`.github/workflows/ci.yml`）：`lint → unit → e2e`。

- **lint**：对 `apisix/` 执行 `luacheck` + `stylua --check`
- **unit**：`busted -v t/00-unit/`（mock ngx/bridge，无需二进制）
- **e2e**：自包含 Docker 镜像（APISIX deb + PHP Yar + Go gRPC）；两个场景
  （grpc2yar / yar2grpc）× 两种 packager（json / msgpack）全覆盖

## 许可协议

[Apache License 2.0](LICENSE)

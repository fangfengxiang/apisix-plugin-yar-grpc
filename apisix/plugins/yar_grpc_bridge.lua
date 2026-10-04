-- apisix/plugins/yar_grpc_bridge.lua
-- APISIX custom plugin: YAR ↔ gRPC protocol bridge.
--
-- Wires APISIX's access phase to the bridge's HTTP endpoint modules
-- (grpc2yar_endpoint.serve / yar2grpc_endpoint.handle) from lua-resty-yar-grpc-bridge.
-- APISIX runs on OpenResty → ngx.* available → bridge entry modules work as-is.
--
-- Lazy initialization: bridge.setup() / yar2grpc.setup() runs once per worker
-- on first request (APISIX's init_worker phase lacks per-plugin config in
-- standalone/custom-nginx mode).
--
-- For yar2grpc direction, the plugin parses the URI to extract the service name
-- and sets ngx.var.service_name (declared via nginx set directive).

local bridge = require("resty.yar_grpc_bridge")
local grpc2yar_endpoint = require("resty.yar_grpc_bridge.grpc2yar_endpoint")
local yar2grpc = require("resty.yar_grpc_bridge.yar2grpc")
local yar2grpc_endpoint = require("resty.yar_grpc_bridge.yar2grpc_endpoint")
local errors = require("yar_grpc.errors")

local ngx = ngx
local type = type
local tostring = tostring
local tonumber = tonumber
local pairs = pairs
local ipairs = ipairs
local next = next
local table_sort = table.sort
local table_concat = table.concat
local math_huge = math.huge

-- 递归序列化 / 类型转换的最大深度上限
-- Max recursion depth for table serialization / value coercion
local MAX_SERIALIZE_DEPTH = 20

-- 请求体大小限制：默认 8MB / 硬上限 2GB (32-bit signed int max)
-- Request body size limit: default 8MB / hard max 2GB
local DEFAULT_MAX_PAYLOAD_BYTES = 8 * 1024 * 1024
local HARD_MAX_PAYLOAD_BYTES = 2147483647

-- gRPC 后端 HTTP 桥接超时（yar2grpc 方向唯一出向调用，防后端挂起阻塞 worker）
-- gRPC backend HTTP bridge timeout (yar2grpc's only outbound call)
local GRPC_BACKEND_TIMEOUT_MS = 10000

-- ── JSON Schema (APISIX plugin config) ──
local schema = {
    type = "object",
    properties = {
        direction = {
            type = "string",
            enum = { "grpc2yar", "yar2grpc" },
            description = "Bridge direction: grpc2yar (gRPC→YAR) or yar2grpc (YAR→gRPC)",
        },
        services = {
            type = "object",
            description = "Map of service_name → { proto, url, methods, options }",
        },
        yar_options = {
            type = "object",
            description = "Global YAR client options (timeout, packager, etc.)",
        },
        max_payload_bytes = {
            type = "integer",
            minimum = 1,
            maximum = HARD_MAX_PAYLOAD_BYTES,
            default = DEFAULT_MAX_PAYLOAD_BYTES,
        },
        grpc_backend_url = {
            type = "string",
            description = "HTTP bridge URL of the gRPC backend (yar2grpc direction only)",
        },
        yar_path_prefix = {
            type = "string",
            default = "/api/",
        },
    },
    required = { "direction", "services" },
}

local _M = {
    version = "0.1.0",
    priority = 1000,
    name = "yar_grpc_bridge",
    schema = schema,
}

-- ── Schema validation ──
-- In production APISIX, core.schema.check(conf, schema) does full JSON Schema
-- validation. In standalone/custom-nginx mode (e2e tests), we do basic checks.
function _M.check_schema(conf)
    if type(conf) ~= "table" then
        return false, "config must be a table"
    end
    if type(conf.direction) ~= "string" then
        return false, "direction is required and must be a string"
    end
    if conf.direction ~= "grpc2yar" and conf.direction ~= "yar2grpc" then
        return false, "direction must be 'grpc2yar' or 'yar2grpc'"
    end
    if type(conf.services) ~= "table" then
        return false, "services is required and must be a table"
    end
    if next(conf.services) == nil then
        return false, "services must not be empty"
    end
    -- yar2grpc 方向必须配置 grpc_backend_url
    -- grpc_backend_url is required for yar2grpc direction
    if conf.direction == "yar2grpc" then
        if type(conf.grpc_backend_url) ~= "string" or conf.grpc_backend_url == "" then
            return false, "grpc_backend_url is required for yar2grpc direction"
        end
    end
    -- Verify each service has at least proto
    for name, svc in pairs(conf.services) do
        if type(svc) ~= "table" then
            return false, "service '" .. tostring(name) .. "' must be a table"
        end
        if type(svc.proto) ~= "string" then
            return false, "service '" .. tostring(name) .. "' requires proto (string)"
        end
    end
    return true
end

-- ── Worker-level state ──
-- 单槽设计：每 worker 仅支持一份生效配置；多路由交替不同配置会触发 re-setup。
-- Single-slot: one active config per worker; alternating configs trigger re-setup.
local _initialized = false
local _config_sig = nil

--- Serialize a config table deterministically (sorted keys) for signature comparison.
local function serialize_table(tbl, depth)
    depth = depth or 0
    if depth > MAX_SERIALIZE_DEPTH or type(tbl) ~= "table" then
        return tostring(tbl)
    end
    local parts = {}
    local keys = {}
    for k in pairs(tbl) do
        keys[#keys + 1] = k
    end
    -- keys 可能混有 string/number（map 与 array 混合表），统一按 tostring 比较
    table_sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)
    for _, k in ipairs(keys) do
        local v = tbl[k]
        if type(v) == "table" then
            parts[#parts + 1] = k .. "=" .. serialize_table(v, depth + 1)
        else
            parts[#parts + 1] = k .. "=" .. tostring(v)
        end
    end
    return "{" .. table_concat(parts, ",") .. "}"
end

--- Build a signature string from the config to detect config changes.
local function config_signature(conf)
    local parts = {}
    parts[#parts + 1] = conf.direction or ""
    parts[#parts + 1] = tostring(conf.max_payload_bytes or "")
    parts[#parts + 1] = conf.grpc_backend_url or ""
    parts[#parts + 1] = conf.yar_path_prefix or ""
    if conf.services then
        parts[#parts + 1] = serialize_table(conf.services)
    end
    if conf.yar_options then
        parts[#parts + 1] = serialize_table(conf.yar_options)
    end
    return table_concat(parts, "||")
end

--- Recursively coerce string values to appropriate Lua types.
-- APISIX config delivery (etcd/admin API) may deliver numbers as strings.
local function coerce_values(tbl, depth)
    depth = depth or 0
    if depth > MAX_SERIALIZE_DEPTH or type(tbl) ~= "table" then
        return tbl
    end
    local result = {}
    for k, v in pairs(tbl) do
        if type(v) == "string" then
            local num = tonumber(v)
            if num and tostring(num) == v and num == num and num ~= math_huge and num ~= -math_huge then
                result[k] = num
            elseif v == "true" then
                result[k] = true
            elseif v == "false" then
                result[k] = false
            else
                result[k] = v
            end
        elseif type(v) == "table" then
            result[k] = coerce_values(v, depth + 1)
        else
            result[k] = v
        end
    end
    return result
end

--- One-time per-worker setup: load .pb, inject cosocket, configure services.
local function ensure_setup(conf)
    local sig = config_signature(conf)
    if _initialized and sig == _config_sig then
        return true
    end

    local ok, err = pcall(function()
        if conf.direction == "grpc2yar" then
            bridge.setup {
                services = coerce_values(conf.services),
                yar_options = conf.yar_options and coerce_values(conf.yar_options) or {},
                max_payload_bytes = tonumber(conf.max_payload_bytes) or nil,
            }
        else
            -- yar2grpc: load .pb descriptors, clear converter caches, inject transport
            local services = coerce_values(conf.services)

            local pb = require("pb")
            local grpc_converter = require("yar_grpc.grpc_converter")
            local pb_converter = require("yar_grpc.pb_converter")

            grpc_converter.clear_cache()
            pb_converter.clear_cache()

            local loaded_files = {}
            for _, svc in pairs(services) do
                local proto_file = svc.proto
                if proto_file and not loaded_files[proto_file] then
                    local f, ferr = io.open(proto_file, "rb")
                    if not f then
                        error(
                            "yar_grpc_bridge: cannot open proto file: " .. proto_file .. " (" .. tostring(ferr) .. ")",
                            0
                        )
                    end
                    local data = f:read("*a")
                    f:close()
                    if not data or #data == 0 then
                        error("yar_grpc_bridge: empty proto file: " .. proto_file, 0)
                    end
                    local pok, res, offset = pcall(pb.load, data)
                    if not pok then
                        error("yar_grpc_bridge: failed to load " .. proto_file .. ": " .. tostring(res), 0)
                    end
                    if res == false then
                        error(
                            "yar_grpc_bridge: invalid .pb descriptor "
                                .. proto_file
                                .. " (parse error at offset "
                                .. tostring(offset)
                                .. ")",
                            0
                        )
                    end
                    loaded_files[proto_file] = true
                end
            end

            local backend_url = conf.grpc_backend_url
            local transport
            if backend_url then
                local http_new = require("resty.http").new
                transport = function(service, method, frame)
                    local httpc = http_new()
                    httpc:set_timeout(GRPC_BACKEND_TIMEOUT_MS)
                    local res, req_err = httpc:request_uri(backend_url .. "/" .. service .. "/" .. method, {
                        method = "POST",
                        body = frame,
                        headers = {
                            ["Content-Type"] = "application/grpc",
                            ["TE"] = "trailers",
                        },
                    })
                    if not res then
                        return nil, errors.UNAVAILABLE, "gRPC backend error: " .. tostring(req_err)
                    end
                    if res.status ~= ngx.HTTP_OK then
                        return nil, errors.UNAVAILABLE, "gRPC backend HTTP error: " .. tostring(res.status)
                    end
                    local grpc_status = tonumber(res.headers["grpc-status"]) or errors.OK
                    if grpc_status ~= errors.OK then
                        return nil, grpc_status, res.headers["grpc-message"] or "gRPC error"
                    end
                    return res.body
                end
            end

            yar2grpc.setup {
                services = services,
                grpc_transport = transport,
            }
        end
    end)

    if not ok then
        return nil, tostring(err)
    end

    _initialized = true
    _config_sig = sig
    return true
end

--- APISIX access phase handler
-- Delegates to the bridge endpoint module based on conf.direction.
-- The endpoint module calls ngx.exit(), short-circuiting APISIX's upstream proxying.
function _M.access(conf, ctx)
    local ok, err = ensure_setup(conf)
    if not ok then
        -- 错误详情（含文件路径）只写日志，客户端收通用文案；必须 ngx.exit 短路，
        -- 否则 APISIX 会继续执行后续 handler 并尝试代理到上游。
        -- Details (may contain fs paths) go to the log only; ngx.exit short-circuits
        -- so APISIX won't proceed to upstream proxying.
        ngx.log(ngx.ERR, "yar_grpc_bridge plugin setup failed: ", tostring(err))
        ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
        ngx.header["Content-Type"] = "text/plain"
        ngx.say("yar_grpc_bridge plugin setup failed")
        return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    if conf.direction == "grpc2yar" then
        grpc2yar_endpoint.serve()
        return
    end

    -- yar2grpc: parse service name from URI and set ngx.var.service_name
    local uri = ngx.var.uri or ""
    local prefix = conf.yar_path_prefix or "/api/"
    -- 容忍配置缺少前导斜杠（standalone 模式 check_schema 不做 pattern 校验）
    if prefix:sub(1, 1) ~= "/" then
        prefix = "/" .. prefix
    end
    local service_name

    if uri:sub(1, #prefix) == prefix then
        service_name = uri:sub(#prefix + 1)
        local slash = service_name:find("/")
        if slash then
            service_name = service_name:sub(1, slash - 1)
        end
    else
        local path = uri:gsub("^/+", "")
        if path ~= "" then
            local slash = path:find("/")
            service_name = slash and path:sub(1, slash - 1) or path
        end
    end

    if service_name and service_name ~= "" then
        ngx.var.service_name = service_name
    end

    yar2grpc_endpoint.handle()
end

return _M

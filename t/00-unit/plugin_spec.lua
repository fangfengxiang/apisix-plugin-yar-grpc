-- t/00-unit/plugin_spec.lua
-- BDD unit tests for the APISIX yar_grpc_bridge plugin.
--
-- Tests the plugin interface (schema, check_schema, access routing, URI parsing,
-- config change detection, transport injection) using mocks — no real network
-- or nginx needed.

--- Check if a value exists in a list (array-like table).
local function contains_value(list, value)
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

-- ── Mock setup (must be before require handler) ──

-- Save original ngx
local saved_ngx = _G.ngx or {}

-- Mock ngx
local mock_ngx = {
    ERR = 0,
    WARN = 1,
    INFO = 2,
    HTTP_INTERNAL_SERVER_ERROR = 500,
    HTTP_NOT_FOUND = 404,
    HTTP_OK = 200,
    log = function() end,
    say = function() end,
    exit = function() end,
    req = {},
    header = {},
    var = {},
    ctx = {},
    encode_base64 = function(s) return s end,
}
_G.ngx = mock_ngx

-- Mock bridge modules
local bridge_setup_called = false
local bridge_setup_args = nil
package.loaded["resty.yar_grpc_bridge"] = {
    setup = function(args)
        bridge_setup_called = true
        bridge_setup_args = args
    end,
    clear_cache = function() end,
}

local grpc2yar_serve_called = false
package.loaded["resty.yar_grpc_bridge.grpc2yar_endpoint"] = {
    serve = function()
        grpc2yar_serve_called = true
    end,
}

local yar2grpc_setup_called = false
local yar2grpc_setup_args = nil
package.loaded["resty.yar_grpc_bridge.yar2grpc"] = {
    setup = function(args)
        yar2grpc_setup_called = true
        yar2grpc_setup_args = args
    end,
    has_transport = function() return true end,
    get_proxy = function() return nil end,
}

local yar2grpc_handle_called = false
package.loaded["resty.yar_grpc_bridge.yar2grpc_endpoint"] = {
    handle = function()
        yar2grpc_handle_called = true
        return true
    end,
}

-- Mock yar_grpc.errors
package.loaded["yar_grpc.errors"] = {
    OK = 0,
    UNAVAILABLE = 14,
    INVALID_ARGUMENT = 3,
    NOT_FOUND = 5,
    INTERNAL = 13,
    DEADLINE_EXCEEDED = 4,
    RESOURCE_EXHAUSTED = 8,
    UNIMPLEMENTED = 12,
}

-- Mock pb / grpc_converter / pb_converter (lazy required by ensure_setup)
package.loaded["pb"] = { load = function() return true end }
package.loaded["yar_grpc.grpc_converter"] = {
    clear_cache = function() end,
    method_to_yar = function(m) return m:lower():sub(1,1) .. m:sub(2) end,
}
package.loaded["yar_grpc.pb_converter"] = { clear_cache = function() end }

-- Mock lua-resty-http
package.loaded["resty.http"] = {
    new = function()
        return {
            request_uri = function(self, url, opts)
                return { status = 200, body = "mock-frame",
                         headers = { ["grpc-status"] = "0" } }
            end,
        }
    end,
}

-- Helper: reset all call flags before each test
local function reset()
    bridge_setup_called = false
    bridge_setup_args = nil
    yar2grpc_setup_called = false
    yar2grpc_setup_args = nil
    grpc2yar_serve_called = false
    yar2grpc_handle_called = false
    mock_ngx.var = {}
    mock_ngx.req = {}
    mock_ngx.header = {}
    mock_ngx.ctx = {}
end

describe("apisix plugin yar_grpc_bridge", function()
    local plugin

    -- Save real io.open (restored in after_each)
    local real_io_open = io.open

    before_each(function()
        reset()
        _G.ngx = mock_ngx
        -- Mock io.open for .pb files (proto loading in ensure_setup)
        io.open = function(path, mode)
            if path and path:match("%.pb$") then
                return { read = function() return "mock-pb-data" end, close = function() end }
            end
            return real_io_open(path, mode)
        end
        -- Force re-require the plugin so it picks up fresh mocks
        package.loaded["apisix.plugins.yar_grpc_bridge"] = nil
        plugin = require("apisix.plugins.yar_grpc_bridge")
    end)

    after_each(function()
        _G.ngx = saved_ngx
        io.open = real_io_open
    end)

    describe("Plugin table", function()
        it("has version, priority, name, schema", function()
            assert.is_not_nil(plugin.version)
            assert.is_not_nil(plugin.priority)
            assert.are.equal("yar-grpc-bridge", plugin.name)
            assert.is_table(plugin.schema)
        end)

        it("schema has required fields", function()
            assert.are.equal("object", plugin.schema.type)
            assert.is_table(plugin.schema.properties)
            assert.is_table(plugin.schema.required)
            assert.truthy(contains_value(plugin.schema.required, "direction"))
            assert.truthy(contains_value(plugin.schema.required, "services"))
        end)
    end)

    describe("check_schema", function()
        it("accepts valid grpc2yar config", function()
            local ok, err = plugin.check_schema({
                direction = "grpc2yar",
                services = {
                    ["calculator.Calculator"] = {
                        proto = "/etc/apisix/proto/calc.pb",
                        url = "http://php:8888/api.php",
                    },
                },
            })
            assert.is_true(ok)
            assert.is_nil(err)
        end)

        it("accepts valid yar2grpc config", function()
            local ok, err = plugin.check_schema({
                direction = "yar2grpc",
                services = {
                    ["calculator.Calculator"] = {
                        proto = "/etc/apisix/proto/calc.pb",
                        methods = { "Add", "Subtract" },
                    },
                },
                grpc_backend_url = "http://go-grpc:50052",
            })
            assert.is_true(ok)
            assert.is_nil(err)
        end)

        it("rejects missing direction", function()
            local ok, err = plugin.check_schema({
                services = { ["test"] = { proto = "/x.pb" } },
            })
            assert.is_false(ok)
            assert.is_string(err)
        end)

        it("rejects invalid direction", function()
            local ok, err = plugin.check_schema({
                direction = "invalid",
                services = { ["test"] = { proto = "/x.pb" } },
            })
            assert.is_false(ok)
            assert.is_string(err)
        end)

        it("rejects missing services", function()
            local ok, err = plugin.check_schema({
                direction = "grpc2yar",
            })
            assert.is_false(ok)
            assert.is_string(err)
        end)

        it("rejects service without proto", function()
            local ok, err = plugin.check_schema({
                direction = "grpc2yar",
                services = { ["test"] = { url = "http://x" } },
            })
            assert.is_false(ok)
            assert.is_string(err)
        end)
    end)

    describe("grpc2yar direction", function()
        local conf = {
            direction = "grpc2yar",
            services = {
                ["calculator.Calculator"] = {
                    proto = "/etc/apisix/proto/calc.pb",
                    url = "http://php:8888/api.php",
                    options = { packager = "json", timeout = "5000" },
                },
            },
            yar_options = { timeout = "3000" },
            max_payload_bytes = 8388608,
        }

        it("calls bridge.setup on first access", function()
            plugin.access(conf, {})
            assert.is_true(bridge_setup_called)
            assert.is_table(bridge_setup_args.services)
        end)

        it("delegates to grpc2yar_endpoint.serve()", function()
            plugin.access(conf, {})
            assert.is_true(grpc2yar_serve_called)
        end)

        it("does not call yar2grpc.setup", function()
            plugin.access(conf, {})
            assert.is_false(yar2grpc_setup_called)
        end)

        it("does not re-setup on second access with same config", function()
            plugin.access(conf, {})
            reset()
            plugin.access(conf, {})
            assert.is_false(bridge_setup_called)
        end)
    end)

    describe("yar2grpc direction", function()
        local conf = {
            direction = "yar2grpc",
            services = {
                ["calculator.Calculator"] = {
                    proto = "/etc/apisix/proto/calc.pb",
                    methods = { "Add", "Subtract" },
                },
            },
            grpc_backend_url = "http://go-grpc:50052",
            yar_path_prefix = "/api/",
        }

        it("calls yar2grpc.setup with transport on first access", function()
            plugin.access(conf, {})
            assert.is_true(yar2grpc_setup_called)
            assert.is_not_nil(yar2grpc_setup_args.grpc_transport)
            assert.are.equal("function", type(yar2grpc_setup_args.grpc_transport))
        end)

        it("delegates to yar2grpc_endpoint.handle()", function()
            mock_ngx.var.uri = "/api/calculator.Calculator"
            plugin.access(conf, {})
            assert.is_true(yar2grpc_handle_called)
        end)

        it("parses service name from URI with prefix", function()
            mock_ngx.var.uri = "/api/calculator.Calculator"
            plugin.access(conf, {})
            assert.are.equal("calculator.Calculator", mock_ngx.var.service_name)
        end)

        it("parses service name with trailing path segment", function()
            mock_ngx.var.uri = "/api/calculator.Calculator/Add"
            plugin.access(conf, {})
            assert.are.equal("calculator.Calculator", mock_ngx.var.service_name)
        end)

        it("handles custom prefix", function()
            local conf2 = {
                direction = "yar2grpc",
                services = conf.services,
                grpc_backend_url = "http://go-grpc:50052",
                yar_path_prefix = "/rpc/",
            }
            mock_ngx.var.uri = "/rpc/calculator.Calculator"
            plugin.access(conf2, {})
            assert.are.equal("calculator.Calculator", mock_ngx.var.service_name)
        end)

        it("does not call bridge.setup (grpc2yar)", function()
            plugin.access(conf, {})
            assert.is_false(bridge_setup_called)
        end)
    end)

    describe("config change detection", function()
        it("re-runs setup when direction changes", function()
            local conf_grpc2yar = {
                direction = "grpc2yar",
                services = {
                    ["calculator.Calculator"] = {
                        proto = "/x.pb",
                        url = "http://php:8888",
                    },
                },
            }
            local conf_yar2grpc = {
                direction = "yar2grpc",
                services = {
                    ["calculator.Calculator"] = {
                        proto = "/x.pb",
                        methods = { "Add" },
                    },
                },
                grpc_backend_url = "http://go:50052",
            }

            plugin.access(conf_grpc2yar, {})
            assert.is_true(bridge_setup_called)
            assert.is_false(yar2grpc_setup_called)

            reset()
            plugin.access(conf_yar2grpc, {})
            assert.is_false(bridge_setup_called)
            assert.is_true(yar2grpc_setup_called)
        end)

        it("re-runs setup when service config changes", function()
            local conf1 = {
                direction = "grpc2yar",
                services = {
                    ["calculator.Calculator"] = {
                        proto = "/x.pb",
                        url = "http://php:8888",
                    },
                },
            }
            local conf2 = {
                direction = "grpc2yar",
                services = {
                    ["calculator.Calculator"] = {
                        proto = "/x.pb",
                        url = "http://php:9999",  -- changed URL
                    },
                },
            }

            plugin.access(conf1, {})
            assert.is_true(bridge_setup_called)

            reset()
            plugin.access(conf2, {})
            assert.is_true(bridge_setup_called)
        end)
    end)

    describe("grpc_transport (yar2grpc)", function()
        it("builds a transport that calls gRPC backend via HTTP", function()
            local conf = {
                direction = "yar2grpc",
                services = {
                    ["calculator.Calculator"] = {
                        proto = "/x.pb",
                        methods = { "Add" },
                    },
                },
                grpc_backend_url = "http://go-grpc:50052",
            }
            plugin.access(conf, {})
            assert.is_not_nil(yar2grpc_setup_args.grpc_transport)
            -- Call the transport function
            local body, code, msg = yar2grpc_setup_args.grpc_transport(
                "calculator.Calculator", "Add", "mock-grpc-frame")
            assert.are.equal("mock-frame", body)
            assert.is_nil(code)
        end)
    end)

    describe("check_schema conditional validation", function()
        it("rejects empty services table", function()
            local ok, err = plugin.check_schema({
                direction = "grpc2yar",
                services = {},
            })
            assert.is_false(ok)
            assert.is_string(err)
        end)

        it("requires grpc_backend_url for yar2grpc direction", function()
            local ok, err = plugin.check_schema({
                direction = "yar2grpc",
                services = {
                    ["test"] = { proto = "/x.pb", methods = { "Add" } },
                },
            })
            assert.is_false(ok)
            assert.is_string(err)
        end)

        it("rejects empty grpc_backend_url for yar2grpc", function()
            local ok, err = plugin.check_schema({
                direction = "yar2grpc",
                services = { ["test"] = { proto = "/x.pb" } },
                grpc_backend_url = "",
            })
            assert.is_false(ok)
            assert.is_string(err)
        end)

        it("does not require grpc_backend_url for grpc2yar", function()
            local ok, err = plugin.check_schema({
                direction = "grpc2yar",
                services = { ["test"] = { proto = "/x.pb", url = "http://x" } },
            })
            assert.is_true(ok)
            assert.is_nil(err)
        end)
    end)

    describe("ensure_setup error paths", function()
        local base_conf = {
            direction = "yar2grpc",
            services = {
                ["calculator.Calculator"] = {
                    proto = "/missing.proto",
                    methods = { "Add" },
                },
            },
            grpc_backend_url = "http://go-grpc:50052",
        }

        it("returns 500 when proto file does not exist", function()
            -- Restore real io.open so /missing.proto fails to open
            io.open = real_io_open
            mock_ngx.status = nil
            plugin.access(base_conf, {})
            assert.are.equal(mock_ngx.HTTP_INTERNAL_SERVER_ERROR, mock_ngx.status)
        end)

        it("returns 500 when proto file is empty", function()
            io.open = function(path, mode)
                if path and path:match("%.proto$") then
                    return { read = function() return "" end, close = function() end }
                end
                return real_io_open(path, mode)
            end
            mock_ngx.status = nil
            plugin.access(base_conf, {})
            assert.are.equal(mock_ngx.HTTP_INTERNAL_SERVER_ERROR, mock_ngx.status)
        end)

        it("returns 500 when pb.load fails", function()
            io.open = function(path, mode)
                if path and path:match("%.proto$") then
                    return { read = function() return "garbage" end, close = function() end }
                end
                return real_io_open(path, mode)
            end
            package.loaded["pb"] = { load = function() return false, 0 end }
            mock_ngx.status = nil
            plugin.access(base_conf, {})
            assert.are.equal(mock_ngx.HTTP_INTERNAL_SERVER_ERROR, mock_ngx.status)
            -- restore mock pb
            package.loaded["pb"] = { load = function() return true end }
        end)

        it("retries setup after a failure (not cached as initialized)", function()
            -- First: fail (pb.load returns false)
            io.open = function(path, mode)
                if path and path:match("%.proto$") then
                    return { read = function() return "x" end, close = function() end }
                end
                return real_io_open(path, mode)
            end
            package.loaded["pb"] = { load = function() return false, 0 end }
            plugin.access(base_conf, {})
            assert.are.equal(mock_ngx.HTTP_INTERNAL_SERVER_ERROR, mock_ngx.status)
            -- Second: succeed (pb.load returns true) — setup should re-run
            package.loaded["pb"] = { load = function() return true end }
            mock_ngx.status = nil
            plugin.access(base_conf, {})
            assert.is_nil(mock_ngx.status) -- no 500 on success
            assert.is_true(yar2grpc_setup_called)
        end)
    end)
end)

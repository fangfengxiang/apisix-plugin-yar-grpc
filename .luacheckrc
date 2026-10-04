-- .luacheckrc — luacheck configuration for apisix-plugin-yar-grpc
-- OpenResty/APISIX globals provided at runtime (ngx); APISIX plugin is invoked
-- as _M.access(conf, ctx) by the APISIX framework — no extra globals needed.
globals = {"ngx"}
-- Ignore 'ctx' — required by APISIX access signature _M.access(conf, ctx) but
-- the plugin may not use it (uses ngx.var directly). Analogous to Kong's
-- ignore = {"self"} for Plugin:access(conf).
ignore = {"ctx"}
-- Match stylua column_width
max_line_length = 120

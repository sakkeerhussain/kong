local helpers = require "spec.helpers"
local cjson = require "cjson"
local admin = require "spec.fixtures.admin_api"

local fixtures = {
  http_mock = {
    upstream = [[
      server {
        access_log logs/upstream_access.log;

        listen 15555;

        location /test {
          content_by_lua_block {
            local mu = require "spec.fixtures.mock_upstream"
            return mu.send_default_json_response()
          }
        }
      }
    ]],
  },
}

for _, strategy in helpers.each_strategy() do
  if strategy ~= "off" then
    for _, proto in ipairs({ "legacy", "wrpc" }) do
      local is_legacy = proto == "legacy"

      describe("vaults in #hybrid mode with #" .. strategy .. " backend [proto: " .. proto .. "]", function()
        lazy_setup(function()

          helpers.get_db_utils(strategy,
            { -- tables
              "routes",
              "services",
              "vaults",
              "plugins",
            },
            nil, -- plugins
            { -- vaults
              "env",
            }
          )

          assert(helpers.start_kong({
            role = "control_plane",
            cluster_cert = "spec/fixtures/kong_clustering.crt",
            cluster_cert_key = "spec/fixtures/kong_clustering.key",
            database = strategy,
            prefix = "servroot",
            cluster_listen = "127.0.0.1:9005",
            vaults = "bundled",
            legacy_hybrid_protocol = is_legacy,
            db_update_frequency = 1,
            plugins = "rewriter",
          }))

          helpers.setenv("MY_TEST_VALUE", "1234")

          assert(helpers.start_kong({
            role = "data_plane",
            database = "off",
            prefix = "servroot2",
            cluster_cert = "spec/fixtures/kong_clustering.crt",
            cluster_cert_key = "spec/fixtures/kong_clustering.key",
            cluster_control_plane = "127.0.0.1:9005",
            proxy_listen = "0.0.0.0:9002",
            vaults = "bundled",
            legacy_hybrid_protocol = is_legacy,
            nginx_conf = "spec/fixtures/custom_nginx.template",
            nginx_main_env = "MY_TEST_VALUE",
            plugins = "rewriter",
          }, nil, nil, fixtures))
        end)

        lazy_teardown(function()
          helpers.stop_kong("servroot2", true)
          helpers.stop_kong("servroot", true)
          helpers.unsetenv("MY_TEST_VALUE")
        end)

        it("propagates vault changes to the data-plane", function()
          local proxy

          local function wait_until_request(req, status, header)
            local ok, err = pcall(helpers.wait_until, function()
              proxy = proxy or helpers.proxy_client(nil, 9002)

              local res, err = proxy:send(req)

              if err then
                proxy:close()
                proxy = nil
                return

              elseif res.status ~= status then
                return
              end

              local body = res:read_body()
              local json = cjson.decode(body)

              return json.headers
                 and json.headers["rewriter"]
                 and json.headers["rewriter"] == header
            end, 15, 0.5)

            if not ok then
              local log = helpers.file.read("servroot/logs/error.log")

              print("\nCONTROL PLANE LOG:\n")
              print(log)
              print("\n----------------------------------------------------\n")

              log = helpers.file.read("servroot2/logs/error.log")
              print("DATA PLANE LOG:\n")
              print(log)
              print("\n----------------------------------------------------\n")

              error("SOMETHING HAS GONE AWRY, MY FRIEND:\n" .. tostring(err) .. "\n")
            end
          end

          -- 1. create a route and service
          assert(admin.routes:insert({
            name = "test",
            protocols = { "http" },
            hosts = { "test" },
          }))

          -- 2. add the `rewriter` plugin (it sets the 'rewriter' request header)
          local plugin = admin.plugins:insert({
            name = "rewriter",
            config = {
              value = "TEST",
            },
          })

          -- 3. wait for a config update
          wait_until_request({
            method = "GET",
            path = "/test",
            headers = { host = "test" },
          }, 200, "TEST")

          -- 4. add a new vault
          assert(admin.vaults:insert({
            prefix = "test",
            name = "env",
          }))

          -- 5. update our plugin to use a env var vault reference
          admin.plugins:update(plugin.id, {
            config = {
              value = "{vault://env/my_test_value}",
            },
          })

          -- 6. finally, check for the correct value
          wait_until_request({
            method = "GET",
            path = "/test",
            headers = { host = "test" },
          }, 200, "1234")
        end)
      end)
    end
  end
end

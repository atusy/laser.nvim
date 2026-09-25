local MiniTest = require("mini.test")
local expect = MiniTest.expect
local T = MiniTest.new_set()

local function client(id, name)
  return { id = id, name = name }
end

T["select follows the explicit client order"] = function()
  local clients = require("laser.clients")
  local all = { client(1, "lua_ls"), client(2, "copilot") }
  expect.equality(clients.select(all, { "copilot", "lua_ls" }, {}), { all[2], all[1] })
end

T["select returns every client when no names are configured"] = function()
  local clients = require("laser.clients")
  local all = { client(1, "lua_ls"), client(2, "copilot") }
  expect.equality(clients.select(all), all)
end

T["select drops a client whose config sets enabled = false"] = function()
  local clients = require("laser.clients")
  local all = { client(1, "lua_ls"), client(2, "copilot") }
  local got = clients.select(all, nil, { copilot = { enabled = false } })
  expect.equality(got, { client(1, "lua_ls") })
end
T['disabling "*" keeps the clients that have options of their own'] = function()
  local clients = require("laser.clients")
  local all = { client(1, "lua_ls"), client(2, "copilot") }
  local got = clients.select(all, nil, { ["*"] = { enabled = false }, lua_ls = {} })
  expect.equality(got, { client(1, "lua_ls") })
end

T["an empty client list selects none"] = function()
  expect.equality(require("laser.clients").select({ client(1, "lua_ls") }, {}), {})
end

T["wildcard expands remaining clients at its position in stable id order"] = function()
  local all = { client(4, "lua_ls"), client(3, "other"), client(2, "copilot"), client(1, "lua_ls") }
  expect.equality(require("laser.clients").select(all, { "copilot", "*", "lua_ls" }), {
    all[3],
    all[2],
    all[4],
    all[1],
  })
  expect.equality(all[1].id, 4)
end

T["repeated names and wildcards never select a client twice"] = function()
  local all = { client(1, "lua_ls"), client(2, "other") }
  expect.equality(require("laser.clients").select(all, { "lua_ls", "*", "lua_ls", "*" }), all)
end

T["options alone do not select unlisted clients"] = function()
  local all = { client(1, "lua_ls"), client(2, "copilot") }
  expect.equality(
    require("laser.clients").select(all, { "missing", "lua_ls" }, {
      copilot = { enabled = true },
    }),
    { all[1] }
  )
end

T["a disabled explicit client does not reappear in the wildcard"] = function()
  local all = { client(1, "lua_ls"), client(2, "copilot") }
  expect.equality(
    require("laser.clients").select(all, { "copilot", "*" }, {
      copilot = { enabled = false },
    }),
    { all[1] }
  )
end

T["_ holds defaults every client inherits key by key"] = function()
  local config = { _ = { timeout_ms = 1000, filters = {} }, lua_ls = { timeout_ms = 2000 } }
  local clients = require("laser.clients")
  expect.equality(clients.resolve("lua_ls", config), { timeout_ms = 2000, filters = {} })
  expect.equality(clients.resolve("copilot", config), { timeout_ms = 1000, filters = {} })
end

T["* applies only to clients without options of their own, over _"] = function()
  local config = {
    _ = { timeout_ms = 1000, max_items = 5 },
    ["*"] = { max_items = 10 },
    lua_ls = {},
  }
  local clients = require("laser.clients")
  expect.equality(clients.resolve("lua_ls", config), { timeout_ms = 1000, max_items = 5 })
  expect.equality(clients.resolve("copilot", config), { timeout_ms = 1000, max_items = 10 })
end

T["disabling _ disables clients that do not enable themselves"] = function()
  local all = { client(1, "lua_ls"), client(2, "copilot"), client(3, "other") }
  local got = require("laser.clients").select(all, nil, {
    _ = { enabled = false },
    lua_ls = { enabled = true },
    copilot = {},
  })
  expect.equality(got, { all[1] })
end

T["_ in the client list selects nothing, even a client named _"] = function()
  local all = { client(1, "lua_ls"), client(2, "_") }
  local clients = require("laser.clients")
  expect.equality(clients.select(all, { "_" }), {})
  expect.equality(clients.select(all, { "_", "*" }), all)
end

---Client whose completion is registered dynamically with `options`.
---@param registrations table one registration, as Neovim 0.11 returns, or a list
local function dynamic_client(static, registrations)
  return {
    server_capabilities = { completionProvider = static },
    dynamic_capabilities = {
      get = function()
        return registrations
      end,
    },
    supports_method = function()
      return false
    end,
  }
end

T["resolve support is read from static and dynamic completion options"] = function()
  local clients = require("laser.clients")
  local registration =
    { method = "textDocument/completion", registerOptions = { resolveProvider = true } }
  expect.equality(
    clients.supports_resolve(dynamic_client({ resolveProvider = true }, nil), 1),
    true
  )
  expect.equality(clients.supports_resolve(dynamic_client(nil, registration), 1), true)
  expect.equality(clients.supports_resolve(dynamic_client(nil, { registration }), 1), true)
  expect.equality(clients.supports_resolve(dynamic_client({}, nil), 1), false)
end

return T

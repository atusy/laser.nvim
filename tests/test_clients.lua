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
T['select keeps a named client when "*" disables the rest'] = function()
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

T["named options override shared defaults"] = function()
  expect.equality(
    require("laser.clients").resolve("lua_ls", {
      ["*"] = { timeout_ms = 1000, filters = {} },
      lua_ls = { timeout_ms = 2000 },
    }),
    { enabled = true, timeout_ms = 2000, filters = {} }
  )
end

return T

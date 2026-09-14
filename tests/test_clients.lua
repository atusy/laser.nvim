local MiniTest = require("mini.test")
local expect = MiniTest.expect
local T = MiniTest.new_set()

local function client(id, name)
  return { id = id, name = name }
end

T["select returns every client when no names are configured"] = function()
  local clients = require("laser.clients")
  local all = { client(1, "lua_ls"), client(2, "copilot") }
  expect.equality(clients.select(all, {}), all)
end

T["select drops a client whose config sets enabled = false"] = function()
  local clients = require("laser.clients")
  local all = { client(1, "lua_ls"), client(2, "copilot") }
  local got = clients.select(all, { copilot = { enabled = false } })
  expect.equality(got, { client(1, "lua_ls") })
end
T["select keeps a named client when \"*\" disables the rest"] = function()
  local clients = require("laser.clients")
  local all = { client(1, "lua_ls"), client(2, "copilot") }
  local got = clients.select(all, { ["*"] = { enabled = false }, lua_ls = {} })
  expect.equality(got, { client(1, "lua_ls") })
end

return T

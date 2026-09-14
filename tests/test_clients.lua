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

return T

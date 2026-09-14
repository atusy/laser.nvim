local MiniTest = require("mini.test")
local expect = MiniTest.expect
local T = MiniTest.new_set()

local Session = require("laser.session")

local function ctx(client_id)
  return { line = "foo.ba", startcol = 4, cursor_col = 6, encoding = "utf-8", client_id = client_id }
end

local function labels(list)
  return vim.tbl_map(function(c)
    return c.abbr
  end, list)
end

T["candidates merge results of every client that answered"] = function()
  local s = Session.new({
    startcol = 4,
    clients = { [1] = { name = "lua_ls" }, [2] = { name = "copilot" } },
  })
  s:set_result(1, { { label = "bar" } }, ctx(1))
  s:set_result(2, { items = { { label = "baz" } }, isIncomplete = false }, ctx(2))
  expect.equality(labels(s:candidates("")), { "bar", "baz" })
end

return T

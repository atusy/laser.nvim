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

T["a client with higher priority lists its candidates first"] = function()
  local s = Session.new({
    startcol = 4,
    clients = { [1] = { name = "lua_ls" }, [2] = { name = "copilot", opts = { priority = 10 } } },
  })
  s:set_result(1, { { label = "bar" } }, ctx(1))
  s:set_result(2, { { label = "baz" } }, ctx(2))
  expect.equality(labels(s:candidates("")), { "baz", "bar" })
end

T["typing into a complete list re-requests nothing"] = function()
  local s = Session.new({ startcol = 4, clients = { [1] = { name = "lua_ls" } } })
  s:set_result(1, { { label = "bar" } }, ctx(1))
  expect.equality(s:on_char("r"), {})
end

T["typing into an incomplete list re-requests that client"] = function()
  local s = Session.new({
    startcol = 4,
    clients = { [1] = { name = "lua_ls" }, [2] = { name = "copilot" } },
  })
  s:set_result(1, { items = { { label = "bar" } }, isIncomplete = true }, ctx(1))
  s:set_result(2, { { label = "baz" } }, ctx(2))
  expect.equality(s:on_char("r"), { [1] = { triggerKind = 3 } })
end

T["typing a trigger character re-requests the clients that declare it"] = function()
  local s = Session.new({
    startcol = 4,
    clients = {
      [1] = { name = "lua_ls", trigger_chars = { ".", ":" } },
      [2] = { name = "copilot" },
    },
  })
  s:set_result(1, { { label = "bar" } }, ctx(1))
  s:set_result(2, { { label = "baz" } }, ctx(2))
  expect.equality(s:on_char("."), { [1] = { triggerKind = 2, triggerCharacter = "." } })
end

return T

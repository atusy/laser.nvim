local MiniTest = require("mini.test")
local expect = MiniTest.expect
local T = MiniTest.new_set()

local Session = require("laser.session")
local doc = { bufnr = 1, mode = "i", line = "foo.bar", col = 7 }

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
  expect.equality(s:on_char("r", doc, {}), {})
end

T["typing into an incomplete list re-requests that client"] = function()
  local s = Session.new({
    startcol = 4,
    clients = { [1] = { name = "lua_ls" }, [2] = { name = "copilot" } },
  })
  s:set_result(1, { items = { { label = "bar" } }, isIncomplete = true }, ctx(1))
  s:set_result(2, { { label = "baz" } }, ctx(2))
  expect.equality(s:on_char("r", doc, {}), { [1] = { triggerKind = 3 } })
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
  expect.equality(s:on_char(".", doc, {}), { [1] = { triggerKind = 2, triggerCharacter = "." } })
end

T["different item starts are matched independently and padded to a shared menu"] = function()
  local s =
    Session.new({ startcol = 3, clients = { [1] = { name = "wide" }, [2] = { name = "narrow" } } })
  local doc = { bufnr = 1, line = "é.ba", col = 5, line_nr = 0, mode = "i" }
  local convert = {
    line = doc.line,
    line_nr = 0,
    startcol = 3,
    cursor_col = 5,
    encoding = "utf-16",
    client_id = 1,
  }
  s:set_result(1, {
    items = { { label = "é.bar" } },
    itemDefaults = {
      editRange = {
        start = { line = 0, character = 0 },
        ["end"] = { line = 0, character = 4 },
      },
    },
  }, convert)
  convert.client_id = 2
  s:set_result(2, { { label = "bar" } }, convert)
  local got, startcol = s:candidates("ba", doc)
  expect.equality(startcol, 0)
  expect.equality(labels(got), { "é.bar", "bar" })
  expect.equality({ got[1].word, got[2].word }, { "é.bar", "é.bar" })
  expect.equality(got[2].user_data.laser.startcol, 3)
  expect.equality(s.results[2].candidates[1].word, "bar")
  s.results[1] = nil
  got, startcol = s:candidates("ba", doc)
  expect.equality(startcol, 3)
  expect.equality(got[1].word, "bar")
end

T["per-client filters see each item input and preserve identity on rerender"] = function()
  local seen = {}
  local s = Session.new({
    startcol = 4,
    clients = {
      [1] = {
        name = "one",
        opts = {
          filters = {
            {
              kind = "matcher",
              callback = function(input, candidate)
                seen[#seen + 1] = input
                return true, { score = #input }
              end,
            },
            {
              kind = "converter",
              callback = function(candidate)
                candidate.abbr = candidate.abbr .. "!"
                return candidate
              end,
            },
          },
        },
      },
      [2] = { name = "two", opts = { filters = {} } },
    },
  })
  s:set_result(1, {
    { label = "bar" },
    {
      label = "foo.bar",
      textEdit = {
        newText = "foo.bar",
        range = {
          start = { line = 0, character = 0 },
          ["end"] = { line = 0, character = 6 },
        },
      },
    },
  }, ctx(1))
  s:set_result(2, { { label = "other" } }, ctx(2))
  local first = s:candidates("bar", doc)
  expect.equality(seen, { "bar", "foo.bar" })
  expect.equality(labels(first), { "bar!", "foo.bar!", "other" })
  expect.equality(first[1].user_data.laser.match_info, { score = 3 })
  expect.equality(first[3].user_data.laser.match_info, nil)
  local second = s:candidates("bar", doc)
  expect.equality(first, second)
  expect.equality(first[1].user_data.laser.id, s.results[1].candidates[1].user_data.laser.id)
  expect.equality(labels(s.results[1].candidates), { "bar", "foo.bar" })
end

return T

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

T["candidates follow the selected client order"] = function()
  local s = Session.new({
    startcol = 4,
    clients = { [1] = { name = "lua_ls", order = 2 }, [2] = { name = "copilot", order = 1 } },
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

T["only clients without filtered candidates refresh"] = function()
  local s = Session.new({
    startcol = 4,
    clients = {
      [1] = { name = "missing" },
      [2] = { name = "matching" },
      [3] = { name = "unfiltered", opts = { filters = {} } },
    },
  })
  s:set_result(1, { { label = "baz" } }, ctx(1))
  s:set_result(2, { { label = "bar" } }, ctx(2))
  s:set_result(3, { { label = "qux" } }, ctx(3))
  expect.equality(s:on_char("r", doc, {}), { [1] = { triggerKind = 1 } })
  expect.equality(s:on_char("r", doc, { [1] = {} }), {})
  local snapshot = s:refresh_context(1, doc, "r", false)
  expect.equality(require("laser.refresh").has_candidate(snapshot), false)
  s:set_result(1, { { label = "bar" } }, ctx(1))
  expect.equality(require("laser.refresh").has_candidate(snapshot), false)
  expect.equality(
    require("laser.refresh").has_candidate(s:refresh_context(1, doc, "r", false)),
    true
  )
end

T["typing into an incomplete list re-requests that client"] = function()
  local s = Session.new({
    startcol = 4,
    clients = { [1] = { name = "lua_ls" }, [2] = { name = "copilot" } },
  })
  s:set_result(1, { items = { { label = "bar" } }, isIncomplete = true }, ctx(1))
  s:set_result(2, { { label = "bar" } }, ctx(2))
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
  s:set_result(2, { { label = "bar" } }, ctx(2))
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
  expect.equality(s:refresh_context(1, doc, "a", false).has_candidate, true)
  expect.equality(s:refresh_context(2, doc, "a", false).has_candidate, true)
  local got, startcol = s:candidates("ba", doc)
  expect.equality(startcol, 0)
  expect.equality(labels(got), { "é.bar", "é.bar" })
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
  expect.equality(labels(first), { "foo.bar!", "foo.bar!", "foo.other" })
  expect.equality(first[1].user_data.laser.match_info, { score = 3 })
  expect.equality(first[3].user_data.laser.match_info, nil)
  local second = s:candidates("bar", doc)
  expect.equality(first, second)
  expect.equality(first[1].user_data.laser.id, s.results[1].candidates[1].user_data.laser.id)
  expect.equality(labels(s.results[1].candidates), { "bar", "foo.bar" })
end

T["shared labels shift abbreviation highlights by UTF-8 bytes without accumulation"] = function()
  local s =
    Session.new({ startcol = 4, clients = { [1] = { name = "file", opts = { filters = {} } } } })
  local doc = { bufnr = 1, line = "界/pr", col = 6, line_nr = 0, mode = "c" }
  s:set_result(1, { { label = "prompt.md" } }, {
    line = doc.line,
    line_nr = 0,
    startcol = 4,
    cursor_col = 6,
    encoding = "utf-8",
    client_id = 1,
  })
  s.results[1].candidates[1].highlights = {
    { type = "abbr", col = 1, width = 2, hl_group = "PmenuMatch" },
    { type = "menu", col = 1, width = 3, hl_group = "Comment" },
  }
  local projection = { startcol = 0, exclude = {} }
  local got = s:candidates("pr", doc, projection)
  expect.equality(got[1].highlights, {
    { type = "abbr", col = 5, width = 2, hl_group = "PmenuMatch" },
    { type = "menu", col = 1, width = 3, hl_group = "Comment" },
    { name = "laser_prefix", type = "abbr", col = 1, width = 4, hl_group = "Comment" },
  })
  expect.equality(s:candidates("pr", doc, projection), got)
  expect.equality(s.results[1].candidates[1].highlights[1].col, 1)
end

T["refresh contexts detect candidates without sorting them"] = function()
  local sorted = false
  local s = Session.new({
    startcol = 4,
    clients = {
      [1] = {
        name = "lua_ls",
        opts = {
          sorter = function()
            sorted = true
            return false
          end,
        },
      },
    },
  })
  s:set_result(1, { { label = "bar" }, { label = "barn" } }, ctx(1))
  expect.equality(s:refresh_context(1, doc, "r", false).has_candidate, true)
  expect.equality(sorted, false)
end

T["candidates convert only the items each client can display"] = function()
  local converted = 0
  local s = Session.new({
    startcol = 4,
    clients = {
      [1] = {
        name = "lua_ls",
        opts = {
          max_items = 1,
          filters = {
            {
              kind = "converter",
              callback = function(candidate)
                converted = converted + 1
                return candidate
              end,
            },
          },
        },
      },
    },
  })
  s:set_result(1, { { label = "bar" }, { label = "barn" } }, ctx(1))
  expect.equality(labels(s:candidates("", doc)), { "bar" })
  expect.equality(converted, 1)
end

T["candidates hidden by max_items do not widen the menu"] = function()
  local s = Session.new({
    startcol = 3,
    clients = { [1] = { name = "wide", opts = { max_items = 1, filters = {} } } },
  })
  local doc = { bufnr = 1, line = "é.ba", col = 5, line_nr = 0, mode = "i" }
  s:set_result(1, {
    { label = "bar" },
    {
      label = "é.bar",
      textEdit = {
        newText = "é.bar",
        range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 4 } },
      },
    },
  }, {
    line = doc.line,
    line_nr = 0,
    startcol = 3,
    cursor_col = 5,
    encoding = "utf-16",
    client_id = 1,
  })
  local got, startcol = s:candidates("ba", doc)
  expect.equality(startcol, 3)
  expect.equality(labels(got), { "bar" })
  expect.equality(got[1].word, "bar")
end

return T

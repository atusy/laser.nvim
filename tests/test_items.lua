local MiniTest = require("mini.test")
local expect = MiniTest.expect
local T = MiniTest.new_set()

local items = require("laser.items")

local function ctx(overrides)
  return vim.tbl_extend("force", {
    line = "foo.ba",
    startcol = 4,
    cursor_col = 6,
    encoding = "utf-8",
    client_id = 7,
  }, overrides or {})
end

T["a label-only item completes its label"] = function()
  local got = items.convert({ label = "bar" }, ctx())
  expect.equality(got.word, "bar")
  expect.equality(got.abbr, "bar")
end

T["insertText wins over label for the inserted word"] = function()
  local got = items.convert({ label = "bar()", insertText = "bar" }, ctx())
  expect.equality(got.word, "bar")
  expect.equality(got.abbr, "bar()")
end

T["a snippet item inserts its label, not the snippet body"] = function()
  local got = items.convert({
    label = "bar",
    insertText = "bar($1)$0",
    insertTextFormat = 2,
  }, ctx())
  expect.equality(got.word, "bar")
end

T["a textEdit starting at the menu start inserts newText"] = function()
  local got = items.convert({
    label = "bar()",
    textEdit = {
      newText = "bar",
      range = { start = { line = 0, character = 4 }, ["end"] = { line = 0, character = 6 } },
    },
  }, ctx())
  expect.equality(got.word, "bar")
end

T["a textEdit starting after the menu start keeps the text in between"] = function()
  -- line "foo.ba", menu replaces from column 4 (".ba" boundary is "b" at 4)
  -- but this server edits only from column 5.
  local got = items.convert({
    label = "bar()",
    textEdit = {
      newText = "ar",
      range = { start = { line = 0, character = 5 }, ["end"] = { line = 0, character = 6 } },
    },
  }, ctx())
  expect.equality(got.word, "bar")
end

T["a textEdit starting before the menu start drops the shared prefix"] = function()
  local got = items.convert({
    label = "foo.bar",
    textEdit = {
      newText = "foo.bar",
      range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 6 } },
    },
  }, ctx())
  expect.equality(got.word, "bar")
end

T["kind, detail and documentation are shown as kind, menu and info"] = function()
  local got = items.convert({
    label = "bar",
    kind = 2, -- Method
    labelDetails = { description = "fn(x)" },
    documentation = { kind = "markdown", value = "Does bar." },
  }, ctx())
  expect.equality(got.kind, "Method")
  expect.equality(got.menu, "fn(x)")
  expect.equality(got.info, "Does bar.")
end

T["user_data carries the client id and the original item"] = function()
  local item = { label = "bar", sortText = "0001", filterText = "bar" }
  local got = items.convert(item, ctx({ client_id = 42 }))
  expect.equality(got.user_data.laser.client_id, 42)
  expect.equality(got.user_data.laser.item, item)
  expect.equality(got.dup, 1)
end

T["item defaults supply insert/replace ranges and text without mutating the response"] = function()
  local item = { label = "bar", textEditText = "bar($1)", data = { own = true } }
  local range = { start = { line = 0, character = 2 }, ["end"] = { line = 0, character = 4 } }
  local got = items.with_defaults(item, {
    editRange = { insert = range, replace = range },
    insertTextFormat = 2,
    data = { default = true },
  })
  expect.equality(got.textEdit, { newText = "bar($1)", insert = range, replace = range })
  expect.equality(got.insertTextFormat, 2)
  expect.equality(got.data, { own = true })
  expect.equality(item.textEdit, nil)
  expect.equality(
    items.start_col(got, ctx({ line = "é.ba", line_nr = 0, cursor_col = 5, encoding = "utf-16" })),
    3
  )
end

T["an explicit textEdit takes precedence over list defaults"] = function()
  local item = {
    label = "bar",
    textEdit = {
      newText = "bar",
      range = {
        start = { line = 0, character = 4 },
        ["end"] = { line = 0, character = 6 },
      },
    },
  }
  local got = items.with_defaults(
    item,
    { editRange = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 6 } } }
  )
  expect.equality(got.textEdit, item.textEdit)
  expect.equality(items.start_col(got, ctx({ line_nr = 0 })), 4)
end

T["missing or inapplicable ranges fall back to the keyword boundary"] = function()
  expect.equality(items.start_col({ label = "bar" }, ctx({ line_nr = 0 })), 4)
  for _, start in ipairs({ { line = 1, character = 0 }, { line = 0, character = 8 } }) do
    expect.equality(
      items.start_col(
        { label = "bar", textEdit = { range = { start = start } } },
        ctx({ line_nr = 0 })
      ),
      4
    )
  end
end

T["file labels show the path replaced by an insert-replace edit"] = function()
  local range = { start = { line = 0, character = 2 }, ["end"] = { line = 0, character = 14 } }
  local item = {
    label = "prompt.md",
    kind = vim.lsp.protocol.CompletionItemKind.File,
    filterText = "__ignored/prompt.md",
    insertText = "__ignored/prompt.md",
    textEdit = { insert = range, replace = range, newText = "__ignored/prompt.md" },
  }
  local got = require("laser.items").convert(item, {
    line = "e __ignored/pr",
    startcol = 2,
    cursor_col = 14,
    encoding = "utf-16",
    client_id = 1,
  })
  expect.equality(got.abbr, "__ignored/prompt.md")
end

return T

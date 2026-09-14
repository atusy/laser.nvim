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

return T

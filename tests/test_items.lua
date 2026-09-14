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

return T

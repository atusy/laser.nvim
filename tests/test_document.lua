local MiniTest = require("mini.test")
local expect = MiniTest.expect
local T = MiniTest.new_set()

local document = require("laser.document")

local function doc(line, col, extra)
  return vim.tbl_extend(
    "force",
    { bufnr = 1, line_nr = 0, mode = "i", line = line, col = col },
    extra or {}
  )
end

T["a single character typed at the cursor is the inserted character"] = function()
  expect.equality(document.inserted_char(doc("fo", 2), doc("foo", 3)), "o")
  expect.equality(document.inserted_char(doc("", 0), doc("é", 2)), "é")
end

T["other changes insert no character"] = function()
  -- Pasted text, deletions, cursor moves and other lines, buffers or modes.
  expect.equality(document.inserted_char(doc("f", 1), doc("foo", 3)), "")
  expect.equality(document.inserted_char(doc("foo", 3), doc("fo", 2)), "")
  expect.equality(document.inserted_char(doc("foo", 1), doc("foo", 2)), "")
  expect.equality(document.inserted_char(doc("fo", 2), doc("foo", 3, { line_nr = 1 })), "")
  expect.equality(document.inserted_char(doc("fo", 2), doc("foo", 3, { bufnr = 2 })), "")
  expect.equality(document.inserted_char(doc("fo", 2), doc("foo", 3, { mode = "c" })), "")
  expect.equality(document.inserted_char(nil, doc("foo", 3)), "")
end

return T

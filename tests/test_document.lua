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

-- continues() reads the live mode, cursor and command line.
local child = MiniTest.new_child_neovim()

T["continues"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "scripts/minimal_init.lua" })
      child.bo.readonly = false
    end,
    post_case = function()
      child.stop()
    end,
  },
})

---Enter Insert mode at the end of `line` on row 2 of { "above", line }.
local function insert_at_end(line)
  child.api.nvim_buf_set_lines(0, 0, -1, false, { "above", line })
  child.api.nvim_win_set_cursor(0, { 2, 0 })
  child.api.nvim_input("A")
end

local function continues(doc, startcol)
  return child.lua_get("require('laser.document').continues(...)", { doc, startcol })
end

T["continues"]["the same line with other text between start and cursor"] = function()
  insert_at_end("foo.bar)")
  child.api.nvim_input("<Left>")
  local bufnr = child.api.nvim_get_current_buf()
  local doc = { bufnr = bufnr, line_nr = 1, line = "foo.b)", col = 5, mode = "i" }
  -- The menu replaced "b" with "bar".
  expect.equality(continues(doc, 4), true)
end

T["continues"]["not another line, buffer, suffix, mode, or a cursor before the start"] = function()
  insert_at_end("foo.b)")
  child.api.nvim_input("<Left>")
  local bufnr = child.api.nvim_get_current_buf()
  local doc = { bufnr = bufnr, line_nr = 1, line = "foo.b)", col = 5, mode = "i" }
  expect.equality(continues(doc, 4), true)
  expect.equality(continues(vim.tbl_extend("force", doc, { line_nr = 0 }), 4), false)
  expect.equality(continues(vim.tbl_extend("force", doc, { bufnr = bufnr + 1 }), 4), false)
  expect.equality(continues(vim.tbl_extend("force", doc, { line = "foo.b]" }), 4), false)
  expect.equality(continues(vim.tbl_extend("force", doc, { mode = "c" }), 4), false)
  child.api.nvim_input("<Left><Left>")
  expect.equality(continues(doc, 4), false)
end

T["continues"]["the command line compares its text and position"] = function()
  child.api.nvim_input(":echo x")
  local doc = { bufnr = 0, line_nr = 0, line = "echo x", col = 6, mode = "c" }
  expect.equality(continues(doc, 5), true)
  -- The text before the start differs.
  expect.equality(continues(vim.tbl_extend("force", doc, { line = "call x" }), 5), false)
end

return T

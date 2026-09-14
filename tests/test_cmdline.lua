local MiniTest = require("mini.test")
local expect = MiniTest.expect
local T = MiniTest.new_set()

local cmdline = require("laser.cmdline")

T["each languageId gets its own scratch document"] = function()
  local a = cmdline.ensure_buffer("laser-a")
  local b = cmdline.ensure_buffer("laser-b")
  expect.no_equality(a.bufnr, b.bufnr)
  expect.equality(a.uri, "untitled://laser-cmdline/laser-a")
  expect.equality(vim.bo[a.bufnr].filetype, "laser-a")
  expect.equality(vim.bo[a.bufnr].buftype, "nofile")
end

T["a wiped scratch document is recreated under the same uri"] = function()
  local first = cmdline.ensure_buffer("laser-wipe")
  vim.api.nvim_buf_delete(first.bufnr, { force = true })
  local second = cmdline.ensure_buffer("laser-wipe")
  expect.no_equality(first.bufnr, second.bufnr)
  expect.equality(second.uri, first.uri)
  expect.equality(vim.api.nvim_buf_is_loaded(second.bufnr), true)
end

T["set_text mirrors the command line into the document"] = function()
  local doc = cmdline.ensure_buffer("laser-text")
  cmdline.set_text(doc.bufnr, "echo 'hi'")
  expect.equality(vim.api.nvim_buf_get_lines(doc.bufnr, 0, -1, false), { "echo 'hi'" })
end

return T

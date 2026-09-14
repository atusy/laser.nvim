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

T["a document that lost its clients re-fires FileType so they can attach"] = function()
  local fake = require("tests.helpers.fake_server")
  local doc = cmdline.ensure_buffer("laser-attach")
  expect.equality(#cmdline.get_clients(doc.bufnr, "laser-attach"), 0)

  -- The user enables a client only after the command line was first opened.
  local attached = 0
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "laser-attach",
    once = true,
    callback = function(ev)
      fake.start({ name = "late", items = {} }, ev.buf)
      attached = attached + 1
    end,
  })
  local again = cmdline.ensure_buffer("laser-attach")
  expect.equality(again.bufnr, doc.bufnr)
  expect.equality(attached, 1)
  expect.equality(
    vim.tbl_map(function(c)
      return c.name
    end, cmdline.get_clients(doc.bufnr, "laser-attach")),
    { "late" }
  )
  fake.stop_all()
end

return T

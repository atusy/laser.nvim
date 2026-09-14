local MiniTest = require("mini.test")
local expect = MiniTest.expect

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "scripts/minimal_init.lua" })
      child.bo.readonly = false
      child.lua([[
        FAKE = require("tests.helpers.fake_server")
        require("laser").setup({})
        vim.keymap.set("i", "<C-n>", function() vim.fn["pum#map#insert_relative"](1) end)
      ]])
    end,
    post_case = child.stop,
  },
})

---pum.vim runs `silent! matchdelete()` while redrawing, which leaves E803 in
---v:errmsg and makes child.type_keys() raise; feed input directly instead.
local function type_keys(keys)
  child.api.nvim_input(keys)
  child.lua([[vim.wait(20)]])
  child.v.errmsg = ""
end

local function wait_pum_items(n)
  local ok = child.lua_get(string.format(
    [[
    vim.wait(1000, function()
      local visible = vim.fn["pum#visible"]()
      return (visible == true or visible == 1) and #vim.fn["pum#complete_info"]().items >= %d
    end)
  ]],
    n
  ))
  assert(ok, "pum did not show " .. n .. " items")
end

local function pum_labels()
  return child.lua_get(
    [[vim.tbl_map(function(i) return i.abbr end, vim.fn["pum#complete_info"]().items)]]
  )
end

T["typing in Insert mode opens pum.vim with the attached client's items"] = function()
  child.lua(
    [[FAKE.start({ name = "one", items = { { label = "bar" }, { label = "baz" }, { label = "qux" } } })]]
  )
  type_keys("ib")
  wait_pum_items(2)
  expect.equality(pum_labels(), { "bar", "baz" })

  type_keys("az")
  child.lua([[vim.wait(200, function() return #vim.fn["pum#complete_info"]().items == 1 end)]])
  expect.equality(pum_labels(), { "baz" })
end

T["confirming a snippet item expands it in the buffer"] = function()
  child.lua([[FAKE.start({
    name = "one",
    items = { { label = "bar", insertText = "bar($1)$0", insertTextFormat = 2 } },
  })]])
  child.lua([[vim.keymap.set("i", "<C-y>", function() vim.fn["pum#map#confirm"]() end)]])
  type_keys("ib")
  wait_pum_items(1)

  type_keys("<C-n>")
  child.lua([[vim.wait(50)]])
  type_keys("<C-y>")
  child.lua([[vim.wait(200, function() return vim.api.nvim_get_current_line() == "bar()" end)]])

  expect.equality(child.api.nvim_get_current_line(), "bar()")
  expect.equality(child.api.nvim_win_get_cursor(0), { 1, 4 })
end

T["the command line completes through the scratch document"] = function()
  child.lua([[
    require("laser").setup({ cmdline = { [":"] = { language_id = "laser-cmd" } } })
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "laser-cmd",
      callback = function(ev)
        FAKE.start({ name = "cmd", items = { { label = "echo" }, { label = "edit" } } }, ev.buf)
      end,
    })
  ]])
  type_keys(":e")
  wait_pum_items(2)
  expect.equality(pum_labels(), { "echo", "edit" })
  expect.equality(child.api.nvim_get_mode().mode, "c")
end

T["moving the selection does not reopen the menu"] = function()
  child.lua([[FAKE.start({ name = "one", items = { { label = "bar" }, { label = "baz" } } })]])
  type_keys("ib")
  wait_pum_items(2)

  type_keys("<C-n>")
  child.lua([[vim.wait(100)]])

  expect.equality(child.api.nvim_get_current_line(), "bar")
  expect.equality(child.lua_get([[vim.fn["pum#complete_info"]().selected]]), 0)
end

return T

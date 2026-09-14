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
  local ok = child.lua_get(string.format([[
    vim.wait(1000, function()
      local visible = vim.fn["pum#visible"]()
      return (visible == true or visible == 1) and #vim.fn["pum#complete_info"]().items >= %d
    end)
  ]], n))
  assert(ok, "pum did not show " .. n .. " items")
end

local function pum_labels()
  return child.lua_get([[vim.tbl_map(function(i) return i.abbr end, vim.fn["pum#complete_info"]().items)]])
end

T["typing in Insert mode opens pum.vim with the attached client's items"] = function()
  child.lua([[FAKE.start({ name = "one", items = { { label = "bar" }, { label = "baz" }, { label = "qux" } } })]])
  type_keys("ib")
  wait_pum_items(2)
  expect.equality(pum_labels(), { "bar", "baz" })

  type_keys("az")
  child.lua([[vim.wait(200, function() return #vim.fn["pum#complete_info"]().items == 1 end)]])
  expect.equality(pum_labels(), { "baz" })
end

return T

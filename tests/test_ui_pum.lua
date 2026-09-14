local MiniTest = require("mini.test")
local expect = MiniTest.expect
local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      vim.fn["pum#close"]()
    end,
  },
})

local function candidate(label)
  return { word = label, abbr = label, user_data = { laser = { client_id = 1, item = { label = label } } } }
end

T["open shows the candidates in pum.vim and close hides them"] = function()
  local ui = require("laser.ui.pum").new()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "foo.ba" })

  ui.open(5, { candidate("bar"), candidate("baz") }, "i")
  expect.equality(ui.visible(), true)
  expect.equality(vim.fn["pum#complete_info"]().items, { candidate("bar"), candidate("baz") })

  ui.close()
  expect.equality(ui.visible(), false)
end

return T

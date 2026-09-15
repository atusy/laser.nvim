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
  return {
    word = label,
    abbr = label,
    user_data = { laser = { client_id = 1, item = { label = label } } },
  }
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

T["a pum.vim confirm reaches the on_confirm callback with the candidate"] = function()
  local confirmed = {}
  local ui = require("laser.ui.pum").new({
    on_confirm = function(candidate)
      table.insert(confirmed, candidate)
    end,
  })
  ui.open(5, { candidate("bar") }, "i")

  -- What pum.vim does after pum#map#confirm(): sets the item and fires the event.
  vim.g["pum#completed_item"] = candidate("bar")
  vim.g["pum#completed_event"] = "confirm"
  vim.api.nvim_exec_autocmds("User", { pattern = "PumCompleteDone", modeline = false })

  expect.equality(confirmed, { candidate("bar") })
end

T["a plain close is not reported as a confirm"] = function()
  local confirmed = 0
  local ui = require("laser.ui.pum").new({
    on_confirm = function()
      confirmed = confirmed + 1
    end,
  })
  ui.open(5, { candidate("bar") }, "i")
  vim.g["pum#completed_item"] = candidate("bar")
  vim.g["pum#completed_event"] = "complete_done"
  vim.api.nvim_exec_autocmds("User", { pattern = "PumCompleteDone", modeline = false })
  expect.equality(confirmed, 0)
end

T["in-place updates apply column highlights to new tail items"] = function()
  local ui = require("laser.ui.pum").new()
  vim.fn["pum#set_option"]({
    max_height = 1,
    auto_select = false,
    highlight_columns = { kind = "Type" },
  })
  local first, second, third = candidate("bar"), candidate("baz"), candidate("bat")
  first.kind, second.kind, third.kind = "Text", "Text", "Text"
  ui.open(1, { first, second }, "i")
  vim.fn["pum#map#select_relative"](1)
  ui.update(1, { first, second, third }, "i")
  local pum = vim.fn["pum#_get"]()
  local marks = vim.api.nvim_buf_get_extmarks(
    pum.buf,
    pum.namespace,
    { 2, 0 },
    { 2, -1 },
    { details = true }
  )
  local groups = vim.tbl_map(function(mark)
    return mark[4].hl_group
  end, marks)
  expect.equality(vim.list_contains(groups, "Type"), true)
  vim.fn["pum#set_option"]({ max_height = 0, highlight_columns = {} })
end

return T

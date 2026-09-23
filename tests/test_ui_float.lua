local MiniTest = require("mini.test")
local expect = MiniTest.expect

local Float = require("laser.ui.float")
local current

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      vim.cmd("enew!")
      vim.o.lines, vim.o.columns = 40, 120
    end,
    post_case = function()
      if current then
        current.close()
        current = nil
      end
    end,
  },
})

local function candidate(label, extra)
  return vim.tbl_extend("force", {
    word = label,
    abbr = label,
    user_data = { laser = { client_id = 1, item = { label = label } } },
  }, extra or {})
end

local function new(opts)
  current = Float.new(opts)
  return current
end

---@param line string
local function set_line(line)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { line })
  vim.api.nvim_win_set_cursor(0, { 1, #line })
end

local function rows(ui)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(ui.win()), 0, -1, false)
end

T["open shows aligned columns under the completion start and close hides them"] = function()
  set_line("foo.ba")
  local ui = new()
  ui.open(5, {
    candidate("bar", { kind = "Field", menu = "string" }),
    candidate("barbaz", { kind = "Method" }),
  }, "i")
  expect.equality(ui.visible(), true)
  expect.equality(rows(ui), { "bar    Field  string", "barbaz Method       " })
  local config = vim.api.nvim_win_get_config(ui.win())
  local start = vim.fn.screenpos(0, 1, 5)
  expect.equality(vim.fn.win_screenpos(ui.win()), { start.row + 1, start.col })
  expect.equality({ config.width, config.height }, { 20, 2 })
  expect.equality(config.focusable, false)

  ui.close()
  expect.equality(ui.visible(), false)
end

T["only visible rows are rendered for long lists"] = function()
  set_line("b")
  local items = {}
  for i = 1, 1000 do
    items[i] = candidate("b" .. i)
  end
  local ui = new()
  ui.configure({ max_height = 3 })
  ui.open(1, items, "i")
  expect.equality(rows(ui), { "b1   ", "b2   ", "b3   " })
  expect.equality(vim.api.nvim_win_get_height(ui.win()), 3)
end

T["update replaces candidates in the open window"] = function()
  set_line("b")
  local ui = new()
  ui.open(1, { candidate("bar") }, "i")
  local win = ui.win()
  ui.update(1, { candidate("bar"), candidate("baz") }, "i")
  expect.equality(ui.win(), win)
  expect.equality(rows(ui), { "bar", "baz" })
end

T["item highlights are drawn in their columns"] = function()
  set_line("b")
  local ui = new()
  ui.open(1, {
    candidate("bar", {
      kind = "Field",
      highlights = {
        { type = "abbr", col = 1, width = 1, hl_group = "PmenuMatch" },
        { type = "kind", col = 2, width = 3, hl_group = "Special" },
      },
    }),
  }, "i")
  local marks =
    vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(ui.win()), -1, 0, -1, { details = true })
  local got = {}
  for _, mark in ipairs(marks) do
    local details = mark[4]
    if details.hl_group == "PmenuMatch" or details.hl_group == "Special" then
      got[#got + 1] = { details.hl_group, mark[3], details.end_col }
    end
  end
  table.sort(got, function(a, b)
    return a[2] < b[2]
  end)
  expect.equality(got, { { "PmenuMatch", 0, 1 }, { "Special", 5, 8 } })
end

local function labels(n)
  local items = {}
  for i = 1, n do
    items[i] = candidate("b" .. i)
  end
  return items
end

T["browsing freezes the seen rows, grows on scroll and reset releases it"] = function()
  set_line("b")
  local ui = new()
  ui.configure({ max_height = 3 })
  ui.open(1, labels(9), "i")
  expect.equality(ui.frozen_count(), 0)
  ui.select_relative(1)
  expect.equality(ui.frozen_count(), 3)
  ui.select_relative(4)
  expect.equality(ui.frozen_count(), 5)
  ui.select_relative(-4)
  expect.equality(ui.frozen_count(), 5)
  ui.reset()
  expect.equality(ui.frozen_count(), 0)
end

T["update keeps the selection and viewport of a frozen prefix"] = function()
  set_line("b")
  local ui = new()
  ui.configure({ max_height = 2 })
  local items = labels(3)
  ui.open(1, items, "i")
  ui.select_relative(2)
  table.insert(items, 3, candidate("b0"))
  ui.update(1, items, "i")
  expect.equality(ui.selected(), 2)
  expect.equality(rows(ui), { "b1", "b2" })
end

T["auto_select highlights the first candidate without freezing the menu"] = function()
  set_line("b")
  local ui = new()
  ui.configure({ auto_select = true })
  ui.open(1, labels(2), "i")
  expect.equality(ui.selected(), 1)
  expect.equality(ui.frozen_count(), 0)
  expect.equality(vim.api.nvim_get_current_line(), "b")
end

return T

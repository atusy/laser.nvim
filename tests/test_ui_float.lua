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

local function marks(ui)
  local buf = vim.api.nvim_win_get_buf(ui.win())
  return vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
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
  expect.equality(rows(ui), { "b1    ", "b2    ", "b3    " })
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
  local marks = marks(ui)
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
  expect.equality(rows(ui), { "b1 ", "b2 " })
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

---Put the cursor on the last screen row of a long buffer.
local function cursor_at_bottom()
  local lines = {}
  for i = 1, 200 do
    lines[i] = ""
  end
  lines[200] = "b"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, { 200, 1 })
  vim.cmd("normal! zb")
end

local function cursor_row()
  return vim.fn.win_screenpos(0)[1] + vim.fn.winline() - 1
end

T["the menu opens above the cursor when there is more room there"] = function()
  cursor_at_bottom()
  local ui = new()
  ui.open(1, labels(3), "i")
  expect.equality(vim.fn.win_screenpos(ui.win())[1], cursor_row() - 3)
  expect.equality(rows(ui), { "b1", "b2", "b3" })
end

T["reversed menus above the cursor put the first candidate nearest to it"] = function()
  cursor_at_bottom()
  local ui = new()
  ui.configure({ reversed = true })
  ui.open(1, labels(3), "i")
  expect.equality(rows(ui), { "b3", "b2", "b1" })
  ui.select_relative(1)
  local sel = marks(ui)
  sel = vim.tbl_filter(function(mark)
    return mark[4].line_hl_group == "PmenuSel"
  end, sel)
  expect.equality(sel[1][2], 2)
end

T["an explicit direction limits the height to the room on that side"] = function()
  cursor_at_bottom()
  local ui = new()
  ui.configure({ direction = "below", max_height = 20 })
  ui.open(1, labels(20), "i")
  local room = vim.o.lines - vim.o.cmdheight - cursor_row()
  expect.equality(vim.api.nvim_win_get_height(ui.win()), math.max(room, 1))
end

T["a scrollbar marks the viewport when candidates overflow"] = function()
  set_line("b")
  local ui = new()
  ui.configure({ max_height = 2 })
  ui.open(1, labels(4), "i")
  expect.equality(rows(ui), { "b1 ", "b2 " })
  local function thumb()
    local found = {}
    for _, mark in ipairs(marks(ui)) do
      if mark[4].hl_group == "PmenuThumb" then
        found[#found + 1] = mark[2]
      end
    end
    return found
  end
  expect.equality(thumb(), { 0 })
  ui.select_relative(4)
  expect.equality(thumb(), { 1 })
end

local function fake_client()
  local client = { callbacks = {}, cancelled = {} }
  function client.supports_method()
    return true
  end
  function client.request(_, _, _, callback)
    client.callbacks[#client.callbacks + 1] = callback
    return true, #client.callbacks
  end
  function client.cancel_request(_, id)
    client.cancelled[#client.cancelled + 1] = id
  end
  return client
end

local function documented(label, documentation)
  local item = candidate(label)
  item.user_data.laser.item.documentation = documentation
  return item
end

T["preview shows the selected documentation beside the menu"] = function()
  set_line("b")
  local ui = new()
  ui.configure({ preview = true })
  ui.open(1, {
    documented("markdown", { kind = "markdown", value = "**bold**" }),
    documented("plain", { kind = "plaintext", value = "text" }),
    candidate("none"),
  }, "i")
  expect.equality(ui.preview_win(), nil)
  ui.select_relative(1)
  local preview = ui.preview_win()
  local buf = vim.api.nvim_win_get_buf(preview)
  expect.equality(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "**bold**" })
  expect.equality(vim.bo[buf].filetype, "markdown")
  local menu_pos = vim.fn.win_screenpos(ui.win())
  expect.equality(
    vim.fn.win_screenpos(preview),
    { menu_pos[1], menu_pos[2] + vim.api.nvim_win_get_width(ui.win()) }
  )
  ui.select_relative(1)
  expect.equality(vim.bo[vim.api.nvim_win_get_buf(ui.preview_win())].filetype, "")
  ui.select_relative(1)
  expect.equality(ui.preview_win(), nil)
end

T["preview resolves the selection and ignores answers after switching or closing"] = function()
  set_line("b")
  local client = fake_client()
  local ui = new({
    preview_context = function()
      return { client = client, bufnr = 0 }
    end,
  })
  ui.configure({ preview = true })
  ui.open(1, { candidate("foo"), candidate("bar") }, "i")
  ui.select_relative(1)
  ui.select_relative(1)
  expect.equality(client.cancelled, { 1 })
  client.callbacks[1](nil, { documentation = "stale" })
  client.callbacks[2](nil, {
    detail = "bar()",
    documentation = { kind = "markdown", value = "Current docs" },
  })
  local buf = vim.api.nvim_win_get_buf(ui.preview_win())
  expect.equality(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "bar()", "", "Current docs" })
  expect.equality(vim.bo[buf].filetype, "markdown")
  ui.select_relative(-1)
  ui.close()
  client.callbacks[3](nil, { documentation = "late" })
  expect.equality(client.cancelled, { 1, 3 })
  expect.equality(ui.preview_win(), nil)
end

T["preview can be toggled and scrolled"] = function()
  set_line("b")
  local ui = new()
  ui.configure({ preview = { max_height = 2 } })
  ui.open(1, { documented("long", "1\n2\n3\n4") }, "i")
  ui.select_relative(1)
  expect.equality(vim.api.nvim_win_get_height(ui.preview_win()), 2)
  expect.equality(ui.scroll_preview(2), true)
  expect.equality(vim.fn.line("w0", ui.preview_win()), 3)
  expect.equality(ui.toggle_preview(), true)
  expect.equality(ui.preview_win(), nil)
  ui.toggle_preview()
  expect.equality(vim.fn.line("w0", ui.preview_win()), 1)
end

T["preview reapplies a filetype only when it changes"] = function()
  set_line("b")
  local ui = new()
  ui.configure({ preview = true })
  ui.open(1, {
    documented("a", { kind = "markdown", value = "a" }),
    documented("b", { kind = "markdown", value = "b" }),
  }, "i")
  local count = 0
  local id = vim.api.nvim_create_autocmd("FileType", {
    pattern = "markdown",
    callback = function()
      count = count + 1
    end,
  })
  ui.select_relative(1)
  ui.select_relative(1)
  vim.api.nvim_del_autocmd(id)
  expect.equality(count, 1)
end

T["control characters in fields are shown as spaces"] = function()
  set_line("b")
  local ui = new()
  ui.open(1, { candidate("a\nb", { kind = "x\ty" }) }, "i")
  expect.equality(rows(ui), { "a b x y" })
  expect.equality(vim.api.nvim_win_get_width(ui.win()), 7)
end

---Display column of byte `col` (1-based) in the current line, 0-based on screen.
local function screen_col(col)
  local line = vim.api.nvim_get_current_line()
  return vim.fn.win_screenpos(0)[2] - 1 + vim.fn.strdisplaywidth(line:sub(1, col - 1))
end

T["the menu starts under the completion start across tabs"] = function()
  set_line("x.a\tb")
  vim.api.nvim_win_set_cursor(0, { 1, 4 })
  local ui = new()
  ui.open(3, { candidate("a\tbc") }, "i")
  local config = vim.api.nvim_win_get_config(ui.win())
  expect.equality(config.col, screen_col(3))
end

T["a menu near the right edge stays on screen"] = function()
  vim.o.columns = 20
  set_line(string.rep("x", 18) .. "b")
  local ui = new()
  ui.open(19, { candidate("barbazqux") }, "i")
  local config = vim.api.nvim_win_get_config(ui.win())
  expect.equality(config.col + config.width, 20)
end

T["a bordered menu aligns its text with the completion start"] = function()
  set_line("foo.ba")
  local ui = new()
  ui.configure({ border = "single" })
  ui.open(5, { candidate("bar") }, "i")
  local config = vim.api.nvim_win_get_config(ui.win())
  expect.equality(config.col + 1, screen_col(5))
end

return T

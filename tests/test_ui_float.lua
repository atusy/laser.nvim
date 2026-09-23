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
  ui.select(1, { insert = false })
  expect.equality(ui.frozen_count(), 3)
  ui.select(4, { insert = false })
  expect.equality(ui.frozen_count(), 5)
  ui.select(-4, { insert = false })
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
  ui.select(2, { insert = false })
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
  ui.select(1, { insert = false })
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
  ui.select(4, { insert = false })
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
  ui.select(1, { insert = false })
  local preview = ui.preview_win()
  local buf = vim.api.nvim_win_get_buf(preview)
  expect.equality(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "**bold**" })
  expect.equality(vim.bo[buf].filetype, "markdown")
  local menu_pos = vim.fn.win_screenpos(ui.win())
  expect.equality(
    vim.fn.win_screenpos(preview),
    { menu_pos[1], menu_pos[2] + vim.api.nvim_win_get_width(ui.win()) }
  )
  ui.select(1, { insert = false })
  expect.equality(vim.bo[vim.api.nvim_win_get_buf(ui.preview_win())].filetype, "")
  ui.select(1, { insert = false })
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
  ui.select(1, { insert = false })
  ui.select(1, { insert = false })
  expect.equality(client.cancelled, { 1 })
  client.callbacks[1](nil, { documentation = "stale" })
  client.callbacks[2](nil, {
    detail = "bar()",
    documentation = { kind = "markdown", value = "Current docs" },
  })
  local buf = vim.api.nvim_win_get_buf(ui.preview_win())
  expect.equality(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "bar()", "", "Current docs" })
  expect.equality(vim.bo[buf].filetype, "markdown")
  ui.select(-1, { insert = false })
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
  ui.select(1, { insert = false })
  expect.equality(vim.api.nvim_win_get_height(ui.preview_win()), 2)
  expect.equality(ui.scroll_preview(2), true)
  expect.equality(vim.fn.line("w0", ui.preview_win()), 3)
  expect.equality(ui.scroll_preview(0), false)
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
  ui.select(1, { insert = false })
  ui.select(1, { insert = false })
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

T["the preview does not cover a menu shifted from the right edge"] = function()
  vim.o.columns = 40
  set_line(string.rep("x", 30) .. "b")
  local ui = new()
  ui.configure({ preview = { max_width = 10 } })
  ui.open(31, { documented("barbazquxquux", "docs") }, "i")
  ui.select(1, { insert = false })
  -- Compare where the windows are drawn, after Neovim has fitted them.
  vim.cmd("redraw")
  local function span(win)
    local col = vim.fn.win_screenpos(win)[2]
    return col, col + vim.api.nvim_win_get_width(win)
  end
  local menu_first, menu_last = span(ui.win())
  local preview_first, preview_last = span(ui.preview_win())
  local overlaps = preview_first < menu_last and menu_first < preview_last
  expect.equality(overlaps, false)
end

T["the preview follows a menu widened by an update"] = function()
  set_line("b")
  local ui = new()
  ui.configure({ preview = true })
  local items = { documented("b1", "docs") }
  ui.open(1, items, "i")
  ui.select(1, { insert = false })
  items[2] = candidate("b" .. string.rep("x", 20))
  ui.update(1, items, "i")
  local menu = vim.api.nvim_win_get_config(ui.win())
  local preview = vim.api.nvim_win_get_config(ui.preview_win())
  expect.equality(preview.col, menu.col + menu.width)
end

T["closing the menu window from outside tears the menu down"] = function()
  set_line("b")
  local client = fake_client()
  local ui = new({
    preview_context = function()
      return { client = client, bufnr = 0 }
    end,
  })
  ui.configure({ preview = true })
  ui.open(1, { documented("foo", "docs") }, "i")
  ui.select(1, { insert = false })
  local preview = ui.preview_win()
  vim.api.nvim_win_close(ui.win(), true)
  expect.equality(vim.api.nvim_win_is_valid(preview), false)
  expect.equality(client.cancelled, { 1 })
  client.callbacks[1](nil, { documentation = "late" })
  expect.equality(ui.preview_win(), nil)
end

T["wide fields are truncated by display width, dropping minor columns first"] = function()
  set_line("b")
  local ui = new()
  ui.configure({ max_width = 12 })
  ui.open(1, {
    candidate("日本語テキスト", {
      kind = "Kind",
      menu = "説明",
      highlights = { { type = "abbr", col = 4, width = 6, hl_group = "PmenuMatch" } },
    }),
  }, "i")
  local got = rows(ui)
  expect.equality(got, { "日本語テキス" })
  expect.equality(vim.api.nvim_strwidth(got[1]), 12)
  expect.equality(vim.api.nvim_win_get_width(ui.win()), 12)
  local match = vim.tbl_filter(function(mark)
    return mark[4].hl_group == "PmenuMatch"
  end, marks(ui))[1]
  expect.equality({ match[3], match[4].end_col }, { 3, 9 })
end

T["highlights on truncated text do not spill onto padding"] = function()
  set_line("b")
  local ui = new()
  ui.configure({ max_width = 11 })
  ui.open(1, {
    candidate("日本語テキスト", {
      highlights = { { type = "abbr", col = 16, width = 3, hl_group = "PmenuMatch" } },
    }),
  }, "i")
  expect.equality(rows(ui), { "日本語テキ " })
  local match = vim.tbl_filter(function(mark)
    return mark[4].hl_group == "PmenuMatch"
  end, marks(ui))
  expect.equality(match, {})
end

T["resolved documentation is reused until the menu closes"] = function()
  set_line("b")
  local client = fake_client()
  local ui = new({
    preview_context = function()
      return { client = client, bufnr = 0 }
    end,
  })
  ui.configure({ preview = true })
  local items = { candidate("foo"), candidate("bar") }
  items[1].user_data.laser.id, items[2].user_data.laser.id = 1, 2
  ui.open(1, items, "i")
  ui.select(1, { insert = false })
  client.callbacks[1](nil, { documentation = "foo docs" })
  ui.select(1, { insert = false })
  ui.select(-1, { insert = false })
  expect.equality(#client.callbacks, 2)
  local buf = vim.api.nvim_win_get_buf(ui.preview_win())
  expect.equality(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "foo docs" })
  ui.close()
  ui.open(1, items, "i")
  ui.select(1, { insert = false })
  expect.equality(#client.callbacks, 3)
end

T["single steps cycle through the typed input and larger moves stop at the ends"] = function()
  set_line("b")
  local ui = new()
  ui.open(1, labels(5), "i")
  local function move(delta)
    ui.select(delta, { insert = false })
    return ui.selected()
  end
  expect.equality(move(3), 3)
  expect.equality(move(10), 5)
  expect.equality(move(1), 0)
  expect.equality(move(-1), 5)
  expect.equality(move(-10), 1)
  expect.equality(move(-1), 0)
  expect.equality(move(-10), 1)
  expect.equality(move(1), 2)
end

T["the menu and preview use pumblend"] = function()
  set_line("b")
  local blend = vim.o.pumblend
  vim.o.pumblend = 20
  local ui = new()
  ui.configure({ preview = true })
  ui.open(1, { documented("b1", "docs") }, "i")
  ui.select(1, { insert = false })
  local got = { vim.wo[ui.win()].winblend, vim.wo[ui.preview_win()].winblend }
  vim.o.pumblend = blend
  expect.equality(got, { 20, 20 })
end

return T

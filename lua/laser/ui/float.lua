---Built-in completion menu drawn in a floating window. Only the rows inside the
---viewport are rendered, so long candidate lists cost little to show.
local M = {}

local ns = vim.api.nvim_create_namespace("laser.ui.float")
local COLUMNS = { "abbr", "kind", "menu" }

---@class laser.MenuOpts
---@field max_height? integer rows shown at once; defaults to 'pumheight' or 10
---@field max_width? integer columns shown at once; defaults to 80
---@field border? string|string[] nvim_open_win() border

---@param opts laser.MenuOpts
---@return integer
local function max_height(opts)
  if opts.max_height and opts.max_height > 0 then
    return opts.max_height
  end
  return vim.o.pumheight > 0 and vim.o.pumheight or 10
end

---@param item table
---@param name string
---@return string
local function field(item, name)
  if name == "abbr" then
    return item.abbr or item.word or ""
  end
  return item[name] or ""
end

---Cut `text` to at most `width` display cells and pad it to exactly `width`.
---@param text string
---@param width integer
---@return string
local function fit(text, width)
  local cells = vim.api.nvim_strwidth(text)
  if cells > width then
    local chars = vim.fn.strchars(text)
    while chars > 0 and cells > width do
      chars = chars - 1
      text = vim.fn.strcharpart(text, 0, chars)
      cells = vim.api.nvim_strwidth(text)
    end
  end
  return text .. string.rep(" ", width - cells)
end

---Column widths over every candidate, so the menu does not jitter on scroll.
---@param items table[]
---@param limit integer
---@return table<string, integer>
local function measure(items, limit)
  local widths = {}
  for _, name in ipairs(COLUMNS) do
    local width = 0
    for _, item in ipairs(items) do
      width = math.max(width, vim.api.nvim_strwidth(field(item, name)))
    end
    widths[name] = width
  end
  -- Give up the least important columns first when the menu is too wide.
  for _, name in ipairs({ "menu", "kind", "abbr" }) do
    local total, shown = 0, 0
    for _, other in ipairs(COLUMNS) do
      if widths[other] > 0 then
        total, shown = total + widths[other], shown + 1
      end
    end
    local excess = total + math.max(shown - 1, 0) - limit
    if excess <= 0 then
      break
    end
    widths[name] = math.max(widths[name] - excess, 0)
  end
  return widths
end

---@param opts? { on_confirm?: fun(candidate: table), on_close?: fun() }
---@return laser.UI
function M.new(opts)
  opts = opts or {}
  local ui = {}
  local menu = {} ---@type laser.MenuOpts
  local buf, win
  local items, widths = {}, {}
  local top = 1

  function ui.configure(options)
    menu = options or {}
  end

  ---@return integer?
  function ui.win()
    return win
  end

  local function ensure_buf()
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
      buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].bufhidden = "hide"
    end
    return buf
  end

  local function height()
    return math.min(#items, max_height(menu))
  end

  ---@param item table
  ---@return string line
  ---@return table<string, { [1]: integer, [2]: integer }> spans 0-based byte range of each field
  local function format(item)
    local parts, spans, offset = {}, {}, 0
    for _, name in ipairs(COLUMNS) do
      if widths[name] > 0 then
        local text = fit(field(item, name), widths[name])
        if #parts > 0 then
          offset = offset + 1
        end
        spans[name] = { offset, offset + #text }
        parts[#parts + 1] = text
        offset = offset + #text
      end
    end
    return table.concat(parts, " "), spans
  end

  local function render()
    local lines, decorations = {}, {}
    for row = 1, height() do
      local item = items[top + row - 1]
      local line, spans = format(item)
      lines[row] = line
      decorations[row] = { item = item, spans = spans }
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for row, decoration in ipairs(decorations) do
      for _, hl in ipairs(decoration.item.highlights or {}) do
        local span = decoration.spans[hl.type]
        if span and hl.hl_group and hl.hl_group ~= "" then
          -- Truncated fields keep only the highlight that is still visible.
          local first = span[1] + (hl.col or 1) - 1
          local last = math.min(first + (hl.width or 0), span[2])
          if last > first then
            vim.api.nvim_buf_set_extmark(buf, ns, row - 1, first, {
              end_col = last,
              hl_group = hl.hl_group,
              priority = 200,
            })
          end
        end
      end
    end
  end

  ---@param startcol integer 1-based
  ---@param mode "i"|"c"
  local function place(startcol, mode)
    local total = 0
    for _, name in ipairs(COLUMNS) do
      if widths[name] > 0 then
        total = total + widths[name] + (total > 0 and 1 or 0)
      end
    end
    local config = {
      width = math.max(total, 1),
      height = math.max(height(), 1),
      style = "minimal",
      focusable = false,
      zindex = 200,
      border = menu.border or "none",
    }
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local line = vim.api.nvim_get_current_line()
    config.relative = "cursor"
    config.row = 1
    config.col = -vim.api.nvim_strwidth(line:sub(startcol, col))
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_config(win, config)
    else
      config.noautocmd = true
      win = vim.api.nvim_open_win(ensure_buf(), false, config)
      vim.wo[win].winhighlight = "Normal:Pmenu,FloatBorder:Pmenu"
      vim.wo[win].wrap = false
    end
  end

  local function show(startcol, new_items, mode)
    items = new_items
    widths = measure(items, menu.max_width or 80)
    top = math.max(1, math.min(top, #items - height() + 1))
    ensure_buf()
    place(startcol, mode)
    render()
  end

  ---@param startcol integer 1-based
  ---@param new_items table[]
  ---@param mode "i"|"c"
  function ui.open(startcol, new_items, mode)
    top = 1
    show(startcol, new_items, mode)
  end

  function ui.update(startcol, new_items, mode)
    if not ui.visible() then
      return
    end
    show(startcol, new_items, mode)
  end

  function ui.close()
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    win = nil
  end

  ---@return boolean
  function ui.visible()
    return win ~= nil and vim.api.nvim_win_is_valid(win)
  end

  return ui
end

return M

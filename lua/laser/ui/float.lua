---Built-in completion menu drawn in a floating window. Only the rows inside the
---viewport are rendered, so long candidate lists cost little to show.
local M = {}

local ns = vim.api.nvim_create_namespace("laser.ui.float")
local COLUMNS = { "abbr", "kind", "menu" }
local SELECTED =
  { PmenuMatch = "PmenuMatchSel", PmenuKind = "PmenuKindSel", PmenuExtra = "PmenuExtraSel" }

-- Callbacks queued behind fed keys, keyed by a serial number.
local pending_callbacks, next_callback = {}, 0

---@param id integer
function M._run(id)
  local callback = pending_callbacks[id]
  pending_callbacks[id] = nil
  if callback then
    callback()
  end
end

---Feed keys that run `callback` once every key queued before it is processed.
---Keys are inserted in front of typeahead, so they are fed in reverse order.
---@param parts { [1]: string, [2]: boolean }[] key strings with their escape_ks flag
---@param callback fun()
local function feed(parts, callback)
  next_callback = next_callback + 1
  pending_callbacks[next_callback] = callback
  local run =
    vim.keycode(string.format("<Cmd>lua require('laser.ui.float')._run(%d)<CR>", next_callback))
  vim.api.nvim_feedkeys(run, "in", false)
  for i = #parts, 1, -1 do
    vim.api.nvim_feedkeys(parts[i][1], "in", parts[i][2])
  end
end

---@param mode "i"|"c"
---@return { buf?: integer, row?: integer, line: string, col: integer } col is a 0-based byte index
local function text_state(mode)
  if mode == "c" then
    return { line = vim.fn.getcmdline(), col = vim.fn.getcmdpos() - 1 }
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  return {
    buf = vim.api.nvim_get_current_buf(),
    row = row,
    line = vim.api.nvim_get_current_line(),
    col = col,
  }
end

---@class laser.MenuOpts
---@field max_height? integer rows shown at once; defaults to 'pumheight' or 10
---@field max_width? integer columns shown at once; defaults to 80
---@field border? string|string[] nvim_open_win() border
---@field auto_select? boolean highlight the first candidate without inserting it
---@field direction? "auto"|"below"|"above" "auto" prefers below unless above has more room
---@field reversed? boolean list candidates bottom-up when the menu opens above
---@field preview? boolean|laser.PreviewOpts show documentation of the selected candidate

---@class laser.PreviewOpts
---@field max_width? integer defaults to 60
---@field max_height? integer defaults to 20
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

---@param opts? { on_confirm?: fun(candidate: table), on_close?: fun(), preview_context?: fun(candidate: table): { client?: vim.lsp.Client, bufnr: integer }?, commit_characters?: fun(candidate: table): string[] }
---@return laser.UI
function M.new(opts)
  opts = opts or {}
  local ui = {}
  local menu = {} ---@type laser.MenuOpts
  local buf, win
  local items, widths = {}, {}
  local top = 1
  local startcol, mode = 1, "i" ---@type integer, "i"|"c" 1-based menu start
  local cursor = 0 -- selected index; 0 selects the typed input
  local typed = "" -- input between startcol and the cursor when the menu opened
  local inserted = "" -- text the menu currently holds between startcol and the cursor
  local expected -- text state right after the menu's own edit
  local browsing, frozen, initial_cursor = false, 0, 0
  local layout = { height = 0, above = false, reversed = false, scrollbar = false }
  local shown -- text state the menu was drawn for
  local preview_buf, preview_win, cancel_resolve
  local preview_hidden = false
  local group = vim.api.nvim_create_augroup("laser.ui.float." .. tostring(ui), { clear = true })
  local dismiss

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
    return layout.height
  end

  local function border_rows()
    return (menu.border == nil or menu.border == "none") and 0 or 2
  end

  local function compute_layout()
    local want = math.min(#items, max_height(menu))
    local row = vim.fn.win_screenpos(0)[1] + vim.fn.winline() - 1
    local below = vim.o.lines - vim.o.cmdheight - row - border_rows()
    local above = row - 1 - border_rows()
    local direction = menu.direction or "auto"
    local up = direction == "above" or (direction == "auto" and below < want and above > below)
    local rows = math.max(1, math.min(want, up and above or below))
    layout = {
      height = rows,
      above = up,
      reversed = up and menu.reversed == true,
      scrollbar = #items > rows,
    }
  end

  ---@param row integer 1-based window row
  ---@return integer index into items
  local function index_at(row)
    return layout.reversed and (top + layout.height - row) or (top + row - 1)
  end

  ---0-based window rows holding the scrollbar thumb.
  ---@return integer first, integer last
  local function thumb()
    local rows, total = layout.height, #items
    local size = math.max(1, math.floor(rows * rows / total + 0.5))
    local first = math.min(math.floor((top - 1) * rows / total + 0.5), rows - size)
    if layout.reversed then
      first = rows - size - first
    end
    return first, first + size - 1
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
      local index = index_at(row)
      local line, spans = format(items[index])
      if layout.scrollbar then
        line = line .. " "
      end
      lines[row] = line
      decorations[row] = { index = index, spans = spans, width = #line }
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    local thumb_first, thumb_last = thumb()
    for row, decoration in ipairs(decorations) do
      if layout.scrollbar then
        local in_thumb = row - 1 >= thumb_first and row - 1 <= thumb_last
        vim.api.nvim_buf_set_extmark(buf, ns, row - 1, decoration.width - 1, {
          end_col = decoration.width,
          hl_group = in_thumb and "PmenuThumb" or "PmenuSbar",
          priority = 300,
        })
      end
      decoration.item = items[decoration.index]
      local selected = decoration.index == cursor
      if selected then
        vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
          line_hl_group = "PmenuSel",
          priority = 100,
        })
      end
      for _, hl in ipairs(decoration.item.highlights or {}) do
        local span = decoration.spans[hl.type]
        if span and hl.hl_group and hl.hl_group ~= "" then
          -- Truncated fields keep only the highlight that is still visible.
          local first = span[1] + (hl.col or 1) - 1
          local last = math.min(first + (hl.width or 0), span[2])
          if last > first then
            vim.api.nvim_buf_set_extmark(buf, ns, row - 1, first, {
              end_col = last,
              hl_group = selected and SELECTED[hl.hl_group] or hl.hl_group,
              priority = 200,
            })
          end
        end
      end
    end
  end

  local function place()
    local total = 0
    for _, name in ipairs(COLUMNS) do
      if widths[name] > 0 then
        total = total + widths[name] + (total > 0 and 1 or 0)
      end
    end
    if layout.scrollbar then
      total = total + 1
    end
    local config = {
      width = math.max(total, 1),
      height = height(),
      style = "minimal",
      focusable = false,
      zindex = 200,
      border = menu.border or "none",
    }
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local line = vim.api.nvim_get_current_line()
    config.relative = "cursor"
    config.row = layout.above and -(height() + border_rows()) or 1
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

  local function hide_preview()
    if preview_win and vim.api.nvim_win_is_valid(preview_win) then
      vim.api.nvim_win_close(preview_win, true)
    end
    preview_win = nil
  end

  local function close_preview()
    if cancel_resolve then
      cancel_resolve()
      cancel_resolve = nil
    end
    hide_preview()
  end

  ---@param text string
  ---@param filetype string
  local function draw_preview(text, filetype)
    if text == "" then
      hide_preview()
      return
    end
    local options = type(menu.preview) == "table" and menu.preview or {}
    if not (preview_buf and vim.api.nvim_buf_is_valid(preview_buf)) then
      preview_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[preview_buf].bufhidden = "hide"
    end
    local lines = vim.split(text, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)
    vim.bo[preview_buf].filetype = filetype
    local width = 1
    for _, line in ipairs(lines) do
      width = math.max(width, vim.api.nvim_strwidth(line))
    end
    width = math.min(width, options.max_width or 60)
    local border = (options.border == nil or options.border == "none") and 0 or 2
    local origin = vim.fn.win_screenpos(win)
    local menu_width = vim.api.nvim_win_get_width(win) + border_rows()
    local col = origin[2] - 1 + menu_width
    if col + width + border > vim.o.columns then
      col = math.max(origin[2] - 1 - width - border, 0)
    end
    local config = {
      relative = "editor",
      row = origin[1] - 1,
      col = col,
      width = width,
      height = math.min(#lines, options.max_height or 20),
      style = "minimal",
      focusable = false,
      zindex = 201,
      border = options.border or "none",
    }
    if preview_win and vim.api.nvim_win_is_valid(preview_win) then
      vim.api.nvim_win_set_config(preview_win, config)
    else
      config.noautocmd = true
      preview_win = vim.api.nvim_open_win(preview_buf, false, config)
      vim.wo[preview_win].winhighlight = "Normal:Pmenu,FloatBorder:Pmenu"
      vim.wo[preview_win].wrap = true
    end
    vim.api.nvim_win_call(preview_win, function()
      vim.fn.winrestview({ topline = 1 })
    end)
  end

  ---Show the selected candidate's documentation, then its resolved version.
  local function update_preview()
    if cancel_resolve then
      cancel_resolve()
      cancel_resolve = nil
    end
    local item = items[cursor]
    if not menu.preview or preview_hidden or not item or not ui.visible() then
      close_preview()
      return
    end
    local preview = require("laser.preview")
    local lsp_item = item.user_data.laser.item
    draw_preview(preview.info(lsp_item))
    local context = opts.preview_context and opts.preview_context(item)
    if context and context.client then
      cancel_resolve = preview.resolve(lsp_item, context.client, context.bufnr, draw_preview)
    end
  end

  ---@return integer?
  function ui.preview_win()
    return preview_win
  end

  ---@param delta integer lines to scroll; negative scrolls up
  ---@return boolean handled
  function ui.scroll_preview(delta)
    if not (preview_win and vim.api.nvim_win_is_valid(preview_win)) then
      return false
    end
    vim.api.nvim_win_call(preview_win, function()
      local key = delta > 0 and "\5" or "\25"
      vim.cmd("normal! " .. math.abs(delta) .. key)
    end)
    return true
  end

  ---@return boolean handled
  function ui.toggle_preview()
    if not ui.visible() or not menu.preview then
      return false
    end
    preview_hidden = not preview_hidden
    update_preview()
    return true
  end

  ---Close when the user moves away from the completed text without editing it.
  local function watch()
    vim.api.nvim_clear_autocmds({ group = group })
    vim.api.nvim_create_autocmd("CursorMovedI", {
      group = group,
      callback = function()
        local state = text_state("i")
        if expected and vim.deep_equal(state, expected.state) then
          return
        end
        if state.row ~= shown.row or (state.line == shown.line and state.col ~= shown.col) then
          dismiss()
        end
      end,
    })
    vim.api.nvim_create_autocmd("WinScrolled", {
      group = group,
      callback = function()
        if vim.v.event[tostring(vim.api.nvim_get_current_win())] then
          dismiss()
        end
      end,
    })
    vim.api.nvim_create_autocmd({ "VimResized", "WinLeave", "CmdwinEnter" }, {
      group = group,
      callback = function()
        dismiss()
      end,
    })
  end

  local function show(col, new_items, new_mode)
    startcol, mode, items = col, new_mode, new_items
    shown = text_state(mode)
    widths = measure(items, menu.max_width or 80)
    compute_layout()
    top = math.max(1, math.min(top, #items - height() + 1))
    ensure_buf()
    place()
    render()
    watch()
  end

  ---@param col integer 1-based
  ---@param new_items table[]
  ---@param new_mode "i"|"c"
  function ui.open(col, new_items, new_mode)
    top = 1
    cursor = menu.auto_select and #new_items > 0 and 1 or 0
    browsing, frozen, initial_cursor = false, 0, cursor
    local state = text_state(new_mode)
    typed = state.line:sub(col, state.col)
    inserted = typed
    preview_hidden = false
    show(col, new_items, new_mode)
    update_preview()
  end

  ---Release the frozen prefix after actual user input.
  function ui.reset()
    browsing, frozen, initial_cursor = false, 0, cursor
  end

  ---Once the user moves the selection, rows up to the bottom of the viewport
  ---they have seen stay in place while further candidates arrive.
  ---@return integer
  function ui.frozen_count()
    if not ui.visible() then
      return 0
    end
    browsing = browsing or (cursor > 0 and cursor ~= initial_cursor)
    if not browsing then
      return 0
    end
    frozen = math.min(#items, math.max(frozen, top + height() - 1))
    return frozen
  end

  function ui.update(col, new_items, new_mode)
    if not ui.visible() then
      return
    end
    show(col, new_items, new_mode)
  end

  function ui.close()
    close_preview()
    vim.api.nvim_clear_autocmds({ group = group })
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    win = nil
  end

  -- Closing on the user's behalf also stops responses that would reopen it.
  function dismiss()
    ui.close()
    if opts.on_close then
      opts.on_close()
    end
  end

  ---@return integer index of the selected candidate, or 0 for the typed input
  function ui.selected()
    return cursor
  end

  ---True once when the text change being handled is the menu's own edit.
  ---@return boolean
  function ui.skip_text_change()
    local want = expected
    expected = nil
    return want ~= nil and vim.deep_equal(text_state(want.mode), want.state)
  end

  ---Replace the text between startcol and the cursor with `word`.
  ---@param word string
  ---@param callback? fun() runs once the edit is in place
  local function insert(word, callback)
    local state = text_state(mode)
    local current = state.line:sub(startcol, state.col)
    local line = state.line:sub(1, startcol - 1) .. word .. state.line:sub(state.col + 1)
    expected = {
      mode = mode,
      state = vim.tbl_extend("force", state, { line = line, col = startcol - 1 + #word }),
    }
    shown = expected.state
    inserted = word
    if mode == "c" then
      vim.fn.setcmdline(line, startcol + #word)
      if callback then
        callback()
      end
      return
    end
    -- Typed keys keep undo and dot-repeat intact, unlike direct buffer edits.
    local backspace, indentkeys = vim.o.backspace, vim.bo.indentkeys
    vim.o.backspace, vim.bo.indentkeys = "start", ""
    local bs = vim.keycode("<BS>")
    feed({ { bs:rep(vim.fn.strchars(current)), false }, { word, true } }, function()
      vim.o.backspace, vim.bo.indentkeys = backspace, indentkeys
      if callback then
        callback()
      end
    end)
  end

  ---@param delta integer
  local function select(delta)
    cursor = (cursor + delta) % (#items + 1)
    local rows = height()
    if cursor > 0 and cursor < top then
      top = cursor
    elseif cursor >= top + rows then
      top = cursor - rows + 1
    end
    browsing = true
    ui.frozen_count()
    render()
    update_preview()
  end

  ---Move the selection without editing text. Moving past either end selects
  ---the typed input.
  ---@param delta integer
  ---@return boolean handled
  function ui.select_relative(delta)
    if not ui.visible() then
      return false
    end
    select(delta)
    return true
  end

  ---Move the selection and put the selected text in place of the input.
  ---@param delta integer
  ---@return boolean handled
  function ui.insert_relative(delta)
    if not ui.visible() then
      return false
    end
    select(delta)
    insert(cursor > 0 and items[cursor].word or typed)
    return true
  end

  ---Select the candidate under the mouse pointer.
  ---@return boolean handled
  function ui.select_mouse()
    if not ui.visible() then
      return false
    end
    -- getmousepos() reports the window below a non-focusable float.
    local pos = vim.fn.getmousepos()
    local origin = vim.fn.win_screenpos(win)
    local offset = border_rows() / 2
    local row = pos.screenrow - origin[1] + 1 - offset
    local col = pos.screencol - origin[2] + 1 - offset
    if row < 1 or row > height() or col < 1 or col > vim.api.nvim_win_get_width(win) then
      return false
    end
    select(index_at(row) - cursor)
    return true
  end

  ---@param after? fun() runs once the confirmation edits are applied
  ---@return boolean confirmed
  local function confirm(after)
    if not ui.visible() then
      return false
    end
    local item = items[cursor]
    dismiss()
    if not item then
      return false
    end
    local function done()
      if opts.on_confirm then
        opts.on_confirm(item)
      end
      if after then
        after()
      end
    end
    if inserted == item.word then
      done()
    else
      insert(item.word, done)
    end
    return true
  end

  ---Accept the selected candidate. Without a selection the menu just closes.
  ---@return boolean confirmed
  function ui.confirm()
    return confirm()
  end

  if opts.commit_characters and opts.on_confirm then
    local pending_commit -- commit character plus input typed while confirming
    vim.on_key(function(key, typed)
      if pending_commit and typed ~= "" then
        pending_commit = pending_commit .. key
        return ""
      end
      local current = vim.api.nvim_get_mode().mode
      if typed == "" or (current ~= "i" and current ~= "c") or not ui.visible() then
        return
      end
      local item = items[cursor]
      if
        not item
        or vim.fn.strchars(key) ~= 1
        or not vim.list_contains(opts.commit_characters(item), key)
      then
        return
      end
      -- Confirmation edits the text, which is not allowed inside on_key.
      pending_commit = key
      local function release()
        local keys = pending_commit
        pending_commit = nil
        vim.api.nvim_feedkeys(keys, "ni", true)
      end
      feed({}, function()
        -- The menu may have closed meanwhile; never keep swallowing input.
        if not confirm(release) then
          release()
        end
      end)
      return ""
    end, vim.api.nvim_create_namespace("laser.ui.float.commit." .. tostring(ui)))
  end

  ---Restore the typed input and close the menu.
  ---@return boolean handled
  function ui.cancel()
    if not ui.visible() then
      return false
    end
    if inserted ~= typed then
      insert(typed)
    end
    dismiss()
    return true
  end

  ---@return boolean
  function ui.visible()
    return win ~= nil and vim.api.nvim_win_is_valid(win)
  end

  return ui
end

return M

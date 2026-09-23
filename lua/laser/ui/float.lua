---Built-in completion menu drawn in a floating window. Only the rows inside the
---viewport are drawn; column widths still visit every candidate.
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
---@field direction? "auto"|"below"|"above" "auto" opens below unless the rows do not fit there and above has more room; the command-line menu always opens above
---@field reversed? boolean list candidates bottom-up when the menu opens above
---@field preview? boolean|laser.PreviewOpts show documentation of the selected candidate

---@class laser.PreviewOpts
---@field max_width? integer defaults to 60
---@field max_height? integer defaults to 20
---@field border? string|string[] nvim_open_win() border

---Cells a drawn window's border takes on each side. Read from the window,
---since options passed to later calls may differ from those it was drawn with.
---@param config vim.api.keyset.win_config
---@return integer
local function drawn_border(config)
  return (config.border == nil or config.border == "none") and 0 or 1
end

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
  local text
  if name == "abbr" then
    text = item.abbr or item.word or ""
  else
    text = item[name] or ""
  end
  -- A newline cannot be drawn in a row and a tab is wider than one cell.
  -- Replace each control byte with one space so highlight offsets still hold.
  if text:find("%c") then
    text = text:gsub("%c", " ")
  end
  return text
end

---Cut `text` to at most `width` display cells and pad it to exactly `width`.
---@param text string
---@param width integer
---@return string padded
---@return integer kept byte length of the text before the padding
local function fit(text, width)
  local cells = vim.api.nvim_strwidth(text)
  if cells > width then
    -- Every character takes at least one cell, so start from `width` of them
    -- and drop only what wide characters push past the limit.
    local chars = width
    text = vim.fn.strcharpart(text, 0, chars)
    cells = vim.api.nvim_strwidth(text)
    while chars > 0 and cells > width do
      chars = chars - 1
      text = vim.fn.strcharpart(text, 0, chars)
      cells = vim.api.nvim_strwidth(text)
    end
  end
  return text .. string.rep(" ", width - cells), #text
end

---Column widths over every candidate, so the menu does not jitter on scroll.
---@param items table[]
---@param limit integer
---@param cells table<string, integer> display widths already measured
---@return table<string, integer>
local function measure(items, limit, cells)
  local widths = {}
  for _, name in ipairs(COLUMNS) do
    local width = 0
    for _, item in ipairs(items) do
      local text = field(item, name)
      local cell = cells[text]
      if not cell then
        cell = vim.api.nvim_strwidth(text)
        cells[text] = cell
      end
      width = math.max(width, cell)
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

---@class laser.FloatUI: laser.UI
---@field configure fun(options?: laser.MenuOpts)
---@field skip_text_change fun(): boolean
---@field items fun(): table[]
---@field selected fun(): integer
---@field win fun(): integer?
---@field preview_win fun(): integer?
---@field select fun(delta: integer, opts?: { insert?: boolean }): boolean
---@field select_mouse fun(): boolean
---@field confirm fun(): boolean
---@field cancel fun(): boolean
---@field scroll_preview fun(delta: integer): boolean
---@field toggle_preview fun(): boolean

---@param opts? { on_confirm?: fun(candidate: table), on_close?: fun(), preview_context?: fun(candidate: table): { client?: vim.lsp.Client, bufnr: integer }?, commit_characters?: fun(candidate: table): string[] }
---@return laser.FloatUI
function M.new(opts)
  opts = opts or {}
  local ui = {} ---@type laser.FloatUI
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
  -- Resolved documentation by candidate id. Ids restart with each completion
  -- session, so the cache lives only while the menu is open.
  local resolved = {}
  -- Display widths of field texts. Kinds and details repeat across candidates
  -- and labels across keystrokes; cleared with the menu to stay bounded.
  local cells = {}
  local preview_hidden = false
  local group = vim.api.nvim_create_augroup("laser.ui.float." .. tostring(ui), { clear = true })
  local dismiss, redraw, watch
  local closing = false -- the menu is closing its own window
  -- Typeahead can leave the mode before the menu's own change is observed.
  vim.api.nvim_create_autocmd({ "InsertLeave", "CmdlineLeave" }, {
    callback = function()
      expected = nil
    end,
  })

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

  ---1-based screen row and column where the current window's rows begin:
  ---below its winbar and, for a floating window, inside its border.
  ---@return integer row, integer col
  local function window_origin()
    local win_id = vim.api.nvim_get_current_win()
    local origin = vim.fn.win_screenpos(win_id)
    local border = drawn_border(vim.api.nvim_win_get_config(win_id))
    local winbar = vim.fn.getwininfo(win_id)[1].winbar
    return origin[1] + border + winbar, origin[2] + border
  end

  ---1-based screen row and column of the cursor in the edited text.
  ---@return integer row, integer col
  local function cursor_screenpos()
    if mode == "c" then
      return vim.o.lines - vim.o.cmdheight + 1, vim.fn.getcmdscreenpos()
    end
    local row, col = window_origin()
    return row + vim.fn.winline() - 1, col + vim.fn.wincol() - 1
  end

  ---1-based screen column where the completed text starts, measured back from
  ---the cursor so tabs, wide and control characters, 'number' and horizontal
  ---scrolling are accounted for.
  ---@return integer
  local function start_screencol()
    local _, col = cursor_screenpos()
    local state = text_state(mode)
    local typed_width = vim.fn.strdisplaywidth(state.line:sub(1, state.col))
      - vim.fn.strdisplaywidth(state.line:sub(1, startcol - 1))
    -- Text wrapped in from the previous screen line starts at the left edge.
    local left = 1
    if mode ~= "c" then
      local _, origin_col = window_origin()
      left = origin_col + vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].textoff
    end
    return math.max(col - typed_width, left)
  end

  local function compute_layout()
    local want = math.min(#items, max_height(menu))
    -- The command line sits on the last rows, so its menu always opens above.
    local row = cursor_screenpos()
    local below = vim.o.lines - vim.o.cmdheight - row - border_rows()
    local above = row - 1 - border_rows()
    local direction = mode == "c" and "above" or menu.direction or "auto"
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
  ---@return table<string, { [1]: integer, [2]: integer }> spans 0-based byte range of each field's text, without padding
  local function format(item)
    local parts, spans, offset = {}, {}, 0
    for _, name in ipairs(COLUMNS) do
      if widths[name] > 0 then
        local text, kept = fit(field(item, name), widths[name])
        if #parts > 0 then
          offset = offset + 1
        end
        spans[name] = { offset, offset + kept }
        parts[#parts + 1] = text
        offset = offset + #text
      end
    end
    return table.concat(parts, " "), spans
  end

  ---Highlights for the characters the matcher matched, computed only for
  ---rows being drawn. Candidates decorated by a converter keep their own.
  ---@param item table
  ---@return table[]
  local function match_highlights(item)
    local data = item.user_data and item.user_data.laser
    local positions = data and data.match_info and data.match_info.positions
    if not positions then
      return {}
    end
    local pad = 0
    for _, hl in ipairs(item.highlights or {}) do
      if hl.name == "laser_match" then
        return {}
      elseif hl.name == "laser_prefix" then
        pad = hl.width
      end
    end
    -- Positions index the matched text; padding for an earlier edit start is
    -- not part of it, and a label shown differently must be matched again.
    local shown = field(item, "abbr"):sub(pad + 1)
    if shown ~= (data.item.filterText or data.item.label) then
      -- Match what the user typed, not a candidate the menu inserted. A
      -- candidate starts at or after the menu start, so its input is the
      -- part of the typed text from its own start.
      local input = typed:sub(math.max((data.startcol or 0) - (startcol - 1), 0) + 1)
      positions = input ~= "" and vim.fn.matchfuzzypos({ shown }, input)[2][1] or {}
    end
    local highlights = {}
    for _, pos in ipairs(positions) do
      local first, last = vim.fn.byteidx(shown, pos), vim.fn.byteidx(shown, pos + 1)
      if first >= 0 and last > first then
        highlights[#highlights + 1] = {
          type = "abbr",
          col = pad + first + 1,
          width = last - first,
          hl_group = "PmenuMatch",
        }
      end
    end
    return highlights
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
      local highlights = vim.list_extend(
        vim.list_slice(decoration.item.highlights or {}),
        match_highlights(decoration.item)
      )
      for _, hl in ipairs(highlights) do
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

  local placed_tick -- b:changedtick when the menu was last placed

  local function place()
    placed_tick = mode == "i" and vim.b.changedtick or nil
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
    -- Position against the editor so the menu stays where it is computed
    -- here; Neovim would otherwise shift a window that does not fit.
    local side = border_rows() / 2
    local row = cursor_screenpos()
    local outer_width = config.width + 2 * side
    config.relative = "editor"
    config.row = layout.above and row - 1 - height() - 2 * side or row
    config.col = math.max(0, math.min(start_screencol() - 1 - side, vim.o.columns - outer_width))
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_config(win, config)
    else
      config.noautocmd = true
      win = vim.api.nvim_open_win(ensure_buf(), false, config)
      vim.wo[win].winhighlight = "Normal:Pmenu,FloatBorder:Pmenu"
      vim.wo[win].wrap = false
      vim.wo[win].winblend = vim.o.pumblend
      -- Watchers read the current state, so one set serves the window's life.
      watch()
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

  local preview_size -- width and height of the drawn documentation

  ---Put the preview beside the menu, or on its left when the right is too
  ---narrow. The menu's configured position is where it is drawn.
  local function place_preview()
    if not (preview_win and vim.api.nvim_win_is_valid(preview_win)) then
      return
    end
    local options = type(menu.preview) == "table" and menu.preview or {}
    local border = (options.border == nil or options.border == "none") and 0 or 2
    local anchor = vim.api.nvim_win_get_config(win)
    local width = preview_size.width
    local col = anchor.col + anchor.width + 2 * drawn_border(anchor)
    if col + width + border > vim.o.columns then
      col = math.max(anchor.col - width - border, 0)
    end
    vim.api.nvim_win_set_config(preview_win, {
      relative = "editor",
      row = anchor.row,
      col = col,
      width = width,
      height = preview_size.height,
      border = options.border or "none",
    })
  end

  ---@param text string
  ---@param filetype string
  local function draw_preview(text, filetype)
    if not ui.visible() then
      return
    end
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
    -- Setting 'filetype' reruns FileType handlers even for the same value.
    if vim.bo[preview_buf].filetype ~= filetype then
      vim.bo[preview_buf].filetype = filetype
    end
    local width = 1
    for _, line in ipairs(lines) do
      width = math.max(width, vim.api.nvim_strwidth(line))
    end
    preview_size = {
      width = math.min(width, options.max_width or 60),
      height = math.min(#lines, options.max_height or 20),
    }
    if not (preview_win and vim.api.nvim_win_is_valid(preview_win)) then
      preview_win = vim.api.nvim_open_win(preview_buf, false, {
        relative = "editor",
        row = 0,
        col = 0,
        width = preview_size.width,
        height = preview_size.height,
        style = "minimal",
        focusable = false,
        zindex = 201,
        noautocmd = true,
      })
      vim.wo[preview_win].winhighlight = "Normal:Pmenu,FloatBorder:Pmenu"
      vim.wo[preview_win].wrap = true
      vim.wo[preview_win].winblend = vim.o.pumblend
    end
    place_preview()
    vim.api.nvim_win_call(preview_win, function()
      -- Scrolling moved the cursor too; Neovim would keep it in view.
      vim.fn.winrestview({ topline = 1, lnum = 1 })
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
    local id = item.user_data.laser.id
    if id and resolved[id] then
      draw_preview(unpack(resolved[id]))
      return
    end
    local preview = require("laser.preview")
    local lsp_item = item.user_data.laser.item
    draw_preview(preview.info(lsp_item))
    local context = opts.preview_context and opts.preview_context(item)
    if context and context.client then
      cancel_resolve = preview.resolve(lsp_item, context.client, context.bufnr, function(info, ft)
        if id then
          resolved[id] = { info, ft }
        end
        draw_preview(info, ft)
        redraw()
      end)
    end
  end

  ---@return integer?
  function ui.preview_win()
    return preview_win
  end

  ---@param delta integer lines to scroll; negative scrolls up
  ---@return boolean handled
  function ui.scroll_preview(delta)
    -- A zero count would make the scroll command move one line.
    if delta == 0 or not (preview_win and vim.api.nvim_win_is_valid(preview_win)) then
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
    redraw()
    return true
  end

  -- Floats are not repainted while the command line is being edited. Each
  -- action that changes what is shown flushes once when it is done. Headless
  -- tests can only observe the first paint.
  function redraw()
    if mode == "c" then
      vim.api.nvim__redraw({ flush = true })
    end
  end

  ---Close when the user moves away from the completed text without editing it.
  function watch()
    vim.api.nvim_clear_autocmds({ group = group })
    vim.api.nvim_create_autocmd({ "CursorMovedI", "CursorMovedC" }, {
      group = group,
      callback = function(args)
        if (args.event == "CursorMovedC") ~= (mode == "c") then
          return
        end
        -- The menu's own insertion updates `shown`, so it never counts as a move.
        local state = text_state(mode)
        if state.row ~= shown.row or (state.line == shown.line and state.col ~= shown.col) then
          dismiss()
        end
      end,
    })
    vim.api.nvim_create_autocmd("WinScrolled", {
      group = group,
      callback = function()
        if not vim.v.event[tostring(vim.api.nvim_get_current_win())] then
          return
        end
        -- Typing, including the menu's own insertion, can scroll the view;
        -- only a scroll without an edit moves away from the completion.
        local tick = vim.b.changedtick
        if tick ~= placed_tick then
          place()
          place_preview()
          redraw()
        else
          dismiss()
        end
      end,
    })
    -- Another command or plugin closed the menu; release what it owns.
    vim.api.nvim_create_autocmd("WinClosed", {
      group = group,
      pattern = tostring(win),
      callback = function()
        if closing then
          return
        end
        win = nil
        dismiss()
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
    widths = measure(items, menu.max_width or 80, cells)
    compute_layout()
    top = math.max(1, math.min(top, #items - height() + 1))
    ensure_buf()
    place()
    place_preview()
    render()
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
    redraw()
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
    redraw()
  end

  function ui.close()
    -- Closing windows is refused under textlock, e.g. from an <expr> mapping.
    -- Do it before any teardown so a refusal leaves the menu fully working.
    hide_preview()
    if win and vim.api.nvim_win_is_valid(win) then
      closing = true
      local ok, err = pcall(vim.api.nvim_win_close, win, true)
      closing = false
      if not ok then
        error(err, 0)
      end
      redraw()
    end
    win = nil
    close_preview()
    resolved, cells = {}, {}
    vim.api.nvim_clear_autocmds({ group = group })
  end

  -- Closing on the user's behalf also stops responses that would reopen it.
  function dismiss()
    ui.close()
    if opts.on_close then
      opts.on_close()
    end
  end

  ---@return table[] candidates in menu order
  function ui.items()
    return items
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

  local saved_options -- options to restore once fed insertion keys are done
  -- Options that change what one typed <BS> or character does, with the values
  -- that make fed keys behave like deleting and typing plain characters.
  local RELAXED = {
    global = { backspace = "start", smarttab = false },
    buffer = { indentkeys = "", softtabstop = 0, varsofttabstop = "" },
  }

  local function restore_options()
    if not saved_options then
      return
    end
    for name, value in pairs(saved_options.global) do
      vim.o[name] = value
    end
    if vim.api.nvim_buf_is_valid(saved_options.buf) then
      for name, value in pairs(saved_options.buffer) do
        vim.bo[saved_options.buf][name] = value
      end
    end
    saved_options = nil
  end

  ---Let backspaces remove exactly one character each, including text typed
  ---before this insertion, and keep typed candidates from reindenting.
  local function relax_options()
    local target = vim.api.nvim_get_current_buf()
    if not saved_options then
      saved_options = { buf = target, global = {}, buffer = {} }
      for name in pairs(RELAXED.global) do
        saved_options.global[name] = vim.o[name]
      end
      for name in pairs(RELAXED.buffer) do
        saved_options.buffer[name] = vim.bo[target][name]
      end
      -- The fed keys, and the restore queued behind them, can be discarded.
      vim.api.nvim_create_autocmd({ "TextChangedI", "InsertLeave" }, {
        once = true,
        callback = restore_options,
      })
    end
    for name, value in pairs(RELAXED.global) do
      vim.o[name] = value
    end
    for name, value in pairs(RELAXED.buffer) do
      vim.bo[target][name] = value
    end
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
    relax_options()
    local bs = vim.keycode("<BS>")
    -- One <BS> removes a character with its composing characters unless
    -- 'delcombine' makes it remove them one at a time.
    local chars = vim.fn.strchars(current, vim.o.delcombine and 0 or 1)
    feed({ { bs:rep(chars), false }, { word, true } }, function()
      restore_options()
      if callback then
        callback()
      end
    end)
  end

  ---Auto-wrap would move the text being typed to another line midway through
  ---the fed keys, so such candidates are only selected.
  ---@param word string
  ---@return boolean
  local function wraps(word)
    if mode ~= "i" or vim.bo.textwidth <= 0 or not vim.bo.formatoptions:find("[tca]") then
      return false
    end
    local before = vim.api.nvim_get_current_line():sub(1, startcol - 1)
    -- Auto-wrap starts only once the text goes past 'textwidth'.
    return vim.fn.strdisplaywidth(before .. word) > vim.bo.textwidth
  end

  ---@param delta integer
  local function move(delta)
    if delta == 0 then
      return
    elseif delta == 1 or delta == -1 then
      -- Stepping cycles through the typed input, so it can be reached again.
      cursor = (cursor + delta) % (#items + 1)
    else
      -- Larger moves, such as paging, stop at the first or last candidate
      -- instead of leaving the list. The typed input counts as past the end
      -- that is moved away from.
      local from = cursor
      if from == 0 then
        from = delta > 0 and 0 or #items + 1
      end
      cursor = math.max(1, math.min(#items, from + delta))
    end
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
    redraw()
  end

  ---Move the selection by `delta` and, unless `opts.insert` is false, put the
  ---selected text in place of the input. Single steps cycle through the typed
  ---input; larger moves stop at the first or last candidate.
  ---@param delta integer
  ---@param opts? { insert?: boolean }
  ---@return boolean handled
  function ui.select(delta, opts)
    if not ui.visible() then
      return false
    end
    move(delta)
    if opts and opts.insert == false then
      return true
    end
    local word = cursor > 0 and items[cursor].word or typed
    if not wraps(word) then
      insert(word)
    end
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
    local offset = drawn_border(vim.api.nvim_win_get_config(win))
    local row = pos.screenrow - origin[1] + 1 - offset
    local col = pos.screencol - origin[2] + 1 - offset
    if row < 1 or row > height() or col < 1 or col > vim.api.nvim_win_get_width(win) then
      return false
    end
    move(index_at(row) - cursor)
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
      local ok, err = true, nil
      if opts.on_confirm then
        local before = text_state(mode)
        ok, err = pcall(opts.on_confirm, item)
        -- Snippet expansion and additional edits are part of the confirmation,
        -- not input that should start a new completion. Without such edits no
        -- change is coming, and a recorded state would swallow a later one.
        local state = text_state(mode)
        if not vim.deep_equal(before, state) then
          expected = { mode = mode, state = state }
        end
      end
      if after then
        after()
      end
      if not ok then
        -- Raising here would abort the keys `after` just queued.
        vim.schedule(function()
          error(err, 0)
        end)
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
    vim.on_key(function(key, typed_key)
      if typed_key == "" or not ui.visible() then
        return
      end
      local current = vim.api.nvim_get_mode().mode
      if current ~= "i" and current ~= "c" then
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
      -- Confirmation edits the text, which is not allowed inside on_key. The
      -- queued command runs ahead of input typed after the commit character,
      -- and so do the keys it feeds, so that input needs no holding back.
      local function type_key()
        vim.api.nvim_feedkeys(key, "ni", false)
      end
      feed({}, function()
        if not confirm(type_key) then
          type_key()
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

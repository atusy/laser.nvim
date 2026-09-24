---Built-in completion menu drawn in a floating window. Only the rows inside the
---viewport are drawn; column widths still visit every candidate.
local M = {}

local borders = require("laser.ui.border")
local columns = require("laser.ui.columns")
local feedkeys = require("laser.ui.feedkeys")
local relaxed = require("laser.ui.relaxed")
local style = require("laser.ui.style")
local highlight = require("laser.highlight")

local ns = vim.api.nvim_create_namespace("laser.ui.float")
local SELECTED =
  { PmenuMatch = "PmenuMatchSel", PmenuKind = "PmenuKindSel", PmenuExtra = "PmenuExtraSel" }

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
---@field border? string|(string|string[])[] nvim_open_win() border
---@field auto_select? boolean highlight the first candidate without inserting it; a candidate the server preselects is highlighted regardless
---@field direction? "auto"|"below"|"above" "auto" opens below unless the rows do not fit there and above has more room; the command-line menu always opens above
---@field reversed? boolean list candidates bottom-up when the menu opens above
---@field preview? boolean|laser.PreviewOpts show documentation of the selected candidate

---@class laser.PreviewOpts
---@field max_width? integer defaults to 60
---@field max_height? integer defaults to 20
---@field border? string|(string|string[])[] nvim_open_win() border

---@param opts laser.MenuOpts
---@return integer
local function max_height(opts)
  if opts.max_height and opts.max_height > 0 then
    return opts.max_height
  end
  return vim.o.pumheight > 0 and vim.o.pumheight or 10
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
---@field dispose fun()

---@class laser.FloatOpts
---@field on_confirm? fun(candidate: table) applies the confirmed candidate once the menu typed its text
---@field confirm_text? fun(candidate: table): string? text the menu types on confirm; nil leaves it to on_confirm. Defaults to the candidate's word
---@field on_close? fun()
---@field preview_context? fun(candidate: table): { client?: vim.lsp.Client, bufnr: integer }?
---@field commit_characters? fun(candidate: table): string[]

---@return { new_mode: string, old_mode: string }
local function mode_event()
  return vim.v.event --[[@as { new_mode: string, old_mode: string }]]
end

---@param opts? laser.FloatOpts
---@return laser.FloatUI
function M.new(opts)
  opts = opts or {}
  ---@diagnostic disable-next-line: missing-fields
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
  local pending_insertions = 0 -- insertions whose fed keys have not run yet
  local after_insertions = {} ---@type fun()[] run once no insertion is pending
  local browsing, frozen, initial_cursor = false, 0, 0
  local layout = { height = 0, above = false, reversed = false, scrollbar = false }
  local shown -- text state the menu was drawn for
  -- Display widths of field texts. Kinds and details repeat across candidates
  -- and labels across keystrokes; cleared with the menu to stay bounded.
  local cells = {}
  local group = vim.api.nvim_create_augroup("laser.ui.float." .. tostring(ui), { clear = true })
  local state_group =
    vim.api.nvim_create_augroup("laser.ui.float.state." .. tostring(ui), { clear = true })
  local key_ns = vim.api.nvim_create_namespace("laser.ui.float.commit." .. tostring(ui))
  local dismiss, redraw, watch, layout_and_draw, reconcile, note_seen
  local preview = require("laser.ui.preview_window").new({
    menu_win = function()
      return win
    end,
    above = function()
      return layout.above
    end,
    options = function()
      return menu.preview
    end,
    visible = function()
      return ui.visible()
    end,
    redraw = function()
      redraw()
    end,
    context = opts.preview_context,
  })
  local closing = false -- the menu is closing its own window
  -- Typeahead can leave the mode before the menu's own change is observed.
  -- Unlike the window watchers, this outlives each menu window. ModeChanged
  -- also covers <C-c>, which skips InsertLeave.
  vim.api.nvim_create_autocmd({ "InsertLeave", "CmdlineLeave", "ModeChanged" }, {
    group = state_group,
    callback = function(args)
      if args.event == "ModeChanged" and mode_event().new_mode:find("^[ic]") then
        return
      end
      expected = nil
      -- Fed keys may have been discarded; nothing may wait for them forever,
      -- and options relaxed for them must come back.
      pending_insertions, after_insertions = 0, {}
      feedkeys.forget(ui)
      relaxed.restore()
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
    local sides = borders.sides(menu.border)
    return sides.top + sides.bottom
  end

  ---1-based screen row and column where the current window's rows begin:
  ---below its winbar and, for a floating window, inside its border.
  ---@return integer row, integer col
  local function window_origin()
    local win_id = vim.api.nvim_get_current_win()
    local origin = vim.fn.win_screenpos(win_id)
    local border = borders.drawn(win_id)
    local winbar = vim.fn.getwininfo(win_id)[1].winbar
    return origin[1] + border.top + winbar, origin[2] + border.left
  end

  ---Display width of the text between the menu start and the cursor.
  ---@return integer
  local function typed_width()
    local state = text_state(mode)
    return vim.fn.strdisplaywidth(state.line:sub(1, state.col))
      - vim.fn.strdisplaywidth(state.line:sub(1, startcol - 1))
  end

  ---1-based screen row the menu is placed against: the cursor row, or the
  ---first row of the command line, which wraps onto more rows as it grows.
  ---@return integer
  local function anchor_row()
    if mode == "c" then
      -- getcmdscreenpos() counts cells from the start of the command line,
      -- prompt included. The cursor takes a cell after the text.
      local cells = vim.fn.getcmdscreenpos()
        + vim.fn.strdisplaywidth(vim.fn.getcmdline():sub(vim.fn.getcmdpos()))
      local rows = math.floor((cells - 1) / vim.o.columns) + 1
      -- With 'cmdheight' 0 the command line still takes a row while edited.
      return vim.o.lines - math.max(vim.o.cmdheight, rows) + 1
    end
    local row = window_origin()
    return row + vim.fn.winline() - 1
  end

  ---1-based screen column where the completed text starts, measured back from
  ---the cursor so tabs, wide and control characters, 'number' and horizontal
  ---scrolling are accounted for.
  ---@return integer
  local function start_screencol()
    if mode == "c" then
      local cell = vim.fn.getcmdscreenpos() - typed_width()
      return (cell - 1) % vim.o.columns + 1
    end
    local _, origin_col = window_origin()
    local col = origin_col + vim.fn.wincol() - 1
    -- Text wrapped in from the previous screen line starts at the left edge.
    local left = origin_col + vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].textoff
    return math.max(col - typed_width(), left)
  end

  local function compute_layout()
    local want = math.min(#items, max_height(menu))
    -- The command line sits on the last rows, so its menu always opens above.
    local row = anchor_row()
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
      if hl.name == highlight.MATCH then
        return {}
      elseif hl.name == highlight.PREFIX then
        pad = hl.width
      end
    end
    -- Positions index the matched text; padding for an earlier edit start is
    -- not part of it, and a label shown differently must be matched again.
    local shown = columns.field(item, "abbr"):sub(pad + 1)
    if shown ~= (data.item.filterText or data.item.label) then
      -- Match what the user typed, not a candidate the menu inserted. A
      -- candidate starts at or after the menu start, so its input is the
      -- part of the typed text from its own start.
      local input = typed:sub(math.max((data.startcol or 0) - (startcol - 1), 0) + 1)
      positions = input ~= "" and vim.fn.matchfuzzypos({ shown }, input)[2][1] or {}
    end
    return highlight.matches(shown, positions, pad)
  end

  local function render()
    local lines, decorations = {}, {}
    for row = 1, height() do
      local index = index_at(row)
      local line, spans = columns.format(items[index], widths)
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
  local placed_view -- window view when the menu was last placed

  local function place()
    placed_tick = mode == "i" and vim.b.changedtick or nil
    placed_view = mode == "i" and vim.fn.winsaveview() or nil
    local total = 0
    for _, name in ipairs(columns.NAMES) do
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
    local sides = borders.sides(config.border)
    local row = anchor_row()
    local outer_width = config.width + sides.left + sides.right
    config.relative = "editor"
    config.row = layout.above and row - 1 - height() - sides.top - sides.bottom or row
    config.col =
      math.max(0, math.min(start_screencol() - 1 - sides.left, vim.o.columns - outer_width))
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_config(win, config)
    else
      config.noautocmd = true
      win = vim.api.nvim_open_win(ensure_buf(), false, config)
      vim.wo[win].winhighlight = style.WINHIGHLIGHT
      vim.wo[win].wrap = false
      vim.wo[win].winblend = vim.o.pumblend
      -- Watchers read the current state, so one set serves the window's life.
      watch()
    end
  end

  ---@return integer?
  function ui.preview_win()
    return preview.win()
  end

  ---@param delta integer lines to scroll; negative scrolls up
  ---@return boolean handled
  function ui.scroll_preview(delta)
    if not preview.scroll(delta) then
      return false
    end
    redraw()
    return true
  end

  ---@return boolean handled
  function ui.toggle_preview()
    if not ui.visible() or not menu.preview then
      return false
    end
    preview.toggle(items[cursor])
    redraw()
    return true
  end

  -- Floats are not repainted while the command line is being edited. Each
  -- action that changes what is shown flushes once when it is done. Headless
  -- tests can only observe the first paint.
  function redraw()
    if mode == "c" then
      -- nvim__redraw is experimental; :redraw also repaints, less precisely.
      if vim.api.nvim__redraw then
        vim.api.nvim__redraw({ flush = true })
      else
        vim.cmd.redraw()
      end
    end
  end

  ---Bring the menu up to date with what the user did to the text since it
  ---was drawn. Moving away closes it. Editing the completed text makes what
  ---they typed the input to restore and match, unless completion redraws the
  ---menu first. The menu's own insertion updates `shown`, so it never counts.
  ---@return boolean open
  function reconcile()
    if pending_insertions > 0 then
      -- The menu's own keys are still queued; the text is not final yet.
      return true
    end
    local state = text_state(mode)
    if state.row ~= shown.row or (state.line == shown.line and state.col ~= shown.col) then
      dismiss()
      return false
    elseif state.line == shown.line then
      return true
    elseif state.col < startcol - 1 then
      dismiss()
      return false
    end
    typed = state.line:sub(startcol, state.col)
    inserted = typed
    cursor = 0
    ui.reset()
    shown = state
    render()
    preview.update(items[cursor])
    redraw()
    return true
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
        reconcile()
      end,
    })
    vim.api.nvim_create_autocmd("WinScrolled", {
      group = group,
      callback = function()
        if not vim.v.event[tostring(vim.api.nvim_get_current_win())] then
          return
        end
        -- Typing, including the menu's own insertion, can scroll the view.
        -- Completion may already have redrawn the menu for that scroll, and
        -- then the view is the one the menu was placed in. Only a scroll
        -- without an edit moves away from the completion.
        if
          vim.b.changedtick ~= placed_tick or vim.deep_equal(vim.fn.winsaveview(), placed_view)
        then
          layout_and_draw()
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
    -- <C-c> leaves Insert mode without InsertLeave, and <C-r>= enters the
    -- command line without leaving Insert mode.
    vim.api.nvim_create_autocmd("ModeChanged", {
      group = group,
      callback = function()
        if mode_event().new_mode:sub(1, 1) ~= mode then
          dismiss()
        end
      end,
    })
    -- A nested command line such as <C-r>= does not leave the outer one.
    vim.api.nvim_create_autocmd({ "VimResized", "WinLeave", "CmdwinEnter", "CmdlineEnter" }, {
      group = group,
      callback = function()
        dismiss()
      end,
    })
  end

  ---Once the user moves the selection, the rows in view count as seen.
  function note_seen()
    browsing = browsing or (cursor > 0 and cursor ~= initial_cursor)
    if browsing then
      frozen = math.min(#items, math.max(frozen, top + height() - 1))
    end
  end

  ---Fit the menu to the room around the cursor and draw it there.
  function layout_and_draw()
    compute_layout()
    -- The fields share the screen width, within max_width, with the border
    -- and the scrollbar.
    local sides = borders.sides(menu.border)
    local limit = math.min(menu.max_width or 80, vim.o.columns - sides.left - sides.right)
    widths = columns.measure(items, limit - (layout.scrollbar and 1 or 0), cells)
    top = math.max(1, math.min(top, #items - height() + 1))
    -- A shorter menu keeps the selection in view.
    if cursor > 0 and cursor >= top + height() then
      top = cursor - height() + 1
    end
    ensure_buf()
    place()
    preview.place()
    render()
    note_seen()
  end

  local function show(col, new_items, new_mode)
    startcol, mode, items = col, new_mode, new_items
    shown = text_state(mode)
    layout_and_draw()
  end

  ---The first candidate the server preselects, else the first one under
  ---auto_select, else the typed input.
  ---@param new_items table[]
  ---@return integer
  local function initial_selection(new_items)
    for i, item in ipairs(new_items) do
      if item.preselect then
        return i
      end
    end
    return menu.auto_select and #new_items > 0 and 1 or 0
  end

  ---@param col integer 1-based
  ---@param new_items table[]
  ---@param new_mode "i"|"c"
  function ui.open(col, new_items, new_mode)
    top = 1
    cursor = initial_selection(new_items)
    browsing, frozen, initial_cursor = false, 0, cursor
    local state = text_state(new_mode)
    typed = state.line:sub(col, state.col)
    inserted = typed
    preview.reveal()
    show(col, new_items, new_mode)
    preview.update(items[cursor])
    redraw()
  end

  ---Release the frozen prefix after actual user input.
  function ui.reset()
    browsing, frozen, initial_cursor = false, 0, cursor
  end

  ---Rows up to the bottom of the viewport the user has seen while browsing
  ---stay in place while further candidates arrive.
  ---@return integer
  function ui.frozen_count()
    if not ui.visible() or not browsing then
      return 0
    end
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
    preview.hide()
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
    preview.close()
    cells = {}
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

  ---Replace the text between startcol and the cursor with `word`; `callback`
  ---runs once the edit is in place.
  ---@type fun(word: string, callback?: fun())
  local insert

  ---Run `step` once no insertion's keys are pending, in call order.
  ---@param step fun()
  local function after_pending(step)
    if pending_insertions > 0 then
      table.insert(after_insertions, step)
    else
      step()
    end
  end

  ---Run steps that waited for insertions, stopping when one feeds keys again.
  local function run_waiting()
    while pending_insertions == 0 and #after_insertions > 0 do
      table.remove(after_insertions, 1)()
    end
  end

  function insert(word, callback)
    inserted = word
    if mode == "i" and pending_insertions > 0 then
      -- Earlier keys are still queued, so the text is not final yet.
      table.insert(after_insertions, function()
        insert(word, callback)
      end)
      return
    end
    -- Keys cannot carry a NUL byte, so it is left out of the inserted text.
    local text = word:gsub("%z", "")
    local state = text_state(mode)
    local current = state.line:sub(startcol, state.col)
    local line = state.line:sub(1, startcol - 1) .. text .. state.line:sub(state.col + 1)
    expected = {
      mode = mode,
      state = vim.tbl_extend("force", state, { line = line, col = startcol - 1 + #text }),
    }
    shown = expected.state
    if mode == "c" then
      vim.fn.setcmdline(line, startcol + #text)
      if callback then
        callback()
      end
      return
    end
    -- Typed keys keep undo and dot-repeat intact, unlike direct buffer edits.
    relaxed.relax()
    local bs = vim.keycode("<BS>")
    -- One <BS> removes a character with its composing characters unless
    -- 'delcombine' makes it remove them one at a time.
    local chars = vim.fn.strchars(current, vim.o.delcombine and 0 or 1)
    -- Typed control characters act as keys, such as <Tab> under 'expandtab';
    -- <C-v> inserts them as they are. Newlines are meant to split the line.
    local typed_word = text:gsub("[\1-\9\11-\31\127]", "\22%0")
    pending_insertions = pending_insertions + 1
    feedkeys.feed(ui, { { bs:rep(chars), false }, { typed_word, true } }, function()
      pending_insertions = pending_insertions - 1
      relaxed.restore()
      -- The keys are in; record what they produced, which a prediction can
      -- miss when a confirmed candidate spans lines.
      expected = { mode = mode, state = text_state(mode) }
      shown = expected.state
      if callback then
        callback()
      end
      run_waiting()
    end)
  end

  ---While browsing, the menu must be able to replace its insertion with the
  ---next candidate and restore the typed input, which it tracks on one line.
  ---Candidates with newlines, or that auto-wrap would move to another line
  ---midway through the fed keys, are therefore only selected.
  ---@param word string
  ---@return boolean
  local function splits_line(word)
    if mode ~= "i" then
      return false
    elseif word:find("\n", 1, true) then
      return true
    elseif not vim.bo.formatoptions:find("[tca]") then
      return false
    end
    local width = vim.bo.textwidth
    if width <= 0 and vim.bo.wrapmargin > 0 then
      local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
      width = info.width - info.textoff - vim.bo.wrapmargin
    end
    if width <= 0 then
      return false
    end
    local before = vim.api.nvim_get_current_line():sub(1, startcol - 1)
    -- Auto-wrap starts only once the text goes past the limit.
    return vim.fn.strdisplaywidth(before .. word) > width
  end

  ---@param delta integer
  local function move(delta)
    if delta == 1 or delta == -1 then
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
    note_seen()
    render()
    preview.update(items[cursor])
    redraw()
  end

  ---Move the selection by `delta` and, unless `opts.insert` is false, put the
  ---selected text in place of the input. Single steps cycle through the typed
  ---input; larger moves stop at the first or last candidate.
  ---@param delta integer
  ---@param opts? { insert?: boolean }
  ---@return boolean handled
  function ui.select(delta, opts)
    -- Keys typed in the same batch have not reached the watchers yet.
    if delta == 0 or not ui.visible() or not reconcile() then
      return false
    end
    move(delta)
    if opts and opts.insert == false then
      return true
    end
    local word = cursor > 0 and items[cursor].word or typed
    if not splits_line(word) then
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
    local border = borders.drawn(win)
    local row = pos.screenrow - origin[1] + 1 - border.top
    local col = pos.screencol - origin[2] + 1 - border.left
    if row < 1 or row > height() or col < 1 or col > vim.api.nvim_win_get_width(win) then
      return false
    end
    move(index_at(row) - cursor)
    return true
  end

  ---@param after? fun() runs once the confirmation edits are applied
  ---@return boolean confirmed
  local function confirm(after)
    if not ui.visible() or not reconcile() then
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
        ok, err = xpcall(opts.on_confirm, debug.traceback, item)
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
    local word = item.word
    if opts.confirm_text then
      word = opts.confirm_text(item)
    end
    -- Typed text keeps dot-repeat; text that would split the line is left
    -- to on_confirm, as keys would reindent and rewrap it.
    if word and inserted ~= word and not splits_line(word) then
      insert(word, done)
    else
      -- The candidate's keys may still be queued; confirmation edits need them.
      after_pending(done)
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
      feedkeys.feed(ui, {}, function()
        if not confirm(type_key) then
          type_key()
        end
      end)
      return ""
    end, key_ns)
  end

  ---Restore the typed input and close the menu.
  ---@return boolean handled
  function ui.cancel()
    if not ui.visible() then
      return false
    elseif not reconcile() then
      -- The cursor had moved away; the menu is closed and nothing to restore.
      return true
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

  ---Close the menu and release its autocmds and key handler for good.
  function ui.dispose()
    ui.close()
    feedkeys.forget(ui)
    vim.on_key(nil, key_ns)
    vim.api.nvim_del_augroup_by_id(group)
    vim.api.nvim_del_augroup_by_id(state_group)
  end

  return ui
end

return M

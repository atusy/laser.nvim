---UI adapter for pum.vim (https://github.com/Shougo/pum.vim).
local M = {}
local active_ui

local augroup = vim.api.nvim_create_augroup("laser.ui.pum", { clear = true })

---@param opts? { on_confirm?: fun(candidate: table) }
---@return laser.UI
function M.new(opts)
  opts = opts or {}
  local ui = {}
  local browsing, frozen, opening = false, 0, false
  local columns, non_abbr, options

  function ui.reset()
    browsing, frozen = false, 0
  end

  function ui.frozen_count()
    if not browsing or not ui.visible() then
      return 0
    end
    local pum = vim.fn["pum#_get"]()
    local last
    if pum.horizontal_menu then
      -- Horizontal layout has no stable vertical viewport; retain its whole list.
      last = pum.len
    elseif pum.reversed == true or pum.reversed == 1 then
      last = pum.len - vim.fn.line("w0", pum.id) + 1
    else
      last = vim.fn.line("w0", pum.id) + vim.api.nvim_win_get_height(pum.id) - 1
    end
    frozen = math.min(pum.len, math.max(frozen, last))
    return frozen
  end

  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "PumCompleteChanged",
    callback = function()
      if active_ui ~= ui or opening or not ui.visible() then
        return
      end
      browsing = true
      ui.frozen_count()
      -- PumCompleteChanged runs just before pum moves its window cursor.
      vim.schedule(function()
        ui.frozen_count()
      end)
    end,
  })

  local function measure(items)
    columns, non_abbr = {}, 0
    local previous = 0
    for _, name in ipairs(options.item_orders) do
      local width = name == "space" and 1 or 0
      for _, item in ipairs(items) do
        local value = name == "abbr" and (item.abbr or item.word)
          or item[name]
          or (item.columns or {})[name]
          or ""
        width = math.max(width, vim.fn.strdisplaywidth(value))
      end
      width = math.min(width, options.max_columns[name] or width)
      if width > 0 and not (name == "space" and previous == 0) then
        columns[#columns + 1] = { name, width }
        if name ~= "abbr" then
          non_abbr = non_abbr + width
        end
        previous = width
      else
        previous = 0
      end
    end
  end

  ---@param startcol integer 1-based
  ---@param items table[]
  ---@param mode "i"|"c"
  function ui.open(startcol, items, mode)
    ui.reset()
    active_ui = ui
    opening = true
    vim.fn["pum#open"](startcol, items, mode)
    opening = false
    options = vim.fn["pum#_options"]()
    measure(items)
  end

  function ui.update(startcol, items, mode)
    if not ui.visible() then
      return
    end
    local pum = vim.fn["pum#_get"]()
    local count = ui.frozen_count()
    local view = not pum.horizontal_menu and vim.api.nvim_win_call(pum.id, vim.fn.winsaveview)
    local padding = options.padding and ((mode == "c" or startcol ~= 1) and 2 or 1) or 0
    local lines = {}
    for i, item in ipairs(items) do
      lines[i] = vim.fn["pum#_format_item"](
        item,
        options,
        mode,
        startcol,
        columns,
        math.max(1, pum.width - non_abbr - padding)
      )
    end
    vim.fn["laser#pum#update"](items, lines, count)
    if view then
      if pum.reversed == true or pum.reversed == 1 then
        local offset = #items - pum.len
        view.topline, view.lnum = view.topline + offset, view.lnum + offset
      end
      vim.api.nvim_win_call(pum.id, function()
        vim.fn.winrestview(view)
      end)
      vim.fn["pum#popup#_redraw_selected"]()
      vim.fn["laser#pum#scrollbar"]()
      vim.fn["pum#popup#_redraw_scroll"]()
    end
  end

  function ui.close()
    ui.reset()
    vim.fn["pum#close"]()
  end

  ---@return boolean
  function ui.visible()
    return vim.fn["pum#visible"]() == 1 or vim.fn["pum#visible"]() == true
  end

  ---True when the text change being handled was made by pum.vim itself
  ---(inserting the selected word), so the engine must not re-render and
  ---reset the selection.
  ---@return boolean
  function ui.skip_text_change()
    local skip = vim.fn["pum#skip_complete"]()
    return skip == 1 or skip == true
  end

  if opts.on_confirm then
    vim.api.nvim_create_autocmd("User", {
      group = augroup,
      pattern = "PumCompleteDone",
      desc = "laser: apply the accepted item",
      callback = function()
        -- pum.vim also fires this with "complete_done" when a menu closes
        -- after the user browsed but kept typing; only explicit confirms
        -- ("confirm", "confirm_word") mean the item was accepted.
        local event = vim.g["pum#completed_event"] or ""
        local item = vim.g["pum#completed_item"]
        if
          vim.startswith(event, "confirm")
          and type(item) == "table"
          and vim.tbl_get(item, "user_data", "laser")
        then
          opts.on_confirm(item)
        end
      end,
    })
  end

  return ui
end

return M

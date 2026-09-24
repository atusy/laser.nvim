---The documentation preview beside the menu.
local M = {}

local borders = require("laser.ui.border")
local documentation = require("laser.preview")
local style = require("laser.ui.style")

---What the preview needs from the menu it sits beside.
---@class laser.PreviewHost
---@field menu_win fun(): integer the menu window
---@field above fun(): boolean whether the menu opens above the cursor
---@field options fun(): boolean|laser.PreviewOpts|nil the menu's preview option
---@field visible fun(): boolean whether the menu is shown
---@field redraw fun() flush what changed on screen
---@field context? fun(candidate: table): { client?: vim.lsp.Client, bufnr: integer }?

---@param host laser.PreviewHost
function M.new(host)
  local self = {}
  local buf, win, cancel_resolve
  -- Resolved documentation by candidate id. Ids restart with each completion
  -- session, so the cache lives only while the menu is open.
  local resolved = {}
  local hidden = false

  ---@return laser.PreviewOpts
  local function preview_options()
    local value = host.options()
    return type(value) == "table" and value or {}
  end

  function self.hide()
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    win = nil
  end

  local function close()
    if cancel_resolve then
      cancel_resolve()
      cancel_resolve = nil
    end
    self.hide()
  end

  ---@type { width: integer, max_height: integer }
  local size -- natural size of the drawn documentation

  ---Put the preview beside the menu, or on its left when the right is too
  ---narrow. The menu's configured position is where it is drawn.
  ---@return boolean placed false when there is no room and it was hidden
  function self.place()
    if not (win and vim.api.nvim_win_is_valid(win)) then
      return false
    end
    local options = preview_options()
    local own = borders.sides(options.border)
    local border = own.left + own.right
    local menu_win = host.menu_win()
    local anchor = vim.api.nvim_win_get_config(menu_win)
    local sides = borders.drawn(menu_win)
    local right = anchor.col + sides.left + anchor.width + sides.right
    local right_room = vim.o.columns - right - border
    local left_room = anchor.col - border
    -- Never cover the menu: narrow the preview to the side it goes on.
    local width, col = size.width, right
    if width > right_room and left_room > right_room then
      width = math.min(width, left_room)
      col = anchor.col - width - border
    else
      width = math.min(width, right_room)
    end
    if width < 1 then
      self.hide()
      return false
    end
    -- The preview wraps; let Neovim count the rows at this width, including
    -- tabs and wide characters that do not split across rows.
    vim.api.nvim_win_set_config(win, { width = width })
    local height = vim.api.nvim_win_text_height(win, {}).all
    height = math.min(height, size.max_height)
    -- Stay on the menu's side of the cursor line, and above the command line.
    local edges = own.top + own.bottom
    local row
    if host.above() then
      -- Grow upward from the menu's bottom edge.
      local bottom = anchor.row + anchor.height + sides.top + sides.bottom
      height = math.max(1, math.min(height, bottom - edges))
      row = math.max(0, bottom - height - edges)
    else
      -- Grow downward from the menu's top edge.
      local limit = vim.o.lines - vim.o.cmdheight
      height = math.max(1, math.min(height, limit - anchor.row - edges))
      row = anchor.row
    end
    vim.api.nvim_win_set_config(win, {
      relative = "editor",
      row = row,
      col = col,
      width = width,
      height = height,
      border = options.border or "none",
    })
    return true
  end

  ---@param text string
  ---@param filetype string
  local function draw(text, filetype)
    if not host.visible() then
      return
    end
    if text == "" then
      self.hide()
      return
    end
    local options = preview_options()
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
      buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].bufhidden = "hide"
    end
    local lines = vim.split(text, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    -- Setting 'filetype' reruns FileType handlers even for the same value.
    if vim.bo[buf].filetype ~= filetype then
      vim.bo[buf].filetype = filetype
    end
    local width = 1
    for _, line in ipairs(lines) do
      width = math.max(width, vim.fn.strdisplaywidth(line))
    end
    size = {
      width = math.min(width, options.max_width or 60),
      max_height = options.max_height or 20,
    }
    if not (win and vim.api.nvim_win_is_valid(win)) then
      win = vim.api.nvim_open_win(buf, false, {
        relative = "editor",
        row = 0,
        col = 0,
        width = size.width,
        height = 1,
        style = "minimal",
        focusable = false,
        zindex = 201,
        noautocmd = true,
      })
      vim.wo[win].winhighlight = style.WINHIGHLIGHT
      vim.wo[win].wrap = true
      -- Windows inherit folding; documentation should be shown whole.
      vim.wo[win].foldenable = false
      vim.wo[win].winblend = vim.o.pumblend
    end
    if not self.place() then
      return
    end
    vim.api.nvim_win_call(win, function()
      -- Scrolling moved the cursor too; Neovim would keep it in view.
      vim.fn.winrestview({ topline = 1, lnum = 1 })
    end)
  end

  ---Show `item`'s documentation, then its resolved version; nil closes.
  ---@param item? table
  function self.update(item)
    if cancel_resolve then
      cancel_resolve()
      cancel_resolve = nil
    end
    if not host.options() or hidden or not item or not host.visible() then
      close()
      return
    end
    local id = item.user_data.laser.id
    if id and resolved[id] then
      draw(unpack(resolved[id]))
      return
    end
    local lsp_item = item.user_data.laser.item
    draw(documentation.info(lsp_item))
    local context = host.context and host.context(item)
    if context and context.client then
      cancel_resolve = documentation.resolve(
        lsp_item,
        context.client,
        context.bufnr,
        function(info, ft)
          if id then
            resolved[id] = { info, ft }
          end
          draw(info, ft)
          host.redraw()
        end
      )
    end
  end

  ---@return integer?
  function self.win()
    return win
  end

  ---Close the preview and forget resolved documentation.
  function self.close()
    close()
    resolved = {}
  end

  ---Show the preview again when the menu reopens.
  function self.reveal()
    hidden = false
  end

  ---Hide or show the preview for `item`.
  ---@param item? table
  function self.toggle(item)
    hidden = not hidden
    self.update(item)
  end

  ---@param delta integer lines to scroll; negative scrolls up
  ---@return boolean scrolled
  function self.scroll(delta)
    -- A zero count would make the scroll command move one line.
    if delta == 0 or not (win and vim.api.nvim_win_is_valid(win)) then
      return false
    end
    vim.api.nvim_win_call(win, function()
      local key = delta > 0 and "\5" or "\25"
      -- :normal passes through Normal mode; the menu must not see it leave.
      vim.cmd("noautocmd normal! " .. math.abs(delta) .. key)
    end)
    return true
  end

  return self
end

return M

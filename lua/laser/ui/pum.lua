---UI adapter for pum.vim (https://github.com/Shougo/pum.vim).
local M = {}

---@param opts? { on_confirm?: fun(candidate: table) }
---@return laser.UI
function M.new(opts)
  opts = opts or {}
  local ui = {}

  ---@param startcol integer 1-based
  ---@param items table[]
  ---@param mode "i"|"c"
  function ui.open(startcol, items, mode)
    vim.fn["pum#open"](startcol, items, mode)
  end

  function ui.close()
    vim.fn["pum#close"]()
  end

  ---@return boolean
  function ui.visible()
    return vim.fn["pum#visible"]() == 1 or vim.fn["pum#visible"]() == true
  end

  return ui
end

return M

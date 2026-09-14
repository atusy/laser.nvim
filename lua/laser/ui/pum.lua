---UI adapter for pum.vim (https://github.com/Shougo/pum.vim).
local M = {}

local augroup = vim.api.nvim_create_augroup("laser.ui.pum", { clear = true })

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
        if vim.startswith(event, "confirm") and type(item) == "table" and vim.tbl_get(item, "user_data", "laser") then
          opts.on_confirm(item)
        end
      end,
    })
  end

  return ui
end

return M

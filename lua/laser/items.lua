local M = {}

---@class laser.ConvertContext
---@field line string
---@field startcol integer 0-based byte column where the menu replaces text
---@field cursor_col integer 0-based byte column of the cursor
---@field encoding string
---@field client_id integer

---@param item lsp.CompletionItem
---@param ctx laser.ConvertContext
---@return table complete-item
function M.convert(item, ctx)
  local _ = ctx
  return { word = item.label, abbr = item.label }
end

return M

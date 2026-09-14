local M = {}

local SNIPPET = 2 -- lsp.InsertTextFormat.Snippet

---@class laser.ConvertContext
---@field line string
---@field startcol integer 0-based byte column where the menu replaces text
---@field cursor_col integer 0-based byte column of the cursor
---@field encoding string
---@field client_id integer

---@param item lsp.CompletionItem
---@return string
local function insert_text(item)
  if item.insertTextFormat == SNIPPET then
    -- The snippet body is expanded on confirm; while browsing, show the label.
    return item.label
  end
  return item.insertText or item.label
end

---@param item lsp.CompletionItem
---@param ctx laser.ConvertContext
---@return table complete-item
function M.convert(item, ctx)
  local _ = ctx
  return { word = insert_text(item), abbr = item.label }
end

return M

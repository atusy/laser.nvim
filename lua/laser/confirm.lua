local M = {}

---@class laser.ConfirmOpts
---@field bufnr integer
---@field startcol integer 0-based byte column the menu replaced from
---@field client vim.lsp.Client

---@param candidate table complete-item produced by laser.items
---@param opts laser.ConfirmOpts
function M.apply(candidate, opts)
  local item = candidate.user_data.laser.item ---@type lsp.CompletionItem
  local edits = item.additionalTextEdits
  if edits and next(edits) then
    vim.lsp.util.apply_text_edits(edits, opts.bufnr, opts.client.offset_encoding, nil, { keep_cursor = true })
  end
end

return M

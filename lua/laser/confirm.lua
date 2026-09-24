local M = {}

local SNIPPET = 2 -- lsp.InsertTextFormat.Snippet

---@class laser.ConfirmOpts
---@field bufnr integer
---@field startcol integer 0-based byte column where the item's edit starts
---@field client vim.lsp.Client

---@param item lsp.CompletionItem
---@return string?
local function snippet_body(item)
  if item.insertTextFormat ~= SNIPPET then
    return nil
  end
  if item.textEdit then
    return item.textEdit.newText
  end
  return item.insertText
end

---Drop the word the menu inserted (from the menu start to the cursor) and
---expand the snippet in its place.
---@param body string
---@param opts laser.ConfirmOpts
local function expand_snippet(body, opts)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local from = opts.startcol
  vim.api.nvim_buf_set_text(opts.bufnr, row - 1, from, row - 1, col, { "" })
  vim.api.nvim_win_set_cursor(0, { row, from })
  vim.snippet.expand(body)
end

---@param edits lsp.TextEdit[]?
---@param opts laser.ConfirmOpts
---@return boolean applied
local function apply_additional_edits(edits, opts)
  if not edits or not next(edits) then
    return false
  end
  vim.lsp.util.apply_text_edits(
    edits,
    opts.bufnr,
    opts.client.offset_encoding,
    nil,
    { keep_cursor = true }
  )
  return true
end

---@param item lsp.CompletionItem
---@param opts laser.ConfirmOpts
local function exec_command(item, opts)
  if item.command then
    opts.client:exec_cmd(item.command, { bufnr = opts.bufnr })
  end
end

---@param candidate table complete-item produced by laser.items
---@param opts laser.ConfirmOpts
function M.apply(candidate, opts)
  local item = candidate.user_data.laser.item ---@type lsp.CompletionItem
  local body = snippet_body(item)
  if body then
    expand_snippet(body, opts)
  end
  local had_edits = apply_additional_edits(item.additionalTextEdits, opts)

  -- Nothing to gain if the item carried its edits, or it cannot be resolved.
  if had_edits or not opts.client:supports_method("completionItem/resolve", opts.bufnr) then
    exec_command(item, opts)
    return
  end

  opts.client:request("completionItem/resolve", item, function(err, resolved)
    if not vim.api.nvim_buf_is_valid(opts.bufnr) then
      return
    end
    resolved = require("laser.items").drop_null(resolved)
    if err then
      vim.notify_once(err.message, vim.log.levels.WARN)
    elseif resolved then
      apply_additional_edits(resolved.additionalTextEdits, opts)
      -- A resolved command replaces the one the item came with.
      item.command = resolved.command or item.command
    end
    exec_command(item, opts)
  end, opts.bufnr)
end

return M

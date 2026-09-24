local M = {}

---@param uri string
---@param line_nr integer 0-based
---@param line string
---@param byte_col integer 0-based byte column
---@param encoding string
---@return lsp.TextDocumentPositionParams
function M.params(uri, line_nr, line, byte_col, encoding)
  return {
    textDocument = { uri = uri },
    position = { line = line_nr, character = vim.str_utfindex(line, encoding, byte_col, false) },
  }
end

---Run `fn` with the options of `bufnr`, such as 'iskeyword', in effect.
---@generic T
---@param bufnr? integer
---@param fn fun(): T
---@return T
function M.in_buffer(bufnr, fn)
  if
    not bufnr
    or bufnr == vim.api.nvim_get_current_buf()
    or not vim.api.nvim_buf_is_valid(bufnr)
  then
    return fn()
  end
  return vim.api.nvim_buf_call(bufnr, fn)
end

---Byte column (0-based) where the keyword run ending at byte_col starts.
---@param line string
---@param byte_col integer 0-based
---@param bufnr? integer buffer whose 'iskeyword' applies; the current one by default
---@return integer
function M.keyword_start(line, byte_col, bufnr)
  local before = line:sub(1, byte_col)
  return M.in_buffer(bufnr, function()
    return vim.fn.match(before, [[\k*$]])
  end)
end

return M

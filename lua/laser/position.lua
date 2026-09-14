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

---Byte column (0-based) where the keyword run ending at byte_col starts.
---@param line string
---@param byte_col integer 0-based
---@return integer
function M.keyword_start(line, byte_col)
  local before = line:sub(1, byte_col)
  return vim.fn.match(before, [[\k*$]])
end

return M

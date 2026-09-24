---Snapshots of the text being completed: the current line in Insert mode or
---the command line mirrored into a scratch document.
local M = {}

---@param language_id? string filetype of the scratch document in command-line mode
---@return laser.Doc?
function M.current(language_id)
  local mode = vim.api.nvim_get_mode().mode:sub(1, 1)
  if mode == "c" then
    if not language_id then
      return
    end
    local cmdline = require("laser.cmdline")
    local doc = cmdline.ensure_buffer(language_id)
    local text = vim.fn.getcmdline()
    cmdline.set_text(doc.bufnr, text)
    return {
      bufnr = doc.bufnr,
      uri = doc.uri,
      line_nr = 0,
      line = text,
      col = vim.fn.getcmdpos() - 1,
      mode = "c",
    }
  elseif mode == "i" then
    local buf = vim.api.nvim_get_current_buf()
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    return {
      bufnr = buf,
      uri = vim.uri_from_bufnr(buf),
      line_nr = row - 1,
      line = vim.api.nvim_get_current_line(),
      col = col,
      mode = "i",
    }
  end
end

---Return the inserted character only for a single-character insertion at the
---previous cursor. Deletions, replacements and cursor moves are not triggers.
---@param old? laser.Doc
---@param doc laser.Doc
---@return string
function M.inserted_char(old, doc)
  if not old or old.bufnr ~= doc.bufnr or old.line_nr ~= doc.line_nr or old.mode ~= doc.mode then
    return ""
  end
  if
    doc.col <= old.col
    or doc.line:sub(1, old.col) ~= old.line:sub(1, old.col)
    or doc.line:sub(doc.col + 1) ~= old.line:sub(old.col + 1)
  then
    return ""
  end
  local char = doc.line:sub(old.col + 1, doc.col)
  return vim.fn.strchars(char) == 1 and char or ""
end

return M

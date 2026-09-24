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

---Whether the editor still shows `doc` around the completed text: the same
---line with the same text before `startcol` and after the cursor. Text
---between them may differ, as the menu inserts candidates there.
---@param doc laser.Doc
---@param startcol integer 0-based byte column where the menu replaces text
---@return boolean
function M.continues(doc, startcol)
  local line, col
  if vim.api.nvim_get_mode().mode:sub(1, 1) ~= doc.mode then
    return false
  elseif doc.mode == "c" then
    line, col = vim.fn.getcmdline(), vim.fn.getcmdpos() - 1
  else
    local row
    row, col = unpack(vim.api.nvim_win_get_cursor(0))
    if vim.api.nvim_get_current_buf() ~= doc.bufnr or row - 1 ~= doc.line_nr then
      return false
    end
    line = vim.api.nvim_get_current_line()
  end
  return col >= startcol
    and line:sub(1, startcol) == doc.line:sub(1, startcol)
    and line:sub(col + 1) == doc.line:sub(doc.col + 1)
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

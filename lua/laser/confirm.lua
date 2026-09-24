---Accepting a candidate applies the server's edits as the LSP describes them:
---the item's edit and its additionalTextEdits, all in the coordinates of the
---document as it was when completion was requested.
local M = {}

local items = require("laser.items")

local SNIPPET = 2 -- lsp.InsertTextFormat.Snippet
local ADJUST_INDENTATION = 2 -- lsp.InsertTextMode.adjustIndentation
local ns = vim.api.nvim_create_namespace("laser.confirm")

---@class laser.ConfirmOpts
---@field bufnr integer
---@field client vim.lsp.Client
---@field startcol? integer 0-based byte column where the menu's text starts; defaults to the item's own start
---@field resolve_timeout_ms? integer how long to wait for completionItem/resolve; default 1000

---@class laser.Request The completion line when the candidate was requested.
---@field line string
---@field line_nr integer 0-based
---@field col integer 0-based byte column of the cursor

---Fill in edits and commands the server leaves to completionItem/resolve.
---Waiting here keeps late edits from landing after the user moved on.
---@param item lsp.CompletionItem
---@param opts laser.ConfirmOpts
---@return lsp.CompletionItem
local function resolve(item, opts)
  if
    item.additionalTextEdits
    or not opts.client:supports_method("completionItem/resolve", opts.bufnr)
  then
    return item
  end
  local done, expired, resolved = false, false, nil
  local ok, id = opts.client:request("completionItem/resolve", item, function(err, result)
    if expired then
      return
    end
    done = true
    if err then
      vim.notify_once(err.message, vim.log.levels.WARN)
    else
      resolved = items.drop_null(result)
    end
  end, opts.bufnr)
  if not ok then
    return item
  end
  if
    not done and not vim.wait(opts.resolve_timeout_ms or 1000, function()
      return done
    end, 1)
  then
    expired = true
    opts.client:cancel_request(id)
    return item
  end
  if type(resolved) ~= "table" then
    return item
  end
  return vim.tbl_extend("force", item, resolved)
end

---@param bufnr integer
---@param row integer 0-based
---@return string
local function get_line(bufnr, row)
  return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
end

---@param bufnr integer
---@param pos lsp.Position
---@param encoding string
---@return integer row, integer col 0-based byte position
local function byte_position(bufnr, pos, encoding)
  return pos.line, vim.str_byteindex(get_line(bufnr, pos.line), encoding, pos.character, false)
end

---The item's own edit as a byte range of the restored document. An item
---without a range replaces the typed word from its start column.
---@param item lsp.CompletionItem
---@param start integer the item's start column
---@param request laser.Request
---@param opts laser.ConfirmOpts
---@return { [1]: integer, [2]: integer, [3]: integer, [4]: integer } range
---@return string text
local function main_edit(item, start, request, opts)
  local edit = item.textEdit
  if edit then
    -- The insert range of an InsertReplaceEdit, like the menu's own word.
    local range = edit.range or edit.insert
    local encoding = opts.client.offset_encoding
    local srow, scol = byte_position(opts.bufnr, range.start, encoding)
    local erow, ecol = byte_position(opts.bufnr, range["end"], encoding)
    return { srow, scol, erow, ecol }, edit.newText
  end
  local text = item.insertText or item.label
  return { request.line_nr, start, request.line_nr, request.col }, text
end

---@param text string
---@param bufnr integer
---@param row integer 0-based row the text starts on
---@param item lsp.CompletionItem
---@return string[]
local function text_lines(text, bufnr, row, item)
  local lines = vim.split(text:gsub("\r\n?", "\n"), "\n", { plain = true })
  if item.insertTextMode == ADJUST_INDENTATION then
    local indent = get_line(bufnr, row):match("^%s*")
    for i = 2, #lines do
      lines[i] = indent .. lines[i]
    end
  end
  return lines
end

---@param bufnr integer
---@return integer? window showing the buffer, preferring the current one
local function window_of(bufnr)
  if vim.api.nvim_win_get_buf(0) == bufnr then
    return vim.api.nvim_get_current_win()
  end
  local win = vim.fn.bufwinid(bufnr)
  return win ~= -1 and win or nil
end

---Text a snippet expands to, without tabstops, for where it cannot expand.
---@param body string
---@return string
function M.snippet_text(body)
  local ok, parsed = pcall(function()
    return tostring(require("vim.lsp._snippet_grammar").parse(body))
  end)
  return ok and parsed or body
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
  local data = candidate.user_data.laser
  local item = resolve(data.item, opts) ---@type lsp.CompletionItem
  local request = data.request ---@type laser.Request
  local bufnr, row = opts.bufnr, request.line_nr

  -- The line is unchanged before the menu's text and after the cursor; put
  -- back what was typed at request time in between.
  local from = math.min(opts.startcol or data.startcol, data.startcol)
  local current = get_line(bufnr, row)
  local to = #current - (#request.line - request.col)
  local restored = request.line:sub(from + 1, request.col)
  local snippet = item.insertTextFormat == SNIPPET
  local edits = item.additionalTextEdits or {}
  local range, text = main_edit(item, data.startcol, request, opts)
  if not snippet and not next(edits) and range[1] == row and range[3] == row then
    local final = request.line:sub(1, range[2]) .. text .. request.line:sub(range[4] + 1)
    if final == current then
      -- The menu already typed exactly this; keep the typed keys as they are.
      exec_command(item, opts)
      return
    end
  end
  vim.api.nvim_buf_set_text(bufnr, row, from, row, to, { restored })
  if item.textEdit then
    -- Ranges are relative to the restored document.
    range, text = main_edit(item, data.startcol, request, opts)
  end

  -- Track the item's range while the additional edits move text around it.
  local start_mark =
    vim.api.nvim_buf_set_extmark(bufnr, ns, range[1], range[2], { right_gravity = false })
  local end_mark = vim.api.nvim_buf_set_extmark(bufnr, ns, range[3], range[4], {})
  if next(edits) then
    vim.lsp.util.apply_text_edits(edits, bufnr, opts.client.offset_encoding)
  end
  local srow, scol = unpack(vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, start_mark, {}))
  local erow, ecol = unpack(vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, end_mark, {}))
  vim.api.nvim_buf_del_extmark(bufnr, ns, start_mark)
  vim.api.nvim_buf_del_extmark(bufnr, ns, end_mark)

  local win = window_of(bufnr)
  if snippet and win and win == vim.api.nvim_get_current_win() then
    vim.api.nvim_buf_set_text(bufnr, srow, scol, erow, ecol, { "" })
    vim.api.nvim_win_set_cursor(win, { srow + 1, scol })
    vim.snippet.expand(text)
  else
    if snippet then
      text = M.snippet_text(text)
    end
    local lines = text_lines(text, bufnr, srow, item)
    vim.api.nvim_buf_set_text(bufnr, srow, scol, erow, ecol, lines)
    if win then
      local last = #lines == 1 and scol + #lines[1] or #lines[#lines]
      vim.api.nvim_win_set_cursor(win, { srow + #lines, last })
    end
  end
  exec_command(item, opts)
end

return M

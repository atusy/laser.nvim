local M = {}

local SNIPPET = 2 -- lsp.InsertTextFormat.Snippet

---@param item lsp.CompletionItem
---@return boolean
function M.is_snippet(item)
  return item.insertTextFormat == SNIPPET
end

---@class laser.ConvertContext
---@field line string
---@field line_nr? integer 0-based line number
---@field startcol integer 0-based byte column where the menu replaces text
---@field cursor_col integer 0-based byte column of the cursor
---@field encoding string
---@field client_id integer
---@field request? laser.Request the completion line when the response was requested
---@field symbols? string non-keyword text before startcol, computed on demand
---@field bufnr? integer document whose 'iskeyword' applies

---The item's edit range; the insert range of an InsertReplaceEdit.
---@param item lsp.CompletionItem
---@return lsp.Range?
function M.edit_range(item)
  local edit = item.textEdit
  if not edit then
    return nil
  end
  return edit.range or edit.insert
end

---Remove JSON nulls, which Neovim decodes as vim.NIL, so absent and null
---fields read the same. Tables are rewritten in place.
---@generic T
---@param value T
---@return T
function M.drop_null(value)
  if value == vim.NIL then
    return nil
  end
  if type(value) == "table" then
    for key, field in pairs(value) do
      if field == vim.NIL then
        value[key] = nil
      else
        M.drop_null(field)
      end
    end
  end
  return value
end

---Materialize list defaults without changing the server's response table.
---@param item lsp.CompletionItem
---@param defaults? table
---@return lsp.CompletionItem
function M.with_defaults(item, defaults)
  if not defaults then
    return item
  end
  local result = {}
  for key, value in pairs(item) do
    result[key] = value
  end
  for _, key in ipairs({ "insertTextFormat", "insertTextMode", "data", "commitCharacters" }) do
    if result[key] == nil then
      result[key] = defaults[key]
    end
  end
  if not result.textEdit and defaults.editRange then
    local range = defaults.editRange
    result.textEdit = {
      newText = item.textEditText or item.insertText or item.label,
      range = range.start and range or nil,
      insert = range.insert,
      replace = range.replace,
    }
  end
  return result
end

---Byte column of the item's edit start when it is on the completion line and
---not after the cursor; nil when the item has no applicable range.
---@param item lsp.CompletionItem
---@param ctx laser.ConvertContext
---@return integer?
local function edit_start(item, ctx)
  local range = M.edit_range(item)
  if not range or (ctx.line_nr and range.start.line ~= ctx.line_nr) then
    return nil
  end
  local char = range.start.character
  if char < 0 or char > vim.str_utfindex(ctx.line, ctx.encoding, ctx.cursor_col) then
    return nil
  end
  return vim.str_byteindex(ctx.line, ctx.encoding, char, false)
end

---Text before the keyword boundary that is not keyword text, like "@" or
---"--". Cached on ctx, which a response's items share.
---@param ctx laser.ConvertContext
---@return string
local function symbols_before(ctx)
  if not ctx.symbols then
    local before = ctx.line:sub(1, ctx.startcol)
    -- The trailing run of characters that are neither keyword nor blank.
    local from = require("laser.position").in_buffer(ctx.bufnr, function()
      return vim.fn.match(before, [[\%(\%(\k\|\s\)\@!.\)*$]])
    end)
    ctx.symbols = before:sub(from + 1)
  end
  return ctx.symbols
end

---Use the item's edit start when it is applicable. Items without a range use
---the keyword boundary, moved back over symbols the item's text starts with,
---so "@pr" completes to "@property" rather than "@@property".
---@param item lsp.CompletionItem
---@param ctx laser.ConvertContext
---@return integer
function M.start_col(item, ctx)
  local start = edit_start(item, ctx)
  if start then
    return start
  elseif item.textEdit then
    return ctx.startcol
  end
  local symbols = symbols_before(ctx)
  if symbols == "" then
    return ctx.startcol
  end
  local text = item.insertTextFormat ~= SNIPPET and item.insertText or item.label
  for k = math.min(#symbols, #text), 1, -1 do
    if text:sub(1, k) == symbols:sub(-k) then
      return ctx.startcol - k
    end
  end
  return ctx.startcol
end

---@param item lsp.CompletionItem
---@return string
local function insert_text(item)
  if item.insertTextFormat == SNIPPET then
    -- The snippet body is expanded on confirm; while browsing, show the label.
    return item.label
  end
  if item.textEdit then
    return item.textEdit.newText
  end
  return item.insertText or item.label
end

---Text that must appear between ctx.startcol and the cursor once the item is
---accepted, given that the menu replaces from ctx.startcol but the server's
---edit may start elsewhere on the line.
---@param item lsp.CompletionItem
---@param ctx laser.ConvertContext
---@return string
local function word(item, ctx)
  local text = insert_text(item)
  local start = edit_start(item, ctx)
  if not start or item.insertTextFormat == SNIPPET then
    return text
  end
  if start > ctx.startcol then
    return ctx.line:sub(ctx.startcol + 1, start) .. text
  end
  if start < ctx.startcol then
    local shared = ctx.line:sub(start + 1, ctx.startcol)
    if vim.startswith(text, shared) then
      return text:sub(#shared + 1)
    end
  end
  return text
end

---@param item lsp.CompletionItem
---@param ctx laser.ConvertContext
---@return table complete-item
function M.convert(item, ctx)
  return {
    word = word(item, ctx),
    abbr = item.label,
    kind = item.kind and vim.lsp.protocol.CompletionItemKind[item.kind] or nil,
    menu = item.labelDetails and item.labelDetails.description or nil,
    preselect = item.preselect == true or nil,
    user_data = { laser = { client_id = ctx.client_id, item = item, request = ctx.request } },
  }
end

return M

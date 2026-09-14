local M = {}

local SNIPPET = 2 -- lsp.InsertTextFormat.Snippet

---@class laser.ConvertContext
---@field line string
---@field startcol integer 0-based byte column where the menu replaces text
---@field cursor_col integer 0-based byte column of the cursor
---@field encoding string
---@field client_id integer

---@param item lsp.CompletionItem
---@return lsp.Range?
local function edit_range(item)
  local edit = item.textEdit
  if not edit then
    return nil
  end
  return edit.range or edit.insert
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
  local range = edit_range(item)
  if not range or item.insertTextFormat == SNIPPET then
    return text
  end
  local edit_start = vim.str_byteindex(ctx.line, ctx.encoding, range.start.character, false)
  if edit_start > ctx.startcol then
    return ctx.line:sub(ctx.startcol + 1, edit_start) .. text
  end
  if edit_start < ctx.startcol then
    local shared = ctx.line:sub(edit_start + 1, ctx.startcol)
    if vim.startswith(text, shared) then
      return text:sub(#shared + 1)
    end
  end
  return text
end

---@param doc string|lsp.MarkupContent|nil
---@return string?
local function info(doc)
  if type(doc) == "table" then
    return doc.value
  end
  return doc
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
    info = info(item.documentation),
  }
end

return M

---The menu's columns: the text each shows for a candidate and their widths.
local M = {}

M.NAMES = { "abbr", "kind", "menu" }

---@param item table
---@param name string
---@return string
function M.field(item, name)
  local text
  if name == "abbr" then
    text = item.abbr or item.word or ""
  else
    text = item[name] or ""
  end
  -- A newline cannot be drawn in a row and a tab is wider than one cell.
  -- Replace each control byte with one space so highlight offsets still hold.
  if text:find("%c") then
    text = text:gsub("%c", " ")
  end
  return text
end

---Cut `text` to at most `width` display cells and pad it to exactly `width`.
---@param text string
---@param width integer
---@return string padded
---@return integer kept byte length of the text before the padding
function M.fit(text, width)
  local cells = vim.api.nvim_strwidth(text)
  if cells > width then
    -- Every character takes at least one cell, so start from `width` of them
    -- and drop only what wide characters push past the limit. Composing
    -- characters take no cell and stay with their base character.
    local chars = width
    local original = text
    text = vim.fn.strcharpart(original, 0, chars, 1)
    cells = vim.api.nvim_strwidth(text)
    while chars > 0 and cells > width do
      chars = chars - 1
      text = vim.fn.strcharpart(original, 0, chars, 1)
      cells = vim.api.nvim_strwidth(text)
    end
  end
  return text .. string.rep(" ", width - cells), #text
end

---Column widths over every candidate, so the menu does not jitter on scroll.
---@param items table[]
---@param limit integer
---@param cells table<string, integer> display widths already measured
---@return table<string, integer>
function M.measure(items, limit, cells)
  local widths = {}
  for _, name in ipairs(M.NAMES) do
    local width = 0
    for _, item in ipairs(items) do
      local text = M.field(item, name)
      local cell = cells[text]
      if not cell then
        cell = vim.api.nvim_strwidth(text)
        cells[text] = cell
      end
      width = math.max(width, cell)
    end
    widths[name] = width
  end
  -- Give up the least important columns first when the menu is too wide.
  for _, name in ipairs({ "menu", "kind", "abbr" }) do
    local total, shown = 0, 0
    for _, other in ipairs(M.NAMES) do
      if widths[other] > 0 then
        total, shown = total + widths[other], shown + 1
      end
    end
    local excess = total + math.max(shown - 1, 0) - limit
    if excess <= 0 then
      break
    end
    widths[name] = math.max(widths[name] - excess, 0)
  end
  return widths
end

---One menu row for `item`.
---@param item table
---@param widths table<string, integer> from measure()
---@return string line
---@return table<string, { [1]: integer, [2]: integer }> spans 0-based byte range of each field's text, without padding
function M.format(item, widths)
  local parts, spans, offset = {}, {}, 0
  for _, name in ipairs(M.NAMES) do
    if widths[name] > 0 then
      local text, kept = M.fit(M.field(item, name), widths[name])
      if #parts > 0 then
        offset = offset + 1
      end
      spans[name] = { offset, offset + kept }
      parts[#parts + 1] = text
      offset = offset + #text
    end
  end
  return table.concat(parts, " "), spans
end

return M

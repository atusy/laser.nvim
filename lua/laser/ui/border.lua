local M = {}

---@class laser.BorderSides
---@field top integer
---@field right integer
---@field bottom integer
---@field left integer

---Cells a nvim_open_win() border takes on each side. An edge whose character
---is empty is not drawn, and "shadow" has only right and bottom edges.
---@param border? string|table
---@return laser.BorderSides
function M.sides(border)
  if border == nil or border == "none" or border == "" then
    return { top = 0, right = 0, bottom = 0, left = 0 }
  elseif border == "shadow" then
    return { top = 0, right = 1, bottom = 1, left = 0 }
  elseif type(border) == "string" then
    return { top = 1, right = 1, bottom = 1, left = 1 }
  end
  -- Clockwise from the top-left corner; shorter lists repeat.
  local function edge(index)
    local part = border[(index - 1) % #border + 1]
    if type(part) == "table" then
      part = part[1]
    end
    return (part and part ~= "") and 1 or 0
  end
  return { top = edge(2), right = edge(4), bottom = edge(6), left = edge(8) }
end

---Border of a drawn window. Read from the window, since options passed to
---later calls may differ from those it was drawn with.
---@param win_id integer
---@return laser.BorderSides
function M.drawn(win_id)
  return M.sides(vim.api.nvim_win_get_config(win_id).border)
end

return M

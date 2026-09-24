---Menu decorations shared by the filters that compute them, the session
---that pads candidates, and the menu that draws them.
local M = {}

---Name of match highlights a converter stored; the menu then draws them
---instead of its own.
M.MATCH = "laser_match"
---Name of the highlight over text the menu shows before a candidate whose
---edit starts later than the menu.
M.PREFIX = "laser_prefix"

---Highlights over the characters of `text` at 0-based character `positions`.
---@param text string
---@param positions integer[]
---@param offset? integer bytes shown before `text` in the column
---@param name? string
---@return table[]
function M.matches(text, positions, offset, name)
  local highlights = {}
  for _, pos in ipairs(positions) do
    local first, last = vim.fn.byteidx(text, pos), vim.fn.byteidx(text, pos + 1)
    if first >= 0 and last > first then
      highlights[#highlights + 1] = {
        name = name,
        type = "abbr",
        col = (offset or 0) + first + 1,
        width = last - first,
        hl_group = "PmenuMatch",
      }
    end
  end
  return highlights
end

return M

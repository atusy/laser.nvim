local M = {}

---@alias laser.Matcher fun(prefix: string, candidate: table): number?
---@alias laser.Sorter fun(a: table, b: table): boolean

---@class laser.MatchOpts
---@field matcher? laser.Matcher
---@field sorter? laser.Sorter

---@param candidate table
---@return string
local function filter_text(candidate)
  local item = candidate.user_data.laser.item
  return item.filterText or item.label
end

---Fuzzy match against filterText (or label). Returns nil when it does not match.
---@type laser.Matcher
function M.fuzzy(prefix, candidate)
  if prefix == "" then
    return 0
  end
  local scores = vim.fn.matchfuzzypos({ filter_text(candidate) }, prefix)[3]
  return scores[1]
end

---@param candidates table[]
---@param prefix string
---@param opts laser.MatchOpts
---@return table[]
function M.apply(candidates, prefix, opts)
  local matcher = opts.matcher or M.fuzzy
  local matched = {}
  for _, candidate in ipairs(candidates) do
    local score = matcher(prefix, candidate)
    if score then
      candidate.score = score
      table.insert(matched, candidate)
    end
  end
  return matched
end

return M

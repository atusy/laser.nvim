local M = {}

---@alias laser.Matcher fun(prefix: string, candidate: table): number?
---@alias laser.Sorter fun(a: table, b: table): boolean

---@class laser.MatchOpts
---@field matcher? laser.Matcher
---@field sorter? laser.Sorter

---@param candidates table[]
---@param prefix string
---@param opts laser.MatchOpts
---@return table[]
function M.apply(candidates, prefix, opts)
  local _, _ = prefix, opts
  return candidates
end

return M

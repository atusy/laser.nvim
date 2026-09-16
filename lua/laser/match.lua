local M = {}

---@alias laser.Candidate table

---@class laser.MatchInfo
---@field score number

---@alias laser.Matcher
---| fun(input: string, candidate: laser.Candidate): false, nil
---| fun(input: string, candidate: laser.Candidate): true, laser.MatchInfo
---@alias laser.Converter fun(candidate: laser.Candidate): laser.Candidate
---@alias laser.LegacyMatcher fun(prefix: string, candidate: table): number?
---@alias laser.Sorter fun(a: table, b: table): boolean

---@class laser.MatcherFilter
---@field kind "matcher"
---@field callback laser.Matcher

---@class laser.SorterFilter
---@field kind "sorter"
---@field callback laser.Sorter

---@class laser.ConverterFilter
---@field kind "converter"
---@field callback laser.Converter

---@alias laser.Filter laser.MatcherFilter|laser.SorterFilter|laser.ConverterFilter

---@class laser.MatchOpts
---@field filters? laser.Filter[] Overrides matcher/sorter; an empty list preserves input order.
---@field matcher? laser.LegacyMatcher
---@field sorter? laser.Sorter

---@param candidate table
---@return string
local function filter_text(candidate)
  local item = candidate.user_data.laser.item
  return item.filterText or item.label
end

---Fuzzy match against filterText (or label). Returns false when it does not match.
---@param prefix string
---@param candidate laser.Candidate
---@return boolean matched
---@return laser.MatchInfo? info
function M.fuzzy(prefix, candidate)
  if prefix == "" then
    return true, { score = 0 }
  end
  local scores = vim.fn.matchfuzzypos({ filter_text(candidate) }, prefix)[3]
  if not scores[1] then
    return false, nil
  end
  return true, { score = scores[1] }
end

---@param candidate table
---@return string
local function sort_text(candidate)
  local item = candidate.user_data.laser.item
  return item.sortText or item.label
end

---Higher score first, then the server's sortText, then label.
---@param a laser.Candidate
---@param b laser.Candidate
---@return boolean
function M.by_score(a, b)
  local ai, bi = a.user_data.laser.match_info, b.user_data.laser.match_info
  local ascore, bscore = ai and ai.score or a.score or 0, bi and bi.score or b.score or 0
  if ascore ~= bscore then
    return ascore > bscore
  end
  local sa, sb = sort_text(a), sort_text(b)
  if sa ~= sb then
    return sa < sb
  end
  return a.abbr < b.abbr
end

---@param candidates table[]
---@param prefix string|fun(candidate: table): string
---@param opts laser.MatchOpts
---@return table[]
function M.apply(candidates, prefix, opts)
  local filters = opts.filters
  if filters == nil then
    local function matcher(input, candidate)
      local matched, info
      if opts.matcher and opts.matcher ~= M.fuzzy then
        local score = opts.matcher(input, candidate)
        matched, info = score ~= nil and score ~= false, { score = score }
      else
        matched, info = M.fuzzy(input, candidate)
      end
      candidate.score = info and info.score or nil -- Legacy sorter callbacks.
      return matched, matched and info or nil
    end
    filters = {
      { kind = "matcher", callback = matcher },
      { kind = "sorter", callback = opts.sorter or M.by_score },
    }
  end
  -- Each render starts from server candidates, never from a previous conversion.
  local current = vim.deepcopy(candidates)
  for _, filter in ipairs(filters) do
    if filter.kind == "sorter" then
      local ordered = {}
      for i, candidate in ipairs(current) do
        ordered[i] = { candidate = candidate, index = i }
      end
      table.sort(ordered, function(a, b)
        if filter.callback(a.candidate, b.candidate) then
          return true
        end
        if filter.callback(b.candidate, a.candidate) then
          return false
        end
        return a.index < b.index
      end)
      for i, entry in ipairs(ordered) do
        current[i] = entry.candidate
      end
    else
      local next_candidates = {}
      for _, candidate in ipairs(current) do
        if filter.kind == "matcher" then
          local input = type(prefix) == "function" and prefix(candidate) or prefix
          local matched, info = filter.callback(input, candidate)
          if matched then
            candidate.user_data.laser.match_info = info
            next_candidates[#next_candidates + 1] = candidate
          end
        elseif filter.kind == "converter" then
          next_candidates[#next_candidates + 1] = filter.callback(candidate)
        else
          error("Unknown filter kind: " .. tostring(filter.kind))
        end
      end
      current = next_candidates
    end
  end
  return current
end

return M

local M = {}

---@alias laser.Candidate table

---@class laser.MatchInfo
---@field score number
---@field positions? integer[] 0-based character indices into item.filterText or item.label

---@alias laser.Matcher
---| fun(input: string, candidate: laser.Candidate): false, nil
---| fun(input: string, candidate: laser.Candidate): true, laser.MatchInfo
---A converter owns the candidate, its user_data.laser, the LSP item's top-level
---fields and highlights for this render. Replace nested item tables instead of
---mutating them; they are shared with the cache.
---@alias laser.Converter fun(candidate: laser.Candidate, input: string): laser.Candidate
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

---@class laser.FilterOpts
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
local function fuzzy(prefix, candidate)
  if prefix == "" then
    return true, { score = 0 }
  end
  local result = vim.fn.matchfuzzypos({ filter_text(candidate) }, prefix)
  if not result[3][1] then
    return false, nil
  end
  return true, { score = result[3][1], positions = result[2][1] }
end

---Create a fuzzy matcher against filterText (or label).
---@return laser.Matcher
function M.fuzzy_matcher()
  return fuzzy
end

---Highlight matching characters in abbr using menu item decorations.
---@param candidate laser.Candidate
---@param input? string Candidate-specific input, used when abbr differs from the matched text.
---@return laser.Candidate
local function highlight(candidate, input)
  local info = candidate.user_data.laser.match_info
  local text = candidate.abbr or candidate.word
  local highlights = {}
  for _, hl in ipairs(candidate.highlights or {}) do
    if hl.name ~= "laser_match" then
      highlights[#highlights + 1] = hl
    end
  end
  local positions = info and text == filter_text(candidate) and info.positions or {}
  if info and info.positions and text ~= filter_text(candidate) and input and input ~= "" then
    positions = vim.fn.matchfuzzypos({ text }, input)[2][1] or {}
  end
  for _, pos in ipairs(positions) do
    local start = vim.fn.byteidx(text, pos)
    local finish = vim.fn.byteidx(text, pos + 1)
    highlights[#highlights + 1] = {
      name = "laser_match",
      type = "abbr",
      hl_group = "PmenuMatch",
      col = start + 1,
      width = finish - start,
    }
  end
  candidate.highlights = highlights
  return candidate
end

---Create a converter that highlights matched characters using PmenuMatch.
---The menu already highlights matches of the rows it draws; this stores them
---on every converted candidate instead, and the menu then leaves them as set.
---@return laser.Converter
function M.highlight_converter()
  return highlight
end

---Create a descending score comparator. Equal scores retain input order.
---@param opts? { tiebreak?: laser.Sorter } Called only when scores are equal.
---@return laser.Sorter
function M.score_sorter(opts)
  local tiebreak = opts and opts.tiebreak
  return function(a, b)
    local ai, bi = a.user_data.laser.match_info, b.user_data.laser.match_info
    local ascore, bscore = ai and ai.score or a.score or 0, bi and bi.score or b.score or 0
    if ascore ~= bscore then
      return ascore > bscore
    end
    return tiebreak ~= nil and tiebreak(a, b) or false
  end
end

---Order by the server's sortText, falling back to the label, as the LSP
---specifies for comparing items. Equal keys keep their order.
---@type laser.Sorter
function M.by_sort_text(a, b)
  local ai, bi = a.user_data.laser.item, b.user_data.laser.item
  local akey, bkey = ai.sortText or ai.label, bi.sortText or bi.label
  if akey ~= bkey then
    return akey < bkey
  end
  return ai.label < bi.label
end

---The default sorter: best match first, then the server's order.
M.by_score = M.score_sorter({ tiebreak = M.by_sort_text })

---@param opts laser.FilterOpts
---@return laser.Filter[]
local function resolve_filters(opts)
  local filters = opts.filters
  if filters == nil then
    local function matcher(input, candidate)
      local matched, info
      if opts.matcher and opts.matcher ~= fuzzy then
        local score = opts.matcher(input, candidate)
        matched, info = score ~= nil and score ~= false, { score = score }
      else
        matched, info = fuzzy(input, candidate)
      end
      candidate.score = info and info.score or nil -- Legacy sorter callbacks.
      return matched, matched and info or nil
    end
    filters = {
      { kind = "matcher", callback = matcher },
      { kind = "sorter", callback = opts.sorter or M.by_score },
    }
  end
  return filters
end

-- vim.tbl_extend validates its arguments, which is costly per candidate.
---@param t table
---@return table
local function shallow_copy(t)
  local copy = {}
  for k, v in pairs(t) do
    copy[k] = v
  end
  return copy
end

---Copy the parts filters may modify. Deep-copying whole LSP items (docs,
---edits, data) dominated filtering time on large lists; nested item fields
---are shared, so converters must replace them rather than mutate them.
---@param candidate table
---@return table
local function own(candidate)
  local copy = shallow_copy(candidate)
  copy.user_data = shallow_copy(candidate.user_data)
  local data = shallow_copy(candidate.user_data.laser)
  copy.user_data.laser = data
  data.item = shallow_copy(data.item)
  if candidate.highlights then
    copy.highlights = vim.deepcopy(candidate.highlights)
  end
  return copy
end

---Run one candidate through the matchers and converters, skipping sorters.
---@param candidate table owned copy
---@param input string
---@param filters laser.Filter[]
---@return table? candidate nil when a matcher rejects it
local function pass(candidate, input, filters)
  for _, filter in ipairs(filters) do
    if filter.kind == "matcher" then
      local matched, info = filter.callback(input, candidate)
      if not matched then
        return nil
      end
      candidate.user_data.laser.match_info = info
    elseif filter.kind == "converter" then
      candidate = filter.callback(candidate, input)
    elseif filter.kind ~= "sorter" then
      error("Unknown filter kind: " .. tostring(filter.kind))
    end
  end
  return candidate
end

---Whether any candidate survives the filters. Sorters cannot change the
---answer, so they are skipped, and the scan stops at the first survivor.
---@param candidates table[]
---@param prefix string|fun(candidate: table): string
---@param opts laser.FilterOpts
---@return boolean
function M.any(candidates, prefix, opts)
  local filters = resolve_filters(opts)
  for _, candidate in ipairs(candidates) do
    local input = type(prefix) == "function" and prefix(candidate) or prefix
    if pass(own(candidate), input, filters) then
      return true
    end
  end
  return false
end

---@param candidates table[]
---@param prefix string|fun(candidate: table): string
---@param opts laser.FilterOpts
---@param limit? integer keep at most this many candidates; nil or 0 keeps all
---@return table[]
function M.apply(candidates, prefix, opts, limit)
  local filters = resolve_filters(opts)
  -- Later converters are one-to-one, so the kept candidates are known once the
  -- last filter that can drop or reorder them has run.
  local truncate_after = 0
  if limit and limit > 0 then
    for i, filter in ipairs(filters) do
      if filter.kind ~= "converter" then
        truncate_after = i
      end
    end
  end
  if truncate_after == 0 and limit and limit > 0 then
    candidates = vim.list_slice(candidates, 1, limit)
  end
  -- Each render starts from server candidates, never from a previous conversion.
  local current = vim.tbl_map(own, candidates)
  for i, filter in ipairs(filters) do
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
          local input = type(prefix) == "function" and prefix(candidate) or prefix
          next_candidates[#next_candidates + 1] = filter.callback(candidate, input)
        else
          error("Unknown filter kind: " .. tostring(filter.kind))
        end
      end
      current = next_candidates
    end
    if i == truncate_after then
      current = vim.list_slice(current, 1, limit)
    end
  end
  return current
end

return M

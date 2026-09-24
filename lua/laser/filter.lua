local M = {}

---@alias laser.Candidate table

---@class laser.MatchInfo
---@field score number
---@field positions? integer[] 0-based character indices into item.filterText or item.label

---A matcher reads the cached candidate and must not modify it; converters
---own the copies that survive.
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
    local matcher = fuzzy
    local legacy = opts.matcher
    if legacy and legacy ~= fuzzy then
      matcher = function(input, candidate)
        local score = legacy(input, candidate)
        if score == nil or score == false then
          return false, nil
        end
        return true, { score = score }
      end
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
---Only converters may change the item, so it is shared when none runs.
---@param candidate table
---@param with_item boolean
---@return table
local function own(candidate, with_item)
  local copy = shallow_copy(candidate)
  copy.user_data = shallow_copy(candidate.user_data)
  local data = shallow_copy(candidate.user_data.laser)
  copy.user_data.laser = data
  if with_item then
    data.item = shallow_copy(data.item)
  end
  if candidate.highlights then
    copy.highlights = vim.deepcopy(candidate.highlights)
  end
  return copy
end

---Match every candidate with the built-in fuzzy matcher in one call per
---distinct input. Matching depends only on the text and the input, so
---candidates sharing both share the result.
---@param candidates table[]
---@param input_of fun(candidate: table): string
---@return table<integer, laser.MatchInfo> infos by candidate index; missing when unmatched
local function fuzzy_all(candidates, input_of)
  -- Per input: distinct texts in order, and the first candidate index of
  -- each text; candidates repeating a text are chained through `next_same`.
  local groups = {} ---@type table<string, { texts: string[], first: table<string, integer> }>
  local next_same, last_same = {}, {}
  for i, candidate in ipairs(candidates) do
    local input = input_of(candidate)
    local group = groups[input]
    if not group then
      group = { texts = {}, first = {} }
      groups[input] = group
    end
    local text = filter_text(candidate)
    local head = group.first[text]
    if head then
      next_same[last_same[head] or head] = i
      last_same[head] = i
    else
      group.first[text] = i
      group.texts[#group.texts + 1] = text
    end
  end
  local infos = {}
  for input, group in pairs(groups) do
    if input == "" then
      for _, head in pairs(group.first) do
        local i = head
        while i do
          infos[i] = { score = 0 }
          i = next_same[i]
        end
      end
    else
      local matched = vim.fn.matchfuzzypos(group.texts, input)
      local scores, positions = matched[3], matched[2]
      for n, text in ipairs(matched[1]) do
        local i = group.first[text]
        while i do
          infos[i] = { score = scores[n], positions = positions[n] }
          i = next_same[i]
        end
      end
    end
  end
  return infos
end

---Run a first matcher over the cached candidates, which it only reads.
---Converters own copies, so only its survivors need copying. Later
---matchers see its match info and run on the copies.
---@param candidates table[]
---@param input_of fun(candidate: table): string
---@param filters laser.Filter[]
---@param stop_at_first? boolean return as soon as one candidate survives
---@return table[] survivors
---@return laser.MatchInfo[] infos match info of each survivor
---@return integer next index of the first filter left to run
local function first_matcher(candidates, input_of, filters, stop_at_first)
  local filter = filters[1]
  if not filter or filter.kind ~= "matcher" then
    return candidates, {}, 1
  end
  local kept, infos = {}, {}
  if filter.callback == fuzzy then
    local matched = fuzzy_all(candidates, input_of)
    for i, candidate in ipairs(candidates) do
      if matched[i] then
        kept[#kept + 1], infos[#kept + 1] = candidate, matched[i]
      end
    end
    return kept, infos, 2
  end
  for _, candidate in ipairs(candidates) do
    local ok, info = filter.callback(input_of(candidate), candidate)
    if ok then
      kept[#kept + 1], infos[#kept + 1] = candidate, info
      if stop_at_first then
        break
      end
    end
  end
  return kept, infos, 2
end

---@param candidate table cached candidate
---@param info? laser.MatchInfo
---@param with_item boolean whether converters will run on the copy
---@return table
local function own_matched(candidate, info, with_item)
  local copy = own(candidate, with_item)
  if info then
    copy.user_data.laser.match_info = info
    copy.score = info.score -- Legacy sorter callbacks.
  end
  return copy
end

---Run one candidate through the matchers and converters, skipping sorters.
---@param candidate table owned copy
---@param input string
---@param filters laser.Filter[]
---@param first integer index of the first filter to run
---@return table? candidate nil when a matcher rejects it
local function pass(candidate, input, filters, first)
  for index = first, #filters do
    local filter = filters[index]
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

---@param prefix string|fun(candidate: table): string
---@return fun(candidate: table): string
local function input_getter(prefix)
  if type(prefix) == "function" then
    return prefix
  end
  return function()
    return prefix
  end
end

---Whether any candidate survives the filters. Sorters cannot change the
---answer, so they are skipped, and the scan stops at the first survivor.
---@param candidates table[]
---@param prefix string|fun(candidate: table): string
---@param opts laser.FilterOpts
---@return boolean
function M.any(candidates, prefix, opts)
  local filters = resolve_filters(opts)
  local input_of = input_getter(prefix)
  local rest = false
  for index = 2, #filters do
    if filters[index].kind == "matcher" then
      rest = true
    end
  end
  local survivors, infos, first = first_matcher(candidates, input_of, filters, not rest)
  if not rest then
    -- Converters are one-to-one; they cannot drop a survivor.
    return #survivors > 0
  end
  for i, candidate in ipairs(survivors) do
    if pass(own_matched(candidate, infos[i], true), input_of(candidate), filters, first) then
      return true
    end
  end
  return false
end

---The default sorter's order with its keys computed once per candidate.
---@param current table[]
local function sort_by_score(current)
  local keyed = {}
  for i, candidate in ipairs(current) do
    local info, item = candidate.user_data.laser.match_info, candidate.user_data.laser.item
    keyed[i] = {
      candidate = candidate,
      score = info and info.score or candidate.score or 0,
      key = item.sortText or item.label,
      label = item.label,
      index = i,
    }
  end
  table.sort(keyed, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    elseif a.key ~= b.key then
      return a.key < b.key
    elseif a.label ~= b.label then
      return a.label < b.label
    end
    return a.index < b.index
  end)
  for i, entry in ipairs(keyed) do
    current[i] = entry.candidate
  end
end

---Sort stably with a user comparator, which may be inconsistent.
---@param current table[]
---@param callback laser.Sorter
local function sort_with(current, callback)
  local ordered = {}
  for i, candidate in ipairs(current) do
    ordered[i] = { candidate = candidate, index = i }
  end
  table.sort(ordered, function(a, b)
    if callback(a.candidate, b.candidate) then
      return true
    end
    if callback(b.candidate, a.candidate) then
      return false
    end
    return a.index < b.index
  end)
  for i, entry in ipairs(ordered) do
    current[i] = entry.candidate
  end
end

---@param candidates table[]
---@param prefix string|fun(candidate: table): string
---@param opts laser.FilterOpts
---@param limit? integer keep at most this many candidates; nil or 0 keeps all
---@return table[]
function M.apply(candidates, prefix, opts, limit)
  local filters = resolve_filters(opts)
  local input_of = input_getter(prefix)
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
  local survivors, infos, first = first_matcher(candidates, input_of, filters)
  if truncate_after == 1 and first == 2 then
    survivors = vim.list_slice(survivors, 1, limit)
  end
  -- Each render starts from server candidates, never from a previous conversion.
  local converts = false
  for i = first, #filters do
    converts = converts or filters[i].kind == "converter"
  end
  local current = {}
  for i, candidate in ipairs(survivors) do
    current[i] = own_matched(candidate, infos[i], converts)
  end
  for i = first, #filters do
    local filter = filters[i]
    if filter.kind == "sorter" then
      if filter.callback == M.by_score then
        sort_by_score(current)
      else
        sort_with(current, filter.callback)
      end
    else
      local next_candidates = {}
      for _, candidate in ipairs(current) do
        if filter.kind == "matcher" then
          local matched, info = filter.callback(input_of(candidate), candidate)
          if matched then
            candidate.user_data.laser.match_info = info
            next_candidates[#next_candidates + 1] = candidate
          end
        elseif filter.kind == "converter" then
          next_candidates[#next_candidates + 1] = filter.callback(candidate, input_of(candidate))
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

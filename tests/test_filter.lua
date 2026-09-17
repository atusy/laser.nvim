local MiniTest = require("mini.test")
local expect = MiniTest.expect
local T = MiniTest.new_set()

local filter = require("laser.filter")

local function cand(label, extra)
  local item = vim.tbl_extend("force", { label = label }, extra or {})
  return { word = label, abbr = label, user_data = { laser = { client_id = 1, item = item } } }
end

local function labels(list)
  return vim.tbl_map(function(c)
    return c.abbr
  end, list)
end

T["an empty prefix preserves input order regardless of sortText"] = function()
  local got = filter.apply(
    { cand("zeta"), cand("alpha", { sortText = "zzz" }), cand("mid") },
    "",
    {}
  )
  expect.equality(labels(got), { "zeta", "alpha", "mid" })
end

T["the default matcher drops candidates that do not fuzzy-match the prefix"] = function()
  local got = filter.apply({ cand("bar"), cand("qux"), cand("baz") }, "ba", {})
  expect.equality(labels(got), { "bar", "baz" })
end

T["fuzzy exposes character positions in filterText"] = function()
  local matched, info = filter.fuzzy("日語", cand("other", { filterText = "日本語" }))
  expect.equality(matched, true)
  expect.equality(info.positions, { 0, 2 })
end

T["the default sorter ranks by score and preserves input order on ties"] = function()
  local scores = { b = 1, a = 1, c = 1, d = 2 }
  local matcher = function(_, candidate)
    return scores[candidate.abbr]
  end
  local got = filter.apply({
    cand("b", { sortText = "9" }),
    cand("a", { sortText = "9" }),
    cand("c", { sortText = "0" }),
    cand("d"),
  }, "x", { matcher = matcher })
  expect.equality(labels(got), { "d", "b", "a", "c" })
end

T["filters run in order and expose match info to later stages"] = function()
  local got = filter.apply({ cand("b"), cand("a") }, "x", {
    filters = {
      {
        kind = "converter",
        callback = function(candidate)
          candidate.abbr = candidate.abbr .. "!"
          return candidate
        end,
      },
      {
        kind = "matcher",
        callback = function(input, candidate)
          expect.equality(input, "x")
          return true, { score = candidate.abbr == "b!" and 2 or 1 }
        end,
      },
      {
        kind = "sorter",
        callback = function(a, b)
          return a.user_data.laser.match_info.score > b.user_data.laser.match_info.score
        end,
      },
      {
        kind = "converter",
        callback = function(candidate)
          candidate.menu = tostring(candidate.user_data.laser.match_info.score)
          return candidate
        end,
      },
    },
  })
  expect.equality(labels(got), { "b!", "a!" })
  expect.equality({ got[1].menu, got[2].menu }, { "2", "1" })
end

T["equal sort keys retain the preceding filter order"] = function()
  local input = {}
  for i = 1, 20 do
    input[i] = cand(tostring(i))
  end
  local got = filter.apply(input, "", {
    filters = {
      {
        kind = "sorter",
        callback = function()
          return false
        end,
      },
    },
  })
  expect.equality(labels(got), labels(input))
end

T["later matchers replace info and rejected candidates never reach later filters"] = function()
  local first = { score = 10 }
  local second = { score = 0 }
  local seen = {}
  local got = filter.apply({ cand("early"), cand("late"), cand("keep") }, "", {
    filters = {
      {
        kind = "matcher",
        callback = function(_, candidate)
          if candidate.abbr == "early" then
            return false, nil
          end
          return true, first
        end,
      },
      {
        kind = "matcher",
        callback = function(_, candidate)
          seen[#seen + 1] = candidate.abbr
          expect.equality(candidate.user_data.laser.match_info == first, true)
          if candidate.abbr == "late" then
            return false, nil
          end
          return true, second
        end,
      },
      {
        kind = "converter",
        callback = function(candidate)
          expect.equality(candidate.abbr, "keep")
          expect.equality(candidate.user_data.laser.match_info == second, true)
          return candidate
        end,
      },
    },
  })
  expect.equality(seen, { "late", "keep" })
  expect.equality(labels(got), { "keep" })
end

T["conversions and match info do not accumulate across renders"] = function()
  local input = { cand("a") }
  input[1].user_data.laser.id = 42
  input[1].user_data.laser.startcol = 3
  local original = vim.deepcopy(input)
  local opts = {
    filters = {
      {
        kind = "converter",
        callback = function(candidate)
          expect.equality(candidate.user_data.laser.match_info, nil)
          candidate.abbr = candidate.abbr .. "!"
          candidate.user_data.laser.item.filterText = "changed"
          return candidate
        end,
      },
      {
        kind = "matcher",
        callback = function()
          return true, { score = 2 }
        end,
      },
    },
  }
  local first = filter.apply(input, "", opts)
  local second = filter.apply(input, "", opts)
  expect.equality(first, second)
  expect.equality(input, original)
  expect.equality(first[1].user_data.laser.id, 42)
  expect.equality(first[1].user_data.laser.startcol, 3)
end

T["empty filters override legacy options and preserve input order"] = function()
  local got = filter.apply({ cand("z"), cand("a") }, "no match", {
    filters = {},
    matcher = function()
      error("legacy matcher must not run")
    end,
    sorter = function()
      error("legacy sorter must not run")
    end,
  })
  expect.equality(labels(got), { "z", "a" })
  expect.equality(got[1].user_data.laser.match_info, nil)
end

T["the built-in sorter works before any matcher"] = function()
  local got = filter.apply({ cand("z"), cand("a") }, "", {
    filters = {
      { kind = "sorter", callback = filter.by_score },
      { kind = "matcher", callback = filter.fuzzy },
    },
  })
  expect.equality(labels(got), { "z", "a" })
  expect.equality(got[1].user_data.laser.match_info, { score = 0 })
end

T["legacy sorters still receive the default match score"] = function()
  local got = filter.apply({ cand("abc"), cand("axbyc") }, "abc", {
    sorter = function(a, b)
      expect.equality(type(a.score), "number")
      expect.equality(type(b.score), "number")
      return a.score > b.score
    end,
  })
  expect.equality(labels(got), { "abc", "axbyc" })
end

T["highlight converts match positions into byte ranges without replacing other decorations"] = function()
  local item = cand("日本語")
  local decoration = { name = "kind", type = "kind", hl_group = "Type", col = 1, width = 1 }
  item.highlights = { decoration }
  local got = filter.apply({ item }, "日語", {
    filters = {
      { kind = "matcher", callback = filter.fuzzy },
      {
        kind = "converter",
        callback = function(candidate)
          return filter.highlight(candidate)
        end,
      },
    },
  })
  expect.equality(got[1].highlights, {
    decoration,
    { name = "laser_match", type = "abbr", hl_group = "PmenuMatch", col = 1, width = 3 },
    { name = "laser_match", type = "abbr", hl_group = "PmenuMatch", col = 7, width = 3 },
  })
end

T["highlight rematches a different abbr using each candidate's input"] = function()
  local got = filter.apply(
    { cand("a日本語", { filterText = "日本語" }), cand("xyz") },
    function(c)
      return c.abbr == "xyz" and "xz" or "日語"
    end,
    {
      filters = {
        { kind = "matcher", callback = filter.fuzzy },
        {
          kind = "converter",
          callback = function(candidate, input)
            return filter.highlight(candidate, input)
          end,
        },
      },
    }
  )
  expect.equality(got[1].highlights, {
    { name = "laser_match", type = "abbr", hl_group = "PmenuMatch", col = 2, width = 3 },
    { name = "laser_match", type = "abbr", hl_group = "PmenuMatch", col = 8, width = 3 },
  })
  expect.equality(got[2].highlights[2].col, 3)
end

T["highlight clears only its own decorations when positions are absent or display does not match"] = function()
  for _, case in ipairs({
    { input = "", label = "abc" },
    { input = "z", label = "abc", filterText = "xyz" },
  }) do
    local got = filter.apply({ cand(case.label, { filterText = case.filterText }) }, case.input, {
      filters = {
        { kind = "matcher", callback = filter.fuzzy },
        { kind = "converter", callback = filter.highlight },
      },
    })
    expect.equality(got[1].highlights, {})
  end
  local item = cand("abc")
  item.user_data.laser.match_info = { score = 1, positions = { 0 } }
  filter.highlight(item, "a")
  expect.equality(#item.highlights, 1)
  filter.highlight(item, "a")
  expect.equality(#item.highlights, 1)
  local decoration = { name = "other", type = "kind", hl_group = "Type", col = 1, width = 1 }
  item.highlights[#item.highlights + 1] = decoration
  item.user_data.laser.match_info = { score = 1 }
  filter.highlight(item, "a")
  expect.equality(item.highlights, { decoration })
  item.user_data.laser.match_info = nil
  filter.highlight(item, "a")
  expect.equality(item.highlights, { decoration })
end

T["score_sorter keeps input order for equal scores despite different labels and sortText"] = function()
  local got = filter.apply(
    {
      cand("weak", { filterText = "axb" }),
      cand("zeta", { filterText = "ab", sortText = "9" }),
      cand("alpha", { filterText = "ab", sortText = "0" }),
    },
    "ab",
    {
      filters = {
        { kind = "matcher", callback = filter.fuzzy },
        { kind = "sorter", callback = filter.score_sorter() },
      },
    }
  )
  expect.equality(labels(got), { "zeta", "alpha", "weak" })
end

T["score_sorter invokes the custom tiebreak only for equal scores"] = function()
  local called = false
  local sorter = filter.score_sorter({
    tiebreak = function(a, b)
      called = true
      expect.equality(a.user_data.laser.match_info.score, b.user_data.laser.match_info.score)
      return a.abbr < b.abbr
    end,
  })
  local got = filter.apply(
    {
      cand("weak", { filterText = "axb" }),
      cand("zeta", { filterText = "ab" }),
      cand("alpha", { filterText = "ab" }),
    },
    "ab",
    {
      filters = {
        { kind = "matcher", callback = filter.fuzzy },
        { kind = "sorter", callback = sorter },
      },
    }
  )
  expect.equality(labels(got), { "alpha", "zeta", "weak" })
  expect.equality(called, true)
end

return T

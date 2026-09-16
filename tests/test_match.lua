local MiniTest = require("mini.test")
local expect = MiniTest.expect
local T = MiniTest.new_set()

local match = require("laser.match")

local function cand(label, extra)
  local item = vim.tbl_extend("force", { label = label }, extra or {})
  return { word = label, abbr = label, user_data = { laser = { client_id = 1, item = item } } }
end

local function labels(list)
  return vim.tbl_map(function(c)
    return c.abbr
  end, list)
end

T["an empty prefix keeps every candidate, ordered as the server asked"] = function()
  -- LSP: when sortText is omitted the label is used for sorting.
  local got = match.apply(
    { cand("zeta"), cand("alpha", { sortText = "zzz" }), cand("mid") },
    "",
    {}
  )
  expect.equality(labels(got), { "mid", "zeta", "alpha" })
end

T["the default matcher drops candidates that do not fuzzy-match the prefix"] = function()
  local got = match.apply({ cand("bar"), cand("qux"), cand("baz") }, "ba", {})
  expect.equality(labels(got), { "bar", "baz" })
end

T["the default sorter ranks by score, then sortText, then label"] = function()
  local scores = { b = 1, a = 1, c = 1, d = 2 }
  local matcher = function(_, candidate)
    return scores[candidate.abbr]
  end
  local got = match.apply({
    cand("b", { sortText = "9" }),
    cand("a", { sortText = "9" }),
    cand("c", { sortText = "0" }),
    cand("d"),
  }, "x", { matcher = matcher })
  expect.equality(labels(got), { "d", "c", "a", "b" })
end

T["filters run in order and expose match info to later stages"] = function()
  local got = match.apply({ cand("b"), cand("a") }, "x", {
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
  local got = match.apply(input, "", {
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
  local got = match.apply({ cand("early"), cand("late"), cand("keep") }, "", {
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
  local first = match.apply(input, "", opts)
  local second = match.apply(input, "", opts)
  expect.equality(first, second)
  expect.equality(input, original)
  expect.equality(first[1].user_data.laser.id, 42)
  expect.equality(first[1].user_data.laser.startcol, 3)
end

T["empty filters override legacy options and preserve input order"] = function()
  local got = match.apply({ cand("z"), cand("a") }, "no match", {
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
  local got = match.apply({ cand("z"), cand("a") }, "", {
    filters = {
      { kind = "sorter", callback = match.by_score },
      { kind = "matcher", callback = match.fuzzy },
    },
  })
  expect.equality(labels(got), { "a", "z" })
  expect.equality(got[1].user_data.laser.match_info, { score = 0 })
end

T["legacy sorters still receive the default match score"] = function()
  local got = match.apply({ cand("abc"), cand("axbyc") }, "abc", {
    sorter = function(a, b)
      expect.equality(type(a.score), "number")
      expect.equality(type(b.score), "number")
      return a.score > b.score
    end,
  })
  expect.equality(labels(got), { "abc", "axbyc" })
end

return T

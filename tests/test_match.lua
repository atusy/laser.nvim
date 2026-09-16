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

return T

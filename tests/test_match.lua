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

T["an empty prefix keeps every candidate in its original order"] = function()
  local got = match.apply({ cand("zeta"), cand("alpha") }, "", {})
  expect.equality(labels(got), { "zeta", "alpha" })
end

return T

local MiniTest = require("mini.test")
local expect = MiniTest.expect
local T = MiniTest.new_set()

local position = require("laser.position")

T["params encode the byte column in the client's offset encoding"] = function()
  -- "é" is 2 bytes in UTF-8 and 1 unit in UTF-16.
  local got = position.params("file:///x", 3, "é.ba", 4, "utf-16")
  expect.equality(got, {
    textDocument = { uri = "file:///x" },
    position = { line = 3, character = 3 },
  })
end

T["the keyword start is the byte column where the current \\k* run begins"] = function()
  expect.equality(position.keyword_start("foo.ba", 6), 4)
  expect.equality(position.keyword_start("foo.", 4), 4)
  expect.equality(position.keyword_start("", 0), 0)
end

T["the keyword start follows the completed document's iskeyword"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].iskeyword = "@,48-57,_,-"
  expect.equality(position.keyword_start("a-b", 3), 2)
  expect.equality(position.keyword_start("a-b", 3, buf), 0)
  vim.api.nvim_buf_delete(buf, { force = true })
end

return T

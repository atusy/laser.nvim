local MiniTest = require("mini.test")
local expect = MiniTest.expect
local T = MiniTest.new_set()

local confirm = require("laser.confirm")

local function client(overrides)
  return vim.tbl_extend("force", {
    id = 1,
    offset_encoding = "utf-8",
    server_capabilities = { completionProvider = {} },
    commands = {},
    exec_cmd = function() end,
    request = function() end,
  }, overrides or {})
end

---Buffer whose line already contains the inserted word, cursor after it.
local function buffer_after_insert(line, col)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
  vim.api.nvim_win_set_cursor(0, { 1, col })
  return buf
end

local function candidate(item, word)
  return { word = word or item.label, user_data = { laser = { client_id = 1, item = item } } }
end

T["additionalTextEdits are applied and the inserted word stays"] = function()
  local buf = buffer_after_insert("foo.bar", 7)
  local item = {
    label = "bar",
    additionalTextEdits = {
      {
        newText = "import bar\n",
        range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
      },
    },
  }
  confirm.apply(candidate(item), { bufnr = buf, startcol = 4, client = client() })
  expect.equality(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "import bar", "foo.bar" })
end

return T

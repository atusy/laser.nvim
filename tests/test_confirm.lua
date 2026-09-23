local MiniTest = require("mini.test")
local expect = MiniTest.expect
-- Headless tests cannot sit in Insert mode; 'virtualedit=onemore' lets the
-- cursor rest after the last character the way it does after the menu inserts.
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      vim.o.virtualedit = "onemore"
    end,
    post_case = function()
      vim.o.virtualedit = ""
    end,
  },
})

local confirm = require("laser.confirm")

local function client(overrides)
  return vim.tbl_extend("force", {
    id = 1,
    offset_encoding = "utf-8",
    server_capabilities = { completionProvider = {} },
    commands = {},
    supports_method = function(self)
      return self.server_capabilities.completionProvider.resolveProvider == true
    end,
    exec_cmd = function() end,
    request = function() end,
  }, overrides or {})
end

---Buffer whose line already contains the inserted word, cursor after it,
---as it is when the menu reports a confirm.
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

T["a snippet item replaces the inserted word with the expanded snippet"] = function()
  local buf = buffer_after_insert("foo.bar", 7)
  local item = { label = "bar", insertText = "bar($1)$0", insertTextFormat = 2 }
  confirm.apply(candidate(item), { bufnr = buf, startcol = 4, client = client() })
  expect.equality(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "foo.bar()" })
  expect.equality(vim.api.nvim_win_get_cursor(0), { 1, 8 })
end

T["the item's command is executed through the client"] = function()
  local buf = buffer_after_insert("foo.bar", 7)
  local executed = {}
  local c = client({
    exec_cmd = function(_, cmd)
      table.insert(executed, cmd.command)
    end,
  })
  local item =
    { label = "bar", command = { title = "t", command = "editor.action.triggerSuggest" } }
  confirm.apply(candidate(item), { bufnr = buf, startcol = 4, client = c })
  expect.equality(executed, { "editor.action.triggerSuggest" })
end

T["an unresolved item is resolved first so late edits and commands apply"] = function()
  local buf = buffer_after_insert("foo.bar", 7)
  local executed = {}
  local c = client({
    server_capabilities = { completionProvider = { resolveProvider = true } },
    exec_cmd = function(_, cmd)
      table.insert(executed, cmd.command)
    end,
    request = function(_, method, params, handler)
      expect.equality(method, "completionItem/resolve")
      local resolved = vim.deepcopy(params)
      resolved.additionalTextEdits = {
        {
          newText = "import bar\n",
          range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
        },
      }
      resolved.command = { title = "t", command = "resolved.cmd" }
      handler(nil, resolved)
      return true, 1
    end,
  })
  confirm.apply(candidate({ label = "bar" }), { bufnr = buf, startcol = 4, client = c })
  expect.equality(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "import bar", "foo.bar" })
  expect.equality(executed, { "resolved.cmd" })
end

T["resolve honors dynamic registration for the completion buffer"] = function()
  local fake = require("tests.helpers.fake_server")
  local buf = buffer_after_insert("foo.bar", 7)
  vim.bo[buf].filetype = "lua"
  local c = fake.start({}, buf)
  c.server_capabilities.completionProvider = nil
  c.capabilities.textDocument.completion.dynamicRegistration = true
  c.dynamic_capabilities:register({
    {
      id = "resolve",
      method = "textDocument/completion",
      registerOptions = {
        documentSelector = { { language = "lua" } },
        resolveProvider = true,
      },
    },
  })
  -- Keep the current buffer different from the completion document.
  vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(false, true))
  local requested = false
  c.request = function(_, method)
    requested = method == "completionItem/resolve"
    return true, 1
  end
  confirm.apply(candidate({ label = "bar" }), { bufnr = buf, startcol = 4, client = c })
  fake.stop_all()
  expect.equality(requested, true)
end

return T

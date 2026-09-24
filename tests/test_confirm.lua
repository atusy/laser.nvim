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
      -- Expanding a snippet starts Insert mode; keep it from leaking.
      vim.snippet.stop()
      vim.cmd.stopinsert()
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
    cancel_request = function() end,
  }, overrides or {})
end

---Buffer holding what the menu left there, with the cursor after it.
local function buffer(lines, row, col)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, { row, col })
  return buf
end

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---@param item lsp.CompletionItem
---@param request { line: string, col: integer, line_nr?: integer } the line when requested
---@param startcol integer the item's own edit start
local function candidate(item, request, startcol)
  request.line_nr = request.line_nr or 0
  return {
    word = item.label,
    user_data = { laser = { client_id = 1, item = item, request = request, startcol = startcol } },
  }
end

-- "foo.b" was typed and the menu inserted "bar" in place of "b".
local function typed_bar()
  return buffer({ "foo.bar" }, 1, 7), { line = "foo.b", col = 5 }
end

T["an item without an edit replaces the typed word"] = function()
  local buf, request = typed_bar()
  confirm.apply(candidate({ label = "bar" }, request, 4), { bufnr = buf, client = client() })
  expect.equality(lines(buf), { "foo.bar" })
  expect.equality(vim.api.nvim_win_get_cursor(0), { 1, 7 })
end

T["the text after the cursor that the edit covers is replaced"] = function()
  -- jsonls-style: `{"na|"}` with an edit spanning both quotes.
  local buf = buffer({ '{"name""}' }, 1, 7)
  local item = {
    label = "name",
    textEdit = {
      newText = '"name"',
      range = { start = { line = 0, character = 1 }, ["end"] = { line = 0, character = 5 } },
    },
  }
  confirm.apply(
    candidate(item, { line = '{"na"}', col = 4 }, 1),
    { bufnr = buf, client = client() }
  )
  expect.equality(lines(buf), { '{"name"}' })
  expect.equality(vim.api.nvim_win_get_cursor(0), { 1, 7 })
end

T["an edit reaching past the cursor replaces the rest of the word"] = function()
  -- The cursor was after the first "f" of "ffx)".
  local buf = buffer({ "foobarfx)" }, 1, 6)
  local item = {
    label = "foobar",
    textEdit = {
      newText = "foobar",
      range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 3 } },
    },
  }
  confirm.apply(candidate(item, { line = "ffx)", col = 1 }, 0), { bufnr = buf, client = client() })
  expect.equality(lines(buf), { "foobar)" })
end

T["the text the menu shows for another candidate is replaced as well"] = function()
  -- "baz" was the last inserted candidate; "bar" is confirmed without typing.
  local buf = buffer({ "foo.baz" }, 1, 7)
  local request = { line = "foo.b", col = 5 }
  confirm.apply(candidate({ label = "bar" }, request, 4), { bufnr = buf, client = client() })
  expect.equality(lines(buf), { "foo.bar" })
end

T["symbols typed before an item's start are not inserted again"] = function()
  -- "@pr" was typed; the item starts after "@" and its text repeats it.
  local buf = buffer({ "@pr" }, 1, 3)
  local c = candidate(
    { label = "property", insertText = "@property" },
    { line = "@pr", col = 3 },
    1
  )
  c.user_data.laser.word = "property"
  confirm.apply(c, { bufnr = buf, client = client() })
  expect.equality(lines(buf), { "@property" })
end

T["multi-line text is inserted as is, without automatic indentation"] = function()
  local buf = buffer({ "  b" }, 1, 3)
  vim.bo[buf].autoindent = true
  vim.bo[buf].comments = "://"
  vim.bo[buf].formatoptions = "rot"
  local item = { label = "bar", insertText = "bar(\n  a\n)" }
  confirm.apply(candidate(item, { line = "  b", col = 3 }, 2), { bufnr = buf, client = client() })
  expect.equality(lines(buf), { "  bar(", "  a", ")" })
  expect.equality(vim.api.nvim_win_get_cursor(0), { 3, 1 })
end

T["adjustIndentation indents following lines like the first"] = function()
  local buf = buffer({ "  b" }, 1, 3)
  local item = { label = "bar", insertText = "bar(\n  a\n)", insertTextMode = 2 }
  confirm.apply(candidate(item, { line = "  b", col = 3 }, 2), { bufnr = buf, client = client() })
  expect.equality(lines(buf), { "  bar(", "    a", "  )" })
end

T["additionalTextEdits are applied with the item's edit"] = function()
  local buf, request = typed_bar()
  local item = {
    label = "bar",
    additionalTextEdits = {
      {
        newText = "import bar\n",
        range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
      },
    },
  }
  confirm.apply(candidate(item, request, 4), { bufnr = buf, client = client() })
  expect.equality(lines(buf), { "import bar", "foo.bar" })
  expect.equality(vim.api.nvim_win_get_cursor(0), { 2, 7 })
end

T["a snippet item replaces the typed word with the expanded snippet"] = function()
  local buf, request = typed_bar()
  local item = { label = "bar", insertText = "bar($1)$0", insertTextFormat = 2 }
  confirm.apply(candidate(item, request, 4), { bufnr = buf, client = client() })
  expect.equality(lines(buf), { "foo.bar()" })
  expect.equality(vim.api.nvim_win_get_cursor(0), { 1, 8 })
end

T["a snippet whose range starts on another line applies there"] = function()
  local buf = buffer({ "x", "foo.bar" }, 2, 7)
  local item = {
    label = "bar",
    insertTextFormat = 2,
    textEdit = {
      newText = "bar($1)",
      range = { start = { line = 0, character = 1 }, ["end"] = { line = 1, character = 5 } },
    },
  }
  confirm.apply(
    candidate(item, { line = "foo.b", col = 5, line_nr = 1 }, 4),
    { bufnr = buf, client = client() }
  )
  expect.equality(lines(buf), { "xbar()" })
end

T["additionalTextEdits below a multi-line snippet stay on their line"] = function()
  local buf = buffer({ "b", "tail" }, 1, 1)
  local item = {
    label = "bar",
    insertText = "bar(\n\t$1\n)",
    insertTextFormat = 2,
    additionalTextEdits = {
      {
        newText = "X",
        range = { start = { line = 1, character = 0 }, ["end"] = { line = 1, character = 0 } },
      },
    },
  }
  confirm.apply(candidate(item, { line = "b", col = 1 }, 0), { bufnr = buf, client = client() })
  expect.equality(lines(buf), { "bar(", "\t", ")", "Xtail" })
end

T["the item's command is executed through the client"] = function()
  local buf, request = typed_bar()
  local executed = {}
  local c = client({
    exec_cmd = function(_, cmd)
      table.insert(executed, cmd.command)
    end,
  })
  local item =
    { label = "bar", command = { title = "t", command = "editor.action.triggerSuggest" } }
  confirm.apply(candidate(item, request, 4), { bufnr = buf, client = c })
  expect.equality(executed, { "editor.action.triggerSuggest" })
end

---Client whose resolve answers `resolved(item)` after `delay` ms, or never.
local function resolving_client(resolved, executed, delay)
  return client({
    server_capabilities = { completionProvider = { resolveProvider = true } },
    exec_cmd = function(_, cmd)
      table.insert(executed, cmd.command)
    end,
    request = function(_, method, params, handler)
      expect.equality(method, "completionItem/resolve")
      if delay then
        vim.defer_fn(function()
          handler(nil, resolved(vim.deepcopy(params)))
        end, delay)
      end
      return true, 1
    end,
  })
end

T["an unresolved item is resolved before its edits are applied"] = function()
  local buf, request = typed_bar()
  local executed = {}
  local c = resolving_client(function(item)
    item.additionalTextEdits = {
      {
        newText = "import bar\n",
        range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
      },
    }
    item.command = { title = "t", command = "resolved.cmd" }
    return item
  end, executed, 10)
  confirm.apply(candidate({ label = "bar" }, request, 4), { bufnr = buf, client = c })
  -- Nothing is left to arrive after the confirmation.
  expect.equality(lines(buf), { "import bar", "foo.bar" })
  expect.equality(executed, { "resolved.cmd" })
end

T["an item that carries its additionalTextEdits is not resolved"] = function()
  local buf, request = typed_bar()
  local c = resolving_client(function(item)
    return item
  end, {}, 0)
  c.request = function()
    error("resolve must not be requested")
  end
  local item = {
    label = "bar",
    additionalTextEdits = {
      {
        newText = "x",
        range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
      },
    },
  }
  confirm.apply(candidate(item, request, 4), { bufnr = buf, client = c })
  expect.equality(lines(buf), { "xfoo.bar" })
end

T["a failed resolve is reported and the item applies as it is"] = function()
  local buf, request = typed_bar()
  local executed, notified = {}, {}
  local c = resolving_client(function(item)
    return item
  end, executed, nil)
  c.request = function(_, _, _, handler)
    handler({ code = -32603, message = "resolve failed" }, nil)
    return true, 1
  end
  local notify_once = vim.notify_once
  vim.notify_once = function(message)
    table.insert(notified, message)
  end
  local item = { label = "bar", command = { title = "t", command = "own.cmd" } }
  local ok, err = pcall(confirm.apply, candidate(item, request, 4), { bufnr = buf, client = c })
  vim.notify_once = notify_once
  assert(ok, err)
  expect.equality(notified, { "resolve failed" })
  expect.equality(lines(buf), { "foo.bar" })
  expect.equality(executed, { "own.cmd" })
end

T["a resolve that does not answer in time is cancelled"] = function()
  local buf, request = typed_bar()
  local executed, cancelled = {}, {}
  local c = resolving_client(function(item)
    return item
  end, executed, nil)
  c.cancel_request = function(_, id)
    table.insert(cancelled, id)
  end
  local item = { label = "bar", command = { title = "t", command = "own.cmd" } }
  confirm.apply(candidate(item, request, 4), { bufnr = buf, client = c, resolve_timeout_ms = 20 })
  expect.equality(lines(buf), { "foo.bar" })
  expect.equality(cancelled, { 1 })
  expect.equality(executed, { "own.cmd" })
end

T["a resolved item with JSON null fields keeps the item's own command"] = function()
  local buf, request = typed_bar()
  local executed = {}
  local c = resolving_client(function(item)
    item.additionalTextEdits = vim.NIL
    item.command = vim.NIL
    return item
  end, executed, 0)
  local item = { label = "bar", command = { title = "t", command = "own.cmd" } }
  confirm.apply(candidate(item, request, 4), { bufnr = buf, client = c })
  expect.equality(lines(buf), { "foo.bar" })
  expect.equality(executed, { "own.cmd" })
end

T["resolve honors dynamic registration for the completion buffer"] = function()
  local fake = require("tests.helpers.fake_server")
  local buf, request = typed_bar()
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
  c.cancel_request = function() end
  confirm.apply(
    candidate({ label = "bar" }, request, 4),
    { bufnr = buf, client = c, resolve_timeout_ms = 1 }
  )
  fake.stop_all()
  expect.equality(requested, true)
end

return T

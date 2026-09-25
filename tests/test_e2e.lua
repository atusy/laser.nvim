local MiniTest = require("mini.test")
local expect = MiniTest.expect

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "scripts/minimal_init.lua" })
      child.bo.readonly = false
      child.lua([[
        FAKE = require("tests.helpers.fake_server")
        vim.api.nvim_create_autocmd({ "InsertEnter", "TextChangedI" }, {
          callback = function() require("laser").complete(OPTIONS) end,
        })
        LASER = require("laser")
        vim.keymap.set("i", "<C-n>", function() LASER.select(1) end)
      ]])
    end,
    post_case = child.stop,
  },
})

local function type_keys(keys)
  child.api.nvim_input(keys)
  child.lua([[require("tests.helpers.settle")()]])
end

local function wait_menu_items(n)
  local ok = child.lua_get(string.format(
    [[
    vim.wait(1000, function()
      local ui = require("laser")._engine().ui
      return ui.visible() and #ui.items() >= %d
    end)
  ]],
    n
  ))
  assert(ok, "the menu did not show " .. n .. " items")
end

---Wait until completion has handled the text typed so far.
local function wait_handled(line)
  local ok = child.lua_get(string.format(
    [[
    vim.wait(1000, function()
      local engine = require("laser")._engine()
      return engine and engine.doc and engine.doc.line == %q
    end)
  ]],
    line
  ))
  assert(ok, "completion did not handle " .. line)
end

local function menu_labels()
  return child.lua_get(
    [[vim.tbl_map(function(i) return i.abbr end, require("laser")._engine().ui.items())]]
  )
end

local function selected()
  return child.lua_get([[require("laser")._engine().ui.selected()]])
end

local function selected_label()
  return child.lua_get(
    [[require("laser")._engine().ui.items()[require("laser")._engine().ui.selected()].abbr]]
  )
end

T["typing in Insert mode opens the menu with the attached client's items"] = function()
  child.lua(
    [[FAKE.start({ name = "one", items = { { label = "bar" }, { label = "baz" }, { label = "qux" } } })]]
  )
  type_keys("ib")
  wait_menu_items(2)
  expect.equality(menu_labels(), { "bar", "baz" })

  type_keys("az")
  child.lua([[vim.wait(200, function() return #require("laser")._engine().ui.items() == 1 end)]])
  expect.equality(menu_labels(), { "baz" })
end

T["commit characters opt in confirms the selected item before typing"] = function()
  child.lua([[
    OPTIONS = { enable_commit_characters = true }
    FAKE.start({ items = { { label = "bar", commitCharacters = { "." },
      command = { title = "test", command = "test.commit" } } } })
    vim.lsp.commands["test.commit"] = function() COMMITTED = true end
    vim.keymap.set("i", "<C-n>", function() LASER.select(1, { insert = false }) end)
  ]])
  type_keys("ib")
  wait_menu_items(1)
  type_keys("<C-n>")
  type_keys(".")
  child.lua([[require("tests.helpers.settle")()]])
  expect.equality(child.api.nvim_get_current_line(), "bar.")
  expect.equality(child.lua_get("COMMITTED"), true)
end

for name, case in pairs({
  ["disabled by default"] = { expected = "b." },
  ["explicitly disabled"] = { enabled = false, expected = "b." },
  ["static server fallback"] = { enabled = true, expected = "bar." },
  ["empty item list overrides server"] = { enabled = true, chars = {}, expected = "b." },
  ["item list overrides server"] = { enabled = true, chars = { ";" }, expected = "b." },
  ["list defaults override server"] = { enabled = true, defaults = { ";" }, expected = "b." },
  ["no selection"] = { enabled = true, no_selection = true, expected = "b." },
  ["dynamic server fallback"] = { enabled = true, dynamic = true, expected = "bar." },
}) do
  T["commit characters: " .. name] = function()
    child.lua("CASE = " .. vim.inspect(case))
    child.lua([[
      OPTIONS = { enable_commit_characters = CASE.enabled }
      vim.bo.filetype = "lua"
      local c = FAKE.start({ items = {
        isIncomplete = false, itemDefaults = { commitCharacters = CASE.defaults },
        items = { { label = "bar", commitCharacters = CASE.chars } },
      } })
      if CASE.dynamic then
        c.server_capabilities.completionProvider = nil
        c.capabilities.textDocument.completion.dynamicRegistration = true
        c.dynamic_capabilities:register({ {
          id = "commit", method = "textDocument/completion", registerOptions = {
            documentSelector = { { language = "lua" } }, allCommitCharacters = { "." },
          },
        } })
      else
        c.server_capabilities.completionProvider.allCommitCharacters = { "." }
      end
      vim.keymap.set("i", "<C-n>", function() LASER.select(1, { insert = false }) end)
    ]])
    type_keys("ib")
    wait_menu_items(1)
    if not case.no_selection then
      type_keys("<C-n>")
    end
    type_keys(".")
    child.lua([[require("tests.helpers.settle")()]])
    expect.equality(child.api.nvim_get_current_line(), case.expected)
  end
end

T["commit character is inserted after snippet expansion"] = function()
  child.lua([[
    OPTIONS = { enable_commit_characters = true }
    FAKE.start({ items = { { label = "bar", insertText = "bar($1)$0",
      insertTextFormat = 2, commitCharacters = { "." } } } })
  ]])
  type_keys("ib")
  wait_menu_items(1)
  type_keys("<C-n>")
  type_keys(".")
  child.lua([[require("tests.helpers.settle")()]])
  expect.equality(child.api.nvim_get_current_line(), "bar(.)")
end

T["commit character preserves queued input after snippet expansion"] = function()
  child.lua([[
    OPTIONS = { enable_commit_characters = true }
    FAKE.start({ items = { { label = "bar", insertText = "bar($1)$0",
      insertTextFormat = 2, commitCharacters = { "." } } } })
  ]])
  type_keys("ib")
  wait_menu_items(1)
  type_keys("<C-n>")
  type_keys(".x")
  child.lua([[require("tests.helpers.settle")()]])
  expect.equality(child.api.nvim_get_current_line(), "bar(.x)")
end

T["commit characters confirm command-line candidates"] = function()
  child.lua([[
    vim.api.nvim_create_autocmd({ "CmdlineEnter", "CmdlineChanged" }, {
      pattern = ":", callback = function()
        require("laser").complete({ language_id = "laser-cmd", enable_commit_characters = true })
      end,
    })
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "laser-cmd", callback = function(ev)
        FAKE.start({ items = { { label = "echo", commitCharacters = { " " } } } }, ev.buf)
      end,
    })
    vim.keymap.set("c", "<C-n>", function() LASER.select(1, { insert = false }) end)
  ]])
  type_keys(":e")
  wait_menu_items(1)
  type_keys("<C-n>")
  type_keys(" ")
  child.lua([[require("tests.helpers.settle")()]])
  expect.equality(child.fn.getcmdline(), "echo ")
end

T["confirming a snippet item expands it in the buffer"] = function()
  child.lua([[FAKE.start({
    name = "one",
    items = { { label = "bar", insertText = "bar($1)$0", insertTextFormat = 2 } },
  })]])
  child.lua([[vim.keymap.set("i", "<C-y>", function() LASER.confirm() end)]])
  type_keys("ib")
  wait_menu_items(1)

  type_keys("<C-n>")
  child.lua([[require("tests.helpers.settle")()]])
  type_keys("<C-y>")
  child.lua([[vim.wait(200, function() return vim.api.nvim_get_current_line() == "bar()" end)]])

  expect.equality(child.api.nvim_get_current_line(), "bar()")
  expect.equality(child.api.nvim_win_get_cursor(0), { 1, 4 })
end

T["confirming a snippet that auto-wrap would split expands it in place"] = function()
  child.lua([[FAKE.start({
    items = { { label = "function", insertText = "function($1)", insertTextFormat = 2 } },
  })]])
  child.lua([[vim.keymap.set("i", "<C-y>", function() LASER.confirm() end)]])
  child.bo.textwidth = 10
  child.bo.formatoptions = "t"
  child.api.nvim_buf_set_lines(0, 0, -1, false, { "aaaaaaaa " })
  type_keys("Af")
  wait_menu_items(1)
  type_keys("<C-n>")
  type_keys("<C-y>")
  child.lua([[require("tests.helpers.settle")()]])
  expect.equality(child.api.nvim_buf_get_lines(0, 0, -1, false), { "aaaaaaaa function()" })
  expect.equality(child.lua_get([[vim.v.errmsg]]), "")
end

T["confirming multi-line text keeps its indentation and comment leaders out"] = function()
  child.lua([[FAKE.start({ items = { { label = "bar", insertText = "bar(\n  a\n)" } } })]])
  child.lua([[vim.keymap.set("i", "<C-y>", function() LASER.confirm() end)]])
  child.bo.autoindent = true
  child.bo.comments = "://"
  child.bo.formatoptions = "ro"
  child.api.nvim_buf_set_lines(0, 0, -1, false, { "  " })
  type_keys("Ab")
  wait_menu_items(1)
  type_keys("<C-n>")
  type_keys("<C-y>")
  child.lua([[require("tests.helpers.settle")()]])
  expect.equality(child.api.nvim_buf_get_lines(0, 0, -1, false), { "  bar(", "  a", ")" })
end

T["confirming a snippet on the command line inserts its text"] = function()
  child.lua([[
    vim.api.nvim_create_autocmd({ "CmdlineEnter", "CmdlineChanged" }, {
      pattern = ":",
      callback = function() require("laser").complete({ language_id = "laser-cmd" }) end,
    })
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "laser-cmd",
      callback = function(ev)
        FAKE.start({
          items = { { label = "echo", insertText = "echo ${1:'x'}", insertTextFormat = 2 } },
        }, ev.buf)
      end,
    })
    vim.keymap.set("c", "<C-n>", function() LASER.select(1) end)
    vim.keymap.set("c", "<C-y>", function() LASER.confirm() end)
  ]])
  type_keys(":e")
  wait_menu_items(1)
  type_keys("<C-n>")
  type_keys("<C-y>")
  expect.equality(child.fn.getcmdline(), "echo 'x'")
end

T["the command line completes through the scratch document"] = function()
  child.lua([[
    vim.api.nvim_create_autocmd({ "CmdlineEnter", "CmdlineChanged" }, {
      pattern = ":",
      callback = function() require("laser").complete({ language_id = "laser-cmd" }) end,
    })
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "laser-cmd",
      callback = function(ev)
        FAKE.start({ name = "cmd", items = { { label = "echo" }, { label = "edit" } } }, ev.buf)
      end,
    })
  ]])
  type_keys(":e")
  wait_menu_items(2)
  expect.equality(menu_labels(), { "echo", "edit" })
  expect.equality(child.api.nvim_get_mode().mode, "c")
end

T["the command-line menu sits above a wrapped command line at the completed word"] = function()
  child.lua([[
    vim.o.columns, vim.o.lines = 40, 24
    vim.api.nvim_create_autocmd({ "CmdlineEnter", "CmdlineChanged" }, {
      pattern = ":",
      callback = function() require("laser").complete({ language_id = "laser-cmd" }) end,
    })
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "laser-cmd",
      callback = function(ev)
        FAKE.start({ name = "cmd", items = { { label = "echo" }, { label = "edit" } } }, ev.buf)
      end,
    })
  ]])
  -- ":" and 50 "x" fill the first row and wrap " e" onto the second.
  type_keys(":" .. string.rep("x", 50) .. " e")
  wait_menu_items(2)
  local config =
    child.api.nvim_win_get_config(child.lua_get([[require("laser")._engine().ui.win()]]))
  -- The command line takes rows 22 and 23 (0-based); "e" is in column 12.
  expect.equality({ config.row, config.col, config.height }, { 20, 12, 2 })
end

T["the command-line preview stays above a wrapped command line"] = function()
  child.lua([[
    vim.o.columns, vim.o.lines = 60, 24
    vim.api.nvim_create_autocmd({ "CmdlineEnter", "CmdlineChanged" }, {
      pattern = ":",
      callback = function()
        require("laser").complete({ language_id = "laser-cmd", menu = { preview = true } })
      end,
    })
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "laser-cmd",
      callback = function(ev)
        -- Resolving replaces documentation but keeps detail.
        local detail = table.concat(vim.split(string.rep("x", 30, " "), " "), "\n")
        FAKE.start({ items = { { label = "echo", detail = detail } } }, ev.buf)
      end,
    })
    vim.keymap.set("c", "<C-n>", function() LASER.select(1, { insert = false }) end)
  ]])
  type_keys(":" .. string.rep("x", 70) .. " e")
  wait_menu_items(1)
  type_keys("<C-n>")
  local config =
    child.api.nvim_win_get_config(child.lua_get([[require("laser")._engine().ui.preview_win()]]))
  -- The command line takes rows 22 and 23 (0-based).
  expect.equality(config.row + config.height <= 22, true)
end

T["command-line words follow the scratch document's iskeyword"] = function()
  child.lua([[
    vim.api.nvim_create_autocmd({ "CmdlineEnter", "CmdlineChanged" }, {
      pattern = ":",
      callback = function() require("laser").complete({ language_id = "laser-cmd" }) end,
    })
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "laser-cmd",
      callback = function(ev)
        vim.bo[ev.buf].iskeyword = "@,-"
        FAKE.start({ items = { { label = "a-bc" } } }, ev.buf)
      end,
    })
    vim.keymap.set("c", "<C-n>", function() LASER.select(1) end)
  ]])
  type_keys(":a-b")
  wait_menu_items(1)
  type_keys("<C-n>")
  expect.equality(child.fn.getcmdline(), "a-bc")
end

T["scrolling the command-line preview redraws it"] = function()
  child.lua([[
    vim.api.nvim_create_autocmd({ "CmdlineEnter", "CmdlineChanged" }, {
      pattern = ":",
      callback = function()
        require("laser").complete({
          language_id = "laser-cmd",
          menu = { preview = { max_height = 2 } },
        })
      end,
    })
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "laser-cmd",
      callback = function(ev)
        FAKE.start({ items = { { label = "echo", detail = "1\n2\n3\n4" } } }, ev.buf)
      end,
    })
    vim.keymap.set("c", "<C-n>", function() LASER.select(1, { insert = false }) end)
    vim.keymap.set("c", "<F9>", function() LASER.scroll_preview(1) end)
    local redraw = vim.api.nvim__redraw
    REDRAWS = 0
    vim.api.nvim__redraw = function(...)
      REDRAWS = REDRAWS + 1
      return redraw(...)
    end
  ]])
  type_keys(":e")
  wait_menu_items(1)
  type_keys("<C-n>")
  local before = child.lua_get("REDRAWS")
  type_keys("<F9>")
  expect.equality(child.lua_get("REDRAWS") > before, true)
end

T["an expression prompt entered from the command line closes its menu"] = function()
  child.lua([[
    vim.api.nvim_create_autocmd({ "CmdlineEnter", "CmdlineChanged" }, {
      pattern = ":",
      callback = function() require("laser").complete({ language_id = "laser-cmd" }) end,
    })
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "laser-cmd",
      callback = function(ev)
        FAKE.start({ name = "cmd", items = { { label = "echo" }, { label = "edit" } } }, ev.buf)
      end,
    })
    vim.keymap.set("c", "<C-n>", function() LASER.select(1) end)
  ]])
  type_keys(":e")
  wait_menu_items(2)
  type_keys("<C-r>=")
  type_keys("xy")
  expect.equality(child.lua_get([[LASER.visible()]]), false)
  type_keys("<C-n>")
  expect.equality(child.fn.getcmdline(), "xy")
end

T["an expression prompt entered from Insert mode closes its menu"] = function()
  child.lua([[
    FAKE.start({ items = { { label = "bar" }, { label = "baz" } } })
    vim.keymap.set("c", "<C-n>", function() LASER.select(1) end)
  ]])
  type_keys("ib")
  wait_menu_items(2)
  type_keys("<C-r>=")
  type_keys("1+")
  expect.equality(child.lua_get([[LASER.visible()]]), false)
  type_keys("<C-n>")
  expect.equality(child.fn.getcmdline(), "1+")
end

T["entering Insert mode completes at the cursor"] = function()
  child.lua([[FAKE.start({ trigger_chars = { "." }, items = { { label = "bar" } } })]])
  child.api.nvim_buf_set_lines(0, 0, -1, false, { "foo." })
  type_keys("A")
  wait_menu_items(1)
  expect.equality(menu_labels(), { "bar" })
end

T["moving the selection does not reopen the menu"] = function()
  child.lua([[FAKE.start({ name = "one", items = { { label = "bar" }, { label = "baz" } } })]])
  type_keys("ib")
  wait_menu_items(2)

  type_keys("<C-n>")
  child.lua([[require("tests.helpers.settle")()]])

  expect.equality(child.api.nvim_get_current_line(), "bar")
  expect.equality(selected(), 1)
end

local function completion_requests()
  return child.lua_get([[vim.tbl_filter(function(r)
    return r.method == "textDocument/completion"
  end, FAKE.last.requests)]])
end

T["typing reuses a complete list"] = function()
  child.lua([[FAKE.start({ items = { { label = "bar" }, { label = "baz" } } })]])
  type_keys("ib")
  wait_menu_items(2)
  local count = #completion_requests()
  type_keys("a")
  wait_handled("ba")
  expect.equality(#completion_requests(), count)
  expect.equality(menu_labels(), { "bar", "baz" })
end

T["trigger characters request a new list with trigger context"] = function()
  child.lua([[FAKE.start({ trigger_chars = { "." }, items = { { label = "bar" } } })]])
  type_keys("ib")
  wait_menu_items(1)
  type_keys(".")
  wait_handled("b.")
  wait_menu_items(1)
  local requests = completion_requests()
  expect.equality(requests[#requests].params.context, {
    triggerKind = 2,
    triggerCharacter = ".",
  })
end

T["an empty client list closes completion and omitted clients restore all"] = function()
  child.lua([[
    FAKE.start({ items = { { label = "bar" } } })
    vim.keymap.set("i", "<F5>", function()
      require("laser").complete({ clients = {} })
    end)
    vim.keymap.set("i", "<F6>", function() require("laser").complete() end)
  ]])
  type_keys("ib")
  wait_menu_items(1)
  type_keys("<F5>")
  expect.equality(child.lua_get([[require("laser")._engine().session == nil]]), true)
  type_keys("<F6>")
  wait_menu_items(1)
end

T["leaving Insert mode cancels delayed completion"] = function()
  child.lua([[FAKE.start({ delay_ms = 200, items = { { label = "bar" } } })]])
  type_keys("ib")
  type_keys("<Esc>")
  -- Past the server's delay: a late reply must not show up.
  child.lua([[vim.wait(300)]])
  expect.equality(child.lua_get([[require("laser")._engine().session == nil]]), true)
  expect.equality(child.lua_get([[require("laser")._engine().ui.visible()]]), false)
  expect.equality(child.lua_get([[FAKE.last.cancelled_count]]), 1)
end

T["a response arriving after the cursor moved away does not open the menu"] = function()
  child.lua([[FAKE.start({ delay_ms = 200, items = { { label = "barbaz" } } })]])
  child.api.nvim_buf_set_lines(0, 0, -1, false, { "xx", "hello world" })
  child.api.nvim_win_set_cursor(0, { 1, 1 })
  type_keys("A b")
  type_keys("<Down>")
  -- Past the server's delay: a late reply must not show up.
  child.lua([[vim.wait(300)]])
  expect.equality(child.lua_get([[require("laser")._engine().ui.visible()]]), false)
  type_keys("<C-n>")
  expect.equality(child.api.nvim_buf_get_lines(0, 0, -1, false), { "xx b", "hello world" })
end

T["switching buffers closes completion"] = function()
  child.lua([[
    FAKE.start({ items = { { label = "bar" } } })
    OTHER = vim.api.nvim_create_buf(true, true)
  ]])
  type_keys("ib")
  wait_menu_items(1)
  type_keys("<Cmd>lua vim.api.nvim_set_current_buf(OTHER)<CR>")
  expect.equality(child.lua_get([[require("laser")._engine().session == nil]]), true)
  expect.equality(child.lua_get([[LASER.visible()]]), false)
end

local function setup_cmdline(items)
  child.lua(string.format(
    [[
    vim.api.nvim_create_autocmd({ "CmdlineEnter", "CmdlineChanged" }, {
      pattern = ":",
      callback = function() require("laser").complete({ language_id = "laser-cmd" }) end,
    })
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "laser-cmd",
      callback = function(ev) FAKE.start({ items = %s }, ev.buf) end,
    })
    vim.keymap.set("c", "<C-n>", function() LASER.select(1) end)
    vim.keymap.set("c", "<C-y>", function() LASER.confirm() end)
  ]],
    vim.inspect(items)
  ))
end

T["wiping the command-line document closes its session"] = function()
  setup_cmdline({ { label = "echo" } })
  type_keys(":e")
  wait_menu_items(1)
  type_keys(
    [[<Cmd>lua vim.api.nvim_buf_delete(require("laser")._engine().doc.bufnr, { force = true })<CR>]]
  )
  expect.equality(child.lua_get([[require("laser")._engine().session == nil]]), true)
end

T["confirming on the command line leaves the edited buffer alone"] = function()
  setup_cmdline({
    {
      label = "echo",
      additionalTextEdits = {
        {
          newText = "edited",
          range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
        },
      },
    },
  })
  child.api.nvim_buf_set_lines(0, 0, -1, false, { "text" })
  type_keys(":e")
  wait_menu_items(1)
  type_keys("<C-n>")
  type_keys("<C-y>")
  expect.equality(child.fn.getcmdline(), "echo")
  expect.equality(child.api.nvim_buf_get_lines(0, 0, -1, false), { "text" })
  -- Nor is the scratch document edited: the command line owns the text.
  local scratch = child.fn.bufnr("untitled://laser-cmdline/laser-cmd")
  expect.equality(child.api.nvim_buf_get_lines(scratch, 0, -1, false), { "e" })
end

T["leaving the command line closes its session"] = function()
  child.lua([[
    vim.api.nvim_create_autocmd({ "CmdlineEnter", "CmdlineChanged" }, {
      pattern = ":",
      callback = function() require("laser").complete({ language_id = "laser-cmd" }) end,
    })
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "laser-cmd",
      callback = function(ev) FAKE.start({ items = { { label = "echo" } } }, ev.buf) end,
    })
  ]])
  type_keys(":e")
  wait_menu_items(1)
  type_keys("<Esc>")
  expect.equality(child.lua_get([[require("laser")._engine().session == nil]]), true)
end

T["the public pattern helper controls refresh from an autocmd"] = function()
  child.lua([[
    CALLS = 0
    SEEN = {}
    OPTIONS = { clientOptions = { _ = { refresh = function(ctx)
      table.insert(SEEN, ctx)
      return require("laser.refresh").hasPattern(ctx, "ba$")
    end } } }
    FAKE.start({ items = function()
      CALLS = CALLS + 1
      return { { label = "bar" }, { label = "baz" } }
    end })
  ]])
  type_keys("ib")
  wait_menu_items(2)
  local initial = child.lua_get("CALLS")
  type_keys("a")
  wait_menu_items(2)
  expect.equality(child.lua_get("CALLS"), initial + 1)
  expect.equality(child.lua_get("SEEN[#SEEN].before_cursor"), "ba")
  expect.equality(child.lua_get("SEEN[#SEEN].is_incomplete"), false)
end

T["detaching a client removes its candidates without discarding the other client"] = function()
  child.lua([[
    ONE = FAKE.start({ name = "one", items = { { label = "bar" } } })
    TWO = FAKE.start({ name = "two", items = { { label = "baz" } } })
  ]])
  type_keys("ib")
  wait_menu_items(2)
  child.lua([[vim.lsp.buf_detach_client(0, ONE.id)]])
  child.lua([[require("tests.helpers.settle")()]])
  expect.equality(menu_labels(), { "baz" })
  expect.equality(
    child.lua_get([[require("laser")._engine().session.results[ONE.id] == nil]]),
    true
  )
end

T["command-line refresh receives the scratch document and current input"] = function()
  child.lua([[
    local laser = require("laser")
    local function refresh(ctx)
      CTX = ctx
      return require("laser.refresh").hasPattern(ctx, "ec$")
    end
    vim.api.nvim_create_autocmd({ "CmdlineEnter", "CmdlineChanged" }, {
      pattern = ":",
      callback = function()
        laser.complete({ language_id = "laser-cmd", clientOptions = { _ = { refresh = refresh } } })
      end,
    })
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "laser-cmd",
      callback = function(ev) FAKE.start({ items = { { label = "echo" } } }, ev.buf) end,
    })
  ]])
  type_keys(":e")
  wait_menu_items(1)
  local count = #completion_requests()
  type_keys("c")
  wait_menu_items(1)
  expect.equality(#completion_requests(), count + 1)
  expect.equality(child.lua_get("CTX.mode"), "c")
  expect.equality(child.lua_get("CTX.before_cursor"), "ec")
  expect.equality(child.lua_get("vim.bo[CTX.bufnr].filetype"), "laser-cmd")
end

T["mixed edit starts preserve the prefix when confirming a snippet"] = function()
  child.lua([[
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "é.b" })
    OPTIONS = { clients = { "wide", "*" } }
    FAKE.start({ name = "wide", items = { { label = "é.bar", textEdit = {
      newText = "é.bar", range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 4 } },
    } } } })
    FAKE.start({ name = "narrow", items = {
      items = { { label = "bar", textEditText = "bar($1)$0" } },
      itemDefaults = { insertTextFormat = 2, editRange = {
        insert = { start = { line = 0, character = 2 }, ["end"] = { line = 0, character = 4 } },
        replace = { start = { line = 0, character = 2 }, ["end"] = { line = 0, character = 4 } },
      } },
    } })
    vim.keymap.set("i", "<C-y>", function() LASER.confirm() end)
  ]])
  type_keys("Aa")
  wait_menu_items(2)
  expect.equality(child.lua_get([[require("laser")._engine().session.startcol]]), 0)
  type_keys("<C-n><C-n>")
  type_keys("<C-y>")
  child.lua([[require("tests.helpers.settle")()]])
  expect.equality(child.api.nvim_get_current_line(), "é.bar()")
  expect.equality(child.api.nvim_win_get_cursor(0), { 1, 7 })
end

T["command-line textEdit sets the menu position and accepted text"] = function()
  child.lua([[
    vim.api.nvim_create_autocmd({ "CmdlineEnter", "CmdlineChanged" }, {
      pattern = ":",
      callback = function() require("laser").complete({ language_id = "laser-cmd" }) end,
    })
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "laser-cmd",
      callback = function(ev) FAKE.start({ items = function(params)
        return { { label = "foo.bar", textEdit = {
          newText = "foo.bar", range = { start = { line = 0, character = 0 }, ["end"] = params.position },
        } } }
      end }, ev.buf) end,
    })
    vim.keymap.set("c", "<C-n>", function() LASER.select(1) end)
    vim.keymap.set("c", "<C-y>", function() LASER.confirm() end)
  ]])
  type_keys(":foo.ba")
  wait_menu_items(1)
  expect.equality(child.lua_get([[require("laser")._engine().session.startcol]]), 0)
  type_keys("<C-n><C-y>")
  expect.equality(child.fn.getcmdline(), "foo.bar")
end

T["partial updates preserve the inserted selection and cancellation input"] = function()
  child.lua([[
    OPTIONS = {
      clientOptions = { ['*'] = { sorter = function(a, b) return a.abbr < b.abbr end } },
      menu = { max_height = 2 },
    }
    FAKE.start({ name = 'stream', manual = true })
    SERVER = FAKE.last
    vim.keymap.set('i', '<C-e>', function() LASER.cancel() end)
  ]])
  type_keys("ib")
  child.lua([[
    TOKEN = SERVER.requests[#SERVER.requests].params.partialResultToken
    SERVER.progress(TOKEN, { { label = 'bb' }, { label = 'bc' }, { label = 'bz' } })
  ]])
  wait_menu_items(3)
  type_keys("<C-n>")
  expect.equality(child.api.nvim_get_current_line(), "bb")
  child.lua([[SERVER.progress(TOKEN, { { label = 'ba' } })]])
  wait_menu_items(4)
  expect.equality(menu_labels(), { "bb", "bc", "ba", "bz" })
  expect.equality(selected(), 1)
  expect.equality(child.api.nvim_get_current_line(), "bb")
  type_keys("<C-e>")
  expect.equality(child.api.nvim_get_current_line(), "b")
  child.lua([[SERVER.progress(TOKEN, { { label = 'b0' } }); require("tests.helpers.settle")()]])
  expect.equality(child.lua_get([[require('laser')._engine().ui.visible()]]), false)
end

T["scrolling expands the frozen prefix and returning does not shrink it"] = function()
  child.lua([[
    OPTIONS = {
      clientOptions = { ['*'] = { sorter = function(a, b) return a.abbr < b.abbr end } },
      menu = { max_height = 3 },
    }
    FAKE.start({ manual = true })
    SERVER = FAKE.last
    vim.keymap.set('i', '<C-p>', function() LASER.select(-1) end)
  ]])
  type_keys("ib")
  child.lua([[
    TOKEN = SERVER.requests[#SERVER.requests].params.partialResultToken
    local items = {}
    for i = 1, 9 do items[i] = { label = 'b' .. i } end
    SERVER.progress(TOKEN, items)
  ]])
  wait_menu_items(9)
  for _ = 1, 5 do
    type_keys("<C-n>")
  end
  local before = child.lua_get([[{
    frozen = require('laser')._engine().ui.frozen_count(),
    rows = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(require('laser')._engine().ui.win()), 0, -1, false),
  }]])
  expect.equality(before.frozen >= 5 and before.frozen < 9, true)
  child.lua([[SERVER.progress(TOKEN, { { label = 'b0' } })]])
  wait_menu_items(10)
  expect.equality(
    child.lua_get(
      [[vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(require('laser')._engine().ui.win()), 0, -1, false)]]
    ),
    before.rows
  )
  expect.equality(child.api.nvim_get_current_line(), "b5")
  expect.equality(menu_labels()[before.frozen + 1], "b0")
  for _ = 1, 5 do
    type_keys("<C-p>")
  end
  child.lua([[SERVER.progress(TOKEN, { { label = 'b00' } })]])
  wait_menu_items(11)
  expect.equality(menu_labels()[1], "b1")
  expect.equality(menu_labels()[before.frozen + 1], "b0")
end

T["reversed menus preserve selection when candidates are prepended visually"] = function()
  child.lua([[
    OPTIONS = { clientOptions = { ['*'] = { sorter = function(a, b) return a.abbr < b.abbr end } } }
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { '', '', '', '', '', '', '', '', '', '' })
    vim.api.nvim_win_set_cursor(0, { 10, 0 })
    OPTIONS.menu = { max_height = 2, direction = 'above', reversed = true }
    FAKE.start({ manual = true })
    SERVER = FAKE.last
  ]])
  type_keys("ib")
  child.lua([[
    TOKEN = SERVER.requests[#SERVER.requests].params.partialResultToken
    SERVER.progress(TOKEN, { {label='bb'}, {label='bc'}, {label='bz'} })
  ]])
  wait_menu_items(3)
  type_keys("<C-n>")
  child.lua([[SERVER.progress(TOKEN, { { label = 'ba' } })]])
  wait_menu_items(4)
  expect.equality(child.api.nvim_get_current_line(), "bb")
  expect.equality(selected_label(), "bb")
  expect.equality(menu_labels(), { "bb", "bc", "ba", "bz" })
  expect.equality(
    child.lua_get(
      [[vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(require('laser')._engine().ui.win()), 0, -1, false)]]
    ),
    { "bc ", "bb " }
  )
end

T["command-line partial updates keep the inserted selection"] = function()
  child.lua([[
    vim.api.nvim_create_autocmd({ 'CmdlineEnter', 'CmdlineChanged' }, {
      pattern = ':', callback = function()
        require('laser').complete({ language_id = 'stream-cmd', menu = { max_height = 1 } })
      end,
    })
    vim.api.nvim_create_autocmd('FileType', {
      pattern = 'stream-cmd', callback = function(ev)
        FAKE.start({ manual = true }, ev.buf)
        SERVER = FAKE.last
      end,
    })
    vim.keymap.set('c', '<C-n>', function() LASER.select(1) end)
  ]])
  type_keys(":e")
  child.lua([[
    TOKEN = SERVER.requests[#SERVER.requests].params.partialResultToken
    SERVER.progress(TOKEN, { {label='echo'}, {label='edit'} })
  ]])
  wait_menu_items(2)
  type_keys("<C-n>")
  child.lua([[SERVER.progress(TOKEN, { {label='earlier'} })]])
  wait_menu_items(3)
  expect.equality(child.fn.getcmdline(), "echo")
  expect.equality(selected_label(), "echo")
end

T["automatic highlighting does not freeze an untouched menu"] = function()
  child.lua([[
    OPTIONS = { menu = { auto_select = true } }
    FAKE.start({ manual = true })
    SERVER = FAKE.last
  ]])
  type_keys("ib")
  child.lua([[
    TOKEN = SERVER.requests[#SERVER.requests].params.partialResultToken
    SERVER.progress(TOKEN, { {label='bb'} })
  ]])
  wait_menu_items(1)
  child.lua([[SERVER.progress(TOKEN, { {label='ba'} })]])
  wait_menu_items(2)
  -- Untouched, the menu re-sorts to place the new candidate first.
  expect.equality(menu_labels(), { "ba", "bb" })
  expect.equality(child.api.nvim_get_current_line(), "b")
end

T["mouse selection is retained when a partial batch arrives"] = function()
  child.o.mouse = "a"
  child.lua([[
    OPTIONS = { menu = { max_height = 2 } }
    vim.keymap.set('i', '<LeftMouse>', function() LASER.select_mouse() end)
    FAKE.start({ manual = true })
    SERVER = FAKE.last
  ]])
  type_keys("ib")
  child.lua([[
    TOKEN = SERVER.requests[#SERVER.requests].params.partialResultToken
    SERVER.progress(TOKEN, { {label='bb'}, {label='bc'}, {label='bz'} })
  ]])
  wait_menu_items(3)
  child.cmd("redraw")
  local pos = child.lua_get([[vim.fn.win_screenpos(require('laser')._engine().ui.win())]])
  child.api.nvim_input_mouse("left", "press", "", 0, pos[1] - 1, pos[2] - 1)
  child.lua([[require("tests.helpers.settle")()]])
  expect.equality(selected_label(), "bb")
  child.lua([[SERVER.progress(TOKEN, { {label='ba'} })]])
  wait_menu_items(4)
  expect.equality(selected_label(), "bb")
end

T["per-call client order rearranges cached candidates"] = function()
  child.lua([[
    FAKE.start({ name = "one", items = { { label = "bar" } } })
    FIRST = FAKE.last
    FAKE.start({ name = "two", items = { { label = "baz" } } })
    OPTIONS = { clients = { "two", "one" } }
    vim.keymap.set("i", "<F5>", function()
      BEFORE = { #FIRST.requests, #FAKE.last.requests }
      require("laser").complete({ clients = { "one", "two" } })
    end)
  ]])
  type_keys("ib")
  wait_menu_items(2)
  expect.equality(menu_labels(), { "baz", "bar" })
  type_keys("<F5>")
  expect.equality(menu_labels(), { "bar", "baz" })
  expect.equality(
    child.lua_get("{ #FIRST.requests, #FAKE.last.requests }"),
    child.lua_get("BEFORE")
  )
end

for name, item in pairs({
  multiline = { label = "bar", insertText = "bar\nbaz" },
  snippet = { label = "bar", insertText = "bar($1)$0", insertTextFormat = 2 },
  ["additional edits"] = {
    label = "bar",
    additionalTextEdits = {
      {
        range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
        newText = "local ",
      },
    },
  },
}) do
  T["confirmation edits do not reopen the menu: " .. name] = function()
    child.lua("ITEM = " .. vim.inspect(item))
    child.lua([[
      FAKE.start({ items = { ITEM } })
      vim.keymap.set("i", "<C-y>", function() LASER.confirm() end)
    ]])
    type_keys("ib")
    wait_menu_items(1)
    local count = #completion_requests()
    type_keys("<C-n><C-y>")
    child.lua([[require("tests.helpers.settle")()]])
    expect.equality(child.lua_get("LASER.visible()"), false)
    expect.equality(#completion_requests(), count)
  end
end

return T

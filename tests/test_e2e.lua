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
        vim.keymap.set("i", "<C-n>", function() vim.fn["pum#map#insert_relative"](1) end)
      ]])
    end,
    post_case = child.stop,
  },
})

---pum.vim runs `silent! matchdelete()` while redrawing, which leaves E803 in
---v:errmsg and makes child.type_keys() raise; feed input directly instead.
local function type_keys(keys)
  child.api.nvim_input(keys)
  child.lua([[vim.wait(20)]])
  child.v.errmsg = ""
end

local function wait_pum_items(n)
  local ok = child.lua_get(string.format(
    [[
    vim.wait(1000, function()
      local visible = vim.fn["pum#visible"]()
      return (visible == true or visible == 1) and #vim.fn["pum#complete_info"]().items >= %d
    end)
  ]],
    n
  ))
  assert(ok, "pum did not show " .. n .. " items")
end

local function pum_labels()
  return child.lua_get(
    [[vim.tbl_map(function(i) return i.abbr end, vim.fn["pum#complete_info"]().items)]]
  )
end

T["typing in Insert mode opens pum.vim with the attached client's items"] = function()
  child.lua(
    [[FAKE.start({ name = "one", items = { { label = "bar" }, { label = "baz" }, { label = "qux" } } })]]
  )
  type_keys("ib")
  wait_pum_items(2)
  expect.equality(pum_labels(), { "bar", "baz" })

  type_keys("az")
  child.lua([[vim.wait(200, function() return #vim.fn["pum#complete_info"]().items == 1 end)]])
  expect.equality(pum_labels(), { "baz" })
end

T["confirming a snippet item expands it in the buffer"] = function()
  child.lua([[FAKE.start({
    name = "one",
    items = { { label = "bar", insertText = "bar($1)$0", insertTextFormat = 2 } },
  })]])
  child.lua([[vim.keymap.set("i", "<C-y>", function() vim.fn["pum#map#confirm"]() end)]])
  type_keys("ib")
  wait_pum_items(1)

  type_keys("<C-n>")
  child.lua([[vim.wait(50)]])
  type_keys("<C-y>")
  child.lua([[vim.wait(200, function() return vim.api.nvim_get_current_line() == "bar()" end)]])

  expect.equality(child.api.nvim_get_current_line(), "bar()")
  expect.equality(child.api.nvim_win_get_cursor(0), { 1, 4 })
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
  wait_pum_items(2)
  expect.equality(pum_labels(), { "echo", "edit" })
  expect.equality(child.api.nvim_get_mode().mode, "c")
end

T["moving the selection does not reopen the menu"] = function()
  child.lua([[FAKE.start({ name = "one", items = { { label = "bar" }, { label = "baz" } } })]])
  type_keys("ib")
  wait_pum_items(2)

  type_keys("<C-n>")
  child.lua([[vim.wait(100)]])

  expect.equality(child.api.nvim_get_current_line(), "bar")
  expect.equality(child.lua_get([[vim.fn["pum#complete_info"]().selected]]), 0)
end

local function completion_requests()
  return child.lua_get([[vim.tbl_filter(function(r)
    return r.method == "textDocument/completion"
  end, FAKE.last.requests)]])
end

T["typing reuses a complete list"] = function()
  child.lua([[FAKE.start({ items = { { label = "bar" }, { label = "baz" } } })]])
  type_keys("ib")
  wait_pum_items(2)
  local count = #completion_requests()
  type_keys("a")
  wait_pum_items(2)
  expect.equality(#completion_requests(), count)
end

T["trigger characters request a new list with trigger context"] = function()
  child.lua([[FAKE.start({ trigger_chars = { "." }, items = { { label = "bar" } } })]])
  type_keys("ib")
  wait_pum_items(1)
  type_keys(".")
  wait_pum_items(1)
  local requests = completion_requests()
  expect.equality(requests[#requests].params.context, {
    triggerKind = 2,
    triggerCharacter = ".",
  })
end

T["per-call client options replace the previous selection"] = function()
  child.lua([[
    FAKE.start({ items = { { label = "bar" } } })
    vim.keymap.set("i", "<F5>", function()
      require("laser").complete({ clients = { ["*"] = { enabled = false } } })
    end)
    vim.keymap.set("i", "<F6>", function() require("laser").complete() end)
  ]])
  type_keys("ib")
  wait_pum_items(1)
  type_keys("<F5>")
  expect.equality(child.lua_get([[require("laser")._engine().session == nil]]), true)
  type_keys("<F6>")
  wait_pum_items(1)
end

T["leaving Insert mode cancels delayed completion"] = function()
  child.lua([[FAKE.start({ delay_ms = 200, items = { { label = "bar" } } })]])
  type_keys("ib")
  type_keys("<Esc>")
  child.lua([[vim.wait(300)]])
  expect.equality(child.lua_get([[require("laser")._engine().session == nil]]), true)
  expect.equality(child.lua_get([[require("laser")._engine().ui.visible()]]), false)
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
  wait_pum_items(1)
  type_keys("<Esc>")
  expect.equality(child.lua_get([[require("laser")._engine().session == nil]]), true)
end

T["the public pattern helper controls refresh from an autocmd"] = function()
  child.lua([[
    CALLS = 0
    SEEN = {}
    OPTIONS = { clients = { ["*"] = { refresh = function(ctx)
      table.insert(SEEN, ctx)
      return require("laser").hasPattern(ctx, "ba$")
    end } } }
    FAKE.start({ items = function()
      CALLS = CALLS + 1
      return { { label = "bar" }, { label = "baz" } }
    end })
  ]])
  type_keys("ib")
  wait_pum_items(2)
  local initial = child.lua_get("CALLS")
  type_keys("a")
  wait_pum_items(2)
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
  wait_pum_items(2)
  child.lua([[vim.lsp.buf_detach_client(0, ONE.id)]])
  child.lua([[vim.wait(100)]])
  expect.equality(pum_labels(), { "baz" })
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
      return laser.hasPattern(ctx, "ec$")
    end
    vim.api.nvim_create_autocmd({ "CmdlineEnter", "CmdlineChanged" }, {
      pattern = ":",
      callback = function()
        laser.complete({ language_id = "laser-cmd", clients = { ["*"] = { refresh = refresh } } })
      end,
    })
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "laser-cmd",
      callback = function(ev) FAKE.start({ items = { { label = "echo" } } }, ev.buf) end,
    })
  ]])
  type_keys(":e")
  wait_pum_items(1)
  local count = #completion_requests()
  type_keys("c")
  wait_pum_items(1)
  expect.equality(#completion_requests(), count + 1)
  expect.equality(child.lua_get("CTX.mode"), "c")
  expect.equality(child.lua_get("CTX.before_cursor"), "ec")
  expect.equality(child.lua_get("vim.bo[CTX.bufnr].filetype"), "laser-cmd")
end

T["mixed edit starts preserve the prefix when confirming a snippet"] = function()
  child.lua([[
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "é.b" })
    OPTIONS = { clients = { wide = { priority = 10 } } }
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
    vim.keymap.set("i", "<C-y>", function() vim.fn["pum#map#confirm"]() end)
  ]])
  type_keys("Aa")
  wait_pum_items(2)
  expect.equality(child.lua_get([[require("laser")._engine().session.startcol]]), 0)
  type_keys("<C-n><C-n>")
  type_keys("<C-y>")
  child.lua([[vim.wait(100)]])
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
    vim.keymap.set("c", "<C-n>", function() vim.fn["pum#map#insert_relative"](1) end)
    vim.keymap.set("c", "<C-y>", function() vim.fn["pum#map#confirm"]() end)
  ]])
  type_keys(":foo.ba")
  wait_pum_items(1)
  expect.equality(child.lua_get([[require("laser")._engine().session.startcol]]), 0)
  type_keys("<C-n><C-y>")
  expect.equality(child.fn.getcmdline(), "foo.bar")
end

T["partial updates preserve the inserted selection and cancellation input"] = function()
  child.lua([[
    vim.fn['pum#set_option']({ max_height = 2, auto_select = false })
    FAKE.start({ name = 'stream', manual = true })
    SERVER = FAKE.last
    vim.keymap.set('i', '<C-e>', function() vim.fn['pum#map#cancel']() end)
  ]])
  type_keys("ib")
  child.lua([[
    TOKEN = SERVER.requests[#SERVER.requests].params.partialResultToken
    SERVER.progress(TOKEN, { { label = 'bb' }, { label = 'bc' }, { label = 'bz' } })
  ]])
  wait_pum_items(3)
  type_keys("<C-n>")
  expect.equality(child.api.nvim_get_current_line(), "bb")
  child.lua([[SERVER.progress(TOKEN, { { label = 'ba' } })]])
  wait_pum_items(4)
  expect.equality(pum_labels(), { "bb", "bc", "ba", "bz" })
  expect.equality(child.lua_get([[vim.fn['pum#complete_info']().selected]]), 0)
  expect.equality(child.api.nvim_get_current_line(), "bb")
  type_keys("<C-e>")
  expect.equality(child.api.nvim_get_current_line(), "b")
  child.lua([[SERVER.progress(TOKEN, { { label = 'b0' } }); vim.wait(50)]])
  expect.equality(child.lua_get([[require('laser')._engine().ui.visible()]]), false)
end

T["scrolling expands the frozen prefix and returning does not shrink it"] = function()
  child.lua([[
    vim.fn['pum#set_option']({ max_height = 3, auto_select = false })
    FAKE.start({ manual = true })
    SERVER = FAKE.last
    vim.keymap.set('i', '<C-p>', function() vim.fn['pum#map#insert_relative'](-1) end)
  ]])
  type_keys("ib")
  child.lua([[
    TOKEN = SERVER.requests[#SERVER.requests].params.partialResultToken
    local items = {}
    for i = 1, 9 do items[i] = { label = 'b' .. i } end
    SERVER.progress(TOKEN, items)
  ]])
  wait_pum_items(9)
  for _ = 1, 5 do
    type_keys("<C-n>")
  end
  local before = child.lua_get([[{
    frozen = require('laser')._engine().ui.frozen_count(),
    top = vim.fn.line('w0', vim.fn['pum#_get']().id),
  }]])
  expect.equality(before.frozen >= 5 and before.frozen < 9, true)
  child.lua([[SERVER.progress(TOKEN, { { label = 'b0' } })]])
  wait_pum_items(10)
  expect.equality(child.lua_get([[vim.fn.line('w0', vim.fn['pum#_get']().id)]]), before.top)
  expect.equality(child.api.nvim_get_current_line(), "b5")
  expect.equality(pum_labels()[before.frozen + 1], "b0")
  for _ = 1, 5 do
    type_keys("<C-p>")
  end
  child.lua([[SERVER.progress(TOKEN, { { label = 'b00' } })]])
  wait_pum_items(11)
  expect.equality(pum_labels()[1], "b1")
  expect.equality(pum_labels()[before.frozen + 1], "b0")
end

T["reversed menus preserve selection when candidates are prepended visually"] = function()
  child.lua([[
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { '', '', '', '', '', '', '', '', '', '' })
    vim.api.nvim_win_set_cursor(0, { 10, 0 })
    vim.fn['pum#set_option']({ max_height = 2, auto_select = false, direction = 'above', reversed = true })
    vim.keymap.set('i', '<C-n>', function() vim.fn['pum#map#insert_relative'](1, 'loop') end)
    FAKE.start({ manual = true })
    SERVER = FAKE.last
  ]])
  type_keys("ib")
  child.lua([[
    TOKEN = SERVER.requests[#SERVER.requests].params.partialResultToken
    SERVER.progress(TOKEN, { {label='bb'}, {label='bc'}, {label='bz'} })
  ]])
  wait_pum_items(3)
  type_keys("<C-n>")
  child.lua([[SERVER.progress(TOKEN, { { label = 'ba' } })]])
  wait_pum_items(4)
  expect.equality(child.api.nvim_get_current_line(), "bb")
  expect.equality(child.lua_get([[vim.fn['pum#current_item']().abbr]]), "bb")
  expect.equality(pum_labels(), { "bz", "ba", "bc", "bb" })
end

return T

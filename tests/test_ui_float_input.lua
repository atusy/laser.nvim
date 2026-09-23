local MiniTest = require("mini.test")
local expect = MiniTest.expect

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "scripts/minimal_init.lua" })
      child.bo.readonly = false
      child.lua([[
        local function candidate(label)
          return { word = label, abbr = label, user_data = { laser = { client_id = 1, item = { label = label } } } }
        end
        ITEMS = { candidate("bar"), candidate("baz") }
        CONFIRMED = {}
        CLOSED = 0
        UI = require("laser.ui.float").new({
          on_close = function() CLOSED = CLOSED + 1 end,
          commit_characters = function(item) return COMMIT and COMMIT[item.word] or {} end,
          on_confirm = function(item)
            if THROW then error("boom") end
            table.insert(CONFIRMED, { word = item.word, line = vim.api.nvim_get_current_line() })
          end,
        })
        vim.keymap.set("i", "<F2>", function() UI.open(START or 1, ITEMS, "i") end)
        vim.keymap.set("c", "<F2>", function() UI.open(1, ITEMS, "c") end)
        vim.keymap.set("c", "<C-n>", function() UI.select(1) end)
        vim.keymap.set("c", "<C-j>", function() UI.select(1, { insert = false }) end)
        vim.keymap.set("c", "<C-y>", function() UI.confirm() end)
        vim.keymap.set("c", "<C-e>", function() UI.cancel() end)
        vim.keymap.set("i", "<C-n>", function() UI.select(1) end)
        vim.keymap.set("i", "<C-p>", function() UI.select(-1) end)
        vim.keymap.set("i", "<C-j>", function() UI.select(1, { insert = false }) end)
        vim.keymap.set("i", "<C-y>", function() UI.confirm() end)
        vim.keymap.set("i", "<C-e>", function() UI.cancel() end)
      ]])
    end,
    post_case = child.stop,
  },
})

local function type_keys(keys)
  child.api.nvim_input(keys)
  child.lua([[vim.wait(20)]])
end

local function line()
  return child.api.nvim_get_current_line()
end

T["select inserts candidates and stepping past the end restores the typed input"] = function()
  type_keys("ib<F2><C-n>")
  expect.equality(line(), "bar")
  expect.equality(child.api.nvim_win_get_cursor(0), { 1, 3 })
  type_keys("<C-n>")
  expect.equality(line(), "baz")
  type_keys("<C-n>")
  expect.equality(line(), "b")
  expect.equality(child.lua_get("UI.selected()"), 0)
  type_keys("<C-p>")
  expect.equality(line(), "baz")
end

T["select without insertion highlights and scrolls the viewport"] = function()
  child.lua([[
    UI.configure({ max_height = 1 })
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
  ]])
  type_keys("ib<F2><C-j><C-j>")
  expect.equality(line(), "b")
  expect.equality(child.lua_get("UI.selected()"), 2)
  expect.equality(
    child.lua_get([[vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(UI.win()), 0, -1, false)]]),
    { "baz " }
  )
end

T["confirm inserts a selected candidate before reporting it and closes"] = function()
  type_keys("ib<F2><C-j><C-y>")
  expect.equality(line(), "bar")
  expect.equality(child.lua_get("CONFIRMED"), { { word = "bar", line = "bar" } })
  expect.equality(child.lua_get("UI.visible()"), false)
end

T["confirm without a selection closes without reporting"] = function()
  type_keys("ib<F2><C-y>")
  expect.equality(line(), "b")
  expect.equality(child.lua_get("CONFIRMED"), {})
  expect.equality(child.lua_get("UI.visible()"), false)
end

T["cancel restores the typed input and closes"] = function()
  type_keys("ib<F2><C-n><C-e>")
  expect.equality(line(), "b")
  expect.equality(child.lua_get("UI.visible()"), false)
end

T["only the menu's own edit is skipped as a text change"] = function()
  child.lua([[
    SKIPPED = {}
    vim.api.nvim_create_autocmd("TextChangedI", {
      callback = function() table.insert(SKIPPED, UI.skip_text_change()) end,
    })
  ]])
  type_keys("ib")
  child.lua([[SKIPPED = {}]])
  type_keys("<F2><C-n>")
  type_keys("x")
  expect.equality(child.lua_get("SKIPPED"), { true, false })
end

T["an inserted candidate is undone with the rest of the insertion"] = function()
  type_keys("ib<F2><C-n><Esc>")
  expect.equality(line(), "bar")
  type_keys("u")
  expect.equality(line(), "")
end

T["dot-repeat inserts the accepted candidate again"] = function()
  child.api.nvim_buf_set_lines(0, 0, -1, false, { "", "" })
  type_keys("ib<F2><C-n><Esc>")
  type_keys("j.")
  expect.equality(child.api.nvim_buf_get_lines(0, 0, -1, false), { "bar", "bar" })
end

T["moving the cursor without editing closes the menu, but its own insertion does not"] = function()
  type_keys("ib<F2><C-n>")
  expect.equality(child.lua_get("UI.visible()"), true)
  type_keys("<Left>")
  expect.equality(child.lua_get("UI.visible()"), false)
  expect.equality(child.lua_get("CLOSED"), 1)
end

T["resizing the editor closes the menu"] = function()
  type_keys("ib<F2>")
  child.o.columns = child.o.columns - 1
  child.lua([[vim.wait(20)]])
  expect.equality(child.lua_get("UI.visible()"), false)
end

T["clicking a candidate selects it"] = function()
  child.o.mouse = "a"
  child.lua([[vim.keymap.set("i", "<LeftMouse>", function() UI.select_mouse() end)]])
  type_keys("ib<F2>")
  child.cmd("redraw")
  local pos = child.lua_get([[vim.fn.win_screenpos(UI.win())]])
  child.api.nvim_input_mouse("left", "press", "", 0, pos[1], pos[2] - 1)
  child.lua([[vim.wait(20)]])
  expect.equality(child.lua_get("UI.selected()"), 2)
  expect.equality(line(), "b")
end

T["a commit character confirms the selection, then is typed"] = function()
  child.lua([[COMMIT = { bar = { "." } }]])
  type_keys("ib<F2><C-j>.")
  child.lua([[vim.wait(50)]])
  expect.equality(line(), "bar.")
  expect.equality(child.lua_get("CONFIRMED"), { { word = "bar", line = "bar" } })
end

T["input typed while a commit is pending follows the commit character"] = function()
  child.lua([[COMMIT = { bar = { "." } }]])
  type_keys("ib<F2><C-j>")
  child.api.nvim_input(".xy")
  child.lua([[vim.wait(50)]])
  expect.equality(line(), "bar.xy")
end

T["other characters and unselected menus are typed normally"] = function()
  child.lua([[COMMIT = { bar = { "." } }]])
  type_keys("ib<F2>.")
  expect.equality(line(), "b.")
  expect.equality(child.lua_get("CONFIRMED"), {})
end

T["the command-line menu is drawn above the command line"] = function()
  child.o.lines, child.o.columns = 10, 30
  type_keys(":b<F2>")
  expect.equality(child.api.nvim_get_mode().mode, "c")
  local pos = child.lua_get([[vim.fn.win_screenpos(UI.win())]])
  expect.equality(pos, { 10 - 1 - 2 + 1, 2 })
  local screen = child.get_screenshot()
  expect.equality(screen.text[8][2], "b")
  expect.equality(table.concat(screen.text[8], "", 2, 4), "bar")
  expect.equality(table.concat(screen.text[9], "", 2, 4), "baz")
end

T["command-line insertion, cancellation and confirmation edit the command line"] = function()
  type_keys(":b<F2><C-n>")
  expect.equality(child.fn.getcmdline(), "bar")
  expect.equality(child.fn.getcmdpos(), 4)
  expect.equality(child.lua_get("UI.skip_text_change()"), true)
  type_keys("<C-e>")
  expect.equality(child.fn.getcmdline(), "b")
  type_keys("<F2><C-n><C-n><C-y>")
  expect.equality(child.fn.getcmdline(), "baz")
  expect.equality(child.lua_get("CONFIRMED"), { { word = "baz", line = "" } })
end

T["moving the command-line cursor without editing closes the menu"] = function()
  type_keys(":b<F2>")
  type_keys("<Left>")
  expect.equality(child.lua_get("UI.visible()"), false)
end

T["command-line scrolling and closing are repainted"] = function()
  child.o.lines, child.o.columns = 10, 30
  child.lua([[UI.configure({ max_height = 1 })]])
  type_keys(":b<F2><C-n><C-n>")
  expect.equality(table.concat(child.get_screenshot().text[9], "", 2, 4), "baz")
  type_keys("<C-e>")
  expect.no_equality(table.concat(child.get_screenshot().text[9], "", 2, 4), "baz")
end

T["command-line selection without insertion is repainted"] = function()
  child.o.lines, child.o.columns = 10, 30
  type_keys(":b<F2>")
  local before = child.get_screenshot().attr
  expect.equality(before[8][2], before[9][2])
  type_keys("<C-j>")
  local after = child.get_screenshot().attr
  expect.no_equality(after[8][2], after[9][2])
end

T["keys typed while a commit is pending are replayed unchanged"] = function()
  child.lua([[COMMIT = { bar = { "." } }]])
  type_keys("ib<F2><C-j>")
  child.api.nvim_input(".<BS>x、")
  child.lua([[vim.wait(50)]])
  expect.equality(line(), "barx、")
end

T["candidates that would be auto-wrapped are selected without insertion"] = function()
  child.lua([[
    ITEMS = { { word = "barbazquxquux", abbr = "barbazquxquux", user_data = { laser = { client_id = 1, item = { label = "barbazquxquux" } } } } }
    vim.bo.textwidth = 10
    vim.bo.formatoptions = "t"
  ]])
  type_keys("ib<F2><C-n>")
  expect.equality(child.api.nvim_buf_get_lines(0, 0, -1, false), { "b" })
  expect.equality(child.lua_get("UI.selected()"), 1)
  expect.equality(child.lua_get("UI.visible()"), true)
end

T["options changed for insertion are restored when the fed keys are discarded"] = function()
  child.lua([[
    vim.o.backspace = "indent,eol,start"
    vim.bo.indentkeys = "0{,0}"
    vim.keymap.set("i", "<F3>", function()
      UI.select(1)
      -- Discard the keys the menu fed, as an interrupt would.
      vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    end)
  ]])
  type_keys("ib<F2><F3>")
  child.lua([[vim.wait(50)]])
  expect.equality(child.o.backspace, "indent,eol,start")
  expect.equality(child.bo.indentkeys, "0{,0}")
end

T["a failing confirmation still types the commit character and keeps input flowing"] = function()
  child.lua([[COMMIT = { bar = { "." } }; THROW = true]])
  type_keys("ib<F2><C-j>")
  child.api.nvim_input(".")
  child.lua([[vim.wait(50)]])
  child.lua([[THROW = false]])
  type_keys("xyz<Esc>")
  child.lua([[vim.wait(50)]])
  expect.equality(line(), "bar.xyz")
  expect.equality(child.api.nvim_get_mode().mode, "n")
end

T["a confirmation without edits does not skip the next completion"] = function()
  -- Completion consumes the menu's own change on each text change.
  child.lua([[vim.api.nvim_create_autocmd("TextChangedI", { callback = UI.skip_text_change })]])
  type_keys("ib<F2><C-n><C-y><Esc>a")
  expect.equality(line(), "bar")
  expect.equality(child.lua_get("UI.skip_text_change()"), false)
end

for _, delcombine in ipairs({ false, true }) do
  T["insertion replaces combining characters exactly (delcombine=" .. tostring(delcombine) .. ")"] = function()
    child.o.delcombine = delcombine
    child.lua([[START = 4]])
    type_keys("iab.e\u{0301}<F2><C-n>")
    expect.equality(line(), "ab.bar")
  end
end

T["insertion replaces spaces one by one despite softtabstop"] = function()
  child.bo.softtabstop, child.bo.expandtab = 4, true
  child.lua([[START = 4]])
  child.api.nvim_buf_set_lines(0, 0, -1, false, { "ab.x    y" })
  type_keys("A<F2><C-n>")
  expect.equality(line(), "ab.bar")
end

T["candidates ending exactly at textwidth are inserted"] = function()
  child.lua([[
    ITEMS = { { word = "barbazquxq", abbr = "barbazquxq", user_data = { laser = { client_id = 1, item = { label = "barbazquxq" } } } } }
    vim.bo.textwidth = 10
    vim.bo.formatoptions = "t"
  ]])
  type_keys("ib<F2><C-n>")
  expect.equality(child.api.nvim_buf_get_lines(0, 0, -1, false), { "barbazquxq" })
end

T["the menu lines up with input() text after its prompt"] = function()
  child.lua([[vim.keymap.set("c", "<F2>", function() UI.open(1, ITEMS, "c") end)]])
  type_keys(":call input('N: ')<CR>b<F2>")
  expect.equality(child.fn.getcmdtype(), "@")
  expect.equality(child.lua_get([[vim.api.nvim_win_get_config(UI.win()).col]]), 3)
end

T["scrolling caused by the menu's own insertion keeps it open"] = function()
  child.o.columns = 20
  child.wo.wrap = false
  child.o.sidescroll = 1
  child.lua([[
    ITEMS = { { word = "0123456789bar_very_long", abbr = "x", user_data = { laser = { client_id = 1, item = { label = "x" } } } } }
    START = 1
  ]])
  type_keys("i0123456789b<F2><C-n>")
  child.cmd("redraw")
  expect.equality(line(), "0123456789bar_very_long")
  expect.equality(child.lua_get("UI.visible()"), true)
  expect.equality(child.lua_get("CLOSED"), 0)
end

T["scrolling the window without editing closes the menu"] = function()
  child.api.nvim_buf_set_lines(0, 0, -1, false, vim.fn["repeat"]({ "" }, 100))
  type_keys("50Gzzib<F2>")
  type_keys("<C-x><C-e>")
  -- WinScrolled is detected when the screen is updated.
  child.cmd("redraw")
  expect.equality(child.lua_get("UI.visible()"), false)
end

T["a close refused under textlock leaves a working menu"] = function()
  child.lua([[
    vim.keymap.set("i", "<F4>", function()
      pcall(UI.cancel)
      return ""
    end, { expr = true })
  ]])
  type_keys("ib<F2><F4>")
  expect.equality(child.lua_get("UI.visible()"), true)
  expect.equality(child.lua_get("CLOSED"), 0)
  type_keys("<Left>")
  expect.equality(child.lua_get("UI.visible()"), false)
end

T["clicking a bordered menu selects by its drawn border"] = function()
  child.o.mouse = "a"
  child.lua([[
    vim.keymap.set("i", "<LeftMouse>", function() UI.select_mouse() end)
    UI.configure({ border = "single" })
  ]])
  type_keys("ib<F2>")
  -- Options passed to a later call must not change how the open menu is read.
  child.lua([[UI.configure({})]])
  child.cmd("redraw")
  local pos = child.lua_get([[vim.fn.win_screenpos(UI.win())]])
  child.api.nvim_input_mouse("left", "press", "", 0, pos[1], pos[2])
  child.lua([[vim.wait(20)]])
  expect.equality(child.lua_get("UI.selected()"), 1)
end

T["leaving the window closes the menu"] = function()
  -- Another buffer's window, so the cursor watcher alone would not close it.
  child.cmd("vnew | wincmd p")
  type_keys("ib<F2>")
  type_keys("<Cmd>wincmd p<CR>")
  expect.equality(child.lua_get("UI.visible()"), false)
  expect.equality(child.lua_get("CLOSED"), 1)
end

T["the menu's own change is recognized once, not when later input returns to it"] = function()
  child.lua([[
    SKIPPED = {}
    vim.api.nvim_create_autocmd("TextChangedI", {
      callback = function() table.insert(SKIPPED, UI.skip_text_change()) end,
    })
  ]])
  type_keys("ib<F2>")
  child.lua([[SKIPPED = {}]])
  type_keys("<C-n>")
  type_keys("x")
  type_keys("<BS>")
  expect.equality(line(), "bar")
  expect.equality(child.lua_get("SKIPPED"), { true, false, false })
end

T["insertion replaces input typed before this insertion even with a strict backspace"] = function()
  child.o.backspace = ""
  child.api.nvim_buf_set_lines(0, 0, -1, false, { "b" })
  type_keys("A<F2><C-n>")
  expect.equality(line(), "bar")
  expect.equality(child.o.backspace, "")
end

T["the command-line menu starts under the completion start when typed text is wide"] = function()
  child.lua([[vim.keymap.set("c", "<F2>", function() UI.open(3, ITEMS, "c") end)]])
  type_keys(":x.日本<F2>")
  -- ":" and "x." take three cells before the typed "日本".
  expect.equality(child.lua_get([[vim.api.nvim_win_get_config(UI.win()).col]]), 3)
end

T["typing that scrolls the window sideways keeps the menu open"] = function()
  child.o.columns = 20
  child.wo.wrap = false
  child.o.sidescroll = 1
  child.lua([[
    -- Like completion, redraw the menu from the current input on every change.
    vim.api.nvim_create_autocmd("TextChangedI", {
      callback = function()
        if not UI.skip_text_change() then UI.open(1, ITEMS, "i") end
      end,
    })
  ]])
  type_keys("i0123456789<F2>")
  for _ = 1, 12 do
    type_keys("x")
    child.cmd("redraw")
  end
  expect.equality(child.fn.winsaveview().leftcol > 0, true)
  expect.equality(child.lua_get("UI.visible()"), true)
  expect.equality(child.lua_get("CLOSED"), 0)
end

T["the command-line menu stays above the command line with cmdheight=0"] = function()
  child.o.lines, child.o.columns = 10, 30
  child.o.cmdheight = 0
  type_keys(":b<F2>")
  -- The command line takes the last row while it is being edited.
  local config = child.lua_get([[vim.api.nvim_win_get_config(UI.win())]])
  expect.equality(config.row + config.height, 9)
end

T["a confirmation without edits leaves no change to skip within Insert mode"] = function()
  child.lua([[vim.api.nvim_create_autocmd("TextChangedI", { callback = UI.skip_text_change })]])
  type_keys("ib<F2>")
  type_keys("<C-n>")
  type_keys("<C-y>")
  type_keys("<Left><Right>")
  expect.equality(child.api.nvim_get_mode().mode, "i")
  expect.equality(child.lua_get("UI.skip_text_change()"), false)
end

return T

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
  child.lua([[require("tests.helpers.settle")()]])
end

local function line()
  return child.api.nvim_get_current_line()
end

T["leaving the mode releases callbacks waiting for discarded keys"] = function()
  child.lua([[
    vim.keymap.set("i", "<F3>", function()
      UI.select(1)
      -- Typeahead can be discarded, e.g. by <C-c>, before the queued keys run.
      vim.api.nvim_exec_autocmds("InsertLeave", {})
      PENDING = require("laser.ui.feedkeys").pending_count()
    end)
  ]])
  type_keys("ib<F2><F3>")
  expect.equality(child.lua_get("PENDING"), 0)
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
  child.lua([[require("tests.helpers.settle")()]])
  expect.equality(child.lua_get("UI.visible()"), false)
end

T["clicking a candidate selects it"] = function()
  child.o.mouse = "a"
  child.lua([[vim.keymap.set("i", "<LeftMouse>", function() UI.select_mouse() end)]])
  type_keys("ib<F2>")
  child.cmd("redraw")
  local pos = child.lua_get([[vim.fn.win_screenpos(UI.win())]])
  child.api.nvim_input_mouse("left", "press", "", 0, pos[1], pos[2] - 1)
  child.lua([[require("tests.helpers.settle")()]])
  expect.equality(child.lua_get("UI.selected()"), 2)
  expect.equality(line(), "b")
end

T["a commit character confirms the selection, then is typed"] = function()
  child.lua([[COMMIT = { bar = { "." } }]])
  type_keys("ib<F2><C-j>.")
  child.lua([[require("tests.helpers.settle")()]])
  expect.equality(line(), "bar.")
  expect.equality(child.lua_get("CONFIRMED"), { { word = "bar", line = "bar" } })
end

T["input typed while a commit is pending follows the commit character"] = function()
  child.lua([[COMMIT = { bar = { "." } }]])
  type_keys("ib<F2><C-j>")
  child.api.nvim_input(".xy")
  child.lua([[require("tests.helpers.settle")()]])
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
  child.lua([[require("tests.helpers.settle")()]])
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
  child.lua([[require("tests.helpers.settle")()]])
  expect.equality(child.o.backspace, "indent,eol,start")
  expect.equality(child.bo.indentkeys, "0{,0}")
end

T["a failing confirmation still types the commit character and keeps input flowing"] = function()
  child.lua([[COMMIT = { bar = { "." } }; THROW = true]])
  type_keys("ib<F2><C-j>")
  child.api.nvim_input(".")
  child.lua([[require("tests.helpers.settle")()]])
  child.lua([[THROW = false]])
  type_keys("xyz<Esc>")
  child.lua([[require("tests.helpers.settle")()]])
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
    ITEMS = { { word = "bar_very_long", abbr = "x", user_data = { laser = { client_id = 1, item = { label = "x" } } } } }
    START = 11
  ]])
  type_keys("i0123456789b<F2><C-n>")
  child.cmd("redraw")
  expect.equality(line(), "0123456789bar_very_long")
  expect.equality(child.lua_get("UI.visible()"), true)
  expect.equality(child.lua_get("CLOSED"), 0)
  -- The menu moved with the scrolled text.
  local leftcol = child.fn.winsaveview().leftcol
  expect.equality(leftcol > 0, true)
  expect.equality(child.lua_get([[vim.api.nvim_win_get_config(UI.win()).col]]), 10 - leftcol)
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
  child.lua([[require("tests.helpers.settle")()]])
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
        if not UI.skip_text_change() then UI.open(START or 1, ITEMS, "i") end
      end,
    })
  ]])
  child.lua([[START = 11]])
  type_keys("i0123456789<F2>")
  for _ = 1, 12 do
    type_keys("x")
    child.cmd("redraw")
  end
  local leftcol = child.fn.winsaveview().leftcol
  expect.equality(leftcol > 0, true)
  expect.equality(child.lua_get("UI.visible()"), true)
  expect.equality(child.lua_get("CLOSED"), 0)
  -- The menu moved with the text: its start is on screen column 10 - leftcol.
  expect.equality(child.lua_get([[vim.api.nvim_win_get_config(UI.win()).col]]), 10 - leftcol)
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

T["clicking right of the menu selects nothing"] = function()
  child.o.mouse = "a"
  child.lua([[vim.keymap.set("i", "<LeftMouse>", function() RESULT = UI.select_mouse() end)]])
  type_keys("ib<F2>")
  child.cmd("redraw")
  local pos = child.lua_get([[vim.fn.win_screenpos(UI.win())]])
  local width = child.lua_get([[vim.api.nvim_win_get_width(UI.win())]])
  -- One cell past the last column, on the first row.
  child.api.nvim_input_mouse("left", "press", "", 0, pos[1] - 1, pos[2] - 1 + width)
  child.lua([[require("tests.helpers.settle")()]])
  expect.equality(child.lua_get("RESULT"), false)
  expect.equality(child.lua_get("UI.selected()"), 0)
end

T["a window shrunk under the menu lays it out again within its limits"] = function()
  child.o.lines = 20
  child.lua([[
    ITEMS = {}
    for i = 1, 6 do
      ITEMS[i] = { word = i .. "barbazqux", abbr = i .. "barbazqux", user_data = { laser = { client_id = 1, item = { label = "b" } } } }
    end
    UI.configure({ max_width = 8 })
  ]])
  type_keys("ib<F2>")
  child.lua([[UI.select(6, { insert = false })]])
  -- Leave less room below the cursor without scrolling the window.
  child.o.cmdheight = 15
  child.cmd("redraw")
  expect.equality(child.lua_get("UI.visible()"), true)
  expect.equality(child.lua_get([[vim.api.nvim_win_get_width(UI.win())]]) <= 8, true)
  local rows =
    child.lua_get([[vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(UI.win()), 0, -1, false)]])
  expect.equality(#rows < 6, true)
  -- Fields fit beside the scrollbar, and the selected last candidate stays in view.
  expect.equality(rows[#rows], "6barbaz ")
end

T["inserting into a cindent buffer does not reindent the line"] = function()
  child.bo.cindent = true
  child.lua([[
    ITEMS = { { word = "}", abbr = "}", user_data = { laser = { client_id = 1, item = { label = "}" } } } } }
    START = 5
  ]])
  child.api.nvim_buf_set_lines(0, 0, -1, false, { "{", "    b" })
  child.api.nvim_win_set_cursor(0, { 2, 4 })
  type_keys("A<F2><C-n>")
  expect.equality(child.api.nvim_buf_get_lines(0, 0, -1, false), { "{", "    }" })
  type_keys("<C-e>")
  expect.equality(child.api.nvim_buf_get_lines(0, 0, -1, false), { "{", "    b" })
end

T["control characters in candidates are inserted literally"] = function()
  child.bo.expandtab = true
  child.lua([[
    ITEMS = { { word = "bar\tbaz", abbr = "bar", user_data = { laser = { client_id = 1, item = { label = "bar" } } } } }
    SKIPPED = {}
    vim.api.nvim_create_autocmd("TextChangedI", {
      callback = function() table.insert(SKIPPED, UI.skip_text_change()) end,
    })
  ]])
  type_keys("ib")
  child.lua([[SKIPPED = {}]])
  type_keys("<F2><C-n>")
  expect.equality(line(), "bar\tbaz")
  expect.equality(child.lua_get("SKIPPED"), { true })
end

T["candidates that would split the line are only selected"] = function()
  child.lua([[
    local function item(word)
      return { word = word, abbr = "x", user_data = { laser = { client_id = 1, item = { label = "x" } } } }
    end
    ITEMS = { item("bar\nbaz"), item("bar baz quux") }
  ]])
  -- 'wrapmargin' wraps a window 20 columns wide at 10 when 'textwidth' is 0.
  child.o.columns = 20
  child.bo.textwidth, child.bo.wrapmargin, child.bo.formatoptions = 0, 10, "t"
  type_keys("ib<F2><C-n>")
  expect.equality(child.api.nvim_buf_get_lines(0, 0, -1, false), { "b" })
  expect.equality(child.lua_get("UI.selected()"), 1)
  type_keys("<C-n>")
  expect.equality(child.api.nvim_buf_get_lines(0, 0, -1, false), { "b" })
  expect.equality(child.lua_get("UI.selected()"), 2)
  expect.equality(child.lua_get("UI.visible()"), true)
end

T["insertion can replace automatic indentation"] = function()
  child.bo.autoindent = true
  child.api.nvim_buf_set_lines(0, 0, -1, false, { "    x" })
  -- A server edit that replaces the new line's indentation as well.
  type_keys("o")
  type_keys("b<F2><C-n>")
  expect.equality(child.api.nvim_buf_get_lines(0, 0, -1, false), { "    x", "bar" })
end

T["InsertCharPre hooks do not transform inserted candidates"] = function()
  child.lua([[
    ITEMS = { { word = "bar(", abbr = "bar(", user_data = { laser = { client_id = 1, item = { label = "bar(" } } } } }
    -- Like an auto-pairs plugin.
    vim.api.nvim_create_autocmd("InsertCharPre", {
      callback = function() if vim.v.char == "(" then vim.v.char = "()" end end,
    })
  ]])
  type_keys("ib<F2><C-n>")
  expect.equality(line(), "bar(")
  expect.equality(child.o.eventignore, "")
  -- Typing afterwards still reaches the hook.
  type_keys("<Esc>A(")
  expect.equality(line(), "bar(()")
end

T["NUL bytes in candidates are dropped instead of corrupting the input"] = function()
  child.lua([[
    ITEMS = { { word = "a\0z", abbr = "az", user_data = { laser = { client_id = 1, item = { label = "az" } } } } }
  ]])
  type_keys("ib<F2><C-n>")
  expect.equality(line(), "az")
  expect.equality(child.api.nvim_buf_line_count(0), 1)
end

T["the command-line preview stays above the command line"] = function()
  child.o.lines, child.o.columns = 12, 40
  child.lua([[
    ITEMS[1].user_data.laser.item.documentation = "1\n2\n3"
    UI.configure({ preview = true, max_height = 1 })
  ]])
  type_keys(":b<F2><C-n>")
  local preview = child.lua_get([[vim.api.nvim_win_get_config(UI.preview_win())]])
  -- Row 11 (0-based) holds the command line.
  expect.equality(preview.row + preview.height <= 11, true)
  expect.equality(preview.height, 3)
end

T["leaving Insert mode with Ctrl-C closes the menu"] = function()
  child.lua(
    [[UI.configure({ preview = true }); ITEMS[1].user_data.laser.item.documentation = "docs"]]
  )
  type_keys("ib<F2><C-j>")
  type_keys("<C-c>")
  expect.equality(child.api.nvim_get_mode().mode, "n")
  expect.equality(child.lua_get("UI.visible()"), false)
  expect.equality(child.lua_get("UI.preview_win()"), vim.NIL)
  expect.equality(child.lua_get("CLOSED"), 1)
end

T["confirming right after selecting waits for the insertion"] = function()
  child.lua([[vim.keymap.set("i", "<F6>", function() UI.select(1); UI.confirm() end)]])
  type_keys("ib<F2><F6>")
  child.lua([[require("tests.helpers.settle")()]])
  expect.equality(line(), "bar")
  expect.equality(child.lua_get("CONFIRMED"), { { word = "bar", line = "bar" } })
end

T["several actions in one mapping apply in order"] = function()
  child.lua([[
    vim.keymap.set("i", "<F7>", function() UI.select(1); UI.select(1); UI.confirm() end)
    vim.keymap.set("i", "<F8>", function() UI.select(1); UI.cancel() end)
  ]])
  type_keys("ib<F2><F7>")
  child.lua([[require("tests.helpers.settle")()]])
  expect.equality(line(), "baz")
  expect.equality(child.lua_get("CONFIRMED"), { { word = "baz", line = "baz" } })
  type_keys("<Esc>o")
  type_keys("b<F2><F8>")
  child.lua([[require("tests.helpers.settle")()]])
  expect.equality(line(), "b")
end

T["options changed for insertion are restored when Ctrl-C leaves Insert mode"] = function()
  child.o.backspace = "indent,eol,start"
  type_keys("ib<F2>")
  -- In one input, so <C-c> can discard the keys the insertion queued.
  type_keys("<C-n><C-c>")
  expect.equality(child.api.nvim_get_mode().mode, "n")
  expect.equality(child.o.eventignore, "")
  expect.equality(child.o.backspace, "indent,eol,start")
end

T["scrolling the preview from a mapping keeps the menu open"] = function()
  child.lua([[
    ITEMS[1].user_data.laser.item.documentation = "1\n2\n3\n4"
    UI.configure({ preview = { max_height = 2 } })
    vim.keymap.set("i", "<F9>", function() UI.scroll_preview(1) end)
  ]])
  type_keys("ib<F2><C-j><F9>")
  expect.equality(child.lua_get("UI.visible()"), true)
  expect.equality(child.lua_get([[vim.fn.line("w0", UI.preview_win())]]), 2)
  expect.equality(child.lua_get("CLOSED"), 0)
end

T["typing after a selection makes the typed text the input to restore"] = function()
  -- Manual completion: nothing redraws the menu on text changes.
  type_keys("ib<F2><C-n>")
  type_keys("x")
  expect.equality(line(), "barx")
  expect.equality(child.lua_get("UI.selected()"), 0)
  type_keys("<C-e>")
  expect.equality(line(), "barx")
end

T["automatic paragraph formatting waits until the candidate is inserted"] = function()
  child.bo.formatoptions, child.bo.textwidth = "a", 30
  child.api.nvim_buf_set_lines(0, 0, -1, false, { "before text", "b after text" })
  child.api.nvim_win_set_cursor(0, { 2, 1 })
  type_keys("i<F2><C-n>")
  expect.equality(
    child.api.nvim_buf_get_lines(0, 0, -1, false),
    { "before text", "bar after text" }
  )
  expect.equality(child.bo.formatoptions, "a")
end

T["cancelling in the same input as typing keeps the typed text"] = function()
  type_keys("ib<F2><C-n>")
  -- One batch, so no watcher runs between the typing and the cancellation.
  type_keys("x<C-e>")
  expect.equality(line(), "barx")
end

return T

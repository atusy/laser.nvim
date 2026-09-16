local MiniTest = require("mini.test")
local expect = MiniTest.expect
local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      vim.fn["pum#close"]()
    end,
  },
})

local function candidate(label)
  return {
    word = label,
    abbr = label,
    user_data = { laser = { client_id = 1, item = { label = label } } },
  }
end

T["open shows the candidates in pum.vim and close hides them"] = function()
  local ui = require("laser.ui.pum").new()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "foo.ba" })

  ui.open(5, { candidate("bar"), candidate("baz") }, "i")
  expect.equality(ui.visible(), true)
  expect.equality(vim.fn["pum#complete_info"]().items, { candidate("bar"), candidate("baz") })

  ui.close()
  expect.equality(ui.visible(), false)
end

T["a pum.vim confirm reaches the on_confirm callback with the candidate"] = function()
  local confirmed = {}
  local ui = require("laser.ui.pum").new({
    on_confirm = function(candidate)
      table.insert(confirmed, candidate)
    end,
  })
  ui.open(5, { candidate("bar") }, "i")

  -- What pum.vim does after pum#map#confirm(): sets the item and fires the event.
  vim.g["pum#completed_item"] = candidate("bar")
  vim.g["pum#completed_event"] = "confirm"
  vim.api.nvim_exec_autocmds("User", { pattern = "PumCompleteDone", modeline = false })

  expect.equality(confirmed, { candidate("bar") })
end

T["a plain close is not reported as a confirm"] = function()
  local confirmed = 0
  local ui = require("laser.ui.pum").new({
    on_confirm = function()
      confirmed = confirmed + 1
    end,
  })
  ui.open(5, { candidate("bar") }, "i")
  vim.g["pum#completed_item"] = candidate("bar")
  vim.g["pum#completed_event"] = "complete_done"
  vim.api.nvim_exec_autocmds("User", { pattern = "PumCompleteDone", modeline = false })
  expect.equality(confirmed, 0)
end

T["in-place updates apply column highlights to new tail items"] = function()
  local ui = require("laser.ui.pum").new()
  vim.fn["pum#set_option"]({
    max_height = 1,
    auto_select = false,
    highlight_columns = { kind = "Type" },
  })
  local first, second, third = candidate("bar"), candidate("baz"), candidate("bat")
  first.kind, second.kind, third.kind = "Text", "Text", "Text"
  ui.open(1, { first, second }, "i")
  vim.fn["pum#map#select_relative"](1)
  ui.update(1, { first, second, third }, "i")
  local pum = vim.fn["pum#_get"]()
  local marks = vim.api.nvim_buf_get_extmarks(
    pum.buf,
    pum.namespace,
    { 2, 0 },
    { 2, -1 },
    { details = true }
  )
  local groups = vim.tbl_map(function(mark)
    return mark[4].hl_group
  end, marks)
  expect.equality(vim.list_contains(groups, "Type"), true)
  vim.fn["pum#set_option"]({ max_height = 0, highlight_columns = {} })
end

T["preview resolves selection and ignores answers after switching or closing"] = function()
  local callbacks, cancelled = {}, {}
  local client = {
    supports_method = function()
      return true
    end,
    request = function(_, _, _, callback)
      callbacks[#callbacks + 1] = callback
      return true, #callbacks
    end,
    cancel_request = function(_, id)
      cancelled[#cancelled + 1] = id
    end,
  }
  vim.fn["pum#set_option"]({ preview = true, preview_delay = 0, auto_select = false })
  local ui = require("laser.ui.pum").new({
    preview_context = function()
      return { client = client, bufnr = 1 }
    end,
  })
  local first, second = candidate("foo"), candidate("bar")
  first.user_data.laser.id, second.user_data.laser.id = 1, 2
  ui.open(1, { first, second }, "i")
  vim.fn["pum#map#select_relative"](1)
  vim.fn["pum#map#select_relative"](1)
  expect.equality(cancelled, { 1 })
  callbacks[1](nil, { documentation = "stale" })
  callbacks[2](nil, { detail = "bar()", documentation = "Current docs" })
  expect.equality(vim.fn["pum#current_item"]().info, "bar()\n\nCurrent docs")
  local buf = vim.fn["pum#get_preview_buf"]()
  expect.equality(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "bar()", "", "Current docs" })
  vim.fn["pum#map#select_relative"](-1)
  ui.close()
  callbacks[3](nil, { documentation = "late" })
  expect.equality(cancelled, { 1, 3 })
  expect.equality(vim.fn["pum#preview_visible"](), false)
  vim.fn["pum#set_option"]({ preview = false, preview_delay = 500 })
end

T["preview filetype follows initial MarkupContent and resets for plain text"] = function()
  vim.fn["pum#set_option"]({ preview = true, auto_select = false })
  local ui = require("laser.ui.pum").new()
  local entries = {}
  for i, doc in ipairs({
    { kind = "markdown", value = "**Markdown**" },
    { kind = "plaintext", value = "Plain text" },
    { kind = "markdown", value = "**Markdown again**" },
    "String documentation",
  }) do
    entries[i] = candidate(tostring(i))
    entries[i].user_data.laser.item.documentation = doc
    entries[i].info = type(doc) == "table" and doc.value or doc
  end
  ui.open(1, entries, "i")
  for _, ft in ipairs({ "markdown", "", "markdown", "" }) do
    vim.fn["pum#map#select_relative"](1)
    vim.fn["pum#open_preview"]()
    expect.equality(vim.bo[vim.fn["pum#get_preview_buf"]()].filetype, ft)
  end
  ui.close()
  vim.fn["pum#set_option"]({ preview = false })
end

T["resolved MarkupContent overrides the initial preview filetype"] = function()
  local reply
  local client = {
    supports_method = function()
      return true
    end,
    request = function(_, _, _, callback)
      reply = callback
      return true, 1
    end,
  }
  vim.fn["pum#set_option"]({ preview = true, auto_select = false })
  local ui = require("laser.ui.pum").new({
    preview_context = function()
      return { client = client, bufnr = 1 }
    end,
  })
  for _, kind in ipairs({ "markdown", "plaintext" }) do
    local entry = candidate("foo")
    entry.user_data.laser.item.documentation = {
      kind = kind == "markdown" and "plaintext" or "markdown",
      value = "Initial docs",
    }
    entry.info = "Initial docs"
    ui.open(1, { entry }, "i")
    vim.fn["pum#map#select_relative"](1)
    vim.fn["pum#open_preview"]()
    reply(nil, { documentation = { kind = kind, value = "Resolved docs" } })
    local buf = vim.fn["pum#get_preview_buf"]()
    expect.equality(vim.bo[buf].filetype, kind == "markdown" and "markdown" or "")
    -- pum may redraw later using its own preview timer.
    vim.fn["pum#open_preview"]()
    expect.equality(vim.bo[buf].filetype, kind == "markdown" and "markdown" or "")
    ui.close()
  end
  vim.fn["pum#set_option"]({ preview = false })
end

return T

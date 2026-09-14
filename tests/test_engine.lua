local MiniTest = require("mini.test")
local expect = MiniTest.expect
local fake = require("tests.helpers.fake_server")
local stub_ui = require("tests.helpers.stub_ui")

local T = MiniTest.new_set({ hooks = { post_case = fake.stop_all } })

local Engine = require("laser.engine")

---A document snapshot the engine works on: insert-mode buffer with `line`
---and the cursor at byte column `col`.
local function doc(bufnr, line, col)
  return {
    bufnr = bufnr,
    uri = vim.uri_from_bufnr(bufnr),
    line_nr = 0,
    line = line,
    col = col,
    mode = "i",
  }
end

local function scratch(line)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
  return buf
end

local function wait_opened(ui, n)
  assert(vim.wait(1000, function()
    return #ui.opened >= n
  end), "ui was not opened " .. n .. " times")
end

T["starting a session shows the server's candidates from the keyword start"] = function()
  local buf = scratch("foo.ba")
  fake.start({ name = "one", items = { { label = "bar" }, { label = "baz" }, { label = "qux" } } }, buf)
  local ui = stub_ui.new()
  local engine = Engine.new({ ui = ui, clients = {} })

  engine:start(doc(buf, "foo.ba", 6), { triggerKind = 1 })
  wait_opened(ui, 1)

  expect.equality(ui.last(), { startcol = 5, mode = "i", labels = { "bar", "baz" } })
end

T["a slow client's answer is merged into the open menu"] = function()
  local buf = scratch("foo.ba")
  fake.start({ name = "quick", items = { { label = "bar" } } }, buf)
  fake.start({ name = "slow", items = { { label = "baz" } }, delay_ms = 30 }, buf)
  local ui = stub_ui.new()
  local engine = Engine.new({ ui = ui, clients = {} })

  engine:start(doc(buf, "foo.ba", 6), { triggerKind = 1 })
  wait_opened(ui, 2)

  expect.equality(ui.opened[1].labels, { "bar" })
  expect.equality(ui.opened[2].labels, { "bar", "baz" })
end

T["typing narrows a complete list locally without a new request"] = function()
  local buf = scratch("foo.ba")
  fake.start({ name = "one", items = { { label = "bar" }, { label = "baz" } } }, buf)
  local ui = stub_ui.new()
  local engine = Engine.new({ ui = ui, clients = {} })
  engine:start(doc(buf, "foo.ba", 6), { triggerKind = 1 })
  wait_opened(ui, 1)
  local requests_before = #fake.last.requests

  engine:on_char(doc(buf, "foo.bar", 7), "r")
  vim.wait(50)

  expect.equality(ui.last().labels, { "bar" })
  expect.equality(#fake.last.requests, requests_before)
end

return T

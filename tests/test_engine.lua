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
  assert(
    vim.wait(1000, function()
      return #ui.opened >= n
    end),
    "ui was not opened " .. n .. " times"
  )
end

T["starting a session shows the server's candidates from the keyword start"] = function()
  local buf = scratch("foo.ba")
  fake.start(
    { name = "one", items = { { label = "bar" }, { label = "baz" }, { label = "qux" } } },
    buf
  )
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

T["typing a trigger character re-requests that client and replaces its share"] = function()
  local buf = scratch("foo")
  local calls = 0
  fake.start({
    name = "one",
    trigger_chars = { "." },
    items = function()
      calls = calls + 1
      if calls == 1 then
        return { { label = "foo" } }
      end
      return { { label = "bar" }, { label = "baz" } }
    end,
  }, buf)
  local ui = stub_ui.new()
  local engine = Engine.new({ ui = ui, clients = {} })
  engine:start(doc(buf, "foo", 3), { triggerKind = 1 })
  wait_opened(ui, 1)

  engine:on_char(doc(buf, "foo.", 4), ".")
  vim.wait(100, function()
    return calls == 2 and #ui.opened >= 2
  end)

  local last = fake.last.requests[#fake.last.requests]
  expect.equality(last.params.context, { triggerKind = 2, triggerCharacter = "." })
  expect.equality(ui.last().labels, { "bar", "baz" })
end

T["closing cancels every request still in flight"] = function()
  local buf = scratch("foo.ba")
  fake.start({ name = "a", items = { { label = "bar" } }, delay_ms = 50 }, buf)
  local a = fake.last
  fake.start({ name = "b", items = { { label = "baz" } }, delay_ms = 50 }, buf)
  local b = fake.last
  local ui = stub_ui.new()
  local engine = Engine.new({ ui = ui, clients = {} })
  engine:start(doc(buf, "foo.ba", 6), { triggerKind = 1 })

  engine:close()
  vim.wait(120)

  expect.equality(#ui.opened, 0)
  expect.equality({ a.cancelled_count, b.cancelled_count }, { 1, 1 })
end

T["a newer request supersedes an older request for the same client"] = function()
  local buf = scratch("ba")
  local opts = {
    name = "one",
    items = function(params)
      return {
        isIncomplete = true,
        items = { { label = "candidate" .. params.position.character } },
      }
    end,
  }
  fake.start(opts, buf)
  local ui = stub_ui.new()
  local engine = Engine.new({
    ui = ui,
    clients = { ["*"] = {
      matcher = function()
        return 1
      end,
    } },
  })
  engine:start(doc(buf, "ba", 2), { triggerKind = 1 })
  wait_opened(ui, 1)

  opts.delay_ms = 100
  engine:on_char(doc(buf, "bar", 3), "r")
  opts.delay_ms = 10
  engine:on_char(doc(buf, "barr", 4), "r")
  vim.wait(200)

  expect.equality(ui.last().labels, { "candidate4" })
  expect.equality(fake.last.cancelled_count, 1)
end

T["refresh can suppress incomplete results for one client"] = function()
  local buf = scratch("ba")
  local calls = 0
  fake.start({
    name = "one",
    items = function()
      calls = calls + 1
      return { isIncomplete = true, items = { { label = "bar" } } }
    end,
  }, buf)
  local seen
  local ui = stub_ui.new()
  local engine = Engine.new({
    ui = ui,
    clients = {
      one = {
        refresh = function(ctx)
          seen = ctx
          return false
        end,
      },
    },
  })
  engine:start(doc(buf, "ba", 2), { triggerKind = 1 })
  wait_opened(ui, 1)
  engine:on_char(doc(buf, "bar", 3), "r")
  vim.wait(50)
  expect.equality(calls, 1)
  expect.equality(seen.is_incomplete, true)
  expect.equality(seen.pending, false)
  expect.equality(seen.before_cursor, "bar")
end

T["a new keyword starts fresh even when refresh rejects a trigger"] = function()
  local buf = scratch("foo")
  local calls = 0
  fake.start({
    name = "one",
    trigger_chars = { "." },
    items = function()
      calls = calls + 1
      return { { label = "bar" } }
    end,
  }, buf)
  local engine = Engine.new({
    ui = stub_ui.new(),
    clients = { one = {
      refresh = function()
        return false
      end,
    } },
  })
  engine:start(doc(buf, "foo", 3), { triggerKind = 1 })
  assert(vim.wait(1000, function()
    return engine.session.results[next(engine.session.clients)] ~= nil
  end))
  engine:on_char(doc(buf, "foo.", 4), ".")
  vim.wait(50)
  expect.equality(calls, 2)
  expect.equality(engine.session.startcol, 4)
end

T["a refresh predicate can supersede the first pending response"] = function()
  local buf = scratch("ba")
  fake.start({ name = "one", delay_ms = 50, items = { { label = "bar" } } }, buf)
  local seen = {}
  local engine = Engine.new({
    ui = stub_ui.new(),
    clients = {
      one = {
        refresh = function(ctx)
          table.insert(seen, ctx)
          return true
        end,
      },
    },
  })
  engine:start(doc(buf, "ba", 2), { triggerKind = 1 })
  expect.equality(#seen, 0)
  engine:on_char(doc(buf, "bar", 3), "r")
  expect.equality(seen[1].is_incomplete, nil)
  expect.equality(seen[1].pending, true)
  expect.equality(fake.last.cancelled_count, 1)
  assert(vim.wait(1000, function()
    return next(engine.pending) == nil
  end))
  engine:on_char(doc(buf, "bar", 3), "")
  expect.equality(seen[2].is_incomplete, false)
  expect.equality(seen[2].pending, false)
  expect.equality(seen[1].pending, true)
  engine:close()
end

T["a trigger inside the same keyword refreshes only its client"] = function()
  local buf = scratch("ba")
  local calls = { 0, 0 }
  for i, name in ipairs({ "one", "two" }) do
    fake.start({
      name = name,
      trigger_chars = { "r" },
      items = function()
        calls[i] = calls[i] + 1
        return { { label = "bar" } }
      end,
    }, buf)
  end
  local ui = stub_ui.new()
  local engine = Engine.new({
    ui = ui,
    clients = { two = {
      refresh = function()
        return false
      end,
    } },
  })
  engine:start(doc(buf, "ba", 2), { triggerKind = 1 })
  wait_opened(ui, 2)
  engine:on_char(doc(buf, "bar", 3), "r")
  vim.wait(50)
  expect.equality(calls, { 2, 1 })
end

T["a server cancellation clears pending while preserving accepted results"] = function()
  local buf = scratch("ba")
  local client = fake.start({ name = "one", items = { { label = "bar" } } }, buf)
  local ui = stub_ui.new()
  local engine = Engine.new({
    ui = ui,
    clients = { one = {
      refresh = function()
        return true
      end,
    } },
  })
  engine:start(doc(buf, "ba", 2), { triggerKind = 1 })
  wait_opened(ui, 1)
  local original = fake.last.request
  fake.last.request = function(method, params, callback)
    if method == "textDocument/completion" then
      vim.schedule(function()
        callback({ code = -32800, message = "cancelled" }, nil)
      end)
      return true, 999
    end
    return original(method, params, callback)
  end
  engine:on_char(doc(buf, "bar", 3), "r")
  vim.wait(50)
  expect.equality(engine.pending[client.id], nil)
  expect.equality(ui.last().labels, { "bar" })
end

T["changing one client's options preserves the other client's results"] = function()
  local buf = scratch("ba")
  local calls = { 0, 0 }
  for i, name in ipairs({ "one", "two" }) do
    fake.start({
      name = name,
      items = function()
        calls[i] = calls[i] + 1
        return { { label = "bar" } }
      end,
    }, buf)
  end
  local ui = stub_ui.new()
  local engine = Engine.new({ ui = ui, clients = {} })
  engine:start(doc(buf, "ba", 2), { triggerKind = 1 })
  wait_opened(ui, 2)
  engine.clients_config = { one = { priority = 1 } }
  engine:on_char(doc(buf, "bar", 3), "r")
  vim.wait(50)
  expect.equality(calls, { 2, 1 })
end

T["a request that cannot be sent does not remain pending"] = function()
  local buf = scratch("ba")
  local client = fake.start({ name = "one", items = { { label = "bar" } } }, buf)
  local engine = Engine.new({ ui = stub_ui.new(), clients = {} })
  client.request = function()
    return false
  end
  engine:start(doc(buf, "ba", 2), { triggerKind = 1 })
  expect.equality(engine.pending[client.id], nil)
end

T["timeout cancels only the slow client and preserves its previous result"] = function()
  local buf = scratch("ba")
  local opts = { name = "slow", items = { { label = "bar" } } }
  local client = fake.start(opts, buf)
  local ui = stub_ui.new()
  local engine = Engine.new({ ui = ui, clients = { slow = { timeout_ms = 20 } } })
  engine:start(doc(buf, "ba", 2), { triggerKind = 1 })
  wait_opened(ui, 1)
  opts.items = { { label = "baz" } }
  opts.delay_ms = 100
  engine:request({ client }, { triggerKind = 1 })
  vim.wait(150)
  expect.equality(ui.last().labels, { "bar" })
  expect.equality(engine.pending[client.id], nil)
  expect.equality(fake.last.cancelled_count, 1)
end

T["a superseded request's timeout cannot cancel its replacement"] = function()
  local buf = scratch("ba")
  local opts = { name = "one", delay_ms = 150, items = { { label = "bar" } } }
  local client = fake.start(opts, buf)
  local ui = stub_ui.new()
  local engine = Engine.new({ ui = ui, clients = { one = { timeout_ms = 80 } } })
  engine:start(doc(buf, "ba", 2), { triggerKind = 1 })
  vim.wait(40)
  opts.delay_ms = 60
  engine:request({ client }, { triggerKind = 1 })
  wait_opened(ui, 1)
  expect.equality(ui.last().labels, { "bar" })
  expect.equality(fake.last.cancelled_count, 1)
  expect.equality(engine.pending[client.id], nil)
end

T["a timed-out client does not prevent another client's answer"] = function()
  local buf = scratch("ba")
  local slow = fake.start({ name = "slow", delay_ms = 120, items = { { label = "bar" } } }, buf)
  local quick = fake.start({ name = "quick", delay_ms = 40, items = { { label = "baz" } } }, buf)
  local ui = stub_ui.new()
  local engine =
    Engine.new({ ui = ui, clients = { slow = { timeout_ms = 20 }, quick = { timeout_ms = 0 } } })
  engine:start(doc(buf, "ba", 2), { triggerKind = 1 })
  wait_opened(ui, 1)
  vim.wait(140)
  expect.equality(ui.last().labels, { "baz" })
  expect.equality(engine.session.results[slow.id], nil)
  expect.equality(engine.session.results[quick.id].incomplete, false)
end

T["textEdit chooses the menu boundary and survives further typing"] = function()
  local buf = scratch("foo.ba")
  local calls = 0
  fake.start({
    items = function()
      calls = calls + 1
      return {
        {
          label = "foo.bar",
          textEdit = {
            newText = "foo.bar",
            range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 6 } },
          },
        },
      }
    end,
  }, buf)
  local ui = stub_ui.new()
  local engine = Engine.new({ ui = ui, clients = {} })
  engine:start(doc(buf, "foo.ba", 6), { triggerKind = 1 })
  wait_opened(ui, 1)
  expect.equality(ui.last().startcol, 1)
  engine:on_char(doc(buf, "foo.bar", 7), "r")
  vim.wait(50)
  expect.equality(calls, 1)
  expect.equality(ui.last().labels, { "foo.bar" })
end

return T

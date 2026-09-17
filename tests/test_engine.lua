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
  local engine = Engine.new({ ui = ui, clientOptions = {} })

  engine:start(doc(buf, "foo.ba", 6), { triggerKind = 1 })
  wait_opened(ui, 1)

  expect.equality(ui.last(), { startcol = 5, mode = "i", labels = { "bar", "baz" } })
end

T["max_items limits display without discarding cached candidates"] = function()
  local buf = scratch("b")
  fake.start(
    { name = "one", items = { { label = "bar" }, { label = "bat" }, { label = "baz" } } },
    buf
  )
  local ui = stub_ui.new()
  local engine = Engine.new({ ui = ui, clientOptions = { one = { max_items = 2 } } })
  engine:start(doc(buf, "b", 1), { triggerKind = 1 })
  wait_opened(ui, 1)
  expect.equality(ui.last().labels, { "bar", "bat" })
  engine:on_char(doc(buf, "baz", 3), "z")
  expect.equality(ui.last().labels, { "baz" })
end

T["max_items defaults and overrides limit each client independently"] = function()
  local buf = scratch("b")
  for _, name in ipairs({ "one", "two", "three" }) do
    fake.start({
      name = name,
      items = { { label = "bar" }, { label = "bat" }, { label = "baz" } },
    }, buf)
  end
  local ui = stub_ui.new()
  local engine = Engine.new({
    ui = ui,
    clients = { "one", "two", "three" },
    clientOptions = {
      ["*"] = { max_items = 1 },
      two = { max_items = 2 },
      three = { max_items = 0 },
    },
  })
  engine:start(doc(buf, "b", 1), { triggerKind = 1 })
  wait_opened(ui, 3)
  expect.equality(ui.last().labels, { "bar", "bar", "bat", "bar", "bat", "baz" })
end

T["frozen candidates count toward their client's max_items during streaming"] = function()
  local buf = scratch("b")
  fake.start({ name = "one", manual = true }, buf)
  local server = fake.last
  local ui = stub_ui.new()
  local locked = 0
  ui.frozen_count = function()
    return locked
  end
  ui.update = ui.open
  local engine = Engine.new({ ui = ui, clientOptions = { one = { max_items = 2 } } })
  engine:start(doc(buf, "b", 1), { triggerKind = 1 })
  local token = server.requests[#server.requests].params.partialResultToken
  server.progress(token, { { label = "bar" }, { label = "bat" } })
  wait_opened(ui, 1)
  locked = 1
  server.progress(token, { { label = "baz" } })
  wait_opened(ui, 2)
  expect.equality(ui.last().labels, { "bar", "bat" })
  engine:close()
end

T["a slow client's answer is merged into the open menu"] = function()
  local buf = scratch("foo.ba")
  fake.start({ name = "quick", items = { { label = "bar" } } }, buf)
  fake.start({ name = "slow", items = { { label = "baz" } }, delay_ms = 30 }, buf)
  local ui = stub_ui.new()
  local engine = Engine.new({ ui = ui, clientOptions = {} })

  engine:start(doc(buf, "foo.ba", 6), { triggerKind = 1 })
  wait_opened(ui, 2)

  expect.equality(ui.opened[1].labels, { "bar" })
  expect.equality(ui.opened[2].labels, { "bar", "baz" })
end

T["typing narrows a complete list locally without a new request"] = function()
  local buf = scratch("foo.ba")
  fake.start({ name = "one", items = { { label = "bar" }, { label = "baz" } } }, buf)
  local ui = stub_ui.new()
  local engine = Engine.new({ ui = ui, clientOptions = {} })
  engine:start(doc(buf, "foo.ba", 6), { triggerKind = 1 })
  wait_opened(ui, 1)
  local requests_before = #fake.last.requests

  engine:on_char(doc(buf, "foo.bar", 7), "r")
  vim.wait(50)

  expect.equality(ui.last().labels, { "bar" })
  expect.equality(#fake.last.requests, requests_before)
end

T["an empty response for older input retries the latest input once"] = function()
  local buf = scratch("")
  local client = fake.start({ name = "one", manual = true }, buf)
  local srv = fake.last
  local ui = stub_ui.new()
  local engine = Engine.new({ ui = ui, clientOptions = {} })
  engine:start(doc(buf, "", 0), { triggerKind = 1 })
  local first = engine.pending[client.id]
  local before = #srv.requests
  engine:on_char(doc(buf, "i", 1), "i")
  engine:on_char(doc(buf, "if", 2), "f")
  expect.equality(engine.pending[client.id], first)
  expect.equality(#srv.requests, before)

  srv.respond(nil)
  expect.equality(#srv.requests, before + 1)
  expect.equality(srv.requests[#srv.requests].params.position.character, 2)
  expect.equality(srv.requests[#srv.requests].params.context, { triggerKind = 1 })
  srv.respond({
    { label = "if", insertText = "if ${1:condition} then\n\t$0\nend", insertTextFormat = 2 },
  })
  expect.equality(ui.last().labels, { "if" })
  expect.equality(#srv.requests, before + 1)
  expect.equality(srv.cancelled_count, 0)
end

T["empty current responses wait for the next input instead of looping"] = function()
  local buf = scratch("")
  fake.start({ name = "one", manual = true }, buf)
  local srv = fake.last
  local engine = Engine.new({ ui = stub_ui.new(), clientOptions = {} })
  engine:start(doc(buf, "", 0), { triggerKind = 1 })
  local before = #srv.requests
  srv.respond({})
  expect.equality(#srv.requests, before)
  engine:on_char(doc(buf, "i", 1), "i")
  expect.equality(#srv.requests, before + 1)
  srv.respond({})
  expect.equality(#srv.requests, before + 1)
  engine:on_char(doc(buf, "if", 2), "f")
  expect.equality(#srv.requests, before + 2)
end

T["a custom predicate can reject retries after an older empty response"] = function()
  local buf = scratch("")
  fake.start({ name = "one", manual = true }, buf)
  local srv = fake.last
  local seen
  local engine = Engine.new({
    ui = stub_ui.new(),
    clientOptions = {
      one = {
        refresh = function(ctx)
          seen = ctx
          return false
        end,
      },
    },
  })
  engine:start(doc(buf, "", 0), { triggerKind = 1 })
  local before = #srv.requests
  engine:on_char(doc(buf, "if", 2), "f")
  srv.respond({})
  expect.equality(#srv.requests, before)
  expect.equality(seen.before_cursor, "if")
  expect.equality(seen.pending, false)
  expect.equality(seen.has_candidate, false)
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
  local engine = Engine.new({ ui = ui, clientOptions = {} })
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

T["dynamic trigger characters apply only to matching documents"] = function()
  local buf = scratch("foo")
  vim.bo[buf].filetype = "lua"
  local client = fake.start({ items = { { label = "foo" } } }, buf)
  client.server_capabilities.completionProvider = nil
  client.capabilities.textDocument.completion.dynamicRegistration = true
  client.dynamic_capabilities:register({
    {
      id = "other",
      method = "textDocument/completion",
      registerOptions = {
        documentSelector = { { language = "python" } },
        triggerCharacters = { ":" },
      },
    },
    {
      id = "lua",
      method = "textDocument/completion",
      registerOptions = {
        documentSelector = { { language = "lua" } },
        triggerCharacters = { "." },
      },
    },
  })
  local engine = Engine.new({ ui = stub_ui.new(), clientOptions = {} })
  engine:start(doc(buf, "foo", 3), { triggerKind = 1 })
  engine:on_char(doc(buf, "foo.", 4), ".")
  assert(vim.wait(1000, function()
    local last = fake.last.requests[#fake.last.requests]
    return last.params.context and last.params.context.triggerKind == 2
  end))
  local last = fake.last.requests[#fake.last.requests]
  expect.equality(last.params.context, { triggerKind = 2, triggerCharacter = "." })
  expect.equality(engine.session.clients[client.id].trigger_chars, { "." })
end

T["closing cancels every request still in flight"] = function()
  local buf = scratch("foo.ba")
  fake.start({ name = "a", items = { { label = "bar" } }, delay_ms = 50 }, buf)
  local a = fake.last
  fake.start({ name = "b", items = { { label = "baz" } }, delay_ms = 50 }, buf)
  local b = fake.last
  local ui = stub_ui.new()
  local engine = Engine.new({ ui = ui, clientOptions = {} })
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
    clientOptions = { ["*"] = {
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
    clientOptions = {
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
    clientOptions = { one = {
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
    clientOptions = {
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
    clientOptions = { two = {
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
    clientOptions = { one = {
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
  local engine = Engine.new({ ui = ui, clientOptions = {} })
  engine:start(doc(buf, "ba", 2), { triggerKind = 1 })
  wait_opened(ui, 2)
  engine.client_options = { one = { timeout_ms = 1000 } }
  engine:on_char(doc(buf, "bar", 3), "r")
  vim.wait(50)
  expect.equality(calls, { 2, 1 })
end

T["a request that cannot be sent does not remain pending"] = function()
  local buf = scratch("ba")
  local client = fake.start({ name = "one", items = { { label = "bar" } } }, buf)
  local engine = Engine.new({ ui = stub_ui.new(), clientOptions = {} })
  client.request = function()
    return false
  end
  engine:start(doc(buf, "ba", 2), { triggerKind = 1 })
  expect.equality(engine.pending[client.id], nil)
end

T["typing retries an initial timeout only once while the retry is pending"] = function()
  local buf = scratch("b")
  local client = fake.start({ name = "one", manual = true }, buf)
  local server = fake.last
  local ui = stub_ui.new()
  local engine = Engine.new({ ui = ui, clientOptions = { one = { timeout_ms = 20 } } })
  engine:start(doc(buf, "b", 1), { triggerKind = 1 })
  local session = engine.session
  local late_response = server.respond
  assert(vim.wait(1000, function()
    return engine.pending[client.id] == nil
  end))

  engine:on_char(doc(buf, "ba", 2), "a")
  expect.equality(engine.pending[client.id] ~= nil, true)
  expect.equality(engine.session == session, true)
  local retry = engine.pending[client.id]
  engine:on_char(doc(buf, "bar", 3), "r")
  expect.equality(engine.pending[client.id] == retry, true)
  late_response({ { label = "bad" } })
  expect.equality(engine.session.results[client.id], nil)
  server.respond({ { label = "bar" } })
  wait_opened(ui, 1)
  expect.equality(ui.last().labels, { "bar" })
  engine:on_char(doc(buf, "ba", 2), "")
  expect.equality(engine.pending[client.id], nil)
  engine:close()
end

T["timeout cancels only the slow client and preserves its previous result"] = function()
  local buf = scratch("ba")
  local opts = { name = "slow", items = { { label = "bar" } } }
  local client = fake.start(opts, buf)
  local ui = stub_ui.new()
  local engine = Engine.new({ ui = ui, clientOptions = { slow = { timeout_ms = 20 } } })
  engine:start(doc(buf, "ba", 2), { triggerKind = 1 })
  wait_opened(ui, 1)
  opts.items = { { label = "baz" } }
  opts.delay_ms = 100
  engine:request({ client }, { triggerKind = 1 })
  vim.wait(150)
  expect.equality(ui.last().labels, { "bar" })
  expect.equality(engine.pending[client.id], nil)
  expect.equality(fake.last.cancelled_count, 1)
  opts.manual = true
  engine:on_char(doc(buf, "bar", 3), "r")
  expect.equality(engine.pending[client.id] ~= nil, true)
  expect.equality(ui.last().labels, { "bar" })
  engine:close()
end

T["custom refresh controls timeout retries using independent snapshots"] = function()
  local buf = scratch("b")
  local client = fake.start({ name = "one", manual = true }, buf)
  local seen, retry = {}, false
  local engine = Engine.new({
    ui = stub_ui.new(),
    clientOptions = {
      one = {
        timeout_ms = 20,
        refresh = function(ctx)
          seen[#seen + 1] = ctx
          return retry and ctx.timed_out
        end,
      },
    },
  })
  engine:start(doc(buf, "b", 1), { triggerKind = 1 })
  engine:on_char(doc(buf, "ba", 2), "a")
  expect.equality(seen[1].timed_out, false)
  assert(vim.wait(1000, function()
    return engine.pending[client.id] == nil
  end))
  engine:on_char(doc(buf, "bar", 3), "r")
  expect.equality(seen[2].timed_out, true)
  expect.equality(engine.pending[client.id], nil)
  retry = true
  engine:on_char(doc(buf, "bars", 4), "s")
  expect.equality(engine.pending[client.id] ~= nil, true)
  engine:on_char(doc(buf, "barst", 5), "t")
  expect.equality(seen[4].timed_out, false)
  expect.equality(seen[2].timed_out, true)
  engine:close()
  engine:start(doc(buf, "b", 1), { triggerKind = 1 })
  engine:on_char(doc(buf, "ba", 2), "a")
  expect.equality(seen[5].timed_out, false)
  engine:close()
end

T["a superseded request's timeout cannot cancel its replacement"] = function()
  local buf = scratch("ba")
  local opts = { name = "one", delay_ms = 150, items = { { label = "bar" } } }
  local client = fake.start(opts, buf)
  local ui = stub_ui.new()
  local engine = Engine.new({ ui = ui, clientOptions = { one = { timeout_ms = 80 } } })
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
  local engine = Engine.new({
    ui = ui,
    clientOptions = { slow = { timeout_ms = 20 }, quick = { timeout_ms = 0 } },
  })
  engine:start(doc(buf, "ba", 2), { triggerKind = 1 })
  wait_opened(ui, 1)
  vim.wait(140)
  expect.equality(ui.last().labels, { "baz" })
  expect.equality(engine.session.results[slow.id], nil)
  expect.equality(engine.session.results[quick.id].incomplete, false)
  expect.equality(engine.session:refresh_context(slow.id, engine.doc, "", false).timed_out, true)
  expect.equality(engine.session:refresh_context(quick.id, engine.doc, "", false).timed_out, false)
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
  local engine = Engine.new({ ui = ui, clientOptions = {} })
  engine:start(doc(buf, "foo.ba", 6), { triggerKind = 1 })
  wait_opened(ui, 1)
  expect.equality(ui.last().startcol, 1)
  engine:on_char(doc(buf, "foo.bar", 7), "r")
  vim.wait(50)
  expect.equality(calls, 1)
  expect.equality(ui.last().labels, { "foo.bar" })
end

T["streamed candidates survive null completion and retain list defaults"] = function()
  local buf = scratch("ba")
  local client = fake.start({ manual = true }, buf)
  local server = fake.last
  local ui = stub_ui.new()
  local engine = Engine.new({ ui = ui, clientOptions = {} })
  engine:start(doc(buf, "ba", 2), { triggerKind = 1 })
  local token = server.requests[#server.requests].params.partialResultToken
  server.progress(
    token,
    { isIncomplete = true, itemDefaults = { data = "shared" }, items = { { label = "baz" } } }
  )
  wait_opened(ui, 1)
  expect.equality(engine.pending[client.id] ~= nil, true)
  server.progress(token, { { label = "bar" } })
  wait_opened(ui, 2)
  expect.equality(ui.last().labels, { "baz", "bar" })
  server.respond(nil)
  assert(vim.wait(100, function()
    return engine.pending[client.id] == nil
  end))
  expect.equality(ui.last().labels, { "baz", "bar" })
  local result = engine.session.results[client.id]
  expect.equality(result.incomplete, true)
  expect.equality(result.candidates[2].user_data.laser.item.data, "shared")
end

T["selection freezes the seen prefix across clients and typing releases it"] = function()
  local buf = scratch("b")
  fake.start(
    { name = "quick", items = { { label = "bb" }, { label = "bc" }, { label = "bz" } } },
    buf
  )
  fake.start({ name = "slow", manual = true }, buf)
  local server = fake.last
  local ui = stub_ui.new()
  local locked = 0
  ui.frozen_count = function()
    return locked
  end
  ui.update = ui.open
  ui.reset = function()
    locked = 0
  end
  local engine = Engine.new({ ui = ui, clients = { "slow", "*" } })
  engine:start(doc(buf, "b", 1), { triggerKind = 1 })
  wait_opened(ui, 1)
  locked = 2
  local token = server.requests[#server.requests].params.partialResultToken
  server.progress(token, { { label = "ba" } })
  wait_opened(ui, 2)
  expect.equality(ui.last().labels, { "bb", "bc", "ba", "bz" })
  locked = 3
  server.progress(token, { { label = "b0" } })
  wait_opened(ui, 3)
  expect.equality(ui.last().labels, { "bb", "bc", "ba", "b0", "bz" })
  engine:on_char(doc(buf, "", 0), "")
  expect.equality(ui.last().labels, { "ba", "b0", "bb", "bc", "bz" })
end

T["partial bursts from multiple clients share one render"] = function()
  local buf = scratch("b")
  fake.start({ name = "one", manual = true }, buf)
  local one = fake.last
  fake.start({ name = "two", manual = true }, buf)
  local two = fake.last
  local ui = stub_ui.new()
  local engine = Engine.new({ ui = ui, clientOptions = {} })
  engine:start(doc(buf, "b", 1), { triggerKind = 1 })
  one.progress(one.requests[#one.requests].params.partialResultToken, { { label = "bb" } })
  two.progress(two.requests[#two.requests].params.partialResultToken, { { label = "bc" } })
  one.progress(one.requests[#one.requests].params.partialResultToken, { { label = "ba" } })
  vim.wait(50)
  expect.equality(#ui.opened, 1)
  expect.equality(ui.last().labels, { "bb", "ba", "bc" })
end

T["a timed out partial list is retried on further input"] = function()
  local buf = scratch("b")
  local client = fake.start({ name = "one", manual = true }, buf)
  local server = fake.last
  local ui = stub_ui.new()
  local engine = Engine.new({ ui = ui, clientOptions = { one = { timeout_ms = 50 } } })
  engine:start(doc(buf, "b", 1), { triggerKind = 1 })
  local token = server.requests[#server.requests].params.partialResultToken
  server.progress(token, { { label = "bar" } })
  wait_opened(ui, 1)
  assert(vim.wait(500, function()
    return engine.pending[client.id] == nil
  end))
  expect.equality(ui.last().labels, { "bar" })
  local before = #server.requests
  engine:on_char(doc(buf, "ba", 2), "a")
  expect.equality(#server.requests, before + 1)
  server.progress(token, { { label = "bad" } })
  vim.wait(20)
  expect.equality(ui.last().labels, { "bar" })
end

T["earlier edit boundaries wait until typing releases the frozen menu"] = function()
  local buf = scratch("foo.b")
  fake.start({ manual = true }, buf)
  local server = fake.last
  local ui = stub_ui.new()
  local frozen = 0
  ui.frozen_count = function()
    return frozen
  end
  ui.reset = function()
    frozen = 0
  end
  ui.update = ui.open
  local engine = Engine.new({ ui = ui, clientOptions = {} })
  engine:start(doc(buf, "foo.b", 5), { triggerKind = 1 })
  local token = server.requests[#server.requests].params.partialResultToken
  server.progress(token, { { label = "bar" } })
  wait_opened(ui, 1)
  frozen = 1
  server.progress(token, {
    {
      label = "foo.baz",
      textEdit = {
        newText = "foo.baz",
        range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 5 } },
      },
    },
  })
  wait_opened(ui, 2)
  expect.equality(ui.last(), { startcol = 5, mode = "i", labels = { "bar" } })
  engine:on_char(doc(buf, "foo.ba", 6), "a")
  expect.equality(ui.last().startcol, 1)
  expect.equality(#ui.last().labels, 2)
end

T["reordering clients preserves cached results and pending requests"] = function()
  local buf = scratch("b")
  local one = fake.start({ name = "one", manual = true }, buf)
  local first = fake.last
  local two = fake.start({ name = "two", manual = true }, buf)
  local second = fake.last
  local ui = stub_ui.new()
  local engine = Engine.new({ ui = ui, clients = { "one", "two" } })
  engine:start(doc(buf, "b", 1), { triggerKind = 1 })
  first.respond({ { label = "bar" } })
  local cached = engine.session.results[one.id]
  local pending = engine.pending[two.id]
  local counts = { #first.requests, #second.requests }
  engine.clients = { "two", "one" }
  engine:on_char(doc(buf, "b", 1), "")
  expect.equality(engine.session.results[one.id] == cached, true)
  expect.equality(engine.pending[two.id] == pending, true)
  expect.equality({ #first.requests, #second.requests }, counts)
  second.respond({ { label = "baz" } })
  expect.equality(ui.last().labels, { "baz", "bar" })
  engine.clients = { "one", "two" }
  engine:on_char(doc(buf, "b", 1), "")
  expect.equality(ui.last().labels, { "bar", "baz" })
  expect.equality({ #first.requests, #second.requests }, counts)
end

T["removing a selected client cancels its request and ignores its late response"] = function()
  local buf = scratch("b")
  local one = fake.start({ name = "one", manual = true }, buf)
  local first = fake.last
  local two = fake.start({ name = "two", manual = true }, buf)
  local second = fake.last
  local ui = stub_ui.new()
  local engine = Engine.new({ ui = ui })
  engine:start(doc(buf, "b", 1), { triggerKind = 1 })
  first.respond({ { label = "bar" } })
  local cached = engine.session.results[one.id]
  engine.clients = { "one" }
  engine:on_char(doc(buf, "b", 1), "")
  expect.equality(second.cancelled_count, 1)
  expect.equality(engine.pending[two.id], nil)
  expect.equality(engine.session.results[one.id] == cached, true)
  second.respond({ { label = "baz" } })
  expect.equality(ui.last().labels, { "bar" })
end

return T

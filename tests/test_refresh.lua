local MiniTest = require("mini.test")
local expect = MiniTest.expect
local T = MiniTest.new_set()
local laser = require("laser")
local Session = require("laser.session")

T["helpers inspect the snapshot without consulting the editor"] = function()
  local ctx = { inserted_char = "。", trigger_characters = { "。" }, before_cursor = "obj。" }
  expect.equality(laser.hasTriggerCharacter(ctx), true)
  expect.equality(laser.hasPattern(ctx, "。$"), true)
  expect.equality(laser.hasPattern(ctx, "[.:]$"), false)
  ctx.inserted_char = ""
  expect.equality(laser.hasTriggerCharacter(ctx), false)
  expect.equality(laser.hasPattern(ctx, "。$"), true)
end

T["contexts preserve nil and false and do not expose mutable session tables"] = function()
  local s =
    Session.new({ startcol = 0, clients = { [7] = { name = "one", trigger_chars = { "." } } } })
  local doc = { bufnr = 9, mode = "c", line = "echo.suffix", col = 5 }
  local first = s:refresh_context(7, doc, ".", true)
  expect.equality(first, {
    client_id = 7,
    client_name = "one",
    bufnr = 9,
    mode = "c",
    before_cursor = "echo.",
    inserted_char = ".",
    trigger_characters = { "." },
    pending = true,
    timed_out = false,
  })
  s:set_result(7, {}, {})
  local second = s:refresh_context(7, doc, "", false)
  expect.equality(second.is_incomplete, false)
  expect.equality(first.is_incomplete, nil)
  expect.equality(first.pending, true)
  first.trigger_characters[1] = ":"
  expect.equality(s.clients[7].trigger_chars, { "." })
  expect.equality(second.trigger_characters, { "." })
end

return T

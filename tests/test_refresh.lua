local MiniTest = require("mini.test")
local expect = MiniTest.expect
local T = MiniTest.new_set()
local refresh = require("laser.refresh")
local Session = require("laser.session")

T["helpers inspect the snapshot without consulting the editor"] = function()
  local ctx = { inserted_char = "。", trigger_characters = { "。" }, before_cursor = "obj。" }
  expect.equality(refresh.hasTriggerCharacter(ctx), true)
  expect.equality(refresh.hasPattern(ctx, "。$"), true)
  expect.equality(refresh.hasPattern(ctx, "[.:]$"), false)
  ctx.inserted_char = ""
  expect.equality(refresh.hasTriggerCharacter(ctx), false)
  expect.equality(refresh.hasPattern(ctx, "。$"), true)
end

T["extendsPreviousInput compares prefixes including identical and multibyte input"] = function()
  for _, case in ipairs({
    { "git re", "git rev", true },
    { "git rev", "git rev", true },
    { "git rev", "git re", false },
    { "git rev", "git cat", false },
    { "git rev", "git checkout", false },
    { "", "c", true },
    { "日本", "日本語", true },
    { "日本語", "日本", false },
  }) do
    expect.equality(
      refresh.extendsPreviousInput({
        previous_before_cursor = case[1],
        before_cursor = case[2],
      }),
      case[3]
    )
  end
  expect.equality(refresh.extendsPreviousInput({ before_cursor = "git c" }), false)
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
    has_candidate = false,
    timed_out = false,
    interrupted = false,
  })
  s:set_result(7, {}, {})
  local second = s:refresh_context(7, doc, "", false, { line = "ech.suffix", col = 3 })
  expect.equality(second.previous_before_cursor, "ech")
  expect.equality(first.previous_before_cursor, nil)
  expect.equality(second.is_incomplete, false)
  expect.equality(first.is_incomplete, nil)
  expect.equality(first.pending, true)
  expect.equality(refresh.has_candidate(first), false)
  first.trigger_characters[1] = ":"
  expect.equality(s.clients[7].trigger_chars, { "." })
  expect.equality(second.trigger_characters, { "." })
end

return T

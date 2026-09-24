local MiniTest = require("mini.test")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["resolve supplies detail and documentation"] = function()
  local callback
  local client = {
    supports_method = function()
      return true
    end,
    request = function(_, method, item, cb, bufnr)
      eq(method, "completionItem/resolve")
      eq(item.label, "foo")
      eq(bufnr, 12)
      callback = cb
      return true, 1
    end,
  }
  local shown
  require("laser.preview").resolve({ label = "foo" }, client, 12, function(info)
    shown = info
  end)
  callback(nil, {
    label = "foo",
    detail = "foo(): string",
    documentation = { kind = "markdown", value = "Docs" },
  })
  eq(shown, "foo(): string\n\nDocs")
end

T["resolve treats JSON null fields as absent"] = function()
  local callback
  local client = {
    supports_method = function()
      return true
    end,
    request = function(_, _, _, cb)
      callback = cb
      return true, 1
    end,
  }
  local shown
  require("laser.preview").resolve({ label = "foo", detail = "kept" }, client, 12, function(info)
    shown = info
  end)
  callback(nil, { label = "foo", detail = vim.NIL, documentation = vim.NIL })
  eq(shown, "kept")
end

return T

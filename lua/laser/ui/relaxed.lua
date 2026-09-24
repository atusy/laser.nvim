---Options relaxed while the menu feeds keys, so each fed key deletes or
---types exactly one character.
local M = {}

local saved -- options to restore once fed insertion keys are done
-- Options that change what one typed <BS> or character does, with the values
-- that make fed keys behave like deleting and typing plain characters.
-- A function derives the value from the user's.
local RELAXED = {
  global = {
    backspace = "indent,start",
    smarttab = false,
    -- Hooks such as auto-pairs would rewrite the candidate's characters.
    eventignore = function(value)
      return value == "" and "InsertCharPre" or value .. ",InsertCharPre"
    end,
  },
  buffer = {
    cinkeys = "",
    indentkeys = "",
    softtabstop = 0,
    varsofttabstop = "",
    -- Paragraph reflow on each key would move text across the backspaces.
    formatoptions = function(value)
      return (value:gsub("a", ""))
    end,
  },
}

function M.restore()
  if not saved then
    return
  end
  for name, value in pairs(saved.global) do
    vim.o[name] = value
  end
  if vim.api.nvim_buf_is_valid(saved.buf) then
    for name, value in pairs(saved.buffer) do
      vim.bo[saved.buf][name] = value
    end
  end
  saved = nil
end

---Let backspaces remove exactly one character each, including text typed
---before this insertion, and keep typed candidates from reindenting or
---being rewritten.
function M.relax()
  local target = vim.api.nvim_get_current_buf()
  if not saved then
    saved = { buf = target, global = {}, buffer = {} }
    for name in pairs(RELAXED.global) do
      saved.global[name] = vim.o[name]
    end
    for name in pairs(RELAXED.buffer) do
      saved.buffer[name] = vim.bo[target][name]
    end
    -- The fed keys, and the restore queued behind them, can be discarded.
    vim.api.nvim_create_autocmd({ "TextChangedI", "InsertLeave" }, {
      once = true,
      callback = M.restore,
    })
  end
  for name, value in pairs(RELAXED.global) do
    if type(value) == "function" then
      value = value(saved.global[name])
    end
    vim.o[name] = value
  end
  for name, value in pairs(RELAXED.buffer) do
    if type(value) == "function" then
      value = value(saved.buffer[name])
    end
    vim.bo[target][name] = value
  end
end

return M

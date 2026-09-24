---Keys fed on the user's behalf, with callbacks that run once the keys
---queued before them have been processed.
local M = {}

-- Callbacks queued behind fed keys, keyed by a serial number, with the owner
-- that queued them.
local pending, serial = {}, 0 ---@type table<integer, { owner: table, fn: fun() }>, integer

---@param id integer
function M._run(id)
  local callback = pending[id]
  pending[id] = nil
  if callback then
    callback.fn()
  end
end

---Drop the callbacks `owner` queued; their keys were discarded or no longer
---apply, and running them later would act on a state that moved on.
---@param owner table
function M.forget(owner)
  for id, callback in pairs(pending) do
    if callback.owner == owner then
      pending[id] = nil
    end
  end
end

---@return integer
function M.pending_count()
  return vim.tbl_count(pending)
end

---Feed keys that run `callback` once every key queued before it is processed.
---Keys are inserted in front of typeahead, so they are fed in reverse order.
---@param owner table what queues the keys, for forget()
---@param parts { [1]: string, [2]: boolean }[] key strings with their escape_ks flag
---@param callback fun()
function M.feed(owner, parts, callback)
  serial = serial + 1
  pending[serial] = { owner = owner, fn = callback }
  local run =
    vim.keycode(string.format("<Cmd>lua require('laser.ui.feedkeys')._run(%d)<CR>", serial))
  vim.api.nvim_feedkeys(run, "in", false)
  for i = #parts, 1, -1 do
    vim.api.nvim_feedkeys(parts[i][1], "in", parts[i][2])
  end
end

---Keys that replace `current`, the text just before the cursor, with
---`text` as if typed.
---@param current string
---@param text string without NUL bytes, which keys cannot carry
---@return { [1]: string, [2]: boolean }[] parts for feed()
function M.replacement(current, text)
  -- One <BS> removes a character with its composing characters unless
  -- 'delcombine' makes it remove them one at a time.
  local chars = vim.fn.strchars(current, vim.o.delcombine and 0 or 1)
  -- Typed control characters act as keys, such as <Tab> under 'expandtab';
  -- <C-v> inserts them as they are. Newlines are meant to split the line.
  local typed = text:gsub("[\1-\9\11-\31\127]", "\22%0")
  return { { vim.keycode("<BS>"):rep(chars), false }, { typed, true } }
end

return M

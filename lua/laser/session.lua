local items = require("laser.items")
local match = require("laser.match")

---@class laser.SessionClient
---@field name string
---@field opts? table resolved per-client options (matcher, sorter, priority)
---@field trigger_chars? string[]

---@class laser.Session
---@field startcol integer
---@field clients table<integer, laser.SessionClient>
---@field results table<integer, { candidates: table[], incomplete: boolean }>
local Session = {}
Session.__index = Session

---@param opts { startcol: integer, clients: table<integer, laser.SessionClient> }
---@return laser.Session
function Session.new(opts)
  return setmetatable({
    startcol = opts.startcol,
    clients = opts.clients,
    results = {},
  }, Session)
end

---@param result lsp.CompletionList|lsp.CompletionItem[]|nil
---@return lsp.CompletionItem[], boolean
local function unpack_result(result)
  if result == nil then
    return {}, false
  end
  if result.items then
    return result.items, result.isIncomplete == true
  end
  return result, false
end

---@param client_id integer
---@param result lsp.CompletionList|lsp.CompletionItem[]|nil
---@param ctx laser.ConvertContext
function Session:set_result(client_id, result, ctx)
  local lsp_items, incomplete = unpack_result(result)
  local candidates = {}
  for _, item in ipairs(lsp_items) do
    table.insert(candidates, items.convert(item, ctx))
  end
  self.results[client_id] = { candidates = candidates, incomplete = incomplete }
end

---@return integer[]
function Session:ordered_client_ids()
  local ids = vim.tbl_keys(self.results)
  table.sort(ids)
  return ids
end

---@param prefix string
---@return table[]
function Session:candidates(prefix)
  local merged = {}
  for _, client_id in ipairs(self:ordered_client_ids()) do
    local opts = self.clients[client_id].opts or {}
    local matched = match.apply(self.results[client_id].candidates, prefix, opts)
    vim.list_extend(merged, matched)
  end
  return merged
end

return Session

local items = require("laser.items")
local match = require("laser.match")
local refresh = require("laser.refresh")

---@class laser.SessionClient
---@field name string
---@field opts? table resolved per-client options (matcher, sorter, priority, refresh)
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

---@param client laser.SessionClient
---@return number
local function priority(client)
  return (client.opts or {}).priority or 0
end

---Higher priority first; equal priorities fall back to client id for stability.
---@return integer[]
function Session:ordered_client_ids()
  local ids = vim.tbl_keys(self.results)
  table.sort(ids, function(a, b)
    local pa, pb = priority(self.clients[a]), priority(self.clients[b])
    if pa ~= pb then
      return pa > pb
    end
    return a < b
  end)
  return ids
end

---Build a new snapshot for each predicate invocation. No internal result or
---trigger-character table is exposed to the callback.
---@param client_id integer
---@param doc laser.Doc
---@param char string
---@param pending boolean
---@return laser.RefreshContext
function Session:refresh_context(client_id, doc, char, pending)
  local client = self.clients[client_id]
  local result = self.results[client_id]
  return {
    client_id = client_id,
    client_name = client.name,
    bufnr = doc.bufnr,
    mode = doc.mode,
    before_cursor = doc.line:sub(1, doc.col),
    inserted_char = char,
    trigger_characters = vim.list_slice(client.trigger_chars or {}),
    is_incomplete = result and result.incomplete,
    pending = pending,
  }
end

---Decide independently for each client whether to replace its cached results.
---@param char string
---@param doc laser.Doc
---@param pending table<integer, any>
---@return table<integer, lsp.CompletionContext>
function Session:on_char(char, doc, pending)
  local requests = {}
  for client_id, client in pairs(self.clients) do
    local ctx = self:refresh_context(client_id, doc, char, pending[client_id] ~= nil)
    -- Compute protocol metadata before calling user code, which may mutate ctx.
    local lsp_context = refresh.lsp_context(ctx)
    local predicate = (client.opts or {}).refresh or refresh.default
    if predicate(ctx) then
      requests[client_id] = lsp_context
    end
  end
  return requests
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

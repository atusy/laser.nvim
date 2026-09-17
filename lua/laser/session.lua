local items = require("laser.items")
local filter = require("laser.filter")
local refresh = require("laser.refresh")

---@class laser.SessionClient
---@field name string
---@field order? integer position in the selected client list
---@field opts? table resolved per-client options (filters, matcher, sorter, refresh)
---@field trigger_chars? string[]
---@field timed_out? boolean last request timed out; cleared when a new request starts

---@class laser.Session
---@field startcol integer common menu boundary
---@field keyword_start integer fallback and session validity boundary
---@field clients table<integer, laser.SessionClient>
---@field results table<integer, { candidates: table[], incomplete: boolean, defaults?: table }>
---@field next_id integer stable candidate identity within the session
local Session = {}
Session.__index = Session

---@param opts { startcol: integer, clients: table<integer, laser.SessionClient> }
---@return laser.Session
function Session.new(opts)
  return setmetatable({
    startcol = opts.startcol,
    keyword_start = opts.startcol,
    clients = opts.clients,
    results = {},
    next_id = 0,
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
---@param append? boolean append to this request's accepted batches
function Session:set_result(client_id, result, ctx, append)
  local lsp_items, incomplete = unpack_result(result)
  local previous = append and self.results[client_id]
  local candidates = previous and previous.candidates or {}
  local defaults = result and result.itemDefaults or previous and previous.defaults
  if previous and not (result and result.items) then
    incomplete = previous.incomplete
  end
  for _, item in ipairs(lsp_items) do
    item = items.with_defaults(item, defaults)
    local startcol = items.start_col(item, ctx)
    local item_ctx = vim.tbl_extend("force", ctx, { startcol = startcol })
    local candidate = items.convert(item, item_ctx)
    candidate.user_data.laser.startcol = startcol
    self.next_id = self.next_id + 1
    candidate.user_data.laser.id = self.next_id
    table.insert(candidates, candidate)
  end
  self.results[client_id] =
    { candidates = candidates, incomplete = incomplete, defaults = defaults }
end

---Follow the selected client order, using client id as a stable fallback.
---@return integer[]
function Session:ordered_client_ids()
  local ids = vim.tbl_keys(self.results)
  table.sort(ids, function(a, b)
    local pa, pb = self.clients[a].order or a, self.clients[b].order or b
    if pa ~= pb then
      return pa < pb
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
    has_candidate = #self:client_candidates(client_id, "", doc) > 0,
    timed_out = client.timed_out == true,
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

---Filter one client's cached items without consulting other clients or the UI.
---@param client_id integer
---@param prefix string
---@param doc? laser.Doc
---@param projection? { exclude: table<integer, boolean>, startcol: integer }
---@return table[]
function Session:client_candidates(client_id, prefix, doc, projection)
  local opts = self.clients[client_id].opts or {}
  local input = doc
      and function(candidate)
        return doc.line:sub(candidate.user_data.laser.startcol + 1, doc.col)
      end
    or prefix
  local result = self.results[client_id]
  local candidates = result and result.candidates or {}
  if projection then
    candidates = vim.tbl_filter(function(candidate)
      local data = candidate.user_data.laser
      return not projection.exclude[data.id] and data.startcol >= projection.startcol
    end, candidates)
  end
  return filter.apply(candidates, input, opts)
end

---@param prefix string
---@param doc? laser.Doc
---@param projection? { exclude: table<integer, boolean>, startcol: integer }
---@return table[]
---@return integer? startcol
function Session:candidates(prefix, doc, projection)
  local merged = {}
  for _, client_id in ipairs(self:ordered_client_ids()) do
    local matched = self:client_candidates(client_id, prefix, doc, projection)
    vim.list_extend(merged, matched)
  end
  if not doc or (#merged == 0 and not projection) then
    return merged
  end
  local startcol = projection and projection.startcol or doc.col
  for _, candidate in ipairs(merged) do
    startcol = math.min(startcol, candidate.user_data.laser.startcol)
  end
  -- Pad a display copy; cached words remain relative to each item's edit start.
  for i, candidate in ipairs(merged) do
    local own_start = candidate.user_data.laser.startcol
    if own_start > startcol then
      local prefix = doc.line:sub(startcol + 1, own_start)
      merged[i] = vim.tbl_extend("force", candidate, {
        word = prefix .. candidate.word,
        abbr = prefix .. (candidate.abbr or candidate.word),
        highlights = vim.deepcopy(candidate.highlights or {}),
      })
      for _, hl in ipairs(merged[i].highlights or {}) do
        if hl.type == "abbr" then
          hl.col = (hl.col or 1) + #prefix
        end
      end
      table.insert(merged[i].highlights, {
        name = "laser_prefix",
        type = "abbr",
        col = 1,
        width = #prefix,
        hl_group = "Comment",
      })
    end
  end
  return merged, startcol
end

return Session

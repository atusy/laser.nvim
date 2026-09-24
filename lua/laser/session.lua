local items = require("laser.items")
local filter = require("laser.filter")
local refresh = require("laser.refresh")

---@class laser.SessionClient
---@field name string
---@field order? integer position in the selected client list
---@field opts? table resolved per-client options (filters, matcher, sorter, refresh)
---@field trigger_chars? string[]
---@field timed_out? boolean last request timed out; cleared when a new request starts
---@field interrupted? boolean last request ended before its final answer; cleared when a new request starts

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
  result = items.drop_null(result)
  local lsp_items, incomplete = unpack_result(result)
  local previous = append and self.results[client_id]
  local candidates = previous and previous.candidates or {}
  local defaults = result and result.itemDefaults or previous and previous.defaults
  if previous and not (result and result.items) then
    incomplete = previous.incomplete
  end
  -- Reused per item: conversion reads the context but does not retain it.
  local item_ctx = vim.tbl_extend("force", {}, ctx)
  for _, item in ipairs(lsp_items) do
    -- The label is the one field every item needs; skip malformed ones.
    if type(item) == "table" and type(item.label) == "string" then
      item = items.with_defaults(item, defaults)
      local startcol = items.start_col(item, ctx)
      item_ctx.startcol = startcol
      local candidate = items.convert(item, item_ctx)
      candidate.user_data.laser.startcol = startcol
      self.next_id = self.next_id + 1
      candidate.user_data.laser.id = self.next_id
      table.insert(candidates, candidate)
    end
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
---@param previous_doc? laser.Doc
---@return laser.RefreshContext
function Session:refresh_context(client_id, doc, char, pending, previous_doc)
  local client = self.clients[client_id]
  local result = self.results[client_id]
  return {
    client_id = client_id,
    client_name = client.name,
    bufnr = doc.bufnr,
    mode = doc.mode,
    before_cursor = doc.line:sub(1, doc.col),
    previous_before_cursor = previous_doc and previous_doc.line:sub(1, previous_doc.col),
    inserted_char = char,
    trigger_characters = vim.list_slice(client.trigger_chars or {}),
    is_incomplete = result and result.incomplete,
    pending = pending,
    has_candidate = self:has_candidate(client_id, doc),
    timed_out = client.timed_out == true,
    interrupted = client.interrupted == true,
  }
end

---Decide independently for each client whether to replace its cached results.
---@param char string
---@param doc laser.Doc
---@param pending table<integer, any>
---@param previous_doc? laser.Doc
---@return table<integer, lsp.CompletionContext>
function Session:on_char(char, doc, pending, previous_doc)
  local requests = {}
  for client_id, client in pairs(self.clients) do
    local ctx = self:refresh_context(client_id, doc, char, pending[client_id] ~= nil, previous_doc)
    -- Compute protocol metadata before calling user code, which may mutate ctx.
    local lsp_context = refresh.lsp_context(ctx)
    local predicate = (client.opts or {}).refresh or refresh.default
    if predicate(ctx) then
      requests[client_id] = lsp_context
    end
  end
  return requests
end

---Each candidate matches the text between its own edit start and the cursor.
---@param doc laser.Doc
---@return fun(candidate: table): string
local function input_at(doc)
  return function(candidate)
    return doc.line:sub(candidate.user_data.laser.startcol + 1, doc.col)
  end
end

---@param client_id integer
---@param doc laser.Doc
---@return boolean
function Session:has_candidate(client_id, doc)
  local result = self.results[client_id]
  return filter.any(
    result and result.candidates or {},
    input_at(doc),
    self.clients[client_id].opts or {}
  )
end

---Rows the menu keeps in place while more candidates arrive.
---@class laser.Projection
---@field exclude table<integer, boolean> ids of the kept rows
---@field used? table<integer, integer> kept rows per client, counted against max_items
---@field startcol integer menu start of the kept rows

---Filter one client's cached items without consulting other clients or the UI.
---Only the first max_items survivors are converted and returned.
---@param client_id integer
---@param doc laser.Doc
---@param projection? laser.Projection
---@return table[]
function Session:client_candidates(client_id, doc, projection)
  local opts = self.clients[client_id].opts or {}
  local input = input_at(doc)
  local result = self.results[client_id]
  local candidates = result and result.candidates or {}
  if projection then
    candidates = vim.tbl_filter(function(candidate)
      local data = candidate.user_data.laser
      return not projection.exclude[data.id] and data.startcol >= projection.startcol
    end, candidates)
  end
  local limit = opts.max_items
  if limit and limit > 0 and projection then
    limit = limit - (projection.used and projection.used[client_id] or 0)
    if limit <= 0 then
      return {}
    end
  end
  return filter.apply(candidates, input, opts, limit)
end

---Each candidate is matched against the text from its own start to the
---cursor in `doc`.
---@param doc laser.Doc
---@param projection? laser.Projection
---@return table[]
---@return integer? startcol
function Session:candidates(doc, projection)
  local merged = {}
  for _, client_id in ipairs(self:ordered_client_ids()) do
    local matched = self:client_candidates(client_id, doc, projection)
    vim.list_extend(merged, matched)
  end
  if #merged == 0 and not projection then
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

local clients_mod = require("laser.clients")
local position = require("laser.position")
local request = require("laser.request")
local refresh = require("laser.refresh")
local Session = require("laser.session")

---@class laser.Doc Snapshot of the text being completed.
---@field bufnr integer buffer the clients are attached to
---@field uri string
---@field line_nr integer 0-based
---@field line string
---@field col integer 0-based byte column of the cursor
---@field mode "i"|"c"

---@class laser.UI What the engine needs from the menu, laser.FloatUI.
---@field open fun(startcol: integer, items: table[], mode: "i"|"c") startcol is 1-based like complete()
---@field close fun()
---@field visible fun(): boolean
---@field frozen_count fun(): integer prefix length to preserve, in input item order
---@field update fun(startcol: integer, items: table[], mode: "i"|"c") preserve selection and inserted text
---@field reset fun() release the frozen prefix after actual user input

---@class laser.Engine
---@field ui laser.UI
---@field enable_commit_characters? boolean
---@field clients? string[]
---@field client_options table<string, laser.ClientOpts>
---@field session laser.Session?
---@field doc laser.Doc?
---@field pending table<integer, { cancel?: fun() }> requests still in flight, keyed by client id
---@field displayed? table[] last snapshot sent to the UI
---@field render_ticket? table identity of a queued render
---@field continues fun(doc: laser.Doc, startcol: integer): boolean whether the editor still shows doc
local Engine = {}
Engine.__index = Engine

---@param opts { ui: laser.UI, clients?: string[], clientOptions?: table<string, laser.ClientOpts>, continues?: fun(doc: laser.Doc, startcol: integer): boolean }
---@return laser.Engine
function Engine.new(opts)
  return setmetatable({
    ui = opts.ui,
    continues = opts.continues or function()
      return true
    end,
    clients = opts.clients,
    client_options = opts.clientOptions or {},
    pending = {},
  }, Engine)
end

---Take the options of a complete() call; they apply from this call on.
---@param opts laser.CompleteOpts
function Engine:configure(opts)
  self.enable_commit_characters = opts.enable_commit_characters == true
  self.clients = vim.deepcopy(opts.clients)
  self.client_options = vim.deepcopy(opts.clientOptions or {})
end

---@param doc laser.Doc
---@return vim.lsp.Client[]
function Engine:clients_for(doc)
  local attached = vim.lsp.get_clients({ bufnr = doc.bufnr, method = "textDocument/completion" })
  return clients_mod.select(attached, self.clients, self.client_options)
end

---Re-run filters over the current candidates and show them.
function Engine:render()
  self.render_ticket = nil
  local session, doc = self.session, self.doc
  if not session or not doc then
    return
  end
  -- A late response must not open the menu where the cursor has moved to.
  if not self.continues(doc, session.startcol) then
    return self:close()
  end
  local count = self.ui.frozen_count()
  local frozen = vim.list_slice(self.displayed or {}, 1, count)
  local projection
  if #frozen > 0 then
    local exclude, used = {}, {}
    for _, item in ipairs(frozen) do
      local data = item.user_data.laser
      exclude[data.id] = true
      used[data.client_id] = (used[data.client_id] or 0) + 1
    end
    projection = { exclude = exclude, used = used, startcol = session.startcol }
  end
  local items, startcol = session:candidates(doc, projection)
  if #frozen > 0 then
    vim.list_extend(frozen, items)
    items = frozen
  end
  if #items == 0 then
    self.ui.close()
    return
  end
  session.startcol = startcol
  if #frozen > 0 then
    self.ui.update(startcol + 1, items, doc.mode)
  else
    self.ui.open(startcol + 1, items, doc.mode)
  end
  self.displayed = items
end

-- Coalesce progress notifications already queued in this event-loop turn.
function Engine:queue_render()
  if self.render_ticket then
    return
  end
  local ticket = {}
  self.render_ticket = ticket
  vim.schedule(function()
    if self.render_ticket == ticket then
      self:render()
    end
  end)
end

---@alias laser.ContextFor lsp.CompletionContext|fun(client: vim.lsp.Client): lsp.CompletionContext

---@param ctx laser.ContextFor
---@param client vim.lsp.Client
---@return lsp.CompletionContext
local function context_for(ctx, client)
  if type(ctx) == "function" then
    return ctx(client)
  end
  return ctx
end

---@param clients vim.lsp.Client[]
---@param ctx laser.ContextFor
function Engine:request(clients, ctx)
  local doc = assert(self.doc)
  local session = assert(self.session)
  for _, client in ipairs(clients) do
    local previous = self.pending[client.id]
    if previous and previous.cancel then
      previous.cancel()
    end
    -- Install the token before sending: in-process clients may reply synchronously.
    local token = {}
    self.pending[client.id] = token
    session:begin_request(client.id)
    local timer
    local function stop_timer()
      if timer then
        timer:stop()
        if not timer:is_closing() then
          timer:close()
        end
        timer = nil
      end
    end
    local cancel_request
    token.cancel = function()
      stop_timer()
      session:mark_interrupted(client.id)
      if cancel_request then
        cancel_request()
      end
    end
    -- Candidates keep the line their edits refer to.
    local requested = { line = doc.line, line_nr = doc.line_nr, col = doc.col }
    cancel_request = request.completion({ client }, function()
      local params =
        position.params(doc.uri, doc.line_nr, doc.line, doc.col, client.offset_encoding)
      params.context = context_for(ctx, client)
      return params
    end, function(_, err, result, partial)
      if self.session ~= session or self.pending[client.id] ~= token then
        return
      end
      if not partial or err then
        self.pending[client.id] = nil
        stop_timer()
      end
      if err then
        session:mark_interrupted(client.id)
        return
      end
      local current = assert(self.doc)
      session:set_result(client.id, result, {
        line = current.line,
        line_nr = current.line_nr,
        startcol = session.keyword_start,
        cursor_col = current.col,
        encoding = client.offset_encoding,
        client_id = client.id,
        request = requested,
        bufnr = doc.bufnr,
      }, token.received)
      token.received = true
      if partial then
        self:queue_render()
      else
        self:render()
        -- Input may have advanced while an empty initial request was pending.
        -- Retry only a newer snapshot, so an empty answer cannot loop by itself.
        if self.session == session and not vim.deep_equal(doc, self.doc) then
          local latest = session:refresh_context(client.id, assert(self.doc), "", false, doc)
          local predicate = (session.clients[client.id].opts or {}).refresh or refresh.default
          local context = refresh.lsp_context(latest)
          if not refresh.has_candidate(latest) and predicate(latest) then
            self:request({ client }, context)
          end
        end
      end
    end, doc.bufnr)
    local timeout = (session.clients[client.id].opts or {}).timeout_ms
    if timeout and timeout > 0 and self.pending[client.id] == token then
      timer = vim.defer_fn(function()
        timer = nil
        if self.pending[client.id] == token then
          self.pending[client.id] = nil
          session:mark_timed_out(client.id)
          token.cancel()
        end
      end, timeout)
    end
  end
end

---@param client vim.lsp.Client
---@param doc laser.Doc
---@param opts laser.ClientOpts
---@param order integer
---@return laser.SessionClient
local function client_state(client, doc, opts, order)
  return {
    order = order,
    name = client.name,
    opts = opts,
    trigger_chars = clients_mod.completion_characters(client, doc.bufnr, "triggerCharacters"),
  }
end

---Begin a new completion session at the keyword start before the cursor.
---@param doc laser.Doc
---@param ctx laser.ContextFor
function Engine:start(doc, ctx)
  self:close()
  local clients = self:clients_for(doc)
  if #clients == 0 then
    return
  end
  local session_clients = {}
  for order, client in ipairs(clients) do
    local opts = clients_mod.resolve(client.name, self.client_options)
    session_clients[client.id] = client_state(client, doc, opts, order)
  end
  self.doc = doc
  self.session = Session.new({
    startcol = position.keyword_start(doc.line, doc.col, doc.bufnr),
    clients = session_clients,
  })
  self:request(clients, ctx)
end

---Forget only this client's results and suppress its outstanding response.
---@param client_id integer
function Engine:drop_client(client_id)
  self.displayed = nil
  self.ui.reset()
  local token = self.pending[client_id]
  self.pending[client_id] = nil
  if token and token.cancel then
    token.cancel()
  end
  if self.session then
    self.session:remove_client(client_id)
  end
end

---The user typed `char`; `doc` is the document after the insertion. Existing
---candidates are re-matched right away; clients that need a fresh request
---according to their refresh predicate are asked in the background
---and replace their share when they answer.
---@param doc laser.Doc
---@param char string
function Engine:on_char(doc, char)
  local session, old = self.session, self.doc
  if not vim.deep_equal(doc, old) then
    self.displayed = nil
    self.ui.reset()
  end
  if
    not session
    or not old
    or old.bufnr ~= doc.bufnr
    or old.mode ~= doc.mode
    or old.line_nr ~= doc.line_nr
    or position.keyword_start(doc.line, doc.col, doc.bufnr) ~= session.keyword_start
    or doc.line:sub(1, session.keyword_start) ~= old.line:sub(1, session.keyword_start)
    or doc.line:sub(doc.col + 1) ~= old.line:sub(old.col + 1)
  then
    -- Refresh predicates only govern reusable results. A new completion range
    -- needs fresh results regardless of the predicate's return value.
    return self:start(doc, function(client)
      return refresh.lsp_context({
        inserted_char = char,
        trigger_characters = assert(self.session).clients[client.id].trigger_chars,
      })
    end)
  end
  local clients = self:clients_for(doc)
  if #clients == 0 then
    return self:close()
  end
  local active, added = {}, {}
  for order, client in ipairs(clients) do
    local opts = clients_mod.resolve(client.name, self.client_options)
    active[client.id] = true
    local state = client_state(client, doc, opts, order)
    if session.clients[client.id] then
      -- Options shape how cached results are shown and when to request
      -- again, not the results themselves; they apply from this call on.
      session:update_client(client.id, state)
    else
      added[client.id] = state
    end
  end
  for client_id in pairs(session.clients) do
    if not active[client_id] then
      self:drop_client(client_id)
    end
  end
  local needed = session:on_char(char, doc, self.pending, old)
  for client_id, state in pairs(added) do
    session:update_client(client_id, state)
    needed[client_id] = refresh.lsp_context(session:refresh_context(client_id, doc, char, false))
  end

  self.doc = doc
  self:render()
  for _, client in ipairs(clients) do
    if needed[client.id] then
      self:request({ client }, needed[client.id])
    end
  end
end

function Engine:cancel_pending()
  self.render_ticket = nil
  for client_id, token in pairs(self.pending) do
    if token.cancel then
      token.cancel()
    end
  end
  self.pending = {}
end

function Engine:close()
  self:cancel_pending()
  self.session = nil
  self.doc = nil
  self.displayed = nil
  self.ui.close()
end

return Engine

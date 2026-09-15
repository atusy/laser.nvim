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

---@class laser.UI
---@field open fun(startcol: integer, items: table[], mode: "i"|"c") startcol is 1-based like complete()
---@field close fun()
---@field visible fun(): boolean

---@class laser.Engine
---@field ui laser.UI
---@field clients_config table<string, table>
---@field session laser.Session?
---@field doc laser.Doc?
---@field pending table<integer, { cancel?: fun() }> requests still in flight, keyed by client id
local Engine = {}
Engine.__index = Engine

---@param opts { ui: laser.UI, clients: table<string, table> }
---@return laser.Engine
function Engine.new(opts)
  return setmetatable({ ui = opts.ui, clients_config = opts.clients or {}, pending = {} }, Engine)
end

---@param client vim.lsp.Client
---@return string[]
local function trigger_chars(client)
  local provider = client.server_capabilities and client.server_capabilities.completionProvider
  return type(provider) == "table" and provider.triggerCharacters or {}
end

---@param doc laser.Doc
---@return vim.lsp.Client[]
function Engine:clients_for(doc)
  local attached = vim.lsp.get_clients({ bufnr = doc.bufnr, method = "textDocument/completion" })
  return clients_mod.select(attached, self.clients_config)
end

---Re-run matcher/sorter over the current candidates and show them.
function Engine:render()
  local session, doc = self.session, self.doc
  if not session or not doc then
    return
  end
  local prefix = doc.line:sub(session.startcol + 1, doc.col)
  local items, startcol = session:candidates(prefix, doc)
  if #items == 0 then
    self.ui.close()
    return
  end
  session.startcol = startcol
  self.ui.open(startcol + 1, items, doc.mode)
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
      if cancel_request then
        cancel_request()
      end
    end
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
      }, token.received)
      token.received = true
      self:render()
    end, doc.bufnr)
    local timeout = (session.clients[client.id].opts or {}).timeout_ms
    if timeout and timeout > 0 and self.pending[client.id] == token then
      timer = vim.defer_fn(function()
        timer = nil
        if self.pending[client.id] == token then
          self.pending[client.id] = nil
          token.cancel()
        end
      end, timeout)
    end
  end
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
  for _, client in ipairs(clients) do
    session_clients[client.id] = {
      name = client.name,
      opts = clients_mod.resolve(client.name, self.clients_config),
      trigger_chars = trigger_chars(client),
    }
  end
  self.doc = doc
  self.session = Session.new({
    startcol = position.keyword_start(doc.line, doc.col),
    clients = session_clients,
  })
  self:request(clients, ctx)
end

---Forget only this client's results and suppress its outstanding response.
---@param client_id integer
function Engine:drop_client(client_id)
  local token = self.pending[client_id]
  self.pending[client_id] = nil
  if token and token.cancel then
    token.cancel()
  end
  if self.session then
    self.session.results[client_id] = nil
    self.session.clients[client_id] = nil
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
  if
    not session
    or not old
    or old.bufnr ~= doc.bufnr
    or old.mode ~= doc.mode
    or old.line_nr ~= doc.line_nr
    or position.keyword_start(doc.line, doc.col) ~= session.keyword_start
    or doc.line:sub(1, session.keyword_start) ~= old.line:sub(1, session.keyword_start)
    or doc.line:sub(doc.col + 1) ~= old.line:sub(old.col + 1)
  then
    -- Refresh predicates only govern reusable results. A new completion range
    -- needs fresh results regardless of the predicate's return value.
    return self:start(doc, function(client)
      local kind = vim.lsp.protocol.CompletionTriggerKind
      if char ~= "" and vim.list_contains(trigger_chars(client), char) then
        return { triggerKind = kind.TriggerCharacter, triggerCharacter = char }
      end
      return { triggerKind = kind.Invoked }
    end)
  end
  local clients = self:clients_for(doc)
  if #clients == 0 then
    return self:close()
  end
  local active, added = {}, {}
  for _, client in ipairs(clients) do
    local opts = clients_mod.resolve(client.name, self.clients_config)
    active[client.id] = true
    local cached = session.clients[client.id]
    if cached and not vim.deep_equal(cached.opts, opts) then
      self:drop_client(client.id)
      cached = nil
    end
    if cached then
      cached.trigger_chars = trigger_chars(client)
    else
      added[client.id] = { name = client.name, opts = opts, trigger_chars = trigger_chars(client) }
    end
  end
  for client_id in pairs(session.clients) do
    if not active[client_id] then
      self:drop_client(client_id)
    end
  end
  local needed = session:on_char(char, doc, self.pending)
  for client_id, client in pairs(added) do
    session.clients[client_id] = client
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

function Engine:close()
  for _, token in pairs(self.pending) do
    if token.cancel then
      token.cancel()
    end
  end
  self.pending = {}
  self.session = nil
  self.doc = nil
  self.ui.close()
end

return Engine

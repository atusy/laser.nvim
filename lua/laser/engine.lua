local clients_mod = require("laser.clients")
local position = require("laser.position")
local request = require("laser.request")
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
---@field cancel fun()?
local Engine = {}
Engine.__index = Engine

---@param opts { ui: laser.UI, clients: table<string, table> }
---@return laser.Engine
function Engine.new(opts)
  return setmetatable({ ui = opts.ui, clients_config = opts.clients or {} }, Engine)
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
  local items = session:candidates(prefix)
  if #items == 0 then
    self.ui.close()
    return
  end
  self.ui.open(session.startcol + 1, items, doc.mode)
end

---@param clients vim.lsp.Client[]
---@param ctx lsp.CompletionContext
function Engine:request(clients, ctx)
  local doc = assert(self.doc)
  local session = assert(self.session)
  self.cancel = request.completion(clients, function(client)
    local params = position.params(doc.uri, doc.line_nr, doc.line, doc.col, client.offset_encoding)
    params.context = ctx
    return params
  end, function(client, _, result)
    local current = assert(self.doc)
    session:set_result(client.id, result, {
      line = current.line,
      startcol = session.startcol,
      cursor_col = current.col,
      encoding = client.offset_encoding,
      client_id = client.id,
    })
    self:render()
  end, doc.bufnr)
end

---Begin a new completion session at the keyword start before the cursor.
---@param doc laser.Doc
---@param ctx lsp.CompletionContext
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

---The user typed `char`; `doc` is the document after the insertion. Existing
---candidates are re-matched right away; clients that need a fresh request
---(incomplete list, or their trigger character) are asked in the background
---and replace their share when they answer.
---@param doc laser.Doc
---@param char string
function Engine:on_char(doc, char)
  local session = self.session
  if not session then
    return
  end
  if doc.col < session.startcol then
    self:close()
    return
  end
  self.doc = doc
  self:render()

  local needed = session:on_char(char)
  if next(needed) == nil then
    return
  end
  for _, client in ipairs(self:clients_for(doc)) do
    local ctx = needed[client.id]
    if ctx then
      self:request({ client }, ctx)
    end
  end
end

function Engine:close()
  if self.cancel then
    self.cancel()
    self.cancel = nil
  end
  self.session = nil
  self.doc = nil
  self.ui.close()
end

return Engine

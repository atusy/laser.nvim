---In-process LSP server for tests. Answers textDocument/completion with the
---configured items after an optional delay, honours $/cancelRequest, and
---resolves items by attaching documentation.
local M = {}

local RequestCancelled = -32800

---@class laser.test.FakeServerOpts
---@field name? string
---@field items? lsp.CompletionItem[]|lsp.CompletionList|fun(params: lsp.CompletionParams): any
---@field delay_ms? integer
---@field trigger_chars? string[]
---@field filetypes? string[]
---@field manual? boolean respond explicitly via fake.last.respond

---@param opts laser.test.FakeServerOpts
---@return fun(dispatchers: vim.lsp.rpc.Dispatchers): vim.lsp.rpc.PublicClient
local function cmd_fn(opts)
  return function(dispatchers)
    local closing = false
    local next_id = 0
    local cancelled = {}
    local srv = {}
    srv.requests = {}
    srv.cancelled_count = 0
    function srv.progress(token, value)
      dispatchers.notification("$/progress", { token = token, value = value })
    end

    local function reply(id, callback, err, result)
      if cancelled[id] then
        callback({ code = RequestCancelled, message = "cancelled" }, nil)
      else
        callback(err, result)
      end
    end

    function srv.request(method, params, callback)
      next_id = next_id + 1
      local id = next_id
      table.insert(srv.requests, { id = id, method = method, params = params })
      if method == "initialize" then
        callback(nil, {
          capabilities = {
            completionProvider = {
              triggerCharacters = opts.trigger_chars or {},
              resolveProvider = true,
            },
          },
        })
      elseif method == "shutdown" then
        callback(nil, nil)
      elseif method == "textDocument/completion" then
        srv.respond = function(result, err)
          callback(err, result)
        end
        if opts.manual then
          return true, id
        end
        local result = type(opts.items) == "function" and opts.items(params) or opts.items or {}
        if (opts.delay_ms or 0) > 0 then
          vim.defer_fn(function()
            reply(id, callback, nil, result)
          end, opts.delay_ms)
        else
          reply(id, callback, nil, result)
        end
      elseif method == "completionItem/resolve" then
        local item = vim.deepcopy(params)
        item.documentation = "resolved: " .. item.label
        callback(nil, item)
      else
        callback(nil, nil)
      end
      return true, id
    end

    function srv.notify(method, params)
      if method == "$/cancelRequest" then
        cancelled[params.id] = true
        srv.cancelled_count = srv.cancelled_count + 1
        M.last_cancelled = (M.last_cancelled or 0) + 1
      elseif method == "exit" then
        dispatchers.on_exit(0, 15)
      end
      return true
    end

    function srv.is_closing()
      return closing
    end

    function srv.terminate()
      if closing then
        return
      end
      closing = true
      -- A real transport reports the exit asynchronously; the client is only
      -- removed once it does.
      vim.schedule(function()
        dispatchers.on_exit(0, 15)
      end)
    end

    M.last = srv
    M.last_cancelled = 0
    return srv
  end
end

---Start a fake server attached to `bufnr` and wait until it is initialized.
---@param opts laser.test.FakeServerOpts
---@param bufnr? integer
---@return vim.lsp.Client
function M.start(opts, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local id = assert(vim.lsp.start({
    name = opts.name or "fake",
    cmd = cmd_fn(opts),
    root_dir = vim.uv.cwd(),
  }, {
    bufnr = bufnr,
    reuse_client = function()
      return false
    end,
  }))
  local client = assert(vim.lsp.get_client_by_id(id))
  assert(
    vim.wait(1000, function()
      return client.initialized and vim.lsp.buf_is_attached(bufnr, id)
    end),
    "fake server did not initialize"
  )
  return client
end

function M.stop_all()
  for _, client in ipairs(vim.lsp.get_clients()) do
    client:stop(true)
  end
  assert(
    vim.wait(1000, function()
      return #vim.lsp.get_clients() == 0
    end),
    "fake servers did not stop"
  )
end

return M

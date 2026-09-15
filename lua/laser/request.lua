local M = {}
local serial = 0
local prefix = "laser/completion/" .. tostring(vim.uv.hrtime()) .. "/"
local routes = setmetatable({}, { __mode = "k" })

-- One dispatcher per client keeps concurrent requests independent. Retain the
-- dispatcher for the client's lifetime so late progress is harmless after cancel.
local function progress_routes(client)
  if routes[client] then
    return routes[client]
  end
  local callbacks = {}
  routes[client] = callbacks
  client.handlers = client.handlers or {}
  local previous = client.handlers["$/progress"]
  client.handlers["$/progress"] = function(err, result, ctx, config)
    local token = result and result.token
    if type(token) == "string" and vim.startswith(token, prefix) then
      if callbacks[token] then
        callbacks[token](err, result.value)
      end
      return
    end
    local handler = previous or vim.lsp.handlers["$/progress"]
    if handler then
      return handler(err, result, ctx, config)
    end
  end
  return callbacks
end

---@alias laser.OnResult fun(client: vim.lsp.Client, err: lsp.ResponseError?, result: any, partial?: boolean)

---Send textDocument/completion to every client and report each answer as it
---arrives. Returns a function that cancels whatever is still in flight and
---suppresses late answers.
---@param clients vim.lsp.Client[]
---@param params fun(client: vim.lsp.Client): lsp.CompletionParams
---@param on_result laser.OnResult
---@param bufnr? integer
---@return fun() cancel
function M.completion(clients, params, on_result, bufnr)
  local cancelled = false
  local pending = {} ---@type table<integer, integer> client id -> request id
  local cleanups = {}

  for _, client in ipairs(clients) do
    serial = serial + 1
    local token = prefix .. serial
    local callbacks = progress_routes(client)
    local finished = false
    local function cleanup()
      finished = true
      callbacks[token] = nil
      pending[client.id] = nil
    end
    cleanups[#cleanups + 1] = cleanup
    callbacks[token] = function(err, value)
      if not cancelled and not finished then
        on_result(client, err, value, true)
      end
    end
    local request_params = vim.tbl_extend("force", params(client), { partialResultToken = token })
    local ok, request_id = client:request(
      "textDocument/completion",
      request_params,
      function(err, result)
        if cancelled or finished then
          return
        end
        cleanup()
        on_result(client, err, result)
      end,
      bufnr
    )
    if ok and request_id and not finished then
      pending[client.id] = request_id
    elseif not ok then
      cleanup()
      on_result(client, {
        code = -32603,
        message = "Could not send completion request",
      }, nil)
    end
  end

  return function()
    cancelled = true
    for client_id, request_id in pairs(pending) do
      local client = vim.lsp.get_client_by_id(client_id)
      if client then
        client:cancel_request(request_id)
      end
    end
    for _, cleanup in ipairs(cleanups) do
      cleanup()
    end
    pending = {}
  end
end

return M

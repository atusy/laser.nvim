local M = {}

---@alias laser.OnResult fun(client: vim.lsp.Client, err: lsp.ResponseError?, result: any)

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

  for _, client in ipairs(clients) do
    local ok, request_id = client:request(
      "textDocument/completion",
      params(client),
      function(err, result)
        pending[client.id] = nil
        if cancelled then
          return
        end
        on_result(client, err, result)
      end,
      bufnr
    )
    if ok and request_id then
      pending[client.id] = request_id
    elseif not ok then
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
    pending = {}
  end
end

return M

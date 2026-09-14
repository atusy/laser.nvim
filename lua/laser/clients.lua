local M = {}

---Per-client options are keyed by client name. "*" holds the defaults.
---A client that is named explicitly is enabled unless it says otherwise,
---so `{ ["*"] = { enabled = false }, lua_ls = {} }` acts as an allow-list.
---@param name string
---@param config table<string, table>
---@return table
function M.resolve(name, config)
  local own = config[name]
  local resolved = vim.tbl_extend("force", config["*"] or {}, own or {})
  if own and own.enabled == nil then
    resolved.enabled = true
  end
  return resolved
end

---@param clients vim.lsp.Client[]
---@param config table<string, table>
---@return vim.lsp.Client[]
function M.select(clients, config)
  return vim.tbl_filter(function(client)
    return M.resolve(client.name, config).enabled ~= false
  end, clients)
end

return M

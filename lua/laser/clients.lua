local M = {}

---Per-client options are keyed by client name. "*" holds the defaults.
---@param name string
---@param config table<string, table>
---@return table
function M.resolve(name, config)
  return vim.tbl_extend("force", config["*"] or {}, config[name] or {})
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

local M = {}

---@param clients vim.lsp.Client[]
---@param config table<string, table>
---@return vim.lsp.Client[]
function M.select(clients, config)
  local _ = config
  return clients
end

return M

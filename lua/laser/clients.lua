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

---@param client vim.lsp.Client
---@param bufnr integer
---@param field "triggerCharacters"|"allCommitCharacters"
---@return string[]
function M.completion_characters(client, bufnr, field)
  local chars = {}
  local function collect(options)
    if type(options) == "table" then
      for _, char in ipairs(options[field] or {}) do
        if not vim.list_contains(chars, char) then
          chars[#chars + 1] = char
        end
      end
    end
  end
  collect(client.server_capabilities and client.server_capabilities.completionProvider)
  if client.dynamic_capabilities then
    local method = "textDocument/completion"
    local provider = client._registration_provider and client:_registration_provider(method)
      or method
    local registrations = client.dynamic_capabilities:get(provider, { bufnr = bufnr })
    -- Neovim 0.11 returns one registration; newer versions return a list.
    if registrations and registrations.method then
      registrations = { registrations }
    end
    for _, registration in ipairs(registrations or {}) do
      collect(registration.registerOptions)
    end
  end
  return chars
end

return M

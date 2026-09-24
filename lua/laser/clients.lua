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

---Select clients in display order. Explicit names are excluded from "*".
---@param clients vim.lsp.Client[]
---@param names? string[] nil selects all; an empty list selects none
---@param config? table<string, table>
---@return vim.lsp.Client[]
function M.select(clients, names, config)
  config = config or {}
  names = names or { "*" }
  local explicit, seen, selected = {}, {}, {}
  for _, name in ipairs(names) do
    if name ~= "*" then
      explicit[name] = true
    end
  end
  local sorted = vim.list_slice(clients)
  table.sort(sorted, function(a, b)
    return a.id < b.id
  end)
  for _, name in ipairs(names) do
    for _, client in ipairs(sorted) do
      if
        (client.name == name or (name == "*" and not explicit[client.name]))
        and not seen[client.id]
        and M.resolve(client.name, config).enabled ~= false
      then
        seen[client.id] = true
        selected[#selected + 1] = client
      end
    end
  end
  return selected
end

---Completion options the server gave at initialization and in dynamic
---registrations that apply to `bufnr`.
---@param client vim.lsp.Client
---@param bufnr integer
---@return table[]
local function completion_options(client, bufnr)
  local options = {}
  local static = client.server_capabilities and client.server_capabilities.completionProvider
  if type(static) == "table" then
    options[#options + 1] = static
  end
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
      if type(registration.registerOptions) == "table" then
        options[#options + 1] = registration.registerOptions
      end
    end
  end
  return options
end

---@param client vim.lsp.Client
---@param bufnr integer
---@param field "triggerCharacters"|"allCommitCharacters"
---@return string[]
function M.completion_characters(client, bufnr, field)
  local chars = {}
  for _, options in ipairs(completion_options(client, bufnr)) do
    for _, char in ipairs(options[field] or {}) do
      if not vim.list_contains(chars, char) then
        chars[#chars + 1] = char
      end
    end
  end
  return chars
end

---Whether the client resolves completion items for `bufnr`. Neovim 0.11
---does not look for resolveProvider in dynamic registrations.
---@param client vim.lsp.Client
---@param bufnr integer
---@return boolean
function M.supports_resolve(client, bufnr)
  for _, options in ipairs(completion_options(client, bufnr)) do
    if options.resolveProvider == true then
      return true
    end
  end
  return client:supports_method("completionItem/resolve", bufnr)
end

return M

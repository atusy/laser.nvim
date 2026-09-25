local M = {}

-- Keys of clientOptions that name no client: `_` holds defaults every
-- client inherits, `*` those of clients without options of their own.
local DEFAULTS, IMPLICIT = "_", "*"

---Options of the client `name`, inherited key by key: its own entry over
---`_`, or, for a client without an entry of its own, `*` over `_`. So
---`{ ["*"] = { enabled = false }, lua_ls = {} }` enables only lua_ls.
---@param name string
---@param config table<string, table>
---@return table
function M.resolve(name, config)
  local own = name ~= DEFAULTS and name ~= IMPLICIT and config[name] or config[IMPLICIT]
  return vim.tbl_extend("force", config[DEFAULTS] or {}, own or {})
end

---Select clients in display order. `*` stands for the clients the list does
---not name, and `_` for none.
---@param clients vim.lsp.Client[]
---@param names? string[] nil selects all; an empty list selects none
---@param config? table<string, table>
---@return vim.lsp.Client[]
function M.select(clients, names, config)
  config = config or {}
  names = names or { IMPLICIT }
  local explicit, seen, selected = {}, {}, {}
  for _, name in ipairs(names) do
    if name ~= IMPLICIT and name ~= DEFAULTS then
      explicit[name] = true
    end
  end
  local sorted = vim.list_slice(clients)
  table.sort(sorted, function(a, b)
    return a.id < b.id
  end)
  for _, name in ipairs(names) do
    if name ~= DEFAULTS then
      for _, client in ipairs(sorted) do
        if
          (client.name == name or (name == IMPLICIT and not explicit[client.name]))
          and not seen[client.id]
          and M.resolve(client.name, config).enabled ~= false
        then
          seen[client.id] = true
          selected[#selected + 1] = client
        end
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
    local registrations = client.dynamic_capabilities:get(provider, { bufnr = bufnr }) --[[@as table?]]
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

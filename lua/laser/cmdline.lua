---Scratch document that mirrors the command line so ordinary LSP clients can
---serve command-line completion. Ported from ddc-source-nvim-lsp.
local M = {}

-- The "/" after the colon matters: nvim_buf_set_name runs the name through
-- vim_FullName, which keeps URL-looking names verbatim only when they contain
-- "://". Without it the name would be resolved against the cwd.
---@param language_id string
---@return string
function M.buffer_uri(language_id)
  local encoded = language_id:gsub("[^%w._~-]", function(char)
    return string.format("%%%02X", string.byte(char))
  end)
  return "untitled://laser-cmdline/" .. encoded
end

---Set 'filetype' while 'buftype' is still "" so a real FileType autocmd fires
---and vim.lsp.enable() attaches the same clients it would for a file. Then
---flip to "nofile" so nothing can write the document to disk.
---@param buf integer
---@param language_id string
local function attach(buf, language_id)
  vim.bo[buf].buftype = ""
  vim.bo[buf].filetype = language_id
  vim.bo[buf].buftype = "nofile"
end

---@param uri string
---@return integer?
local function find_buffer(uri)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == uri then
      return buf
    end
  end
  return nil
end

---Clients attached to the document that can serve completion. Filtering by
---method rather than by server_capabilities picks up capabilities that are
---registered dynamically after initialize.
---@param bufnr integer
---@param language_id string
---@return vim.lsp.Client[]
function M.get_clients(bufnr, language_id)
  return vim.tbl_filter(function(client)
    local filetypes = client.config and client.config.filetypes
    return filetypes == nil or vim.tbl_contains(filetypes, language_id)
  end, vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/completion" }))
end

---Find or recreate the scratch document for `language_id`.
---
---An existing document without completion clients re-runs attach so a client
---the user enabled after the command line was first opened gets its FileType
---chance instead of the document staying client-less for the session.
---@param language_id string
---@return { bufnr: integer, uri: string }
function M.ensure_buffer(language_id)
  local uri = M.buffer_uri(language_id)
  local buf = find_buffer(uri)
  if buf then
    if not vim.api.nvim_buf_is_loaded(buf) then
      vim.fn.bufload(buf)
    end
    if #M.get_clients(buf, language_id) == 0 then
      attach(buf, language_id)
    end
    return { bufnr = buf, uri = uri }
  end

  buf = vim.api.nvim_create_buf(false, false)
  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, uri)
  attach(buf, language_id)
  return { bufnr = buf, uri = uri }
end

---@param bufnr integer
---@param text string
function M.set_text(bufnr, text)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { text })
end

return M

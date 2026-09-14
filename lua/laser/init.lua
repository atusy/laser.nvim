local cmdline = require("laser.cmdline")
local confirm = require("laser.confirm")
local Engine = require("laser.engine")

local M = {}

---@class laser.CmdlineConfig
---@field language_id string 'filetype' of the scratch document that mirrors the command line

---@class laser.Config
---@field clients table<string, table> per-client options keyed by client name; "*" holds defaults
---@field autotrigger boolean open the menu while typing
---@field ui "pum"|laser.UI
---@field cmdline table<string, laser.CmdlineConfig> keyed by command-line type (":" ...)

---@type laser.Config
M.config = {
  clients = {},
  autotrigger = true,
  ui = "pum",
  cmdline = {},
}

local augroup = vim.api.nvim_create_augroup("laser", { clear = true })
local TriggerKind = vim.lsp.protocol.CompletionTriggerKind

---@type laser.Engine
local engine

---@param char string
---@return boolean
local function is_keyword(char)
  return char ~= "" and vim.fn.match(char, [[\k]]) == 0
end

---@param doc laser.Doc
---@param char string
---@return boolean
local function is_trigger(doc, char)
  for _, client in ipairs(engine:clients_for(doc)) do
    local provider = vim.tbl_get(client, "server_capabilities", "completionProvider")
    if type(provider) == "table" and vim.list_contains(provider.triggerCharacters or {}, char) then
      return true
    end
  end
  return false
end

---Route a text change to the engine: narrow an open session, or open one
---when a keyword or trigger character was typed.
---@param doc laser.Doc
---@param char string
local function on_change(doc, char)
  if engine.session then
    engine:on_char(doc, char)
  elseif M.config.autotrigger and (is_keyword(char) or is_trigger(doc, char)) then
    engine:start(doc, { triggerKind = TriggerKind.Invoked })
  end
end

-- Insert mode ---------------------------------------------------------------

---@return laser.Doc
local function insert_doc()
  local bufnr = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  return {
    bufnr = bufnr,
    uri = vim.uri_from_bufnr(bufnr),
    line_nr = row - 1,
    line = vim.api.nvim_get_current_line(),
    col = col,
    mode = "i",
  }
end

local pending_char = ""

local function attach_insert(bufnr)
  vim.api.nvim_create_autocmd("InsertCharPre", {
    group = augroup,
    buffer = bufnr,
    callback = function()
      pending_char = vim.v.char
    end,
  })
  vim.api.nvim_create_autocmd("TextChangedI", {
    group = augroup,
    buffer = bufnr,
    callback = function()
      local char = pending_char
      pending_char = ""
      if engine.ui.skip_text_change and engine.ui.skip_text_change() then
        return
      end
      on_change(insert_doc(), char)
    end,
  })
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = augroup,
    buffer = bufnr,
    callback = function()
      engine:close()
    end,
  })
end

-- Command line --------------------------------------------------------------

local last_cmdline = ""

---@param conf laser.CmdlineConfig
---@return laser.Doc
local function cmdline_doc(conf)
  local doc = cmdline.ensure_buffer(conf.language_id)
  local text = vim.fn.getcmdline()
  cmdline.set_text(doc.bufnr, text)
  return {
    bufnr = doc.bufnr,
    uri = doc.uri,
    line_nr = 0,
    line = text,
    col = vim.fn.getcmdpos() - 1,
    mode = "c",
  }
end

local function attach_cmdline()
  local types = vim.tbl_keys(M.config.cmdline)
  if #types == 0 then
    return
  end
  vim.api.nvim_create_autocmd("CmdlineEnter", {
    group = augroup,
    pattern = types,
    callback = function()
      last_cmdline = ""
    end,
  })
  vim.api.nvim_create_autocmd("CmdlineChanged", {
    group = augroup,
    pattern = types,
    callback = function()
      local conf = M.config.cmdline[vim.fn.getcmdtype()]
      if not conf then
        return
      end
      local doc = cmdline_doc(conf)
      -- CmdlineChanged carries no character; infer it from a one-byte growth.
      local char = ""
      if #doc.line == #last_cmdline + 1 and vim.startswith(doc.line, last_cmdline:sub(1, doc.col - 1)) then
        char = doc.line:sub(doc.col, doc.col)
      end
      last_cmdline = doc.line
      on_change(doc, char)
    end,
  })
  vim.api.nvim_create_autocmd("CmdlineLeave", {
    group = augroup,
    pattern = types,
    callback = function()
      engine:close()
    end,
  })
end

-- Confirm -------------------------------------------------------------------

---@param candidate table
local function on_confirm(candidate)
  local session, doc = engine.session, engine.doc
  local client = vim.lsp.get_client_by_id(candidate.user_data.laser.client_id)
  if session and doc and doc.mode == "i" and client then
    confirm.apply(candidate, { bufnr = doc.bufnr, startcol = session.startcol, client = client })
  end
  engine:close()
end

---@return laser.UI
local function make_ui()
  if type(M.config.ui) == "table" then
    return M.config.ui
  end
  return require("laser.ui." .. M.config.ui).new({ on_confirm = on_confirm })
end

-- Public --------------------------------------------------------------------

---@param config? laser.Config
function M.setup(config)
  M.config = vim.tbl_deep_extend("force", M.config, config or {})
  vim.api.nvim_clear_autocmds({ group = augroup })
  engine = Engine.new({ ui = make_ui(), clients = M.config.clients })

  local attached = {}
  vim.api.nvim_create_autocmd("LspAttach", {
    group = augroup,
    callback = function(ev)
      if attached[ev.buf] or vim.bo[ev.buf].buftype ~= "" then
        return
      end
      attached[ev.buf] = true
      attach_insert(ev.buf)
    end,
  })
  attach_cmdline()
end

---Open the menu now, regardless of 'autotrigger'.
function M.trigger()
  engine:start(insert_doc(), { triggerKind = TriggerKind.Invoked })
end

function M.close()
  engine:close()
end

---@return laser.Engine
function M._engine()
  return engine
end

return M

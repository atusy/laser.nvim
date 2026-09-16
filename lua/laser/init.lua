local M = {}

---@class laser.ClientOpts: laser.FilterOpts
---@field enabled? boolean
---@field priority? number
---@field timeout_ms? integer request timeout in milliseconds; nil or 0 disables it
---@field refresh? laser.Refresh predicate for refreshing reusable results

---@class laser.CompleteOpts
---@field clients? table<string, laser.ClientOpts> per-client options; "*" holds defaults
---@field enable_commit_characters? boolean accept selected candidates on LSP commit characters; default false
---@field ui? "pum"|laser.UI
---@field language_id? string filetype of the scratch document in command-line mode

---@type laser.Engine?
local engine
local adapters = {}
local initialized = false

function M.close()
  if engine then
    engine:close()
  end
end

local function initialize()
  if initialized then
    return
  end
  local group = vim.api.nvim_create_augroup("laser", { clear = true })
  vim.api.nvim_create_autocmd({ "InsertLeave", "CmdlineLeave", "BufLeave" }, {
    group = group,
    callback = M.close,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      if engine and engine.doc and engine.doc.bufnr == args.buf then
        M.close()
      end
    end,
  })
  vim.api.nvim_create_autocmd("LspDetach", {
    group = group,
    callback = function(args)
      if engine and engine.doc and engine.doc.bufnr == args.buf then
        engine:drop_client(args.data.client_id)
        engine:render()
      end
    end,
  })
  initialized = true
end

---@param candidate table
local function on_confirm(candidate)
  if not engine then
    return
  end
  local session, doc = engine.session, engine.doc
  local client = vim.lsp.get_client_by_id(candidate.user_data.laser.client_id)
  if session and doc and doc.mode == "i" and client then
    require("laser.confirm").apply(candidate, {
      bufnr = doc.bufnr,
      startcol = candidate.user_data.laser.startcol or session.startcol,
      client = client,
    })
  end
  M.close()
end

local function make_ui(ui)
  if type(ui) == "table" then
    return ui
  end
  ui = ui or "pum"
  if not adapters[ui] then
    adapters[ui] = require("laser.ui." .. ui).new({
      on_confirm = on_confirm,
      preview_context = function(candidate)
        if engine and engine.doc then
          return {
            bufnr = engine.doc.bufnr,
            client = vim.lsp.get_client_by_id(candidate.user_data.laser.client_id),
          }
        end
      end,
      commit_characters = function(candidate)
        if not engine or not engine.enable_commit_characters or not engine.doc then
          return {}
        end
        local data = candidate.user_data.laser
        if data.item.commitCharacters ~= nil then
          return data.item.commitCharacters
        end
        local client = vim.lsp.get_client_by_id(data.client_id)
        return client
            and require("laser.clients").completion_characters(
              client,
              engine.doc.bufnr,
              "allCommitCharacters"
            )
          or {}
      end,
      -- PumCompleteDone follows PumClose asynchronously. Preserve the session
      -- until confirmation can apply its edits, but stop any more responses now.
      on_close = function()
        if engine then
          engine:cancel_pending()
        end
      end,
    })
  end
  return adapters[ui]
end

---@param opts laser.CompleteOpts
---@return laser.Doc?
local function document(opts)
  local mode = vim.api.nvim_get_mode().mode:sub(1, 1)
  if mode == "c" then
    if not opts.language_id then
      return
    end
    local cmdline = require("laser.cmdline")
    local doc = cmdline.ensure_buffer(opts.language_id)
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
  elseif mode == "i" then
    local buf = vim.api.nvim_get_current_buf()
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    return {
      bufnr = buf,
      uri = vim.uri_from_bufnr(buf),
      line_nr = row - 1,
      line = vim.api.nvim_get_current_line(),
      col = col,
      mode = "i",
    }
  end
end

---Return the inserted character only for a single-character insertion at the
---previous cursor. Deletions, replacements and cursor moves are not triggers.
local function inserted_char(old, doc)
  if not old or old.bufnr ~= doc.bufnr or old.line_nr ~= doc.line_nr or old.mode ~= doc.mode then
    return ""
  end
  if
    doc.col <= old.col
    or doc.line:sub(1, old.col) ~= old.line:sub(1, old.col)
    or doc.line:sub(doc.col + 1) ~= old.line:sub(old.col + 1)
  then
    return ""
  end
  local char = doc.line:sub(old.col + 1, doc.col)
  return vim.fn.strchars(char) == 1 and char or ""
end

---Start or update completion at the current cursor. Options belong to this
---call; changing client options invalidates that client, changing UI resets
---the session. No setup is required.
---@param opts? laser.CompleteOpts
function M.complete(opts)
  opts = opts or {}
  initialize()
  local ui = make_ui(opts.ui)
  if ui.skip_text_change and ui.skip_text_change() then
    return
  end
  local doc = document(opts)
  if not doc then
    M.close()
    return
  end
  local clients = opts.clients or {}
  if not engine or engine.ui ~= ui then
    M.close()
    engine = require("laser.engine").new({ ui = ui, clients = {} })
  end
  engine.enable_commit_characters = opts.enable_commit_characters == true
  engine.clients_config = vim.deepcopy(clients)
  engine:on_char(doc, inserted_char(engine.doc, doc))
end

---@return laser.Engine?
function M._engine()
  return engine
end

return M

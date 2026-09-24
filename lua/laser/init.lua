local M = {}

---@class laser.ClientOpts: laser.FilterOpts
---@field max_items? integer maximum displayed candidates after filtering per client; nil or 0 means unlimited
---@field enabled? boolean
---@field timeout_ms? integer request timeout in milliseconds; nil or 0 disables it
---@field refresh? laser.Refresh predicate for refreshing reusable results

---@class laser.CompleteOpts
---@field clients? string[] names in display order; "*" expands remaining clients; nil selects all
---@field clientOptions? table<string, laser.ClientOpts> per-client options; "*" holds defaults
---@field enable_commit_characters? boolean accept selected candidates on LSP commit characters; default false
---@field menu? laser.MenuOpts appearance and behavior of the built-in menu
---@field language_id? string filetype of the scratch document in command-line mode

---@type laser.Engine?
local engine
---@type laser.FloatUI?
local menu
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

local SNIPPET = 2 -- lsp.InsertTextFormat.Snippet

---Insert mode types plain candidates for dot-repeat and leaves snippets to
---expansion. The command line cannot expand snippets and takes their text.
---@param candidate table
---@return string?
local function confirm_text(candidate)
  local item = candidate.user_data.laser.item
  if item.insertTextFormat ~= SNIPPET then
    return candidate.word
  elseif not engine or not engine.doc or engine.doc.mode == "i" then
    return nil
  end
  local session, doc = assert(engine.session), engine.doc
  local body = item.textEdit and item.textEdit.newText or item.insertText or item.label
  local pad = doc.line:sub(session.startcol + 1, candidate.user_data.laser.startcol)
  return pad .. require("laser.confirm").snippet_text(body)
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
      startcol = session.startcol,
      client = client,
    })
  end
  M.close()
end

---@return laser.FloatUI
local function get_menu()
  if not menu then
    menu = require("laser.ui.float").new({
      on_confirm = on_confirm,
      confirm_text = confirm_text,
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
      -- The user closed the menu; stop responses that would reopen it.
      on_close = function()
        if engine then
          engine:cancel_pending()
        end
      end,
    })
  end
  return menu
end

---Run a menu action; returns false before completion has started.
---@param name string
---@return fun(...): boolean
local function action(name)
  return function(...)
    if not menu then
      return false
    end
    return menu[name](...)
  end
end

---Move the selection by `delta` and put the selected candidate in place of the
---typed input, unless `opts.insert` is false or the candidate would split the
---line, by a newline or auto-wrap. Single steps cycle through the typed input;
---larger moves stop at the first or last candidate.
---@type fun(delta: integer, opts?: { insert?: boolean }): boolean
M.select = action("select")
---Accept the selected candidate; returns false when nothing was selected.
---Closes the menu either way.
M.confirm = action("confirm")
---Restore the typed input and close the menu.
M.cancel = action("cancel")
---Select the candidate under the mouse; returns false outside the menu.
M.select_mouse = action("select_mouse")
---Scroll the documentation preview by `delta` lines.
M.scroll_preview = action("scroll_preview")
---Hide or show the documentation preview.
M.toggle_preview = action("toggle_preview")
---Whether the menu is open.
M.visible = action("visible")

---Start or update completion at the current cursor. Options belong to this
---call and apply to results already received. No setup is required.
---@param opts? laser.CompleteOpts
function M.complete(opts)
  opts = opts or {}
  initialize()
  local ui = get_menu()
  ui.configure(opts.menu)
  if ui.skip_text_change() then
    return
  end
  local document = require("laser.document")
  local doc = document.current(opts.language_id)
  if not doc then
    M.close()
    -- InsertEnter runs while the mode is still Normal; complete once Insert
    -- mode has started.
    local mode = vim.api.nvim_get_mode().mode
    if mode == "n" then
      vim.schedule(function()
        local now = vim.api.nvim_get_mode().mode
        if now == "i" or now == "c" then
          M.complete(opts)
        end
      end)
    end
    return
  end
  if not engine then
    engine = require("laser.engine").new({ ui = ui, continues = document.continues })
  end
  engine:configure(opts)
  engine:on_char(doc, document.inserted_char(engine.doc, doc))
end

---@return laser.Engine?
function M._engine()
  return engine
end

return M

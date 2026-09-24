local M = {}

---What the LSP trigger context is derived from.
---@class laser.TriggerContext
---@field inserted_char string single inserted character, or "" for other changes
---@field trigger_characters string[] this client's trigger characters
---@field is_incomplete boolean? nil until a response has been accepted

---@class laser.RefreshContext: laser.TriggerContext
---@field client_id integer
---@field client_name string
---@field bufnr integer completion document (scratch buffer in command-line mode)
---@field mode "i"|"c"
---@field before_cursor string current line up to the cursor
---@field previous_before_cursor? string previous line up to the cursor, when available
---@field inserted_char string single inserted character, or "" for other changes
---@field trigger_characters string[] this client's trigger characters
---@field is_incomplete boolean? nil until a response has been accepted
---@field has_candidate boolean whether this client has candidates after filtering for the current input
---@field pending boolean whether this client has a request in flight
---@field timed_out boolean whether this client's last request timed out; cleared on request start
---@field interrupted boolean whether this client's last request was cancelled, timed out or failed before its final answer; cleared on request start

---@alias laser.Refresh fun(ctx: laser.RefreshContext): boolean?

---Test the inserted character against this client's triggers, using only ctx.
---@param ctx laser.TriggerContext
---@return boolean
function M.hasTriggerCharacter(ctx)
  return ctx.inserted_char ~= "" and vim.list_contains(ctx.trigger_characters, ctx.inserted_char)
end

---Match a Lua pattern against the current line before the cursor. Use $ to
---anchor the match at the cursor. Deletions and other changes can also match.
---@param ctx laser.RefreshContext
---@param pattern string
---@return boolean
function M.hasPattern(ctx, pattern)
  return ctx.before_cursor:find(pattern) ~= nil
end

---Whether this client's filtered snapshot contains any candidates.
---@param ctx laser.RefreshContext
---@return boolean
function M.has_candidate(ctx)
  return ctx.has_candidate == true
end

---Whether the current input retains the previous input as a prefix.
---Identical inputs also return true; a missing previous input returns false.
---This compares text, not edit operations or the resulting candidate sets.
---@param ctx laser.RefreshContext
---@return boolean
function M.extendsPreviousInput(ctx)
  return ctx.previous_before_cursor ~= nil
    and vim.startswith(ctx.before_cursor, ctx.previous_before_cursor)
end

---@type laser.Refresh
function M.default(ctx)
  return ctx.timed_out == true
    or ctx.interrupted == true
    or ctx.is_incomplete == true
    or M.hasTriggerCharacter(ctx)
    or (ctx.previous_before_cursor ~= nil and not M.extendsPreviousInput(ctx))
    or (not ctx.pending and not M.has_candidate(ctx))
end

---The predicate chooses whether to request; laser chooses the LSP context.
---@param ctx laser.TriggerContext
---@return lsp.CompletionContext
function M.lsp_context(ctx)
  local kind = vim.lsp.protocol.CompletionTriggerKind
  if M.hasTriggerCharacter(ctx) then
    return { triggerKind = kind.TriggerCharacter, triggerCharacter = ctx.inserted_char }
  elseif ctx.is_incomplete then
    return { triggerKind = kind.TriggerForIncompleteCompletions }
  end
  return { triggerKind = kind.Invoked }
end

return M

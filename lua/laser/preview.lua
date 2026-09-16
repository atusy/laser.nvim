local M = {}

---@param item lsp.CompletionItem
---@return string
function M.info(item)
  local doc = item.documentation
  doc = type(doc) == "table" and doc.value or doc
  local parts = {}
  for _, text in ipairs({ item.detail or "", doc or "" }) do
    if text ~= "" then
      parts[#parts + 1] = text
    end
  end
  return table.concat(parts, "\n\n")
end

---Resolve only presentation data; confirmation still owns edits and commands.
---@return fun() cancel
function M.resolve(item, client, bufnr, show)
  local done = false
  local request_id
  if client and client:supports_method("completionItem/resolve", bufnr) then
    local ok, id = client:request("completionItem/resolve", item, function(err, result)
      if done then
        return
      end
      done = true
      if not err and type(result) == "table" then
        show(M.info(vim.tbl_extend("force", {}, item, result)))
      end
    end, bufnr)
    if ok and not done then
      request_id = id
    end
  end
  return function()
    local pending = not done
    done = true
    if pending and request_id then
      client:cancel_request(request_id)
    end
  end
end

return M

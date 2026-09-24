---UI stub that records what the engine asked it to show.
local M = {}

function M.new()
  local ui = { opened = {}, closed = 0, resets = 0, updates = 0, is_visible = false }
  local shown = {}
  function ui.open(startcol, items, mode)
    ui.is_visible = true
    shown = items
    table.insert(ui.opened, {
      startcol = startcol,
      mode = mode,
      labels = vim.tbl_map(function(c)
        return c.abbr
      end, items),
    })
  end
  function ui.close()
    ui.is_visible = false
    ui.closed = ui.closed + 1
  end
  function ui.visible()
    return ui.is_visible
  end
  -- Tests that exercise browsing replace these.
  function ui.frozen_count()
    return 0
  end
  function ui.update(startcol, items, mode)
    ui.updates = ui.updates + 1
    ui.open(startcol, items, mode)
  end
  function ui.reset()
    ui.resets = ui.resets + 1
  end
  function ui.last()
    return ui.opened[#ui.opened]
  end
  ---The words the last shown candidates would insert from the menu start.
  ---@return string[]
  function ui.words()
    return vim.tbl_map(function(c)
      return c.word
    end, shown)
  end
  return ui
end

return M

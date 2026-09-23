---UI stub that records what the engine asked it to show.
local M = {}

function M.new()
  local ui = { opened = {}, closed = 0, is_visible = false }
  function ui.open(startcol, items, mode)
    ui.is_visible = true
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
    ui.open(startcol, items, mode)
  end
  function ui.reset() end
  function ui.last()
    return ui.opened[#ui.opened]
  end
  return ui
end

return M

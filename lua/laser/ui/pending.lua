---Edits whose fed keys have not run yet, and the steps waiting for them.
local M = {}

---@class laser.Pending
---@field busy fun(): boolean whether an edit's keys are still queued
---@field after fun(step: fun()) run `step` now, or once no edit is pending, in call order
---@field start fun() count an edit whose keys were just fed
---@field finish fun(done: fun()) the edit's keys ran: `done`, then the steps waiting for them
---@field reset fun() forget pending edits whose keys were discarded

---@return laser.Pending
function M.new()
  local count, waiting = 0, {} ---@type integer, fun()[]
  local self = {}

  function self.busy()
    return count > 0
  end

  function self.after(step)
    if count > 0 then
      waiting[#waiting + 1] = step
    else
      step()
    end
  end

  function self.start()
    count = count + 1
  end

  function self.finish(done)
    count = count - 1
    done()
    -- A step may feed keys again; the rest wait for those in turn.
    while count == 0 and #waiting > 0 do
      table.remove(waiting, 1)()
    end
  end

  function self.reset()
    count, waiting = 0, {}
  end

  return self
end

return M

---Wait until work already queued has run: timers due now, then callbacks
---those schedule, a few hops deep. Replaces fixed sleeps after typing.
---@param timeout? integer
return function(timeout)
  local hops, done = 0, false
  local function hop()
    hops = hops + 1
    if hops >= 4 then
      done = true
    else
      vim.schedule(hop)
    end
  end
  -- A 1 ms timer fires after the 0 ms timers the fake server replies with.
  vim.defer_fn(hop, 1)
  assert(vim.wait(timeout or 1000, function()
    return done
  end, 1))
end

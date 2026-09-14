local MiniTest = require("mini.test")
local expect = MiniTest.expect
local fake = require("tests.helpers.fake_server")

local T = MiniTest.new_set({ hooks = { post_case = fake.stop_all } })

local request = require("laser.request")

local function params_for(client)
  return {
    textDocument = { uri = "file:///x" },
    position = { line = 0, character = 0 },
    _for = client.name,
  }
end

T["each client's answer is delivered as soon as it arrives"] = function()
  local slow = fake.start({ name = "slow", items = { { label = "slow" } }, delay_ms = 50 })
  local quick = fake.start({ name = "quick", items = { { label = "quick" } } })
  local arrived = {}
  request.completion({ slow, quick }, params_for, function(client, _, result)
    table.insert(arrived, { client.name, result[1].label })
  end)
  vim.wait(500, function()
    return #arrived == 2
  end)
  expect.equality(arrived, { { "quick", "quick" }, { "slow", "slow" } })
end

T["cancelling suppresses answers that were still in flight"] = function()
  local slow = fake.start({ name = "slow", items = { { label = "slow" } }, delay_ms = 50 })
  local arrived = 0
  local cancel = request.completion({ slow }, params_for, function()
    arrived = arrived + 1
  end)
  cancel()
  vim.wait(150)
  expect.equality(arrived, 0)
  expect.equality(fake.last_cancelled, 1)
end

return T

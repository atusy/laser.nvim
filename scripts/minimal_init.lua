local root = vim.fn.getcwd()
local mini = vim.env.MINI_NVIM_PATH or vim.fs.joinpath(root, "deps", "mini.nvim")

vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:append(mini)

require("mini.test").setup({
  collect = {
    find_files = function()
      return vim.fn.globpath("tests", "test_*.lua", true, true)
    end,
  },
})

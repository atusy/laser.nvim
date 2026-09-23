# ✨ laser.nvim

**LA**nguage **SER**vice-oriented completion for Neovim

🚧 Experimental.

- **Start with your existing LSP setup.** Laser uses attached language servers; there are no separate completion sources to configure. Server priority is customizable.
- **Stream suggestions as they arrive.** Browse results without waiting for every server or the full stream to finish. Once you start navigating, visible candidates and your selection stay stable as more suggestions arrive.
- **Complete on the command line too.** Use LSP-powered suggestions for `:` commands alongside Insert-mode completion.

## 🚀 Get started

You need Neovim 0.11 or newer and a configured LSP server that supports completion.

Install `atusy/laser.nvim` with your plugin manager, then add:

```lua
local group = vim.api.nvim_create_augroup("my-completion", { clear = true })

vim.api.nvim_create_autocmd({ "InsertEnter", "TextChangedI" }, {
  group = group,
  callback = function()
    require("laser").complete()
  end,
})

local laser = require("laser")
vim.keymap.set({ "i", "c" }, "<C-n>", function()
  laser.select(1)
end)
vim.keymap.set({ "i", "c" }, "<C-p>", function()
  laser.select(-1)
end)
vim.keymap.set({ "i", "c" }, "<C-y>", function()
  laser.confirm()
end)
vim.keymap.set({ "i", "c" }, "<C-e>", function()
  laser.cancel()
end)
```

`laser.select(delta)` inserts the selected candidate as you move; pass
`{ insert = false }` to only highlight it. Single steps cycle back to what you
typed, and larger steps, such as paging with `laser.select(10)`, stop at the
first or last candidate.

Actions edit text and windows, so call them from regular mappings as above,
not from `<expr>` mappings. Each returns `false` when it did nothing, so a
mapping can fall back to the key's default behavior. `laser.confirm()` closes
the menu even when nothing is selected.

```lua
vim.keymap.set("i", "<LeftMouse>", function()
  if not laser.select_mouse() then
    vim.api.nvim_feedkeys(vim.keycode("<LeftMouse>"), "n", false)
  end
end)
```

In an `<expr>` mapping, check `laser.visible()` and return a `<Cmd>` mapping:

```lua
vim.keymap.set("i", "<Tab>", function()
  return laser.visible() and "<Cmd>lua require('laser').select(1)<CR>" or "<Tab>"
end, { expr = true })
```

For manual completion, replace the autocmd with a mapping:

```lua
vim.keymap.set("i", "<C-Space>", function()
  require("laser").complete()
end)
```

## 🎯 Configuration

### Language servers

In your completion callback, choose servers and their display order:

```lua
require("laser").complete({
  clients = { "lua_ls", "*" }, -- Show lua_ls first, then other attached clients.
  clientOptions = {
    ["*"] = { timeout_ms = 1000 }, -- Optional request timeout in milliseconds.
    copilot = { enabled = false },
  },
})
```

Omit `clients` to use all attached completion clients, or list names without `"*"` to use only those clients. `clientOptions["*"]` provides shared defaults; `clientOptions[name]` overrides them for a particular client. Requests have no timeout by default.

Set `clientOptions[name].max_items = 30` to display at most 30 candidates from that client after filtering and sorting. Use `clientOptions["*"].max_items = 30` to apply the limit to each client by default; individual clients can override it. Cached results remain available for further narrowing, and converters after the last matcher or sorter run only on the displayed candidates. Omit it or use `0` for no limit.

### Command-line completion

Enable an LSP server for the `vim` filetype with `vim.lsp.enable()`, then add:

```lua
vim.api.nvim_create_autocmd({ "CmdlineEnter", "CmdlineChanged" }, {
  pattern = ":",
  callback = function()
    require("laser").complete({ language_id = "vim" })
  end,
})
```

The mappings above work in both Insert and command-line mode.

### 🪟 Menu

Pass `menu` to adjust the built-in menu:

```lua
require("laser").complete({
  menu = {
    max_height = 10, -- Rows shown at once; defaults to 'pumheight' or 10.
    max_width = 80,
    border = "none",
    auto_select = false, -- Highlight the first candidate without inserting it.
    direction = "auto", -- "auto", "below", or "above".
    reversed = false, -- List candidates bottom-up when the menu opens above.
  },
})
```

The menu draws only the rows in view. Filtering and column widths still visit
every candidate, so `max_items` remains useful for servers that return very
long lists.

### 📖 Documentation preview

Show documentation for the selected candidate beside the menu:

```lua
require("laser").complete({
  menu = { preview = { border = "single", max_width = 60, max_height = 20 } },
})
```

Use `preview = true` for the defaults. Map `laser.scroll_preview(delta)` and
`laser.toggle_preview()` to scroll or toggle the preview.

### Commit characters

To accept the selected suggestion when you type a server-defined commit
character, then insert that character (disabled by default):

```lua
require("laser").complete({ enable_commit_characters = true })
```

### Match highlighting

Fuzzy matching and score sorting are enabled by default. To highlight matches
with `PmenuMatch`, define these filters outside your completion callback:

```lua
local filter = require("laser.filter")
local filters = {
  { kind = "matcher", callback = filter.fuzzy_matcher() },
  { kind = "sorter", callback = filter.score_sorter() },
  { kind = "converter", callback = filter.highlight_converter() },
}
```

Then use them in the callback:

```lua
require("laser").complete({
  clientOptions = { ["*"] = { filters = filters } },
})
```

For custom matching, sorting, or refresh behavior, see the API details in [filters](lua/laser/filter.lua), [refresh helpers](lua/laser/refresh.lua), and [completion options](lua/laser/init.lua).

By default, edits that no longer retain the previous input as a prefix trigger
a background refresh, even when cached candidates still match. The menu keeps
matching cached candidates until the new response replaces that client's results.
Custom refresh callbacks can use `require("laser.refresh").extendsPreviousInput(ctx)`
to make the same comparison; identical input counts as extending the previous input.

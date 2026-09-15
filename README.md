# laser.nvim

LSP-only completion for Neovim. Experimental.

## Design

- **Sources are LSP clients, picked by name.** Nothing is configured means every
  attached client serves completion. Per-client options live in one table keyed by
  client name, with `"*"` as the defaults.
- **Matcher and sorter are plain Lua functions**, configurable per client. Defaults:
  fuzzy matching via `matchfuzzypos()` and ordering by score, `sortText`, label.
- **Typing reuses the candidates you already have.** A client is asked again only when
  it said its list was incomplete, or when you typed one of its trigger characters.
  The answer replaces that client's share of the menu when it arrives.
- **Clients answer independently.** The first answer opens the menu; later ones are
  merged in, grouped per client and ordered by a per-client `priority`.
- **The command line is completed through a scratch document** whose `filetype` is
  the configured `language_id`, so `vim.lsp.enable()` attaches the same clients it
  would for a file.
- **The UI is an adapter.** The first one drives [pum.vim](https://github.com/Shougo/pum.vim).
  Confirming an item applies `textEdit`/snippets, `additionalTextEdits` and the item's
  command, resolving the item first when the server supports it.

## Requirements

- Neovim 0.11 or newer (in-process LSP servers, `vim.snippet`, `vim.str_byteindex`)
- [pum.vim](https://github.com/Shougo/pum.vim) for the default UI

## Setup

```lua
local group = vim.api.nvim_create_augroup("my-completion", { clear = true })

vim.api.nvim_create_autocmd({ "InsertEnter", "TextChangedI" }, {
  group = group,
  callback = function(args)
    require("laser").complete({
      -- Per-call options keyed by client name. "*" holds the defaults.
      -- { ["*"] = { enabled = false }, lua_ls = {} } acts as an allow-list.
      clients = {
        ["*"] = {
          -- matcher = function(prefix, candidate) return score_or_nil end,
          -- sorter = function(a, b) return a_before_b end,
          priority = 0,
        },
        copilot = { enabled = false },
      },
      ui = "pum", -- or a table implementing open/close/visible
    })
  end,
})

vim.api.nvim_create_autocmd({ "CmdlineEnter", "CmdlineChanged" }, {
  group = group,
  pattern = ":",
  callback = function()
    require("laser").complete({ language_id = "vim" })
  end,
})

-- pum.vim mappings, as in its README.
vim.keymap.set({ "i", "c" }, "<C-n>", function() vim.fn["pum#map#insert_relative"](1) end)
vim.keymap.set({ "i", "c" }, "<C-p>", function() vim.fn["pum#map#insert_relative"](-1) end)
vim.keymap.set({ "i", "c" }, "<C-y>", function() vim.fn["pum#map#confirm"]() end)
vim.keymap.set({ "i", "c" }, "<C-e>", function() vim.fn["pum#map#cancel"]() end)
```

No `setup()` is needed. Call `require("laser").complete(opts)` from an autocmd
or an Insert-mode mapping. It works with clients that are already attached.
Use the callback to choose options or skip completion based on `args.buf`,
filetype, or your own conditions. Calling `complete()` starts completion even
without a newly typed keyword character.

Options apply to each call; omitted options use defaults, not the previous call's
values. Equivalent client options reuse the current session. Changing client
options or the UI starts a new session. Reuse the same custom UI table and
matcher/sorter functions across calls to retain the session.

In command-line mode, pass `language_id` to choose the scratch document's filetype.
Laser handles trigger characters, ignores pum's selection edits, and closes and
cancels pending requests on mode exit or buffer departure. To close explicitly,
call `require("laser").close()`.

Migration: replace `setup()` and `trigger()` with the autocmds above and
`complete(opts)` respectively. `config`, `autotrigger`, and the command-line
configuration map are replaced by per-call options and autocmd conditions.

Candidates handed to a matcher or sorter are `complete-items` (see `:h complete-items`)
with `user_data.laser = { client_id = ..., item = <lsp.CompletionItem> }`; the matcher's
score is stored in `candidate.score` for the sorter.

## Module map

| Module | Role |
| --- | --- |
| `laser.clients` | select clients by name, resolve per-client options |
| `laser.items` | `lsp.CompletionItem` to `complete-item` |
| `laser.match` | matcher/sorter stage |
| `laser.session` | per-client results, re-request decisions |
| `laser.request` | async per-client `textDocument/completion` with cancel |
| `laser.engine` | ties document, session, requests and UI together |
| `laser.confirm` | applies the accepted item |
| `laser.cmdline` | scratch document mirroring the command line |
| `laser.ui.pum` | pum.vim adapter |

## Development

```sh
make test   # clones deps/mini.nvim and deps/pum.vim, or set MINI_NVIM_PATH / PUM_VIM_PATH
make fmt
```

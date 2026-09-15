# laser.nvim

LSP-only completion for Neovim. Experimental.

## Design

- **Sources are LSP clients, picked by name.** Nothing is configured means every
  attached client serves completion. Per-client options live in one table keyed by
  client name, with `"*"` as the defaults.
- **Matcher and sorter are plain Lua functions**, configurable per client. Defaults:
  fuzzy matching via `matchfuzzypos()` and ordering by score, `sortText`, label.
- **Typing reuses the candidates you already have.** By default, a client is asked again when
  it said its list was incomplete, or when you typed one of its trigger characters.
  A per-client `refresh(ctx)` predicate can replace that policy.
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
options invalidates only that client's results; changing the UI starts a new
session. Reuse the same custom UI table and matcher/sorter/refresh functions
across calls to retain cached results.

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

## Request timeout

Set `clients[name].timeout_ms` (or `clients["*"].timeout_ms`) to bound a
completion request in milliseconds. Omitted or zero means no timeout.
When the deadline expires, only that client's request is cancelled; its previous
candidates remain available and late responses are ignored. Timers are stopped
on response, superseding requests, detachment, and session closure.

## Refresh predicates

Set `clients[name].refresh` or a default in `clients["*"].refresh`. The predicate
runs once per reusable client on each `complete()` call (except UI selection
edits), including while a request is pending. A truthy return value requests a
new result for that client; false or nil keeps its candidates for local filtering.
Omitting `refresh` preserves the default incomplete-or-trigger behavior.

```lua
local laser = require("laser")

-- Define the function outside the autocmd so its identity stays stable.
local function refresh(ctx)
  return ctx.is_incomplete
    or laser.hasTriggerCharacter(ctx)
    or laser.hasPattern(ctx, "[.:]$")
end

vim.api.nvim_create_autocmd({ "CmdlineEnter", "CmdlineChanged" }, {
  pattern = ":",
  callback = function()
    laser.complete({
      language_id = "vim",
      clients = { ["*"] = { refresh = refresh } },
    })
  end,
})
```

To always refresh, use a function returning `true`; to never refresh reusable
results, return `false`. A custom predicate replaces the whole policy, so include
`ctx.is_incomplete` explicitly if incomplete responses should force a refresh.

Each call receives a new snapshot, which laser does not retain or subsequently
modify. Treat predicates as read-only decisions. Client identity is provided as
scalar fields, rather than exposing the mutable LSP client object.

| Context field | Meaning |
| --- | --- |
| `client_id`, `client_name` | Target client |
| `bufnr` | Completion document; the scratch buffer in command-line mode |
| `mode` | `"i"` or `"c"` |
| `before_cursor` | Current line from its start to just before the cursor |
| `inserted_char` | Single inserted character, or `""` for other changes |
| `trigger_characters` | A copy of this client's current trigger characters |
| `is_incomplete` | Last accepted response's `isIncomplete`; nil before any response, false for a complete or empty response |
| `pending` | Whether this client has a request in flight |

`laser.hasTriggerCharacter(ctx)` checks `inserted_char` against
`trigger_characters`. `laser.hasPattern(ctx, pattern)` matches a Lua pattern
against `before_cursor`; use `$` to anchor it at the cursor. Pattern matches can
also occur after deletions. Both helpers use only the supplied context.

### Result lifetime

Initial requests bypass the predicate. Moving to a different document, mode,
line, or keyword start, or changing text outside the completion range, starts a
new session and fetches fresh results even when `refresh` returns false.

Within that range, refreshing one client preserves other clients' results. The
previous result stays available while a replacement is pending. A successful
response replaces it (an empty response clears its candidates); errors and server
cancellations preserve it. Only the current request's response can be accepted.
Client option changes or detachment discard that client's results and cancel its
pending request. Closing the session discards all results and cancels all requests.

Laser chooses the LSP request context independently of the predicate: a declared
trigger character uses `TriggerCharacter`, an incomplete result uses
`TriggerForIncompleteCompletions`, and other refreshes use `Invoked`.

## Module map

| Module | Role |
| --- | --- |
| `laser.clients` | select clients by name, resolve per-client options |
| `laser.items` | `lsp.CompletionItem` to `complete-item` |
| `laser.match` | matcher/sorter stage |
| `laser.session` | per-client results, refresh snapshots and decisions |
| `laser.refresh` | predicate helpers and LSP request context |
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

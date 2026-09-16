# laser.nvim

LSP-only completion for Neovim. Experimental.

## Design

- **Sources are LSP clients, picked by name.** Nothing is configured means every
  attached client serves completion. Per-client options live in one table keyed by
  client name, with `"*"` as the defaults.
- **Converters, matchers, and sorters are plain Lua functions**, configurable per
  client in any order through `filters`. Defaults:
  fuzzy matching via `matchfuzzypos()` and ordering by score, `sortText`, label.
- **Typing reuses the candidates you already have.** By default, a client is asked again when
  it said its list was incomplete, when you typed one of its trigger characters,
  or when no candidates match and no request is pending.
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
          -- filters = {
          --   { kind = "matcher", callback = require("laser.filter").fuzzy },
          --   { kind = "sorter", callback = require("laser.filter").by_score },
          -- },
          priority = 0,
          timeout_ms = 1000, -- omitted or 0: no request timeout
        },
        copilot = { enabled = false },
      },
      enable_commit_characters = false, -- opt in to LSP commit characters
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
session. Reuse the same custom UI table and filter callbacks and refresh functions
across calls to retain cached results.

In command-line mode, pass `language_id` to choose the scratch document's filetype.
Laser handles trigger characters, ignores pum's selection edits, and closes and
cancels pending requests on mode exit or buffer departure. To close explicitly,
call `require("laser").close()`.

With the default pum UI, `enable_commit_characters = true` accepts the selected
candidate when you type one of its LSP commit characters, then inserts that
character. This works in Insert and command-line mode and is disabled by default.
Item `commitCharacters` (including `CompletionList.itemDefaults`) takes precedence
over the server's `allCommitCharacters`; an empty item list disables this behavior
for that candidate. Static and buffer-matching dynamic registrations are supported.
No candidate is accepted when the menu has no selection.

Migration: replace `setup()` and `trigger()` with the autocmds above and
`complete(opts)` respectively. `config`, `autotrigger`, and the command-line
configuration map are replaced by per-call options and autocmd conditions.

## Candidate preview

Enable the default UI's documentation preview through pum.vim:

```lua
vim.fn["pum#set_option"]({
  preview = true,
  preview_border = "single",
  preview_width = 60,
  preview_height = 20,
})
```

Selecting a candidate displays its `detail` and `documentation`. Laser requests
`completionItem/resolve` when supported and refreshes the preview with the result.
Switching candidates or closing the menu cancels the pending request and ignores
late responses. This also works with the command-line scratch document. Preview
buffers use `filetype=markdown` for Markdown `MarkupContent`; plaintext and string
documentation clear the filetype.
Use `pum#map#scroll_preview()` to scroll and `pum#map#toggle_preview()` to toggle it.

## Filters

Per-client `filters` run in array order. Kinds can repeat or be omitted:

```lua
local filter = require("laser.filter")
local filters = {
  { kind = "converter", callback = function(candidate)
    -- Change the text used by the following matcher.
    candidate.user_data.laser.item.filterText = candidate.abbr:lower()
    return candidate
  end },
  { kind = "matcher", callback = filter.fuzzy },
  { kind = "sorter", callback = filter.by_score },
  { kind = "converter", callback = function(candidate)
    candidate.menu = tostring(candidate.user_data.laser.match_info.score)
    return candidate
  end },
}
require("laser").complete({ clients = { ["*"] = { filters = filters } } })
```

Candidates (`laser.Candidate`) are `complete-items` (see `:h complete-items`)
with `user_data.laser` containing the client ID, original LSP item, stable candidate
ID, and completion boundary. Callbacks are synchronous:

| Kind | Callback | Effect |
| --- | --- | --- |
| `converter` | `(candidate) -> candidate` | Replace each candidate with the returned candidate. |
| `matcher` | `(input, candidate) -> boolean, MatchInfo?` | Reject or annotate each candidate. |
| `sorter` | `(a, b) -> boolean` | Order candidates; return true when `a` belongs before `b`. |

A matcher returns `false, nil` to remove a candidate permanently from this run;
no later filter receives it. Returning `true, match_info` keeps it and replaces
`candidate.user_data.laser.match_info` in full. Later matchers always win; results
are never merged. `laser.MatchInfo` currently has one required field, `score: number`.
Position and highlight metadata are not yet defined. Each matcher receives input
starting at that candidate's own completion boundary.

`filter.fuzzy` implements this boolean/MatchInfo contract, matching against
`item.filterText` or `item.label`. `filter.by_score` sorts by descending score,
then `sortText`, then label; candidates without match info use score zero.
Sorters preserve the preceding order for equivalent candidates. Comparators must
use a strict ordering (return false for equal keys).

Each run works on deep copies of cached candidates, so conversion and match info
do not accumulate as you type. Converters may modify their copy or return a new
candidate, but must preserve `user_data.laser` identity and the information needed
for confirmation (`client_id`, `id`, `startcol`, and the LSP `item`). Changes to
matching or sorting text affect only filters that follow them. Filters run per
client before merging results and padding words to the shared menu boundary.

Omitting `filters` uses fuzzy matching followed by score sorting. `filters = {}`
performs neither filtering nor sorting. An explicit list overrides the legacy
`matcher` and `sorter` options, including those inherited from `"*"`.
The legacy options remain supported: `matcher(input, candidate)` returns a
numeric score or nil, and legacy sorters receive `candidate.score`. The pipeline
module is now `laser.filter`; update existing require calls accordingly. Its
`fuzzy` function returns a boolean and MatchInfo instead of a numeric score.

## Completion position

Laser uses each item's `textEdit.range.start` or `textEdit.insert.start` as its
completion boundary, converting the client's character offsets to byte offsets.
`CompletionList.itemDefaults.editRange` is also supported. Items without a usable
range fall back to the keyword boundary; no position callback is required.

Each candidate is matched against the input starting at its own boundary. The
menu starts at the earliest boundary among the displayed candidates. Candidates
that start later retain the intervening text, including when confirming snippets.
The original keyword boundary remains the session's reuse boundary, so a menu
position supplied by the server does not cause unnecessary requests while typing.

## Streaming completion

Laser sends `partialResultToken` and accepts completion batches through
`$/progress`. Each request accumulates its own candidates. An initial
`CompletionList` supplies `isIncomplete` and `itemDefaults` for subsequent
batches; a final `null` keeps the candidates already received. Refreshing a
client starts a new list. Cancelled and superseded requests cannot add items.
Partial notifications queued in the same event-loop turn share one render.

The pum adapter uses the same update policy for partial batches and late
responses from other clients:

- Before navigation, the entire list is filtered and sorted again. Automatic
  highlighting alone does not count as navigation.
- Once navigation starts, the prefix through the last visible item is frozen.
  Scrolling farther expands that prefix; returning upward or to the unselected
  position does not shrink it. Only the remaining candidates are filtered and
  sorted, including newly arrived candidates from higher-priority clients.
- Selection, inserted text, scroll position, menu dimensions and column widths
  stay stable. Candidates requiring an earlier completion boundary are retained
  for the next full update.
- Actual input or deletion releases the prefix. Closing the menu cancels its
  pending requests. An interrupted partial list is marked incomplete so further
  input can request it again.

Reversed menus preserve the prefix in completion order. Horizontal menus
conservatively retain the entire previously displayed list before new items.
The in-place pum integration uses internal pum APIs, isolated in
`lua/laser/ui/pum.lua` and `autoload/laser/pum.vim`, because `pum#open()` resets
selection and insertion state.

### Custom UI adapters

Existing `open(startcol, items, mode)`, `close()` and `visible()` adapters keep
working and receive full snapshots. Stable selection is opt-in through:

- `frozen_count()`: return the prefix length to retain, in the order of the
  items passed to `open`/`update`. Track the greatest seen extent until reset.
- `update(startcol, items, mode)`: replace the tail while retaining selection,
  viewport and insertion state. If omitted, the menu stays unchanged while
  `frozen_count()` is positive.
- `reset()`: release the navigation state after input or client invalidation.

## Request timeout

Set `clients[name].timeout_ms` (or `clients["*"].timeout_ms`) to bound a
completion request in milliseconds. Omitted or zero means no timeout.
When the deadline expires, only that client's request is cancelled; its previous
candidates remain available and late responses are ignored. Timers are stopped
on response, superseding requests, detachment, and session closure.
By default, the next `complete()` call retries the timed-out client. Starting
the retry clears its timeout flag; no background retry is scheduled.

## Refresh predicates

Set `clients[name].refresh` or a default in `clients["*"].refresh`. The predicate
runs once per reusable client on each `complete()` call (except UI selection
edits), including while a request is pending. A truthy return value requests a
new result for that client; false or nil keeps its candidates for local filtering.
Omitting `refresh` retries after a timeout, refreshes incomplete results, or
requests on trigger characters, or fetches again when that client has no matching
candidates and no request is pending.

```lua
local laser = require("laser")

-- Define the function outside the autocmd so its identity stays stable.
local function refresh(ctx)
  return ctx.timed_out
    or ctx.is_incomplete
    or laser.hasTriggerCharacter(ctx)
    or (not ctx.pending and not laser.has_candidate(ctx))
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
`ctx.is_incomplete` explicitly if incomplete responses should force a refresh,
and `ctx.timed_out` if timed-out requests should be retried.

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
| `has_candidate` | Whether this client has any candidates after filtering for the current input |
| `pending` | Whether this client has a request in flight |
| `timed_out` | Whether this client's last request timed out; false initially and cleared when the next request starts |

`laser.hasTriggerCharacter(ctx)` checks `inserted_char` against
`trigger_characters`. `laser.hasPattern(ctx, pattern)` matches a Lua pattern
against `before_cursor`; use `$` to anchor it at the cursor. Pattern matches can
also occur after deletions. `laser.has_candidate(ctx)` reads `has_candidate`:
only this client's candidates count, using its filters and each item's edit start,
independently of UI selection or other clients. All helpers use only the supplied
context. Filters may run for both the refresh decision and display; keep them
free of side effects.

If input advances during a request and its successful final response has no
matching candidates, laser also evaluates the predicate for the latest input
with `inserted_char = ""` and `pending = false`. This lets the default policy retry
without cancelling every pending request. An empty response for unchanged input
does not retry itself. Returning false from a custom predicate suppresses this
retry too. If any candidate still matches, this policy does not fetch missing
alternatives.

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
| `laser.filter` | ordered converter/matcher/sorter pipeline |
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

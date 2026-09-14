# laser.nvim

LSP-only completion for Neovim. Experimental.

Design goals:

- Sources are LSP clients, selected by client name. Unspecified means every attached client.
- Matcher and sorter are plain Lua functions, configurable per client.
- Existing candidates are reused while typing; incomplete lists and trigger characters
  re-query in the background and replace the menu when the answer arrives.
- Results from several clients are merged as they arrive.
- Command-line completion goes through a scratch buffer so the same clients serve `:`.
- The UI is pluggable. The first adapter targets [pum.vim](https://github.com/Shougo/pum.vim).

## Development

```sh
make test   # uses deps/mini.nvim, or MINI_NVIM_PATH
make fmt
```

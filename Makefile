MINI := $(or $(MINI_NVIM_PATH),deps/mini.nvim)
MINI_VERSION := v0.18.0
NVIM_TEST := MINI_NVIM_PATH=$(MINI) nvim --headless --noplugin -u ./scripts/minimal_init.lua

test: $(MINI)
	$(NVIM_TEST) -c "lua MiniTest.run()"

test_file: $(MINI)
	$(NVIM_TEST) -c "lua MiniTest.run_file('$(FILE)')"

deps/mini.nvim:
	@mkdir -p deps
	git clone --filter=blob:none --branch $(MINI_VERSION) https://github.com/nvim-mini/mini.nvim $@

fmt:
	stylua lua tests scripts

lint:
	stylua --check lua tests scripts

typecheck:
	VIMRUNTIME="$$(nvim --headless --clean -c 'lua io.stdout:write(vim.env.VIMRUNTIME)' -c q)" \
		lua-language-server --check=lua --checklevel=Warning \
		--configpath="$(CURDIR)/.luarc.json" --logpath="$(CURDIR)/deps/luals"

check: lint typecheck test

.PHONY: test test_file fmt lint typecheck check

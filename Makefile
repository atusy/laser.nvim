MINI := $(or $(MINI_NVIM_PATH),deps/mini.nvim)
NVIM_TEST := MINI_NVIM_PATH=$(MINI) nvim --headless --noplugin -u ./scripts/minimal_init.lua

test: $(MINI)
	$(NVIM_TEST) -c "lua MiniTest.run()"

test_file: $(MINI)
	$(NVIM_TEST) -c "lua MiniTest.run_file('$(FILE)')"

deps/mini.nvim:
	@mkdir -p deps
	git clone --filter=blob:none https://github.com/nvim-mini/mini.nvim $@

fmt:
	stylua lua tests scripts

.PHONY: test test_file fmt

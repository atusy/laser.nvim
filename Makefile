MINI := $(or $(MINI_NVIM_PATH),deps/mini.nvim)
PUM := $(or $(PUM_VIM_PATH),deps/pum.vim)
NVIM_TEST := MINI_NVIM_PATH=$(MINI) PUM_VIM_PATH=$(PUM) nvim --headless --noplugin -u ./scripts/minimal_init.lua

test: $(MINI) $(PUM)
	$(NVIM_TEST) -c "lua MiniTest.run()"

test_file: $(MINI) $(PUM)
	$(NVIM_TEST) -c "lua MiniTest.run_file('$(FILE)')"

deps/mini.nvim:
	@mkdir -p deps
	git clone --filter=blob:none https://github.com/nvim-mini/mini.nvim $@

deps/pum.vim:
	@mkdir -p deps
	git clone --filter=blob:none https://github.com/Shougo/pum.vim $@

fmt:
	stylua lua tests scripts

.PHONY: test test_file fmt

.PHONY: deps test helper test-helper bench

deps:
	@test -d deps/mini.nvim || git clone --depth 1 https://github.com/echasnovski/mini.nvim deps/mini.nvim

test: deps $(if $(shell command -v cargo),helper)
	nvim --headless --noplugin -u tests/minimal_init.lua -c "luafile tests/run.lua"

helper:
	cargo build --release --manifest-path helper/Cargo.toml

test-helper:
	cargo test --manifest-path helper/Cargo.toml

bench: deps
	nvim --headless --noplugin -u tests/minimal_init.lua -c "luafile tests/bench.lua" -c "qa!"

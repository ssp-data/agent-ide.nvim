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
	BENCH_DIR="$(DIR)" nvim --headless --noplugin -u tests/minimal_init.lua -c "luafile tests/bench.lua" -c "qa!"

.PHONY: test-omarchy
test-omarchy:
	node --test omarchy/io.github.sspaeti.agent-ide/test/*.test.js

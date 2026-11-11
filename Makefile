.PHONY: deps test helper test-helper bench release-notes release publish

deps:
	@test -d deps/mini.nvim || git clone --depth 1 https://github.com/echasnovski/mini.nvim deps/mini.nvim

test: deps $(if $(shell command -v cargo),helper)
	nvim --headless --noplugin -u tests/minimal_init.lua -c "luafile tests/run.lua"

helper:
	cargo build --release --manifest-path helper/Cargo.toml

test-helper: test-helper-release
	cargo test --manifest-path helper/Cargo.toml

# The speed budgets only hold (and only run) in an optimised build.
.PHONY: test-helper-release
test-helper-release:
	cargo test --release --manifest-path helper/Cargo.toml search

# Real Claude (subscription login; model haiku) in a temporary git repository; not part of `test`.
.PHONY: test-real
test-real: deps $(if $(shell command -v cargo),helper)
	timeout 1800 nvim --headless --noplugin -u tests/minimal_init.lua -c "luafile tests/real/run.lua"

# Real ACP agents (gemini --acp, opencode acp; their own logins) in temporary git repositories;
# not part of `test`. REAL_ACP_AGENTS="gemini" limits it.
.PHONY: test-real-acp
test-real-acp: deps
	timeout 1800 nvim --headless --noplugin -u tests/minimal_init.lua -c "luafile tests/real/acp.lua"

bench: deps
	BENCH_DIR="$(DIR)" nvim --headless --noplugin -u tests/minimal_init.lua -c "luafile tests/bench.lua" -c "qa!"

.PHONY: test-omarchy
test-omarchy:
	node --test omarchy/io.github.sspaeti.agent-ide/test/*.test.js

install-omarchy:
	cp -r omarchy/io.github.sspaeti.agent-ide ~/.config/omarchy/plugins/

# The changelog section that a release would carry (VERSION=x.y.z prints a released one).
release-notes:
	@scripts/release-notes.sh $(if $(VERSION),$(VERSION),Unreleased)

# Local only: changelog section, helper version, commit and annotated tag. `make publish` pushes.
release:
	@scripts/release.sh "$(VERSION)"

publish:
	@scripts/publish.sh "$(VERSION)"

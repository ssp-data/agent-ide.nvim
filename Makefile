.PHONY: deps test helper test-helper bench changelog release-notes release publish demo

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

# Neovim on the synthetic demo (demo/): sessions, repositories and prompts under /tmp/agent-ide-demo.
demo: $(if $(shell command -v cargo),helper)
	scripts/demo.sh

bench: deps
	BENCH_DIR="$(DIR)" nvim --headless --noplugin -u tests/minimal_init.lua -c "luafile tests/bench.lua" -c "qa!"

.PHONY: test-omarchy
test-omarchy:
	node --test omarchy/io.github.sspaeti.agent-ide/test/*.test.js

install-omarchy:
	cp -r omarchy/io.github.sspaeti.agent-ide ~/.config/omarchy/plugins/

# Print a changelog section: [Unreleased] by default, VERSION=x.y.z for a released one.
changelog:
	@scripts/changelog-section.sh $(if $(VERSION),$(VERSION),Unreleased)

# Draft RELEASE_NOTES.md (summary, highlights, fixes) with Claude Code from the changelog and the
# commits since the last tag (PREV=vX.Y.Z to override). Review and commit it before `make release`.
release-notes:
	@scripts/release-notes.sh "$(VERSION)" "$(PREV)"

# Local only, no tests (run `make test` before): changelog section, helper version, commit and
# annotated tag with RELEASE_NOTES.md as its message. `make publish` pushes.
release:
	@scripts/release.sh "$(VERSION)"

publish:
	@scripts/publish.sh "$(VERSION)"

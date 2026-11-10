# Part 1 follow-ups (open minor findings after final review)

None of these block part 1. Each was found in review and deliberately left.

## Backend parity edge cases
- vim.json accepts inputs serde_json rejects (NaN, Infinity, hex, leading zeros, raw control characters in strings; serde stops at 128 nesting levels). Such a line would render as an `unknown` fold on one backend and normally on the other. Claude Code never writes these.
- Transcript file names with invalid UTF-8: Rust uses lossy conversion, Lua keeps raw bytes.
- `lua_number` prints negative zero as `0`.

## Lifecycle
- Drawer visibility is re-checked on WinClosed, TabEnter and close only; `:e` in the drawer window or `<C-w>T` keeps polling running.
- `fs_realpath` on absolute worktree gitdirs can split a worktree from its repo when the repo sits under a symlinked path.
- `setup()` called again can remove a user's remap of the toggle key.
- `main_win` accepts quickfix/help/terminal windows as the main window.
- History winbar state is a snapshot taken when the history opens.

## Speed
- Very large histories (80 MB): rendering is synchronous, about 110-150 ms UI block; total open about 0.2 s with the helper. Budget only covers 1 MB.
- Lua history reads the whole file before chunked parsing.
- Lua change detection rescans every 5 s while the drawer is visible; a stat pass first would avoid that.
- Cold-scan budget test uses small files only.

## Tests
- Helper-client tests write to the real `stdpath('cache')/agent-ide`; point them at a temp cache dir.
- `watch.rs` test and one UI debounce test rely on fixed waits.
- No test asserts timer cancellation, the skip-tick-while-in-flight guard, or `live.stop()` on tab close.
- Renderer: Edit with nil old/new string emits an empty `- `/`+ ` line; duplicate tool call ids share results; subagent "(n events)" counts results shown inside their call.
- Titles: control characters other than CR/LF are not normalised.

## Before publishing
- README install snippet still has the placeholder `your-github-user/Agent-IDE.nvim`.
- Decide whether `docs/superpowers/` (design and plans, with personal paths and project names) should be public.
- An old `index-v1.json` may remain in the cache directory; harmless.

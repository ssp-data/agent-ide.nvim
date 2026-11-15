# Review comments, round 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Comments stay until their prompt is sent; the Commits section's `full diff` row lists its files; the full diff's winbar names the file under the cursor.

**Architecture:** Small additions to the modules of round 1: a `in_prompt` flag in the store and a buffer mark on the prompt (`vim.b.agent_ide_review`) that `chat_send.deliver` reads; a fold row in `git_sections.lua` over `cache.committed`; a `CursorMoved` autocmd in `fulldiff.lua` feeding `winbar()`.

**Tech Stack:** Lua, Neovim 0.12, mini.test.

**Spec:** `docs/superpowers/specs/2026-11-15-review-comments-design.md`, section "Round 2".

## Global Constraints

As round 1: AGENTS.md rules 3, 4, 8, 10, 11; keys through `util/keys.lua`; highlight groups `default = true`; README, CHANGELOG, AGENTS.md updated in the same commits; commits by explicit paths on `in-line-git-comments`.

## Review Focus

1. The prompt holds the review, the user deletes its text by hand and sends something else: the comments must stay (the sent text no longer contains the intro line). Pinned in Task 1.
2. `gs` twice without sending: the prompt must hold one review text, not two (`Replace the draft` first). Pinned in Task 1.
3. The Commits section lists `Recent commits` (default branch): the `full diff` row's files are those of the commits scope there too (`cache.committed`). Pinned in Task 2.
4. The cursor on a blank line between files, or on the header: the winbar names that file; on the `loading…` line nothing. Pinned in Task 3.

---

### Task 1: Comments stay until their prompt is sent

**Files:** Modify `lua/agent-ide/review.lua` (`M.mark(root, ids, fields)`; `take` keeps `in_prompt`), `lua/agent-ide/ui/review_marks.lua` (an `↑ in prompt  ` dim chunk after the kind), `lua/agent-ide/ui/review_send.lua` (`put` marks and sets `vim.b[pbuf].agent_ide_review = { root, ids, intro }`; `done` no longer clears after a put; `Replace the draft` first when any comment is in the prompt; `M.sent_from_prompt(mark)`), `lua/agent-ide/ui/chat_send.lua` (`deliver`, prompt path, ok: when `vim.b[c.pbuf].agent_ide_review` exists and `text` contains its `intro`, call `review_send.sent_from_prompt`; the mark is dropped either way), `lua/agent-ide/ui/fulldiff.lua` (winbar `3 comments, 2 in the prompt`). Tests: `tests/test_review.lua` (`mark`), `tests/test_review_ui.lua`.

- [ ] Tests first: `mark` round-trips `in_prompt`; UI: after `gs` the comments stay with the `↑ in prompt` chunk and the count; a second comment then `gs` offers `Replace the draft` first and the prompt holds one text with both; sending the prompt through the chat (`<C-CR>` with the fake) clears them; deleting the prompt's text and sending other text keeps them.
- [ ] Run, see them fail. Implement. Run `TEST_FILE=tests/test_review.lua`, `tests/test_review_ui.lua`, `tests/test_chat.lua`.
- [ ] Docs: README (the Review comments paragraph: "stay until sent"), docs/review.md step 5 and the paragraph after it, CHANGELOG (the Added entry), AGENTS.md ruling line. Commit.

### Task 2: The Commits section's `full diff` row expands to its files

**Files:** Modify `lua/agent-ide/ui/git_sections.lua` (`fulldiff_row(out, w, ctx, parent, kind)`: for `kind == 'commits'` a fold row keyed `w.root .. '/git/fulldiff'` with the open/closed icon; open: `cache.committed(w.root)` files through `files_rows(..., 'commits', nil, open_fulldiff)` or `loading…`), `files_rows` gains an `open` parameter (default `open_diff`), `lua/agent-ide/ui/fulldiff_open.lua` (`git_file` with `mode == 'commits'` opens the commits scope with the file focused). Tests: `tests/test_git_sections.lua` (the row closed and open, nodes), `tests/test_fulldiff_ui.lua` (`<CR>` on a file under the row opens the commits scope on that file).

- [ ] Tests first, run, implement, run `tests/test_git_sections.lua`, `tests/test_fulldiff_ui.lua`, `tests/test_git_ui.lua`.
- [ ] Docs: README (Git section: the row expands; the full diff paragraph), CHANGELOG. Commit.

### Task 3: The winbar names the file under the cursor

**Files:** Modify `lua/agent-ide/ui/fulldiff.lua` (`winbar()` starts with `%#AgentIdeFullDiffFile#<path>%*` when `V.cur_file` is set; a buffer-local `CursorMoved` autocmd sets `V.cur_file` from `t.nodes[row].file` and refreshes the winbar only when it changed; `draw` sets it from the cursor), `lua/agent-ide/ui/git_hl.lua` (`AgentIdeFullDiffFile = { bold = true }`). Tests: `tests/test_fulldiff_ui.lua` (the winbar starts with the file; moving to another file changes it; the `loading…` state has none).

- [ ] Tests first, run, implement, run `tests/test_fulldiff_ui.lua`, `tests/test_review_ui.lua`.
- [ ] Docs: README (full diff paragraph: the winbar example), CHANGELOG. Commit.

### Task 4: Full suite and hand-off

- [ ] `make test` green (background run), ledger, final message with the tuicr findings.

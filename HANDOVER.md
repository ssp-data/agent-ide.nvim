# Hand-over (2026-11-10)

State of Agent-IDE.nvim for whoever picks it up next. Rules, layout and commands are in `AGENTS.md`; the feature list is in `CHANGELOG.md` under `## [Unreleased]`; the design is in `docs/superpowers/specs/2026-11-10-agents-ide-design.md` (section 14: changes since approval).

## Where things are

- Branch `dev` holds everything. `main` is what is published; merging `dev` into `main`, `make release VERSION=0.1.0` and `make publish VERSION=0.1.0` are the owner's steps.
- Tests on `dev`, run alone: `make test` 791 cases, 0 fails; `make test-helper` all pass.
- Run test suites one at a time. Several suites in parallel make the timing budgets and child-Neovim waits unreliable.
- `make test-real` (real Claude, uses the subscription) was last run when the chat was built; it has not been run against the features added since.

## What exists

| Area | Entry points |
|---|---|
| Drawer | `:Agents`, `<leader>aa`; `g?` lists every key |
| Project scope | `scope = 'project'`, `:Agents project`, `:Agents all`, `gs` |
| Chat | prompt buffer + transcript; `<C-CR>` / `<leader><CR>` send; `/` command menu; `@` attach; `<leader>aM` model; `<S-Tab>` mode; `<C-c>` interrupt; `<leader>at` native Claude; `gr` raw view |
| Permissions | answered in Neovim; `<leader>an` next session that needs you |
| Git | Changes / Commits sections; diff view (`]c` `[c` `]f` `[f` `gb` `gB`); `gd` on an edit; `glg` lazygit |
| Commit graph | `gG`, `:AgentsGraph` |
| Search | `<leader>as`, `s`; `<leader>aP` prompt history; `]n` `[n` matches |
| Prompts | Prompts node; `:w` / `ZZ` save per project; `<leader>W` to the library |
| Sessions housekeeping | `H` hide; `D` delete to trash, `:AgentsTrash`; `X` close a terminal Claude, `:AgentsCloseIdle`; `zM` `zR`; `gL` legend |
| Status | statusline component, per-Neovim status file, Omarchy widget |

## Verified by tests only, never seen on a screen

Everything was built without a display. These need a human look first:

1. Omarchy bar widget (QML never run).
2. Commit graph on real repositories: lanes, corners, badges, narrow widths.
3. Legend float at the bottom of the drawer, with `laststatus` 2 and 3, on resize and tab switches.
4. Buffer names (`agents://<project>/<title>`) in a tabline or bufferline; no `[No Name]` left in the Agents tab.
5. Chat header colours, the italic model, the mode badge.
6. The `/` menu together with nvim-cmp; `<M-n>` / `<M-p>` in the search picker through the terminal and tmux.
7. `<C-CR>` through tmux (extended keys); `<leader>at` hand-over to a tmux pane and back.
8. Permission pickers with a `vim.ui.select` replacement (Snacks): never while typing.

## Handle with care

- **Delete (`D`)** moves files out of Claude's folder and edits Claude's `history.jsonl`. It was reviewed and hardened (confirm first, checks again afterwards, backup flushed before anything is touched, every failure step undone and tested). First real use: try it on a throwaway session, check `:AgentsTrash` restore brings it back, then trust it. The trash keeps the content until `:AgentsTrash empty`.
- **Close (`X`, `:AgentsCloseIdle`)** types Ctrl-C twice into a tmux pane, only after verifying that this Claude is the pane's foreground program. The verification was tested with fake `ps` and `tmux`, not against real panes. First real use: one idle terminal Claude you do not need.
- Known limits of delete: the "history file is open" check exists on Linux only; a crash before the first manifest leaves an unlisted folder in the trash (files safe); `todos/` and `debug/` files of a session are not moved (none exist on the development machine).

## Open items

Small, known:

- `lua/agent-ide/prompts/store.lua` checks `fs_write` only for non-nil (short writes); `util/jsonfile.lua` has a safe writer to reuse.
- `lua/agent-ide/trash.lua` (about 450 lines) and `ui/prompt.lua` (about 700) are over the size the conventions ask for.
- Scratch buffers that `ui/delete.lua` puts into emptied windows are unnamed.
- A `vim.ui.select` provider that never calls back leaves the `@` picker state set until the buffer is left.
- "Allow for this session" on a permission is offered only as far as Claude's suggestions were verified.
- Changes list refreshes after a turn only for sessions run in this Neovim.
- No key inside the chat jumps to the tmux pane of a session running elsewhere (`gp` in the drawer does).

From the design, not built:

- Idle-timeout setting for parked processes (design section 12).
- Prebuilt helper binaries (section 9.2); `cargo` is needed for the fast path.
- Other agents through ACP (part 6): plan in `docs/superpowers/plans/2026-11-10-part-6-other-agents.md`, deliberately deferred until the owner asks.

Owner's feedback, not acted on:

- `docs/superpowers/plans/2026-11-10-feedback-round-1.md`: the appendix compares the owner's mock with the real views (permission float, slash float, combined model/mode float, one-line search rows, richer fold headers). None of those were built.
- `feedback.md` in the repository root is the owner's running list for the next round. Read it first.

## A thorough test pass, in order

1. `:Agents` in a repository with history: rows, states, ages, `g?`, legend, `zM` / `zR`, `H` on a few sessions.
2. Project scope: `gs` on a project row, search inside it, `<Tab>` to widen, `:Agents all` back.
3. New session: write a prompt with an `@` attachment mid-sentence, send, watch streaming, answer a permission, switch model and mode, interrupt.
4. `/` on an empty prompt line: full list, narrows while typing, `/model` and `/copy`.
5. Save the prompt (`:w`), reuse it from the drawer, save one to the library (`<leader>W`).
6. Let Claude edit a file: `gd` on the edit, the Changes section, the diff view keys, `gG` graph, `glg`.
7. Search for two words where one is only in the title; step with `]n`; open the hit.
8. Second Neovim or a terminal Claude on the same project: rows show `tmux w.p`, sending is refused, `gp` jumps.
9. Footer and Omarchy widget while sessions change state; hide the drawer for a minute and look again.
10. `<leader>at` and back.
11. Only then: `D` on a throwaway session with restore, and `X` on a spare terminal Claude.

## Decisions taken on the owner's behalf

Recorded as `Ruling:` lines in the build ledger. The ones that shape behaviour:

- A hidden session that needs attention is shown as normal while that lasts.
- In project scope the footer counts only that project; the status file for the bar stays global; a last drawer line counts sessions of other projects that need you.
- `<C-c>` on a drawer session row asks first; in the chat it interrupts at once.
- Quota is never read through credentials or the network; `quota.file` reads a local file another tool writes.
- Over-long lines are cut for display with a counted marker; the raw view keeps everything.
- Templates and saved prompts are loaded and saved byte for byte, frontmatter included.
- Permission rules are offered only where Claude suggests them.

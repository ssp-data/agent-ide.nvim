# Agent-IDE.nvim: notes for coding agents

Instructions for any AI coding agent (and a quick orientation for humans) working in this repository. `CLAUDE.md` imports this file, so there is one source of truth.

## What this is

A Neovim plugin that manages Claude Code sessions from inside Neovim: a drawer with every session grouped by git repository, a chat in native buffers (a prompt buffer and a markdown transcript), git review (changes, commits, diffs, a commit graph), fuzzy search over all sessions, reusable prompts, and a status for the statusline and an Omarchy bar widget. Lua for everything the user sees, a small Rust helper for scanning, search and file watching.

- Lua module: `agent-ide`. Command: `:Agents`. Global keys under `<leader>a`.
- Design document: `docs/superpowers/specs/2026-11-10-agents-ide-design.md` (section 14 lists what changed since approval). Plans per part are in `docs/superpowers/plans/`.
- Observed Claude Code stream protocol: `docs/protocol.md`.
- Open items and decisions taken on the owner's behalf: the end of this file.

## Layout

| Path | Purpose |
|---|---|
| `plugin/agent-ide.lua` | user commands |
| `lua/agent-ide/init.lua`, `config.lua` | setup, defaults, global keys |
| `lua/agent-ide/prefs.lua` | `prefs.json`: the model last used (what a new session starts with), the legend toggle |
| `lua/agent-ide/sound.lua` | the chime when a session needs you (`chime.wav` in the cache folder, a system player) |
| `lua/agent-ide/claude/` | starting Claude Code (directly or through a keeper), stream parsing, version guard |
| `lua/agent-ide/keeper/` | the keeper (`main.lua`, run by `nvim -l`, owns a Claude's pipes and outlives Neovim), its client, discovery; `session/attach.lua` reattaches a Session |
| `lua/agent-ide/session/` | session object, states, prompt queue, actions |
| `lua/agent-ide/transcript/` | parsing transcripts into events, rendering events into lines and folds; `ansi.lua` reads the colour codes of tool output |
| `lua/agent-ide/index/`, `search/` | talking to the helper, Lua fallbacks |
| `lua/agent-ide/git*.lua` | read-only, asynchronous git queries, parsing, cache; `git_patch.lua` the full diff's patch per scope and its untracked reads |
| `lua/agent-ide/prompts/` | prompt library, skills and commands, saved prompts |
| `lua/agent-ide/ui/` | drawer, chat, prompt, permission, diff, graph, search picker, help palette, highlights, icons |
| `lua/agent-ide/ui/ask_float.lua` | the window for Claude's asks (permission, question, plan): the question's rows, a rule, numbered choices; `chat.ask_picker = 'select'` uses `vim.ui.select` instead |
| `lua/agent-ide/ui/drafts.lua` | the prompt buffer's text kept in `drafts/<session id>.md`, brought back when the prompt opens |
| `lua/agent-ide/ui/prompt_label.lua` | the prompt window's winbar (`↑ title · model`); which session a prompt window should follow |
| `lua/agent-ide/ui/queue.lua`, `queue_edit.lua`, `queue_activity.lua` | the queue panel (`Q`): prompts sent, running and queued, left of the transcript; `e`, `dd`, `J`, `K` on queued ones; below them the session's size and its turn's requests and subagents |
| `lua/agent-ide/session/activity.lua` | what a turn does, from the stream's `call`, `task`, `thinking` and `result` actions and the Agent and TodoWrite calls (pure): requests and tokens, a cache written again, subagents, background shells, todos, the last turn per model |
| `lua/agent-ide/ui/drawer_legend.lua`, `drawer_session_keys.lua` | the drawer's legend of state marks (`gL`, remembered in `prefs.json`); the chat's keys on a session row |
| `lua/agent-ide/ui/graph.lua`, `graph_render.lua`, `graph_keys.lua`, `graph_context.lua` | commit graph: window, pure lane layout, keys, which repository |
| `lua/agent-ide/ui/fulldiff.lua`, `fulldiff_render.lua`, `fulldiff_keys.lua`, `fulldiff_open.lua`, `fulldiff_cursor.lua` | full diff (`gd`, `:AgentsDiff`): window and reload, pure rendering of a patch into lines and folds, keys, a drawer row to its scope and `<CR>` into the side-by-side view, cursor and fold state across redraws |
| `lua/agent-ide/ui/tmux_close.lua`, `tmux_verify.lua` | closing a Claude in a tmux pane (`X`, `:AgentsCloseIdle`); the checks before any key is typed |
| `lua/agent-ide/ui/delete.lua`, `lua/agent-ide/trash.lua`, `trash_fs.lua`, `trash_history.lua` | deleting a session (`D`) into the trash, `:AgentsTrash` restore and empty |
| `lua/agent-ide/ui/search_hl.lua` | marks of a search query in a transcript window (`]n`, `[n`) |
| `lua/agent-ide/ui/bufname.lua` | names of the plugin's buffers (`agents://<project>/<title>`, …) |
| `lua/agent-ide/hidden.lua` | hidden sessions (`H`), kept in `hidden.json` |
| `lua/agent-ide/names.lua` | session names (`r` on a session row), kept in `names.json`; applied to the drawer's rows and to search hits |
| `lua/agent-ide/scope.lua` | project scope or all: what the drawer, search, next waiting and the footer show |
| `lua/agent-ide/session/commands.lua` | Claude's command list per project for the `/` menu, kept in `commands.json` |
| `lua/agent-ide/claude/models.lua`, `models_fetch.lua` | the models Claude lists in its `initialize` answer, kept in `models.json`; the one-off fetch for the picker |
| `lua/agent-ide/claude/usage.lua`, `session/context.lua`, `ui/context_ask.lua` | the size of a conversation from `usage` objects (pure) and from a transcript's tail; the questions before a resume and before parking, the `/compact` key |
| `lua/agent-ide/util/jsonfile.lua` | private JSON files, read leniently and written atomically |
| `lua/agent-ide/status.lua`, `live.lua`, `tmux.lua` | footer and status files, sessions running elsewhere, tmux |
| `demo/`, `scripts/demo.sh`, `scripts/demo-screenshot.sh` | synthetic demo data and fake `claude` for `make demo`, and the README screenshots (no real data; the screenshot script needs Hyprland, foot and grim) |
| `helper/` | Rust helper `agent-ide-helper` (scan, history, watch, search) |
| `omarchy/` | Omarchy bar widget |
| `tests/` | mini.test suite, fixtures, fakes; `tests/real/` talks to real Claude |

## Commands

```sh
make test          # Lua suite (builds the helper when cargo exists); must stay green
make test-helper   # Rust tests
make helper        # build the helper after changing helper/ or pulling
make test-omarchy  # widget tests (node)
make test-real     # real Claude on the subscription; not part of `make test`, run on purpose only
make changelog     # print the [Unreleased] changelog section (VERSION=x.y.z for a released one)
make release-notes VERSION=x.y.z   # draft RELEASE_NOTES.md with Claude Code; see "Releasing"
make demo          # Neovim on the synthetic demo (demo/, see demo/README.md) under /tmp/agent-ide-demo; you drive, for screenshots
make release VERSION=x.y.z   # see "Releasing"
```

Run one file or case: `TEST_FILE=tests/test_tree.lua make test`, `TEST_CASE='text of the case' make test`.

## Rules that are not negotiable

1. **Fidelity.** What Claude sent is what the user sees. Nothing is dropped or altered silently; unknown events are shown as `unknown` folds; anything cut for display carries a counted marker and the raw view (`gr`) keeps everything. Colour codes (SGR) in tool output are shown as the colours they stand for, as a terminal would; other escape sequences stay in the text. The Lua parser (`transcript/parse.lua`) and the Rust parser (`helper/src/events.rs`) must produce the same events: change both, bump `RULES_VERSION` in both, and keep the parity tests green.
2. **Prompts are sent verbatim.** Templates and saved prompts are loaded and saved byte for byte.
3. **Never interrupt typing.** No focus changes, no pop-ups while the user types; permission requests and results wait. Nothing synchronous on a keystroke.
4. **Speed.** The budget tests (`tests/test_budget.lua`, `test_git_budget.lua`, `test_graph_budget.lua`, `test_fulldiff_budget.lua`, `test_search_budget.lua`, with `budget_lib.lua`, and the helper's search budgets in `make test-helper`) are requirements; never weaken them. No synchronous git or file scanning on the UI thread.
5. **Subscription only.** Claude runs through the Claude Code CLI; `ANTHROPIC_API_KEY` is stripped from every child process. Never read credentials, never call the network from the plugin.
6. **The plugin works without the helper.** Every helper feature has a Lua fallback (search is limited there).
7. **Git is read-only.** Queries use `--no-optional-locks`; staging, committing and the like are left to lazygit.
8. **Writes stay in the plugin's own folders** (`stdpath` data, state, cache, and the runtime dir, where the status files and the keepers' json files and sockets live), files 0600 in 0700 folders, written atomically. The only writes inside Claude's folder are the explicit, confirmed session delete and its restore; the trash (a 0700 folder) keeps the moved files with their own modes.
9. **Never stop a Claude process the plugin did not start** (a Claude under one of the plugin's keepers is one it started, from any Neovim), with one exception: the explicit, confirmed close of a Claude in a tmux pane (`X` in the drawer, `:AgentsCloseIdle`), which types Claude's own exit keys (Ctrl-C twice) into that pane and never sends it a signal. The confirm comes first; afterwards, before any key, a fresh `claude agents` must still list the session with the same process (still idle where idle was confirmed), and `ps`/`tmux` must show that process as a Claude (`claude` or `node`) whose process group is the foreground group of a tmux pane's terminal, with the pane in no mode and not synchronized (`ui/tmux_verify.lua`); anything else, or anything that cannot be checked, sends nothing. Never let two Claude processes drive one session.
10. **No dependencies** on other plugins. Neovim 0.12+. Optional integrations are guarded (`pcall`, `package.loaded`).
11. **Privacy.** The repository is public. No personal paths, names of private projects, real session ids, or content from real transcripts in code, tests, docs or commits. Fixtures are synthetic. Tests run with data, cache, state and runtime dirs pointed at temporary folders (`tests/run.lua`) and must not touch the real ones.

## A trap worth knowing

With `conceallevel >= 2`, Neovim asks the treesitter highlighter about every row it needs a height for, and each answer is its own range parse. On a transcript of 20 000 lines that froze Neovim for minutes as soon as the cursor entered the window. `lua/agent-ide/util/ts_conceal.lua` switches that per-row check off for transcript buffers (a private flag of the highlighter; `tests/test_ts_conceal.lua` holds a budget for it). If a long transcript ever feels stuck again, start with `AGENT_IDE_WATCHDOG=1 nvim` and read `stuck.log`.

## Conventions

- Match the surrounding code: comment density, naming, idiom. Keep files focused (about 350 lines is a good ceiling).
- Pure logic stays pure and tested without a window (`ui/tree.lua`, `ui/layout.lua`, `ui/graph_render.lua`, `ui/fulldiff_render.lua`, `transcript/render.lua`, `git_parse.lua`).
- Every configurable key goes through `lua/agent-ide/util/keys.lua` and accepts a key, a list of keys, or `false`. New keys are added to the view's help (`g?`) and the README key tables. Do not shadow common Vim keys where the user edits text (the prompt buffer, the real file in the diff view).
- Highlight groups are defined with `default = true` and re-applied on `ColorScheme`. Dimmed text is never italic.
- Test first where behaviour changes. Child Neovims in tests are headless with a timeout; wait on conditions rather than fixed sleeps. Tests never start a real `claude`; use the fakes in `tests/`.
- User-facing text is plain and short. The README is written for a public audience.

## Keeping the docs current

With every user-visible change, in the same commit or pull request:

- add a line to `CHANGELOG.md` under `## [Unreleased]` (Added / Changed / Fixed / Removed), written for users, not as a commit log;
- update the README sections it touches (keys tables, configuration block, privacy list of written files);
- update this file when a rule, a command or the layout changes.

## Open items

Small, known:

- `lua/agent-ide/prompts/store.lua` checks `fs_write` only for non-nil (short writes); `util/jsonfile.lua` has a safe writer to reuse.
- `lua/agent-ide/trash.lua` (about 450 lines) and `ui/prompt.lua` (about 700) are over the size the conventions ask for.
- Scratch buffers that `ui/delete.lua` puts into emptied windows are unnamed.
- A `vim.ui.select` provider that never calls back leaves the `@` picker state set until the buffer is left.
- "Allow for this session" on a permission is offered only as far as Claude's suggestions were verified.
- The Changes list refreshes after a turn only for sessions run in this Neovim.
- No key inside the chat jumps to the tmux pane of a session running elsewhere (`gT` in the drawer does).
- Delete (`D`): the "history file is open" check exists on Linux only; `todos/` and `debug/` files of a session are not moved.
- `make test-real` has not been run against the features added after the chat was built (`initialize`, `--resume` with `--model`).

From the design, not built: an idle-timeout setting for parked processes (design section 12); prebuilt helper binaries (section 9.2); other agents through ACP (part 6, `docs/superpowers/plans/2026-11-10-part-6-other-agents.md`), deferred until the owner asks. The owner's feedback rounds are `docs/superpowers/plans/2026-11-10-feedback-round-1.md` and `docs/superpowers/specs/2026-11-10-feedback-round-2-design.md`; the appendix of round 1 lists mock views (permission float, slash float, richer fold headers) that were not built.

Decisions taken on the owner's behalf, recorded as `Ruling:` lines in the build ledger; the ones that shape behaviour: a hidden session that needs attention is shown as normal while that lasts; in project scope the footer counts only that project, the status file for the bar stays global; `<C-c>` on a drawer session row asks first, in the chat it interrupts at once; quota is never read through credentials or the network; over-long lines are cut for display with a counted marker, the raw view keeps everything; templates and saved prompts are loaded and saved byte for byte; permission rules are offered only where Claude suggests them; `<S-Tab>` in the drawer is the scope key on every row, so the chat's mode cycle is not on a session row; `y` on a session row yanks its last prompt. A foreground task's `task_*` stream objects (and `background_tasks_changed`) add no fold: the task's own tool call shows it.

## Releasing

Versions follow semantic versioning; tags are `vX.Y.Z`.

1. `make release-notes VERSION=0.1.0` drafts `RELEASE_NOTES.md` from the `## [Unreleased]` section and the commits since the last tag (`PREV=vX.Y.Z` to override), with Claude Code (`claude -p`, prompt in `scripts/release-notes-prompt.md`): a short summary of what changed, **Highlights** and **Fixes**. Without `claude` it writes the sources into the file for editing by hand. Review it and commit it.
2. `make release VERSION=0.1.0` does not run the tests (run `make test` before). It requires a clean tree on `main` and a `RELEASE_NOTES.md` changed since the last tag, then renames the Unreleased section to the version with today's date, opens a fresh Unreleased section, sets the helper's version, commits `release vX.Y.Z` and creates an annotated tag with `RELEASE_NOTES.md` as its message. It does not push.
3. Publishing is a separate, deliberate step: `make publish VERSION=0.1.0` pushes `main` and the tag and creates the GitHub release from the tag's `RELEASE_NOTES.md` (needs `gh`).

## Git etiquette

- Work on a branch (currently `dev`); `main` is what is published. Do not push or publish unless asked.
- Commit messages: short imperative subject, body only when it adds something.

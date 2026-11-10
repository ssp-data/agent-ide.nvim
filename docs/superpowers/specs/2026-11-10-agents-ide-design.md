# Agent-IDE.nvim — Design

Date: 2026-11-10
Status: approved 2026-11-10
Author of decisions: Simon (sspaeti), unless marked **[builder's call]** (decided by the design author, open to veto).

## 1. Intent

Simon works entirely in tmux + Neovim and runs about ten Claude Code sessions across many projects at once. Today he manages them with a tmux fuzzy finder (`tmux-claude-session-manager`). It lists sessions but he cannot tell which one is which, what each last did, or which is active. He keeps sessions around on purpose so he can come back to them with their context intact.

He loves `vim-dadbod-ui`: a drawer tree on the side, "New query", saved queries, results in a normal buffer. He wants the same idea for agents: **an agent IDE inside Neovim**, tied closely to git review, because reviewing what an agent changed is half of working with agents.

A throwaway spike (`spike/agent_spike.lua`) proved the core idea and shaped this design. His reaction to Claude's answers appearing as rendered markdown in a normal Neovim buffer: "this is AMAZING". That is the heart of the product.

## 2. Goals

1. **See everything at a glance.** One drawer lists every project and every Claude session, including very old ones and ones started from another path, each with a readable title, state and age.
2. **Talk to Claude in native Neovim buffers.** Prompts are written in a normal buffer with all of Vim; answers stream into a markdown buffer that his markdown renderer displays; tool calls are folds.
3. **Review agent work with git, built in.** Browse the whole branch's changes and single commits as diffs, without leaving Neovim and without extra plugins.
4. **One Neovim for all projects.** Switching project in the drawer switches sessions and git context. No second Neovim per project.
5. **Reusable prompts.** A library of prompt templates plus his existing Claude skills/commands, one keypress away.
6. **Other agents later.** Claude Code is the main target. The design must not block adding Codex, Gemini CLI and opencode.

## 3. Non-goals

- Git *actions* (stage, commit, rebase, push). Those stay in lazygit, which the plugin opens on the selected project.
- GitHub PR review, CI logs, notifications (guh.nvim / octo.nvim territory). May come later; not designed here.
- Replacing tmux. tmux stays his session manager; the plugin cooperates with it.
- Rebuilding Claude Code's screen-only features (`/config`, `/mcp`, login, pickers). The escape hatch covers them.
- Billing through an API key. See 5.1.

## 4. Anti-goals (would make him drop it within a week)

1. **Mismatch between what Claude sent and what he sees.** Any dropped or altered information.
2. **Prompts mangled on the way to Claude.** What he wrote must be what Claude receives.
3. **Slowness.** Interacting must feel at least as fast as Claude Code's own screen, ideally faster.

These three drive section 8 (fidelity) and section 9 (speed). They outrank every feature.

## 5. Constraints

### 5.1 Subscription only
Claude must run through the Claude Code CLI on his Max subscription. Verified in the spike: screenless Claude prefers `ANTHROPIC_API_KEY` from the environment over the claude.ai login. The plugin therefore removes `ANTHROPIC_API_KEY` from the environment of every Claude process it starts, by default. A setting can turn that off for users who want API billing.

### 5.2 Environment
- Neovim 0.12.6, lazy.nvim, leader is Space. Rust toolchain installed (cargo 1.99).
- Claude Code 2.1.306. tmux with extended keys on.
- Free key prefix: `<leader>a…` (taken: `<leader>am` MCPHub; buffer-local `<leader>a`, `<leader>as` in neomd buffers).
- His config lives in `~/git/general/dotfiles/nvim/.config/nvim` (stowed to `~/.config/nvim`); the plugin may be wired in there.
- Existing plugins it must coexist with: lualine (footer), a markdown renderer, Snacks (has lazygit), vim-tmux-navigator (`<C-hjkl>`), diffview, dadbod-ui (drawer on the right).

### 5.3 Language
Simon wants it fast and asked for Rust/C where speed matters. Decision in 9.2.

## 6. How Claude is driven (verified in spike)

Claude Code runs as a long-lived child process without its screen:

```
claude -p --verbose --input-format stream-json --output-format stream-json
       --include-partial-messages --permission-prompts host
       --permission-prompt-tool stdio  (--session-id <uuid> | --resume <id>)
```

Verified on 2.1.306:

| Capability | How | Verified |
|---|---|---|
| Send prompt | JSON line `{"type":"user","message":{"role":"user","content":…}}` on stdin | yes |
| Streaming answer | `stream_event` / `content_block_delta` / `text_delta` | yes |
| Tool calls and results | `assistant` message with `tool_use`; `user` message with `tool_result` | yes |
| Switch model mid-session | control request `set_model` | yes, context kept |
| Switch permission mode mid-session | control request `set_permission_mode` (manual, acceptEdits, plan, auto) | yes |
| Claude's native permission ask | control request `can_use_tool` from Claude; reply allow/deny. Needs `--permission-prompt-tool stdio` | yes |
| Slash commands | sent as prompt text (`/context`); session's `init` event lists all commands incl. user skills | yes |
| Resume a session in a new process | `--resume <id>` | yes |
| Quota | `rate_limit_event` with 5-hour and 7-day utilization | yes |
| Interrupt | control request `interrupt` | sent in spike, effect not verified |
| Live sessions elsewhere | `claude agents --json`: pid, cwd, sessionId, name, status (busy/waiting/idle) | yes |
| Session history | `~/.claude/projects/<slug>/<session>.jsonl`, incl. `ai-title`, `cwd`, `gitBranch` | yes |

Not yet verified, must be checked during the build before relying on them:
- Hand-off to the real Claude screen in a tmux pane and back (flags exist; round trip untested).
- How interactive tools arrive (plan approval, Claude asking the user a multiple-choice question, image content).
- Whether a per-model weekly quota window is reported on Opus/Fable sessions.
- `<C-CR>` reaching Neovim through his terminal + tmux.

The stream format is Claude Code's own and may change between versions. Section 8 says how the plugin stays honest when it does.

## 7. What it looks like

### 7.1 Drawer

Toggled with one key **[builder's call: `<leader>aa`, command `:Agents`]**. Sits on the right like his dadbod drawer. Nerd-font icons per node type, bold project names, colors by state.

```
▾ 󰚩 Prompts
  ▸ Skills & commands (12)
  ▸ Library (30)
▾  neomd                     ◐ now
     New session
  ▾ Sessions (14)
      ◐ Shorter signature trigger alias      now
      ○ Missing image in screener.md         5d
  ▸ Saved prompts (3)
  ▸ Changes vs origin/main (8)
  ▸ Commits on branch (7)
▸  ff10k                     ● 2m
▸  dotfiles                  ○ 2d
```

- **Projects**: one row per **git repository**, newest activity first. All sessions started anywhere inside a repo (sub-folders, worktrees) fold into that one row; a session started in a sub-folder shows its sub-path. He wants to see at a glance that he worked on the same repo several times. A folder without git still gets a row and full chat features, just without the Changes and Commits nodes. Folders that no longer exist keep their sessions viewable. Top row shows name, combined state, age of last activity. Branches are not shown on the top row; they appear inside.
- **States**: busy (Claude working), waiting (needs him: permission or question, with the reason shown), idle (alive, nothing to do), parked (no process; history on disk). Parked sessions are dimmed, never hidden.
- **Sessions**: titled with Claude's own session title, falling back to the first prompt. All sessions are listed regardless of age.
- **Enter** on a node opens it in the main window at full size; the drawer can be toggled away. `za` toggles tree nodes. `R` refreshes. `gl` opens lazygit on that project.

### 7.2 Chat view (Enter on a session or "New session")

```
┌ neomd · sonnet · mode:auto · busy ─────────────────────────┐
│ ## You                                                     │
│ add IDLE support to imap client                            │
│                                                            │
│ ## Claude                                                  │
│ Plan: …rendered markdown…                                  │
│ ▸ Edit: imap/client.go            ← fold, za opens         │
│ ▸ Bash: go test ./...                                      │
├ prompt ────────────────────────────────────────────────────┤
│ [attach] imap/idle.go                                      │
│ now handle reconnect                                       │
└────────────────────────────────────────────────────────────┘
```

- **Transcript**: plain markdown buffer. Read-only content, but every Neovim motion, search, yank and his markdown renderer work. Opening a parked session shows its full history without starting Claude.
- **Tool calls**: one closed fold each. Inside: what was called (command, file, skill name and arguments) and its output. Edits show old/new; Enter on an edit fold opens that file's diff. Subagent activity and thinking are folds too.
- **Text object for one answer**, so `y` + object copies the last (or Nth) answer as markdown. This replaces `/copy`.
- **Prompt buffer**: normal buffer below the transcript.
  - Send: `<C-CR>` (normal and insert), `<leader><CR>` as fallback.
  - `@` opens a file picker and inserts an `[attach] path` line; converted to Claude's file mention on send (same idea as neomd's `[attach]`).
  - `/` completes from the live session's own command list (includes his skills).
  - History of sent prompts navigable with `<C-n>`/`<C-p>` and arrows.
  - `i`/`a`/`o` in the transcript jump to the prompt in insert mode.
- **Window bar**: project, model, permission mode, state. Mode toggle `<S-Tab>` and model picker act on the real Claude session immediately.
- **Permissions**: Claude's own permission system decides when to ask. The ask appears as a Neovim prompt (allow / deny / allow for session where Claude offers it). No separate permission logic in the plugin.
- **Interrupt**: `<C-c>`.

### 7.3 Sessions that are running somewhere else

His existing sessions run in tmux panes in Claude's own screen. Two Claude processes must never drive one session. When he opens such a session the history shows read-only. Sending is refused with a short notice, and one key jumps tmux to the pane running it.

Taking over such a session from Neovim is **out of scope** (his decision): the focus is working well inside Neovim. If he wants one of those sessions in Neovim he quits it in its pane himself; it then shows as parked and opens normally. The plugin never stops a Claude process it did not start.

### 7.4 Escape hatch to the real Claude screen

Low priority (his decision): running `claude --resume` by hand in another tmux pane already covers this. What must work regardless is that a session touched outside Neovim shows its new turns when reopened, and that the plugin refuses to send while another Claude holds the session. The convenience key below is optional and comes last.

One key (`<leader>at`) stops the Neovim-side process and opens `claude --resume <id>` in a tmux pane beside Neovim **[builder's call: tmux pane first; an inline Neovim terminal is the fallback when not inside tmux]**. When that Claude exits, Neovim reloads the session history (so turns made there appear) and reattaches. Used for MCP setup and other screen-only features.

### 7.5 Prompts

Top-level node, shared by all projects.

- **Skills & commands**: read from `~/.claude/commands` and `~/.claude/skills` (symlinks into `~/git/skills/my-skills/skills/.claude/`). Enter inserts `/name` into the prompt buffer; Claude loads the skill itself. Nothing is copied.
- **Library**: plain text templates, one markdown file per prompt, subfolders become tree groups. Default location for Simon: `~/git/skills/my-skills/prompts/` (repo root, deliberately outside `skills/.claude/` so stow does not expose them to Claude as commands). The path is a setting. Enter opens the text in the prompt buffer.
- **Saved prompts** (per project node): prompts stored from that project.

Saving rules:
- `:w` or `ZZ` on a fresh prompt stores it under the project's Saved prompts. `ZZ` hides the prompt window; it never ends the session.
- `<leader>W` stores it into the global Library (same key as his dadbod "save query").
- A prompt opened from Library or Saved prompts: `:w` / `ZZ` updates that file in place.

Splitting his existing "My AI Prompts" note into library files is a one-time content job, done by hand or with Claude when this part is built. The note itself is not read or modified by the plugin.

### 7.6 Git: seeing, not acting

Per project, two nodes:

- **Changes vs `<base>`**: everything on the current branch compared with where it left the default branch, including uncommitted work. This is the "what did the agent do overall" view. On the default branch it shows uncommitted changes.
- **Commits on branch**: each commit expands to its files. On the default branch it shows recent commits.

Enter on a file opens a side-by-side diff in the main window. For branch changes the right side is the real, editable working file. One key flips the same file between "whole branch" and "this commit only". `]c`/`[c` move between hunks, and a pair of keys moves to the next/previous changed file without returning to the drawer **[builder's call on the exact keys]**.

Built on Neovim's own diff, no plugin dependency **[builder's call]**. If `codediff.nvim` or `diffview.nvim` is installed, a setting may route diffs to it; not required for v1.

The changes list refreshes when a session in that project finishes a turn.

### 7.7 Footer

A lualine component (also callable from any statusline):

```
claude sonnet · 5h ▰▰▰▰▱ 89% · week ▰▰▰▰▱ 82%
```

Model of the session in focus, then quota **left** in the 5-hour and weekly windows. If Claude reports a model-specific window, it gets its own bar. Values are known only after the first answer of a Neovim session **[builder's call: persist the last known values to disk so the bar is filled on startup, marked with its age]**.

### 7.8 Attention: never interrupt, always visible

With ten sessions, permission asks and questions arrive from sessions that are not on screen. Rule (his decision): **the plugin never interrupts what he is typing.** An ask from a session not in focus waits inside that session. A permission prompt pops up only for the session he is looking at.

One overall status, in four levels, highest wins:

| Level | Color | Meaning |
|---|---|---|
| 1 | green | all quiet, nothing running, no questions |
| 2 | yellow | agents are running, no questions |
| 3 | orange | something more is needed **[author's reading, to confirm: an agent finished or failed and its result waits for him]** |
| 4 | violet | his input is required (permission or question), with a count |

Shown in three places:
- **Drawer**: per-session and per-project state icons in these colors.
- **Neovim footer**: while the plugin is loaded, the lualine component takes the status color and a short text, e.g. `input required (2)`. One key jumps to the next session that needs him.
- **Omarchy bar**: a small Omarchy plugin (same form as his others in `~/git/general/dotfiles/omarchy/.config/omarchy/plugins`: `manifest.json`, `Panel.qml`, `Model.js`), modelled on Omarchy's built-in agents overview. It shows the color and the count, so he sees it from any workspace even when Neovim is not visible.

So the Omarchy plugin and anything else outside Neovim can read it, the Neovim plugin writes the combined status to a small JSON file under `$XDG_RUNTIME_DIR/agent-ide/` whenever it changes: overall level, counts, and per session project, title, state and reason. The indicator also counts sessions running in tmux panes (from `claude agents --json`), so the picture is complete when Neovim is closed.

## 8. Fidelity (anti-goals 1 and 2)

- **Nothing is dropped silently.** Every event from Claude is either rendered or shown as a generic fold labelled with its type. Unknown event types never vanish.
- **Raw view.** One key shows the exact JSON events behind the current session, and the exact text that was sent for any prompt.
- **Prompts go out verbatim.** The only transformation is the documented placeholder conversion (`[attach] path`). Whitespace, markdown, code fences and blank lines are untouched. Claude is started with `--replay-user-messages`, and the echoed prompt is compared with what was sent; a difference raises a visible warning.
- **History equals live.** A session rendered live and the same session reloaded from its transcript must produce the same buffer content for prompts, answers and tool calls.
- **Version guard.** The plugin records which Claude Code versions it was tested against. On an untested version it says so once, and keeps working.
- **Recorded fixtures.** Real event streams (captured from the spike and during the build) are kept as test fixtures; rendering is tested against them.

## 9. Speed (anti-goal 3)

### 9.1 Budgets
- Typing in the prompt buffer is never blocked by the plugin.
- First streamed text appears in the buffer within one screen frame of arriving.
- Sending does not start a new process: one Claude process per open session stays alive.
- Drawer opens in under 50 ms with 60 projects (spike: 64 ms for 40 projects in plain Lua, unoptimized).
- Opening a 1 MB session history: under 150 ms.
- No synchronous git or file scanning on the UI thread once past the spike.

The model's own thinking time is Claude's; the plugin's job is to add nothing on top.

### 9.2 Lua and Rust **[builder's call]**
- **Lua**: all UI, buffers, keymaps, the Claude process pipe. This is what Neovim plugins use, and the work here is waiting on I/O, not computing.
- **Rust helper binary** (one executable, talks JSON lines to Neovim over stdio): indexes all transcripts (titles, cwd, branch, last activity), watches them for changes, parses large histories, and provides full-text search across all sessions. This is the part that grows with years of sessions.
- The plugin must work without the helper (Lua fallback, slower on large histories), so installation never blocks use. Distribution follows blink.cmp / fff.nvim: prebuilt binaries from releases, `cargo build` as fallback.

## 10. Other agents

Internally there is one event model (prompt, text chunk, tool call, tool result, permission ask, state change, quota) and one adapter per agent that translates to it.

- **Claude adapter**: the stream format in section 6. Built first, gets every feature.
- **ACP adapter** (Agent Client Protocol): for Codex, Gemini CLI, opencode. Built last. Features an agent does not offer are simply absent in its sessions.

Session discovery (history on disk, live state) is also per adapter; only Claude's is designed here.

## 11. Parts and order

Each part is planned and built on its own, in this order. Each leaves something usable.

1. **Drawer and history.** Projects, sessions, states, titles; read-only history view with folds; jump to tmux pane; Rust index helper with Lua fallback. Fixes today's "which session is which" problem by itself.
2. **Chat.** Native prompt and transcript, streaming, permissions, model/mode, attach, slash completion, footer quota and status, status file, fidelity checks. Escape hatch last within this part.
3. **Prompts.** Skills & commands, Library, Saved prompts, saving rules.
4. **Git seeing.** Changes, Commits, diff view, branch/commit flip, lazygit launcher.
5. **Omarchy indicator.** Small separate plugin in his Omarchy plugins folder, reading the status file.
6. **Other agents** through ACP.

The spike file is throwaway and is deleted when part 1 lands.

## 12. Decisions made by the design author (veto welcome)

- `<leader>aa` / `:Agents` to toggle the drawer; all plugin keys under `<leader>a`.
- Claude processes are children of Neovim. Quitting Neovim while a session is busy asks for confirmation; the session's context survives on disk and resumes later, but a turn in progress is lost. A background keeper that lets turns outlive Neovim is left for later.
- Diff view on Neovim's built-in diff; external diff plugins optional.
- Rust helper for indexing/search, Lua for the rest, Lua fallback mandatory.
- Last known quota persisted to disk.
- Library lives outside `skills/.claude/`.

- **Audience**: built for Simon first, published on GitHub later (his stated intent). So: no hard-coded personal paths (all are settings with his values as his config), tmux features degrade cleanly when not in tmux, Linux and macOS in mind. The release pipeline for prebuilt binaries is not part of part 1; part 1 ships with `cargo build` plus the Lua fallback.
- **Working directory**: the plugin never changes Neovim's global working directory. The Agents tab gets a tab-local working directory (`:tcd`) of the project in focus, so pickers, the `@` attach picker and LSP inside that tab see the right root. Every plugin feature also carries its project root explicitly. A setting turns the `:tcd` off.
- **Process lifetime**: a Claude process started by the plugin lives until he parks the session (a key in drawer and chat), or quits Neovim. Hiding windows or buffers never ends it. No idle timeout by default (setting available). Parking a busy session asks first.
- **Per-project saved prompts** live in the plugin's data directory (`stdpath('data')/agent-ide/prompts/<project>/`), never inside the project repo, so they do not show up as changes. File name is a slug of the first line. An unsent prompt buffer maps to one file: repeated `:w` updates it. After sending, the buffer is a new, unnamed prompt again.

## 13. Left to the builder

- Module layout, test framework, exact highlight groups and icons.
- Exact keys inside views where not named above.
- Index cache format and file-watching approach in the Rust helper.
- How tool-specific folds are formatted beyond Bash, Edit, Write, Skill.

## 14. Changes since approval

Recorded after the build; the approved text above is unchanged.

- The project row shows the branch name (when it is not the default branch).
- The lazygit key is `glg` (in the drawer and the diff view).
- An edit's diff opens with `gd` / `<leader>gd` on its fold in the transcript, not with Enter.
- Hand-off to native Claude outside tmux has no terminal fallback: the session is parked and the command to run is shown.
- One status file per Neovim (`status-<pid>.json`), combined by the reader, instead of one shared file.
- Over-long lines are cut for display with a marker that counts what was cut; the raw view keeps every byte.
- Templates and saved prompts are loaded and saved exactly as the file is (frontmatter included); nothing is kept or added.
- The saved-prompt folder of a project is `<project>-<hash>`.
- The footer quota shows percent used, not percent left.
- Not every key is under `<leader>a`: `<leader>W` (save to the library), `<leader><CR>` (send), and `<leader>g…` in the diff view.
- No idle-timeout setting exists yet; a session's process runs until it is parked, handed off or Neovim quits.
- Prebuilt helper binaries are not provided yet; the helper is built with `make helper` (cargo).
- "Allow for this session" is offered only as far as Claude's own permission suggestions were verified (labelled where Claude saves the rule).

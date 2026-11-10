# Agent-IDE.nvim Part 3: Prompts — Implementation Plan

## Adjustments made while building

Where the code (or the brief given at build time) differed from this plan, the code won:

- **Drawer hook.** `ui/sections.lua` already had `top(ctx)` for rows above the projects, so `tree.lua`
  needed no change. The Prompts node is a `top` row; Saved prompts are `rows(project, ctx)`. The
  provider is registered before the git provider, so `Saved prompts` sits right after `Sessions`.
- **Hook extension (row keys).** Drawer keys on prompt rows (`e`, `r`, `d`, `y`, `L`) needed one
  generic addition: a provider may return `keys() -> { { lhs, desc }, ... }`; the drawer maps each
  lhs once (before its own keys, which win a clash), lists it in its help, and on a row whose node
  has `keys = { [lhs] = fn(node) }` calls that function; on any other row the key keeps its native
  meaning (fed with `nvim_feedkeys`, count kept).
- **Config keys.** Row keys live in `keys.prompts = { edit, rename, delete, yank, to_library }`;
  every key value is a string, a list of strings or `false` (`diff_buf.keys`).
- **Saved prompts folder.** `<saved_dir>/<folder>/` where folder = the project folder's name plus
  8 hex digits of the sha256 of the project key (`alpha-1a2b3c4d`): drawer names change when two
  projects share a name (`parent/name`), and two projects called `api` must not share prompts.
  `sources.scan` still takes `project_name` (the folder) as planned.
- **Saved prompts section** is shown only when the project has at least one saved prompt (not
  with `(0)`): the drawer's existing lines stay unchanged when nothing was saved.
- **Defaults of the folds:** Prompts collapsed (nothing is scanned until it is opened), Skills &
  commands collapsed, Library open, library groups collapsed, Saved prompts collapsed.
- **Project commands and skills** in the top node are those of the project of the chat shown in
  the Agents tab's transcript window (rescanned when that changes).
- **Files.** Saving lives in `prompts/save.lua` (attached by `ui/prompt.lua`'s `create`), drawer
  row keys in `prompts/manage.lua`, the lazy entry cache in `prompts/cache.lua`, so no file grows
  past ~350 lines (`ui/prompt.lua` was already 421). `chat.focus_prompt(s, insert)` and
  `prompt.browsing(buf)` were added as small public functions.
- **Origin** is kept in the buffer variable `b:agent_ide_origin = { kind, path, stamp }` (stamp:
  mtime and size); `prompt.clear` (after a send) forgets it. A prompt shown from the history is
  saved as a new prompt, never into the loaded file. "Insert above" the draft gives a fresh
  prompt (no origin): the mix is not that template.
- **`ZZ` and `:x`.** The buffer is never modified, so Neovim never writes it for `ZZ`/`:x`:
  `ZZ` is a buffer-local map (save, then `normal! ZZ`), `:x`/`:exit` are caught in `QuitPre` from
  the typed command line. `:wq` goes through `BufWriteCmd`. `:wqa`/`:xa` save nothing. `:w <file>`
  is refused with a notice.
- **Insert-mode picker key** only for a key that does not start with a printable character (the
  default `<leader>al` would fire while typing ` al…` with a space leader).
- **Writes are synchronous** (one small file, before `:wq` quits); scans stay asynchronous. New
  files: temp file + hard link (no clobber, falls back to an exclusive create); updates: temp
  file + rename, keeping the file's mode and its frontmatter. Same text saved twice is kept once.
- **File names.** Lower-cased with `tolower()`; letters include non-ASCII word characters
  (umlauts, CJK), emoji become `-`. Library names typed for `<leader>W`, `r` and `L` keep their
  case, spaces become `-`; a taken name re-asks with the next free name.
- **No chat open** from a Saved prompt row starts a session for that row's project; "a project
  row was last selected" is not tracked (top-level rows only notify).
- **Review fixes (after merging search).** One function, `prompt.put(buf, lines, how)`, writes
  text into a prompt buffer for the plugin (loading, commands, queued prompts coming back, a
  reused search hit): it leaves history browsing first (`prompt.leave_history`) and forgets the
  origin. "Already saved" no longer ties the buffer to the existing file. Saved prompts load
  as the whole file; a library file's leading `---` block counts as frontmatter only when it
  reads as YAML. The changed-on-disk question is scheduled, so it opens after `ZZ`/`:x` hid
  the prompt. A rename keeps the origin's old stamp. `:file`/`:saveas` put the name back.
  Command names from sub-folders (`folder:name`) were checked against Claude Code 2.1.306
  (see docs/protocol.md). Drawer focus rescans only what is shown open, reading only changed
  files. Name parts are limited to 240 bytes.
- **Existing tests** that counted drawer lines from the top (`tests/test_chat.lua`,
  `tests/test_git_budget.lua`) now skip the Prompts row; `tests/run.lua` gives every test Neovim a
  temporary `XDG_DATA_HOME`, so no test reads or writes the user's data folder.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reusable prompts one keypress away: a top-level Prompts node in the drawer listing the user's Claude skills and commands and a library of prompt templates, per-project saved prompts, and dadbod-style saving from the prompt buffer.

**Architecture:** A pure module scans prompt sources (folders of markdown files) into a small list of entries. The drawer shows them through the sections hook that the git part introduced (`lua/agent-ide/ui/sections.lua`), plus one top-level node above the projects. Actions put text into the chat's prompt buffer. Saving is implemented on the prompt buffer's existing `BufWriteCmd`.

**Tech Stack:** Lua (Neovim 0.12, `vim.uv`), mini.test.

**Spec:** `docs/superpowers/specs/2026-11-10-agents-ide-design.md` section 7.5 (Prompts), section 12 (per-project saved prompts live in the plugin's data directory), and the user's words recorded below.

**Depends on:** the chat part (prompt buffer, `chat.current()`), and the git part's sections hook. **Before starting, read `lua/agent-ide/ui/sections.lua`, `tree.lua`, `drawer.lua`, `drawer_model.lua`, `prompt.lua`, `chat.lua`, `chat_keys.lua` as they are then; where this plan names an interface that turned out different, the code wins and the task text is adjusted first.**

## What the user asked for (their words, condensed)

- "saved prompts could be a higher level tree on the very top, as saved prompts I want to use for all; could be the ones I have in my claude repo as `commands` such as fix-grammar etc, but I'd like to add also others" (their note "My AI Prompts").
- Two kinds, confirmed: **Skills & commands** (already live in their Claude folders; Enter inserts `/name`, Claude loads it itself, nothing copied) and **Library** (plain text templates; Enter opens the text in the prompt buffer, they fill gaps and send).
- Library location: "could be managed in `~/git/skills/my-skills`" → folder `prompts/` at that repo's root, outside `skills/.claude/` so stow does not expose templates to Claude as commands. One file per prompt, sub-folders become tree groups.
- Saving: "`ZZ` or write could be saved prompts per session [project] … then have also overall prompts that we can save with leader-W (same as dadbod), and if we open an overall prompt, `:w` or `ZZ` should save or update that prompt too."

## Global Constraints

- All constraints of the part 1 and part 2 plans hold (module `agent-ide`, no runtime dependencies, synthetic fixtures, nothing from the user's real folders in the repo or tests, nothing blocking on the UI thread, never interrupt typing, files under ~350 lines).
- **No personal paths in the plugin.** Defaults: library `stdpath('data')/agent-ide/library`; skills and commands from `~/.claude/commands`, `~/.claude/skills` and, for the project of the current session, `<project>/.claude/commands` and `<project>/.claude/skills`. The user's own library path is set in their own config (Task 6).
- **The plugin never edits files under a Claude folder** (`.claude/commands`, `.claude/skills`); skills and commands are read-only here. It writes only to the library folder and to its own data directory.
- **Prompts are sent verbatim.** Loading a template into the prompt buffer changes nothing in it; no placeholder syntax is interpreted beyond the existing `[attach]` rule.
- The prompt buffer is never marked `modified` (chat part decision): whether there is a draft is decided from its lines, not from that flag.
- Symlinked folders are followed (the user's `~/.claude/commands` and `~/.claude/skills` are symlinks).
- Commits end with `Co-Authored-By: Claude <noreply@anthropic.com>`.

## Review Focus

1. **A skill or command file with odd frontmatter** (missing, malformed YAML, a `name` that differs from the file name, CRLF, a very long description): it still lists, under the name Claude would use, and never raises. → Task 1.
2. **Saving must never lose or overwrite silently:** two prompts whose first lines give the same file name; a library file changed on disk since it was opened; saving an empty buffer; a name with `/`, `..` or characters illegal in file names. → Task 4.
3. **Enter on a prompt while the prompt buffer holds a draft:** the draft is not thrown away without asking. → Task 3.
4. **No chat open** when the user picks a prompt: a sensible, stated behaviour instead of an error. → Task 3.
5. **Hundreds of files and deep folders in the library:** the drawer stays fast and the scan stays off the UI thread. → Task 1, Task 2.

## File Structure

```
lua/agent-ide/prompts/sources.lua   pure-ish: scan folders -> entries; frontmatter; names
lua/agent-ide/prompts/store.lua     write/rename/delete library and saved prompts; naming rules
lua/agent-ide/prompts/actions.lua   insert a command, load a template, save from the prompt buffer
lua/agent-ide/ui/prompt_sections.lua  drawer rows for Prompts (top node) and per-project Saved prompts
tests/test_prompts.lua, tests/test_prompt_save.lua, tests/fixtures/prompts/…
```
Modified: `lua/agent-ide/config.lua`, `lua/agent-ide/init.lua`, `lua/agent-ide/ui/prompt.lua` (BufWriteCmd, origin tracking), `lua/agent-ide/ui/chat_keys.lua`, `lua/agent-ide/ui/tree.lua` / `drawer.lua` (top-level node only, if the hook does not already allow it), `README.md`.

## Shared Types

**PromptEntry:** `{ kind = 'command' | 'skill' | 'template' | 'saved', name, title, description|nil, path, group|nil, scope = 'user' | 'project' | 'library' | 'saved', insert }` where `insert` is `/name` for commands and skills and nil for templates and saved prompts (their text is the file content without frontmatter).

**Prompt origin** (kept per prompt buffer): `nil` for a fresh prompt, or `{ kind = 'template' | 'saved', path, mtime }` after a template or saved prompt was loaded; cleared after sending.

## Config (additions)

```lua
prompts = {
  library_dir = nil,          -- nil: stdpath('data') .. '/agent-ide/library'
  command_dirs = { '~/.claude/commands' },
  skill_dirs = { '~/.claude/skills' },
  project_dirs = true,        -- also read <project>/.claude/{commands,skills}
  saved_dir = nil,            -- nil: stdpath('data') .. '/agent-ide/prompts'
},
keys = { chat = { save_library = '<leader>W', prompts = '<leader>al' } },
```

---

### Task 1: Prompt sources

**Files:** create `lua/agent-ide/prompts/sources.lua`, `tests/fixtures/prompts/`; test `tests/test_prompts.lua`.

**Interfaces:**
- `sources.scan(opts, cb(entries: PromptEntry[]))` — asynchronous (chunked like the Lua session scan); `opts`: `command_dirs`, `skill_dirs`, `library_dir`, `saved_dir`, `project_root|nil`, `project_name|nil`.
- `sources.parse(text) -> { name|nil, description|nil, body }` — pure; splits optional YAML frontmatter (`---` fenced at the top) from the body; reads only `name` and `description` (plain scalars, quoted scalars, and folded `>`/`|` blocks reduced to one line); never raises.
- `sources.read(entry, cb(text))` — body of a template or saved prompt, frontmatter removed.

Rules:
- Commands: every `*.md` under a command dir, recursively; name = path relative to the dir without `.md`, with `/` → `:` (Claude's namespacing for sub-folders); `insert = '/' .. name`.
- Skills: every `<dir>/<skill>/SKILL.md`; name = frontmatter `name` if present, else the folder name; `insert = '/' .. name`. Plugin-provided skills are not listed (they are not in these folders); the session's own `/` completion covers them.
- Library: every `*.md` under `library_dir`, recursively; `group` = relative folder (`writing/social`), `title` = frontmatter `name`, else the first markdown heading, else the file name without extension with `-`/`_` → spaces.
- Saved: `*.md` directly under `<saved_dir>/<project_name>/`.
- Project scope entries (`scope = 'project'`) come from `<project_root>/.claude/…` when `project_root` is given and `project_dirs` is on; a project entry with the same name as a user entry is listed once, project first (as Claude resolves it).
- Sorted by group then title, case-insensitive. Missing folders give no entries and no error. Unreadable files are skipped.

- [ ] **Step 1: Fixtures (synthetic).** `commands/fix-grammar.md` (frontmatter name + description), `commands/git/sync.md` (no frontmatter), `skills/data-viz/SKILL.md` (name differs from folder: `dataviz-pro`, folded description), `skills/broken/SKILL.md` (malformed frontmatter, CRLF), `library/writing/linkedin-post.md` (heading title), `library/writing/social/tweet.md`, `library/invoice.md` (frontmatter `name: Invoice text`), `saved/alpha/add-idle-support.md`, plus a project dir with `.claude/commands/fix-grammar.md`.
- [ ] **Step 2: Failing tests:** names and inserts (`/fix-grammar`, `/git:sync`, `/dataviz-pro`, `/broken`); descriptions one line; library groups `writing`, `writing/social`, none; titles `linkedin post` heading text, `Invoice text`; project entry shadows the user one and is marked `project`; `parse` on CRLF, on malformed YAML, on no frontmatter, on a body that itself starts with `---` after the frontmatter; missing folders; symlinked dir followed; 500 generated library files scan without a tick longer than 16 ms (same technique as `tests/budget_lib.lua`).
- [ ] **Step 3:** Implement. **Step 4:** Suite green. **Step 5:** Commit `feat: prompt sources (commands, skills, library, saved)`.

---

### Task 2: Drawer — Prompts node and Saved prompts section

**Files:** create `lua/agent-ide/ui/prompt_sections.lua`; modify `tree.lua` / `drawer.lua` only as far as the hook requires; test `tests/test_tree.lua`, `tests/test_ui.lua`.

- A top-level row `▸ <icon> Prompts` above the first project (config icon `prompts`). Expanded: `Skills & commands (n)` and `Library (n)`; library groups are nested rows; entries show title and, dimmed, the description (truncated to the drawer width). Commands and skills show their `/name`.
- Per expanded project: a section `Saved prompts (n)` registered through `sections.register`, placed after `Sessions`.
- Data loads lazily on first expansion and refreshes on `R`, after a save/rename/delete, and when the library folder changes on disk (reuse the helper's watch if it can watch another directory cheaply; otherwise re-scan on drawer focus, debounced).
- With no entries at all the Prompts node shows a one-line hint `no prompts yet — <leader>W in a prompt buffer saves one`.
- The existing drawer lines for projects and sessions are unchanged (assert on the part 1 fixtures).

- [ ] **Step 1: Failing tests:** tree lines for a fixture set (exact strings with ASCII icons), nodes carry the PromptEntry, groups expand/collapse independently, Saved prompts section appears only when the project has saved prompts or is expanded (state the choice: shown with `(0)` when expanded), hint line, unchanged project lines.
- [ ] **Step 2:** Implement. **Step 3:** Suite green incl. `tests/test_budget.lua` unchanged. **Step 4:** Commit `feat: Prompts node and per-project saved prompts in the drawer`.

---

### Task 3: Using a prompt

**Files:** create `lua/agent-ide/prompts/actions.lua`; modify `drawer.lua` (Enter on prompt rows), `chat_keys.lua`, `init.lua`; test `tests/test_prompts.lua` (child Neovim).

Behaviour:
- **Enter on a command or skill:** inserts `/name ` at the start of the current chat's prompt buffer (as its own first line if the buffer already has text) and focuses the prompt in insert mode at the end of that line, so arguments can be typed. Nothing is sent.
- **Enter on a template or saved prompt:** loads its text into the current chat's prompt buffer and sets the prompt origin. If the buffer holds a draft (any non-blank line): ask `Replace the draft, insert above it, or cancel?` (`vim.ui.select`); never discard silently (Review Focus 3).
- **No chat open in the Agents tab** (Review Focus 4): if the cursor's project is known (a Saved prompt row, or a project row was last selected) open a new session for that project and continue; from the top-level Prompts node with no chat open, notify `Agent-IDE: open or start a session first, then pick a prompt` and do nothing else.
- **`e` on a template or saved prompt row:** opens the file itself in the main window as a normal buffer for editing (library maintenance). On a command or skill: opens it read-only with a notice that it belongs to Claude's folder.
- **Picker without the drawer:** `require('agent-ide').prompts()` and a chat key (`config.keys.chat.prompts`, default `<leader>al`) open `vim.ui.select` over all entries (label `kind · group/title — description`), same Enter behaviour. In insert mode in the prompt buffer the same key works and returns to insert mode.
- Help floats updated (drawer and chat).

- [ ] **Step 1: Failing tests** for each behaviour, including the draft question (all three answers), no-chat cases, `e`, the picker, and that loading a template leaves its text byte-identical in the buffer (tabs, trailing spaces, a final line without newline).
- [ ] **Step 2:** Implement. **Step 3:** Suite green. **Step 4:** Commit `feat: insert commands and load templates into the prompt buffer`.

---

### Task 4: Saving from the prompt buffer

**Files:** create `lua/agent-ide/prompts/store.lua`; modify `lua/agent-ide/ui/prompt.lua`, `chat_keys.lua`; test `tests/test_prompt_save.lua`.

Rules (the user's, section "What the user asked for"):
- **Fresh prompt, `:w` (or `ZZ` / `:wq` / `:x`):** saved under the session's project in Saved prompts. File name = slug of the first non-blank line that is not an `[attach]` line (lowercase, runs of non-alphanumerics → `-`, trimmed, at most 60 characters; empty → `prompt-<YYYYMMDD-HHMMSS>`). The buffer's origin becomes that saved file, so a further `:w` updates the same file. `ZZ` then hides the prompt window as it does today. After the prompt is sent, the origin is cleared and the next `:w` creates a new saved prompt.
- **Name collision** with a different existing file: append `-2`, `-3`, … (never overwrite another prompt; Review Focus 2).
- **`<leader>W`** (normal mode in the prompt buffer; `config.keys.chat.save_library`): asks for a name with `vim.ui.input` (default: the slug; a `group/name` form creates sub-folders), saves into the library, sets the origin to that library file. Cancel does nothing. Path components are sanitised: no `..`, no leading `/`, no characters outside letters, digits, space, `-`, `_`, `.`; a rejected name re-asks with a notice.
- **Prompt with an origin (loaded template or saved prompt), `:w` / `ZZ`:** updates that file in place. If the file changed on disk since it was loaded (mtime differs): ask `Overwrite, save as new, or cancel?`.
- **Empty buffer:** `:w` does nothing and says `Agent-IDE: nothing to save`; `ZZ` just hides.
- Files are written atomically (temp + rename), with a trailing newline, UTF-8 as is. Frontmatter is not added. A saved prompt stores the text as typed (with `[attach]` lines as typed, not converted).
- After any save: one-line notice with the short path (`saved → Saved prompts/alpha/add-idle-support`), drawer refreshed.
- `store.rename(entry, new_name, cb)` and `store.delete(entry, cb)` for Task 5, with the same sanitising; both refuse entries of kind command or skill.

- [ ] **Step 1: Failing tests** for every rule above, including: two different prompts with the same first line → two files; `:w` twice → one file updated; send then `:w` → second file; `<leader>W` with `writing/my post` → `library/writing/my-post.md`; `../x` rejected; overwrite question on external change (all three answers); empty buffer; atomicity (no partial file when the directory is not writable → one WARN, nothing raised); the prompt buffer is still never `modified`; `:qa` with a draft still quits without saving anything.
- [ ] **Step 2:** Implement. **Step 3:** Suite green. **Step 4:** Commit `feat: save prompts per project and to the library`.

---

### Task 5: Managing prompts from the drawer

**Files:** modify `drawer.lua` / `prompt_sections.lua`; test `tests/test_ui.lua`.

- On a template or saved prompt row: `r` rename (input pre-filled; library entries accept `group/name` to move between groups), `d` delete after `vim.fn.confirm` naming the file (default No), `y` yank the prompt's text to the unnamed and `+` registers.
- On a saved prompt row: `L` copies it into the library (asks for a name like `<leader>W`).
- On command and skill rows these keys give a one-line notice that the file belongs to Claude's folders.
- Help float updated.

- [ ] Failing tests → implement → suite green → commit `feat: rename, delete, yank and promote prompts from the drawer`.

---

### Task 6: Docs and the user's own setup

**Files:** modify `README.md`; other repository (leave uncommitted): `~/git/general/dotfiles/nvim/.config/nvim/lua/sspaeti/plugins/agent-ide.lua`.

- [ ] README "Prompts" section: the two kinds, where they come from, keys, saving rules table, config block, how to point `library_dir` at a git-managed folder.
- [ ] In the user's lazy spec add `opts = { prompts = { library_dir = '~/git/skills/my-skills/prompts' } }` (merge into the existing `opts`). Do not create that folder's content and do not touch the `my-skills` repository; report the diff.
- [ ] Headless check with the user's real config, counts only: number of commands, skills, library entries, saved prompts found; scan time. No names printed.
- [ ] Commit `docs: prompts section`.

## Not in this plan

- Splitting the user's long "My AI Prompts" note into one file per prompt in their library. That is a one-time content job in their private skills repository; offer to do it with them after this part is in use (it needs their eye on naming and grouping).
- Placeholder/variable syntax inside templates.
- Listing skills that come from Claude plugins (available through `/` completion in a running session).
- Syncing or publishing the library.

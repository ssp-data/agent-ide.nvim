# Full diff: every change of a branch in one buffer

Date: 2026-11-12. Status: approved by the owner in conversation; this document records it.

## Intent

Today the drawer's `Changes vs <base>` and `Commits on branch` sections list files, and `<CR>` on a file opens the side-by-side diff view of that one file. Reviewing a branch means stepping through files one at a time. The owner wants what lazygit shows on a branch row and what [hunk](https://github.com/modem-dev/hunk) does: all changes of the branch in one scrollable patch, file by file, with a few context lines around each change, so the whole branch can be read top to bottom with one interface. The same view should work for the committed part of the branch, for one commit, and for the uncommitted changes.

The owner chose the name **full diff**. Not "hunk" (the name of a tool) and not "patch" (git jargon).

## Goals

- One buffer in the Agents tab's main window with the whole diff of a scope: a header line per file, then only its hunks with three lines of context (git's default), each file foldable.
- Four scopes, same view and keys:
  - **branch**: the merge-base of the branch against the working tree, uncommitted and untracked files included. This is what the `Changes vs <base>` section lists.
  - **commits**: the merge-base against `HEAD`, committed changes only. This is what the `Commits on branch` section lists. On the default branch (`Recent commits`) it covers the commits that section lists: from the parent of the oldest listed commit to `HEAD` (a root commit: from the empty tree).
  - **commit**: one commit against its first parent (a root commit against the empty tree), as the side-by-side view does.
  - **head**: `HEAD` against the working tree, untracked included. This is what the `uncommitted (n)` row lists.
- Reachable from the drawer with one key on any git row, and from a dimmed row inside each section like the existing `commit graph · G` row.
- `<CR>` on any line jumps into the existing side-by-side diff view of that file; closing it comes back to the full diff.
- Browsing keys: next/previous file, next/previous hunk, fold one file, collapse all, expand all.
- Follows the git cache: reloads when the repository's data is invalidated (a session's turn ends, `R`), keeping the cursor where it was.
- Read-only, asynchronous, nothing on the UI thread. The speed budget rule (AGENTS.md rule 4) applies: a budget test for rendering.

## Non-goals

- No staging, no editing in the full diff. The right side of the side-by-side view stays the place to edit (`<CR>` gets you there).
- No word-level (intra-line) diff highlighting in this version.
- No key in the chat for the full diff (the chat's `gd` stays the side-by-side diff of one file). A `:AgentsDiff` command covers "from anywhere".
- No syntax highlighting of the code inside hunks.
- Not a replacement for the side-by-side view: the file lists and `<CR>` on a file row keep working as today.

## Anti-goals

- A full diff that silently leaves changes out. Everything the scope's file list shows appears in the full diff, in the same order; what cannot be shown (binary, submodule, a file too large to read) gets a one-line note under its header, never nothing.
- Blocking Neovim on a large branch. The patch of a long-lived branch can be tens of thousands of lines; rendering must stay within the budget below, and git runs asynchronously.
- Any git write. Queries go through `git.lua`'s `--no-optional-locks` runner (rule 7).

## What the user sees

The main window (where the chat or the graph is) shows a buffer named `agents://<project>/full diff`, filetype `agent-ide-fulldiff`, `nowrap`, cursorline, manual folds, no numbers. The winbar reads, for example:

```
myapp · full diff · vs main · 12 files +340 −120
```

Scope labels in the winbar: `vs <base label>` (branch), `commits on branch` or `recent commits` (commits), `<short hash> <subject>` (commit), `uncommitted` (head).

The buffer, from top to bottom, one block per file in the order of the scope's file list:

```
▾ M lua/agent-ide/ui/diff.lua                                  +12 −3
@@ -133,7 +133,9 @@ local function apply(left_raw, right_raw, keep_cursor)
   local f = D.file
   local note = f.submodule and 'submodule: not shown (no descent)'
-    or (f.binary or left_lines == true or right == true) and 'binary file, not shown' or nil
+    or (f.binary or left_lines == true or right == true) and 'binary file, not shown'
+    or nil
   local cursors = keep_cursor and { ... }

▾ A lua/agent-ide/ui/fulldiff.lua                              +210
@@ -0,0 +1,210 @@
+-- The full diff view ...
+local api = vim.api
...

▸ R lua/agent-ide/ui/old.lua → lua/agent-ide/ui/new.lua          +2 −2
▾ ? notes/todo.md                                                +14
@@ -0,0 +1,14 @@
+# todo
...
▾ M assets/logo.png
  binary file, not shown
```

- **Header line**: fold arrow (the drawer's `open`/`closed` icons), the status letter in its drawer colour (`AgentIdeGitModified` and friends from `ui/git_sections.lua`'s `STATUS_HL`), the path (`old → new` for a rename), the `+a −d` stats right-aligned as the drawer shows them (`git_sections.stats`). The header is the fold's first line, and the fold text of a closed file is the header itself (so collapsing changes only the arrow).
- **Hunk lines**: git's `@@ … @@` line, dimmed with its own group; context lines plain; removed lines in `AgentIdeDiffDel`, added lines in `AgentIdeDiffAdd` (the chat's groups, so a removed line looks the same in a transcript's `Edit` fold and here). Whole-line highlights through extmarks (`line_hl_group`), no syntax file.
- Git's own `diff --git`, `index`, `---`, `+++`, `similarity`, `old mode` lines are not shown: the header line carries what they say. A mode-only change (status `T`) shows its header and a note `mode changed`.
- **Untracked files** (`?`) are shown as one hunk of added lines (`@@ -0,0 +1,N @@`), read from disk asynchronously (the limits of `git.lua`'s `count_lines`: 2 MiB per file, 16 MiB in total, 4 at a time); a file beyond the limits or with a NUL byte gets the note `binary file, not shown` or `not shown (larger than 2 MiB)`.
- **Binary files**: header and `binary file, not shown`. **Submodules**: header and `submodule: not shown`. A **deleted file**: its hunks are all removals, as git prints them.
- An empty scope shows a single dimmed line: `nothing changed vs main`, `no commits on the branch`, `nothing to commit`.
- While loading: `loading…` on one line; the old content stays if there was one (a reload).
- A blank line separates files. Folds run from a file's header to its last line, so the blank line belongs to the file above.

Files whose patch is longer than 500 lines start folded closed (the header still shows the stats), the rest start open. `z9` opens everything.

## Keys

`keys.full_diff` in the configuration, each a key, a list of keys, or `false`; buffer-local, normal mode, `nowait`:

| Default | Action name | What it does |
|---|---|---|
| `<CR>` | `open` | Side-by-side diff of the file under the cursor (see below) |
| `]f` | `next_file` | Cursor to the next file header |
| `[f` | `prev_file` | Cursor to the previous file header |
| `]c` | `next_hunk` | Cursor to the next `@@` line (closed folds skipped, a count works) |
| `[c` | `prev_hunk` | Cursor to the previous `@@` line |
| `za` | `fold` | Fold or unfold the file under the cursor |
| `z0` | `collapse_all` | Close every file |
| `z9` | `expand_all` | Open every file |
| `R` | `refresh` | Reload (invalidates the repository's git cache, as the drawer's `R` does) |
| `glg` | `lazygit` | lazygit for this repository |
| `y` | `yank` | Yank the path of the file under the cursor (`"` and `+`) |
| `q` | `close` | Close, back to what the main window showed before (a chat when one was open) |
| `g?` | `help` | Help float, like the graph's |

`/`, Vim motions, `zM`, `zR`, `zj`, `zk` work as they do anywhere (the folds are manual folds). The owner asked for `za`, `z0`, `z9` to match the drawer.

**`<CR>`** opens the side-by-side view (`ui/diff.lua`) on the file under the cursor (any line of its block), with the list and mode the drawer would use for that file:

| Full diff scope | Side-by-side mode | List |
|---|---|---|
| branch | `branch` | `cache.changes(root)` |
| commits | `branch` on a branch; in recent mode (default branch) `commit` of the newest listed commit that touches the file | `cache.changes(root)`; recent mode: `cache.commit_files(root, <hash>)` after `git.file_commits` |
| commit | `commit` | `cache.commit_files(root, hash)` |
| head | `head` | `cache.uncommitted(root)` |

When the file is not in that list (it changed since the full diff was loaded), a notice says so and nothing opens. Where the cursor is on or below a hunk line, the side-by-side view puts its right-side cursor on the hunk's new-side line number (from `@@ -a,b +c,d @@`, plus the offset of the cursor line among the hunk's context and added lines); on a header line, the top of the file. Closing the side-by-side view comes back to the full diff with the cursor where it was (as the graph does: the buffer is kept with `bufhidden=hide` while the diff view shows, and the previous-buffer restore of `ui/diff.lua` brings it back).

## Where it opens from

**Drawer** (`keys.drawer.full_diff`, default `gd`; free in the drawer today, and `gd` means "diff" in the chat too). On a row of a git project it opens the full diff of the row's work tree (a session in a linked worktree: that worktree, as `G` does):

| Row | Scope | Cursor on |
|---|---|---|
| project row, worktree row, session row, `Changes` section | branch | first file |
| a file under `Changes` | branch | that file |
| `Commits` section, `commit graph` row, `full diff` row under Commits | commits | first file |
| a commit row | commit (that commit) | first file |
| a file under a commit | commit (that commit) | that file |
| `uncommitted` row | head | first file |
| a file under `uncommitted` | head | that file |
| Prompts rows, a non-git project, the hints | notice `not a git project` | |

Two dimmed rows, like the existing `commit graph · G` row (named with the configured key): `full diff · gd` as the first row of an open `Changes` section (above the files), and `full diff · gd` as the second row of an open `Commits` section, between `commit graph · G` and `uncommitted (n)`. `<CR>` on them opens the branch, respectively commits, scope.

**Commit graph** (`keys.graph.full_diff`, default `gd`): on a commit row, the full diff of that commit; on a file row of an expanded commit, the same with the cursor on that file. Closing the full diff returns to the graph.

**Command** `:AgentsDiff`: the branch scope of the current context, found the way `:AgentsGraph` finds its repository (`ui/graph_context.lua`): an open full diff's repository, the graph's, the side-by-side view's, the chat session's, the drawer row's, else the work tree of the current file or of the working directory. Outside a repository: a notice, nothing opens.

The help floats of the drawer (`?`) and the graph (`g?`) list the new key. `G` in the full diff is not mapped (the main window shows one of these views at a time; `G` stays Vim's go-to-end here).

## Behaviour details

- **One view at a time** in the main window, as with the graph: opening the full diff closes an open side-by-side diff view and replaces an open full diff (remembering what was there before the first of them, so `q` returns to the chat). Opened from the drawer or `:AgentsDiff` while a graph is showing, it replaces the graph the same way. Opened with `gd` inside the graph, the graph is kept underneath (`bufhidden=hide`, as the graph does for the side-by-side view) and `q` returns to it with the cursor on its commit. Opening the same scope again just focuses the window.
- **Reload** on `cache.invalidate(root)` for the view's repository (a turn ended, `R` in the drawer or here, the focus check found a change). The commit scope does not reload on invalidation (a commit's diff never changes). After a reload the cursor stays on the same file and, inside it, on the same hunk (matched by its `@@` line, else the file header); folds that the user closed stay closed by path.
- **The branch base** comes from `cache.base(root)` (`git.base`): `base.rev` is the left revision for branch and commits scopes. `base.mode == 'recent'` (the default branch, no merge-base, no commits) is where the commits scope uses the oldest listed commit's parent instead (`base.merge_base` is not nil on the default branch: it is HEAD's own hash). A repository without a commit: branch and head scopes are the working tree against the empty tree (`base.rev` already is), commits scope is empty.
- **Ordering**: files in the order git prints them (`git diff` sorts by path; renames show under the new path), untracked files after them sorted by path, as the drawer's list does.
- **`tcd`**: opening sets the tab's directory to the work tree when `config.tcd` is on, as the graph and the diff view do.
- **Size**: no cap on the number of files or lines; `-U3` keeps the patch small relative to the files. A patch of 50 000 lines renders within the budget below. Folded-closed files over 500 lines keep long patches navigable.
- **Encoding**: lines are set as git gives them (bytes); a line with `\r` is shown as Neovim shows it. Nothing is altered.

## Git queries (read-only, asynchronous, `git_patch.lua` next to `git.lua`)

All with `--no-color --no-ext-diff --no-textconv -M -U3` and `--` before paths, run through `git.run`:

| Scope | Command |
|---|---|
| branch | `git diff <base.rev> --` then the untracked files (`ls-files --others --exclude-standard`, read from disk) |
| commits | `git diff <merge_base> HEAD --`; recent mode: `git diff <oldest>^ HEAD --` (root commit: `git diff <empty tree> HEAD --`) |
| commit | `git diff-tree -p -r --root --no-commit-id --diff-merges=first-parent <hash> --` |
| head | `git diff HEAD --` then the untracked files |

The file list of each scope (status, stats, binary, submodule flags) comes from the existing queries (`cache.changes`, `cache.uncommitted`, `cache.commit_files`, and for the commits scope a new cache kind `committed` with the same `--raw --numstat` query between the two revisions). The patch is split per file by its `diff --git` lines and joined with the list by path (the new path for renames); a file in the list without patch text (binary, submodule, untracked) gets its note or its generated hunk; patch text without a list entry (should not happen) is shown anyway under a header built from the patch's own header, so nothing is dropped.

The patch of a scope is not cached across openings (it is large and cheap to regenerate); the git cache's generation guards stale answers, as in `ui/diff.lua`'s `seq`.

## Speed budget

`tests/test_fulldiff_budget.lua`: splitting a synthetic 50 000-line patch (500 files, 100 lines each, with renames and multi-byte lines) into file blocks, building the lines and highlights and putting them into a buffer with their folds, best of 5, under 60 ms. The pure part (`fulldiff_render.lua`: patch text + file list → lines, highlight ranges, fold ranges, file index) is tested without a window.

## Code layout

| File | Purpose |
|---|---|
| `lua/agent-ide/git_patch.lua` | the patch queries per scope, the untracked reads, the `committed` file list |
| `lua/agent-ide/git_parse.lua` | `parse.patch(text)`: split a patch into `{ path, old_path, lines }` blocks (pure) |
| `lua/agent-ide/ui/fulldiff.lua` | the view: state, window, buffer, load, reload, `<CR>`, close, `open(opts)`, `state()` |
| `lua/agent-ide/ui/fulldiff_render.lua` | pure: blocks + file list → `{ lines, hl, folds, files }` |
| `lua/agent-ide/ui/fulldiff_keys.lua` | `keys.full_diff` mapping and the help float |
| `lua/agent-ide/ui/git_sections.lua` | the two `full diff` rows; `gd` handlers on git rows |
| `lua/agent-ide/ui/drawer.lua` | the `full_diff` action and its help line |
| `lua/agent-ide/ui/graph.lua`, `graph_keys.lua` | `gd` on a commit or file row |
| `lua/agent-ide/ui/graph_context.lua` | reused for `:AgentsDiff` (an open full diff counts as a context) |
| `plugin/agent-ide.lua` | `:AgentsDiff` |
| `lua/agent-ide/config.lua` | `keys.drawer.full_diff`, `keys.graph.full_diff`, `keys.full_diff` |
| `lua/agent-ide/ui/highlights.lua` | `AgentIdeDiffHunk` (the `@@` line, dim, not italic), `AgentIdeDiffNote` (the one-line notes) |
| `tests/test_fulldiff.lua`, `test_fulldiff_ui.lua`, `test_fulldiff_budget.lua` | pure rendering and parsing; the view in a child Neovim on a synthetic repository (`tests/git_repo.lua`); the budget |

Keep each file near the 350-line ceiling; `ui/fulldiff.lua` may need a `fulldiff_open.lua` for the drawer and graph entry points if it grows.

## Docs to update in the same change

- `README.md`: the "Git: what an agent changed" section (a paragraph and a key table for the full diff, the new drawer and graph keys in their tables, `keys.full_diff` in the configuration block, the buffer name in the list of the plugin's buffers if one exists).
- `CHANGELOG.md` under Unreleased, Added.
- `AGENTS.md`: the layout table (`git_patch.lua`, `ui/fulldiff*.lua`).

## Decisions taken (the owner may revisit)

- **Name**: "full diff" (owner's choice). The view, the rows, the winbar and the command use it.
- **Keys**: `gd` in the drawer and the graph (my call; `D` is delete). `za`, `z0`, `z9` for folds (owner's choice). `]c`/`[c` for hunks to match the side-by-side view (my call).
- **`<CR>` in the commits scope opens the branch side-by-side view** (the working file on the right), since the side-by-side view has no committed-only mode and the owner asked for `<CR>` to go to the existing view (my call). In recent mode (the default branch) that list is HEAD against the working tree and would miss the committed files, so there `<CR>` opens the commit view of the newest listed commit touching the file (`gb` flips between commits as usual). Adding a `commits` mode to `ui/diff.lua` later is possible without changing the full diff.
- **From the graph, `q` returns to the graph**; from the drawer or the command the full diff replaces a showing graph (my call, following how the graph treats the side-by-side view).
- **Three context lines**, git's default, not configurable in this version (my call; the owner said "a couple of lines").
- **Files over 500 patch lines start folded** (my call), so a generated file does not bury the rest.
- **Git's own header lines are not shown**; the file header carries the same information. The side-by-side view and the raw git output remain available for anyone who needs the exact `index` line (my call).
- **Recent mode commits scope** covers the listed commits (my call; the alternative, showing nothing on the default branch, hides the `Recent commits` list's content).
- **No cap** on the patch size, the budget test guarantees rendering speed instead (my call).

## Left to the builder

- Exact fold handling when the user re-opens a file that started closed and a reload happens (the rule: the user's own fold state wins once they touched a file).
- How the `+a −d` stats are right-aligned against the window width (the drawer and the graph already do this; reuse their approach and re-render on `WinResized` as the graph does).
- Whether the untracked reads reuse `git.lua`'s `count_lines` by exposing it or copy its limits into `git_patch.lua`.
- The order of the two new rows relative to `loading…` while a section's list is loading.

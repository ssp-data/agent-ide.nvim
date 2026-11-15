# Review comments: inline notes in the full diff, sent to Claude

Date: 2026-11-15. Status: approach approved by the owner in conversation; this document records it.

## Intent

Reviewing what Claude wrote today means reading the full diff, then typing a prompt by hand: "in `lua/x.lua` around line 42 the error is swallowed, and in commit 7f0f916 …". [tuicr](https://tuicr.dev/) shows the better loop: put a typed comment (`ISSUE`, `SUGGESTION`) on a line of the diff, and when done, export the list as agent-ready markdown. tuicr then needs the text copied into a Claude Code terminal. Agent-IDE already drives Claude, so the loop can close in place: comment in the full diff, send to the session.

The owner wants: comments on any line of the full diff in every scope it has (uncommitted, branch, commits, one commit from `Recent commits`), typed as `NOTE`, `ISSUE`, `BUG`, `DESIGN` and the like, shown inline under their line; each comment carrying its reference (commit hash where there is one, file, line) without typing it; when done, the list placed at the top of the prompt buffer where general remarks are added before sending; and a shortcut that sends one comment at once, queued behind a running turn or starting the session with its usual model and settings.

The owner chose to keep this inside the full diff (`gd`) rather than a separate review mode: the scopes are already reachable from every git row of the drawer and from the graph; a review menu would duplicate them. The docs make the workflow visible instead (a `docs/review.md`, a later video).

## Goals

- A comment on any line of the full diff: a `+`, `-` or context line (anchored to the line), a `@@` line, a file header or a note line (anchored to the file). One comment per line; `c` on a commented line edits it.
- Comments show inline under their line as virtual lines, coloured by kind, in every scope that shows the line. They survive a reload of the view (a turn ended, `R`), closing it, and a restart of Neovim.
- A **review** is the set of pending comments of one repository, across scopes: a comment on the uncommitted changes and one on a commit in `Recent commits` go out together, grouped by where they were made.
- Every comment is sent with its reference: the commit's short hash and subject when the scope is one commit, else which scope (uncommitted against `HEAD <hash>`, the branch against its base, the commits of the branch), the path relative to the repository, the line number on the side the line exists on, and the line's text, so Claude finds the place even after lines shift.
- Done (`gs`): the review text goes into the prompt buffer of the review's session (above the draft or replacing it, the dialog the prompt library already uses), or to the clipboard, so general remarks can be added before `<C-CR>` sends it. The pending comments are cleared once they have left.
- Direct send (`<C-CR>` inside the comment editor): that one comment, as a review text of its own, sent to the review's session at once: queued when a turn runs, else started with the model and mode the session would start with anyway (`prefs.start_model`, the same path as the chat's send, with its gates: the "running elsewhere" check, the resume-size question).
- Which session: asked once per review, when its first comment is saved (never while typing): the chat the full diff was opened over when there was one, else the project's most recent session, marked as the default; `+ new session` of the project; `another session…` (a picker of the project's sessions). Changeable from the done dialog.
- The drawer shows a pending review: a dimmed `review (n) · gs` row at the top of the project's `Commits` section when `n > 0`; `<CR>` on it is the done step. The full diff's winbar counts the comments of its scope.
- `:AgentsReview` runs the done step for the repository of the current context (as `:AgentsDiff` finds it), from anywhere.
- Documentation: README (full diff section, key tables, configuration, privacy), CHANGELOG, AGENTS.md layout, and `docs/review.md`: the workflow end to end and an honest comparison with tuicr, hunk, lumen, `gh pr review` and `git diff`.

## Non-goals

- No comments in the side-by-side diff view (`<CR>` from the full diff) in this version. The full diff is the review surface.
- No push of comments to GitHub, GitLab or any forge. The review goes to Claude or to the clipboard.
- No threads, no replies, no resolved state. A comment is pending until it is sent, copied or deleted.
- No comment kinds with behaviour: a kind is a label Claude reads; the list is configurable text.
- No search over comments; `]r` / `[r` step through those of the open scope.

## Anti-goals

- Writing into the repository or into `.git` (rule 8). Comments live in the plugin's state folder; nothing is committed, no git notes.
- A comment lost silently. A comment whose line is no longer in the diff after a reload shows under its file header with a dim note (`line 42 not in this diff`) and is still sent with its reference; only `dd`, sending and copying remove comments.
- Interrupting typing (rule 3). The session question and the placement dialog come on save and on `gs`, not on the first keystroke; the editor is a window the user opened.
- Slowing the full diff (rule 4). Placing comments costs by the number of comments of the scope, never by the length of the patch; the render budgets stay as they are.
- Sending anything the user has not seen. The direct send shows the exact text it sends in the notice (`sent to <session>: [BUG] path:42 …`), and the done step puts the text in the prompt, where it is read before `<C-CR>`.

## What the user sees

In the full diff, after `c` on a line, typing `BUG: swallows the error, notify instead` and `<CR>`:

```
▾ M lua/agent-ide/git.lua                                        +3 −1
@@ -40,6 +40,8 @@ local function run(args, cb)
   local ok, err = pcall(start, args)
-  if not ok then return end
+  if not ok then return cb(nil) end
   ┃ BUG  swallows the error, notify instead
+  if not cb then return end
   ┃ NOTE  this is fine, but move the guard above the pcall
```

The comment is a virtual line under its diff line: an indent, a bar, the kind in its colour, the text. A multi-line comment takes one virtual line per line. The winbar reads `myapp · full diff · uncommitted · 4 files +12 −3 · 2 comments`.

The comment editor is a small floating window under the cursor line (width of the text area, 3 lines, grows with the text), a markdown buffer, insert mode on an empty line. Its winbar names the kinds: `NOTE · ISSUE · BUG · DESIGN · SUGGESTION · QUESTION — <CR> save · <C-CR> send now · q cancel`. The kind is the first word up to a colon when it is one of the configured kinds (any case); else the comment is a `NOTE`. `<CR>` in normal mode and `:w` save and close; `<C-CR>` in normal and insert mode sends this one comment now; `q` and `<Esc><Esc>` in normal mode close without saving (a changed text asks first). In insert mode `<CR>` is a new line.

The first save of a review asks (an `ask_float`, or `vim.ui.select` with `chat.ask_picker = 'select'`):

```
Review of myapp: send the comments to which session?
1. fix the git runner (idle, 10 min ago)      ← the chat under the diff, else the most recent
2. + new session
3. another session…
```

Done (`gs`, the drawer row, `:AgentsReview`) asks:

```
Review of myapp: 3 comments, to "fix the git runner"
1. Insert above the draft         (one choice, "Put in the prompt", when the prompt is empty)
2. Replace the draft
3. Copy to clipboard
4. Another session…
5. Cancel
```

The text that lands in the prompt (and that the direct send sends, with one comment):

```
I reviewed your changes and have the following comments. Please address them.

Comment kinds: NOTE (an observation), ISSUE (a problem to fix), BUG (wrong behaviour), DESIGN (structure or approach)

## uncommitted changes (working tree against HEAD 7f0f916)

1. **[BUG]** `lua/agent-ide/git.lua:42` — `if not ok then return cb(nil) end`
   swallows the error, notify instead
2. **[NOTE]** `lua/agent-ide/git.lua:43` — `if not cb then return end`
   this is fine, but move the guard above the pcall

## commit 60523ec (update images)

3. **[DESIGN]** `README.md` (file)
   the screenshots belong under docs/images, not the root
```

The kinds line lists only the kinds used. A `-` line is referenced as `path:42 (old line)`, a file-level comment as `path (file)`. Paths are relative to the repository root; when the session's folder is not the root, a `Repository: <root>` line follows the first line. Branch and commits scopes head their group `branch vs main (uncommitted included)` and `commits on branch (main..HEAD)`; on the default branch, `recent commits (<oldest>..HEAD)`.

In the drawer:

```
  ▾ Commits on branch (4)
        review (3) · gs
        full diff · gd
        commit graph · G
      ▸ uncommitted (2)
      7f0f916 rearrange full diff          2 h
```

## Constraints

- Rules 3, 4, 8 and 11 of AGENTS.md as above. Rule 10: no dependencies; `vim.ui.select` and the plugin's `ask_float` only.
- Every key through `util/keys.lua`, listed in the full diff's `g?` and the README tables. `c`, `dd`, `]r`, `[r`, `gs` are in a read-only buffer; nothing is shadowed where the user edits text. Inside the editor the user edits text: only `<CR>` (normal), `<C-CR>`, `q`, `<Esc><Esc>` (normal) and `:w` are taken.
- Highlight groups `default = true`, re-applied on `ColorScheme`; dim text never italic.
- Files about 350 lines; pure logic (the store, the text, the anchoring) tested without a window.

## Approaches considered

1. **Inside the full diff** (chosen). A comment key on any line; the done and send keys there, in the drawer and as a command. Nothing new to open: `gd` already reaches every scope. Cost: the full diff learns about one more overlay and gets five keys.
2. **A review mode**: `:AgentsReview` with a scope picker, the full diff opened in a mode of its own with its own keys and winbar. A clearer entry point, but a second way to open the same view, and the keys would be missing when a problem is spotted while merely reading a diff. Rejected by the owner.
3. **tuicr as an external tool** called from the plugin, reading its markdown export. Rejected: a dependency, a terminal to switch to, and its export would still have to be pasted; the plugin already has the diff and the session.

## Design

### Store (`lua/agent-ide/review.lua`, pure apart from the file)

A review is **per work tree**: keyed by the full diff's root (`V.root`), the same tree whose `Commits` section the drawer shows (a project with linked worktrees has one section and one review per tree). Paths are relative to that root; the session candidates are the project's sessions regardless of their folder. One JSON file per work tree: `stdpath('state')/agent-ide/reviews/<repository folder name>-<short hash of root>.json` (the naming of saved prompts), `0600` in a `0700` folder, written atomically through `util/jsonfile.lua`; read leniently (a corrupt file: no comments, a notice). Refreshed by stamp before every read of another Neovim's changes, as `names.lua` does.

```json
{ "version": 1, "root": "/abs/path", "session": "<id>" | "new" | null,
  "comments": [ { "id": 1, "kind": "BUG", "text": "swallows the error",
    "scope": { "kind": "head", "hash": "7f0f916" },
    "path": "lua/agent-ide/git.lua", "line": 42, "side": "new", "code": "  if not ok then return cb(nil) end",
    "at": "2026-11-15T08:10:05Z" } ] }
```

`scope.kind` is the full diff's (`branch`, `commits`, `commit`, `head`); `hash` the commit's for `commit`, `HEAD`'s short hash for `head`, and the base's label for `branch` and `commits` (`base`), with `subject` for a commit. `side` is `new` for `+` and context lines, `old` for `-` lines, absent with `line` for a file-level comment. `code` is the line's text without its `+`/`-`/space.

API: `load(root)`, `list(root, scope?)`, `add(root, comment)`, `update(root, id, text, kind)`, `remove(root, id)`, `session(root)`, `set_session(root, id)`, `clear(root, ids)`, `count(root)`, `roots()` (repositories with pending comments, for the drawer). `kind_of(text, kinds)` splits `KIND: text` (pure).

### Anchoring (`fulldiff_render.lua`, pure)

The render's per-line nodes get `old_line` beside `new_line` (counted from the `@@ -a` start as `new_line` is counted from `+c`), so a `-` line has an anchor. A comment matches a line of the open scope when the path and (`side`, line) agree with the node; a file-level comment matches the file's header line; a comment whose path is in the scope but whose line is not shows under the header with the dim note; a comment whose path is not in the scope is not shown there (it is still in the review, and in the count of the drawer row and the done dialog).

Scope match: a comment belongs to a scope when `scope.kind` agrees and, for `commit`, the hash agrees. `branch` and `head` both show the uncommitted lines of a file: a comment made in one is shown in the other too when the line is there, so that a review of the branch sees the notes made on the uncommitted part. The group heading in the text is the scope the comment was made in.

### Display (`lua/agent-ide/ui/review_marks.lua`)

Its own namespace. `place(view)` is called at the end of the full diff's `draw`: clears the namespace, walks the comments of the scope (not the lines), finds each anchor through an index `path -> { side/line -> buffer line, header -> buffer line }` built from the nodes in one pass, and sets `virt_lines` extmarks (`virt_lines_above = false`). A fold hides the virtual lines of its lines with them, as Neovim does. The winbar gets `· n comments` (`1 comment`). `cursor.key` and `cursor.find` are unchanged: virtual lines do not shift buffer lines.

Highlights: `AgentIdeReviewBar` (dim), `AgentIdeReviewText` (normal), and one per built-in kind: `AgentIdeReviewNote` (blue), `AgentIdeReviewIssue` (yellow), `AgentIdeReviewBug` (red), `AgentIdeReviewDesign` (violet), `AgentIdeReviewSuggestion` (green), `AgentIdeReviewQuestion` (cyan); a configured kind without a group of its own uses `AgentIdeReviewKind` (bold). The dim note of a lost line: `AgentIdeDiffNote`.

### Editor (`lua/agent-ide/ui/review_edit.lua`)

`open(view, node, existing?)`: the float as described, `buftype = acwrite`, filetype markdown, `agent_ide_kind = 'review'`. Save parses the kind, writes through the store, closes, and re-places the marks. The first save of a review with no session chosen asks the session question first; cancel there leaves the comment unsaved in the editor (the float stays). `<C-CR>` saves, then runs the direct send with this comment only, and on success removes it from the review.

### Session and sending (`lua/agent-ide/ui/review_send.lua`)

- `candidates(root)`: the chat the open full diff was opened over (`view.prev.chat`), the project's sessions from the drawer's model, newest first; the default marked.
- `ask_session(root, cb)`: the question above; `+ new session` creates one as the drawer's `+ New session` row does (`session.open({ cwd = root })`, `model.add_unsaved`), opened in the chat; `another session…` lists the project's sessions with state and age. The choice is stored (`set_session`); `new` is resolved to the created session's id at once.
- `done(root)`: builds the text (below) and asks the placement; `Insert above` / `Replace` go through `prompt.put` on the session's prompt buffer (the chat opened when it is not), then `chat.focus_prompt`; `Copy to clipboard` sets the `+` and unnamed registers; both clear the sent comments and notify (`review of myapp: 3 comments in the prompt of "fix the git runner"`). `Another session…` re-asks and comes back to the placement.
- `send_now(root, comment)`: the text with this one comment, sent through the chat's send path with a given text instead of the prompt buffer's lines, so every gate applies (handoff, the fresh `claude agents` check before a start, the resume-size question) and the draft in the prompt stays untouched. The builder refactors `chat.lua`'s `send(c)` into `send_text(c, text)` plus the buffer-reading wrapper, where the text is held across the asynchronous gates (the "prompt changed while checking" test does not apply to a given text). The gates are floats, `vim.ui.select` and `vim.fn.confirm`: they need no chat window. The chat's buffers are created (`get_chat`) when the session has none; **no chat window is opened** by the review flow, the full diff stays where it is. Queued when busy (`Session:send` already does), else started with `prefs.start_model(s)` and the deferred mode as any first send. The comment leaves the review when `Session:send` answers ok (queued counts); a cancelled gate or a refusal keeps it.

**The full diff keeps its window.** `chat.open` would put the transcript into the window the full diff occupies and wipe the view. So: `+ new session` in the session question only creates the session (`session.open({ cwd = root })`, the drawer model's `add_unsaved`), it does not open it; the done step's `Insert above` / `Replace` put the text through `prompt.put` and then `chat.focus_prompt(s, false)`, which opens the prompt split below the full diff (the chat's transcript is not shown), so the diff stays readable while the general remarks are typed, and `q` in the diff still comes back to what was there. The chat is opened as usual from the drawer or the prompt's own keys.

**The target is visible before a direct send.** The editor's winbar names the review's session (`→ fix the git runner`) after the kinds; the full diff's winbar reads `· 2 comments → fix the git runner`. A stored session that no longer exists (not loaded, not in the project's list, deleted) is dropped from the store and the question is asked again at the next save or done step; nothing is recreated from an id.

### Text (`lua/agent-ide/review_text.lua`, pure)

`build(comments, opts)` with `opts = { project, root, cwd, kinds }` gives the lines shown above: the first line, the `Repository:` line when `cwd ~= root`, the kinds line with the kinds used and their descriptions, then a group per scope in the order the comments were made (first comment of each scope decides the group's place), numbered through, each comment as `n. **[KIND]** \`path:line\` — \`code\`` then the text indented by three spaces (every line of a multi-line comment). The first line and the kinds line are configurable (`review.intro`, `review.kinds`).

### Keys and configuration

```lua
keys.full_diff = { …, comment = 'c', delete_comment = 'dd', next_comment = ']r', prev_comment = '[r', review = 'gs' }
keys.review = { save = '<CR>', send = '<C-CR>', cancel = { 'q', '<Esc><Esc>' } }   -- the editor, buffer-local
keys.drawer.review = 'gs'   -- the done step for the row's project, on any row of a git project
review = {
  kinds = { { 'NOTE', 'an observation' }, { 'ISSUE', 'a problem to fix' }, { 'BUG', 'wrong behaviour' },
    { 'DESIGN', 'structure or approach' }, { 'SUGGESTION', 'an improvement' }, { 'QUESTION', 'something to explain' } },
  intro = 'I reviewed your changes and have the following comments. Please address them.',
}
```

`dd` on a diff line with a comment removes it (into the unnamed register, as the queue panel does); on a line without one it does nothing. `]r` / `[r` go to the next / previous commented line not inside a closed fold. The full diff's `g?` lists the five keys; the editor has its own `g?` row in the winbar instead of a help float.

### Drawer

`git_sections.lua` adds the `review (n) · gs` row above `full diff · gd` in the Commits section when the store counts `n > 0` for the root (the count read from the store's cache: no file read while building rows; the store refreshes its stamp on the drawer's refresh ticks, as `names.refresh` is called). Its node: `{ type = 'git_review', root, project, open = done }`. The drawer's `gs` on any row of a git project runs the done step for that root.

### Tests

- `tests/test_review.lua`: the store (round trip, lenient read, stamps, `kind_of`), the text (`build` against the example above, old side, file-level, `Repository:` line, kinds line), anchoring (`old_line` in the nodes; a lost line goes to the header).
- `tests/test_review_ui.lua` (child Neovim, the full diff's fixture repository): `c` + text + `<CR>` shows the virtual line and writes the file; the session question appears once; `R` keeps the comment; a comment on a `-` line; `dd` removes; `gs` puts the text in the prompt (above the draft) and clears the review; `<C-CR>` in the editor calls `Session:send` with the one-comment text (the fake `claude` of `tests/`), the comment gone afterwards; the drawer row appears and disappears; `:AgentsReview`.
- `tests/test_fulldiff_budget.lua` gains a case: placing 200 comments on the 50 000-line synthetic patch under 20 ms, and the existing budgets unchanged.

## What is left to the builder

- The exact float geometry and how it follows a resize; whether the float has a border.
- The index from nodes to buffer lines (one pass over `t.nodes`, built in `place`, or kept on the render result).
- How `send_text` shares code with `send` without growing `chat.lua` past its size (a `chat_send.lua` split is fine).
- The order of the `another session…` picker and its row format (reuse the drawer's row text where it can).
- The wording of notices and of `docs/review.md`, within the README's tone. The comparison table states only what is verified from each tool's README at the time of writing, dated, and lists what Agent-IDE does not do (no forge push, no jj or hg, not a single binary). The tools: [tuicr](https://tuicr.dev/), [hunk](https://github.com/modem-dev/hunk), [lumen](https://github.com/jnsahaj/lumen), `gh pr review`, `git diff`.
- Cross-showing a comment between the `branch` and `head` scopes only for new-side and file-level anchors (old-side numbers differ between the merge-base and `HEAD`); the commit's full hash stored beside the short one; a notice for `:AgentsReview` and `gs` with nothing pending.

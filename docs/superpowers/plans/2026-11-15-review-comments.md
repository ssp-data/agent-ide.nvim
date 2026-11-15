# Review comments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Typed comments on lines of the full diff, shown inline, kept per work tree in the plugin's state folder, and sent to a Claude session as a tuicr-style review with every reference filled in.

**Architecture:** A pure store (`review.lua`) and a pure text builder (`review_text.lua`) under `lua/agent-ide/`; three UI modules beside the full diff: `review_marks.lua` (virtual lines from a render), `review_edit.lua` (the comment float), `review_send.lua` (session choice, the done dialog, the direct send). The full diff gets five keys and places the marks after every draw; the drawer a `review (n)` row and `gs`; the chat a `send_text` entry that shares every gate of its `send`.

**Tech Stack:** Lua, Neovim 0.12 (`virt_lines` extmarks, `ask_float` / `vim.ui.select`), mini.test (`make test`, `TEST_FILE=… make test`).

**Spec:** `docs/superpowers/specs/2026-11-15-review-comments-design.md`

## Global Constraints

- AGENTS.md rules 3 (no focus changes or pop-ups while typing), 4 (budgets never weakened; nothing synchronous on the UI thread), 8 (writes only in the plugin's folders, `0600` in `0700`, atomic), 10 (no dependencies), 11 (synthetic fixtures, no real paths or ids).
- Every key through `util/keys.lua`; new full diff keys in `fulldiff_keys.HELP` and the README tables; nothing shadowed in the comment editor beyond `<CR>` (normal), `<C-CR>`, `q`, `<Esc><Esc>` (normal), `:w`.
- Highlight groups `default = true`, re-applied on `ColorScheme`; dim never italic.
- Files about 350 lines; `review.lua`, `review_text.lua`, `review_marks.lines` tested without a window.
- The state file: `stdpath('state')/agent-ide/reviews/<basename of root>-<sha256(root):sub(1,12)>.json`, version 1, shape in the spec.
- Default kinds, in this order: `NOTE` an observation, `ISSUE` a problem to fix, `BUG` wrong behaviour, `DESIGN` structure or approach, `SUGGESTION` an improvement, `QUESTION` something to explain. Default intro: `I reviewed your changes and have the following comments. Please address them.`
- Branch: the current branch `in-line-git-comments` (clean tree). Commit per task with explicit paths only; never `git add -A`, never stash.

## Review Focus

1. A comment typed as `bug: …` or `Bug - …` (lower case, no colon): the kind must be found case-insensitively up to a colon; without a colon the whole text is a `NOTE`. Pinned in Task 1 (`kind_of` cases).
2. A reload after a turn removes the commented line (the hunk is gone): the comment must still be shown under its file header with the note and still be sent. Pinned in Task 3 (`lines` with a lost anchor) and Task 4 (UI reload).
3. The review's stored session was deleted or never loaded: `<C-CR>` and `gs` must ask again, never send to an id that no longer exists. Pinned in Task 5 (`ensure_session` with a dead id).
4. A corrupt or hand-edited reviews file: no error on open, an empty review, a notice once. Pinned in Task 1 (`load` of garbage).
5. The done step with the prompt holding a draft, then `Cancel`: nothing in the prompt changes and the comments stay. Pinned in Task 5 (UI done cancel).

---

### Task 1: The store (`review.lua`)

**Files:**
- Create: `lua/agent-ide/review.lua`
- Test: `tests/test_review.lua`

**Interfaces:**
- Produces:
  - `M.DEFAULT_KINDS: { string, string }[]` (the six kinds above).
  - `M.kind_of(text: string, kinds?: table): string kind, string rest` — `kinds` as `config.review.kinds` (default `DEFAULT_KINDS`); the first word up to a colon, case-insensitive, is a kind; `rest` is trimmed; otherwise `'NOTE', text`.
  - `M.file(root: string): string`.
  - `M.load(root)`, `M.refresh(root): boolean changed` (by `jsonfile.stamp`, as `names.lua`).
  - `M.list(root, scope?: table): comment[]` in creation order; with `scope`, only those `M.matches(c, scope)`.
  - `M.matches(c: comment, scope: { kind: string, hash?: string }): boolean` (pure): same `kind` and, for `commit`, same `hash`; `head` and `branch` match each other when `c.side ~= 'old'`.
  - `M.add(root, c: { kind, text, scope, path, side?, line?, code? }): comment` — assigns `id` (next integer) and `at` (ISO 8601 UTC), writes.
  - `M.update(root, id, fields: { kind?, text? }): boolean`.
  - `M.remove(root, id): comment|nil`.
  - `M.clear(root, ids: integer[])`.
  - `M.count(root): integer` (refreshes first).
  - `M.session(root): string|nil`, `M.set_session(root, id: string|nil)`.
  - `M._reset()` (tests).
- Consumes: `agent-ide.util.jsonfile` (`read`, `stamp`, `write_atomic`), modes 0600/0700 as `drafts.lua`.

- [ ] **Step 1: Write the failing tests**

```lua
-- tests/test_review.lua
local review = require('agent-ide.review')
T['kind_of: a known kind up to a colon, any case; else NOTE with the whole text'] = function()
  eq({ review.kind_of('BUG: swallows the error') }, { 'BUG', 'swallows the error' })
  eq({ review.kind_of('bug:   trailing  ') }, { 'BUG', 'trailing' })
  eq({ review.kind_of('Bug - no colon') }, { 'NOTE', 'Bug - no colon' })
  eq({ review.kind_of('nit: x', { { 'NIT', 'small' } }) }, { 'NIT', 'x' })
  eq({ review.kind_of('NOTE:') }, { 'NOTE', '' })
end
T['add, list, update, remove, clear, count; ids grow; the file round-trips'] = function()
  local c = review.add(root, { kind = 'BUG', text = 'x', scope = { kind = 'head', hash = 'abc1234' }, path = 'a.lua', side = 'new', line = 3, code = 'local a' })
  eq({ c.id, c.at ~= nil }, { 1, true })
  review.add(root, { kind = 'NOTE', text = 'y', scope = { kind = 'commit', hash = 'deadbeef', short = 'deadbee', subject = 's' }, path = 'b.lua' })
  eq(#review.list(root), 2); eq(review.count(root), 2)
  review._reset(); eq(review.list(root)[2].scope.subject, 's')  -- read again from disk
  eq(review.update(root, 1, { text = 'z' }), true); eq(review.list(root)[1].text, 'z')
  eq(review.remove(root, 2).text, 'y'); review.clear(root, { 1 }); eq(review.count(root), 0)
  eq(review.add(root, { kind = 'NOTE', text = 'n', scope = { kind = 'head' }, path = 'a' }).id, 3)
end
T['matches: kind and hash; head and branch see each other except old-side anchors'] = function()
  local head_new = { scope = { kind = 'head' }, side = 'new' }
  eq(review.matches(head_new, { kind = 'branch' }), true)
  eq(review.matches({ scope = { kind = 'head' }, side = 'old' }, { kind = 'branch' }), false)
  eq(review.matches({ scope = { kind = 'branch' } }, { kind = 'head' }), true)  -- file-level
  eq(review.matches({ scope = { kind = 'commit', hash = 'a' } }, { kind = 'commit', hash = 'b' }), false)
  eq(review.matches({ scope = { kind = 'commits' } }, { kind = 'commits' }), true)
end
T['session is kept; a corrupt file reads as empty and notifies once'] = function()
  review.set_session(root, 'id-1'); review._reset(); eq(review.session(root), 'id-1')
  vim.fn.writefile({ '{ not json' }, review.file(root)); review._reset()
  eq(review.list(root), {}); eq(#notes, 1)
end
T['file: under state/agent-ide/reviews, mode 0600, folder 0700'] = function() ... end
T['refresh: another writer\'s change is seen by stamp'] = function() ... end
```

Use the runner's temporary `stdpath('state')`; `root` is a temp folder; stub `vim.notify` into `notes`.

- [ ] **Step 2: Run to see them fail**

Run: `TEST_FILE=tests/test_review.lua make test` — expected: module not found.

- [ ] **Step 3: Implement `lua/agent-ide/review.lua`**

Per-root cache `{ data = { version, root, session, comments, next_id }, stamp }`; `load` reads leniently (a non-table or wrong `version`: empty, one notice `Agent-IDE: reviews file unreadable, starting empty: <path>` per file until it reads again). Write after every change through `jsonfile.write_atomic(path, vim.json.encode(data) .. '\n', 384)` with the folder made `0700` (`vim.fn.mkdir(dir, 'p', 448)` as `drafts.lua`). Header comment in the file's style: what the file holds and its shape.

- [ ] **Step 4: Run the tests to see them pass**

Run: `TEST_FILE=tests/test_review.lua make test` — expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lua/agent-ide/review.lua tests/test_review.lua
git commit -m "review: a per-work-tree store of comments"
```

---

### Task 2: The review text (`review_text.lua`)

**Files:**
- Create: `lua/agent-ide/review_text.lua`
- Test: `tests/test_review.lua` (a second section)

**Interfaces:**
- Produces:
  - `M.heading(scope): string` — `head`: `uncommitted changes (working tree against HEAD <short>)`; `commit`: `commit <short> (<subject>)`; `branch`: `branch vs <base> (uncommitted included)`; `commits`: `commits on branch (<base>..HEAD)`, or `recent commits` when `scope.base == 'HEAD'` or nil.
  - `M.reference(c): string` — `` `path:line` `` (new side), `` `path:line (old line)` ``, `` `path (file)` ``.
  - `M.build(comments: comment[], opts: { project: string, root: string, cwd?: string, kinds: table, intro: string }): string[]` — the lines of the spec's example: intro; `Repository: <root>` when `opts.cwd ~= nil and opts.cwd ~= opts.root`; blank; `Comment kinds: KIND (description), …` for the kinds used, in `kinds` order (a kind not in `kinds`: its name alone); then per scope group in first-appearance order: blank, `## <heading>`, blank, numbered items `n. **[KIND]** <reference> — \`<code>\`` (no ` — \`code\`` when `code` is nil or empty), then each line of the text indented three spaces.
- Consumes: Task 1's comment shape.

- [ ] **Step 1: Write the failing tests**

```lua
T['build: the spec example, grouped by scope in first-appearance order, numbered through'] = function()
  local lines = text.build({
    { id = 1, kind = 'BUG', text = 'swallows the error, notify instead', scope = { kind = 'head', hash = '7f0f916' }, path = 'lua/agent-ide/git.lua', side = 'new', line = 42, code = '  if not ok then return cb(nil) end' },
    { id = 2, kind = 'NOTE', text = 'this is fine, but move the guard above the pcall', scope = { kind = 'head', hash = '7f0f916' }, path = 'lua/agent-ide/git.lua', side = 'new', line = 43, code = '  if not cb then return end' },
    { id = 3, kind = 'DESIGN', text = 'the screenshots belong under docs/images, not the root', scope = { kind = 'commit', hash = '60523ec0', short = '60523ec', subject = 'update images' }, path = 'README.md' },
  }, { project = 'myapp', root = '/r', kinds = review.DEFAULT_KINDS, intro = review_text.DEFAULT_INTRO })
  eq(lines, {
    'I reviewed your changes and have the following comments. Please address them.', '',
    'Comment kinds: NOTE (an observation), BUG (wrong behaviour), DESIGN (structure or approach)', '',
    '## uncommitted changes (working tree against HEAD 7f0f916)', '',
    '1. **[BUG]** `lua/agent-ide/git.lua:42` — `  if not ok then return cb(nil) end`', '   swallows the error, notify instead',
    '2. **[NOTE]** `lua/agent-ide/git.lua:43` — `  if not cb then return end`', '   this is fine, but move the guard above the pcall', '',
    '## commit 60523ec (update images)', '',
    '3. **[DESIGN]** `README.md` (file)', '   the screenshots belong under docs/images, not the root' })
end
T['build: old side, multi-line text, Repository line, an unknown kind'] = function() ... end
T['heading: branch, commits, recent commits'] = function() ... end
```

Note: `(file)` sits outside the backticks: `` `README.md` (file) ``.

- [ ] **Step 2: Run to see them fail** — `TEST_FILE=tests/test_review.lua make test`.

- [ ] **Step 3: Implement `lua/agent-ide/review_text.lua`** with `M.DEFAULT_INTRO`.

- [ ] **Step 4: Run to see them pass.**

- [ ] **Step 5: Commit**

```bash
git add lua/agent-ide/review_text.lua tests/test_review.lua
git commit -m "review: the text sent to Claude, grouped by scope with references"
```

---

### Task 3: Anchors in the render and the marks (`review_marks.lua`)

**Files:**
- Modify: `lua/agent-ide/ui/fulldiff_render.lua` (the `hunks` loop, lines ~104-146)
- Create: `lua/agent-ide/ui/review_marks.lua`
- Test: `tests/test_fulldiff.lua` (nodes), `tests/test_review.lua` (`lines`), `tests/test_fulldiff_budget.lua` (one case)

**Interfaces:**
- Produces:
  - Render nodes: a `-` line's node is `{ file = k, old_line = n }`; a context line `{ file = k, new_line = n, old_line = m }`; a `+` line unchanged (`new_line` only). `old_line` counts from `@@ -a` as `new_line` counts from `+c` (`hunk_start` returns both).
  - `M.anchor(t, row): { path: string, side?: 'new'|'old', line?: integer, code?: string }|nil` — the anchor of buffer line `row` of render `t`: header, note, `@@` or blank: file-level (`side`, `line`, `code` nil); `+`/context: `new`; `-`: `old`; `code` is the line without its first character for diff lines. nil when `row` has no node.
  - `M.lines(t, comments): table<integer, { comment: comment, lost: boolean }[]>` (pure) — buffer line → the comments to show under it; a comment whose path is in `t.files` but whose anchor line is not found goes under the header with `lost = true`; a path not in the render is left out. Walks only the fold ranges (`t.folds`) of commented paths.
  - `M.place(buf, t, comments): table<integer, {...}[]>` — `lines(...)`, clears the namespace `agent-ide.review`, one `virt_lines` extmark per line (`virt_lines_above = false`), returns the map. Virtual line chunks: `{ '  ┃ ', 'AgentIdeReviewBar' }, { kind .. '  ', group_of(kind) }, { text line, 'AgentIdeReviewText' }`; further text lines `{ '  ┃      ', bar }`; a lost one adds `{ '  (line 42 not in this diff)', 'AgentIdeDiffNote' }` after the kind.
  - `M.group_of(kind): string` — `AgentIdeReview` .. capitalised kind for the six built-in, else `AgentIdeReviewKind`.
  - Highlight groups added to `ui/git_hl.lua` `GROUPS`: `AgentIdeReviewBar` (dim), `AgentIdeReviewText` ({}), `AgentIdeReviewNote` blue `#7aa2f7`/111, `AgentIdeReviewIssue` yellow `#e0af68`/179, `AgentIdeReviewBug` red `#f7768e`/204, `AgentIdeReviewDesign` violet `#bb9af7`/141, `AgentIdeReviewSuggestion` green `#9ece6a`/114, `AgentIdeReviewQuestion` cyan `#7dcfff`/117, `AgentIdeReviewKind` `{ bold = true }`; all `bold = true` for the kinds.
- Consumes: `agent_ide.FullDiffRender` (`lines`, `nodes`, `files`, `folds`).

- [ ] **Step 1: Write the failing tests**

In `tests/test_fulldiff.lua` (renderer section), using `PATCH`'s first block (`@@ -1,3 +1,4 @@`, ` a`, `-b`, `+bb`, `+c`, ` d`):

```lua
T['nodes carry old_line for - and context lines'] = function()
  local t = render.build(files, blocks, OPTS)
  eq(t.nodes[3], { file = 1, new_line = 1, old_line = 1 })   -- ' a'
  eq(t.nodes[4], { file = 1, old_line = 2 })                 -- '-b'
  eq(t.nodes[5], { file = 1, new_line = 2 })                 -- '+bb'
  eq(t.nodes[7], { file = 1, new_line = 4, old_line = 3 })   -- ' d'
end
```

In `tests/test_review.lua`:

```lua
T['anchor: header and @@ are file-level; +, -, context carry side, line and code'] = function()
  eq(marks.anchor(t, 1), { path = 'lua/x.lua' })
  eq(marks.anchor(t, 4), { path = 'lua/x.lua', side = 'old', line = 2, code = 'b' })
  eq(marks.anchor(t, 5), { path = 'lua/x.lua', side = 'new', line = 2, code = 'bb' })
end
T['lines: anchors found, a lost line under the header, a path not shown left out'] = function()
  local m = marks.lines(t, {
    { id = 1, path = 'lua/x.lua', side = 'new', line = 2 },
    { id = 2, path = 'lua/x.lua', side = 'old', line = 2 },
    { id = 3, path = 'lua/x.lua' },
    { id = 4, path = 'lua/x.lua', side = 'new', line = 99 },
    { id = 5, path = 'gone.lua', side = 'new', line = 1 } })
  eq(vim.tbl_map(function(e) return e.comment.id end, m[5]), { 1 })
  eq(m[4][1].comment.id, 2)
  eq(vim.tbl_map(function(e) return { e.comment.id, e.lost } end, m[1]), { { 3, false }, { 4, true } })
  eq(m[99], nil)
end
```

In `tests/test_fulldiff_budget.lua`: `T['placing 200 comments on 50 000 lines: under 20 ms']` — 200 comments spread over 200 files (new-side lines 2..), `marks.place(buf, t, comments)` on the buffer the existing render case fills, best of 5 under 20 ms; the existing budgets unchanged.

- [ ] **Step 2: Run to see them fail** — `TEST_FILE=tests/test_fulldiff.lua make test`, `TEST_FILE=tests/test_review.lua make test`.

- [ ] **Step 3: Implement** the `old_line` counting in `fulldiff_render.hunks` and `lua/agent-ide/ui/review_marks.lua`; add the groups to `git_hl.lua`.

- [ ] **Step 4: Run the three files and `make test`** — expected: all green, `test_fulldiff_budget` still within its budgets.

- [ ] **Step 5: Commit**

```bash
git add lua/agent-ide/ui/fulldiff_render.lua lua/agent-ide/ui/review_marks.lua lua/agent-ide/ui/git_hl.lua tests/test_fulldiff.lua tests/test_review.lua tests/test_fulldiff_budget.lua
git commit -m "full diff: old-side anchors; review comments as virtual lines"
```

---

### Task 4: Comments in the full diff: keys, editor, winbar

**Files:**
- Modify: `lua/agent-ide/config.lua` (`keys.full_diff`, new `keys.review`, new `review = { kinds, intro }`), `lua/agent-ide/ui/fulldiff_keys.lua` (HELP), `lua/agent-ide/ui/fulldiff.lua` (actions, `draw`, `winbar`, `V.marks`), `README.md` configuration block only as far as the defaults (Task 7 does the prose)
- Create: `lua/agent-ide/ui/review_edit.lua`
- Test: `tests/test_review_ui.lua` (child Neovim; copy the fixture repository helpers of `tests/test_fulldiff_ui.lua`: `make_repo`, `write_session`, `start`, `view`, `cursor_on`, `open`)

**Interfaces:**
- Config defaults: `keys.full_diff` gains `comment = 'c', delete_comment = 'dd', next_comment = ']r', prev_comment = '[r', review = 'gs'`; `keys.review = { save = '<CR>', send = '<C-CR>', cancel = { 'q', '<Esc><Esc>' } }`; `review = { kinds = <DEFAULT_KINDS>, intro = <DEFAULT_INTRO> }`.
- `fulldiff.lua`: after `draw` sets `V.t`, `V.marks = review_marks.place(V.buf, V.t, review.list(V.root, V.scope))` (an empty map while loading); `winbar()` appends `· n comments` (`1 comment`) when `n > 0`, and ` → <session name>` after it when `review_send.target_name(V.root)` is non-nil (Task 5; until then nothing). `M.scope_of(v): table` — the stored scope of the open view: `{ kind, hash = head short | commit hash, short, subject, base = cache.base(root).label }` (for `head`: `hash = (cache.head(root).head or ''):sub(1, 7)`).
- Actions in `fulldiff.lua`: `A.comment()` (edit when the cursor line has a comment in `V.marks` that is not lost, else a new one from `review_marks.anchor(V.t, row)`), `A.delete_comment()` (the first comment of the cursor line: `review.remove`, text into the unnamed register, re-place; nothing when none), `A.next_comment()` / `A.prev_comment()` (the next / previous line in `V.marks` not inside a closed fold, wrapping not), `A.review()` (Task 5's `review_send.done(V.root, V.project)`; until then a notice).
- `review_edit.lua`:
  - `M.open(opts: { root: string, scope: table, anchor: table, existing?: comment, project: table, on_change: fun() }): integer win` — a float anchored to the cursor line (`relative = 'cursor'`, `row = 1`, `col = 0`, width = the window's text width minus 2, height 3, border `'rounded'`, `title = ' comment '`), a scratch buffer `buftype = 'acwrite'`, filetype `markdown`, `agent_ide_kind = 'review'`, prefilled with `KIND: text` for an existing comment, insert mode at the end; winbar `NOTE · ISSUE · BUG · DESIGN · SUGGESTION · QUESTION — <CR> save · <C-CR> send now · q cancel` (the configured kinds and keys). Height follows the line count up to 8 (`TextChanged`, `TextChangedI`).
  - Save: `review.kind_of(text)` on the buffer's text (lines joined with `\n`, trailing blank lines dropped); empty: close, nothing saved; `existing`: `review.update`; else `review_send.ensure_session(root, project, function(ok) … end)` (Task 5; until then a stub that calls back `true`) then `review.add`; close; `on_change()`.
  - `<C-CR>`: save as above, then `review_send.send_now(root, project, comment)` (Task 6; until then a notice `send now comes in a later step`).
  - Cancel keys: close; when the text differs from what was opened: `vim.fn.confirm('Discard this comment?', '&Discard\n&Keep editing', 2)`.
  - `BufWriteCmd` = save. `M.state(): { win, buf }|nil` (tests).

- [ ] **Step 1: Write the failing UI tests**

```lua
-- tests/test_review_ui.lua (start with chat = { ask_picker = 'select' } and a vim.ui.select stub that records items and picks 1)
T['c on a + line, text, <CR>: a virtual line under it, the file written, the winbar counts'] = function()
  start(); open({ kind = 'head' }); cursor_on('+aaa')
  child.type_keys('c'); eq(child.lua_get('require("agent-ide.ui.review_edit").state() ~= nil'), true)
  child.type_keys('BUG: swallows it', '<Esc>', '<CR>')
  wait_for(function() return virt_lines()[view_line('+aaa')] ~= nil end, 'the virtual line')
  eq(virt_text(view_line('+aaa')), '  ┃ BUG  swallows it')
  eq(view().winbar:find('1 comment', 1, true) ~= nil, true)
  local data = vim.json.decode(table.concat(vim.fn.readfile(child.lua_get('require("agent-ide.review").file(...)', { repo })), '\n'))
  eq({ data.comments[1].path, data.comments[1].side, data.comments[1].line, data.comments[1].code, data.comments[1].scope.kind }, { 'a.txt', 'new', 3, 'aaa', 'head' })
end
T['c on a - line anchors the old side; c on a header is file-level; c on a commented line edits it'] ...
T['R reloads: the comment stays; after the line is gone it sits under the header with the note'] ...
T['dd removes the comment (unnamed register holds its text); ]r / [r step commented lines'] ...
T['q in the editor with changed text asks; an empty save writes nothing'] ...
T['the comment is shown in the branch scope too (head and branch see each other)'] ...
```

`virt_lines()` reads `nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })` for the namespace `agent-ide.review` and maps row+1 → the joined chunk texts.

- [ ] **Step 2: Run to see them fail** — `TEST_FILE=tests/test_review_ui.lua make test`.

- [ ] **Step 3: Implement** config defaults, `fulldiff_keys.HELP` entries (`comment`: `comment on this line (on a commented line: edit it)`, `delete_comment`: `delete the comment on this line`, `next_comment` / `prev_comment`, `review`: `review: put the pending comments in the prompt (asks how)`), the actions, `draw` placing, the winbar, `review_edit.lua`.

- [ ] **Step 4: Run `TEST_FILE=tests/test_review_ui.lua make test`, then `make test`** — expected: green, including `test_fulldiff_ui` and `test_keys`.

- [ ] **Step 5: Commit**

```bash
git add lua/agent-ide/config.lua lua/agent-ide/ui/fulldiff_keys.lua lua/agent-ide/ui/fulldiff.lua lua/agent-ide/ui/review_edit.lua tests/test_review_ui.lua
git commit -m "full diff: c comments on a line, dd, ]r / [r, the comment editor"
```

---

### Task 5: The session question, the done step, the drawer row, `:AgentsReview`

**Files:**
- Create: `lua/agent-ide/ui/review_send.lua`
- Modify: `lua/agent-ide/ui/git_sections.lua` (a `review_row` above `fulldiff_row` in the Commits section), `lua/agent-ide/ui/drawer.lua` (`ACTIONS` entry `review`, `actions.review`), `lua/agent-ide/config.lua` (`keys.drawer.review = 'gs'`), `plugin/agent-ide.lua` (`:AgentsReview`), `lua/agent-ide/init.lua` (`M.review()`), `lua/agent-ide/ui/fulldiff.lua` (`A.review`, winbar target)
- Test: `tests/test_review_ui.lua`, `tests/test_git_sections.lua` (the row)

**Interfaces:**
- `review_send.lua`:
  - `M.candidates(root, project): { id?: string, label: string, kind: 'session'|'new'|'other', meta?: table }[]` — first the full diff's `prev.chat` session when the open view has one and it belongs to `project`, else `project.sessions[1]`; labelled `<name or title> (<state>, <age>)` with `names.get`, `drawer_model.state_of`, `tree.ago`; then `{ kind = 'new', label = '+ new session' }`, `{ kind = 'other', label = 'another session…' }`.
  - `M.ask_session(root, project, cb: fun(ok: boolean))` — the question `Review of <project>: send the comments to which session?` through the same `select` dispatch as `permission.lua` (`ask_float.select` or `vim.ui.select` by `chat.ask_picker`; extract that dispatch into `ui/ask_select.lua` `M.select(items, prompt, done, view)` and use it from both). `new`: `session.open({ cwd = root })` + `drawer_model.add_unsaved(s.id, project.key)` + `drawer.refresh()`; `other`: a second select over `project.sessions` labelled as above. Stores `review.set_session(root, id)`; cancel: `cb(false)`.
  - `M.valid_session(root, project): table|nil meta` — the stored id when `session.get(id)` exists or `project.sessions` lists it; else `review.set_session(root, nil)` and nil.
  - `M.ensure_session(root, project, cb)` — `valid_session` or `ask_session`.
  - `M.target_name(root, project?): string|nil` — the stored session's name or title, nil when none.
  - `M.text(root, project, comments): string[]` — `review_text.build` with `project.name`, `root`, the session's `cwd`, `config.review.kinds`, `config.review.intro`.
  - `M.done(root, project)` — nothing pending: notice `no review comments for <project>`; else `ensure_session`, then the dialog `Review of <project>: <n> comments, to "<target>"` with items `Insert above the draft`, `Replace the draft` (one item `Put in the prompt` when the session's prompt buffer is empty or absent), `Copy to clipboard`, `Another session…`, `Cancel`. Put: `chat.buffers(s)` (created through a new `chat.ensure(s, project)` that calls `get_chat` without windows), `prompt.put(pbuf, lines, 'above' | 'replace')`, `chat.focus_prompt(s, false)`; then `review.clear(root, ids)`, notice `review of <project>: <n> comments in the prompt of "<target>"`. Copy: `vim.fn.setreg('+', text)` and `setreg('"', text)`, clear, notice `… copied`. Another session: `ask_session` then the dialog again. Cancel: nothing changes.
- `git_sections.lua`: `review_row(out, w, parent)` when `review.count(w.root) > 0`: text `<indent>    review (<n>) · <keys.drawer.review[1]>` in `AgentIdeSection` for the word, the count dim; node `{ type = 'git_review', root = w.root, project = w.project, id = w.root .. '#review', fold = {...as fulldiff_row}, open = function(n) review_send.done(n.root, n.project) end }`. Placed before `fulldiff_row` in the Commits section only.
- `drawer.lua`: `{ 'review', 'review: send the pending comments of the row\'s repository to Claude (asks how)' }` in `ACTIONS`; `actions.review()` = root from `graph.node_root(current_node())` else notice `not a git project`, then `review_send.done(root, p)`.
- `init.lua`: `M.review()` — the root and project as `fulldiff.open_context` finds them (`graph_context`), then `review_send.done`. `plugin/agent-ide.lua`: `:AgentsReview` → `require('agent-ide').review()`.

- [ ] **Step 1: Write the failing tests**

```lua
T['the first save asks for the session: the project\'s most recent is the default; the answer sticks'] = function()
  -- open the head scope, c, type, <CR>: the select stub saw 'Review of r: send the comments to which session?'
  -- with items[1] starting with the fixture session's title, items[2] '+ new session', items[3] 'another session…';
  -- a second comment asks nothing; review.session(repo) == ID
end
T['+ new session creates one without opening it; the full diff stays'] ...
T['gs: the text lands above the draft, the prompt is focused below the diff, the review is cleared, the drawer row goes'] = function()
  -- write a draft 'my draft' into the session's prompt first (chat.ensure + nvim_buf_set_lines), then gs, pick 'Insert above the draft'
  -- prompt lines: the review text, '', 'my draft'; fulldiff.state() ~= nil; review.count(repo) == 0; the current window shows the prompt buffer
end
T['gs with an empty prompt offers one put choice; Copy to clipboard fills + and clears'] ...
T['gs then Cancel: the prompt and the comments stay'] ...
T['a stored session that is gone is dropped and asked again'] = function()
  -- review.set_session(repo, 'dead-id'); gs → the session question first
end
T['the drawer shows review (n) · gs in Commits while comments are pending; <CR> on it runs the done step'] ...
T[':AgentsReview from the chat of the repository runs the done step; nothing pending notifies'] ...
```

In `tests/test_git_sections.lua`: a `review (2) · gs` row above `full diff · gd` when the store counts 2 for the root (seed the file through `review.add`), none when 0.

- [ ] **Step 2: Run to see them fail.**

- [ ] **Step 3: Implement** `review_send.lua` (keep it near 300 lines: the dialogs and the candidates there, the text in `review_text`), `ask_select.lua` extracted from `permission.lua`, the row, the drawer action, the command, the winbar target in `fulldiff.lua`, and wire `review_edit`'s `ensure_session`.

- [ ] **Step 4: Run `make test`** — expected green (`test_permission` still passes after the extraction).

- [ ] **Step 5: Commit**

```bash
git add lua/agent-ide/ui/review_send.lua lua/agent-ide/ui/ask_select.lua lua/agent-ide/ui/permission.lua lua/agent-ide/ui/git_sections.lua lua/agent-ide/ui/drawer.lua lua/agent-ide/config.lua plugin/agent-ide.lua lua/agent-ide/init.lua lua/agent-ide/ui/fulldiff.lua lua/agent-ide/ui/review_edit.lua tests/test_review_ui.lua tests/test_git_sections.lua
git commit -m "review: which session, the done step into the prompt, the drawer row, :AgentsReview"
```

---

### Task 6: Direct send (`<C-CR>` in the editor)

**Files:**
- Modify: `lua/agent-ide/ui/chat.lua` (`send` → `send(c, given?)`, `deliver(c, given?)`, new `M.send_text`, `M.ensure`), `lua/agent-ide/ui/review_send.lua` (`send_now`), `lua/agent-ide/ui/review_edit.lua` (`<C-CR>`)
- Test: `tests/test_review_ui.lua` (with `tests/fake.lua`'s fake Claude, as `tests/test_chat.lua` does)

**Interfaces:**
- `chat.M.send_text(s: table, project: table, text: string, done?: fun(ok: boolean))` — `get_chat(s, project)` (no window), then the same path as `send(c)` with `given = { text = text, done = done }`: the plugin-command check is skipped, `handoff.away` applies, `c.loading` holds it (`c.pending = given`, delivered after the load instead of `send_after_load`), the live check applies without the changedtick test, `context_ask.before_resume` applies without it; `deliver` sends `given.text` and does not clear the prompt; `done(ok)` is called once with `Session:send`'s result (false on any refusal, cancel or timeout; a cancel notifies as today). If `chat.lua` passes ~700 lines, move `send`, `deliver`, the live check and `M.send_text` into `ui/chat_send.lua` with `send(c)` kept as the chat's action.
- `review_send.M.send_now(root, project, comment)` — `ensure_session`, then `chat.send_text(s, project, table.concat(M.text(root, project, { comment }), '\n'), function(ok) if ok then review.remove(root, comment.id); fulldiff.redraw_marks(); notify('sent to "<target>": [KIND] <reference> …') end end)`; `fulldiff.M.redraw_marks()` re-places the marks and the winbar of the open view.

- [ ] **Step 1: Write the failing tests**

```lua
T['<C-CR> in the editor sends that one comment: the fake sees the review text; the comment leaves the review'] = function()
  -- start with claude = { cmd = fake.cmd(turn('**[BUG]** `a.txt:3`', 'ok')) }, FAKE_CLAUDE_LOG set
  -- c, 'BUG: swallows it', <C-CR>; the select stub answers the session question with 1
  -- wait: fake log holds an "in" line containing 'I reviewed your changes' and '`a.txt:3` — `aaa`' and 'swallows it'
  -- review.count(repo) == 0; the full diff is still shown; the session's state goes busy then idle
end
T['<C-CR> while a turn runs queues it (the comment leaves the review once queued)'] ...
T['<C-CR> on a session running elsewhere is refused; the comment stays'] ...
```

- [ ] **Step 2: Run to see them fail.**

- [ ] **Step 3: Implement** the `chat.lua` refactor (behaviour of `send(c)` unchanged: `tests/test_chat.lua` is the guard), `send_now`, the editor key.

- [ ] **Step 4: Run `make test`** — expected green, `test_chat` included.

- [ ] **Step 5: Commit**

```bash
git add lua/agent-ide/ui/chat.lua lua/agent-ide/ui/chat_send.lua lua/agent-ide/ui/review_send.lua lua/agent-ide/ui/review_edit.lua tests/test_review_ui.lua
git commit -m "review: <C-CR> sends one comment at once through the chat's send path"
```

(Drop `chat_send.lua` from the `add` if the split was not needed.)

---

### Task 7: Documentation

**Files:**
- Modify: `README.md` (Full diff section: a **Review comments** paragraph with the workflow, the example text, the keys; the full diff key table with `c`, `dd`, `]r` / `[r`, `gs`; the drawer key table with `gs`; the configuration block with `keys.full_diff` additions, `keys.review`, `keys.drawer.review`, `review = { kinds, intro }`; the privacy table with a `Reviews (<folder>-<hash>.json per work tree)` row under `stdpath('state')/agent-ide/reviews/`; the highlight groups list; the commands list with `:AgentsReview`), `CHANGELOG.md` (`### Added` under Unreleased: one entry for the feature, one for `:AgentsReview`), `AGENTS.md` (layout rows for `review.lua`, `review_text.lua`, `ui/review_marks.lua`, `ui/review_edit.lua`, `ui/review_send.lua`, `ui/ask_select.lua`; the ledger line that comments live in the state folder, never in git)
- Create: `docs/review.md`

- [ ] **Step 1: Write `docs/review.md`**: what a review is here, the loop (open a scope with `gd`, `c`, `<CR>`, more scopes, `gs` or `<C-CR>`), what Claude receives (the example), where comments are kept, then **How it compares** (dated 2026-11-15): a table with columns Agent-IDE, tuicr, hunk, lumen, `gh pr review`, `git diff` and rows: diff viewer in a TUI / in Neovim; write comments inline; Vim keys; the review goes to the agent without copy-paste; agent-ready markdown export (Agent-IDE: the prompt text, or the clipboard); push a review to a forge (Agent-IDE: no); git / jj / hg (Agent-IDE: git only); single binary (Agent-IDE: no, a Neovim plugin). Fill the other columns only from each tool's README (`WebFetch` the three repositories; a cell you cannot verify reads `?`), and say so under the table. One paragraph on what only an editor-resident review gives: the diff, the transcript, the prompt and the queue are buffers in one tab with the keys already known.

- [ ] **Step 2: Update README, CHANGELOG, AGENTS.md** as listed. Keep the README's tone and the key tables' format.

- [ ] **Step 3: Verify**: `make test` green; `grep -n "AgentsReview\|review (n)" README.md` finds the new text; `git diff --stat` shows only the four files.

- [ ] **Step 4: Commit**

```bash
git add README.md CHANGELOG.md AGENTS.md docs/review.md
git commit -m "docs: review comments in the full diff; docs/review.md with a comparison"
```

---

## Self-review notes

- Spec coverage: store (1), text (2), anchoring and display (3), keys, editor, winbar, lost lines (4), session question, done dialog, clipboard, drawer row, command, dead session (5), direct send with every gate (6), docs and comparison (7). The spec's `AgentIdeReview*` groups are in Task 3; `keys.review` in Task 4; the `Repository:` line in Task 2; cross-showing head/branch in Task 1's `matches` and Task 4's UI test.
- Names used across tasks: `review.list/add/update/remove/clear/count/session/set_session/kind_of/matches/file`, `review_text.build/heading/reference/DEFAULT_INTRO`, `review_marks.anchor/lines/place/group_of`, `review_edit.open/state`, `review_send.candidates/ask_session/valid_session/ensure_session/target_name/text/done/send_now`, `chat.send_text/ensure`, `fulldiff.scope_of/redraw_marks`, `ask_select.select`.

-- Review comments: the per-work-tree store (review.lua), the text sent to Claude
-- (review_text.lua) and the anchoring of comments on a render (ui/review_marks.lua), all
-- without a window. Synthetic roots in a temporary folder; the runner's temporary state dir.
local eq = MiniTest.expect.equality
local review = require('agent-ide.review')
local text = require('agent-ide.review_text')
local marks = require('agent-ide.ui.review_marks')

local tmp, root, notes

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    tmp = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    tmp = vim.uv.fs_realpath(tmp)
    root = tmp .. '/repo'
    vim.fn.mkdir(root, 'p')
    vim.fn.delete(vim.fn.stdpath('state') .. '/agent-ide/reviews', 'rf')
    review._reset()
    notes = {}
    vim.notify = function(msg) notes[#notes + 1] = msg end
  end,
  post_case = function()
    review._reset()
    vim.fn.delete(tmp, 'rf')
  end,
} })

-- The store ---------------------------------------------------------------------------------------

T['kind_of: a known kind up to a colon, any case; else NOTE with the whole text'] = function()
  eq({ review.kind_of('BUG: swallows the error') }, { 'BUG', 'swallows the error' })
  eq({ review.kind_of('bug:   trailing  ') }, { 'BUG', 'trailing' })
  eq({ review.kind_of('Bug - no colon') }, { 'NOTE', 'Bug - no colon' })
  eq({ review.kind_of('nit: x', { { 'NIT', 'small' } }) }, { 'NIT', 'x' })
  eq({ review.kind_of('NOTE:') }, { 'NOTE', '' })
  eq({ review.kind_of('BUG: first line\nsecond') }, { 'BUG', 'first line\nsecond' })
end

T['add, list, update, remove, clear, count; ids grow; the file round-trips'] = function()
  local c = review.add(root, { kind = 'BUG', text = 'x', scope = { kind = 'head', hash = 'abc1234' }, path = 'a.lua',
    side = 'new', line = 3, code = 'local a' })
  eq({ c.id, c.at ~= nil }, { 1, true })
  review.add(root, { kind = 'NOTE', text = 'y', scope = { kind = 'commit', hash = 'deadbeef', short = 'deadbee', subject = 's' },
    path = 'b.lua' })
  eq(#review.list(root), 2)
  eq(review.count(root), 2)
  review._reset() -- read again from disk
  eq(review.list(root)[2].scope.subject, 's')
  eq(review.list(root)[1].code, 'local a')
  eq(review.update(root, 1, { text = 'z' }), true)
  eq(review.list(root)[1].text, 'z')
  eq(review.update(root, 9, { text = 'z' }), false)
  eq(review.remove(root, 2).text, 'y')
  eq(review.remove(root, 2), nil)
  review.clear(root, { 1 })
  eq(review.count(root), 0)
  eq(review.add(root, { kind = 'NOTE', text = 'n', scope = { kind = 'head' }, path = 'a' }).id, 3)
end

T['mark: in_prompt is kept on the comments named and round-trips'] = function()
  review.add(root, { kind = 'NOTE', text = 'a', scope = { kind = 'head' }, path = 'a' })
  review.add(root, { kind = 'NOTE', text = 'b', scope = { kind = 'head' }, path = 'b' })
  review.mark(root, { 1 }, { in_prompt = true })
  review._reset()
  eq({ review.list(root)[1].in_prompt, review.list(root)[2].in_prompt }, { true, nil })
  review.mark(root, { 1, 2 }, { in_prompt = false })
  eq({ review.list(root)[1].in_prompt, review.list(root)[2].in_prompt }, { nil, nil })
end

T['matches: kind and hash; head and branch see each other except old-side anchors'] = function()
  eq(review.matches({ scope = { kind = 'head' }, side = 'new' }, { kind = 'branch' }), true)
  eq(review.matches({ scope = { kind = 'head' }, side = 'old' }, { kind = 'branch' }), false)
  eq(review.matches({ scope = { kind = 'branch' } }, { kind = 'head' }), true) -- file-level
  eq(review.matches({ scope = { kind = 'commit', hash = 'a' } }, { kind = 'commit', hash = 'b' }), false)
  eq(review.matches({ scope = { kind = 'commit', hash = 'a' } }, { kind = 'commit', hash = 'a' }), true)
  eq(review.matches({ scope = { kind = 'commits' } }, { kind = 'commits' }), true)
  eq(review.matches({ scope = { kind = 'commits' } }, { kind = 'head' }), false)
  review.add(root, { kind = 'NOTE', text = 'a', scope = { kind = 'head' }, path = 'a', side = 'old', line = 1 })
  review.add(root, { kind = 'NOTE', text = 'b', scope = { kind = 'head' }, path = 'a', side = 'new', line = 1 })
  eq(#review.list(root, { kind = 'branch' }), 1)
  eq(#review.list(root, { kind = 'head' }), 2)
end

T['session is kept; a corrupt file reads as empty and notifies once'] = function()
  review.set_session(root, 'id-1')
  review._reset()
  eq(review.session(root), 'id-1')
  review.set_session(root, nil)
  eq(review.session(root), nil)
  vim.fn.writefile({ '{ not json' }, review.file(root))
  review._reset()
  eq(review.list(root), {})
  eq(review.count(root), 0)
  eq(#notes, 1)
  eq(notes[1]:find('starting empty', 1, true) ~= nil, true)
end

T['file: under state/agent-ide/reviews, named by folder and hash, mode 0600 in a 0700 folder'] = function()
  local path = review.file(root)
  local dir = vim.fn.stdpath('state') .. '/agent-ide/reviews'
  eq(vim.fs.dirname(path), dir)
  eq(vim.fs.basename(path), 'repo-' .. vim.fn.sha256(root):sub(1, 12) .. '.json')
  review.add(root, { kind = 'NOTE', text = 'a', scope = { kind = 'head' }, path = 'a' })
  eq(vim.uv.fs_stat(path).mode % 512, 384)
  eq(vim.uv.fs_stat(dir).mode % 512, 448)
  local data = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
  eq({ data.version, data.root, #data.comments }, { 1, root, 1 })
end

T['refresh: another writer\'s change is seen by stamp'] = function()
  review.add(root, { kind = 'NOTE', text = 'a', scope = { kind = 'head' }, path = 'a' })
  local path = review.file(root)
  local data = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
  data.comments[2] = { id = 2, kind = 'BUG', text = 'b', scope = { kind = 'head' }, path = 'b', at = 'x' }
  data.next_id = 3
  vim.fn.writefile({ vim.json.encode(data) }, path)
  vim.uv.fs_utime(path, os.time() + 5, os.time() + 5) -- a stamp that differs for sure
  eq(review.count(root), 2)
  eq(review.add(root, { kind = 'NOTE', text = 'c', scope = { kind = 'head' }, path = 'c' }).id, 3)
end

-- The text --------------------------------------------------------------------------------------

local OPTS = { project = 'myapp', root = '/r', kinds = review.DEFAULT_KINDS, intro = text.DEFAULT_INTRO }

T['build: the spec example, grouped by scope in first-appearance order, numbered through'] = function()
  local lines = text.build({
    { id = 1, kind = 'BUG', text = 'swallows the error, notify instead', scope = { kind = 'head', hash = '7f0f916' },
      path = 'lua/agent-ide/git.lua', side = 'new', line = 42, code = '  if not ok then return cb(nil) end' },
    { id = 2, kind = 'NOTE', text = 'this is fine, but move the guard above the pcall', scope = { kind = 'head', hash = '7f0f916' },
      path = 'lua/agent-ide/git.lua', side = 'new', line = 43, code = '  if not cb then return end' },
    { id = 3, kind = 'DESIGN', text = 'the screenshots belong under docs/images, not the root',
      scope = { kind = 'commit', hash = '60523ec0', short = '60523ec', subject = 'update images' }, path = 'README.md' },
  }, OPTS)
  eq(lines, {
    'I reviewed your changes and have the following comments. Please address them.', '',
    'Comment kinds: NOTE (an observation), BUG (wrong behaviour), DESIGN (structure or approach)', '',
    '## uncommitted changes (working tree against HEAD 7f0f916)', '',
    '1. **[BUG]** `lua/agent-ide/git.lua:42` — `  if not ok then return cb(nil) end`',
    '   swallows the error, notify instead',
    '2. **[NOTE]** `lua/agent-ide/git.lua:43` — `  if not cb then return end`',
    '   this is fine, but move the guard above the pcall', '',
    '## commit 60523ec (update images)', '',
    '3. **[DESIGN]** `README.md` (file)',
    '   the screenshots belong under docs/images, not the root' })
end

T['build: old side, multi-line text, the Repository line, an unknown kind, interleaved scopes'] = function()
  local lines = text.build({
    { id = 1, kind = 'NIT', text = 'one\ntwo', scope = { kind = 'commit', hash = 'aaaa', short = 'aaa', subject = 'first' },
      path = 'a.lua', side = 'old', line = 7, code = 'gone()' },
    { id = 2, kind = 'ISSUE', text = 'x', scope = { kind = 'head', hash = 'bbbbbbb' }, path = 'b.lua', side = 'new', line = 1, code = '' },
    { id = 3, kind = 'ISSUE', text = 'y', scope = { kind = 'commit', hash = 'aaaa', short = 'aaa', subject = 'first' }, path = 'c.lua' },
  }, vim.tbl_extend('force', OPTS, { cwd = '/r/sub' }))
  eq(lines, {
    'I reviewed your changes and have the following comments. Please address them.',
    'Repository: /r', '',
    'Comment kinds: ISSUE (a problem to fix), NIT', '',
    '## commit aaa (first)', '',
    '1. **[NIT]** `a.lua:7 (old line)` — `gone()`', '   one', '   two',
    '3. **[ISSUE]** `c.lua` (file)', '   y', '',
    '## uncommitted changes (working tree against HEAD bbbbbbb)', '',
    '2. **[ISSUE]** `b.lua:1`', '   x' })
end

T['heading: branch, commits on branch, recent commits, head without a hash'] = function()
  eq(text.heading({ kind = 'branch', base = 'main' }), 'branch vs main (uncommitted included)')
  eq(text.heading({ kind = 'commits', base = 'origin/main' }), 'commits on branch (origin/main..HEAD)')
  eq(text.heading({ kind = 'commits', base = 'HEAD' }), 'recent commits')
  eq(text.heading({ kind = 'commits' }), 'recent commits')
  eq(text.heading({ kind = 'head' }), 'uncommitted changes (working tree against HEAD)')
end

T['reference'] = function()
  eq(text.reference({ path = 'a b.lua', side = 'new', line = 3 }), '`a b.lua:3`')
  eq(text.reference({ path = 'a.lua', side = 'old', line = 3 }), '`a.lua:3 (old line)`')
  eq(text.reference({ path = 'a.lua' }), '`a.lua` (file)')
end

-- Anchors on a render ------------------------------------------------------------------------------

local function render_fixture()
  local render = require('agent-ide.ui.fulldiff_render')
  local files = {
    { status = 'M', path = 'lua/x.lua', added = 2, removed = 1, binary = false, submodule = false },
    { status = 'M', path = 'img.png', binary = true, submodule = false },
  }
  local blocks = { ['lua/x.lua'] = { lines = { '@@ -1,3 +1,4 @@', ' a', '-b', '+bb', '+c', ' d' } } }
  return render.build(files, blocks, { icons = { open = 'v', closed = '>' }, width = 60, fold_over = 500 })
end

T['anchor: header, @@, note and blank are file-level; +, -, context carry side, line and code'] = function()
  local t = render_fixture()
  eq(marks.anchor(t, 1), { path = 'lua/x.lua' })
  eq(marks.anchor(t, 2), { path = 'lua/x.lua' })
  eq(marks.anchor(t, 3), { path = 'lua/x.lua', side = 'new', line = 1, code = 'a' })
  eq(marks.anchor(t, 4), { path = 'lua/x.lua', side = 'old', line = 2, code = 'b' })
  eq(marks.anchor(t, 5), { path = 'lua/x.lua', side = 'new', line = 2, code = 'bb' })
  eq(marks.anchor(t, 8), { path = 'lua/x.lua' }) -- the blank line after the file
  eq(marks.anchor(t, 10), { path = 'img.png' }) -- the note
  eq(marks.anchor(t, 99), nil)
end

T['lines: anchors found, a lost line under the header with lost = true, a path not shown left out'] = function()
  local t = render_fixture()
  local m = marks.lines(t, {
    { id = 1, path = 'lua/x.lua', side = 'new', line = 2 },
    { id = 2, path = 'lua/x.lua', side = 'old', line = 2 },
    { id = 3, path = 'lua/x.lua' },
    { id = 4, path = 'lua/x.lua', side = 'new', line = 99 },
    { id = 5, path = 'gone.lua', side = 'new', line = 1 },
    { id = 6, path = 'img.png' },
  })
  eq(vim.tbl_map(function(e) return e.comment.id end, m[5]), { 1 })
  eq({ m[4][1].comment.id, m[4][1].lost }, { 2, false })
  eq(vim.tbl_map(function(e) return { e.comment.id, e.lost } end, m[1]), { { 3, false }, { 4, true } })
  eq(m[99], nil)
  eq(m[9][1].comment.id, 6)
  eq(vim.tbl_count(m), 4)
end

T['place: one virt_lines extmark per commented line, the kind in its group, a lost note'] = function()
  local t = render_fixture()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, t.lines)
  local map = marks.place(buf, t, {
    { id = 1, kind = 'BUG', text = 'one\ntwo', path = 'lua/x.lua', side = 'new', line = 2 },
    { id = 4, kind = 'NIT', text = 'gone', path = 'lua/x.lua', side = 'new', line = 99 },
  })
  eq(vim.tbl_count(map), 2)
  local ns = vim.api.nvim_create_namespace('agent-ide.review')
  local ext = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  eq(#ext, 2)
  eq(ext[1][2], 0) -- the header: the lost one
  eq(ext[1][4].virt_lines[1][2], { 'NIT  ', 'AgentIdeReviewKind' })
  eq(ext[1][4].virt_lines[1][3], { '(line 99 not in this diff)  ', 'AgentIdeDiffNote' })
  eq(ext[2][2], 4)
  local v = ext[2][4].virt_lines
  eq(#v, 2)
  eq(v[1], { { '  ┃ ', 'AgentIdeReviewBar' }, { 'BUG  ', 'AgentIdeReviewBug' }, { 'one', 'AgentIdeReviewText' } })
  eq(v[2], { { '  ┃      ', 'AgentIdeReviewBar' }, { 'two', 'AgentIdeReviewText' } })
  eq(ext[2][4].virt_lines_above, false)
  marks.place(buf, t, {})
  eq(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), 0)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T['group_of'] = function()
  eq(marks.group_of('BUG'), 'AgentIdeReviewBug')
  eq(marks.group_of('SUGGESTION'), 'AgentIdeReviewSuggestion')
  eq(marks.group_of('NIT'), 'AgentIdeReviewKind')
end

return T

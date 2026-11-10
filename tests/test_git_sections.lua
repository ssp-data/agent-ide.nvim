-- Git cache and the git drawer provider (rows from cached data; loads against real repos).
local R = dofile(vim.fn.getcwd() .. '/tests/git_repo.lua')
local cache = require('agent-ide.git_cache')
local gs = require('agent-ide.ui.git_sections')
local tree = require('agent-ide.ui.tree')
local eq = MiniTest.expect.equality

local icons = { open = 'v', closed = '>', project = 'P', waiting = 'W', busy = 'B', idle = 'I', parked = '.',
  done = 'D', failed = 'F', new = '+' }
local function parked() return 'parked' end
local tmp
local saved = {}

local T = MiniTest.new_set({ hooks = {
  pre_once = function()
    for k, v in pairs(R.ENV) do
      saved[k] = vim.env[k] or false
      vim.uv.os_setenv(k, v)
    end
  end,
  post_once = function()
    for k, v in pairs(saved) do
      if v then vim.uv.os_setenv(k, v) else vim.uv.os_unsetenv(k) end
    end
  end,
  pre_case = function()
    tmp = R.tmp()
    cache._reset()
  end,
  post_case = function()
    cache._reset()
    vim.fn.delete(tmp, 'rf')
  end,
} })

local function project(root, extra)
  return vim.tbl_extend('force', { key = root, root = root, name = 'p', is_git = true, missing = false, activity = 0,
    sessions = {} }, extra or {})
end

local BRANCH = { branch = 'feat', detached = false, head = 'h1', default_ref = 'origin/main', default_name = 'main',
  ref = 'origin/main', on_default = false, merge_base = 'mb', mode = 'branch', rev = 'mb', label = 'origin/main' }

local function lines(p, expanded)
  return tree.build({ p }, parked, expanded, 0, icons, nil, nil, gs.rows).lines
end

T['collapsed project: branch suffix only off the default branch'] = function()
  local p = project('/x/r')
  cache._set('/x/r', 'head', BRANCH)
  eq(lines(p, {}), { '> p  feat  . now' })
  cache._set('/x/r', 'head', vim.tbl_extend('force', BRANCH, { branch = 'main', on_default = true }))
  eq(lines(p, {}), { '> p  . now' })
  cache._set('/x/r', 'head', vim.tbl_extend('force', BRANCH, { branch = 'abc1234', detached = true }))
  eq(lines(p, {}), { '> p  abc1234  . now' })
end

T['non-git and missing projects show no git rows'] = function()
  eq(lines(project('/x/n', { is_git = false, root = nil }), { ['/x/n'] = true }), { 'v p  . now', '    + New session', '  v Sessions (0)' })
  eq(#lines(project('/x/m', { missing = true }), { ['/x/m'] = true }), 3)
end

T['expanded project: section labels with counts, collapsed by default; loading rows'] = function()
  local p = project('/x/r')
  cache._set('/x/r', 'head', BRANCH)
  cache._set('/x/r', 'base', BRANCH)
  local l = lines(p, { ['/x/r'] = true })
  eq(vim.list_slice(l, 4), { '  > Changes vs origin/main', '  > Commits on branch' })
  l = lines(p, { ['/x/r'] = true, ['/x/r/git/changes'] = true, ['/x/r/git/commits'] = true })
  eq(vim.list_slice(l, 4), { '  v Changes vs origin/main', '      loading…', '  v Commits on branch', '      loading…' })
  cache._set('/x/r', 'changes', {
    { status = 'M', path = 'a b.lua', added = 3, removed = 1 },
    { status = 'R', path = 'new.lua', old_path = 'old.lua', added = 0, removed = 0 },
    { status = 'A', path = 'img.png', binary = true },
    { status = 'M', path = 'sub', submodule = true },
    { status = '?', path = 'ü.txt', added = 2, removed = 0, untracked = true },
    { status = '?', path = 'nested/', untracked = true, dir = true },
  })
  cache._set('/x/r', 'commits', { { hash = 'aaaa', short = 'aaaa', subject = 'two', date = 0, files = 2 } })
  l = lines(p, { ['/x/r'] = true, ['/x/r/git/changes'] = true, ['/x/r/git/commits'] = true })
  eq(vim.list_slice(l, 4), {
    '  v Changes vs origin/main (6)',
    '      M a b.lua  +3 −1',
    '      R old.lua → new.lua  +0 −0',
    '      A img.png  bin',
    '      M sub  submodule',
    '      ? ü.txt  +2',
    '      ? nested/  dir',
    '  v Commits on branch (1)',
    '      > aaaa two  now',
  })
end

T['at the drawer width: stats and commit ages right-aligned, long paths cut, a side of 0 left out'] = function()
  local p = project('/x/r')
  cache._set('/x/r', 'head', BRANCH)
  cache._set('/x/r', 'base', BRANCH)
  cache._set('/x/r', 'changes', {
    { status = 'M', path = 'imap/client.go', added = 18, removed = 3 },
    { status = 'D', path = 'imap/poll_legacy.go', added = 0, removed = 41 },
    { status = 'A', path = 'a/very/long/path/to/some/deeply/nested/file.go', added = 74, removed = 0 },
  })
  cache._set('/x/r', 'commits', { { hash = 'a1b2c3d', short = 'a1b2c3d', subject = 'feat: IMAP IDLE loop', date = -480, files = 2 } })
  local t = tree.build({ p }, parked, { ['/x/r'] = true, ['/x/r/git/changes'] = true, ['/x/r/git/commits'] = true }, 0, icons,
    nil, nil, gs.rows, { width = 40 })
  eq(vim.list_slice(t.lines, 5, 9), {
    '      M imap/client.go            +18 −3',
    '      D imap/poll_legacy.go          −41',
    '      A a/very/long/path/to/some/d…  +74',
    '  v Commits on branch (1)',
    '      > a1b2c3d feat: IMAP IDLE loop  8m',
  })
  for _, i in ipairs({ 5, 6, 7, 9 }) do eq(vim.fn.strdisplaywidth(t.lines[i]), 40) end
  local groups = {}
  for _, h in ipairs(t.hl) do
    if h.line == 5 or h.line == 6 then groups[#groups + 1] = t.lines[h.line]:sub(h.col_start + 1, h.col_end) .. '=' .. h.group end
  end
  eq(groups, { 'M=AgentIdeGitModified', '+18=AgentIdeGitAdd', '−3=AgentIdeGitDel', 'D=AgentIdeGitDeleted', '−41=AgentIdeGitDel' })
end

T['an untracked folder (nested repository) is listed but cannot be opened'] = function()
  local p = project('/x/r')
  cache._set('/x/r', 'head', BRANCH)
  cache._set('/x/r', 'base', BRANCH)
  cache._set('/x/r', 'changes', { { status = '?', path = 'nested/', untracked = true, dir = true },
    { status = 'M', path = 'f', added = 1, removed = 0 } })
  local t = tree.build({ p }, parked, { ['/x/r'] = true, ['/x/r/git/changes'] = true }, 0, icons, nil, nil, gs.rows)
  eq({ t.lines[5], t.nodes[5].open, type(t.nodes[6].open) }, { '      ? nested/  dir', nil, 'function' })
end

T['default branch labels and recent commits'] = function()
  local p = project('/x/r')
  local b = vim.tbl_extend('force', BRANCH, { branch = 'main', on_default = true, mode = 'recent', label = 'HEAD' })
  cache._set('/x/r', 'head', b)
  cache._set('/x/r', 'base', b)
  cache._set('/x/r', 'changes', {})
  cache._set('/x/r', 'commits', {})
  eq(vim.list_slice(lines(p, { ['/x/r'] = true }), 4), { '  > Changes vs HEAD (0)', '  > Recent commits (0)' })
end

T['commit expands to its files; nodes carry ids, folds and open handlers'] = function()
  local p = project('/x/r')
  cache._set('/x/r', 'head', BRANCH)
  cache._set('/x/r', 'base', BRANCH)
  cache._set('/x/r', 'commits', { { hash = 'aaaa', short = 'aaaa', subject = 'two', date = 0, files = 1 } })
  local exp = { ['/x/r'] = true, ['/x/r/git/commits'] = true, ['/x/r/git/commit/aaaa'] = true }
  local t = tree.build({ p }, parked, exp, 0, icons, nil, nil, gs.rows)
  eq(t.lines[7], '          loading…')
  cache._set('/x/r', 'files:aaaa', { { status = 'M', path = 'f.lua', added = 1, removed = 0 } })
  t = tree.build({ p }, parked, exp, 0, icons, nil, nil, gs.rows)
  eq(t.lines[6], '      v aaaa two  now')
  eq(t.lines[7], '          M f.lua  +1')
  local commit, file = t.nodes[6], t.nodes[7]
  eq({ commit.fold.key, commit.fold.default, commit.id ~= file.id, type(file.open), file.fold.focus }, {
    '/x/r/git/commit/aaaa', false, true, 'function', commit.id })
end

T['at most 500 files are listed, then a line with the rest'] = function()
  local p = project('/x/r')
  cache._set('/x/r', 'head', BRANCH)
  cache._set('/x/r', 'base', BRANCH)
  local files = {}
  for i = 1, 620 do files[i] = { status = 'A', path = ('f%03d'):format(i), added = 1, removed = 0 } end
  cache._set('/x/r', 'changes', files)
  local l = lines(p, { ['/x/r'] = true, ['/x/r/git/changes'] = true })
  eq(l[4], '  v Changes vs origin/main (620)')
  eq(l[4 + 500], '      A f500  +1')
  eq(l[4 + 501], '      … 120 more')
end

T['loads from a real repository; invalidate keeps old data until the new arrives'] = function()
  local d = R.init(tmp .. '/r')
  R.write(d, 'a', 'a\n')
  R.commit(d, 'init')
  R.git(d, { 'checkout', '-q', '-b', 'feat' })
  R.write(d, 'b', 'b\n')
  R.commit(d, 'b')
  local updates = 0
  local function on(root) if root == d then updates = updates + 1 end end
  cache.on_update(on)
  eq(cache.changes(d), nil)
  vim.wait(3000, function() return cache.changes(d) ~= nil and cache.commits(d) ~= nil end, 10)
  eq(#cache.changes(d), 1)
  eq(#cache.commits(d), 1)
  eq(cache.head(d).branch, 'feat')
  R.write(d, 'c', 'c\n')
  cache.invalidate(d)
  eq(#cache.changes(d), 1) -- old data stays visible
  vim.wait(3000, function() return #cache.changes(d) == 2 end, 10)
  eq(#cache.changes(d), 2)
  eq(updates > 0, true)
  cache.off_update(on)
end

T['a result for an older generation is dropped'] = function()
  local d = R.init(tmp .. '/r')
  R.write(d, 'a', 'a\n')
  R.commit(d, 'init')
  cache.changes(d) -- starts a load
  cache._set(d, 'changes', { { status = 'M', path = 'manual' } }) -- bumps the generation
  vim.wait(300)
  eq(cache.changes(d)[1].path, 'manual')
end

T['check invalidates only when the status snapshot changed and 5 s passed'] = function()
  local d = R.init(tmp .. '/r')
  R.write(d, 'a', 'a\n')
  R.commit(d, 'init')
  cache.changes(d)
  vim.wait(3000, function() return cache.changes(d) ~= nil and cache.peek(d).sig ~= nil end, 10)
  local gen = cache.peek(d).gen
  cache.check(d)
  vim.wait(200)
  eq(cache.peek(d).gen, gen) -- too soon
  cache.peek(d).checked = 0
  cache.check(d)
  vim.wait(300)
  eq(cache.peek(d).gen, gen) -- nothing changed
  R.write(d, 'new', 'n\n')
  cache.peek(d).checked = 0
  cache.check(d)
  vim.wait(3000, function() return cache.peek(d).gen ~= gen end, 10)
  eq(cache.peek(d).gen ~= gen, true)
  vim.wait(3000, function() return #cache.changes(d) == 1 end, 10)
  eq(cache.changes(d)[1].path, 'new')
end

T['invalidate between when() and the git answer still answers'] = function()
  local d = R.init(tmp .. '/r')
  R.write(d, 'a', 'a\n')
  R.commit(d, 'init')
  R.git(d, { 'checkout', '-q', '-b', 'feat' })
  R.write(d, 'b', 'b\n')
  local hash = R.commit(d, 'b')
  local got, files
  cache.when(d, 'changes', function(v) got = v end)
  cache.when(d, 'files:' .. hash, function(v) files = v end)
  cache.invalidate(d) -- the loads above are still running
  vim.wait(3000, function() return got ~= nil and files ~= nil end, 10)
  eq({ got and #got, files and #files }, { 1, 1 })
  local b
  cache._reset()
  cache.when(d, 'base', function(v) b = v end)
  cache.invalidate(d)
  vim.wait(3000, function() return b ~= nil end, 10)
  eq(b.branch, 'feat')
end

T['check also covers repositories with only the branch loaded'] = function()
  local d = R.init(tmp .. '/r')
  R.write(d, 'a', 'a\n')
  R.commit(d, 'init')
  R.git(d, { 'checkout', '-q', '-b', 'one' })
  cache.head(d)
  vim.wait(3000, function() return cache.head(d) ~= nil end, 10)
  vim.wait(3000, function() return cache.peek(d).sig ~= nil end, 10)
  R.git(d, { 'checkout', '-q', '-b', 'two' })
  cache.peek(d).checked = 0
  cache.check(d)
  vim.wait(3000, function() return cache.head(d).branch == 'two' end, 10)
  eq(cache.head(d).branch, 'two')
end

return T

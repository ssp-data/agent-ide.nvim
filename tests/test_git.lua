-- Git data layer against temporary repositories.
local R = dofile(vim.fn.getcwd() .. '/tests/git_repo.lua')
local git = require('agent-ide.git')
local eq = MiniTest.expect.equality

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
  pre_case = function() tmp = R.tmp() end,
  post_case = function() vim.fn.delete(tmp, 'rf') end,
} })

local function by_path(files)
  local m = {}
  for _, f in ipairs(files) do m[f.path] = f end
  return m
end

-- main: a.txt, del.txt, ren.txt, 'sp ace.txt'; feat: two commits changing all of them.
local function feature_repo()
  local d = R.init(tmp .. '/r')
  R.write(d, 'a.txt', { 'a', 'b' })
  R.write(d, 'del.txt', { 'x' })
  R.write(d, 'ren.txt', { 'r1', 'r2', 'r3', 'r4' })
  R.write(d, 'sp ace.txt', { 'old' })
  local first = R.commit(d, 'init')
  R.git(d, { 'checkout', '-q', '-b', 'feat' })
  R.write(d, 'a.txt', { 'a', 'B', 'c' })
  R.git(d, { 'mv', 'ren.txt', 'ren2.txt' })
  R.commit(d, 'feat one')
  R.git(d, { 'rm', '-q', 'del.txt' })
  R.write(d, 'bin.dat', 'a\0b\1')
  R.write(d, 'ünï cödé.txt', { 'ü' })
  R.commit(d, 'feat two')
  return d, first
end

T['base: main without remote, merge-base, branch'] = function()
  local d, first = feature_repo()
  local b = R.await(function(cb) git.base(d, cb) end)
  eq({ b.ref, b.merge_base, b.branch, b.detached, b.on_default, b.mode, b.label }, { 'main', first, 'feat', false, false, 'branch', 'main' })
end

T['base: origin/HEAD target wins over main'] = function()
  local d, first = feature_repo()
  R.git(d, { 'update-ref', 'refs/remotes/origin/trunk', first })
  R.git(d, { 'symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/trunk' })
  local b = R.await(function(cb) git.base(d, cb) end)
  eq({ b.ref, b.merge_base, b.default_name }, { 'origin/trunk', first, 'trunk' })
end

T['base: master, and no default branch at all'] = function()
  local d = R.init(tmp .. '/m', 'master')
  R.write(d, 'f', 'x\n')
  R.commit(d, 'c')
  R.git(d, { 'checkout', '-q', '-b', 'topic' })
  eq(R.await(function(cb) git.base(d, cb) end).ref, 'master')
  local e = R.init(tmp .. '/t', 'trunk')
  R.write(e, 'f', 'x\n')
  R.commit(e, 'c')
  local b = R.await(function(cb) git.base(e, cb) end)
  eq({ b.ref, b.merge_base, b.mode, b.label }, { nil, nil, 'recent', 'HEAD' })
end

T['base: on the default branch compares with HEAD'] = function()
  local d = R.init(tmp .. '/r')
  R.write(d, 'f', 'x\n')
  local head = R.commit(d, 'c')
  local b = R.await(function(cb) git.base(d, cb) end)
  eq({ b.on_default, b.mode, b.rev, b.label }, { true, 'recent', head, 'HEAD' })
end

T['base: detached HEAD'] = function()
  local d = feature_repo()
  local head = vim.trim(R.git(d, { 'rev-parse', 'HEAD' }))
  R.git(d, { 'checkout', '-q', '--detach' })
  local b = R.await(function(cb) git.base(d, cb) end)
  eq({ b.detached, b.branch, b.mode }, { true, head:sub(1, #b.branch), 'branch' })
  eq(R.await(function(cb) git.branch(d, cb) end), b.branch)
end

T['base: no merge-base (unrelated history)'] = function()
  local d = feature_repo()
  R.git(d, { 'checkout', '-q', '--orphan', 'island' })
  R.git(d, { 'rm', '-rfq', '.' })
  R.write(d, 'i.txt', 'i\n')
  R.commit(d, 'island')
  local b = R.await(function(cb) git.base(d, cb) end)
  eq({ b.ref, b.merge_base, b.mode, b.label }, { 'main', nil, 'recent', 'HEAD' })
end

T['changes: renames, deletes, binary, spaces, non-ASCII, uncommitted, untracked'] = function()
  local d = feature_repo()
  R.write(d, 'sp ace.txt', { 'old', 'new' }) -- uncommitted change
  R.write(d, 'new dir/ünt racked.txt', { '1', '2', '3' })
  R.write(d, 'untracked.bin', 'x\0y')
  local files = R.await(function(cb) git.changes(d, cb) end)
  local m = by_path(files)
  eq({ m['a.txt'].status, m['a.txt'].added, m['a.txt'].removed }, { 'M', 2, 1 })
  eq({ m['ren2.txt'].status, m['ren2.txt'].old_path, m['ren2.txt'].added }, { 'R', 'ren.txt', 0 })
  eq({ m['del.txt'].status, m['del.txt'].removed }, { 'D', 1 })
  eq({ m['bin.dat'].status, m['bin.dat'].binary }, { 'A', true })
  eq({ m['ünï cödé.txt'].status, m['ünï cödé.txt'].added }, { 'A', 1 })
  eq({ m['sp ace.txt'].status, m['sp ace.txt'].added }, { 'M', 1 })
  eq({ m['new dir/ünt racked.txt'].status, m['new dir/ünt racked.txt'].added, m['new dir/ünt racked.txt'].untracked },
    { '?', 3, true })
  eq(m['untracked.bin'].binary, true)
  eq(#files, 8)
end

T['changes: on the default branch only uncommitted against HEAD'] = function()
  local d = R.init(tmp .. '/r')
  R.write(d, 'f', 'x\n')
  R.write(d, 'g', 'x\n')
  R.commit(d, 'c')
  eq(R.await(function(cb) git.changes(d, cb) end), {})
  R.write(d, 'f', 'y\n')
  local files = R.await(function(cb) git.changes(d, cb) end)
  eq(#files, 1)
  eq({ files[1].path, files[1].status, files[1].added, files[1].removed }, { 'f', 'M', 1, 1 })
end

T['changes and commits: repository without commits'] = function()
  local d = R.init(tmp .. '/r')
  R.write(d, 'staged.txt', 'a\n')
  R.git(d, { 'add', 'staged.txt' })
  R.write(d, 'loose.txt', 'b\n')
  local b = R.await(function(cb) git.base(d, cb) end)
  eq({ b.head, b.merge_base, b.branch, b.mode }, { nil, nil, 'main', 'recent' })
  local m = by_path(R.await(function(cb) git.changes(d, cb) end))
  eq({ m['staged.txt'].status, m['loose.txt'].status }, { 'A', '?' })
  eq(R.await(function(cb) git.commits(d, cb) end), {})
  eq(R.await(function(cb) git.branch(d, cb) end), 'main')
end

T['commits: branch commits newest first with files count; recent on default'] = function()
  local d = feature_repo()
  local cs = R.await(function(cb) git.commits(d, cb) end)
  eq(vim.tbl_map(function(c) return c.subject end, cs), { 'feat two', 'feat one' })
  eq({ cs[1].files, cs[2].files, #cs[1].short >= 7, cs[1].date > 0 }, { 3, 2, true, true })
  R.git(d, { 'checkout', '-q', 'main' })
  for i = 1, 22 do
    R.write(d, 'n.txt', tostring(i) .. '\n')
    R.commit(d, 'n' .. i)
  end
  cs = R.await(function(cb) git.commits(d, cb) end)
  eq({ #cs, cs[1].subject }, { 20, 'n22' })
end

T['commits: a merge commit counts files against its first parent'] = function()
  local d = feature_repo()
  R.git(d, { 'checkout', '-q', 'main' })
  R.write(d, 'm.txt', 'm\n')
  R.commit(d, 'main moves')
  R.git(d, { 'checkout', '-q', 'feat' })
  R.git(d, { 'merge', '-q', '--no-edit', 'main' })
  local cs = R.await(function(cb) git.commits(d, cb) end)
  eq({ cs[1].subject:match('^Merge') ~= nil, cs[1].files }, { true, 1 })
  local files = R.await(function(cb) git.commit_files(d, cs[1].hash, cb) end)
  eq(vim.tbl_map(function(f) return f.path end, files), { 'm.txt' })
  -- the merge-base moved: main's commit is not a branch change
  eq(by_path(R.await(function(cb) git.changes(d, cb) end))['m.txt'], nil)
end

T['commit_files: root commit, rename, binary'] = function()
  local d, first = feature_repo()
  local root_files = R.await(function(cb) git.commit_files(d, first, cb) end)
  eq(#root_files, 4)
  eq(by_path(root_files)['ren.txt'].status, 'A')
  local cs = R.await(function(cb) git.commits(d, cb) end)
  local m = by_path(R.await(function(cb) git.commit_files(d, cs[2].hash, cb) end))
  eq({ m['ren2.txt'].status, m['ren2.txt'].old_path, m['a.txt'].added }, { 'R', 'ren.txt', 2 })
  eq(by_path(R.await(function(cb) git.commit_files(d, cs[1].hash, cb) end))['bin.dat'].binary, true)
end

T['file_commits: commits of the branch touching a path, newest first'] = function()
  local d = feature_repo()
  R.write(d, 'a.txt', { 'again' })
  R.commit(d, 'feat three')
  local cs = R.await(function(cb) git.file_commits(d, 'a.txt', cb) end)
  eq(vim.tbl_map(function(c) return c.subject end, cs), { 'feat three', 'feat one' })
end

T['show: content at a revision, nil when missing'] = function()
  local d, first = feature_repo()
  eq(R.await(function(cb) git.show(d, first, 'sp ace.txt', cb) end), 'old\n')
  eq(R.await(function(cb) git.show(d, first, 'ünï cödé.txt', cb) end), nil)
  eq(R.await(function(cb) git.show(d, 'HEAD', 'bin.dat', cb) end), 'a\0b\1')
  eq(R.await(function(cb) git.show(d, nil, 'a.txt', cb) end), nil)
end

T['submodule: listed as one changed path, no descent'] = function()
  local sub = R.init(tmp .. '/sub')
  R.write(sub, 'inner.txt', 'i\n')
  R.commit(sub, 'inner')
  local d = feature_repo()
  R.git(d, { '-c', 'protocol.file.allow=always', 'submodule', 'add', '-q', sub, 'mod' })
  local m = by_path(R.await(function(cb) git.changes(d, cb) end))
  eq({ m.mod ~= nil, m.mod and m.mod.submodule, m['mod/inner.txt'] }, { true, true, nil })
end

T['large change list: every file is returned'] = function()
  local d = R.init(tmp .. '/r')
  R.write(d, 'seed', 's\n')
  R.commit(d, 'seed')
  R.git(d, { 'checkout', '-q', '-b', 'big' })
  for i = 1, 600 do R.write(d, ('f%03d.txt'):format(i), 'x\n') end
  R.commit(d, 'many')
  eq(#R.await(function(cb) git.changes(d, cb) end), 600)
end

T['never writes: no index.lock is created, a missing folder gives empty results'] = function()
  local d = feature_repo()
  R.write(d, 'a.txt', { 'dirty' })
  local idx = vim.uv.fs_stat(d .. '/.git/index').mtime
  R.await(function(cb) git.changes(d, cb) end)
  R.await(function(cb) git.signature(d, cb) end)
  eq(vim.uv.fs_stat(d .. '/.git/index').mtime, idx)
  eq(R.await(function(cb) git.changes(tmp .. '/nope', cb) end), {})
  eq(R.await(function(cb) git.base(tmp .. '/nope', cb) end), nil)
end

T['signature changes with the working tree'] = function()
  local d = feature_repo()
  local a = R.await(function(cb) git.signature(d, cb) end)
  eq(R.await(function(cb) git.signature(d, cb) end), a)
  R.write(d, 'zz.txt', 'z\n')
  eq(R.await(function(cb) git.signature(d, cb) end) ~= a, true)
end

return T

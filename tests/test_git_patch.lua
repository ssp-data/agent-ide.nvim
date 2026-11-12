-- The full diff's git queries (git_patch) against temporary repositories.
local R = dofile(vim.fn.getcwd() .. '/tests/git_repo.lua')
local patch = require('agent-ide.git_patch')
local cache = require('agent-ide.git_cache')
local eq = MiniTest.expect.equality

local tmp, repo
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
  post_case = function() vim.fn.delete(tmp, 'rf') end,
} })

-- main: a.txt, 'sp ace "q".txt'; feat: commit 1 modifies a.txt and renames the quoted file,
-- commit 2 adds img.png; then an uncommitted edit of a.txt and three untracked files.
local function feature_repo()
  repo = R.init(tmp .. '/r')
  R.write(repo, 'a.txt', { 'a' })
  R.write(repo, 'sp ace "q".txt', { '1', '2', '3', '4' })
  R.commit(repo, 'init')
  R.git(repo, { 'checkout', '-q', '-b', 'feat' })
  R.write(repo, 'a.txt', { 'a', 'aa' })
  vim.fn.mkdir(repo .. '/dir', 'p')
  R.git(repo, { 'mv', 'sp ace "q".txt', 'dir/sp ace "q".txt' })
  R.write(repo, 'dir/sp ace "q".txt', { '1', '2', '3', '5' })
  R.commit(repo, 'feat one')
  R.write(repo, 'img.png', '\137PNG\0\0')
  R.commit(repo, 'feat two')
  R.write(repo, 'a.txt', { 'a', 'aa', 'aaa' })
  R.write(repo, 'new.txt', { 'n1', 'n2' })
  R.write(repo, 'nul.bin', 'x\0y')
  R.write(repo, 'empty.txt', '')
  return repo
end

local function commits()
  return R.await(function(cb) require('agent-ide.git').commits(repo, cb) end)
end

local function paths(files) return vim.tbl_map(function(f) return f.path end, files) end

T['load branch: tracked hunks, rename joined by exact path, binary, untracked generated'] = function()
  feature_repo()
  local res = R.await(function(cb) patch.load(repo, { kind = 'branch' }, cb) end)
  eq(res.error, nil)
  eq(res.label, 'vs main')
  eq(paths(res.files), { 'a.txt', 'dir/sp ace "q".txt', 'img.png', 'empty.txt', 'new.txt', 'nul.bin' })
  eq(res.blocks['a.txt'].lines, { '@@ -1 +1,3 @@', ' a', '+aa', '+aaa' })
  eq(res.blocks['dir/sp ace "q".txt'].lines, { '@@ -1,4 +1,4 @@', ' 1', ' 2', ' 3', '-4', '+5' })
  eq(res.blocks['img.png'].binary, true)
  eq(res.blocks['new.txt'].lines, { '@@ -0,0 +1,2 @@', '+n1', '+n2' })
  eq(res.blocks['empty.txt'].lines, {})
  eq(res.blocks['nul.bin'].binary, true)
end

T['load commits: committed only; load commit: one commit; load head: uncommitted'] = function()
  feature_repo()
  local res = R.await(function(cb) patch.load(repo, { kind = 'commits' }, cb) end)
  eq(res.label, 'commits on branch')
  eq(res.blocks['a.txt'].lines, { '@@ -1 +1,2 @@', ' a', '+aa' })
  eq(res.blocks['new.txt'], nil)
  eq(paths(res.files), { 'a.txt', 'dir/sp ace "q".txt', 'img.png' })
  local c2 = commits()[1] -- newest
  res = R.await(function(cb) patch.load(repo, { kind = 'commit', commit = c2 }, cb) end)
  eq(res.label, c2.short .. ' ' .. c2.subject)
  eq(paths(res.files), { 'img.png' })
  res = R.await(function(cb) patch.load(repo, { kind = 'head' }, cb) end)
  eq(res.label, 'uncommitted')
  eq(res.blocks['a.txt'].lines, { '@@ -1,2 +1,3 @@', ' a', ' aa', '+aaa' })
  eq(res.blocks['new.txt'].lines, { '@@ -0,0 +1,2 @@', '+n1', '+n2' })
end

T['recent mode: commits scope covers the listed commits; root commit from the empty tree'] = function()
  feature_repo()
  R.git(repo, { 'checkout', '-q', '--force', 'main' })
  vim.fn.delete(repo .. '/new.txt')
  R.git(repo, { 'commit', '-q', '--allow-empty', '-m', 'main two' })
  cache._reset()
  local res = R.await(function(cb) patch.load(repo, { kind = 'commits' }, cb) end)
  eq(res.label, 'recent commits')
  eq(res.blocks['a.txt'].lines, { '@@ -0,0 +1 @@', '+a' })
  eq(paths(res.files), { 'a.txt', 'sp ace "q".txt' })
end

T['a large untracked file is noted, not read; an empty repository gives empty scopes'] = function()
  feature_repo()
  local fd = assert(vim.uv.fs_open(repo .. '/big.bin', 'w', 420))
  vim.uv.fs_ftruncate(fd, 2 * 1024 * 1024 + 1)
  vim.uv.fs_close(fd)
  local res = R.await(function(cb) patch.load(repo, { kind = 'head' }, cb) end)
  eq(res.blocks['big.bin'].note, 'not shown (larger than 2 MiB)')
  local empty = R.init(tmp .. '/e')
  for _, kind in ipairs({ 'branch', 'commits', 'head' }) do
    local r = R.await(function(cb) patch.load(empty, { kind = kind }, cb) end)
    eq({ kind, r.error, #r.files }, { kind, nil, 0 })
  end
  vim.fn.delete(repo .. '/big.bin')
end

T['cache.committed loads through the cache and is invalidated with it'] = function()
  feature_repo()
  local files = R.await(function(cb) cache.when(repo, 'committed', cb) end)
  eq(paths(files), { 'a.txt', 'dir/sp ace "q".txt', 'img.png' })
  eq(paths(cache.committed(repo)), paths(files))
  R.write(repo, 'c.txt', { 'c' })
  R.commit(repo, 'feat three')
  cache.invalidate(repo)
  files = R.await(function(cb)
    local function on(root, kind)
      if root == repo and kind == 'committed' then
        cache.off_update(on)
        cb(cache.committed(repo))
      end
    end
    cache.on_update(on)
  end)
  eq(paths(files), { 'a.txt', 'c.txt', 'dir/sp ace "q".txt', 'empty.txt', 'img.png', 'new.txt', 'nul.bin' }) -- R.commit adds all
end

return T

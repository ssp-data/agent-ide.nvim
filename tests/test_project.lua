local P = require('agent-ide.project')
local eq = MiniTest.expect.equality
local tmp

local function mk(p) vim.fn.mkdir(p, 'p') end

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    local d = vim.fn.tempname()
    mk(d)
    tmp = vim.uv.fs_realpath(d)
    mk(tmp .. '/repo/.git/worktrees/wt'); mk(tmp .. '/repo/sub/deep')
    mk(tmp .. '/wt'); mk(tmp .. '/plain')
    mk(tmp .. '/homefake/.git'); mk(tmp .. '/homefake/stuff')
    local f = io.open(tmp .. '/wt/.git', 'w')
    f:write('gitdir: ' .. tmp .. '/repo/.git/worktrees/wt\n'); f:close()
    mk(tmp .. '/repo/.git/worktrees/rel'); mk(tmp .. '/rel')
    f = io.open(tmp .. '/rel/.git', 'w')
    f:write('gitdir: ../repo/.git/worktrees/rel\n'); f:close()
  end,
  post_case = function() vim.fn.delete(tmp, 'rf') end,
} })

T['git_root: nested folder, worktree, plain, home rule, vanished folder'] = function()
  eq({ P.git_root(tmp .. '/repo/sub/deep', '/nohome') }, { tmp .. '/repo', true })
  eq({ P.git_root(tmp .. '/wt', '/nohome') }, { tmp .. '/repo', true })
  eq({ P.git_root(tmp .. '/rel', '/nohome') }, { tmp .. '/repo', true }) -- relative gitdir
  eq({ P.git_root(tmp .. '/plain', '/nohome') }, { nil, true })
  eq({ P.git_root(tmp .. '/homefake/stuff', tmp .. '/homefake') }, { nil, true })
  eq({ P.git_root(tmp .. '/homefake', tmp .. '/homefake') }, { tmp .. '/homefake', true })
  eq({ P.git_root(tmp .. '/repo/gone/dir', '/nohome') }, { tmp .. '/repo', false })
end

local function sample()
  return {
    { id = 'a', cwd = tmp .. '/repo', mtime = 10, title = 'A' },
    { id = 'b', cwd = tmp .. '/repo/sub/deep', mtime = 30, title = 'B' },
    { id = 'c', cwd = tmp .. '/wt', mtime = 20, title = 'C' },
    { id = 'd', cwd = tmp .. '/plain', mtime = 5, title = 'D' },
    { id = 'e', cwd = nil, path = '/x/projects/-nocwd/e.jsonl', mtime = 1, title = 'E' },
  }
end

T['group: sub-folders and worktrees fold into one project'] = function()
  local ps = P.group(sample(), { home = '/nohome' })
  eq(#ps, 3)
  eq({ ps[1].name, ps[1].is_git, ps[1].mtime, #ps[1].sessions }, { 'repo', true, 30, 3 })
  eq(vim.tbl_map(function(s) return s.id end, ps[1].sessions), { 'b', 'c', 'a' })
  eq(ps[1].sessions[1].subpath, 'sub/deep')
  eq({ ps[2].name, ps[2].is_git, ps[2].missing }, { 'plain', false, false })
  eq({ ps[3].name, ps[3].missing, ps[3].root, ps[3].is_git }, { '-nocwd', true, nil, false })
end

T['group: same basename gets parent prefix'] = function()
  local ps = P.group({ { id = 'a', cwd = '/x/one/app', mtime = 2 }, { id = 'b', cwd = '/x/two/app', mtime = 1 } },
    { root_of = function() return nil, true end })
  eq({ ps[1].name, ps[2].name }, { 'one/app', 'two/app' })
end

T['group: vanished plain folder is missing'] = function()
  local ps = P.group({ { id = 'a', cwd = tmp .. '/plain/gone', mtime = 1 } }, { home = '/nohome' })
  eq({ ps[1].missing, ps[1].is_git }, { true, false })
end

T['group: twice on the same input gives equal results'] = function()
  local input = sample()
  local snapshot = vim.deepcopy(input)
  local a = P.group(input, { home = '/nohome' })
  local b = P.group(input, { home = '/nohome' })
  eq(a, b)
  eq(input, snapshot)
end

T['group: relative-gitdir worktree joins its main repository'] = function()
  local ps = P.group({ { id = 'a', cwd = tmp .. '/repo', mtime = 1 }, { id = 'b', cwd = tmp .. '/rel', mtime = 2 } }, { home = '/nohome' })
  eq(#ps, 1)
  eq(ps[1].key, tmp .. '/repo')
end

T['group: ties are ordered by path and key, not by input order'] = function()
  local root_of = function() return nil, true end
  local s1 = { id = 'z', cwd = '/x/b', path = '/p/-b/z.jsonl', mtime = 5 }
  local s2 = { id = 'y', cwd = '/x/b', path = '/p/-b/y.jsonl', mtime = 5 }
  local s3 = { id = 'w', cwd = '/x/a', path = '/p/-a/w.jsonl', mtime = 5 }
  local s4 = { id = 'B', cwd = '/x/c', path = '/p/-c/B.jsonl', mtime = 5 }
  local s5 = { id = 'a', cwd = '/x/c', path = '/p/-c/a.jsonl', mtime = 5 }
  local one = P.group({ s1, s2, s3, s4, s5 }, { root_of = root_of })
  local two = P.group({ s5, s3, s4, s2, s1 }, { root_of = root_of })
  local function shape(ps)
    return vim.tbl_map(function(p) return { p.key, vim.tbl_map(function(s) return s.id end, p.sessions) } end, ps)
  end
  eq(shape(one), shape(two))
  -- byte order: upper case before lower case whatever the locale
  eq(shape(one), { { '/x/a', { 'w' } }, { '/x/b', { 'y', 'z' } }, { '/x/c', { 'B', 'a' } } })
end

return T

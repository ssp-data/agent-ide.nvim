-- Read-only git queries, all asynchronous: `git --no-optional-locks -C <root> ...` through
-- `vim.system` with callbacks (called on the main loop). Nothing here writes to a repository,
-- so a running agent or lazygit is never disturbed. Results come with `-z` where paths appear.
local parse = require('agent-ide.git_parse')

local M = {}

local RECENT = 20 -- commits shown on the default branch
local MAX_COMMITS = 1000
local MAX_COUNT_BYTES = 2 * 1024 * 1024 -- untracked files larger than this get no line count
local MAX_COUNTED = 500 -- untracked files whose lines are counted

-- Background queue: at most BG_MAX git processes at once for work nobody waits for.
local BG_MAX = 4
local bg_running, bg_queue = 0, {}

local function spawn(root, args, cb)
  local cmd = { 'git', '--no-optional-locks', '-C', root }
  vim.list_extend(cmd, args)
  local ok, err = pcall(vim.system, cmd, { text = false, env = { GIT_OPTIONAL_LOCKS = '0', GIT_TERMINAL_PROMPT = '0' } },
    function(r) vim.schedule(function() cb(r.code, r.stdout or '', r.stderr or '') end) end)
  if not ok then vim.schedule(function() cb(-1, '', tostring(err)) end) end
end

local function bg_next()
  while bg_running < BG_MAX and #bg_queue > 0 do
    local job = table.remove(bg_queue, 1)
    bg_running = bg_running + 1
    spawn(job[1], job[2], function(...)
      bg_running = bg_running - 1
      bg_next()
      job[3](...)
    end)
  end
end

---Run `git <args>` in `root`; `cb(code, stdout, stderr)` on the main loop.
---@param root string
---@param args string[]
---@param cb fun(code: integer, stdout: string, stderr: string)
---@param opts? { background?: boolean } background: queued behind at most 4 running jobs
function M.run(root, args, cb, opts)
  if opts and opts.background then
    bg_queue[#bg_queue + 1] = { root, args, cb }
    return bg_next()
  end
  spawn(root, args, cb)
end

-- Run several commands at once; `cb` gets one { code, out } per command, in order.
local function all(root, cmds, cb, opts)
  local res, left = {}, #cmds
  for i, args in ipairs(cmds) do
    M.run(root, args, function(code, out)
      res[i] = { code = code, out = out }
      left = left - 1
      if left == 0 then cb(res) end
    end, opts)
  end
end

---Current branch and the default branch, without the merge-base.
---@param root string
---@param cb fun(head: { branch: string|nil, detached: boolean, head: string|nil, default_ref: string|nil, default_name: string|nil }|nil)
---@param opts? { background?: boolean }
function M.head(root, cb, opts)
  all(root, {
    { 'for-each-ref', '--format=%(refname)%00%(symref)', 'refs/remotes/origin/HEAD', 'refs/heads/main', 'refs/heads/master' },
    { 'symbolic-ref', '-q', 'HEAD' },
    { 'rev-parse', '-q', '--verify', 'HEAD' },
  }, function(r)
    if r[1].code ~= 0 then return cb(nil) end -- not a repository
    local ref, name = parse.default_ref(r[1].out)
    local sha = r[3].code == 0 and parse.line(r[3].out) or nil
    local branch = r[2].code == 0 and parse.line(r[2].out):gsub('^refs/heads/', '') or nil
    local detached = branch == nil and sha ~= nil
    if detached then branch = sha:sub(1, 7) end
    cb({ branch = branch, detached = detached, head = sha, default_ref = ref, default_name = name })
  end, opts)
end

local function with_empty_tree(root, cb)
  M.run(root, { 'hash-object', '-t', 'tree', '/dev/null' }, function(code, out)
    cb(code == 0 and parse.line(out) or nil)
  end)
end

---The default branch and where the current branch left it.
---`mode = 'branch'`: changes since `merge_base`, commits `merge_base..HEAD`; `mode = 'recent'`
---(on the default branch, no default branch, no merge-base, no commits): uncommitted changes
---against HEAD and the last 20 commits. `rev` is what the working tree is compared with
---(the empty tree in a repository without commits); `label` names it for the drawer.
---@param root string
---@param cb fun(base: table|nil)
function M.base(root, cb)
  M.head(root, function(h)
    if not h then return cb(nil) end
    local b = vim.tbl_extend('force', h, { ref = h.default_ref, on_default = not h.detached and h.branch ~= nil
      and h.branch == h.default_name })
    local function finish(mb)
      b.merge_base = mb
      if mb and not b.on_default then
        b.mode, b.rev, b.label = 'branch', mb, b.ref
      else
        b.mode, b.rev, b.label = 'recent', h.head, 'HEAD'
      end
      if b.rev then return cb(b) end
      with_empty_tree(root, function(t)
        b.rev = t
        cb(b)
      end)
    end
    if not (h.head and b.ref) then return finish(nil) end
    M.run(root, { 'merge-base', b.ref, 'HEAD' }, function(code, out)
      finish(code == 0 and parse.line(out) or nil)
    end)
  end)
end

local function with_base(root, base, cb)
  if base then return cb(base) end
  M.base(root, cb)
end

-- Count lines of untracked files (async reads; binary when a NUL byte is found).
local function count_lines(root, files, cb)
  local left = 0
  for _, f in ipairs(files) do
    if left >= MAX_COUNTED then break end
    left = left + 1
    local path = root .. '/' .. f.path
    vim.uv.fs_open(path, 'r', 438, function(err, fd)
      local function done()
        left = left - 1
        if left == 0 then vim.schedule(cb) end
      end
      if err or not fd then return done() end
      vim.uv.fs_fstat(fd, function(_, st)
        if not st or st.type ~= 'file' or st.size > MAX_COUNT_BYTES then
          vim.uv.fs_close(fd)
          return done()
        end
        vim.uv.fs_read(fd, st.size, 0, function(_, data)
          vim.uv.fs_close(fd)
          data = data or ''
          if data:find('\0', 1, true) then
            f.binary = true
          else
            local _, n = data:gsub('\n', '')
            if #data > 0 and data:sub(-1) ~= '\n' then n = n + 1 end
            f.added, f.removed = n, 0
          end
          done()
        end)
      end)
    end)
  end
  if left == 0 then vim.schedule(cb) end
end

local DIFF = { '-z', '--no-ext-diff', '--no-textconv', '-M', '--raw', '--numstat' }

---Files changed between `base.rev` and the working tree, uncommitted and untracked included.
---@param root string
---@param cb fun(files: table[], base: table|nil)
---@param base? table from `M.base` (fetched when nil)
function M.changes(root, cb, base)
  with_base(root, base, function(b)
    if not b or not b.rev then return cb({}, b) end
    all(root, {
      vim.list_extend({ 'diff' }, vim.list_extend(vim.list_slice(DIFF), { b.rev, '--' })),
      { 'ls-files', '-z', '--others', '--exclude-standard' },
    }, function(r)
      local files = r[1].code == 0 and parse.raw_numstat(r[1].out) or {}
      local untracked = {}
      if r[2].code == 0 then
        for _, p in ipairs(parse.paths(r[2].out)) do
          local f = { status = '?', path = p, untracked = true, binary = false, submodule = false }
          files[#files + 1] = f
          untracked[#untracked + 1] = f
        end
      end
      count_lines(root, untracked, function() cb(files, b) end)
    end)
  end)
end

local LOG_FORMAT = '--format=%x1e%H%x1f%h%x1f%at%x1f%s'

local function log_range(b)
  if b.mode == 'branch' then return { '--max-count=' .. MAX_COMMITS, b.merge_base .. '..HEAD' } end
  return { '--max-count=' .. RECENT, 'HEAD' }
end

---Commits on the branch since the merge-base (newest first); the last 20 in 'recent' mode.
---@param root string
---@param cb fun(commits: table[], base: table|nil)
---@param base? table
function M.commits(root, cb, base)
  with_base(root, base, function(b)
    if not b or not b.head then return cb({}, b) end
    local args = { 'log', '--no-color', LOG_FORMAT, '--shortstat', '--diff-merges=first-parent' }
    M.run(root, vim.list_extend(args, log_range(b)), function(code, out)
      cb(code == 0 and parse.log(out) or {}, b)
    end)
  end)
end

---Commits of the branch (or the recent ones) that touch `path` (or `old_path`), newest first.
---@param root string
---@param path string
---@param cb fun(commits: table[])
---@param base? table
---@param old_path? string
function M.file_commits(root, path, cb, base, old_path)
  with_base(root, base, function(b)
    if not b or not b.head then return cb({}) end
    local range = b.mode == 'branch' and { b.merge_base .. '..HEAD' } or { '--max-count=' .. RECENT, 'HEAD' }
    local args = vim.list_extend({ 'log', '--no-color', LOG_FORMAT }, range)
    vim.list_extend(args, { '--', path, old_path })
    M.run(root, args, function(code, out) cb(code == 0 and parse.log(out) or {}) end)
  end)
end

---Files of one commit, against its first parent (a root commit against the empty tree).
---@param root string
---@param hash string
---@param cb fun(files: table[])
function M.commit_files(root, hash, cb)
  local args = { 'diff-tree', '-r', '--root', '--no-commit-id', '--diff-merges=first-parent' }
  vim.list_extend(args, vim.list_slice(DIFF))
  vim.list_extend(args, { hash, '--' })
  M.run(root, args, function(code, out) cb(code == 0 and parse.raw_numstat(out) or {}) end)
end

---Content of `path` at revision `rev` (exact bytes); nil when the file does not exist there
---(or `rev` is nil).
---@param root string
---@param rev string|nil
---@param path string relative to the repository root
---@param cb fun(content: string|nil)
function M.show(root, rev, path, cb)
  if not rev then return vim.schedule(function() cb(nil) end) end
  M.run(root, { 'cat-file', 'blob', rev .. ':' .. path }, function(code, out) cb(code == 0 and out or nil) end)
end

---Current branch name, or the short hash of a detached HEAD.
---@param root string
---@param cb fun(branch: string|nil)
function M.branch(root, cb)
  M.head(root, function(h) cb(h and h.branch) end)
end

---A cheap snapshot of HEAD and the working tree state (status level): equal snapshots mean
---nothing was committed, staged, added or removed in between.
---@param root string
---@param cb fun(sig: string|nil)
---@param opts? { background?: boolean }
function M.signature(root, cb, opts)
  M.run(root, { 'status', '--porcelain=v2', '--branch', '-z', '--untracked-files=normal', '--ignore-submodules=none' },
    function(code, out) cb(code == 0 and out or nil) end, opts)
end

return M

-- The full diff's git queries, read-only and asynchronous through git.run: the patch of a
-- scope (the branch against the working tree, its commits, one commit, or the uncommitted
-- changes) split into per-file blocks and joined with the scope's file list from git_cache.
-- Untracked files are read from disk (within git.read_limits) and shown as added lines.
local git = require('agent-ide.git')
local parse = require('agent-ide.git_parse')

local M = {}

local QUOTE = { '-c', 'core.quotePath=false' } -- only control characters and quotes get quoted
-- the prefixes are fixed on the command line: a user's diff.mnemonicPrefix (`c/` `w/`) or
-- diff.noprefix would otherwise change the `diff --git` lines the parser reads
local PATCH = { '--no-color', '--no-ext-diff', '--no-textconv', '--src-prefix=a/', '--dst-prefix=b/', '-M', '-U3' }
local LIST = { '-z', '--no-ext-diff', '--no-textconv', '-M', '--raw', '--numstat' }

M.NOTE_LARGE = 'not shown (larger than 2 MiB)'

local function cache() return require('agent-ide.git_cache') end

local function run(root, args, cb)
  local full = vim.list_extend(vim.list_slice(QUOTE), args)
  git.run(root, full, cb)
end

local function empty_tree(root, cb)
  git.run(root, { 'hash-object', '-t', 'tree', '/dev/null' }, function(code, out)
    cb(code == 0 and parse.line(out) or nil)
  end)
end

---The revision the commits scope starts from: the merge-base on a branch; in recent mode the
---parent of the oldest listed commit (a root commit: the empty tree). nil without commits.
---@param root string
---@param base table|nil from git.base
---@param cb fun(rev: string|nil)
function M.start(root, base, cb)
  if not base or not base.head then return cb(nil) end
  if base.mode == 'branch' then return cb(base.merge_base) end
  cache().when(root, 'commits', function(commits)
    if not commits or #commits == 0 then return cb(nil) end
    local oldest = commits[#commits].hash
    git.run(root, { 'rev-parse', '-q', '--verify', oldest .. '^{commit}' }, function(code, out)
      if code ~= 0 then return cb(nil) end
      git.run(root, { 'rev-parse', '-q', '--verify', oldest .. '^' }, function(c2, out2)
        if c2 == 0 then return cb(parse.line(out2)) end
        empty_tree(root, cb)
      end)
    end)
  end)
end

---Files changed between the commits scope's start and HEAD (the drawer's list shape).
---@param root string
---@param base table|nil
---@param cb fun(files: table[])
function M.committed(root, base, cb)
  M.start(root, base, function(from)
    if not from then return cb({}) end
    local args = vim.list_extend({ 'diff' }, vim.list_slice(LIST))
    vim.list_extend(args, { from, 'HEAD', '--' })
    git.run(root, args, function(code, out) cb(code == 0 and parse.raw_numstat(out) or {}) end)
  end)
end

-- Untracked files as blocks of added lines, read with the limits of git.count_lines (4 at a
-- time, 2 MiB per file, 16 MiB in total); a NUL byte makes the block binary.
local function read_untracked(root, files, cb)
  local lim = git.read_limits
  local blocks = {}
  local next_i, running, budget, finished = 1, 0, lim.total, false
  local function pump()
    while running < lim.parallel and next_i <= #files do
      local f = files[next_i]
      next_i = next_i + 1
      running = running + 1
      local function done(block)
        blocks[f.path] = block
        running = running - 1
        pump()
      end
      vim.uv.fs_open(root .. '/' .. f.path, 'r', 438, function(err, fd)
        if err or not fd then return done(nil) end
        vim.uv.fs_fstat(fd, function(_, st)
          if not st or st.type ~= 'file' or st.size > lim.file or st.size > budget then
            vim.uv.fs_close(fd)
            return done({ note = M.NOTE_LARGE })
          end
          budget = budget - st.size
          vim.uv.fs_read(fd, st.size, 0, function(_, data)
            vim.uv.fs_close(fd)
            data = data or ''
            if data:find('\0', 1, true) then return done({ binary = true }) end
            local lines = {}
            if data ~= '' then
              for l in data:gmatch('([^\n]*)\n') do lines[#lines + 1] = '+' .. l end
              local tail = data:match('[^\n]*$')
              if tail ~= '' then lines[#lines + 1] = '+' .. tail end
              table.insert(lines, 1, ('@@ -0,0 +1,%d @@'):format(#lines))
            end
            done({ lines = lines })
          end)
        end)
      end)
    end
    if running == 0 and next_i > #files and not finished then
      finished = true
      vim.schedule(function() cb(blocks) end)
    end
  end
  pump()
end

-- delta (https://github.com/dandavison/delta) colours the patch without changing its lines:
-- syntax colours, a background per changed line, the changed words stronger. Tabs and long
-- lines pass through as they are.
local DELTA_FLAGS = { '--color-only', '--paging=never', '--true-color=always', '--tabs=0', '--max-line-length=0' }

---The delta command the full diff pipes its patch through, per `git.delta`: 'auto' (the
---default) when `delta` is installed, a command list of your own as given, nil for false or
---without delta. The flags above and `--dark` / `--light` after Neovim's background follow.
---@return string[]|nil
function M.delta_cmd()
  local g = require('agent-ide.config').get().git
  local d = type(g) == 'table' and g.delta
  if d == nil then d = 'auto' end
  if d == false then return nil end
  local cmd
  if type(d) == 'table' then
    cmd = vim.list_slice(d)
  elseif vim.fn.executable('delta') == 1 then
    cmd = { 'delta' }
  else
    return nil
  end
  vim.list_extend(cmd, DELTA_FLAGS)
  cmd[#cmd + 1] = vim.o.background == 'light' and '--light' or '--dark'
  return cmd
end

M.DELTA_MAX_LINES = 20000 -- a longer patch keeps the plugin's own colours: delta's spans cost per line

-- `cb(colored)` with the patch `text` through delta, nil without delta, for a patch over
-- DELTA_MAX_LINES lines, or when delta failed.
local function colorize(text, cb)
  local cmd = M.delta_cmd()
  if not cmd or text == '' then return cb(nil) end
  local n, at = 0, 0
  while n <= M.DELTA_MAX_LINES do
    at = text:find('\n', at + 1, true)
    if not at then break end
    n = n + 1
  end
  if n > M.DELTA_MAX_LINES then return cb(nil) end
  local ok = pcall(vim.system, cmd, { stdin = text, text = false }, function(r)
    vim.schedule(function() cb(r.code == 0 and r.stdout ~= '' and r.stdout or nil) end)
  end)
  if not ok then cb(nil) end
end

-- Run the patch command, colour it, split it, add the untracked files of `files`, and answer.
local function patch(root, args, files, label, cb)
  run(root, args, function(code, out, err)
    local res = { files = files, blocks = {}, label = label }
    if code ~= 0 then
      res.error = parse.line(err) ~= '' and parse.line(err) or ('git failed (' .. code .. ')')
      return cb(res)
    end
    colorize(out, function(colored)
      res.colored = colored ~= nil
      for _, b in ipairs(parse.patch(colored or out)) do
        b.colored = res.colored
        res.blocks[b.path] = b
      end
      local untracked = vim.tbl_filter(function(f) return f.untracked and not f.dir end, files)
      if #untracked == 0 then return cb(res) end
      read_untracked(root, untracked, function(blocks)
        for path, b in pairs(blocks) do res.blocks[path] = b end
        cb(res)
      end)
    end)
  end)
end

local function diff_args(from, to)
  local args = vim.list_extend({ 'diff' }, vim.list_slice(PATCH))
  args[#args + 1] = from
  if to then args[#args + 1] = to end
  args[#args + 1] = '--'
  return args
end

local loaders = {}

function loaders.branch(root, _, cb)
  cache().when(root, 'base', function(b)
    local label = 'vs ' .. (b and b.label or 'HEAD')
    if not (b and b.rev) then return cb({ files = {}, blocks = {}, label = label }) end
    cache().when(root, 'changes', function(files) patch(root, diff_args(b.rev), files or {}, label, cb) end)
  end)
end

function loaders.commits(root, _, cb)
  cache().when(root, 'base', function(b)
    local label = (b and b.mode == 'branch') and 'commits on branch' or 'recent commits'
    M.start(root, b, function(from)
      if not from then return cb({ files = {}, blocks = {}, label = label }) end
      cache().when(root, 'committed', function(files) patch(root, diff_args(from, 'HEAD'), files or {}, label, cb) end)
    end)
  end)
end

function loaders.commit(root, scope, cb)
  local c = scope.commit
  local label = c.short .. ' ' .. (c.subject or '')
  local args = { 'diff-tree', '-p', '-r', '--root', '--no-commit-id', '--diff-merges=first-parent' }
  vim.list_extend(args, vim.list_slice(PATCH))
  vim.list_extend(args, { c.hash, '--' })
  cache().when(root, 'files:' .. c.hash, function(files) patch(root, args, files or {}, label, cb) end)
end

function loaders.head(root, _, cb)
  cache().when(root, 'base', function(b)
    local rev = b and (b.head and 'HEAD' or b.rev) -- a repository without a commit: the empty tree
    if not rev then return cb({ files = {}, blocks = {}, label = 'uncommitted' }) end
    cache().when(root, 'uncommitted', function(files) patch(root, diff_args(rev), files or {}, 'uncommitted', cb) end)
  end)
end

---Load the full diff of `scope` in `root`: `cb(res)` with the scope's file list (`files`), the
---blocks by path (`blocks`), the winbar label (`label`) and `error` when git failed.
---@param root string
---@param scope { kind: 'branch'|'commits'|'commit'|'head', commit?: { hash: string, short: string, subject: string } }
---@param cb fun(res: { files: table[], blocks: table<string, table>, label: string, error?: string })
function M.load(root, scope, cb)
  local loader = loaders[scope.kind]
  if not loader then error('unknown full diff scope: ' .. tostring(scope.kind)) end
  loader(root, scope, cb)
end

return M

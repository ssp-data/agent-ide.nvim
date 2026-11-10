-- Keys of the diff view (buffer-local on both sides), its help, and the flip between the whole
-- branch and one commit.
local cache = require('agent-ide.git_cache')
local config = require('agent-ide.config')
local git = require('agent-ide.git')
local scratch = require('agent-ide.ui.diff_buf')

local M = {}

local function notify(msg) vim.notify('Agent-IDE: ' .. msg, vim.log.levels.INFO) end

---`config.keys.diff` (name -> lhs or false).
function M.keys()
  local keys = config.get().keys
  return type(keys) == 'table' and type(keys.diff) == 'table' and keys.diff or {}
end

local function index_of(list, path)
  for i, f in ipairs(list) do
    if f.path == path then return i end
  end
end

---Show `path` of commit `c` (its files are the list for `]f`/`[f`).
function M.open_commit(view, d, c, path)
  cache.when(d.root, 'files:' .. c.hash, function(files)
    local i = index_of(files, path)
    if not i then return notify(path .. ' is not in ' .. c.short) end
    view.open({ project = d.project, root = d.root, mode = 'commit', list = files, index = i, commit = c })
  end)
end

---Back to the whole-branch diff of the current path.
function M.to_branch(view)
  local d = view.state()
  if not d or d.mode == 'branch' then return end
  local path = d.file.path
  cache.when(d.root, 'changes', function(list)
    local i = index_of(list or {}, path)
    if not i then return notify(path .. ' has no changes on the branch') end
    view.open({ project = d.project, root = d.root, mode = 'branch', list = list, index = i })
  end)
end

---Branch view: pick one of the commits that touched this path (newest first); commit view: back
---to the branch.
function M.flip(view)
  local d = view.state()
  if not d then return end
  if d.mode == 'commit' then return M.to_branch(view) end
  local f = d.file
  git.file_commits(d.root, f.path, function(commits)
    if view.state() ~= d then return end
    if #commits == 0 then return notify('no commit touches ' .. f.path .. ' (uncommitted only)') end
    if #commits == 1 then return M.open_commit(view, d, commits[1], f.path) end
    vim.ui.select(commits, {
      prompt = 'Commit of ' .. f.path,
      format_item = function(c) return c.short .. ' ' .. c.subject end,
    }, function(c)
      if c and view.state() == d then M.open_commit(view, d, c, f.path) end
    end)
  end, d.base, f.old_path)
end

local HELP = {
  { 'next_file', 'next changed file' },
  { 'prev_file', 'previous changed file' },
  { 'flip', 'this file: whole branch <-> one commit (pick the commit)' },
  { 'branch', 'back to the whole-branch diff' },
  { 'refresh', 'refresh the file list and the base side' },
  { 'lazygit', 'lazygit for this repository' },
  { 'close', 'close the diff, back to what was shown before' },
  { 'help', 'this help' },
}

function M.help()
  local keys = M.keys()
  local rows = {}
  for _, h in ipairs(HELP) do
    local list = scratch.keys(keys[h[1]])
    if #list > 0 then rows[#rows + 1] = { key = table.concat(list, ' / '), desc = h[2] } end
  end
  rows[#rows + 1] = { key = ']c / [c', desc = 'next / previous hunk (Neovim)' }
  rows[#rows + 1] = { key = 'do / dp', desc = 'diff get / put (Neovim; right side is your file)' }
  require('agent-ide.ui.help').open('Agent-IDE diff', rows)
end

---Map the diff keys on `buf`.
---@param buf integer
---@param view table the diff module
function M.map(buf, view)
  local keys = M.keys()
  scratch.map(buf, keys.next_file, function() view.step(1) end, 'next changed file')
  scratch.map(buf, keys.prev_file, function() view.step(-1) end, 'previous changed file')
  scratch.map(buf, keys.flip, function() M.flip(view) end, 'flip branch / commit')
  scratch.map(buf, keys.branch, function() M.to_branch(view) end, 'branch diff')
  scratch.map(buf, keys.close, view.close, 'close diff')
  scratch.map(buf, keys.refresh, view.refresh, 'refresh diff')
  scratch.map(buf, keys.help, M.help, 'diff help')
  scratch.map(buf, keys.lazygit, function()
    local d = view.state()
    if d then require('agent-ide.ui.lazygit').open(d.root) end
  end, 'lazygit')
end

return M

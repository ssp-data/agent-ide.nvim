-- The git provider of the drawer sections hook: per git project `Changes vs <base>` and
-- `Commits on branch` (`Recent commits` on the default branch), the branch as a dim suffix on
-- the project row, and the refresh triggers (a session's turn ends, `R`, drawer focus).
local cache = require('agent-ide.git_cache')
local prefix = require('agent-ide.ui.icons').prefix

local M = {}

local MAX_ROWS = 500

local STATUS_HL = { M = 'AgentIdeGitModified', A = 'AgentIdeGitAdded', D = 'AgentIdeGitDeleted', R = 'AgentIdeGitRenamed',
  C = 'AgentIdeGitRenamed', ['?'] = 'AgentIdeGitUntracked', T = 'AgentIdeGitModified', U = 'AgentIdeGitDeleted' }

local function drawer() return require('agent-ide.ui.drawer') end

---Pieces of the stats of a file: `+a −d` (a side that is 0 is left out unless both are),
---`bin`, `submodule` or `dir`.
---@param f table
---@return table[]
function M.stats(f)
  if f.submodule then return { { 'submodule', 'AgentIdeAge' } } end
  if f.dir then return { { 'dir', 'AgentIdeAge' } } end
  if f.binary then return { { 'bin', 'AgentIdeAge' } } end
  if not f.added then return {} end
  local added, removed = f.added, f.removed or 0
  local out = {}
  if added > 0 or removed == 0 then out[#out + 1] = { '+' .. added, 'AgentIdeGitAdd' } end
  if removed > 0 or added == 0 then
    if #out > 0 then out[#out + 1] = { ' ' } end
    out[#out + 1] = { '−' .. removed, 'AgentIdeGitDel' }
  end
  return out
end

-- A file row: status and path on the left, the stats right-aligned.
local function file_row(indent, f, node)
  local name = f.old_path and (f.old_path .. ' → ' .. f.path) or f.path
  local pieces = { { indent }, { f.status, STATUS_HL[f.status] }, { ' ' }, { (name:gsub('[\r\n]', ' ')), nil, fit = true } }
  return { pieces = pieces, right = M.stats(f), node = node }
end

local function hint(indent, text, project)
  return { pieces = { { indent .. text, 'AgentIdeAge' } }, node = { type = 'hint', project = project } }
end

local function is_open(expanded, key) return expanded[key] == true end

local function open_diff(node)
  require('agent-ide.ui.diff').open({ project = node.project, root = node.root, mode = node.mode,
    list = node.list, index = node.index, commit = node.commit })
end

-- Work trees ---------------------------------------------------------------------------------

local TREE_TTL = 5000 -- ms a cwd's work tree (and its existence) is trusted
local trees = {} -- cwd -> { tree = string|false, at = ms }

---The work tree's own top level of `cwd` (a linked worktree, not its main checkout); nil when
---`cwd` is gone or not in a repository. Cached per cwd for 5 s.
---@param cwd string|nil
---@return string|nil
function M.tree_of(cwd)
  if not cwd then return nil end
  local now = vim.uv.now()
  local hit = trees[cwd]
  if hit and now - hit.at < TREE_TTL then return hit.tree or nil end
  local tree = vim.uv.fs_stat(cwd) and vim.fs.root(cwd, '.git') or nil
  trees[cwd] = { tree = tree or false, at = now }
  return tree
end

---Work trees of `project`: its root first, then those of its sessions that still exist.
---@param project table
---@return string[]
function M.trees(project)
  local out, seen = { project.root }, { [project.root] = true }
  local extra = {}
  for _, s in ipairs(project.sessions or {}) do
    local t = M.tree_of(s.cwd)
    if t and not seen[t] then
      seen[t] = true
      extra[#extra + 1] = t
    end
  end
  table.sort(extra)
  return vim.list_extend(out, extra)
end

-- Rows -----------------------------------------------------------------------------------------

-- File rows of `list` (at most 500, then `… n more`).
local function files_rows(out, w, list, indent, parent, mode, commit)
  for i, f in ipairs(list) do
    if i > MAX_ROWS then
      out[#out + 1] = hint(indent, ('… %d more'):format(#list - MAX_ROWS), w.project)
      break
    end
    local node = { type = 'git_file', project = w.project, root = w.root, id = parent.id .. ':' .. f.path, file = f,
      list = list, index = i, mode = mode, commit = commit,
      fold = { key = parent.fold.key, default = false, focus = parent.id } }
    if not f.dir then node.open = open_diff end
    out[#out + 1] = file_row(indent, f, node)
  end
end

local function fold_row(out, w, ctx, name, text, group, icon)
  local key = w.root .. '/git/' .. name
  local open = is_open(ctx.expanded, key)
  local node = { type = 'git_section', project = w.project, root = w.root, id = w.root .. '#' .. name,
    fold = { key = key, default = false } }
  node.fold.focus = node.id
  out[#out + 1] = { pieces = { { w.indent .. (open and ctx.icons.open or ctx.icons.closed) .. ' ' .. prefix(icon) .. text, group } },
    node = node }
  return open, node
end

-- `name` is also the icon key (`changes`, `commits`).
local function section(out, w, ctx, name, label, count)
  return fold_row(out, w, ctx, name, label .. (count and (' (' .. count .. ')') or ''), 'AgentIdeSection', ctx.icons[name])
end

local function age(date, now) return require('agent-ide.ui.tree').ago(date, now) end

local function commit_rows(out, w, ctx, commits)
  local ind = w.indent .. '    '
  for i, c in ipairs(commits) do
    if i > MAX_ROWS then
      out[#out + 1] = hint(ind, ('… %d more'):format(#commits - MAX_ROWS), w.project)
      break
    end
    local key = w.root .. '/git/commit/' .. c.hash
    local open = is_open(ctx.expanded, key)
    local node = { type = 'git_commit', project = w.project, root = w.root, commit = c, id = w.root .. '#commit:' .. c.hash,
      fold = { key = key, default = false } }
    node.fold.focus = node.id
    out[#out + 1] = { node = node, pieces = {
      { ind .. (open and ctx.icons.open or ctx.icons.closed) .. ' ' },
      { c.short, 'AgentIdeGitHash' },
      { ' ' },
      { (c.subject:gsub('[\r\n]', ' ')), nil, fit = true },
    }, right = { { age(c.date, ctx.now), 'AgentIdeAge' } } }
    if open then
      local files = cache.commit_files(w.root, c.hash)
      if not files then
        out[#out + 1] = hint(ind .. '    ', 'loading…', w.project)
      else
        files_rows(out, w, files, ind .. '    ', node, 'commit', c)
      end
    end
  end
end

-- The counts of closed sections load for at most COUNT_ROOTS work trees at a time: opening many
-- projects at once (`zR`) loads the rest as earlier ones finish (each finish re-renders), never
-- starting git in all of them together. An open section loads at once.
local COUNT_ROOTS = 4
local counting, counted = 0, {}
local function admit(root)
  if counted[root] then return true end
  if counting >= COUNT_ROOTS then return false end
  counted[root], counting = true, counting + 1
  local left = 2
  local function one()
    left = left - 1
    if left > 0 then return end
    counting = counting - 1
    vim.schedule(function() drawer().refresh() end)
  end
  cache.when(root, 'changes', one)
  cache.when(root, 'commits', one)
  return true
end

---Test only: work trees whose closed-section counts are loading.
function M._counting() return counting end

-- Changes and Commits of one work tree `w = { root, project, indent }`.
local function tree_rows(out, w, ctx)
  local root = w.root
  local changes, commits, base
  if admit(root) or is_open(ctx.expanded, root .. '/git/changes') or is_open(ctx.expanded, root .. '/git/commits') then
    changes, base = cache.changes(root)
    commits = cache.commits(root)
    base = base or cache.base(root)
  else
    local e = cache.peek(root)
    if e then changes, commits, base = e.data.changes, e.data.commits, e.data.base end
  end
  local label = base and ('Changes vs ' .. base.label) or 'Changes'
  local open, node = section(out, w, ctx, 'changes', label, changes and #changes)
  if open then
    if not changes then
      out[#out + 1] = hint(w.indent .. '    ', 'loading…', w.project)
    else
      files_rows(out, w, changes, w.indent .. '    ', node, 'branch')
    end
  end
  label = base and (base.mode == 'branch' and 'Commits on branch' or 'Recent commits') or 'Commits'
  open, node = section(out, w, ctx, 'commits', label, commits and #commits)
  if open then
    if not commits then
      out[#out + 1] = hint(w.indent .. '    ', 'loading…', w.project)
    else
      commit_rows(out, w, ctx, commits)
    end
  end
end

local function branch_suffix(root)
  local h = cache.head(root)
  if h and h.branch and (h.detached or h.branch ~= h.default_name) then return { { '  ' .. h.branch, 'AgentIdeBranch' } } end
end

---Provider: rows for an expanded git project, the branch suffix for any git project. One work
---tree: Changes and Commits directly; several (linked worktrees of its sessions): one fold row
---per tree (`⎇ <branch> · <folder>`, the main checkout first) with Changes and Commits inside.
---@param project table
---@param ctx table
function M.rows(project, ctx)
  if not project.is_git or project.missing or not project.root then return nil end
  local list = M.trees(project)
  local suffix = branch_suffix(project.root) -- the single tree, or the main checkout
  if not ctx.open then return nil, suffix end
  local out = {}
  if #list == 1 then
    tree_rows(out, { root = list[1], project = project, indent = '  ' }, ctx)
    return out, suffix
  end
  for _, root in ipairs(list) do
    local h = cache.head(root)
    local w = { root = root, project = project, indent = '  ' }
    local text = (h and h.branch or '…') .. ' · ' .. vim.fs.basename(root)
    local open = fold_row(out, w, ctx, 'tree', text, 'AgentIdeSection', ctx.icons.worktree or '⎇')
    if open then tree_rows(out, { root = root, project = project, indent = '    ' }, ctx) end
  end
  return out, suffix
end

-- Refresh triggers ---------------------------------------------------------------------------

local last_state = {} -- session id -> last state seen
local focus_timer

---Repository root of a session: its drawer project, else found from its folder.
local function root_of(s)
  for _, p in ipairs(drawer().state().projects or {}) do
    for _, m in ipairs(p.sessions or {}) do
      if m.id == s.id then return p.is_git and p.root or nil end
    end
  end
  if not s.cwd then return nil end
  return (require('agent-ide.project').git_root(s.cwd, vim.uv.os_homedir() or ''))
end

local function on_session(s, what)
  if what ~= 'state' then return end
  local prev = last_state[s.id]
  last_state[s.id] = s.state
  if prev == 'busy' and s.state ~= 'busy' then
    local root = M.tree_of(s.cwd) or root_of(s)
    if root then cache.invalidate(root) end
  end
end

local function on_update() drawer().refresh() end

---Invalidate the git data of every known repository (drawer `R`).
function M.refresh()
  for _, root in ipairs(cache.roots()) do cache.invalidate(root) end
end

---The drawer was entered: a cheap status check per repository, debounced.
function M.focus()
  if not focus_timer then focus_timer = vim.uv.new_timer() end
  focus_timer:stop()
  focus_timer:start(200, 0, vim.schedule_wrap(function()
    for _, root in ipairs(cache.roots()) do cache.check(root) end
  end))
end

function M.setup()
  require('agent-ide.ui.git_hl').setup()
  local session = require('agent-ide.session')
  session.off_change(on_session)
  session.on_change(on_session)
  cache.on_update(on_update)
end

M._on_session = on_session

function M.register()
  require('agent-ide.ui.sections').register('git', { rows = M.rows, setup = M.setup, refresh = M.refresh, focus = M.focus })
end

return M

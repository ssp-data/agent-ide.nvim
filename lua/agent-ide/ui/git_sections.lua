-- The git provider of the drawer sections hook: per git project `Changes vs <base>` and
-- `Commits on branch` (`Recent commits` on the default branch), the branch as a dim suffix on
-- the project row, and the refresh triggers (a session's turn ends, `R`, drawer focus).
local cache = require('agent-ide.git_cache')

local M = {}

local MAX_ROWS = 500

local STATUS_HL = { M = 'AgentIdeGitModified', A = 'AgentIdeGitAdded', D = 'AgentIdeGitDeleted', R = 'AgentIdeGitRenamed',
  C = 'AgentIdeGitRenamed', ['?'] = 'AgentIdeGitUntracked', T = 'AgentIdeGitModified', U = 'AgentIdeGitDeleted' }

local function drawer() return require('agent-ide.ui.drawer') end

---Pieces of the stats of a file: `+a −d`, `bin` or `submodule`.
---@param f table
---@return table[]
function M.stats(f)
  if f.submodule then return { { 'submodule', 'AgentIdeAge' } } end
  if f.binary then return { { 'bin', 'AgentIdeAge' } } end
  if not f.added then return {} end
  return { { '+' .. f.added, 'AgentIdeGitAdd' }, { ' ' }, { '−' .. (f.removed or 0), 'AgentIdeGitDel' } }
end

local function file_row(indent, f, node)
  local name = f.old_path and (f.old_path .. ' → ' .. f.path) or f.path
  local pieces = { { indent }, { f.status, STATUS_HL[f.status] }, { ' ' .. name:gsub('[\r\n]', ' ') } }
  local stats = M.stats(f)
  if #stats > 0 then
    pieces[#pieces + 1] = { '  ' }
    vim.list_extend(pieces, stats)
  end
  return { pieces = pieces, node = node }
end

local function hint(indent, text, project)
  return { pieces = { { indent .. text, 'AgentIdeAge' } }, node = { type = 'hint', project = project } }
end

local function is_open(expanded, key) return expanded[key] == true end

local function open_diff(node)
  require('agent-ide.ui.diff').open({ project = node.project, root = node.project.root, mode = node.mode,
    list = node.list, index = node.index, commit = node.commit })
end

-- File rows of `list` (at most 500, then `… n more`).
local function files_rows(out, project, list, indent, parent, mode, commit)
  for i, f in ipairs(list) do
    if i > MAX_ROWS then
      out[#out + 1] = hint(indent, ('… %d more'):format(#list - MAX_ROWS), project)
      break
    end
    out[#out + 1] = file_row(indent, f, { type = 'git_file', project = project, id = parent.id .. ':' .. f.path, file = f,
      list = list, index = i, mode = mode, commit = commit, open = open_diff,
      fold = { key = parent.fold.key, default = false, focus = parent.id } })
  end
end

local function section(out, project, ctx, name, label, count)
  local key = project.key .. '/git/' .. name
  local open = is_open(ctx.expanded, key)
  local node = { type = 'git_section', project = project, id = project.key .. '#' .. name,
    fold = { key = key, default = false } }
  node.fold.focus = node.id
  local text = '  ' .. (open and ctx.icons.open or ctx.icons.closed) .. ' ' .. label .. (count and (' (' .. count .. ')') or '')
  out[#out + 1] = { pieces = { { text, 'AgentIdeSection' } }, node = node }
  return open, node
end

local function age(date, now) return require('agent-ide.ui.tree').ago(date, now) end

local function commit_rows(out, project, ctx, commits)
  local root = project.root
  for i, c in ipairs(commits) do
    if i > MAX_ROWS then
      out[#out + 1] = hint('      ', ('… %d more'):format(#commits - MAX_ROWS), project)
      break
    end
    local key = project.key .. '/git/commit/' .. c.hash
    local open = is_open(ctx.expanded, key)
    local node = { type = 'git_commit', project = project, commit = c, id = project.key .. '#commit:' .. c.hash,
      fold = { key = key, default = false } }
    node.fold.focus = node.id
    out[#out + 1] = { node = node, pieces = {
      { '      ' .. (open and ctx.icons.open or ctx.icons.closed) .. ' ' },
      { c.short, 'AgentIdeGitHash' },
      { ' ' .. c.subject:gsub('[\r\n]', ' ') .. '  ' },
      { c.files .. (c.files == 1 and ' file' or ' files') .. '  ' .. age(c.date, ctx.now), 'AgentIdeAge' },
    } }
    if open then
      local files = cache.commit_files(root, c.hash)
      if not files then
        out[#out + 1] = hint('          ', 'loading…', project)
      else
        files_rows(out, project, files, '          ', node, 'commit', c)
      end
    end
  end
end

---Provider: rows for an expanded git project, the branch suffix for any git project.
---@param project table
---@param ctx table
function M.rows(project, ctx)
  if not project.is_git or project.missing or not project.root then return nil end
  local root = project.root
  local suffix
  local h = cache.head(root)
  if h and h.branch and (h.detached or h.branch ~= h.default_name) then suffix = { { '  ' .. h.branch, 'AgentIdeBranch' } } end
  if not ctx.open then return nil, suffix end

  local out = {}
  local changes, base = cache.changes(root)
  local commits = cache.commits(root)
  base = base or cache.base(root)
  local label = base and ('Changes vs ' .. base.label) or 'Changes'
  local open, node = section(out, project, ctx, 'changes', label, changes and #changes)
  if open then
    if not changes then
      out[#out + 1] = hint('      ', 'loading…', project)
    else
      files_rows(out, project, changes, '      ', node, 'branch')
    end
  end
  label = base and (base.mode == 'branch' and 'Commits on branch' or 'Recent commits') or 'Commits'
  open, node = section(out, project, ctx, 'commits', label, commits and #commits)
  if open then
    if not commits then
      out[#out + 1] = hint('      ', 'loading…', project)
    else
      commit_rows(out, project, ctx, commits)
    end
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
    local root = root_of(s)
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

-- Into and out of the full diff: a drawer row to its scope (`gd`), and from the full diff into
-- the side-by-side diff view (`<CR>`) with the list and mode the drawer would use for the file.
local cache = require('agent-ide.git_cache')
local git = require('agent-ide.git')

local M = {}

---Open the full diff a drawer row stands for: the row's project, section, commit or file. The
---scope follows the row (its work tree as `G` picks it); a file row puts the cursor on that
---file. false when the row is not in a git project.
---@param node table|nil
---@return boolean
function M.from_node(node)
  local root, project = require('agent-ide.ui.graph_context').node_root(node)
  if not root then return false end
  local scope, focus = { kind = 'branch' }, nil
  local t = node.type
  if t == 'git_file' then
    scope = { kind = node.mode == 'commit' and 'commit' or node.mode == 'head' and 'head' or 'branch', commit = node.commit }
    focus = node.file.path
  elseif t == 'git_commit' then
    scope = { kind = 'commit', commit = node.commit }
  elseif t == 'git_uncommitted' then
    scope = { kind = 'head' }
  elseif t == 'git_fulldiff' then
    scope = { kind = node.kind }
  elseif t == 'git_graph' or (t == 'git_section' and node.name == 'commits') then
    scope = { kind = 'commits' }
  end
  require('agent-ide.ui.fulldiff').open({ root = root, project = project, scope = scope, focus_path = focus })
  return true
end

local function notify(msg) vim.notify('Agent-IDE: ' .. msg, vim.log.levels.INFO) end

local function index_of(list, path)
  for i, f in ipairs(list or {}) do
    if f.path == path then return i end
  end
end

local function view() return require('agent-ide.ui.fulldiff') end

-- Open the side-by-side view of `path` with the list of cache `kind` in `mode`, once `v` is
-- still the open view.
local function side_by_side(v, path, line, mode, kind, commit)
  cache.when(v.root, kind, function(list)
    if view().state() ~= v then return end
    local i = index_of(list, path)
    if not i then return notify(path .. ' is not in the list any more') end
    require('agent-ide.ui.diff').open({ project = v.project, root = v.root, mode = mode, list = list, index = i,
      commit = commit, line = line })
  end)
end

---Side-by-side view of `path` of view `v`, the right side's cursor on `line` (nil: the first
---hunk). Branch and commits scopes: the branch view (the working file on the right); on the
---default branch (recent commits) the commits scope opens the newest listed commit touching
---the file; commit and head scopes their own modes.
---@param v table the open view (fulldiff.state())
---@param path string
---@param line integer|nil
function M.side_by_side(v, path, line)
  local kind = v.scope.kind
  if kind == 'commit' then
    return side_by_side(v, path, line, 'commit', 'files:' .. v.scope.commit.hash, v.scope.commit)
  elseif kind == 'head' then
    return side_by_side(v, path, line, 'head', 'uncommitted')
  end
  local base = cache.base(v.root)
  if kind == 'branch' or (base and base.mode == 'branch') then
    return side_by_side(v, path, line, 'branch', 'changes')
  end
  git.file_commits(v.root, path, function(commits)
    if view().state() ~= v then return end
    local c = commits[1]
    if not c then return notify('no commit touches ' .. path) end
    side_by_side(v, path, line, 'commit', 'files:' .. c.hash, c)
  end, base)
end

return M

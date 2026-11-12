-- From the full diff into the side-by-side diff view (`<CR>`): the file under the cursor with
-- the list and mode the drawer would use for it.
local cache = require('agent-ide.git_cache')
local git = require('agent-ide.git')

local M = {}

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

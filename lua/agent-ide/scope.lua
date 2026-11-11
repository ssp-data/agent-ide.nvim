-- The plugin's scope: every project ('all') or one project ('project'). Per Neovim instance,
-- not persisted; `config.scope` is where it starts. The drawer, search, "next waiting" and the
-- footer ask here; the status file for the desktop bar does not (it stays the global overview).
-- A project is identified as the drawer groups them (project.lua): the git repository root of a
-- folder (sub-folders and worktrees fold into it), else the folder itself.
local project = require('agent-ide.project')

local M = {}

local kind -- 'all' | 'project'; nil: not set yet (config.scope)
local anchor -- { key, name, root, is_git } of the project scope; nil: resolve from the cwd
local keys = {} -- cwd -> project key

local function basename(p) return p:match('([^/]*)$') end

---Project key of a folder, as `project.group` keys it (cached per folder).
---@param cwd string
---@return string
function M.key_of(cwd)
  local k = keys[cwd]
  if not k then
    local root = project.git_root(cwd, vim.uv.os_homedir() or '')
    k = root or cwd
    keys[cwd] = k
  end
  return k
end

-- The project of Neovim's global working directory (the plugin sets tab-local ones itself).
local function from_cwd()
  local cwd = vim.fn.getcwd(-1, -1)
  local root = project.git_root(cwd, vim.uv.os_homedir() or '')
  local key = root or cwd
  keys[cwd] = key
  return { key = key, name = basename(key), root = root, is_git = root ~= nil }
end

---The project of Neovim's working directory, whatever the scope is.
---@return table { key, name, root, is_git }
function M.cwd_project() return from_cwd() end

---@return 'all'|'project'
function M.get()
  if kind then return kind end
  local c = require('agent-ide.config').get().scope
  return c == 'project' and 'project' or 'all'
end

---Set the scope. 'project' with `at` (a drawer project: `key`, `name`, `root`, `is_git`) scopes
---to that project, without it to the project of the current working directory (resolved again
---on every call, so `:Agents project` re-anchors).
---@param k 'all'|'project'
---@param at? table
function M.set(k, at)
  if k ~= 'all' and k ~= 'project' then error('scope must be "all" or "project"', 2) end
  kind = k
  if k == 'project' then
    anchor = at and { key = at.key, name = at.name or basename(at.key), root = at.root, is_git = at.is_git } or from_cwd()
  end
end

---The scoped project `{ key, name, root, is_git }`, or nil in 'all' scope.
---@return table|nil
function M.project()
  if M.get() ~= 'project' then return nil end
  if not anchor then anchor = from_cwd() end
  return anchor
end

---Whether `x` is in scope: a project (has `sessions`, compared by `key`), or anything with a
---`cwd` (a session, a live entry). Everything is in 'all' scope; something without either is not
---in a project scope.
---@param x table
---@return boolean
function M.matches(x)
  local p = M.project()
  if not p then return true end
  if type(x) ~= 'table' then return false end
  if x.sessions ~= nil and x.key then return x.key == p.key end
  if type(x.cwd) == 'string' and x.cwd ~= '' then return M.key_of(x.cwd) == p.key end
  return false
end

---Test only: back to the configured scope, caches cleared.
function M._reset() kind, anchor, keys = nil, nil, {} end

return M

-- Which repository a commit graph is for: a drawer row's, or the current context's
-- (`:AgentsGraph`).
local api = vim.api

local M = {}

local function tree_of(cwd) return require('agent-ide.ui.git_sections').tree_of(cwd) end

---Repository of a drawer row: a git row's own work tree, a session's (a linked worktree), else
---the project's root. nil for rows outside a git project.
---@param node table|nil
---@return string|nil root, table|nil project
function M.node_root(node)
  local p = node and node.project
  if not (p and p.is_git and p.root) then return nil end
  return node.root or (node.session and tree_of(node.session.cwd)) or p.root, p
end

---What `:AgentsGraph` opens: the open graph's repository, the diff view's, the chat session's,
---the drawer row's, else the work tree of the current file (or of the working directory).
---@param view table|nil the open graph (ui/graph.lua state)
---@return { root?: string, dir?: string, project?: table }
function M.target(view)
  local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
  if view and buf == view.buf then return { root = view.root, project = view.project } end
  local diff = package.loaded['agent-ide.ui.diff']
  local d = diff and diff.state()
  if d and (win == d.left or win == d.right) then return { root = d.root, project = d.project } end
  local chat = package.loaded['agent-ide.ui.chat']
  local s = chat and chat.session_of(buf)
  if s then
    local p = chat.project_of(s)
    local root = tree_of(s.cwd) or (p.is_git and p.root)
    if root then return { root = root, project = p.is_git and p or nil } end
  end
  local ds = require('agent-ide.ui.drawer').state()
  if ds.win and win == ds.win then
    local root, p = M.node_root(ds.nodes[api.nvim_win_get_cursor(win)[1]])
    if root then return { root = root, project = p } end
  end
  local name = api.nvim_buf_get_name(buf)
  return { dir = (vim.bo[buf].buftype == '' and name ~= '') and vim.fs.dirname(name) or vim.fn.getcwd() }
end

return M

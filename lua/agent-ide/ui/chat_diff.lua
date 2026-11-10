-- `gd` in a chat transcript: on a line of an `Edit` / `Write` tool fold, open the branch diff of
-- that file. The fold comes from the renderer's fold levels (not from the text), its header is
-- matched against the session's Edit/Write events (rendered the way `transcript.render` renders
-- a call header), and the path is the event's full `file_path`, never the cut header text.
local api = vim.api
local history = require('agent-ide.ui.history')
local render = require('agent-ide.transcript.render')

local M = {}

local NOTICE = 'no Edit or Write of a file here'
local TOOLS = { Edit = true, Write = true, MultiEdit = true }

local function notify(msg) vim.notify('Agent-IDE: ' .. msg, vim.log.levels.INFO) end

---Header text -> file path of the Edit/Write calls of `s`.
local function headers(s)
  local out = {}
  for _, ev in ipairs(s.events or {}) do
    local input = ev.input
    if ev.kind == 'tool_call' and TOOLS[ev.name] and type(input) == 'table' and type(input.file_path) == 'string' then
      out[('▸ %s: %s'):format(ev.name, (render.tool_parts(ev.name, input)))] = input.file_path
    end
  end
  return out
end

---File path of the Edit/Write fold at `row` of transcript `buf`, or nil. Only the line that
---starts the fold (level `>1`) is taken for its header, so a look-alike line inside a body
---never is.
---@param buf integer
---@param s table Session
---@param row integer
---@return string|nil
function M.target(buf, s, row)
  local levels = history.levels(buf) or {}
  if (levels[row] or '0') == '0' then return nil end
  local first = row
  while first > 1 and levels[first] ~= '>1' do first = first - 1 end
  if levels[first] ~= '>1' then return nil end
  local header = api.nvim_buf_get_lines(buf, first - 1, first, false)[1] or ''
  return headers(s)[header]
end

local function root_of(s, path)
  local chat = package.loaded['agent-ide.ui.chat']
  local p = chat and chat.project_of(s)
  -- the file's own work tree first (a linked worktree under the project is not the project root)
  local root = vim.fs.root(vim.fs.dirname(path), '.git')
  if not root and p and p.root and vim.startswith(path, p.root .. '/') then root = p.root end
  if not root then return nil end
  return root, p or { key = root, root = root, name = vim.fs.basename(root), is_git = true, sessions = {} }
end

---Open the branch diff of the file of the Edit/Write fold under the cursor.
---@param buf integer
---@param s table Session
function M.open(buf, s)
  local path = M.target(buf, s, api.nvim_win_get_cursor(0)[1])
  if not path then return notify(NOTICE) end
  path = vim.fs.normalize(path)
  local root, project = root_of(s, path)
  if not root then return notify('not in a git repository: ' .. path) end
  local rel = path:sub(#root + 2)
  require('agent-ide.git_cache').when(root, 'changes', function(list)
    for i, f in ipairs(list or {}) do
      if f.path == rel then
        return require('agent-ide.ui.diff').open({ project = project, root = root, mode = 'branch', list = list, index = i })
      end
    end
    notify(rel .. ' has no changes on the branch')
  end)
end

---Map `keys.diff` in transcript `buf` of session `s`.
function M.map(buf, s, keys)
  for _, lhs in ipairs(require('agent-ide.ui.diff_buf').keys(keys.diff)) do
    vim.keymap.set('n', lhs, function() M.open(buf, s) end,
      { buffer = buf, nowait = true, silent = true, desc = 'Agent-IDE: branch diff of this Edit/Write' })
  end
end

return M

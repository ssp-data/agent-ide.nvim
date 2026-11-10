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

-- Subagent groups of the transcript, in render order: the runs of sidechain events that
-- `transcript.render` folds into one `▸ subagent (n events)` block (per turn, a run starts at a
-- sidechain event that is neither a prompt nor the result of a call of the same turn).
local function groups(events)
  local out, first = {}, 1
  for i = 2, #events + 1 do
    if i > #events or render.starts_turn(events[i]) then
      local turn = vim.list_slice(events, first, i - 1)
      local known = {}
      for _, ev in ipairs(turn) do
        if ev.kind == 'tool_call' and ev.id ~= nil then known[ev.id] = true end
      end
      local k = 1
      while k <= #turn do
        local ev = turn[k]
        if ev.sidechain and ev.kind ~= 'prompt' and not (ev.kind == 'tool_result' and known[ev.id]) then
          local j = k
          while j <= #turn and turn[j].sidechain do j = j + 1 end
          out[#out + 1] = vim.list_slice(turn, k, j - 1)
          k = j
        else
          k = k + 1
        end
      end
      first = i
    end
  end
  return out
end

-- The group's body as `render` draws it inside the subagent fold (lines without the `│ `
-- prefix, folds of its own blocks): the group rendered as a main-thread run.
local function inner(group)
  local copy = {}
  for i, ev in ipairs(group) do
    copy[i] = ev.kind == 'prompt' and ev or setmetatable({ sidechain = false }, { __index = ev })
  end
  return render.render(copy)
end

local BAR = '│ '

-- Header of the block of subagent fold `first` (buffer line) that contains `row`, or nil.
local function nested_header(buf, s, levels, first, row)
  -- which subagent fold this is: count the subagent fold starts above it
  local k = 0
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  for l = 1, first do
    if levels[l] == '>1' and vim.startswith(lines[l], '▸ subagent (') then k = k + 1 end
  end
  local group = groups(s.events or {})[k]
  if not group then return nil end
  local r = inner(group)
  -- the body in the buffer must be exactly the rendered group, or nothing is trusted
  for n, l in ipairs(r.lines) do
    if lines[first + n] ~= BAR .. l then return nil end
  end
  local idx = row - first
  for _, f in ipairs(r.folds) do
    if idx >= f.first and idx <= f.last then return r.lines[f.first] end
  end
end

---File path of the Edit/Write fold at `row` of transcript `buf`, or nil. Only the line that
---starts a fold (level `>1`) is taken for a header, so a look-alike line inside a body never is.
---Inside a subagent fold, the nested block holding `row` is found by rendering the subagent's
---events the way `transcript.render` does, so nested Edit/Write calls work too.
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
  local known = headers(s)
  if known[header] then return known[header] end
  if vim.startswith(header, '▸ subagent (') and row > first then
    local h = nested_header(buf, s, levels, first, row)
    return h and known[h]
  end
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
  for _, lhs in ipairs(require('agent-ide.util.keys').list(keys.diff)) do
    vim.keymap.set('n', lhs, function() M.open(buf, s) end,
      { buffer = buf, nowait = true, silent = true, desc = 'Agent-IDE: branch diff of this Edit/Write' })
  end
end

return M

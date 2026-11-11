-- Pure drawer model: projects + session states -> lines, one node per line, highlight ranges.
-- Every row has a left part (indent, fold arrow, mark, title) and a right part (state word,
-- age, git stats) aligned to the drawer's right edge (see ui/layout.lua).
local live = require('agent-ide.live')
local layout = require('agent-ide.ui.layout')

local M = {}

local STATE_GROUP = {
  waiting = 'AgentIdeWaiting',
  busy = 'AgentIdeBusy',
  idle = 'AgentIdeIdle',
  parked = 'AgentIdeParked',
  done = 'AgentIdeDone',
  failed = 'AgentIdeFailed',
}
M.STATE_GROUP = STATE_GROUP

---Age of `activity` at `now`: now, 5m, 3h, 12d (up to 60 days), 14mo (30-day months, up to
---24 months), then years.
---@param activity integer
---@param now integer
---@return string
function M.ago(activity, now)
  local d = now - activity
  if d < 90 then return 'now' end
  if d < 3600 then return math.floor(d / 60) .. 'm' end
  if d < 86400 then return math.floor(d / 3600) .. 'h' end
  local days = math.floor(d / 86400)
  if days < 60 then return days .. 'd' end
  local months = math.floor(days / 30)
  if months < 24 then return months .. 'mo' end
  return math.floor(months / 12) .. 'y'
end

local function one_line(s) return (tostring(s or ''):gsub('[\r\n\t]', ' ')) end

-- Right part of a project row: the rolled-up state icon, a word for the states that want
-- attention (`input (n)` waiting, `review (n)` done or failed), the age.
local function project_right(rolled, states, icons, age)
  local group = STATE_GROUP[rolled]
  local out = {}
  local icon = icons[rolled] or ''
  if icon ~= '' then out[#out + 1] = { icon, group } end
  local word
  if rolled == 'waiting' or rolled == 'done' or rolled == 'failed' then
    local n = 0
    for _, s in ipairs(states) do
      if s == rolled or (rolled ~= 'waiting' and (s == 'done' or s == 'failed')) then n = n + 1 end
    end
    word = (rolled == 'waiting' and 'input' or 'review') .. ' (' .. n .. ')'
  end
  if word then
    if #out > 0 then out[#out + 1] = { ' ' } end
    out[#out + 1] = { word, group }
  end
  if #out > 0 then out[#out + 1] = { ' ' } end
  out[#out + 1] = { age, 'AgentIdeAge' }
  return out
end

---@param projects table[] a project's `hidden` sessions (see drawer_model.with_hidden) form a
---  collapsed `Hidden (n)` group at the end of its Sessions section (`expanded[key .. '/hidden']`)
---@param state_of fun(session_id: string): string State of one session
---@param expanded table<string, boolean>
---@param now integer
---@param icons table
---@param projects_dir string|nil
---@param note_of? fun(session_id: string, state: string): table|string|nil the state word of a session row (`{ text, hl_group }`)
---@param extra? fun(project: table, ctx: table): table[]|nil, table[]|nil extra rows and a project-row suffix (see ui/sections.lua)
---@param opts? { top?: fun(ctx: table): table[]|nil, width?: integer, scope?: { branch?: string, others?: integer, key?: string } }
---  top: rows above the projects (see ui/sections.lua); width: the drawer width (nil: no
---  alignment, the right part follows after two spaces); scope: project scope (see scope.lua):
---  `projects` holds the one project, shown without its own row (its rows one level up) under a
---  dim scope line (`branch` on it), and `others` (sessions of other projects that need the
---  user) counted on a dim last line
function M.build(projects, state_of, expanded, now, icons, projects_dir, note_of, extra, opts)
  opts = opts or {}
  local width = opts.width
  local lines, nodes, hl = {}, {}, {}

  -- project scope: the project's rows lose one level of indent (two spaces)
  local undent = false
  local function dedent(pieces)
    for i, p in ipairs(pieces) do
      if p[1] ~= '' then
        if p[1]:sub(1, 2) ~= '  ' then return pieces end
        local out = vim.list_extend({}, pieces)
        out[i] = { p[1]:sub(3), p[2], fit = p.fit }
        return out
      end
    end
    return pieces
  end

  -- Append a line made of { text, group|nil } pieces; records byte ranges of grouped pieces.
  local function add(pieces, node)
    if undent then pieces = dedent(pieces) end
    local n = #lines + 1
    local col, parts = 0, {}
    for _, p in ipairs(pieces) do
      local text = p[1]
      parts[#parts + 1] = text
      if p[2] and text ~= '' then hl[#hl + 1] = { line = n, col_start = col, col_end = col + #text, group = p[2] } end
      col = col + #text
    end
    lines[n] = table.concat(parts)
    nodes[n] = node
  end
  local function add_row(left, right, node)
    if undent then left = dedent(left) end
    local was = undent
    undent = false -- already done; the padding of layout.row must stay
    add(layout.row(left, right, width), node)
    undent = was
  end
  -- a provider row: aligned when it has a `right` part, else as given
  local function add_provided(r)
    if r.right then add_row(r.pieces, r.right, r.node) else add(r.pieces, r.node) end
  end

  local scoped = opts.scope
  if scoped then
    local p = projects[1]
    local left = { { one_line(p.name), 'AgentIdeAge', fit = true } }
    if scoped.branch and scoped.branch ~= '' then left[2] = { '  ' .. one_line(scoped.branch), 'AgentIdeAge', fit = true } end
    if p.missing then left[#left + 1] = { ' (folder missing)', 'AgentIdeMissing', fit = 'last' } end
    add_row(left, { { (scoped.key or '?') .. ': all', 'AgentIdeAge' } }, { type = 'scope', project = p })
  end

  if opts.top then
    for _, r in ipairs(opts.top({ expanded = expanded, icons = icons, now = now, width = width }) or {}) do add_provided(r) end
  end

  if #projects == 0 and not scoped then
    add({ { projects_dir and ('No Claude sessions found in ' .. projects_dir) or 'No Claude sessions found' } }, { type = 'hint' })
    return { lines = lines, nodes = nodes, hl = hl }
  end

  for _, project in ipairs(projects) do
    local is_open = scoped ~= nil or expanded[project.key] == true
    local states = {}
    for i, s in ipairs(project.sessions) do states[i] = state_of(s.id) end
    local rows, suffix
    if extra then rows, suffix = extra(project, { open = is_open, expanded = expanded, icons = icons, now = now, width = width }) end
    if not scoped then
      local rolled = live.rollup(states)
      local left = {
        { (is_open and icons.open or icons.closed) .. ' ' },
        { one_line(project.name), rolled == 'parked' and 'AgentIdeParked' or 'AgentIdeProject', fit = true },
      }
      for _, p in ipairs(suffix or {}) do left[#left + 1] = { p[1], p[2], fit = true } end
      if project.missing then left[#left + 1] = { ' (folder missing)', 'AgentIdeMissing', fit = 'last' } end
      add_row(left, project_right(rolled, states, icons, M.ago(project.activity, now)), { type = 'project', project = project })
    else
      undent = true -- the project's rows one level up: there is no project row above them
    end

    if is_open then
      add({ { '    + New session' } }, { type = 'new', project = project })
      local key = project.key .. '/sessions'
      local sec_open = expanded[key] ~= false
      add({ { '  ' .. (sec_open and icons.open or icons.closed) .. ' '
        .. 'Sessions (' .. #project.sessions .. ')', 'AgentIdeSection' } }, { type = 'section', project = project, key = key })
      if sec_open then
        local function session_row(s, state, indent, hidden)
          local group = STATE_GROUP[state]
          local title_hl = state == 'parked' and 'AgentIdeParked' or nil
          local sl = { { indent } }
          local icon = icons[state] or ''
          if icon ~= '' then
            sl[#sl + 1] = { icon, group }
            sl[#sl + 1] = { ' ' }
          end
          -- a session of another agent names it; Claude's rows read as they always did
          if s.agent and s.agent ~= 'claude' then sl[#sl + 1] = { one_line(s.agent) .. ' · ', title_hl or 'AgentIdeAgent' } end
          if s.subpath and s.subpath ~= '' then sl[#sl + 1] = { one_line(s.subpath) .. '/ · ', title_hl } end
          sl[#sl + 1] = { one_line(s.title), title_hl, fit = true }
          local sr = {}
          local note = note_of and note_of(s.id, state)
          if type(note) == 'string' then note = { note, group } end
          if note and note[1] and note[1] ~= '' then
            sr[1] = { one_line(note[1]), note[2] or group }
            sr[2] = { ' ' }
          end
          sr[#sr + 1] = { M.ago(s.activity, now), 'AgentIdeAge' }
          add_row(sl, sr, { type = 'session', project = project, session = s, state = state, hidden = hidden })
        end
        for i, s in ipairs(project.sessions) do session_row(s, states[i], '      ') end
        -- hidden sessions (see drawer_model.with_hidden): a collapsed group, the section's last row
        local hidden = project.hidden
        if hidden and #hidden > 0 then
          local hkey = project.key .. '/hidden'
          local h_open = expanded[hkey] == true
          add({ { '    ' .. (h_open and icons.open or icons.closed) .. ' Hidden (' .. #hidden .. ')', 'AgentIdeParked' } },
            { type = 'hidden', project = project, key = hkey })
          if h_open then
            for _, s in ipairs(hidden) do session_row(s, state_of(s.id), '        ', true) end
          end
        end
      end
      for _, r in ipairs(rows or {}) do add_provided(r) end
    end
  end
  undent = false

  if scoped and (scoped.others or 0) > 0 then
    local n = scoped.others
    add({ { ('%d session%s in other projects need%s you · %s'):format(n, n == 1 and '' or 's', n == 1 and 's' or '', scoped.key or '?'),
      'AgentIdeAge' } }, { type = 'others' })
  end

  return { lines = lines, nodes = nodes, hl = hl }
end

return M

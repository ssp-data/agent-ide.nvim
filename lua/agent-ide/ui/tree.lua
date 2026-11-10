-- Pure drawer model: projects + live state -> lines, one node per line, highlight ranges.
local live = require('agent-ide.live')

local M = {}

local STATE_GROUP = {
  waiting = 'AgentIdeWaiting',
  busy = 'AgentIdeBusy',
  idle = 'AgentIdeIdle',
  parked = 'AgentIdeParked',
}

---@param mtime integer
---@param now integer
---@return string
function M.ago(mtime, now)
  local d = now - mtime
  if d < 90 then return 'now' end
  if d < 3600 then return math.floor(d / 60) .. 'm' end
  if d < 86400 then return math.floor(d / 3600) .. 'h' end
  return math.floor(d / 86400) .. 'd'
end

---@param projects table[]
---@param live_map table
---@param expanded table<string, boolean>
---@param now integer
---@param icons table
---@param projects_dir string|nil
function M.build(projects, live_map, expanded, now, icons, projects_dir)
  local lines, nodes, hl = {}, {}, {}

  -- Append a line made of { text, group|nil } pieces; records byte ranges of grouped pieces.
  local function add(pieces, node)
    local n = #lines + 1
    local col, parts = 0, {}
    for _, p in ipairs(pieces) do
      parts[#parts + 1] = p[1]
      if p[2] then hl[#hl + 1] = { line = n, col_start = col, col_end = col + #p[1], group = p[2] } end
      col = col + #p[1]
    end
    lines[n] = table.concat(parts)
    nodes[n] = node
  end

  if #projects == 0 then
    add({ { projects_dir and ('No Claude sessions found in ' .. projects_dir) or 'No Claude sessions found' } }, { type = 'hint' })
    return { lines = lines, nodes = nodes, hl = hl }
  end

  for _, project in ipairs(projects) do
    local is_open = expanded[project.key] == true
    local states = {}
    for i, s in ipairs(project.sessions) do states[i] = live.state_of(live_map, s.id) end
    local rolled = live.rollup(states)
    local pieces = {
      { (is_open and icons.open or icons.closed) .. ' ' .. icons.project .. ' ' },
      { project.name, 'AgentIdeProject' },
      { '  ' },
      { icons[rolled], STATE_GROUP[rolled] },
      { ' ' },
      { M.ago(project.mtime, now), 'AgentIdeAge' },
    }
    if project.missing then pieces[#pieces + 1] = { ' (gone)', 'AgentIdeMissing' } end
    add(pieces, { type = 'project', project = project })

    if is_open then
      local key = project.key .. '/sessions'
      local sec_open = expanded[key] ~= false
      add({ { '  ' .. (sec_open and icons.open or icons.closed) .. ' Sessions (' .. #project.sessions .. ')', 'AgentIdeSection' } },
        { type = 'section', project = project, key = key })
      if sec_open then
        for i, s in ipairs(project.sessions) do
          local state = states[i]
          local title = (s.title or ''):gsub('[\r\n]', ' ')
          local sp = {
            { '      ' },
            { icons[state], STATE_GROUP[state] },
            { ' ' .. title },
          }
          if s.subpath and s.subpath ~= '' then sp[#sp + 1] = { '  [' .. s.subpath .. ']' } end
          sp[#sp + 1] = { '  ' }
          sp[#sp + 1] = { M.ago(s.mtime, now), 'AgentIdeAge' }
          add(sp, { type = 'session', project = project, session = s, state = state })
        end
      end
    end
  end

  return { lines = lines, nodes = nodes, hl = hl }
end

return M

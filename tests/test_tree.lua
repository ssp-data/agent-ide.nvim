local tree = require('agent-ide.ui.tree')
local highlights = require('agent-ide.ui.highlights')
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local icons = { open = 'v', closed = '>', project = 'P', waiting = 'W', busy = 'B', idle = 'I', parked = '.' }
local projects = {
  { key = '/r/alpha', name = 'alpha', is_git = true, missing = false, activity = 1000, sessions = {
    { id = 's1', title = 'Fix login', activity = 1000 },
    { id = 's2', title = 'Docs', activity = 400, subpath = 'docs' } } },
  { key = '/r/old', name = 'old', is_git = false, missing = true, activity = 100, sessions = { { id = 's3', title = 'X', activity = 100 } } },
}

local function find(t, line, group)
  for _, h in ipairs(t.hl) do
    if h.line == line and h.group == group then return h end
  end
end

T['ago'] = function()
  eq({ tree.ago(1000, 1050), tree.ago(1000, 1000 + 600), tree.ago(1000, 1000 + 7200), tree.ago(1000, 1000 + 3 * 86400) },
    { 'now', '10m', '2h', '3d' })
end

T['collapsed: one line per project with rolled-up state'] = function()
  local t = tree.build(projects, { s2 = { status = 'waiting' } }, {}, 1060, icons)
  eq(t.lines, { '> P alpha  W now', '> P old  . 16m (gone)' })
  eq(t.nodes[1].type, 'project')
end

T['expanded: section and all sessions'] = function()
  local t = tree.build(projects, { s1 = { status = 'busy' } }, { ['/r/alpha'] = true }, 1060, icons)
  eq(t.lines, { 'v P alpha  B now', '  v Sessions (2)', '      B Fix login  now', '      . Docs  [docs]  11m', '> P old  . 16m (gone)' })
  eq({ t.nodes[3].type, t.nodes[3].session.id, t.nodes[3].state }, { 'session', 's1', 'busy' })
  eq(t.nodes[2], { type = 'section', project = projects[1], key = '/r/alpha/sessions' })
end

T['section can be closed'] = function()
  local t = tree.build(projects, {}, { ['/r/alpha'] = true, ['/r/alpha/sessions'] = false }, 1060, icons)
  eq(#t.lines, 3)
  eq(t.lines[2], '  > Sessions (2)')
end

T['highlights name the state group on the state icon'] = function()
  local t = tree.build(projects, { s1 = { status = 'busy' } }, {}, 1060, icons)
  local groups = vim.tbl_map(function(h) return h.group end, vim.tbl_filter(function(h) return h.line == 1 end, t.hl))
  eq(vim.tbl_contains(groups, 'AgentIdeBusy'), true)
  eq(vim.tbl_contains(groups, 'AgentIdeProject'), true)
end

T['highlight ranges cover project, state, age, gone, section, session'] = function()
  local t = tree.build(projects, { s1 = { status = 'busy' } }, { ['/r/alpha'] = true }, 1060, icons)
  local function text(line, h) return t.lines[line]:sub(h.col_start + 1, h.col_end) end
  eq(text(1, find(t, 1, 'AgentIdeProject')), 'alpha')
  eq(text(1, find(t, 1, 'AgentIdeBusy')), 'B')
  eq(text(1, find(t, 1, 'AgentIdeAge')), 'now')
  eq(text(2, find(t, 2, 'AgentIdeSection')), '  v Sessions (2)')
  eq(text(3, find(t, 3, 'AgentIdeBusy')), 'B')
  eq(text(3, find(t, 3, 'AgentIdeAge')), 'now')
  eq(text(4, find(t, 4, 'AgentIdeParked')), '.')
  eq(text(5, find(t, 5, 'AgentIdeMissing')), ' (gone)')
  eq(text(5, find(t, 5, 'AgentIdeParked')), '.')
end

T['highlight ranges are byte offsets with multi-byte icons'] = function()
  local mb = { open = '▾', closed = '▸', project = '', waiting = '', busy = '●', idle = '○', parked = '·' }
  local t = tree.build(projects, { s1 = { status = 'busy' } }, {}, 1060, mb)
  local h = find(t, 1, 'AgentIdeProject')
  eq(t.lines[1]:sub(h.col_start + 1, h.col_end), 'alpha')
  local b = find(t, 1, 'AgentIdeBusy')
  eq(t.lines[1]:sub(b.col_start + 1, b.col_end), '●')
  local a = find(t, 1, 'AgentIdeAge')
  eq(t.lines[1]:sub(a.col_start + 1, a.col_end), 'now')
end

T['session title is one line, not truncated'] = function()
  local long = string.rep('x', 300)
  local p = { { key = '/r/a', name = 'a', is_git = true, missing = false, activity = 1000, sessions = {
    { id = 's', title = 'one\ntwo\r\nthree ' .. long, activity = 1000 } } } }
  local t = tree.build(p, {}, { ['/r/a'] = true }, 1000, icons)
  eq(#t.lines, 3)
  eq(t.lines[3], '      . one two  three ' .. long .. '  now')
  eq(t.lines[3]:find('[\r\n]'), nil)
end

T['empty'] = function()
  local t = tree.build({}, {}, {}, 0, icons)
  eq(t.nodes[1].type, 'hint')
  eq(t.lines, { 'No Claude sessions found' })
  t = tree.build({}, {}, {}, 0, icons, '/p/dir')
  eq(t.lines, { 'No Claude sessions found in /p/dir' })
end

T['highlights.setup defines all groups and is idempotent'] = function()
  highlights.setup()
  highlights.setup()
  for _, g in ipairs({ 'Project', 'Waiting', 'Busy', 'Idle', 'Parked', 'Missing', 'Age', 'Section' }) do
    eq(vim.fn.hlexists('AgentIde' .. g), 1)
  end
end

return T

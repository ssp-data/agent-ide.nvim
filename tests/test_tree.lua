local tree = require('agent-ide.ui.tree')
local live = require('agent-ide.live')
local highlights = require('agent-ide.ui.highlights')
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local icons = { open = 'v', closed = '>', project = 'P', waiting = 'W', busy = 'B', idle = 'I', parked = '.',
  done = 'D', failed = 'F', new = '+' }

-- State lookup as the drawer supplies it, here from a live map only.
local function lookup(m) return function(id) return live.state_of(m, id) end end
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
  local t = tree.build(projects, lookup({ s2 = { status = 'waiting' } }), {}, 1060, icons)
  eq(t.lines, { '> P alpha  W now', '> P old  . 16m (gone)' })
  eq(t.nodes[1].type, 'project')
end

T['expanded: section and all sessions'] = function()
  local t = tree.build(projects, lookup({ s1 = { status = 'busy' } }), { ['/r/alpha'] = true }, 1060, icons)
  eq(t.lines, { 'v P alpha  B now', '    + New session', '  v Sessions (2)', '      B Fix login  now', '      . Docs  [docs]  11m',
    '> P old  . 16m (gone)' })
  eq({ t.nodes[4].type, t.nodes[4].session.id, t.nodes[4].state }, { 'session', 's1', 'busy' })
  eq(t.nodes[2], { type = 'new', project = projects[1] })
  eq(t.nodes[3], { type = 'section', project = projects[1], key = '/r/alpha/sessions' })
end

T['section can be closed'] = function()
  local t = tree.build(projects, lookup({}), { ['/r/alpha'] = true, ['/r/alpha/sessions'] = false }, 1060, icons)
  eq(#t.lines, 4)
  eq(t.lines[2], '    + New session')
  eq(t.lines[3], '  > Sessions (2)')
end

T['highlights name the state group on the state icon'] = function()
  local t = tree.build(projects, lookup({ s1 = { status = 'busy' } }), {}, 1060, icons)
  local groups = vim.tbl_map(function(h) return h.group end, vim.tbl_filter(function(h) return h.line == 1 end, t.hl))
  eq(vim.tbl_contains(groups, 'AgentIdeBusy'), true)
  eq(vim.tbl_contains(groups, 'AgentIdeProject'), true)
end

T['highlight ranges cover project, state, age, gone, section, session'] = function()
  local t = tree.build(projects, lookup({ s1 = { status = 'busy' } }), { ['/r/alpha'] = true }, 1060, icons)
  local function text(line, h) return t.lines[line]:sub(h.col_start + 1, h.col_end) end
  eq(text(1, find(t, 1, 'AgentIdeProject')), 'alpha')
  eq(text(1, find(t, 1, 'AgentIdeBusy')), 'B')
  eq(text(1, find(t, 1, 'AgentIdeAge')), 'now')
  eq(text(3, find(t, 3, 'AgentIdeSection')), '  v Sessions (2)')
  eq(text(4, find(t, 4, 'AgentIdeBusy')), 'B')
  eq(text(4, find(t, 4, 'AgentIdeAge')), 'now')
  eq(text(5, find(t, 5, 'AgentIdeParked')), '.')
  eq(text(6, find(t, 6, 'AgentIdeMissing')), ' (gone)')
  eq(text(6, find(t, 6, 'AgentIdeParked')), '.')
end

T['highlight ranges are byte offsets with multi-byte icons'] = function()
  local mb = { open = '▾', closed = '▸', project = '', waiting = '', busy = '●', idle = '○', parked = '·',
    done = '✔', failed = '✖', new = '+' }
  local t = tree.build(projects, lookup({ s1 = { status = 'busy' } }), {}, 1060, mb)
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
  local t = tree.build(p, lookup({}), { ['/r/a'] = true }, 1000, icons)
  eq(#t.lines, 4)
  eq(t.lines[4], '      . one two  three ' .. long .. '  now')
  eq(t.lines[4]:find('[\r\n]'), nil)
end

T['empty'] = function()
  local t = tree.build({}, lookup({}), {}, 0, icons)
  eq(t.nodes[1].type, 'hint')
  eq(t.lines, { 'No Claude sessions found' })
  t = tree.build({}, lookup({}), {}, 0, icons, '/p/dir')
  eq(t.lines, { 'No Claude sessions found in /p/dir' })
end

T['highlights.setup defines all groups and is idempotent'] = function()
  highlights.setup()
  highlights.setup()
  for _, g in ipairs({ 'Project', 'Waiting', 'Busy', 'Idle', 'Parked', 'Missing', 'Age', 'Section', 'Done', 'Failed' }) do
    eq(vim.fn.hlexists('AgentIde' .. g), 1)
  end
end

T['state lookup decides session icons; roll-up ranks waiting > failed > done > busy > idle > parked'] = function()
  local p = { { key = '/r/a', name = 'a', is_git = true, missing = false, activity = 1000, sessions = {
    { id = 'a', title = 'A', activity = 1000 }, { id = 'b', title = 'B', activity = 900 },
    { id = 'c', title = 'C', activity = 800 } } } }
  local function roll(states)
    local t = tree.build(p, function(id) return states[id] or 'parked' end, { ['/r/a'] = true }, 1000, icons)
    return t.lines[1]:match('^v P a  (%S+) ')
  end
  eq(roll({ a = 'idle', b = 'busy' }), 'B')
  eq(roll({ a = 'done', b = 'busy' }), 'D')
  eq(roll({ a = 'done', b = 'failed', c = 'busy' }), 'F')
  eq(roll({ a = 'waiting', b = 'failed' }), 'W')
  eq(roll({ a = 'idle' }), 'I')
  eq(roll({}), '.')
  local t = tree.build(p, function(id) return ({ a = 'done', b = 'failed' })[id] or 'idle' end, { ['/r/a'] = true }, 1000, icons)
  eq({ t.lines[4], t.lines[5], t.lines[6] }, { '      D A  now', '      F B  1m', '      I C  3m' })
  eq({ find(t, 4, 'AgentIdeDone') ~= nil, find(t, 5, 'AgentIdeFailed') ~= nil, t.nodes[5].state }, { true, true, 'failed' })
end

return T

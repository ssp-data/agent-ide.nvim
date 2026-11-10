-- The generic drawer sections hook: tree.build with extra rows, and the registry.
local tree = require('agent-ide.ui.tree')
local sections = require('agent-ide.ui.sections')
local eq = MiniTest.expect.equality

local icons = { open = 'v', closed = '>', project = 'P', waiting = 'W', busy = 'B', idle = 'I', parked = '.',
  done = 'D', failed = 'F', new = '+' }
local projects = {
  { key = '/r/alpha', name = 'alpha', is_git = true, activity = 1000, sessions = { { id = 's1', title = 'Fix', activity = 1000 } } },
  { key = '/r/beta', name = 'beta', is_git = false, activity = 900, sessions = { { id = 's2', title = 'B', activity = 900 } } },
}
local function parked() return 'parked' end

local T = MiniTest.new_set({ hooks = { pre_case = function() sections._reset() end, post_case = function() sections._reset() end } })

T['tree.build without the hook is unchanged'] = function()
  local a = tree.build(projects, parked, { ['/r/alpha'] = true }, 1000, icons)
  local b = tree.build(projects, parked, { ['/r/alpha'] = true }, 1000, icons, nil, nil, nil)
  eq(a, b)
end

T['extra rows come after Sessions, suffix on the project row, highlights offset'] = function()
  local seen = {}
  local function extra(p, ctx)
    seen[#seen + 1] = { p.key, ctx.open }
    if p.key ~= '/r/alpha' then return nil end
    return { { pieces = { { '  ' }, { 'Extra (1)', 'AgentIdeSection' } }, node = { type = 'x', id = 'x1', project = p } } },
      { { ' feat', 'AgentIdeBranch' } }
  end
  local t = tree.build(projects, parked, { ['/r/alpha'] = true }, 1000, icons, nil, nil, extra)
  eq(t.lines, { 'v P alpha  . now feat', '    + New session', '  v Sessions (1)', '      . Fix  now', '  Extra (1)',
    '> P beta  . 1m' })
  eq(t.nodes[5].id, 'x1')
  eq(seen, { { '/r/alpha', true }, { '/r/beta', false } })
  local found
  for _, h in ipairs(t.hl) do
    if h.line == 5 then found = t.lines[5]:sub(h.col_start + 1, h.col_end) end
    if h.line == 1 and h.group == 'AgentIdeBranch' then eq(t.lines[1]:sub(h.col_start + 1, h.col_end), ' feat') end
  end
  eq(found, 'Extra (1)')
end

T['rows of a collapsed project are not shown'] = function()
  local function extra(p) return { { pieces = { { 'row' } }, node = { type = 'x', id = 'r', project = p } } } end
  local t = tree.build(projects, parked, {}, 1000, icons, nil, nil, extra)
  eq(t.lines, { '> P alpha  . now', '> P beta  . 1m' })
end

T['registry: providers in registration order, functions and tables, replace by name'] = function()
  local calls = {}
  sections.register('a', function(p) return { { pieces = { { 'a ' .. p.name } }, node = { type = 'a', id = 'a' } } } end)
  sections.register('b', { rows = function(p, ctx)
    return { { pieces = { { 'b' } }, node = { type = 'b', id = 'b' } } }, { { ' sb' } }
  end, setup = function() calls[#calls + 1] = 'setup' end, refresh = function() calls[#calls + 1] = 'refresh' end,
    focus = function() calls[#calls + 1] = 'focus' end })
  local rows, suffix = sections.collect(projects[1], { open = true })
  eq(vim.tbl_map(function(r) return r.pieces[1][1] end, rows), { 'a alpha', 'b' })
  eq(suffix, { { ' sb' } })
  sections.register('a', function() return nil end)
  rows = sections.collect(projects[1], { open = true })
  eq(#rows, 1)
  sections.setup()
  sections.refresh()
  sections.focus()
  eq(calls, { 'setup', 'refresh', 'focus' })
end

T['registry: a provider error is reported once and does not break the drawer'] = function()
  local notes = {}
  local orig = vim.notify
  vim.notify = function(m) notes[#notes + 1] = m end
  sections.register('bad', function() error('boom') end)
  sections.register('good', function() return { { pieces = { { 'ok' } }, node = { type = 'g', id = 'g' } } } end)
  local rows = sections.collect(projects[1], { open = true })
  sections.collect(projects[1], { open = true })
  vim.wait(200, function() return #notes > 0 end, 5)
  vim.wait(20)
  vim.notify = orig
  eq(#rows, 1)
  eq(#notes, 1)
end

return T

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
  local day = 86400
  eq({ tree.ago(0, 59 * day), tree.ago(0, 60 * day), tree.ago(0, 14 * 30 * day), tree.ago(0, 719 * day),
    tree.ago(0, 720 * day), tree.ago(0, 1100 * day) }, { '59d', '2mo', '14mo', '23mo', '2y', '3y' })
end

T['collapsed: one line per project with rolled-up state'] = function()
  local t = tree.build(projects, lookup({ s2 = { status = 'waiting' } }), {}, 1060, icons)
  eq(t.lines, { '> P alpha  W input (1) now', '> P old (folder missing)  . 16m' })
  eq(t.nodes[1].type, 'project')
end

T['expanded: section and all sessions'] = function()
  local t = tree.build(projects, lookup({ s1 = { status = 'busy' } }), { ['/r/alpha'] = true }, 1060, icons)
  eq(t.lines, { 'v P alpha  B now', '    + New session', '  v Sessions (2)', '      B Fix login  now', '      . docs/ · Docs  11m',
    '> P old (folder missing)  . 16m' })
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
  eq(text(6, find(t, 6, 'AgentIdeMissing')), ' (folder missing)')
  -- a parked project: its name is dimmed like its state icon
  local parked = vim.tbl_filter(function(h) return h.line == 6 and h.group == 'AgentIdeParked' end, t.hl)
  eq(vim.tbl_map(function(h) return text(6, h) end, parked), { 'old', '.' })
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
  -- the mock's colours: failed red of its own, waiting bold violet, sections like directories
  local function hl(name) return vim.api.nvim_get_hl(0, { name = name, link = false }) end
  eq(('#%06x'):format(hl('AgentIdeFailed').fg), '#f7768e')
  eq(('#%06x'):format(hl('AgentIdeDone').fg), '#ff9e64')
  eq({ ('#%06x'):format(hl('AgentIdeWaiting').fg), hl('AgentIdeWaiting').bold }, { '#a277ff', true })
  eq(vim.api.nvim_get_hl(0, { name = 'AgentIdeSection', link = true }).link, 'Directory')
  eq(vim.api.nvim_get_hl(0, { name = 'AgentIdeAge', link = true }).link, 'Comment')
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

-- Width-aware rows ---------------------------------------------------------------------------

local W = vim.fn.strdisplaywidth

local function mixed()
  return { { key = '/r/n', name = 'neomd', is_git = true, missing = false, activity = 1000, sessions = {
    { id = 'a', title = 'Add IDLE support', activity = 1000 },
    { id = 'b', title = 'Shorter signature alias', activity = 940 },
    { id = 'c', title = 'Fix flaky maildir test', activity = 280 },
    { id = 'd', title = 'Bump go-imap', activity = 0 },
    { id = 'e', title = 'Keybinding table', activity = 1000 - 5 * 86400, subpath = 'docs' } } } }
end
local STATES = { a = 'busy', b = 'waiting', c = 'done', d = 'failed', e = 'parked' }
local NOTES = { b = { 'permission: Bash', 'AgentIdeWaiting' }, c = { 'done, unread', 'AgentIdeDone' },
  d = { 'failed: quota', 'AgentIdeFailed' } }

T['rows align the right part to the drawer width; state words in their colour'] = function()
  local t = tree.build(mixed(), function(id) return STATES[id] end, { ['/r/n'] = true }, 1000, icons, nil,
    function(id) return NOTES[id] end, nil, { width = 44 })
  eq(t.lines, {
    'v P neomd                    W input (1) now',
    '    + New session',
    '  v Sessions (5)',
    '      B Add IDLE support                 now',
    '      W Shorter signa…  permission: Bash now',
    '      D Fix flaky maildir…  done, unread 12m',
    '      F Bump go-imap       failed: quota 16m',
    '      . docs/ · Keybinding table          5d',
  })
  for _, i in ipairs({ 1, 4, 5, 6, 7, 8 }) do eq(W(t.lines[i]), 44) end
  local function text(line, h) return t.lines[line]:sub(h.col_start + 1, h.col_end) end
  eq(text(5, find(t, 5, 'AgentIdeWaiting')), 'W')
  local waiting = vim.tbl_filter(function(h) return h.line == 5 and h.group == 'AgentIdeWaiting' end, t.hl)
  eq(vim.tbl_map(function(h) return text(5, h) end, waiting), { 'W', 'permission: Bash' })
  eq(text(7, vim.tbl_filter(function(h) return h.line == 7 and h.group == 'AgentIdeFailed' end, t.hl)[2]), 'failed: quota')
  eq(text(1, find(t, 1, 'AgentIdeWaiting')), 'W')
end

T['a too long left part cuts the title, never the state word or the age'] = function()
  local t = tree.build(mixed(), function(id) return STATES[id] end, { ['/r/n'] = true }, 1000, icons, nil,
    function(id) return NOTES[id] end, nil, { width = 40 })
  eq(t.lines[5], '      W Shorter s…  permission: Bash now')
  eq(t.lines[6], '      D Fix flaky mai…  done, unread 12m')
  for i = 4, 8 do eq(W(t.lines[i]), 40) end
end

T['project row: review (n) for done and failed, icon and age when quiet'] = function()
  local p = mixed()
  local t = tree.build(p, function(id) return ({ c = 'done', d = 'failed' })[id] or 'idle' end, {}, 1000, icons, nil, nil, nil, { width = 30 })
  eq(t.lines[1], '> P neomd     F review (2) now')
  eq(W(t.lines[1]), 30)
  t = tree.build(p, function() return 'idle' end, {}, 1000, icons, nil, nil, nil, { width = 30 })
  eq(t.lines[1], '> P neomd                I now')
end

T['header: title left, key hints right; hints that do not fit are dropped'] = function()
  local header = { title = 'Agents', hints = { 'R refresh', 'glg lazygit', '? help' } }
  local ic = vim.tbl_extend('force', icons, { agents = 'A' })
  local t = tree.build(projects, lookup({}), {}, 1060, ic, nil, nil, nil, { width = 44, header = header })
  eq(t.lines[1], 'A Agents    R refresh · glg lazygit · ? help')
  eq(t.nodes[1], { type = 'header' })
  eq(t.lines[2]:sub(1, 9), '> P alpha')
  t = tree.build(projects, lookup({}), {}, 1060, ic, nil, nil, nil, { width = 30, header = header })
  eq(t.lines[1], 'A Agents             R refresh')
  t = tree.build(projects, lookup({}), {}, 1060, ic, nil, nil, nil, { width = 12, header = header })
  eq(t.lines[1], 'A Agents')
  -- on an empty drawer the header stays above the hint
  t = tree.build({}, lookup({}), {}, 0, ic, nil, nil, nil, { width = 44, header = header })
  eq({ #t.lines, t.nodes[1].type, t.nodes[2].type }, { 2, 'header', 'hint' })
end

T['umlauts, CJK and emoji titles align by display width and cut whole characters'] = function()
  for _, title in ipairs({ 'Übersetzung prüfen für Bäume und Sträucher', '日本語のタイトルはとても長いですね本当に', 'Party 🎉🎉 with 🎉 emoji everywhere 🎉🎉🎉' }) do
    local p = { { key = '/r/a', name = 'a', is_git = false, missing = false, activity = 1000, sessions = {
      { id = 's', title = title, activity = 1000 } } } }
    for _, w in ipairs({ 24, 30, 44, 60 }) do
      local t = tree.build(p, lookup({}), { ['/r/a'] = true }, 1000, icons, nil, nil, nil, { width = w })
      local l = t.lines[4]
      eq({ w, W(l) }, { w, w })
      eq(vim.endswith(l, ' now'), true)
      eq(vim.fn.strchars(l) > 0 and vim.str_utf_pos(l) ~= nil, true)
      eq(vim.fn.byteidx(l, vim.fn.strchars(l)), #l) -- no split character
    end
  end
end

T['a title of 300 characters at width 24: the age stays visible'] = function()
  local p = { { key = '/r/a', name = string.rep('n', 80), is_git = false, missing = false, activity = 1000, sessions = {
    { id = 's', title = string.rep('x', 300), activity = 1000 } } } }
  local t = tree.build(p, lookup({}), { ['/r/a'] = true }, 1000, icons, nil, function() return 'elsewhere' end, nil, { width = 24 })
  eq(t.lines[1], 'v P nnnnnnnnnnnn…  . now')
  eq(t.lines[4], '      . …  elsewhere now')
end

T['a project without sessions'] = function()
  local p = { { key = '/r/e', name = 'empty', is_git = false, missing = false, activity = 1000, sessions = {} } }
  local t = tree.build(p, lookup({}), { ['/r/e'] = true }, 1000, icons, nil, nil, nil, { width = 30 })
  eq(t.lines, { 'v P empty                . now', '    + New session', '  v Sessions (0)' })
end

T['provider rows with a right part are aligned; rows without stay as given'] = function()
  local extra = function()
    return { { pieces = { { '      ' }, { 'M', 'X' }, { ' a/file.lua', nil, fit = true } }, right = { { '+3 −1' } }, node = { type = 'x' } },
      { pieces = { { '      plain row' } }, node = { type = 'y' } } }
  end
  local top = function() return { { pieces = { { 'top' } }, right = { { '9' } }, node = { type = 'z' } } } end
  local t = tree.build(projects, lookup({}), { ['/r/alpha'] = true }, 1060, icons, nil, nil, extra, { width = 30, top = top })
  eq(t.lines[1], 'top                          9')
  eq(t.lines[7], '      M a/file.lua       +3 −1')
  eq(t.lines[8], '      plain row')
end

return T

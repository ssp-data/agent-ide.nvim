-- Commit graph: the parser of `git log --graph` and the pure renderer, from fixture text.
local F = dofile(vim.fn.getcwd() .. '/tests/graph_fixtures.lua')
local parse = require('agent-ide.git_parse')
local render = require('agent-ide.ui.graph_render')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local function graph_of(name)
  local rows = parse.graph(F.out(name))
  local graphs = vim.tbl_map(function(r) return r.graph end, rows)
  return vim.tbl_map(function(c) return (table.concat(c):gsub('%s+$', '')) end, render.cells(graphs)), rows
end

local function build(name, opts)
  local rows, more = parse.graph(F.out(name), opts and opts.limit)
  return render.build(rows, vim.tbl_extend('force', { now = F.NOW + 8 * 60, width = 90, more = more and '… more' or nil }, opts or {})), rows
end

T['parse: commit rows with fields, connector rows'] = function()
  local rows, more = parse.graph(F.out('merge'))
  eq(#rows, 8)
  eq(more, false)
  local m = rows[1]
  eq({ m.graph, m.hash, m.short, m.time, m.author, m.subject, #m.parents },
    { '*   ', F.hash('a1'), 'a1', F.NOW, 'Ana', "Merge branch 'long'", 2 })
  eq(m.refs, { { name = 'main', kind = 'branch' }, { name = 'HEAD', kind = 'head' }, { name = 'origin/main', kind = 'remote' } })
  eq(rows[2], { graph = '|\\' }) -- trailing spaces cut
  eq(rows[7].refs, { { name = 'v0.3.0', kind = 'tag' } })
  eq(rows[8].parents, {}) -- the root commit
end

T['parse: refs with slashes, a remote HEAD left out, tags, detached HEAD and grafted'] = function()
  local rows = parse.graph(F.out('refs'))
  eq(rows[1].refs, { { name = 'feat/retry', kind = 'branch' }, { name = 'HEAD', kind = 'head' },
    { name = 'origin/feat/retry', kind = 'remote' }, { name = 'v1.0/rc1', kind = 'tag' } })
  eq(rows[2].refs, { { name = 'upstream/main', kind = 'remote' }, { name = 'main', kind = 'branch' } })
  rows = parse.graph(F.out('detached'))
  eq(rows[1].refs, { { name = 'HEAD', kind = 'head' } })
  eq(rows[2].refs, { { name = 'main', kind = 'branch' }, { name = 'grafted', kind = 'other' } })
end

T['parse: a subject holding the separators and multi-byte text stays whole'] = function()
  local rows = parse.graph(F.out({ '* @a1\t\t\tfix: a\31b\30c — Übersetzung 日本語' }))
  eq(rows[1].subject, 'fix: a b c — Übersetzung 日本語')
  eq(rows[1].short, 'a1')
end

T['parse: limit cuts after that many commits and tells there are more'] = function()
  local rows, more = parse.graph(F.out('merge'), 3)
  eq(more, true)
  eq(vim.tbl_map(function(r) return r.short or r.graph end, rows), { 'a1', '|\\', 'f1', 'b2' })
  rows, more = parse.graph(F.out('merge'), 6)
  eq({ #rows, more }, { 8, false })
  eq({ parse.graph('') }, { {}, false })
end

T['cells: linear history'] = function()
  eq(graph_of('linear'), { '●', '●', '●' })
end

T['cells: a merge forks with ├─╮ and joins with ├─╯'] = function()
  eq(graph_of('merge'), { '●', '├─╮', '● │', '│ ●', '│ ●', '├─╯', '●', '●' })
end

T['cells: an octopus merge keeps the 1:1 mapping where corners are not certain'] = function()
  eq(graph_of('octopus'), {
    '●───╮', '│╲ ╲ ╲', '● │ │ │', '│ ● │ │', '│ │ ● │', '│ │╱ ╱', '│╱│ │', '│ │ ●', '│ ├─╯', '│╱│', '● │', '├─╯', '●',
  })
end

T['cells: two long-lived branches crossing'] = function()
  eq(graph_of('crossing'), {
    '●', '│ ●', '● │', '│╲│', '● │', '│ ●', '│ ●', '│ │╲', '│ │╱', '│╱│', '│ ●', '● │', '├─╯', '●',
  })
end

T['build: hash, ref badges, subject, age and author aligned at the right edge'] = function()
  local t = build('merge')
  local l = t.lines[1]
  eq(vim.fn.strdisplaywidth(l), 90)
  eq(l:match('^ ●   a1 main HEAD origin/main Merge branch \'long\' +8m  Ana$') ~= nil, true)
  eq(t.nodes[1].type, 'commit')
  eq(t.nodes[2].type, 'connector')
  -- highlights: lanes by column, badges by kind, the hash and the age dim
  local groups = {}
  for _, h in ipairs(t.hl) do
    if h.line == 1 then groups[#groups + 1] = { l:sub(h.col_start + 1, h.col_end), h.group } end
  end
  eq(groups, { { '●', 'AgentIdeGraph1' }, { 'a1', 'AgentIdeGraphHash' }, { 'main', 'AgentIdeGraphBranch' },
    { 'HEAD', 'AgentIdeGraphHead' }, { 'origin/main', 'AgentIdeGraphRemote' }, { '8m', 'AgentIdeAge' }, { 'Ana', 'AgentIdeAge' } })
  local fork = {}
  for _, h in ipairs(t.hl) do
    if h.line == 2 then fork[#fork + 1] = { t.lines[2]:sub(h.col_start + 1, h.col_end), h.group } end
  end
  eq(fork, { { '├', 'AgentIdeGraph1' }, { '─', 'AgentIdeGraph2' }, { '╮', 'AgentIdeGraph2' } })
  eq(build('merge').lines[7]:match('v0%.3%.0 release notes') ~= nil, true)
end

T['build: a long multi-byte subject is cut with … and the age and author stay'] = function()
  local subject = string.rep('Übersetzung 日本語 ', 10)
  local rows = parse.graph(F.out({ '* @a1\t\t\t' .. subject }))
  local t = render.build(rows, { now = F.NOW + 3 * 3600, width = 60 })
  eq(vim.fn.strdisplaywidth(t.lines[1]), 60)
  eq(t.lines[1]:match('… +3h  Ana$') ~= nil, true)
end

T['build: expanded commit files under the commit, lanes going on; loading; the more line'] = function()
  local files = { { status = 'M', path = 'src/retry.lua', added = 3, removed = 1 }, { status = 'A', path = 'ünï.txt', added = 2, removed = 0 } }
  local t = build('merge', { open = { [F.hash('f1')] = files, [F.hash('b1')] = false }, limit = 5 })
  eq(t.nodes[4].type, 'file')
  eq(t.nodes[4].file.path, 'src/retry.lua')
  eq(t.nodes[4].index, 1)
  eq(t.lines[4]:match('^ │ │   M src/retry%.lua +%+3 −1$') ~= nil, true)
  eq(t.lines[5]:match('^ │ │   A ünï%.txt +%+2$') ~= nil, true)
  eq(vim.fn.strdisplaywidth(t.lines[4]), 90)
  eq(t.lines[8], ' │ │   loading…')
  eq(t.nodes[#t.lines], { type = 'more' })
  eq(t.lines[#t.lines], ' … more')
end

T['build: states'] = function()
  eq(render.build({}, { now = 0, state = 'empty' }).lines, { ' no commits yet' })
  eq(render.build({}, { now = 0, state = 'error', message = 'fatal: bad' }).lines, { ' fatal: bad' })
  eq(render.build({}, { now = 0, state = 'loading' }).lines, { ' loading…' })
end

T['build: the root commit has no lane below its files'] = function()
  local files = { { status = 'A', path = 'a', added = 1, removed = 0 } }
  local t = build('linear', { open = { [F.hash('c3')] = files } })
  eq(t.lines[4]:match('^     A a ') ~= nil, true)
end

return T

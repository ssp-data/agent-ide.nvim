-- The commit graph view end to end: a child Neovim against a temporary repository per case.
local R = dofile(vim.fn.getcwd() .. '/tests/git_repo.lua')
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()

local ICONS = { open = 'v', closed = '>', project = 'P', waiting = 'W', busy = 'B', idle = 'I', parked = '.',
  done = 'D', failed = 'F', new = '+' }
local ID = '33333333-3333-4333-8333-333333333333'

local tmp, repo, projects

-- main: init (a.txt), "main work"; feat: "feat one" (b.txt), "feat two"; main merges feat, tag v1.
local function make_repo()
  local saved = { R.ENV.GIT_AUTHOR_DATE, R.ENV.GIT_COMMITTER_DATE }
  -- a minute apart, so `--date-order` gives one order
  local function at(min) R.ENV.GIT_AUTHOR_DATE = ('2026-01-01T00:%02d:00Z'):format(min); R.ENV.GIT_COMMITTER_DATE = R.ENV.GIT_AUTHOR_DATE end
  repo = R.init(tmp .. '/r')
  R.write(repo, 'a.txt', { 'a' })
  at(1); R.commit(repo, 'init')
  R.git(repo, { 'checkout', '-q', '-b', 'feat' })
  R.write(repo, 'b.txt', { 'b' })
  at(2); R.commit(repo, 'feat one')
  R.write(repo, 'b.txt', { 'b', 'bb' })
  at(3); R.commit(repo, 'feat two')
  R.git(repo, { 'checkout', '-q', 'main' })
  R.write(repo, 'a.txt', { 'a', 'aa' })
  at(4); R.commit(repo, 'main work')
  at(5); R.git(repo, { 'merge', '-q', '--no-ff', '--no-edit', '-m', 'Merge feat', 'feat' })
  R.git(repo, { 'tag', 'v1' })
  R.ENV.GIT_AUTHOR_DATE, R.ENV.GIT_COMMITTER_DATE = saved[1], saved[2]
end

local function write_session(cwd)
  local dir = projects .. '/-r'
  vim.fn.mkdir(dir, 'p')
  vim.fn.writefile({ vim.json.encode({ type = 'user', uuid = 'z1', cwd = cwd or repo, message = { role = 'user', content = 'Work on it' } }) },
    dir .. '/' .. ID .. '.jsonl')
end

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    tmp = R.tmp()
    projects = tmp .. '/projects'
    make_repo()
    write_session()
  end,
  post_case = function()
    child.stop()
    vim.fn.delete(tmp, 'rf')
  end,
  post_once = function() child.stop() end,
} })

local function start(opts)
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[
    local env, opts = ...
    for k, v in pairs(env) do vim.uv.os_setenv(k, v) end
    vim.env.TMUX = nil
    vim.o.columns, vim.o.lines = 200, 50
    _G.notes = {}
    vim.notify = function(msg) table.insert(_G.notes, msg) end
    require('agent-ide').setup(opts)
  ]], { R.ENV, vim.tbl_deep_extend('force', {
    projects_dir = projects,
    helper = { enabled = false },
    live = { interval_ms = 50, cmd = { 'echo', '[]' } },
    icons_style = 'plain', icons = ICONS,
  }, opts or {}) })
end

local function wait_for(cond, what, ms)
  if not vim.wait(ms or 5000, cond, 20) then error('timed out waiting for ' .. what, 2) end
end

local function has_line(lines, text)
  for i, l in ipairs(lines) do
    if l:find(text, 1, true) then return i end
  end
end

local function drawer_lines()
  return child.lua_get([[(function()
    local s = require('agent-ide.ui.drawer').state()
    return s.buf and vim.api.nvim_buf_get_lines(s.buf, 0, -1, false) or {}
  end)()]])
end

local function press_on(text, keys)
  wait_for(function() return has_line(drawer_lines(), text) ~= nil end, 'drawer line ' .. text)
  child.lua('local s = require("agent-ide.ui.drawer").state(); vim.api.nvim_set_current_win(s.win); vim.api.nvim_win_set_cursor(s.win, { ..., 0 })',
    { has_line(drawer_lines(), text) })
  child.type_keys(keys or '<CR>')
end

-- The graph view as seen: nil when closed.
local function graph()
  return child.lua_get([[(function()
    local g = require('agent-ide.ui.graph').state()
    if not g or not vim.api.nvim_buf_is_valid(g.buf) then return vim.NIL end
    local w = vim.fn.win_findbuf(g.buf)[1]
    local out = { root = g.root, state = g.state, lines = vim.api.nvim_buf_get_lines(g.buf, 0, -1, false), shown = w ~= nil,
      focused = w ~= nil and vim.api.nvim_get_current_win() == w }
    if w then
      out.cursor = vim.api.nvim_win_get_cursor(w)[1]
      out.winbar = vim.wo[w].winbar
    end
    return out
  end)()]])
end

local function graph_line(text)
  local g = graph()
  return g ~= vim.NIL and has_line(g.lines, text) or nil
end

local function cursor_on(text)
  wait_for(function() return graph_line(text) ~= nil end, 'graph line ' .. text)
  child.lua([[local g = require('agent-ide.ui.graph').state()
    local w = vim.fn.win_findbuf(g.buf)[1]
    vim.api.nvim_set_current_win(w)
    vim.api.nvim_win_set_cursor(w, { ..., 0 })]], { graph_line(text) })
end

local function open_graph()
  child.lua('require("agent-ide").toggle()')
  press_on(' r  ', 'G')
  wait_for(function() local g = graph(); return g ~= vim.NIL and g.state == 'ok' end, 'graph')
end

local function rev(r) return vim.trim(R.git(repo, { 'rev-parse', r })) end

T['gG on the project row: graph of every branch with refs, a read-only scratch buffer, focused'] = function()
  start()
  open_graph()
  local g = graph()
  eq({ g.root, g.focused, g.winbar }, { repo, true, 'r · graph · all branches' })
  local short = rev('HEAD'):sub(1, 7)
  eq(g.lines[1]:match('^ ●   ' .. short .. ' main HEAD v1 Merge feat +%S+  Test$') ~= nil, true)
  eq(g.lines[2], ' ├─╮')
  for _, s in ipairs({ 'main work', 'feat two', 'feat one', 'init' }) do eq({ s, graph_line(s) ~= nil }, { s, true }) end
  eq(graph_line('feat HEAD') == nil and graph_line(' feat feat two') ~= nil, true) -- the branch badge
  eq(child.lua_get([[(function()
    local g = require('agent-ide.ui.graph').state()
    local w = vim.fn.win_findbuf(g.buf)[1]
    local b = g.buf
    return { vim.bo[b].buftype, vim.bo[b].filetype, vim.bo[b].modifiable, vim.bo[b].swapfile, vim.bo[b].bufhidden,
      vim.wo[w].wrap, vim.wo[w].cursorline, #vim.api.nvim_buf_get_extmarks(b, -1, 0, -1, {}) > 10 }
  end)()]]), { 'nofile', 'agent-ide-graph', false, false, 'wipe', false, true, true })
  -- the line ends at the window's right edge
  eq(child.lua_get('vim.fn.strdisplaywidth(vim.api.nvim_get_current_line()) == vim.api.nvim_win_get_width(0)'), true)
end

T['<CR> lists a commit\'s files; <CR> on a file opens its diff; closing it comes back here'] = function()
  start()
  open_graph()
  cursor_on('feat two')
  child.type_keys('<CR>')
  wait_for(function() return graph_line('M b.txt') ~= nil end, 'files of feat two')
  local fl = graph_line('M b.txt')
  eq(graph().lines[fl]:match('M b%.txt +%+1$') ~= nil, true)
  -- the merge commit: its files against the first parent
  cursor_on('Merge feat')
  child.type_keys('<CR>')
  wait_for(function() return graph_line('A b.txt') ~= nil end, 'files of the merge')
  child.type_keys('<CR>') -- closes it again
  wait_for(function() return graph_line('A b.txt') == nil end, 'merge files closed')
  cursor_on('M b.txt')
  child.type_keys('<CR>')
  wait_for(function() return child.lua_get('(function() local d = require("agent-ide.ui.diff").state(); return d ~= nil and d.shown ~= nil end)()') end, 'diff')
  local d = child.lua_get([[(function()
    local d = require('agent-ide.ui.diff').state()
    local l, r = vim.api.nvim_win_get_buf(d.left), vim.api.nvim_win_get_buf(d.right)
    return { mode = d.mode, hash = d.commit.hash, left = vim.api.nvim_buf_get_lines(l, 0, -1, false), right = vim.api.nvim_buf_get_lines(r, 0, -1, false) }
  end)()]])
  eq(d, { mode = 'commit', hash = rev('feat'), left = { 'b' }, right = { 'b', 'bb' } })
  eq(graph().shown, false)
  child.lua('require("agent-ide.ui.diff").close()')
  wait_for(function() local g = graph(); return g ~= vim.NIL and g.shown end, 'graph back')
  local g = graph()
  eq({ g.cursor, g.lines[g.cursor]:find('M b.txt', 1, true) ~= nil, g.winbar }, { fl, true, 'r · graph · all branches' })
  eq(child.lua_get('vim.bo[require("agent-ide.ui.graph").state().buf].bufhidden'), 'wipe')
end

T['the root commit\'s file diff: an empty left side'] = function()
  start()
  open_graph()
  cursor_on(' init ')
  child.type_keys('<CR>')
  cursor_on('A a.txt')
  child.type_keys('<CR>')
  wait_for(function() return child.lua_get('(function() local d = require("agent-ide.ui.diff").state(); return d ~= nil and d.shown ~= nil end)()') end, 'diff')
  eq(child.lua_get('vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(require("agent-ide.ui.diff").state().left), 0, -1, false)'), { '' })
end

T[']] / [[ step over commits, a: current branch only, y yanks the full hash, glg, help'] = function()
  start()
  open_graph()
  cursor_on('Merge feat')
  child.type_keys('<CR>')
  wait_for(function() return graph_line('A b.txt') ~= nil end, 'files')
  child.type_keys(']]')
  eq(graph().lines[graph().cursor]:find('main work', 1, true) ~= nil, true) -- over the files and the connector
  child.type_keys('2]]')
  eq(graph().lines[graph().cursor]:find('feat one', 1, true) ~= nil, true)
  child.type_keys('[[')
  eq(graph().lines[graph().cursor]:find('feat two', 1, true) ~= nil, true)
  child.type_keys('y')
  eq(child.lua_get('vim.fn.getreg(\'"\')'), rev('feat'))
  eq(child.lua_get('_G.notes[#_G.notes]'), 'Agent-IDE: yanked ' .. rev('feat'))
  child.lua('require("agent-ide.ui.lazygit").open = function(root) _G.lg = root end')
  child.type_keys('glg')
  eq(child.lua_get('_G.lg'), repo)
  -- a: the current branch only (feat checked out: main's own commits go)
  R.git(repo, { 'checkout', '-q', 'feat' })
  child.type_keys('a')
  wait_for(function() return graph_line('main work') == nil end, 'current branch only')
  eq({ graph().winbar, graph_line('feat two') ~= nil, graph_line('Merge feat') }, { 'r · graph · current branch', true, nil })
  eq(graph().lines[graph().cursor]:find('feat two', 1, true) ~= nil, true) -- still on the same commit
  child.type_keys('a')
  wait_for(function() return graph_line('main work') ~= nil end, 'all branches again')
  child.type_keys('g?')
  local help = child.lua_get("vim.api.nvim_buf_get_lines(require('agent-ide.ui.help')._state().lbuf, 0, -1, false)")
  for _, k in ipairs({ '<CR>', ']]', '[[', 'a ', 'R ', 'L ', 'y ', 'glg', 'q ', 'g?' }) do
    eq({ k, has_line(vim.tbl_map(function(l) return l .. ' ' end, help), k) ~= nil }, { k, true })
  end
  child.type_keys('<Esc>', 'q')
  eq(child.lua_get('vim.fn.maparg("?", "n", false, true).buffer'), vim.NIL) -- ? stays backward search
end

T['L loads more when the limit was hit'] = function()
  start({ git = { graph_limit = 2 } })
  open_graph()
  local g = graph()
  eq(g.lines[#g.lines], ' … more (press L to load 2 more)')
  eq(graph_line('feat one'), nil)
  child.type_keys('L')
  wait_for(function() return graph_line('feat one') ~= nil end, 'two more commits')
  child.type_keys('L')
  wait_for(function() return graph_line(' init ') ~= nil end, 'all of them')
  g = graph()
  eq(g.lines[#g.lines]:find('more', 1, true), nil)
  child.type_keys('L')
  eq(child.lua_get('_G.notes[#_G.notes]'), 'Agent-IDE: all commits are shown')
end

T['an invalidated cache reloads the graph: the cursor stays on its commit, focus stays'] = function()
  start()
  open_graph()
  cursor_on('feat two')
  -- focus elsewhere (the drawer), then a new commit and the drawer's refresh signal
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.drawer").state().win)')
  R.write(repo, 'c.txt', { 'c' })
  R.commit(repo, 'after the turn')
  child.lua('require("agent-ide.git_cache").invalidate(...)', { repo })
  wait_for(function() return graph_line('after the turn') ~= nil end, 'reloaded')
  local g = graph()
  eq(g.lines[g.cursor]:find('feat two', 1, true) ~= nil, true)
  eq(child.lua_get('vim.api.nvim_get_current_win() == require("agent-ide.ui.drawer").state().win'), true)
  -- R in the graph reloads too
  R.write(repo, 'c.txt', { 'c', 'd' })
  R.commit(repo, 'second turn')
  cursor_on('feat two')
  child.type_keys('R')
  wait_for(function() return graph_line('second turn') ~= nil end, 'R')
  eq(graph().lines[graph().cursor]:find('feat two', 1, true) ~= nil, true)
end

T['q returns to the chat that was open; the buffer is wiped'] = function()
  start()
  child.lua('require("agent-ide").toggle()')
  press_on(' r  ')
  press_on('Work on it')
  wait_for(function() return child.lua_get('require("agent-ide.ui.chat")._windows().prompt ~= nil') end, 'chat')
  press_on('Work on it', 'G') -- a session row
  wait_for(function() local g = graph(); return g ~= vim.NIL and g.state == 'ok' end, 'graph')
  eq(child.lua_get('require("agent-ide.ui.chat")._windows().prompt'), vim.NIL) -- the prompt made room
  local buf = child.lua_get('require("agent-ide.ui.graph").state().buf')
  child.type_keys('q')
  eq(graph(), vim.NIL)
  wait_for(function() return child.lua_get('require("agent-ide.ui.chat")._windows().prompt ~= nil') end, 'chat back')
  eq(child.lua_get('(vim.b[vim.api.nvim_win_get_buf(require("agent-ide.ui.chat")._windows().transcript)].agent_ide_kind or "") .. "/" .. (vim.b[vim.api.nvim_win_get_buf(require("agent-ide.ui.chat")._windows().transcript)].agent_ide_session or "")'),
    'chat/' .. ID)
  eq(child.lua_get('vim.api.nvim_buf_is_valid(...)', { buf }), false)
end

T[':AgentsGraph: the chat\'s repository; an empty repository; a folder outside git'] = function()
  start()
  child.lua('require("agent-ide").toggle()')
  press_on(' r  ')
  press_on('Work on it')
  wait_for(function() return child.lua_get('require("agent-ide.ui.chat")._windows().prompt ~= nil') end, 'chat')
  child.lua('vim.cmd("AgentsGraph")')
  wait_for(function() local g = graph(); return g ~= vim.NIL and g.state == 'ok' end, 'graph of the chat')
  eq(graph().root, repo)
  child.type_keys('q')
  local empty = R.init(tmp .. '/empty')
  child.lua('vim.cmd.tabnew(); vim.cmd.tcd(...); vim.cmd("AgentsGraph")', { empty })
  wait_for(function() local g = graph(); return g ~= vim.NIL and g.state == 'empty' end, 'empty repository')
  eq(graph().lines, { ' no commits yet' })
  child.type_keys('q')
  local plain = tmp .. '/plain'
  vim.fn.mkdir(plain, 'p')
  child.lua('vim.cmd.tabnew(); vim.cmd.tcd(...); vim.cmd("AgentsGraph")', { plain })
  wait_for(function() return child.lua_get('_G.notes[#_G.notes] or ""'):find('not a git repository', 1, true) ~= nil end, 'notice')
  eq(graph(), vim.NIL)
end

T['gG on a worktree session: that worktree\'s graph; a narrower window re-renders'] = function()
  local wt = tmp .. '/wt'
  R.git(repo, { 'worktree', 'add', '-q', '-b', 'wtb', wt, 'main' })
  R.write(wt, 'w.txt', { 'w' })
  R.commit(wt, 'in the worktree')
  vim.fn.writefile({ vim.json.encode({ type = 'user', uuid = 'w1', cwd = wt, message = { role = 'user', content = 'Worktree job' } }) },
    projects .. '/-r/44444444-4444-4444-8444-444444444444.jsonl')
  start()
  child.lua('require("agent-ide").toggle()')
  press_on(' r  ')
  press_on('Worktree job', 'G')
  wait_for(function() local g = graph(); return g ~= vim.NIL and g.state == 'ok' end, 'graph')
  eq(graph().root, wt)
  eq(graph().lines[1]:find('wtb HEAD in the worktree', 1, true) ~= nil, true) -- HEAD of the worktree
  -- the window gets narrower: lines follow its width (debounced)
  child.lua('vim.cmd("vertical resize 70")')
  wait_for(function()
    return child.lua_get('vim.fn.strdisplaywidth(vim.api.nvim_buf_get_lines(require("agent-ide.ui.graph").state().buf, 0, 1, false)[1])') == 70
  end, 'resized lines')
end

T['a detached HEAD and a git error'] = function()
  R.git(repo, { 'checkout', '-q', '--detach', 'HEAD~1' })
  start()
  open_graph()
  child.type_keys('a')
  wait_for(function() local g = graph(); return g ~= vim.NIL and g.winbar:find('current', 1, true) ~= nil and graph_line('Merge feat') == nil end, 'detached, current only')
  eq(graph().lines[1]:find(' HEAD main work', 1, true) ~= nil, true)
  -- a broken repository: the error's first line, R retries
  local head = R.git(repo, { 'rev-parse', 'HEAD' })
  vim.fn.writefile({ 'garbage' }, repo .. '/.git/HEAD')
  child.type_keys('R')
  wait_for(function() return graph().state == 'error' end, 'error')
  eq(#graph().lines, 1)
  vim.fn.writefile({ vim.trim(head) }, repo .. '/.git/HEAD')
  child.type_keys('R')
  wait_for(function() return graph().state == 'ok' end, 'retried')
end

return T

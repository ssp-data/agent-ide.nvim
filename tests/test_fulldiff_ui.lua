-- The full diff view end to end: a child Neovim against a temporary repository per case.
local R = dofile(vim.fn.getcwd() .. '/tests/git_repo.lua')
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()

local ICONS = { open = 'v', closed = '>', project = 'P', waiting = 'W', busy = 'B', idle = 'I', parked = '.',
  done = 'D', failed = 'F', new = '+' }
local ID = '44444444-4444-4444-8444-444444444444'

local tmp, repo, projects

-- main: a.txt, 'sp ace "q".txt'; feat: "feat one" (a.txt + rename), "feat two" (img.png); then an
-- uncommitted edit of a.txt and untracked new.txt.
local function make_repo()
  repo = R.init(tmp .. '/r')
  R.write(repo, 'a.txt', { 'a' })
  R.write(repo, 'sp ace "q".txt', { '1', '2', '3', '4' })
  R.commit(repo, 'init')
  R.git(repo, { 'checkout', '-q', '-b', 'feat' })
  R.write(repo, 'a.txt', { 'a', 'aa' })
  vim.fn.mkdir(repo .. '/dir', 'p')
  R.git(repo, { 'mv', 'sp ace "q".txt', 'dir/sp ace "q".txt' })
  R.write(repo, 'dir/sp ace "q".txt', { '1', '2', '3', '5' })
  R.commit(repo, 'feat one')
  R.write(repo, 'img.png', '\137PNG\0\0')
  R.commit(repo, 'feat two')
  R.write(repo, 'a.txt', { 'a', 'aa', 'aaa' })
  R.write(repo, 'new.txt', { 'n1', 'n2' })
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

-- The view as seen: nil when closed.
local function view()
  return child.lua_get([[(function()
    local v = require('agent-ide.ui.fulldiff').state()
    if not v or not vim.api.nvim_buf_is_valid(v.buf) then return vim.NIL end
    local w = vim.fn.win_findbuf(v.buf)[1]
    local out = { root = v.root, kind = v.scope.kind, loading = v.loading, lines = vim.api.nvim_buf_get_lines(v.buf, 0, -1, false),
      shown = w ~= nil, focused = w ~= nil and vim.api.nvim_get_current_win() == w, name = vim.api.nvim_buf_get_name(v.buf),
      modifiable = vim.bo[v.buf].modifiable, bufhidden = vim.bo[v.buf].bufhidden }
    if w then
      out.cursor = vim.api.nvim_win_get_cursor(w)[1]
      out.winbar = vim.wo[w].winbar
      out.closed = {}
      for i = 1, #out.lines do out.closed[i] = vim.api.nvim_win_call(w, function() return vim.fn.foldclosed(i) end) ~= -1 end
    end
    return out
  end)()]])
end

local function view_line(text)
  local v = view()
  return v ~= vim.NIL and has_line(v.lines, text) or nil
end

local function cursor_on(text)
  wait_for(function() return view_line(text) ~= nil end, 'full diff line ' .. text)
  child.lua([[local v = require('agent-ide.ui.fulldiff').state()
    local w = vim.fn.win_findbuf(v.buf)[1]
    vim.api.nvim_set_current_win(w)
    vim.api.nvim_win_set_cursor(w, { ..., 0 })]], { view_line(text) })
end

local function open(scope, extra)
  child.lua('if not require("agent-ide.ui.drawer").state().tab then require("agent-ide").toggle() end')
  child.lua('require("agent-ide.ui.fulldiff").open(vim.tbl_extend("force", { root = ..., scope = select(2, ...) }, select(3, ...) or {}))',
    { repo, scope, extra or {} })
  wait_for(function() local v = view(); return v ~= vim.NIL and v.kind == scope.kind and v.loading == false end, 'full diff')
end

local function diff_state()
  return child.lua_get([[(function()
    local d = require('agent-ide.ui.diff').state()
    if not d or not d.shown then return vim.NIL end
    return { path = d.file.path, mode = d.mode, right_line = vim.api.nvim_win_get_cursor(d.right)[1] }
  end)()]])
end

local function hl_at(line)
  return child.lua_get([[(function(line)
    local v = require('agent-ide.ui.fulldiff').state()
    local ns = vim.api.nvim_get_namespaces()['agent-ide.fulldiff']
    local marks = vim.api.nvim_buf_get_extmarks(v.buf, ns, { line - 1, 0 }, { line - 1, -1 }, { details = true, overlap = true })
    return marks[1] and marks[1][4].hl_group or ''
  end)(...)]], { line })
end

T['open branch: buffer, winbar, headers with stats, hunks coloured, folds, read only'] = function()
  start()
  open({ kind = 'branch' })
  local v = view()
  eq(v.lines[1]:sub(1, 9), 'v M a.txt')
  eq(v.lines[1]:match('%+2$') ~= nil, true)
  wait_for(function() return view().winbar == 'r · full diff · vs main · 4 files +5 −1' end, 'winbar with the untracked counts')
  eq({ v.modifiable, v.name:match('/full diff$') ~= nil, v.shown, v.focused }, { false, true, true, true })
  eq(v.lines[2], '@@ -1 +1,3 @@')
  eq(v.lines[4], '+aa')
  eq(hl_at(4), 'AgentIdeDiffAdd')
  eq(v.closed[1], false)
  eq(view_line('v R sp ace "q".txt → dir/sp ace "q".txt') ~= nil, true)
  eq(view_line('binary file, not shown') ~= nil, true)
  eq(v.lines[view_line('v ? new.txt') + 1], '@@ -0,0 +1,2 @@')
  eq(child.lua_get('vim.fn.getcwd(-1, 0)'), repo)
end

T[']f / [f step files, ]c / [c step hunks, za / z0 / z9 fold, y yanks the path'] = function()
  start()
  open({ kind = 'branch' })
  cursor_on('v M a.txt')
  child.type_keys(']f')
  eq(view().lines[view().cursor]:sub(1, 3), 'v R')
  child.type_keys(']f')
  eq(view().lines[view().cursor]:sub(1, 11), 'v A img.png')
  child.type_keys('[f')
  eq(view().lines[view().cursor]:sub(1, 3), 'v R')
  child.type_keys('y')
  eq(child.fn.getreg('"'), 'dir/sp ace "q".txt')
  cursor_on('v M a.txt')
  child.type_keys(']c')
  eq(view().lines[view().cursor], '@@ -1 +1,3 @@')
  child.type_keys(']c')
  eq(view().lines[view().cursor], '@@ -1,4 +1,4 @@')
  child.type_keys('[c')
  eq(view().lines[view().cursor], '@@ -1 +1,3 @@')
  cursor_on('v M a.txt')
  child.type_keys('za')
  local v = view()
  eq({ v.closed[1], v.lines[1]:sub(1, 1) }, { true, 'v' }) -- the fold closed; the line text redraws only on reload
  child.type_keys('za')
  eq(view().closed[1], false)
  child.type_keys('z0')
  v = view()
  eq({ v.closed[1], v.closed[view_line('v A img.png')] }, { true, true })
  child.type_keys('z9')
  v = view()
  eq({ v.closed[1], v.closed[view_line('v A img.png')] }, { false, false })
end

T['<CR> on a + line opens the side-by-side view on that file and line; q comes back to the same row'] = function()
  start()
  open({ kind = 'branch' })
  cursor_on('+aaa')
  local row = view().cursor
  child.type_keys('<CR>')
  wait_for(function() return diff_state() ~= vim.NIL end, 'diff')
  eq(diff_state(), { path = 'a.txt', mode = 'branch', right_line = 3 })
  eq(view().shown, false)
  child.lua('require("agent-ide.ui.diff").close()')
  wait_for(function() local v = view(); return v ~= vim.NIL and v.shown end, 'full diff back')
  local v = view()
  eq({ v.cursor, v.focused, v.bufhidden }, { row, true, 'wipe' })
  eq(v.closed[1], false) -- folds rebuilt
  -- a header line: the file at its top
  cursor_on('v R sp ace')
  child.type_keys('<CR>')
  wait_for(function() return diff_state() ~= vim.NIL end, 'diff')
  eq(diff_state().path, 'dir/sp ace "q".txt')
end

T['commit scope and head scope: labels; an empty scope shows one line'] = function()
  start()
  local c2 = R.await(function(cb) require('agent-ide.git').commits(repo, cb) end)[1]
  open({ kind = 'commit', commit = { hash = c2.hash, short = c2.short, subject = c2.subject } })
  local v = view()
  eq(v.winbar, 'r · full diff · ' .. c2.short .. ' feat two · 1 file')
  eq({ v.lines[1]:sub(1, 11), v.lines[2] }, { 'v A img.png', '  binary file, not shown' })
  open({ kind = 'head' })
  v = view()
  eq(v.winbar, 'r · full diff · uncommitted · 2 files +3')
  eq(v.lines[2], '@@ -1,2 +1,3 @@')
  R.git(repo, { 'checkout', '-q', '--', 'a.txt' })
  vim.fn.delete(repo .. '/new.txt')
  child.lua('require("agent-ide.git_cache").invalidate(...)', { repo })
  wait_for(function() local v2 = view(); return v2 ~= vim.NIL and v2.lines[1] == 'nothing to commit' end, 'empty scope')
  eq(view().winbar, 'r · full diff · uncommitted · 0 files')
end

T['an invalidated cache reloads: the cursor stays on its file and hunk; a closed fold stays closed'] = function()
  start()
  open({ kind = 'branch' })
  cursor_on('v M a.txt')
  child.type_keys('zc')
  cursor_on('@@ -1,4 +1,4 @@')
  local row = view().cursor
  R.write(repo, 'new.txt', { 'n0', 'n1', 'n2' })
  R.write(repo, 'zz.txt', { 'z' })
  child.lua('require("agent-ide.git_cache").invalidate(...)', { repo })
  wait_for(function() return view_line('v ? zz.txt') ~= nil end, 'reload')
  local v = view()
  eq({ v.cursor, v.lines[v.cursor] }, { row, '@@ -1,4 +1,4 @@' })
  eq({ v.closed[1], v.lines[1]:sub(1, 1) }, { true, '>' })
  eq(v.focused, true)
end

T[':AgentsDiff: the chat\'s repository; from the full diff itself; a folder outside git notifies'] = function()
  start()
  child.lua('require("agent-ide").toggle()')
  child.lua([[local d = require('agent-ide.ui.drawer'); local s = d.state(); vim.api.nvim_set_current_win(s.win)]])
  local lines = child.lua_get('vim.api.nvim_buf_get_lines(require("agent-ide.ui.drawer").state().buf, 0, -1, false)')
  child.lua('vim.api.nvim_win_set_cursor(require("agent-ide.ui.drawer").state().win, { ..., 0 })', { has_line(lines, ' r  ') })
  child.type_keys('<CR>')
  wait_for(function()
    lines = child.lua_get('vim.api.nvim_buf_get_lines(require("agent-ide.ui.drawer").state().buf, 0, -1, false)')
    return has_line(lines, 'Work on it') ~= nil
  end, 'session row')
  child.lua('vim.api.nvim_win_set_cursor(require("agent-ide.ui.drawer").state().win, { ..., 0 })', { has_line(lines, 'Work on it') })
  child.type_keys('<CR>')
  wait_for(function() return child.lua_get('require("agent-ide.ui.chat")._windows().prompt ~= nil') end, 'chat')
  child.lua('vim.cmd("AgentsDiff")')
  wait_for(function() local v = view(); return v ~= vim.NIL and v.loading == false end, 'full diff of the chat')
  eq({ view().root, view().kind }, { repo, 'branch' })
  child.lua('vim.cmd("AgentsDiff")') -- from the full diff itself: the same view stays
  vim.wait(200)
  eq({ view().root, view().kind, view().shown }, { repo, 'branch', true })
  child.type_keys('q')
  local plain = tmp .. '/plain'
  vim.fn.mkdir(plain, 'p')
  child.lua('vim.cmd.tabnew(); vim.cmd.tcd(...); vim.cmd("AgentsDiff")', { plain })
  wait_for(function() return child.lua_get('_G.notes[#_G.notes] or ""'):find('not a git repository', 1, true) ~= nil end, 'notice')
  eq(view(), vim.NIL)
end

T['G in the drawer while the full diff shows replaces it; q then returns to the chat'] = function()
  start()
  child.lua('require("agent-ide").toggle()')
  child.lua([[local d = require('agent-ide.ui.drawer'); local s = d.state(); vim.api.nvim_set_current_win(s.win)]])
  local lines = child.lua_get('vim.api.nvim_buf_get_lines(require("agent-ide.ui.drawer").state().buf, 0, -1, false)')
  child.lua('vim.api.nvim_win_set_cursor(require("agent-ide.ui.drawer").state().win, { ..., 0 })', { has_line(lines, ' r  ') })
  child.type_keys('<CR>')
  wait_for(function()
    lines = child.lua_get('vim.api.nvim_buf_get_lines(require("agent-ide.ui.drawer").state().buf, 0, -1, false)')
    return has_line(lines, 'Work on it') ~= nil
  end, 'session row')
  child.lua('vim.api.nvim_win_set_cursor(require("agent-ide.ui.drawer").state().win, { ..., 0 })', { has_line(lines, 'Work on it') })
  child.type_keys('<CR>')
  wait_for(function() return child.lua_get('require("agent-ide.ui.chat")._windows().prompt ~= nil') end, 'chat')
  open({ kind = 'branch' })
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.drawer").state().win)')
  child.type_keys('G')
  wait_for(function() return child.lua_get('require("agent-ide.ui.graph").state() ~= nil and require("agent-ide.ui.graph").state().state == "ok"') end, 'graph')
  eq(view(), vim.NIL)
  child.lua('require("agent-ide.ui.graph").close()')
  wait_for(function() return child.lua_get('require("agent-ide.ui.chat")._windows().prompt ~= nil') end, 'chat back')
  eq(child.lua_get('vim.b[vim.api.nvim_win_get_buf(require("agent-ide.ui.chat")._windows().transcript)].agent_ide_session'), ID)
end

T['q returns to the chat that was open; the buffer is wiped'] = function()
  start()
  child.lua('require("agent-ide").toggle()')
  child.lua([[local d = require('agent-ide.ui.drawer'); local s = d.state(); vim.api.nvim_set_current_win(s.win)]])
  local lines = child.lua_get('vim.api.nvim_buf_get_lines(require("agent-ide.ui.drawer").state().buf, 0, -1, false)')
  child.lua('vim.api.nvim_win_set_cursor(require("agent-ide.ui.drawer").state().win, { ..., 0 })', { has_line(lines, ' r  ') })
  child.type_keys('<CR>')
  wait_for(function()
    lines = child.lua_get('vim.api.nvim_buf_get_lines(require("agent-ide.ui.drawer").state().buf, 0, -1, false)')
    return has_line(lines, 'Work on it') ~= nil
  end, 'session row')
  child.lua('vim.api.nvim_win_set_cursor(require("agent-ide.ui.drawer").state().win, { ..., 0 })', { has_line(lines, 'Work on it') })
  child.type_keys('<CR>')
  wait_for(function() return child.lua_get('require("agent-ide.ui.chat")._windows().prompt ~= nil') end, 'chat')
  open({ kind = 'branch' })
  eq(child.lua_get('require("agent-ide.ui.chat")._windows().prompt'), vim.NIL) -- the prompt made room
  local buf = child.lua_get('require("agent-ide.ui.fulldiff").state().buf')
  child.type_keys('q')
  eq(view(), vim.NIL)
  wait_for(function() return child.lua_get('require("agent-ide.ui.chat")._windows().prompt ~= nil') end, 'chat back')
  eq(child.lua_get('vim.b[vim.api.nvim_win_get_buf(require("agent-ide.ui.chat")._windows().transcript)].agent_ide_session'), ID)
  eq(child.lua_get('vim.api.nvim_buf_is_valid(...)', { buf }), false)
end

return T

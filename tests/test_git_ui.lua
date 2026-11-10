-- Git sections in the drawer and the diff view: each case drives a fresh child Neovim against a
-- temporary repository.
local R = dofile(vim.fn.getcwd() .. '/tests/git_repo.lua')
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()

local ICONS = { open = 'v', closed = '>', project = 'P', waiting = 'W', busy = 'B', idle = 'I', parked = '.',
  done = 'D', failed = 'F', new = '+' }
local ID = '22222222-2222-4222-8222-222222222222'

local tmp, repo, projects

local function lua_lines(n)
  local t = {}
  for i = 1, n do t[i] = 'local x' .. i .. ' = ' .. i end
  return t
end

-- main: a.lua, del.txt; feat: "one" (a.lua line 2), "two" (a.lua line 8, del.txt removed,
-- bin.dat and new.lua added); uncommitted: a.lua line 5; untracked: u.txt.
local function make_repo()
  repo = R.init(tmp .. '/r')
  R.write(repo, 'a.lua', lua_lines(10))
  R.write(repo, 'del.txt', { 'gone soon' })
  R.commit(repo, 'init')
  R.git(repo, { 'checkout', '-q', '-b', 'feat' })
  local l = lua_lines(10)
  l[2] = 'local x2 = 20'
  R.write(repo, 'a.lua', l)
  R.commit(repo, 'one')
  l[8] = 'local x8 = 80'
  R.write(repo, 'a.lua', l)
  R.git(repo, { 'rm', '-q', 'del.txt' })
  R.write(repo, 'bin.dat', 'a\0b')
  R.write(repo, 'new.lua', { 'return 1' })
  R.commit(repo, 'two')
  l[5] = 'local x5 = 50'
  R.write(repo, 'a.lua', l)
  R.write(repo, 'u.txt', { 'untracked' })
end

local function write_session(extra)
  local dir = projects .. '/-r'
  vim.fn.mkdir(dir, 'p')
  local recs = { vim.json.encode({ type = 'user', uuid = 'z1', cwd = repo, message = { role = 'user', content = 'Work on it' } }) }
  vim.list_extend(recs, extra or {})
  vim.fn.writefile(recs, dir .. '/' .. ID .. '.jsonl')
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
    _G.notes = {}
    vim.notify = function(msg) table.insert(_G.notes, msg) end
    require('agent-ide').setup(opts)
  ]], { R.ENV, vim.tbl_deep_extend('force', {
    projects_dir = projects,
    helper = { enabled = false },
    live = { interval_ms = 50, cmd = { 'echo', '[]' } },
    icons = ICONS,
  }, opts or {}) })
end

local function wait_for(cond, what, ms)
  if not vim.wait(ms or 5000, cond, 20) then error('timed out waiting for ' .. what, 2) end
end

local function drawer_lines()
  return child.lua_get([[(function()
    local s = require('agent-ide.ui.drawer').state()
    return s.buf and vim.api.nvim_buf_get_lines(s.buf, 0, -1, false) or {}
  end)()]])
end

local function has_line(lines, text)
  for i, l in ipairs(lines) do
    if l:find(text, 1, true) then return i end
  end
end

local function cursor_to(text)
  wait_for(function() return has_line(drawer_lines(), text) ~= nil end, 'drawer line ' .. text)
  child.lua('local s = require("agent-ide.ui.drawer").state(); vim.api.nvim_set_current_win(s.win); vim.api.nvim_win_set_cursor(s.win, { ..., 0 })',
    { has_line(drawer_lines(), text) })
end

local function press_on(text, keys)
  cursor_to(text)
  child.type_keys(keys or '<CR>')
end

local function view()
  return child.lua_get([[(function()
    local d = require('agent-ide.ui.diff').state()
    if not d then return vim.NIL end
    local api = vim.api
    local function side(w)
      local b = api.nvim_win_get_buf(w)
      return { name = api.nvim_buf_get_name(b), ft = vim.bo[b].filetype, diff = vim.wo[w].diff, winbar = vim.wo[w].winbar,
        modifiable = vim.bo[b].modifiable, buftype = vim.bo[b].buftype, lines = api.nvim_buf_get_lines(b, 0, -1, false) }
    end
    -- what is on screen: the file last shown (a load may be on its way)
    return { mode = d.mode, index = d.index, n = #d.list, path = d.shown and d.shown.path, left = side(d.left), right = side(d.right) }
  end)()]])
end

-- Expand the project and its Changes section.
local function open_changes()
  child.lua('require("agent-ide").toggle()')
  press_on('P r  ')
  press_on('Changes vs main (5)')
  wait_for(function() return has_line(drawer_lines(), 'M a.lua') ~= nil end, 'changed files')
end

local function open_file(row_text)
  open_changes()
  press_on(row_text)
  local ok = pcall(wait_for, function() local v = view(); return v ~= vim.NIL and v.left.diff == true end, 'diff view')
  if not ok then error('no diff view: ' .. vim.inspect(view()) .. vim.inspect(child.lua_get('_G.notes')) .. vim.inspect(child.lua_get('vim.v.errmsg')), 2) end
end

local function real_buf_opts(path)
  return child.lua_get([[(function(path)
    local b = vim.fn.bufnr(path)
    if b < 0 then return vim.NIL end
    vim.cmd('tabnew')
    vim.api.nvim_win_set_buf(0, b)
    local r = { diff = vim.wo.diff, scb = vim.wo.scrollbind, crb = vim.wo.cursorbind, fdm = vim.wo.foldmethod,
      maps = vim.fn.maparg(']f', 'n') }
    vim.cmd('tabclose')
    return r
  end)(...)]], { path })
end

T['drawer: branch suffix, Changes and Commits sections with counts, files with stats'] = function()
  start()
  child.lua('require("agent-ide").toggle()')
  wait_for(function() return has_line(drawer_lines(), '  feat') ~= nil end, 'branch suffix')
  press_on('P r  ')
  wait_for(function() return has_line(drawer_lines(), 'Changes vs main (5)') ~= nil end, 'changes count')
  wait_for(function() return has_line(drawer_lines(), 'Commits on branch (2)') ~= nil end, 'commits count')
  local l = drawer_lines()
  eq(has_line(l, 'Sessions (1)') < has_line(l, 'Changes vs main'), true)
  press_on('Changes vs main (5)')
  wait_for(function() return has_line(drawer_lines(), 'M a.lua') ~= nil end, 'files')
  l = drawer_lines()
  for _, row in ipairs({ '      M a.lua  +3 −3', '      A bin.dat  bin', '      D del.txt  +0 −1', '      A new.lua  +1 −0',
    '      ? u.txt  +1 −0' }) do
    eq(has_line(l, row) ~= nil, true)
  end
  press_on('Commits on branch (2)')
  press_on('two  4 files')
  wait_for(function() return has_line(drawer_lines(), '          M a.lua  +1 −1') ~= nil end, 'commit files')
  -- za on a file row folds its section; the cursor lands on the section
  press_on('          M a.lua', 'za')
  eq(has_line(drawer_lines(), '          M a.lua'), nil)
end

T['non-git project shows no git sections'] = function()
  local plain = tmp .. '/plain'
  vim.fn.mkdir(plain, 'p')
  vim.fn.delete(projects, 'rf')
  vim.fn.mkdir(projects .. '/-plain', 'p')
  vim.fn.writefile({ vim.json.encode({ type = 'user', uuid = 'z', cwd = plain, message = { role = 'user', content = 'hi' } }) },
    projects .. '/-plain/' .. ID .. '.jsonl')
  start()
  child.lua('require("agent-ide").toggle()')
  press_on('P plain  ')
  wait_for(function() return has_line(drawer_lines(), 'Sessions (1)') ~= nil end, 'sessions')
  vim.wait(200)
  eq(has_line(drawer_lines(), 'Changes'), nil)
  eq(has_line(drawer_lines(), 'ommits'), nil)
end

T['Enter on a changed file: base scratch left, the real file right, both in diff mode'] = function()
  start()
  open_file('M a.lua')
  local v = view()
  local mb = vim.trim(R.git(repo, { 'merge-base', 'main', 'HEAD' })):sub(1, 7)
  eq(v.left.name, 'agent-ide://git/' .. mb .. '/a.lua')
  eq({ v.left.ft, v.left.modifiable, v.left.buftype, v.left.lines[2] }, { 'lua', false, 'nofile', 'local x2 = 2' })
  eq({ v.right.name, v.right.ft, v.right.modifiable, v.right.buftype, v.right.diff }, { repo .. '/a.lua', 'lua', true, '', true })
  eq(v.left.winbar, 'base main (' .. mb .. ') · a.lua · file 1/5')
  eq(v.right.winbar, 'working tree · file 1/5')
  -- two windows beside the drawer, the right one focused
  eq(child.lua_get('#vim.api.nvim_tabpage_list_wins(0)'), 3)
  eq(child.lua_get('vim.api.nvim_get_current_win() == require("agent-ide.ui.diff").state().right'), true)
end

T[']f / [f walk the list; added, binary, deleted and untracked files'] = function()
  start()
  open_file('M a.lua')
  child.type_keys(']f')
  wait_for(function() return view().path == 'bin.dat' end, 'bin.dat')
  local v = view()
  eq({ v.left.lines, v.right.lines, v.left.diff }, { { 'binary file, not shown' }, { 'binary file, not shown' }, false })
  child.type_keys(']f')
  wait_for(function() return view().path == 'del.txt' end, 'del.txt')
  v = view()
  eq({ v.left.lines, v.right.lines, v.right.winbar, v.left.diff }, { { 'gone soon' }, { '' }, 'working tree (deleted) · file 3/5', true })
  child.type_keys(']f')
  wait_for(function() return view().path == 'new.lua' end, 'new.lua')
  v = view()
  eq({ v.left.lines, v.right.name, v.right.diff }, { { '' }, repo .. '/new.lua', true })
  child.type_keys(']f')
  wait_for(function() return view().path == 'u.txt' end, 'u.txt')
  child.type_keys(']f')
  vim.wait(100)
  eq(view().path, 'u.txt')
  child.type_keys('[f')
  wait_for(function() return view().path == 'new.lua' end, 'back to new.lua')
  -- the real buffers that were shown are left clean
  eq(real_buf_opts(repo .. '/a.lua'), { diff = false, scb = false, crb = false, fdm = 'manual', maps = '' })
end

T['gb picks a commit of this file, gB goes back to the branch view'] = function()
  start()
  open_file('M a.lua')
  child.lua([[vim.ui.select = function(items, opts, cb)
    _G.picked = vim.tbl_map(function(c) return opts.format_item(c) end, items)
    cb(items[2])
  end]])
  child.type_keys('gb')
  wait_for(function() return view().mode == 'commit' end, 'commit mode')
  local items = child.lua_get('_G.picked')
  eq({ #items, items[1]:match(' two$') ~= nil, items[2]:match(' one$') ~= nil }, { 2, true, true })
  local v = view()
  local one = vim.trim(R.git(repo, { 'rev-parse', '--short', 'HEAD~1' }))
  eq({ v.left.name, v.right.name, v.left.lines[2], v.right.lines[2], v.right.modifiable },
    { 'agent-ide://git/' .. one .. '^/a.lua', 'agent-ide://git/' .. one .. '/a.lua', 'local x2 = 2', 'local x2 = 20', false })
  eq(v.right.winbar, one .. ' one · file 1/1')
  child.type_keys('gB')
  wait_for(function() return view().right.name == repo .. '/a.lua' end, 'branch mode')
  eq({ view().path, view().right.name }, { 'a.lua', repo .. '/a.lua' })
end

T['q returns to the chat that was open; keys and diff options are gone from the real buffer'] = function()
  start()
  child.lua([[vim.api.nvim_buf_call(vim.fn.bufadd(...), function()
    vim.fn.bufload(vim.api.nvim_get_current_buf())
    vim.keymap.set('n', 'q', function() _G.mine = true end, { buffer = true })
  end)]], { repo .. '/a.lua' })
  child.lua('require("agent-ide").toggle()')
  press_on('P r  ')
  press_on('Work on it')
  wait_for(function() return child.lua_get('require("agent-ide.ui.chat")._windows().prompt ~= nil') end, 'chat')
  press_on('Changes vs main (5)')
  press_on('M a.lua')
  wait_for(function() local v = view(); return v ~= vim.NIL and v.right.diff end, 'diff')
  eq(child.lua_get('require("agent-ide.ui.chat")._windows().prompt'), vim.NIL) -- the prompt split made room
  child.type_keys('q')
  wait_for(function() return view() == vim.NIL end, 'closed')
  wait_for(function() return child.lua_get('require("agent-ide.ui.chat")._windows().prompt ~= nil') end, 'chat back')
  eq(child.lua_get('vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(require("agent-ide.ui.chat")._windows().transcript))'),
    'agent-ide://chat/' .. ID)
  eq(child.lua_get('#vim.api.nvim_tabpage_list_wins(0)'), 3) -- transcript, prompt, drawer
  child.lua([[vim.api.nvim_buf_call(vim.fn.bufnr(...), function() vim.cmd('normal q') end)]], { repo .. '/a.lua' })
  eq(child.lua_get('_G.mine'), true) -- the user's own buffer-local q is back
  local o = real_buf_opts(repo .. '/a.lua')
  eq({ o.diff, o.scb, o.maps }, { false, false, '' })
end

T['opening a chat or another diff replaces the view cleanly; repeated opens keep two windows'] = function()
  start()
  open_file('M a.lua')
  for _ = 1, 3 do
    press_on('A new.lua')
    wait_for(function() return view().path == 'new.lua' end, 'new.lua')
    press_on('M a.lua')
    wait_for(function() return view().path == 'a.lua' end, 'a.lua')
  end
  eq(child.lua_get('#vim.api.nvim_tabpage_list_wins(0)'), 3)
  press_on('Work on it')
  wait_for(function() return view() == vim.NIL end, 'diff closed by the chat')
  eq(child.lua_get('#vim.api.nvim_tabpage_list_wins(0)'), 3) -- transcript, prompt, drawer
  eq(child.lua_get('vim.tbl_contains(vim.tbl_map(function(w) return vim.wo[w].diff end, vim.api.nvim_tabpage_list_wins(0)), true)'), false)
  local o = real_buf_opts(repo .. '/a.lua')
  eq({ o.diff, o.scb, o.crb }, { false, false, false })
  -- no scratch buffer is left behind
  eq(child.lua_get('#vim.tbl_filter(function(b) return vim.api.nvim_buf_get_name(b):find("agent-ide://git/", 1, true) ~= nil end, vim.api.nvim_list_bufs())'), 0)
end

T['closing the Agents tab with a diff open; the real file shown again has no diff'] = function()
  start()
  open_file('M a.lua')
  child.lua('vim.cmd("tabclose")')
  wait_for(function() return view() == vim.NIL end, 'view gone')
  eq(child.lua_get('vim.fn.tabpagenr("$")'), 1)
  child.lua('vim.cmd.edit(vim.fn.fnameescape(...))', { repo .. '/a.lua' })
  eq(child.lua_get('{ vim.wo.diff, vim.wo.scrollbind, vim.wo.cursorbind }'), { false, false, false })
end

T[':bd on the scratch side, then the right window; an unsaved real file is never wiped'] = function()
  start()
  open_file('M a.lua')
  -- edit the real file without saving
  child.lua('vim.api.nvim_buf_set_lines(vim.fn.bufnr(...), 0, 1, false, { "-- edited" })', { repo .. '/a.lua' })
  child.lua('vim.cmd("bd " .. vim.api.nvim_win_get_buf(require("agent-ide.ui.diff").state().left))')
  wait_for(function() return view() == vim.NIL end, 'view closed by :bd')
  local s = child.lua_get([[(function(p)
    local b = vim.fn.bufnr(p)
    return { valid = vim.api.nvim_buf_is_loaded(b), modified = vim.bo[b].modified, first = vim.api.nvim_buf_get_lines(b, 0, 1, false)[1],
      diff = vim.tbl_map(function(w) return vim.wo[w].diff end, vim.api.nvim_tabpage_list_wins(0)) }
  end)(...)]], { repo .. '/a.lua' })
  eq({ s.valid, s.modified, s.first, vim.tbl_contains(s.diff, true) }, { true, true, '-- edited', false })
  -- the same unsaved buffer, opened again in a diff, shows the edit on the right
  press_on('M a.lua')
  wait_for(function() local v = view(); return v ~= vim.NIL and v.right.diff end, 'diff again')
  eq(view().right.lines[1], '-- edited')
  child.lua('vim.api.nvim_win_close(require("agent-ide.ui.diff").state().right, true)')
  wait_for(function() return view() == vim.NIL end, 'view closed with the right window')
  eq(child.lua_get('vim.bo[vim.fn.bufnr(...)].modified', { repo .. '/a.lua' }), true)
end

T['late git results after collapsing the project or closing the tab are harmless'] = function()
  start()
  child.lua('require("agent-ide").toggle()')
  press_on('P r  ')
  press_on('P r  ') -- collapse again before git answers
  vim.wait(300)
  press_on('P r  ')
  press_on('Changes vs main (5)')
  press_on('M a.lua')
  child.lua('vim.cmd("tabclose")') -- the diff's git show is still on its way
  vim.wait(500)
  eq(child.lua_get('vim.v.errmsg'), '')
  eq(child.lua_get('_G.notes'), {})
  eq(view(), vim.NIL)
  eq(child.lua_get('vim.fn.tabpagenr("$")'), 1)
  eq(child.lua_get('vim.tbl_contains(vim.tbl_map(function(w) return vim.wo[w].diff end, vim.api.nvim_list_wins()), true)'), false)
end

T['the same file open in another tab keeps its own window options'] = function()
  start()
  child.lua('vim.cmd("tabnew " .. vim.fn.fnameescape(...)); vim.wo.foldmethod = "indent"; vim.cmd("tabprevious")', { repo .. '/a.lua' })
  open_file('M a.lua')
  local other = child.lua_get([[(function()
    local agents = require('agent-ide.ui.drawer').state().tab
    local w
    for _, t in ipairs(vim.api.nvim_list_tabpages()) do
      if t ~= agents and t ~= vim.api.nvim_list_tabpages()[1] then w = vim.api.nvim_tabpage_list_wins(t)[1] end
    end
    return { diff = vim.wo[w].diff, fdm = vim.wo[w].foldmethod }
  end)()]])
  eq(other, { diff = false, fdm = 'indent' })
  child.type_keys('q')
  wait_for(function() return view() == vim.NIL end, 'closed')
end

T['refresh: R, a session finishing its turn, drawer focus after 5 s; the open diff keeps its cursor'] = function()
  start()
  open_file('M a.lua')
  child.lua('vim.api.nvim_win_set_cursor(require("agent-ide.ui.diff").state().right, { 8, 0 })')
  -- an agent commits the uncommitted change and adds a file
  R.write(repo, 'z.txt', { 'z' })
  R.commit(repo, 'three')
  press_on('Changes vs main (5)', 'R')
  wait_for(function() return has_line(drawer_lines(), 'Changes vs main (6)') ~= nil end, 'R refresh')
  wait_for(function() return has_line(drawer_lines(), 'Commits on branch (3)') ~= nil end, 'commits refresh')
  wait_for(function() return view().n == 6 end, 'diff list refreshed')
  eq(child.lua_get('vim.api.nvim_win_get_cursor(require("agent-ide.ui.diff").state().right)[1]'), 8)
  -- busy -> idle of a session of this project
  R.write(repo, 'y.txt', { 'y' })
  child.lua(([[local s = require('agent-ide.session').open({ id = '%s', cwd = '%s' })
    s:_set_state('busy'); s:_set_state('idle')]]):format(ID, repo))
  wait_for(function() return has_line(drawer_lines(), 'Changes vs main (7)') ~= nil end, 'turn-end refresh')
  -- focus: nothing within 5 s, then a status check
  R.write(repo, 'x.txt', { 'x' })
  child.lua('vim.cmd("wincmd p")')
  cursor_to('Changes vs main (7)')
  vim.wait(500)
  eq(has_line(drawer_lines(), 'Changes vs main (8)'), nil)
  child.lua('for _, r in ipairs(require("agent-ide.git_cache").roots()) do require("agent-ide.git_cache").peek(r).checked = 0 end')
  child.lua('vim.cmd("wincmd p")')
  cursor_to('Changes vs main (7)')
  wait_for(function() return has_line(drawer_lines(), 'Changes vs main (8)') ~= nil end, 'focus refresh')
end

T['gl: Snacks.lazygit when loaded, a terminal tab otherwise, a notice without lazygit; data invalidated'] = function()
  start()
  child.lua([[_G.Snacks = { lazygit = function(o)
    _G.snacks_cwd = o.cwd
    local b = vim.api.nvim_create_buf(false, true)
    _G.snacks_buf = b
    return { buf = b }
  end }]])
  child.lua('require("agent-ide").toggle()')
  press_on('P r  ')
  wait_for(function() return has_line(drawer_lines(), 'Changes vs main (5)') ~= nil end, 'changes')
  press_on('Sessions (1)', 'gl')
  eq(child.lua_get('_G.snacks_cwd'), repo)
  local gen = child.lua_get('require("agent-ide.git_cache").peek(...).gen', { repo })
  child.lua('vim.api.nvim_buf_delete(_G.snacks_buf, { force = true })')
  wait_for(function() return child.lua_get('require("agent-ide.git_cache").peek(...).gen', { repo }) > gen end, 'invalidated')
  -- terminal path with a fake lazygit on PATH
  local bin = tmp .. '/bin'
  vim.fn.mkdir(bin, 'p')
  vim.fn.writefile({ '#!/bin/sh', 'echo "$@" > ' .. tmp .. '/lg.args' }, bin .. '/lazygit')
  vim.fn.setfperm(bin .. '/lazygit', 'rwxr-xr-x')
  child.lua('_G.Snacks = nil; vim.env.PATH = ... .. ":" .. vim.env.PATH', { bin })
  gen = child.lua_get('require("agent-ide.git_cache").peek(...).gen', { repo })
  press_on('Sessions (1)', 'gl')
  wait_for(function() return vim.fn.filereadable(tmp .. '/lg.args') == 1 end, 'lazygit ran')
  eq(vim.fn.readfile(tmp .. '/lg.args'), { '-p ' .. repo })
  wait_for(function() return child.lua_get('require("agent-ide.git_cache").peek(...).gen', { repo }) > gen end, 'invalidated 2')
  wait_for(function() return child.lua_get('vim.fn.tabpagenr("$")') == 2 end, 'lazygit tab closed')
  -- not installed
  child.lua('vim.env.PATH = "/nonexistent"; _G.notes = {}')
  press_on('Sessions (1)', 'gl')
  eq(child.lua_get('_G.notes'), { 'Agent-IDE: lazygit is not installed' })
end

T['gl and ? in the diff view'] = function()
  start()
  open_file('M a.lua')
  child.lua('_G.Snacks = { lazygit = function(o) _G.snacks_cwd = o.cwd end }')
  child.type_keys('gl')
  eq(child.lua_get('_G.snacks_cwd'), repo)
  child.type_keys('?')
  wait_for(function() return child.lua_get('vim.api.nvim_win_get_config(0).relative') ~= '' end, 'help')
  local text = table.concat(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, -1, false)'), '\n')
  for _, k in ipairs({ ']f', '[f', 'gb', 'gB', 'q', ']c / [c', 'gl' }) do eq(text:find(k, 1, true) ~= nil, true) end
end

T['gd on an Edit or Write fold in the chat opens the branch diff of that file'] = function()
  write_session({
    vim.json.encode({ type = 'assistant', uuid = 'z2', cwd = repo, message = { role = 'assistant', content = {
      { type = 'tool_use', id = 't1', name = 'Edit', input = { file_path = repo .. '/a.lua', old_string = 'a', new_string = 'b' } },
    } } }),
    vim.json.encode({ type = 'assistant', uuid = 'z3', cwd = repo, message = { role = 'assistant', content = {
      { type = 'tool_use', id = 't2', name = 'Write', input = { file_path = repo .. '/new.lua', content = 'return 1' } },
    } } }),
    vim.json.encode({ type = 'assistant', uuid = 'z4', cwd = repo, message = { role = 'assistant', content = {
      { type = 'tool_use', id = 't3', name = 'Bash', input = { command = 'ls' } },
    } } }),
  })
  start()
  child.lua('require("agent-ide").toggle()')
  press_on('P r  ')
  press_on('Work on it')
  local function tline(text)
    local lines
    wait_for(function()
      lines = child.lua_get('vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(require("agent-ide.ui.chat")._windows().transcript), 0, -1, false)')
      return has_line(lines, text) ~= nil
    end, 'transcript line ' .. text)
    return has_line(lines, text)
  end
  local function gd_at(row)
    child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.chat")._windows().transcript); vim.api.nvim_win_set_cursor(0, { ..., 0 })', { row })
    child.type_keys('gd')
  end
  gd_at(tline('▸ Bash: ls'))
  eq(child.lua_get('_G.notes[#_G.notes]'), 'Agent-IDE: no Edit or Write of a file here')
  gd_at(tline('▸ Write: '))
  wait_for(function() local v = view(); return v ~= vim.NIL and v.path == 'new.lua' end, 'diff of new.lua')
  child.type_keys('q')
  wait_for(function() return view() == vim.NIL end, 'closed')
  gd_at(tline('▸ Edit: '))
  wait_for(function() local v = view(); return v ~= vim.NIL and v.path == 'a.lua' end, 'diff of a.lua')
  eq({ view().index, view().n }, { 1, 5 })
end

return T

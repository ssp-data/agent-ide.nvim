-- Deleting a session (`D` in the drawer) into the plugin's trash, restore and purge
-- (`:AgentsTrash`), on a synthetic Claude folder in a temp dir; each case drives a child Neovim.
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()

local ICONS = { open = 'v', closed = '>', project = 'P', waiting = 'W', busy = 'B', idle = 'I', parked = '.',
  done = 'D', failed = 'F', new = '+' }
local A = 'dddddddd-0000-4000-8000-00000000000a'
local B = 'dddddddd-0000-4000-8000-00000000000b'
local C = 'dddddddd-0000-4000-8000-00000000000c'

local tmp, repo, claude, slug

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    tmp = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    tmp = vim.uv.fs_realpath(tmp)
    repo = tmp .. '/repo'
    claude = tmp .. '/claude'
    slug = '-repo'
    vim.fn.mkdir(repo, 'p')
    vim.fn.system({ 'git', 'init', '-q', repo })
    -- the runner's temporary data folder (tests/run.lua); never anything else
    assert(vim.fn.stdpath('data'):find('%-xdg/data/'), 'run through tests/run.lua')
    vim.fn.delete(vim.fn.stdpath('data') .. '/agent-ide/trash', 'rf')
    vim.fn.delete(vim.fn.stdpath('data') .. '/agent-ide/hidden.json')
  end,
  post_case = function()
    child.stop()
    vim.fn.delete(tmp, 'rf')
  end,
  post_once = function() child.stop() end,
} })

local function write(path, text, mode)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local f = assert(io.open(path, 'wb'))
  f:write(text)
  f:close()
  if mode then vim.uv.fs_chmod(path, mode) end
end

local function read(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local t = f:read('a')
  f:close()
  return t
end

local function transcript(id, prompt, hours)
  local ts = os.date('!%Y-%m-%dT%H:%M:%SZ', os.time() - hours * 3600)
  return vim.json.encode({ type = 'user', uuid = 'u-' .. id, cwd = repo, timestamp = ts,
    message = { role = 'user', content = prompt } }) .. '\n'
end

local function hist(id, text, ts)
  return vim.json.encode({ display = text, pastedContents = vim.empty_dict(), project = repo, sessionId = id, timestamp = ts }) .. '\n'
end

local HISTORY
-- Three sessions; A and B with every kind of file, history.jsonl interleaved.
local function tree()
  local p = claude .. '/projects/' .. slug
  write(p .. '/' .. A .. '.jsonl', transcript(A, 'Alpha topic', 1), 384)
  write(p .. '/' .. B .. '.jsonl', transcript(B, 'Beta topic', 2), 384)
  write(p .. '/' .. C .. '.jsonl', transcript(C, 'Gamma topic', 3), 420)
  for _, id in ipairs({ A, B }) do
    write(p .. '/' .. id .. '/subagents/agent-1.jsonl', 'sub ' .. id .. '\n', 384)
    write(p .. '/' .. id .. '/tool-results/r1.txt', 'result ' .. id .. '\n', 420)
    write(claude .. '/file-history/' .. id .. '/f1@v1', 'old file ' .. id, 384)
    write(claude .. '/session-env/' .. id .. '/env', 'X=1', 384)
    write(claude .. '/tasks/' .. id .. '/t.json', '{}', 384)
  end
  write(claude .. '/stats-cache.json', '{"s":1}', 384)
  write(claude .. '/paste-cache/abc.txt', 'pasted', 384)
  HISTORY = hist(B, 'b first', 1000) .. hist(A, 'a first', 1001) .. 'not json at all ' .. A .. '\n'
    .. hist(C, 'c one', 1002) .. hist(A, 'a second "quoted"', 1003) .. hist(B, 'b last', 1004)
  write(claude .. '/history.jsonl', HISTORY, 384)
end

-- Every file and folder below `root`: rel -> { mode, content|nil }.
local function snapshot(root)
  local out = {}
  local function walk(dir, rel)
    for name, typ in vim.fs.dir(dir) do
      local path, r = dir .. '/' .. name, rel == '' and name or (rel .. '/' .. name)
      local st = vim.uv.fs_lstat(path)
      out[r] = { mode = st.mode % 4096, content = typ == 'file' and read(path) or nil }
      if typ == 'directory' then walk(path, r) end
    end
  end
  walk(root, '')
  return out
end

local function start(opts)
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[
    vim.env.TMUX = nil
    _G.notes = {}
    vim.notify = function(msg) table.insert(_G.notes, msg) end
    _G.confirms = {}
    _G.answer = 1
    vim.fn.confirm = function(msg) table.insert(_G.confirms, msg); return _G.answer end
    require('agent-ide').setup(...)
  ]], { vim.tbl_deep_extend('force', {
    projects_dir = claude .. '/projects',
    helper = { enabled = false },
    live = { interval_ms = 50, cmd = { 'echo', '[]' } },
    icons_style = 'plain', icons = ICONS,
    prompts = { command_dirs = {}, skill_dirs = {}, project_dirs = false },
  }, opts or {}) })
end

local function wait_for(cond, what, ms)
  if not vim.wait(ms or 5000, cond, 20) then error('timed out waiting for ' .. what, 2) end
end

local function lines()
  return child.lua_get([[(function()
    local s = require('agent-ide.ui.drawer').state()
    return s.buf and vim.api.nvim_buf_get_lines(s.buf, 0, -1, false) or {}
  end)()]])
end

local function find(text)
  for i, l in ipairs(lines()) do
    if l:find(text, 1, true) then return i end
  end
end

local function cursor_to(text)
  wait_for(function() return find(text) ~= nil end, 'drawer line ' .. text)
  local row = find(text)
  child.lua('local s = require("agent-ide.ui.drawer").state(); vim.api.nvim_set_current_win(s.win); vim.api.nvim_win_set_cursor(s.win, { ..., 0 })', { row })
  return row
end

local function open_drawer()
  child.lua('require("agent-ide").toggle()')
  cursor_to('> repo')
  child.type_keys('<CR>')
  cursor_to('Sessions (')
end

local function notes() return child.lua_get('_G.notes') end
local function last_note() local n = notes(); return n[#n] or '' end
local function trash_dirs()
  local out = {}
  local root = vim.fn.stdpath('data') .. '/agent-ide/trash'
  if vim.uv.fs_stat(root) then
    for name in vim.fs.dir(root) do out[#out + 1] = root .. '/' .. name end
  end
  table.sort(out)
  return out
end

-- Press D on the session row `title`; waits until the session is gone or a notice came.
local function delete(title)
  local before = #notes()
  local row = cursor_to(title)
  child.type_keys('D')
  wait_for(function() return find(title) == nil or #notes() > before end, 'delete of ' .. title)
  return row
end

T['D moves every kind of file and the history lines into the trash; others stay byte-identical'] = function()
  tree()
  local before = snapshot(claude)
  start()
  open_drawer()
  local row = delete('Alpha topic')
  wait_for(function() return find('Alpha topic') == nil end, 'row gone')
  eq(child.lua_get('vim.api.nvim_win_get_cursor(0)[1]'), row) -- the same screen line
  eq(child.lua_get('vim.api.nvim_get_current_line()'):find('Beta topic', 1, true) ~= nil, true)
  eq(#child.lua_get('_G.confirms'), 1)
  local msg = child.lua_get('_G.confirms[1]')
  eq(msg:find("Move this session to the plugin's trash? Claude will no longer list it.", 1, true) ~= nil, true)
  eq(msg:find('Alpha topic', 1, true) ~= nil and msg:find('repo · 1h', 1, true) ~= nil, true)

  local after = snapshot(claude)
  -- everything of A is gone; everything else is as it was
  for rel, v in pairs(before) do
    local mine = rel:find(A, 1, true) ~= nil
    if rel == 'history.jsonl' then
      eq(after[rel].content, hist(B, 'b first', 1000) .. 'not json at all ' .. A .. '\n' .. hist(C, 'c one', 1002) .. hist(B, 'b last', 1004))
      eq(after[rel].mode, 384)
    elseif mine then
      eq(after[rel], nil)
    else
      eq(after[rel], v)
    end
  end
  -- the trash keeps the layout, the modes and the removed lines
  local dirs = trash_dirs()
  eq(#dirs, 1)
  local dir = dirs[1]
  eq(vim.fs.basename(dir):match('^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-(.+)$'), A)
  eq(vim.uv.fs_stat(dir).mode % 512, 448)
  eq(vim.uv.fs_stat(vim.fs.dirname(dir)).mode % 512, 448)
  local t = snapshot(dir)
  for rel, v in pairs(before) do
    if rel:find(A, 1, true) then eq(t[rel], v) end
  end
  eq(t['history.jsonl'].content, hist(A, 'a first', 1001) .. hist(A, 'a second "quoted"', 1003))
  local m = vim.json.decode(t['manifest.json'].content)
  eq({ m.version, m.id, m.title, m.project, m.history_lines, #m.entries }, { 1, A, 'Alpha topic', 'repo', 2, 5 })
  eq(m.entries[1].path, claude .. '/projects/' .. slug .. '/' .. A .. '.jsonl')
  eq(type(m.deleted_at), 'number')
  eq(child.lua_get('require("agent-ide.session").get(...)', { A }), vim.NIL)

  -- search no longer finds it (Lua backend)
  child.lua([[_G.hits = nil
    require('agent-ide.index.search').search({ query = 'topic', limit = 50 }, function(r) _G.hits = r end)]])
  wait_for(function() return child.lua_get('_G.hits ~= nil and not _G.hits.indexing') end, 'search')
  local titles = child.lua_get('vim.tbl_map(function(h) return h.title end, _G.hits.hits)')
  eq(vim.tbl_contains(titles, 'Alpha topic'), false)
  eq(vim.tbl_contains(titles, 'Beta topic'), true)

  -- restore: the tree is byte-identical to the original
  child.lua([[vim.ui.select = function(items, opts, cb)
    if opts.prompt == 'Trashed sessions' then return cb(items[1]) end
    cb('Restore')
  end]])
  child.lua('require("agent-ide.ui.delete").command("")')
  eq(last_note(), 'Agent-IDE: restored')
  eq(snapshot(claude), before)
  eq(#trash_dirs(), 0)
  wait_for(function() return find('Alpha topic') ~= nil end, 'row back')
end

T['a hidden session can be deleted from the Hidden group; its id leaves hidden.json'] = function()
  tree()
  start()
  child.lua('require("agent-ide.hidden").set(...)', { A, true })
  open_drawer()
  cursor_to('Hidden (1)')
  child.type_keys('<CR>')
  -- its chat is open: closed first
  cursor_to('Alpha topic')
  child.type_keys('<CR>')
  wait_for(function() return child.lua_get('require("agent-ide.ui.chat")._windows().prompt ~= nil') end, 'chat open')
  delete('Alpha topic')
  local names = child.lua_get('vim.tbl_map(vim.api.nvim_buf_get_name, vim.api.nvim_list_bufs())')
  for _, n in ipairs(names) do eq(n:find(A, 1, true), nil) end
  wait_for(function() return find('Hidden (') == nil end, 'group gone')
  local h = vim.json.decode(read(vim.fn.stdpath('data') .. '/agent-ide/hidden.json'))
  eq(h.ids[A], nil)
  eq(vim.uv.fs_stat(claude .. '/projects/' .. slug .. '/' .. A .. '.jsonl'), nil)
end

T['refused: active here, elsewhere, in native Claude, live query failing, unsent prompt text; No'] = function()
  tree()
  local before = snapshot(claude)
  local function refused(text)
    eq(last_note():find(text, 1, true) ~= nil, true)
    eq(snapshot(claude), before)
    eq(#trash_dirs(), 0)
    eq(find('Alpha topic') ~= nil, true)
  end

  start()
  open_drawer()
  -- active in this Neovim
  child.lua('require("agent-ide.session").open({ id = ..., cwd = ... }).state = "idle"', { A, repo })
  delete('Alpha topic')
  refused('not deleted: it is active here; park it first (x)')
  child.lua('require("agent-ide.session").get(...).state = "parked"', { A })
  -- handed to native Claude
  child.lua('require("agent-ide.ui.handoff").away = function() return true end')
  delete('Alpha topic')
  refused('not deleted: it is open in native Claude')
  child.lua('package.loaded["agent-ide.ui.handoff"] = nil')
  -- unsent text in its prompt
  child.lua([[
    local s = require('agent-ide.session').get(...)
    local p = require('agent-ide.ui.prompt').create(s)
    vim.api.nvim_buf_set_lines(p, 0, -1, false, { 'draft' })
  ]], { A })
  delete('Alpha topic')
  refused('not deleted: its prompt holds unsent text')
  child.lua([[for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):find('prompt/', 1, true) then vim.api.nvim_buf_delete(b, { force = true }) end
  end]])
  -- the answer is No
  child.lua('_G.answer = 2')
  child.lua('_G.confirms = {}')
  cursor_to('Alpha topic')
  child.type_keys('D')
  wait_for(function() return #child.lua_get('_G.confirms') == 1 end, 'confirm')
  child.lua('vim.wait(50)')
  eq(snapshot(claude), before)
  eq(find('Alpha topic') ~= nil, true)

  -- running in another Claude (the fresh live query says so)
  start({ live = { cmd = { 'echo', '[{"sessionId":"' .. A .. '","status":"idle","pid":4242,"cwd":"' .. repo .. '"}]' } } })
  open_drawer()
  delete('Alpha topic')
  refused('not deleted: it runs in another Claude')

  -- the live command fails
  start({ live = { cmd = { 'false' } } })
  open_drawer()
  delete('Alpha topic')
  refused('not deleted: cannot check whether it runs elsewhere (exit code 1)')
end

T['lines Claude appends to history.jsonl while it is rewritten are kept'] = function()
  tree()
  start()
  local appended = hist(C, 'typed meanwhile', 2000)
  child.lua([[
    local line = ...
    local n = 0
    require('agent-ide.trash')._before_history_rename = function(path)
      n = n + 1
      if n == 1 then
        local f = io.open(path, 'ab'); f:write(line); f:close()
        vim.uv.sleep(5)
      end
    end
  ]], { appended })
  open_drawer()
  delete('Alpha topic')
  wait_for(function() return find('Alpha topic') == nil end, 'deleted')
  eq(read(claude .. '/history.jsonl'), hist(B, 'b first', 1000) .. 'not json at all ' .. A .. '\n'
    .. hist(C, 'c one', 1002) .. hist(B, 'b last', 1004) .. appended)
end

T['a failing move puts everything back; across file systems a copy is made'] = function()
  tree()
  local before = snapshot(claude)
  start()
  child.lua([[
    local n = 0
    require('agent-ide.trash')._rename = function(a, b)
      n = n + 1
      if n == 3 then return nil, 'EACCES: permission denied' end
      return vim.uv.fs_rename(a, b)
    end
  ]])
  open_drawer()
  delete('Alpha topic')
  eq(last_note():find('not deleted: EACCES', 1, true) ~= nil, true)
  eq(snapshot(claude), before)
  eq(#trash_dirs(), 0)

  -- EXDEV: copied, sizes checked, sources removed
  child.lua([[require('agent-ide.trash')._rename = function(a, b)
    if a:find('/agent-ide/trash/', 1, true) then return vim.uv.fs_rename(a, b) end
    return nil, 'EXDEV: cross-device link not permitted'
  end]])
  delete('Alpha topic')
  wait_for(function() return find('Alpha topic') == nil end, 'deleted')
  local dir = trash_dirs()[1]
  local t = snapshot(dir)
  for rel, v in pairs(before) do
    if rel:find(A, 1, true) then eq(t[rel], v) end
    if rel:find(A, 1, true) then eq(vim.uv.fs_lstat(claude .. '/' .. rel), nil) end
  end
end

T['safety: a symlinked session folder or a transcript outside Claude\'s folder is refused'] = function()
  tree()
  local outside = tmp .. '/elsewhere'
  vim.fn.mkdir(outside, 'p')
  vim.fn.delete(claude .. '/file-history/' .. A, 'rf')
  vim.uv.fs_symlink(outside, claude .. '/file-history/' .. A)
  start()
  eq(child.lua_get('{ require("agent-ide.trash").plan(...) }', { A, claude .. '/projects/' .. slug .. '/' .. A .. '.jsonl' }),
    { vim.NIL, 'a symbolic link: file-history/' .. A })
  eq(child.lua_get('{ require("agent-ide.trash").plan(...) }', { 'not-an-id', claude .. '/x.jsonl' }), { vim.NIL, 'not a session id' })
  eq(child.lua_get('{ require("agent-ide.trash").plan(...) }', { B, tmp .. '/' .. B .. '.jsonl' }),
    { vim.NIL, 'the transcript is not in Claude\'s projects folder' })
  eq(vim.uv.fs_stat(outside) ~= nil, true)
end

T[':AgentsTrash empty purges after a confirm; keep_days purges older entries at setup'] = function()
  tree()
  start()
  open_drawer()
  delete('Alpha topic')
  wait_for(function() return find('Alpha topic') == nil end, 'deleted')
  delete('Beta topic')
  wait_for(function() return find('Beta topic') == nil end, 'deleted')
  eq(#trash_dirs(), 2)
  -- restore is refused while something is at the original place
  local again = claude .. '/projects/' .. slug .. '/' .. B .. '.jsonl'
  write(again, 'new\n')
  child.lua([[vim.ui.select = function(items, opts, cb)
    if opts.prompt == 'Trashed sessions' then return cb(items[1]) end -- the newest: B
    cb('Restore')
  end]])
  child.lua('require("agent-ide.ui.delete").command("")')
  eq(last_note(), 'Agent-IDE: not restored: something is there already: ' .. again)
  eq(read(again), 'new\n')
  eq(#trash_dirs(), 2)
  child.lua('_G.answer = 2')
  child.lua('require("agent-ide.ui.delete").command("empty")')
  eq(#trash_dirs(), 2)
  child.lua('_G.answer = 1; _G.confirms = {}')
  child.lua('require("agent-ide.ui.delete").command("empty")')
  eq(child.lua_get('_G.confirms[1]'), 'Delete 2 trashed session(s) for good?')
  eq(#trash_dirs(), 0)
  eq(last_note(), 'Agent-IDE: deleted 2 session(s) for good')

  -- keep_days
  local root = vim.fn.stdpath('data') .. '/agent-ide/trash'
  local old = root .. '/' .. os.date('%Y%m%d-%H%M%S', os.time() - 10 * 86400) .. '-' .. A
  local new = root .. '/' .. os.date('%Y%m%d-%H%M%S', os.time() - 3600) .. '-' .. B
  write(old .. '/manifest.json', '{"version":1}')
  write(new .. '/manifest.json', '{"version":1}')
  start({ trash = { keep_days = 7 } })
  wait_for(function() return vim.uv.fs_stat(old) == nil end, 'old purged')
  eq(vim.uv.fs_stat(new) ~= nil, true)
end

T['history: split and merge are byte-exact'] = function()
  local T2 = dofile(vim.fn.getcwd() .. '/lua/agent-ide/trash.lua')
  local text = hist(B, 'b', 1) .. hist(A, 'a', 2) .. '{"broken": ' .. A .. '\n' .. hist(B, 'c', 3) .. hist(A, 'd', 4)
  local kept, removed, n = T2.split_history(text, A)
  eq(n, 2)
  eq(kept, hist(B, 'b', 1) .. '{"broken": ' .. A .. '\n' .. hist(B, 'c', 3))
  eq(T2.merge_history(kept, removed), text)
  eq(T2.merge_history('', removed), removed)
end

return T

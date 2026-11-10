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

-- A child call cannot time out by itself: a watchdog timer kills a child that lives longer than
-- CHILD_MAX_S, so a stuck child fails its case instead of hanging the run.
local CHILD_MAX_S = 60
local watchdog
local function stop_watchdog()
  if watchdog then
    watchdog:stop()
    watchdog:close()
  end
  watchdog = nil
end

-- A folder removed even when a case left a read-only folder in it.
local function rm_rf(path)
  if vim.uv.fs_lstat(path) then vim.fn.system({ 'chmod', '-R', 'u+rwX', path }) end
  vim.fn.delete(path, 'rf')
end

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
    rm_rf(vim.fn.stdpath('data') .. '/agent-ide/trash')
    vim.fn.delete(vim.fn.stdpath('data') .. '/agent-ide/hidden.json')
  end,
  post_case = function()
    child.stop()
    stop_watchdog()
    rm_rf(tmp)
  end,
  post_once = function()
    child.stop()
    stop_watchdog()
  end,
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
  stop_watchdog()
  child.restart({ '-u', 'tests/minimal_init.lua' })
  -- stubs first: a real confirm or select would wait for input forever in a headless child
  child.lua([[
    _G.confirms = {}
    _G.answer = 1
    _G.order = {}
    _G.defaults = {}
    vim.fn.confirm = function(msg, _, default)
      table.insert(_G.confirms, msg); table.insert(_G.defaults, default); table.insert(_G.order, 'confirm')
      if _G.on_confirm then _G.on_confirm() end
      return _G.answer
    end
    -- every command spawned, in order with the confirms
    local system = vim.system
    vim.system = function(cmd, ...) table.insert(_G.order, 'spawn ' .. tostring(cmd[1])); return system(cmd, ...) end
    vim.ui.select = function(_, _, cb) cb(nil) end
    vim.ui.input = function(_, cb) cb(nil) end
  ]])
  local pid = child.lua_get('vim.fn.getpid()')
  watchdog = vim.uv.new_timer()
  -- a fast callback: it runs while this Neovim waits for a child reply
  watchdog:start(CHILD_MAX_S * 1000, 0, function() vim.uv.kill(pid, 'sigkill') end)
  child.lua([[
    vim.env.TMUX = nil
    _G.notes = {}
    vim.notify = function(msg) table.insert(_G.notes, msg) end
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
  eq({ m.version, m.id, m.complete, m.title, m.project, m.history_lines, #m.entries }, { 1, A, true, 'Alpha topic', 'repo', 2, 5 })
  eq(m.entries[1].path, claude .. '/projects/' .. slug .. '/' .. A .. '.jsonl')
  eq(type(m.deleted_at), 'number')
  eq(child.lua_get('require("agent-ide.session").get(...)', { A }), vim.NIL)

  -- search no longer finds it (Lua backend)
  -- asked again until the background indexing is done
  child.lua([[_G.hits = nil
    _G.ask = function()
      require('agent-ide.index.search').search({ query = 'topic', limit = 50 }, function(r)
        if r.indexing then return vim.defer_fn(_G.ask, 20) end
        _G.hits = r
      end)
    end
    _G.ask()]])
  wait_for(function() return child.lua_get('_G.hits ~= nil') end, 'search')
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

-- Each refusal in a fresh child: nothing moved, no trash, the row stays.
local REFUSALS = {
  { 'active in this Neovim', 'not deleted: it is active here; park it first (x)', nil, function()
    child.lua('require("agent-ide.session").open({ id = ..., cwd = ... }).state = "idle"', { A, repo })
  end },
  { 'handed to native Claude', 'not deleted: it is open in native Claude', nil, function()
    child.lua('local h = require("agent-ide.ui.handoff"); local id = ...; h.away = function(s) return s.id == id end', { A })
    child.lua('require("agent-ide.session").open({ id = ..., cwd = ... })', { A, repo })
  end },
  { 'unsent prompt text', 'not deleted: its prompt holds unsent text', nil, function()
    cursor_to('Alpha topic')
    child.type_keys('<CR>')
    wait_for(function() return child.lua_get('require("agent-ide.ui.chat")._windows().prompt ~= nil') end, 'chat open')
    child.lua([[
      local _, p = require('agent-ide.ui.chat').buffers(require('agent-ide.session').get(...))
      vim.api.nvim_buf_set_lines(p, 0, -1, false, { 'draft' })
    ]], { A })
  end },
  { 'running in another Claude', 'not deleted: it runs in another Claude',
    { live = { cmd = { 'echo', '[{"sessionId":"' .. A .. '","status":"idle","pid":4242,"cwd":"/x"}]' } } } },
  { 'live query failing', 'not deleted: cannot check whether it runs elsewhere (exit code 1)', { live = { cmd = { 'false' } } } },
  { 'live output unreadable', 'not deleted: cannot check whether it runs elsewhere (unexpected output)',
    { live = { cmd = { 'echo', 'Welcome to Claude Code v9' } } } },
  { 'a special file in a session folder', 'cannot delete: a special file (fifo): ', nil, function()
    vim.fn.system({ 'mkfifo', claude .. '/projects/' .. slug .. '/' .. A .. '/subagents/pipe' })
  end, true },
}

for _, r in ipairs(REFUSALS) do
  T['refused: ' .. r[1]] = function()
    tree()
    local before = snapshot(claude)
    start(r[3])
    open_drawer()
    if r[4] then r[4]() end
    if r[5] then before = snapshot(claude) end
    delete('Alpha topic')
    if r[5] then
      eq(vim.startswith(last_note(), 'Agent-IDE: ' .. r[2]), true)
    else
      eq(last_note(), 'Agent-IDE: ' .. r[2])
    end
    eq(snapshot(claude), before)
    eq(#trash_dirs(), 0)
    eq(find('Alpha topic') ~= nil, true)
  end
end

T['answering No to the confirm does nothing'] = function()
  tree()
  local before = snapshot(claude)
  start()
  open_drawer()
  child.lua('_G.answer = 2')
  cursor_to('Alpha topic')
  child.type_keys('D')
  wait_for(function() return #child.lua_get('_G.confirms') == 1 end, 'confirm')
  child.lua('vim.wait(50)')
  eq(snapshot(claude), before)
  eq(#trash_dirs(), 0)
  eq(find('Alpha topic') ~= nil, true)
end

T['lines Claude appends to history.jsonl while it is rewritten are kept'] = function()
  tree()
  start()
  local appended = hist(C, 'typed meanwhile', 2000)
  child.lua([[
    local line = ...
    local n = 0
    require('agent-ide.trash_history')._before_rename = function(path)
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
    require('agent-ide.trash_fs')._rename = function(a, b)
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
  child.lua([[require('agent-ide.trash_fs')._rename = function(a, b)
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
  write(old .. '/manifest.json', '{"version":1,"id":"' .. A .. '","complete":true}')
  write(new .. '/manifest.json', '{"version":1,"id":"' .. B .. '","complete":true}')
  start({ trash = { keep_days = 7 } })
  wait_for(function() return vim.uv.fs_stat(old) == nil end, 'old purged')
  eq(vim.uv.fs_stat(new) ~= nil, true)
end

-- Safety ----------------------------------------------------------------------------------------

local function transcript_path(id) return claude .. '/projects/' .. slug .. '/' .. id .. '.jsonl' end

-- trash.delete of `id` (default A) called directly in the child: { dir|nil, err|nil, left|nil }.
local function tdelete(id)
  return child.lua_get('{ require("agent-ide.trash").delete(...) }', { id or A, transcript_path(id or A), { title = 'Alpha topic' } })
end

local function our_tmp_files()
  local out = {}
  for name in vim.fs.dir(claude) do
    if name:find('agent-ide', 1, true) then out[#out + 1] = name end
  end
  return out
end

local STEPS = { 'folder', 'manifest', 'history_copy', 'move', 'history', 'complete' }

T['a failure at each of the six steps leaves Claude\'s folder as it was and nothing in the trash'] = function()
  start()
  for _, name in ipairs(STEPS) do
    vim.fn.delete(claude, 'rf')
    tree()
    local before = snapshot(claude)
    child.lua('local name = ...; require("agent-ide.trash")._step = function(s) if s == name then return "injected " .. s end end', { name })
    local res = tdelete()
    eq({ name, res[1], res[2] }, { name, vim.NIL, 'injected ' .. name })
    eq(snapshot(claude), before)
    eq(trash_dirs(), {})
    eq(our_tmp_files(), {})
  end
end

T['a failing undo keeps the trash folder, says what is where, and the entry restores'] = function()
  tree()
  local before = snapshot(claude)
  start()
  -- step 6 fails, and so does every write after it: the history lines cannot go back
  child.lua([[
    local jf = require('agent-ide.util.jsonfile')
    require('agent-ide.trash')._step = function(s)
      if s == 'complete' then
        jf._write = function() return nil, 'ENOSPC: no space left on device' end
        return 'injected complete'
      end
    end
  ]])
  local res = tdelete()
  local dir = trash_dirs()[1]
  eq(res[1], vim.NIL)
  eq(vim.startswith(res[2], 'injected complete; the session\'s history lines are not back in ' .. claude .. '/history.jsonl (they are in '
    .. dir .. '/history.jsonl): '), true)
  eq(vim.endswith(res[2], '(the trash folder ' .. dir .. ' is kept)'), true)
  -- nothing lost: the lines are in the trash, the files are back
  eq(read(dir .. '/history.jsonl'), hist(A, 'a first', 1001) .. hist(A, 'a second "quoted"', 1003))
  local now = snapshot(claude)
  for rel, v in pairs(before) do
    if rel ~= 'history.jsonl' then eq({ rel, now[rel] }, { rel, v }) end
  end
  -- listed as incomplete; restore merges the lines back
  child.lua('require("agent-ide.util.jsonfile")._write = function(fd, d, o) return vim.uv.fs_write(fd, d, o) end')
  local items = child.lua_get('vim.tbl_map(function(i) return { i.incomplete, i.manifest.complete } end, require("agent-ide.trash").list())')
  eq(items, { { true, false } })
  child.lua([[vim.ui.select = function(items, opts, cb)
    if opts.prompt == 'Trashed sessions' then
      _G.label = opts.format_item(items[1])
      return cb(items[1])
    end
    cb('Restore')
  end]])
  child.lua('require("agent-ide.ui.delete").command("")')
  eq(vim.startswith(child.lua_get('_G.label'), '[incomplete] '), true)
  eq(last_note(), 'Agent-IDE: restored')
  eq(snapshot(claude), before)
  eq(trash_dirs(), {})
end

T['an entry that cannot be put back stays in the trash and the message names it'] = function()
  tree()
  start()
  child.lua([[
    local fs = require('agent-ide.trash_fs')
    require('agent-ide.trash')._step = function(s)
      if s == 'history' then
        fs._rename = function(a, b)
          if a:find('/agent-ide/trash/', 1, true) and a:find('file%-history') then return nil, 'EACCES: permission denied' end
          return vim.uv.fs_rename(a, b)
        end
        return 'injected history'
      end
    end
  ]])
  local res = tdelete()
  local dir = trash_dirs()[1]
  eq(res[2], ('injected history; %s/file-history/%s could not be put back; it is in %s/file-history/%s (EACCES: permission denied) (the trash folder %s is kept)')
    :format(claude, A, dir, A, dir))
  eq(read(dir .. '/file-history/' .. A .. '/f1@v1'), 'old file ' .. A)
  eq(read(transcript_path(A)) ~= nil, true) -- the others went back
  eq(read(claude .. '/history.jsonl'), HISTORY) -- never touched
end

T['across file systems: a source that cannot be fully removed still counts as moved, the user is told'] = function()
  tree()
  local before = snapshot(claude)
  start()
  child.lua([[require('agent-ide.trash_fs')._rename = function(a, b)
    if a:find('/agent-ide/trash/', 1, true) then return vim.uv.fs_rename(a, b) end
    return nil, 'EXDEV: cross-device link not permitted'
  end]])
  local sub = claude .. '/projects/' .. slug .. '/' .. A .. '/subagents'
  vim.uv.fs_chmod(sub, 320) -- 0500: its file cannot be removed
  open_drawer()
  delete('Alpha topic')
  vim.uv.fs_chmod(sub, 448)
  wait_for(function() return find('Alpha topic') == nil end, 'deleted')
  local note = last_note()
  eq(vim.startswith(note, 'Agent-IDE: moved to the trash (:AgentsTrash to restore); could not remove from Claude\'s folder: '), true)
  eq(note:find(sub .. '/agent-1.jsonl', 1, true) ~= nil, true)
  -- the full copy is in the trash, every file of A is there with its content
  local t = snapshot(trash_dirs()[1])
  for rel, v in pairs(before) do
    if rel:find(A, 1, true) and not rel:find('subagents$') then eq({ rel, t[rel] }, { rel, v }) end
  end
  eq(read(sub .. '/agent-1.jsonl'), 'sub ' .. A .. '\n') -- the left-over source
  -- the copy kept the read-only folder; purging it still works
  local copy_sub = trash_dirs()[1] .. '/projects/' .. slug .. '/' .. A .. '/subagents'
  eq(vim.uv.fs_stat(copy_sub).mode % 512, 320)
  child.lua('_G.answer = 1')
  child.lua('require("agent-ide.ui.delete").command("empty")')
  eq(trash_dirs(), {})
end

T['across file systems with an undo: a partly removed source keeps its full copy in the trash'] = function()
  tree()
  start()
  child.lua([[
    require('agent-ide.trash_fs')._rename = function(a, b)
      if a:find('/agent-ide/trash/', 1, true) then return vim.uv.fs_rename(a, b) end
      return nil, 'EXDEV: cross-device link not permitted'
    end
    require('agent-ide.trash')._step = function(s) if s == 'complete' then return 'injected complete' end end
  ]])
  local sub = claude .. '/projects/' .. slug .. '/' .. A .. '/subagents'
  vim.uv.fs_chmod(sub, 320)
  local res = tdelete()
  vim.uv.fs_chmod(sub, 448)
  local dir = trash_dirs()[1]
  eq(res[2]:find(('%s/projects/%s/%s was only partly removed; its full copy is in %s/projects/%s/%s'):format(claude, slug, A, dir, slug, A), 1, true) ~= nil, true)
  eq(read(dir .. '/projects/' .. slug .. '/' .. A .. '/subagents/agent-1.jsonl'), 'sub ' .. A .. '\n')
  eq(read(dir .. '/projects/' .. slug .. '/' .. A .. '/tool-results/r1.txt'), 'result ' .. A .. '\n')
  eq(read(claude .. '/history.jsonl'), HISTORY) -- the lines went back
end

T['a short write of the new history.jsonl fails the delete; nothing changes, no temp file stays'] = function()
  tree()
  local before = snapshot(claude)
  start()
  child.lua([[
    local jf = require('agent-ide.util.jsonfile')
    require('agent-ide.trash')._step = function(s)
      if s == 'history' then
        -- writes a little, then reports that nothing more goes in (a full disk)
        local n = 0
        jf._write = function(fd, data, off)
          n = n + 1
          if n == 1 then return vim.uv.fs_write(fd, data:sub(1, 10), off) end
          return 0
        end
      end
    end
  ]])
  local res = tdelete()
  eq(res[1], vim.NIL)
  eq(res[2]:find('write made no progress', 1, true) ~= nil, true)
  eq(snapshot(claude), before)
  eq(trash_dirs(), {})
  eq(our_tmp_files(), {})
end

T['a line written into the old history.jsonl after the rename is carried over'] = function()
  tree()
  start()
  local late = hist(C, 'written to the old file', 2001)
  local seam = [[
    local line = ...
    local h = require('agent-ide.trash_history')
    local fd
    -- a writer that opened the file before the rename and writes after it
    h._before_rename = function(path) fd = fd or vim.uv.fs_open(path, 'a', 384) end
    h._after_rename = function()
      if fd then vim.uv.fs_write(fd, line, -1); vim.uv.fs_close(fd); fd = nil end
    end
  ]]
  child.lua(seam, { late })
  local res = tdelete()
  eq(res[2], nil)
  eq(read(claude .. '/history.jsonl'), hist(B, 'b first', 1000) .. 'not json at all ' .. A .. '\n'
    .. hist(C, 'c one', 1002) .. hist(B, 'b last', 1004) .. late)
  -- a line of the deleted session written that way goes to the trash, not back to Claude
  vim.fn.delete(claude, 'rf')
  tree()
  local mine = hist(B, 'b written late', 2002)
  child.lua(seam, { mine })
  res = tdelete(B)
  eq(res[2], nil)
  eq(read(claude .. '/history.jsonl'), hist(A, 'a first', 1001) .. 'not json at all ' .. A .. '\n' .. hist(C, 'c one', 1002)
    .. hist(A, 'a second "quoted"', 1003))
  eq(read(res[1] .. '/history.jsonl'), hist(B, 'b first', 1000) .. hist(B, 'b last', 1004) .. mine)
  eq(vim.json.decode(read(res[1] .. '/manifest.json')).history_lines, 3)
end

T['a process holding history.jsonl open makes the delete refuse (Linux)'] = function()
  if not vim.uv.fs_stat('/proc/self/fd') then return MiniTest.skip('no /proc') end
  tree()
  local before = snapshot(claude)
  start()
  local f = assert(io.open(claude .. '/history.jsonl', 'ab'))
  local ok, res = pcall(tdelete)
  f:close()
  assert(ok, res)
  eq(res[2], 'a running Claude has its history file open; close it or try later (pid ' .. vim.fn.getpid() .. ')')
  eq(snapshot(claude), before)
  eq(trash_dirs(), {})
end

T['stale temp files of ours next to history.jsonl are removed at the next delete; the mode is kept'] = function()
  tree()
  vim.uv.fs_chmod(claude .. '/history.jsonl', 416) -- 0640
  local old, fresh = claude .. '/.agent-ide-trash-1-1.tmp', claude .. '/.agent-ide-trash-2-2.tmp'
  write(old, 'x')
  write(fresh, 'y')
  vim.uv.fs_utime(old, os.time() - 3600, os.time() - 3600)
  start()
  eq(tdelete()[2], nil)
  eq(vim.uv.fs_stat(old), nil)
  eq(read(fresh), 'y')
  eq(vim.uv.fs_stat(claude .. '/history.jsonl').mode % 4096, 416)
end

T['incomplete trash entries are listed, restorable, never purged by age; empty names them'] = function()
  tree()
  start()
  local root = vim.fn.stdpath('data') .. '/agent-ide/trash'
  local stamp = os.date('%Y%m%d-%H%M%S', os.time() - 30 * 86400)
  -- a crash after the manifest and the history copy, while moving: only the tasks folder moved
  local dir = root .. '/' .. stamp .. '-' .. A
  write(dir .. '/manifest.json', vim.json.encode({ version = 1, id = A, complete = false, deleted_at = os.time() - 30 * 86400,
    title = 'Alpha topic', entries = { { rel = 'projects/' .. slug .. '/' .. A .. '.jsonl', path = transcript_path(A), kind = 'file' },
      { rel = 'tasks/' .. A, path = claude .. '/tasks/' .. A, kind = 'dir' } } }))
  write(dir .. '/history.jsonl', hist(A, 'a first', 1001) .. hist(A, 'a second "quoted"', 1003))
  vim.fn.mkdir(dir .. '/tasks', 'p')
  vim.uv.fs_rename(claude .. '/tasks/' .. A, dir .. '/tasks/' .. A)
  -- no manifest at all, and an old complete one
  local bare = root .. '/' .. stamp .. '-' .. B
  write(bare .. '/projects/x', 'x')
  local done = root .. '/' .. os.date('%Y%m%d-%H%M%S', os.time() - 31 * 86400) .. '-' .. C
  write(done .. '/manifest.json', vim.json.encode({ version = 1, id = C, complete = true, entries = {} }))
  child.lua('_G.purged = nil; require("agent-ide.trash").purge_older(7, function(n) _G.purged = n end)')
  wait_for(function() return child.lua_get('_G.purged') ~= vim.NIL end, 'purge')
  eq(child.lua_get('_G.purged'), 1)
  eq({ vim.uv.fs_stat(dir) ~= nil, vim.uv.fs_stat(bare) ~= nil, vim.uv.fs_stat(done) == nil }, { true, true, true })
  -- empty: its confirm names the incomplete one
  child.lua('_G.answer = 2')
  child.lua('require("agent-ide.ui.delete").command("empty")')
  local msg = child.lua_get('_G.confirms[1]')
  eq(vim.startswith(msg, 'Delete 1 trashed session(s) for good?\n\n1 of them incomplete'), true)
  eq(msg:find('[incomplete] ', 1, true) ~= nil and msg:find('Alpha topic', 1, true) ~= nil, true)
  eq(vim.uv.fs_stat(dir) ~= nil, true)
  -- restore puts back what is there; the history lines that were never removed are not doubled
  eq(child.lua_get('require("agent-ide.trash").list()[1].incomplete'), true)
  eq(child.lua_get('{ require("agent-ide.trash").restore(require("agent-ide.trash").list()[1]) }'), { true })
  eq(read(claude .. '/history.jsonl'), HISTORY)
  eq(read(claude .. '/tasks/' .. A .. '/t.json'), '{}')
  eq(vim.uv.fs_stat(dir), nil)
end

T['restore: a manifest with .. or a path through a link out of Claude\'s folder is refused'] = function()
  tree()
  start()
  local root = vim.fn.stdpath('data') .. '/agent-ide/trash'
  local outside = tmp .. '/outside'
  vim.fn.mkdir(outside, 'p')
  vim.uv.fs_symlink(outside, claude .. '/projects/escape')
  local cases = {
    { rel = 'projects/' .. slug .. '/' .. A .. '.jsonl', path = claude .. '/projects/../../outside/' .. A .. '.jsonl' },
    { rel = 'projects/../' .. A .. '.jsonl', path = transcript_path(A) },
    { rel = 'projects/escape/' .. A .. '.jsonl', path = claude .. '/projects/escape/' .. A .. '.jsonl' },
    { rel = 'projects/escape/new/' .. A .. '.jsonl', path = claude .. '/projects/escape/new/' .. A .. '.jsonl' },
  }
  vim.uv.fs_unlink(transcript_path(A))
  for i, e in ipairs(cases) do
    local dir = root .. '/2026010' .. i .. '-000000-' .. A
    write(dir .. '/manifest.json', vim.json.encode({ version = 1, id = A, complete = true, entries = { { rel = e.rel, path = e.path, kind = 'file' } } }))
    write(dir .. '/' .. e.rel:gsub('%.%./', ''), 'evil\n')
    local got = child.lua_get('{ require("agent-ide.trash").restore({ dir = ..., manifest = vim.json.decode(io.open(... .. "/manifest.json"):read("a")) }) }', { dir })
    eq({ i, got }, { i, { false, 'unexpected entry in the manifest' } })
  end
  eq(vim.fn.readdir(outside), {})
end

T['restore: when its own undo fails, every path that could not return is named'] = function()
  tree()
  local before = snapshot(claude)
  start()
  eq(tdelete()[2], nil)
  local dir = trash_dirs()[1]
  child.lua([[
    require('agent-ide.util.jsonfile')._write = function() return nil, 'ENOSPC: no space left on device' end
    require('agent-ide.trash_fs')._rename = function(a, b)
      if b:find('/agent-ide/trash/', 1, true) and not a:find('session%-env') then return nil, 'EACCES: permission denied' end
      return vim.uv.fs_rename(a, b)
    end
  ]])
  local res = child.lua_get('{ require("agent-ide.trash").restore(require("agent-ide.trash").list()[1]) }')
  eq(res[1], false)
  eq(res[2]:find('ENOSPC', 1, true) ~= nil, true)
  for _, rel in ipairs({ 'projects/' .. slug .. '/' .. A .. '.jsonl', 'projects/' .. slug .. '/' .. A, 'file-history/' .. A, 'tasks/' .. A }) do
    eq({ rel, res[2]:find(claude .. '/' .. rel, 1, true) ~= nil }, { rel, true })
  end
  eq(res[2]:find(claude .. '/session-env/' .. A, 1, true), nil) -- that one did go back to the trash
  eq(read(dir .. '/history.jsonl') ~= nil, true)
  -- nothing is lost: each file is in one of the two places
  local c, t = snapshot(claude), snapshot(dir)
  for rel, v in pairs(before) do
    if rel:find(A, 1, true) then eq({ rel, c[rel] or t[rel] }, { rel, v }) end
  end
end

T[':AgentsTrash: Delete for good asks first, default No'] = function()
  tree()
  start()
  eq(tdelete()[2], nil)
  child.lua([[vim.ui.select = function(items, opts, cb)
    if opts.prompt == 'Trashed sessions' then return cb(items[1]) end
    cb('Delete for good')
  end]])
  child.lua('_G.answer = 2')
  child.lua('require("agent-ide.ui.delete").command("")')
  eq(child.lua_get('_G.defaults'), { 2 })
  eq(vim.startswith(child.lua_get('_G.confirms[1]'), 'Delete this trashed session for good?'), true)
  eq(#trash_dirs(), 1)
  child.lua('_G.answer = 1')
  child.lua('require("agent-ide.ui.delete").command("")')
  eq(#trash_dirs(), 0)
  eq(last_note(), 'Agent-IDE: deleted for good')
end

T['a relative projects_dir is refused (it would follow the current folder)'] = function()
  tree()
  local before = snapshot(claude)
  start({ projects_dir = 'claude/projects' })
  child.lua('vim.cmd.cd(...)', { tmp })
  eq(child.lua_get('{ require("agent-ide.trash").plan(...) }', { A, transcript_path(A) }), { vim.NIL, 'projects_dir is not an absolute path' })
  eq(child.lua_get('{ require("agent-ide.trash").delete(...) }', { A, transcript_path(A), {} }), { vim.NIL, 'projects_dir is not an absolute path' })
  child.lua('require("agent-ide.config").get().projects_dir = ""')
  eq(child.lua_get('{ require("agent-ide.trash").claude_dir() }'), { vim.NIL, 'projects_dir is not an absolute path' })
  eq(snapshot(claude), before)
end

T['D: the confirm comes first, on the key; then the live command; No spawns nothing'] = function()
  tree()
  start({ live = { interval_ms = 100000 } })
  open_drawer()
  child.lua('_G.answer = 2; _G.order = {}')
  cursor_to('Alpha topic')
  -- the drawer runs other commands meanwhile; only the confirm and the live command count here
  local function order()
    return vim.tbl_filter(function(o) return o == 'confirm' or o == 'spawn echo' end, child.lua_get('_G.order'))
  end
  child.type_keys('D')
  -- synchronous: the confirm already ran when the key returned
  eq(order(), { 'confirm' })
  child.lua('vim.wait(100)')
  eq(order(), { 'confirm' })
  child.lua('_G.answer = 1; _G.order = {}')
  delete('Alpha topic')
  wait_for(function() return find('Alpha topic') == nil end, 'deleted')
  eq(order(), { 'confirm', 'spawn echo' })
end

T['D: what changed while the confirm was open is checked again; nothing moves'] = function()
  tree()
  local before = snapshot(claude)
  start({ live = { interval_ms = 100000 } })
  open_drawer()
  -- a buffer of the session found by its variables (any name): text typed into it meanwhile
  child.lua([[
    local id = ...
    _G.pbuf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(_G.pbuf, 'agents://repo/some title')
    vim.b[_G.pbuf].agent_ide_session = id
    vim.b[_G.pbuf].agent_ide_kind = 'prompt'
    _G.on_confirm = function() vim.api.nvim_buf_set_lines(_G.pbuf, 0, -1, false, { 'typed meanwhile' }) end
  ]], { A })
  delete('Alpha topic')
  eq(#child.lua_get('_G.confirms'), 1)
  eq(last_note(), 'Agent-IDE: not deleted: its prompt holds unsent text')
  eq(snapshot(claude), before)
  -- no longer parked meanwhile
  child.lua('vim.api.nvim_buf_set_lines(_G.pbuf, 0, -1, false, {})')
  child.lua([[
    local id, cwd = ...
    _G.on_confirm = function()
      require('agent-ide.session').open({ id = id, cwd = cwd }).state = 'idle'
    end
  ]], { A, repo })
  delete('Alpha topic')
  eq(last_note(), 'Agent-IDE: not deleted: it is active here; park it first (x)')
  eq(snapshot(claude), before)
  eq(trash_dirs(), {})
end

T['D: the session\'s buffers are closed only after the move succeeded'] = function()
  tree()
  start({ live = { interval_ms = 100000 } })
  open_drawer()
  child.lua([[
    local id = ...
    _G.cbuf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(_G.cbuf, 'agents://repo/chat title')
    vim.b[_G.cbuf].agent_ide_session = id
    vim.b[_G.cbuf].agent_ide_kind = 'chat'
    require('agent-ide.trash')._step = function(s) if s == 'complete' then return 'injected complete' end end
  ]], { A })
  delete('Alpha topic')
  eq(last_note(), 'Agent-IDE: not deleted: injected complete')
  eq(child.lua_get('vim.api.nvim_buf_is_valid(_G.cbuf)'), true)
  child.lua('require("agent-ide.trash")._step = nil')
  delete('Alpha topic')
  wait_for(function() return find('Alpha topic') == nil end, 'deleted')
  eq(child.lua_get('vim.api.nvim_buf_is_valid(_G.cbuf)'), false)
end

-- Not a budget: reports how long the synchronous history part takes on a 50 MB file.
T['measure: delete with a 50 MB history.jsonl (a note, not a budget)'] = function()
  tree()
  local parts, size = { HISTORY }, #HISTORY
  local filler = hist(C, ('x'):rep(180), 999)
  while size < 50 * 1024 * 1024 do
    parts[#parts + 1] = filler
    size = size + #filler
  end
  write(claude .. '/history.jsonl', table.concat(parts), 384)
  start()
  local res = child.lua_get([[(function(...)
    local t0 = vim.uv.hrtime()
    local r = { require('agent-ide.trash').delete(...) }
    return { r[2] or false, (vim.uv.hrtime() - t0) / 1e6 }
  end)(...)]], { A, transcript_path(A), {} })
  eq(res[1], false)
  MiniTest.add_note(('delete with a %d MB history.jsonl: %d ms'):format(math.floor(size / 1048576), res[2]))
  eq(vim.uv.fs_stat(claude .. '/history.jsonl').size, size - #hist(A, 'a first', 1001) - #hist(A, 'a second "quoted"', 1003))
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

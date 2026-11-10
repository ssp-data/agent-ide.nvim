-- Fidelity tools and guards: raw view, unknown output, Claude version notice, quit guard, and
-- "history equals live". Each case drives a fresh child Neovim with the fake Claude.
local fake = dofile(vim.fn.getcwd() .. '/tests/fake.lua')
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()

local FIXTURE_ID = '11111111-1111-4111-8111-111111111111'
local FIXTURE = vim.fn.getcwd() .. '/tests/fixtures/projects/-home-u-git-alpha/' .. FIXTURE_ID .. '.jsonl'

local tmp, repo, projects, log, asked, fixture_path

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    tmp = vim.uv.fs_realpath(tmp)
    repo, projects, asked = tmp .. '/repo', tmp .. '/projects', tmp .. '/asked'
    vim.fn.mkdir(repo, 'p')
    vim.fn.system({ 'git', 'init', '-q', repo })
    local dir = projects .. '/-repo'
    vim.fn.mkdir(dir, 'p')
    fixture_path = dir .. '/' .. FIXTURE_ID .. '.jsonl'
    local lines = {}
    for i, l in ipairs(vim.fn.readfile(FIXTURE)) do lines[i] = l:gsub('/home/u/git/alpha', repo) end
    vim.fn.writefile(lines, fixture_path)
  end,
  post_case = function()
    child.stop()
    vim.uv.os_unsetenv('FAKE_CLAUDE_LOG')
    vim.fn.delete(tmp, 'rf')
  end,
  post_once = function() child.stop() end,
} })

-- Exact lines Claude "writes" (the scenario emits them byte for byte) -----------------------------

local INIT = '{"type":"system","subtype":"init","session_id":"x","model":"claude-haiku-5-5-20261001",'
  .. '"permissionMode":"default","slash_commands":["compact"],"claude_code_version":"2.1.306"}'
local SAY = '{"type":"assistant","message":{"id":"m","type":"message","role":"assistant",'
  .. '"content":[{"type":"text","text":"Hi there ü"}]}}'
local RESULT = '{"type":"result","subtype":"success","is_error":false,"result":"Hi there ü"}'
local function raw(s) return { emit_raw = s .. '\n' } end

local function flat(...)
  local out = {}
  for _, part in ipairs({ ... }) do
    if part[1] then vim.list_extend(out, part) else out[#out + 1] = part end
  end
  return out
end

-- Child helpers ---------------------------------------------------------------------------

---@param opts? { env?: table, config?: table }
local function start(steps, opts)
  opts = opts or {}
  local cmd
  cmd, log = fake.cmd(steps or {})
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[
    local log, asked, env, cfg = ...
    vim.env.TMUX = nil
    vim.uv.os_setenv('FAKE_CLAUDE_LOG', log)
    for k, v in pairs(env) do vim.uv.os_setenv(k, v) end
    _G.notes, _G.levels, _G.confirms, _G.answer = {}, {}, {}, 2
    vim.notify = function(msg, level) table.insert(_G.notes, msg); table.insert(_G.levels, level) end
    vim.ui.select = function() end
    vim.api.nvim_list_uis = function() return { {} } end -- the test child has no UI; the quit guard needs one
    vim.fn.confirm = function(msg, choices, default)
      table.insert(_G.confirms, { msg = msg, choices = choices, default = default })
      vim.fn.writefile({ 'asked' }, asked, 'a') -- survives the child's exit
      return _G.answer
    end
    require('agent-ide').setup(cfg)
  ]], { log, asked, opts.env or {}, vim.tbl_deep_extend('force', {
    projects_dir = projects,
    helper = { enabled = false },
    live = { interval_ms = 50, cmd = { 'echo', '[]' } },
    claude = { cmd = cmd },
  }, opts.config or {}) })
end

local function wait_for(cond, what, ms)
  local ok = vim.wait(ms or 5000, cond, 20)
  if not ok then error('timed out waiting for ' .. what, 2) end
end

local function has_line(lines, text, from)
  for i = from or 1, #lines do
    if lines[i] == text or lines[i]:find(text, 1, true) then return i end
  end
end

---Open the chat of a new session (or of the fixture session) and put the cursor in its transcript.
local function open_chat(fixture)
  return child.lua([[
    local repo, id, path = ...
    local s = require('agent-ide.session').open({ id = id, cwd = repo, path = path, title = id and 'Alpha basics' })
    _G.S = s
    local chat = require('agent-ide.ui.chat')
    chat.open(s, { key = repo, name = 'repo', root = repo, sessions = {} })
    vim.api.nvim_set_current_win(chat._windows().transcript)
    return s.id
  ]], { repo, fixture and FIXTURE_ID or nil, fixture and fixture_path or nil })
end

local function send(text) child.lua('assert(_G.S:send(...))', { text }) end
local function state() return child.lua_get('_G.S.state') end
local function cur_lines() return child.lua_get('vim.api.nvim_buf_get_lines(0, 0, -1, false)') end
local function cur_name() return child.lua_get('(vim.b[0].agent_ide_kind or "") .. "/" .. (vim.b[0].agent_ide_session or "")') end
local function cur_row() return child.lua_get('vim.api.nvim_win_get_cursor(0)[1]') end
local function transcript()
  return child.lua_get('vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(require("agent-ide.ui.chat")._windows().transcript), 0, -1, false)')
end

local function fake_ins()
  local out = {}
  for _, l in ipairs(fake.log(log)) do
    if l['in'] then out[#out + 1] = l['in'] end
  end
  return out
end

-- A process that was killed but not yet reaped (zombie) is not alive.
local function alive(pid)
  if vim.uv.kill(pid, 0) ~= 0 then return false end
  local f = io.open('/proc/' .. pid .. '/stat')
  if not f then return false end
  local stat = f:read('*a')
  f:close()
  return stat:match('^%d+ %b() (%a)') ~= 'Z'
end

-- Raw view ---------------------------------------------------------------------------------

T['raw view lists every line sent and received, in order, byte-exact'] = function()
  start(flat({ expect = 'Héllo' }, raw(INIT), raw(SAY), raw(RESULT)))
  local id = open_chat()
  send('Héllo "q" \\ x')
  wait_for(function() return state() == 'idle' end, 'turn end')
  local transcript_win = child.lua_get('vim.api.nvim_get_current_win()')
  child.type_keys('gr')
  eq(cur_name(), 'raw/' .. id)
  local sent = fake_ins()
  eq(#sent, 2) -- the `initialize` request first, then the prompt
  eq(fake.is_init(sent[1]), true)
  eq(cur_lines(), { '>> ' .. sent[1], '>> ' .. sent[2], '<< ' .. INIT, '<< ' .. SAY, '<< ' .. RESULT })
  eq(child.lua_get('{ vim.bo.buftype, vim.bo.filetype, vim.bo.modifiable }'), { 'nofile', '', false })
  eq(child.lua_get('vim.api.nvim_get_current_win()'), transcript_win)
  eq(cur_row(), 5)
  -- q returns to the chat transcript, in the same window
  child.type_keys('q')
  eq(child.lua_get('vim.api.nvim_get_current_win()'), transcript_win)
  eq(cur_name(), 'chat/' .. id)
  eq(has_line(transcript(), 'Hi there ü') ~= nil, true)
  -- gr again from the raw view returns too
  child.type_keys('gr')
  eq(child.lua_get('vim.bo.buftype'), 'nofile')
  child.type_keys('gr')
  eq(cur_name(), 'chat/' .. id)
end

T['raw view updates while open; the cursor follows only from the last line'] = function()
  start(flat({ expect = 'Go' }, raw(INIT), { sleep_ms = 600 }, raw('{"type":"mystery","n":"A"}'),
    { sleep_ms = 600 }, raw('{"type":"mystery","n":"B"}'), { sleep_ms = 300 }, raw(RESULT)))
  open_chat()
  send('Go')
  wait_for(function() return #fake_ins() == 2 end, 'prompt received')
  wait_for(function() return child.lua_get('#_G.S.raw') == 3 end, 'init received')
  child.type_keys('gr')
  eq(#cur_lines(), 3)
  wait_for(function() return has_line(cur_lines(), '<< {"type":"mystery","n":"A"}') ~= nil end, 'A appended')
  eq(cur_row(), #cur_lines()) -- was on the last line: follows
  child.type_keys('gg')
  wait_for(function() return has_line(cur_lines(), '<< {"type":"mystery","n":"B"}') ~= nil end, 'B appended')
  eq(cur_row(), 1) -- was not on the last line: stays
  wait_for(function() return state() ~= 'busy' end, 'turn end') -- 'done': the chat is not on screen
  local lines = cur_lines()
  eq(lines[#lines], '<< ' .. RESULT)
  eq(#lines, 6)
end

T['raw view of a capped session says how many lines were dropped'] = function()
  start()
  child.lua([[
    local s = require('agent-ide.session').open({ cwd = ... })
    _G.S = s
    for i = 1, 5003 do s:_raw('in', 'x' .. i) end
    require('agent-ide.ui.raw').open(s)
  ]], { repo })
  eq(child.lua_get('_G.S.raw_dropped'), 3)
  local lines = cur_lines()
  eq(#lines, 5001)
  eq({ lines[1], lines[2], lines[#lines] }, { '… 3 earlier lines dropped (cap 5000)', '<< x4', '<< x5003' })
  -- live: the oldest line goes, the header counts on
  child.lua('_G.S:_raw("out", "y")')
  lines = cur_lines()
  eq(#lines, 5001)
  eq({ lines[1], lines[2], lines[#lines] }, { '… 4 earlier lines dropped (cap 5000)', '<< x5', '>> y' })
  eq(cur_row(), 5001)
end

T['raw view of a session that never ran here shows the transcript file (async, in chunks)'] = function()
  start()
  open_chat(true)
  child.lua('require("agent-ide.ui.raw")._chunk = 64')
  child.type_keys('gr')
  local want = vim.list_extend({ '-- transcript file: ' .. FIXTURE_ID .. '.jsonl --' }, vim.fn.readfile(fixture_path))
  wait_for(function() return #cur_lines() == #want end, 'file read')
  eq(cur_lines(), want)
  eq(cur_lines()[1]:find('/', 1, true), nil) -- basename only
  eq(child.lua_get('vim.bo.modifiable'), false)
  child.type_keys('q')
  wait_for(function() return has_line(cur_lines(), '## You') ~= nil end, 'chat back')
end

T['a session that starts running while its file is shown switches to the live lines'] = function()
  start(flat({ expect = 'More' }, raw(INIT), raw(SAY), raw(RESULT)))
  open_chat(true)
  child.type_keys('gr')
  wait_for(function() return #cur_lines() > 3 end, 'file read')
  send('More')
  wait_for(function() return state() ~= 'busy' end, 'turn end')
  local sent = fake_ins()
  eq(cur_lines(), { '>> ' .. sent[1], '>> ' .. sent[2], '<< ' .. INIT, '<< ' .. SAY, '<< ' .. RESULT })
end

T['unknown objects and garbage lines are folds in the transcript and << lines in the raw view'] = function()
  start(flat({ expect = 'Go' }, raw(INIT), raw('not json at all'), raw('{"type":"mystery","n":1}'),
    raw('{"type":"mystery","n":2}'), raw(SAY), raw(RESULT)))
  open_chat()
  send('Go')
  wait_for(function() return state() == 'idle' end, 'turn end')
  local t = transcript()
  local garbage = has_line(t, '▸ unknown: not JSON')
  local first = has_line(t, '▸ unknown: mystery')
  local second = has_line(t, '▸ unknown: mystery', first + 1)
  eq({ garbage ~= nil, first ~= nil, second ~= nil }, { true, true, true })
  -- they are folds (closed): the header line is where the fold starts
  eq(child.lua_get('vim.fn.foldclosed(...)', { second }), second)
  child.type_keys('gr')
  local r = cur_lines()
  eq(has_line(r, '<< not json at all') ~= nil, true)
  local m1 = has_line(r, '<< {"type":"mystery","n":1}')
  local m2 = has_line(r, '<< {"type":"mystery","n":2}')
  eq({ m1 ~= nil, m2 ~= nil }, { true, true })
  child.type_keys('q')

  -- gR on the second unknown fold lands on its raw line
  child.lua('vim.api.nvim_win_set_cursor(0, { ..., 0 })', { second })
  child.type_keys('gR')
  eq(vim.startswith(cur_name(), 'raw/'), true)
  eq(cur_row(), m2)
  child.type_keys('q')
  -- on the first one
  child.lua('vim.api.nvim_win_set_cursor(0, { ..., 0 })', { first })
  child.type_keys('gR')
  eq(cur_row(), m1)
  child.type_keys('q')
  -- on a line that is not an unknown fold: the raw view opens, at its end
  child.lua('vim.api.nvim_win_set_cursor(0, { 1, 0 })')
  child.type_keys('gR')
  eq(vim.startswith(cur_name(), 'raw/'), true)
  eq(cur_row(), #cur_lines())
end

T['gr can be disabled with keys.chat.raw = false'] = function()
  start(nil, { config = { keys = { chat = { raw = false } } } })
  open_chat()
  eq(child.lua_get('vim.fn.maparg("gr", "n", false, true).buffer'), vim.NIL)
  eq(child.lua_get('vim.fn.maparg("gR", "n", false, true).buffer'), 1)
end

T['the chat help lists gr and gR'] = function()
  start()
  open_chat()
  child.type_keys('g?')
  local lines = cur_lines()
  eq(has_line(lines, 'gr  ') ~= nil, true)
  eq(has_line(lines, 'gR  ') ~= nil, true)
end

-- Claude version notice ----------------------------------------------------------------------

local NOTICE = 'Agent-IDE: tested with Claude Code 2.1.306, found 9.9.9; unknown output will show as folds'

T['version.parse takes the first x.y.z'] = function()
  start()
  local parse = function(s) return child.lua_get('require("agent-ide.claude.version").parse(...)', { s }) end
  eq(parse('2.1.306 (Claude Code)'), '2.1.306')
  eq(parse('claude 10.20.30-beta 1.2.3'), '10.20.30')
  eq(parse('no version'), vim.NIL)
  eq(child.lua_get('require("agent-ide.claude.version").tested'), { '2.1.306' })
end

T['an untested Claude version is announced once, at the first process start'] = function()
  start(flat({ expect = 'One' }, raw(INIT), raw(RESULT), { expect = 'Two' }, raw(RESULT)),
    { env = { FAKE_CLAUDE_VERSION = '9.9.9 (Claude Code)' } })
  open_chat()
  eq(child.lua_get('_G.notes'), {})
  send('One')
  wait_for(function() return #child.lua_get('_G.notes') == 1 end, 'notice')
  eq(child.lua_get('_G.notes'), { NOTICE })
  eq(child.lua_get('_G.levels'), { vim.log.levels.INFO })
  eq(child.lua_get('require("agent-ide.claude.version").found()'), '9.9.9')
  wait_for(function() return state() == 'idle' end, 'turn end')
  -- a second session, a second process: no second notice
  child.lua('local s2 = require("agent-ide.session").open({ cwd = ... }); assert(s2:send("Two"))', { repo })
  vim.uv.sleep(400)
  eq(child.lua_get('#_G.notes'), 1)
end

T['the tested Claude version, a failing command and unparsable output give no notice'] = function()
  start(flat({ expect = 'One' }, raw(INIT), raw(RESULT)))
  open_chat()
  send('One')
  wait_for(function() return child.lua_get('require("agent-ide.claude.version").found()') == '2.1.306' end, 'version')
  wait_for(function() return state() == 'idle' end, 'turn end')
  eq(child.lua_get('_G.notes'), {})

  for _, cmd in ipairs({ { 'sh', '-c', 'exit 3', 'sh' }, { 'echo', 'hello' }, { 'no-such-claude-binary' } }) do
    start(nil, { config = { claude = { cmd = cmd } } })
    child.lua('require("agent-ide.claude.version").check()')
    vim.uv.sleep(300)
    eq({ child.lua_get('_G.notes'), child.lua_get('require("agent-ide.claude.version").found()') }, { {}, vim.NIL })
  end
end

T['claude.version_check = false skips the check'] = function()
  start(flat({ expect = 'One' }, raw(INIT), raw(RESULT)),
    { env = { FAKE_CLAUDE_VERSION = '9.9.9' }, config = { claude = { version_check = false } } })
  open_chat()
  send('One')
  wait_for(function() return state() == 'idle' end, 'turn end')
  vim.uv.sleep(300)
  eq(child.lua_get('_G.notes'), {})
  eq(child.lua_get('require("agent-ide.claude.version").found()'), vim.NIL)
end

-- Quit guard ---------------------------------------------------------------------------------

local WORK = flat({ expect = 'Work' }, raw(INIT), { ignore_stdin = true })

-- True while the child Neovim answers (`child.is_running` does not notice an exit by `:qa`).
local function responds() return (pcall(child.api.nvim_eval, '1')) end

-- Type a quit command without waiting for an answer: Neovim may refuse (an error) or be gone.
local function quit(keys) child.api_notify.nvim_input(keys) end

-- Neovim shows its refusal with a hit-enter prompt when a UI is attached; headless it does not.
local function dismiss_hit_enter()
  if child.lua_get('vim.api.nvim_get_mode().blocking') then child.api_notify.nvim_input('<CR>') end
end

T['quitting with working sessions asks; Cancel keeps everything, Quit stops the processes'] = function()
  start(WORK)
  open_chat()
  send('Work')
  child.lua('local s2 = require("agent-ide.session").open({ cwd = ... }); _G.S2 = s2; assert(s2:send("Work"))', { repo })
  wait_for(function() return child.lua_get('#_G.S.raw >= 2 and #_G.S2.raw >= 2') end, 'both running')
  local pids = child.lua_get('{ _G.S.pid, _G.S2.pid }')
  local buf, win = child.lua_get('vim.api.nvim_get_current_buf()'), child.lua_get('vim.api.nvim_get_current_win()')
  child.lua('vim.api.nvim_win_set_cursor(0, { 1, 0 })')
  local modified_now = 'vim.tbl_map(function(b) return b.name end, vim.fn.getbufinfo({ bufmodified = 1 }))'
  local nbufs = child.lua_get('#vim.fn.getbufinfo()')
  local modified = child.lua_get(modified_now) -- the transcript counts: Neovim keeps it modified, unwritable

  quit(':qa<CR>') -- the stub answers Cancel
  wait_for(function() return #child.lua_get('_G.confirms') == 1 end, 'question')
  eq(child.lua_get('_G.confirms[1]'), { msg = 'Agent-IDE: 2 session(s) still working. Quit anyway?',
    choices = '&Quit\n&Cancel', default = 2 })
  dismiss_hit_enter()
  eq(responds(), true)
  eq(child.lua_get('vim.fn.execute("messages")'):find('No write since last change', 1, true) ~= nil, true)
  eq(child.lua_get('{ _G.S.owned, _G.S.state, _G.S2.owned, _G.S2.state }'), { true, 'busy', true, 'busy' })
  eq({ alive(pids[1]), alive(pids[2]) }, { true, true })
  -- the window, its buffer and the buffer list are as before; nothing is left modified
  eq({ child.lua_get('vim.api.nvim_get_current_buf()'), child.lua_get('vim.api.nvim_get_current_win()') }, { buf, win })
  eq(child.lua_get(modified_now), modified)
  eq(child.lua_get('#vim.fn.getbufinfo()'), nbufs)

  child.lua('_G.answer = 1')
  quit(':qa<CR>')
  wait_for(function() return not responds() end, 'Neovim to exit')
  wait_for(function() return not alive(pids[1]) and not alive(pids[2]) end, 'processes to stop')
  eq(#vim.fn.readfile(asked), 2) -- one question per quit
end

T['Cancel also holds for :wqa and :xa: Neovim stays, no file is written, sessions untouched'] = function()
  start(WORK)
  open_chat()
  send('Work')
  wait_for(function() return child.lua_get('#_G.S.raw') >= 2 end, 'running')
  local cwd = tmp .. '/cwd'
  vim.fn.mkdir(cwd, 'p')
  -- a named buffer of the user's, modified: Neovim's own :wqa writes it before it refuses
  child.lua('vim.cmd.cd(...); vim.cmd.edit("mine.txt"); vim.api.nvim_buf_set_lines(0, 0, -1, false, { "mine" })', { cwd })
  local pid = child.lua_get('_G.S.pid')
  for i, cmd in ipairs({ ':wqa<CR>', ':xa<CR>' }) do
    quit(cmd)
    wait_for(function() return responds() and #child.lua_get('_G.confirms') == i end, 'question ' .. cmd)
    dismiss_hit_enter()
    eq(responds(), true)
    eq(child.lua_get('_G.S.state'), 'busy')
    eq(alive(pid), true)
    local files = vim.fn.readdir(cwd)
    table.sort(files)
    eq(files, { 'mine.txt' }) -- nothing else was created
  end
  -- observed on 0.12.6: the named modified buffer is written by :wqa before the refusal
  eq(vim.fn.readfile(cwd .. '/mine.txt'), { 'mine' })
end

T['a second quit before the next tick asks again'] = function()
  start(WORK)
  open_chat()
  send('Work')
  wait_for(function() return child.lua_get('#_G.S.raw') >= 2 end, 'running')
  child.lua('pcall(vim.cmd, "qa"); pcall(vim.cmd, "qa")') -- no tick between the two
  eq(#child.lua_get('_G.confirms'), 2)
  eq(responds(), true)
  vim.uv.sleep(100)
  eq(child.lua_get('#vim.fn.getbufinfo({ bufmodified = 1 }) <= 1'), true)
end

T['without a UI there is no question'] = function()
  start(WORK)
  open_chat()
  send('Work')
  wait_for(function() return child.lua_get('#_G.S.raw') >= 2 end, 'running')
  local pid = child.lua_get('_G.S.pid')
  child.lua('vim.api.nvim_list_uis = function() return {} end')
  quit(':qa<CR>')
  wait_for(function() return not responds() end, 'Neovim to exit')
  wait_for(function() return not alive(pid) end, 'process to stop')
  eq(vim.fn.filereadable(asked), 0)
end

T['the raw view has no folds; the transcript folds are back after q'] = function()
  start(flat({ expect = 'Go' }, raw(INIT), raw('{"type":"mystery","n":1}'), raw(SAY), raw(RESULT)))
  open_chat()
  send('Go')
  wait_for(function() return state() ~= 'busy' end, 'turn end')
  local header = has_line(transcript(), '▸ unknown: mystery')
  eq(child.lua_get('vim.fn.foldclosed(...)', { header }), header)
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.chat")._windows().transcript)')
  child.type_keys('gr')
  eq(child.lua_get('{ vim.wo.foldmethod, vim.wo.foldenable, vim.fn.foldclosed(1) }'), { 'manual', false, -1 })
  child.type_keys('q')
  eq(child.lua_get('vim.wo.foldmethod'), 'expr')
  eq(child.lua_get('vim.fn.foldclosed(...)', { header }), header)
end

T['the raw view does not wrap (long lines); the transcript wraps again after q and after :b'] = function()
  start(flat({ expect = 'Go' }, raw(INIT), raw(SAY), raw(RESULT)))
  open_chat()
  send('Go')
  wait_for(function() return state() ~= 'busy' end, 'turn end')
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.chat")._windows().transcript); vim.wo.list = true')
  local opts = '{ vim.wo.wrap, vim.wo.linebreak, vim.wo.list }'
  eq(child.lua_get(opts), { true, true, true })
  child.type_keys('gr')
  eq(child.lua_get(opts), { false, false, false })
  child.type_keys('q')
  eq({ 'after q', child.lua_get(opts) }, { 'after q', { true, true, true } })
  -- the other way back: :b to the transcript buffer
  local tbuf = child.lua_get('vim.api.nvim_get_current_buf()')
  child.type_keys('gr')
  eq(child.lua_get(opts), { false, false, false })
  child.cmd('buffer ' .. tbuf)
  eq(child.lua_get(opts), { true, true, true })
end

T['while the raw view is shown the chat is not on screen; q marks it seen'] = function()
  start(flat({ expect = 'Go' }, raw(INIT), { sleep_ms = 300 }, raw(RESULT)))
  open_chat()
  send('Go')
  wait_for(function() return child.lua_get('#_G.S.raw') >= 2 end, 'running')
  child.type_keys('gr')
  wait_for(function() return state() ~= 'busy' end, 'turn end')
  eq({ state(), child.lua_get('_G.S.visible'), child.lua_get('_G.S.unread') }, { 'done', false, true })
  child.type_keys('q')
  eq({ state(), child.lua_get('_G.S.visible'), child.lua_get('_G.S.unread') }, { 'idle', true, false })
end

T[':qa! and :q! do not ask'] = function()
  for _, cmd in ipairs({ ':qa!<CR>', ':only<CR>:q!<CR>' }) do
    vim.fn.delete(asked)
    start(WORK)
    open_chat()
    send('Work')
    wait_for(function() return child.lua_get('#_G.S.raw') >= 2 end, 'running')
    local pid = child.lua_get('_G.S.pid')
    quit(cmd)
    wait_for(function() return not responds() end, 'Neovim to exit')
    wait_for(function() return not alive(pid) end, 'process to stop')
    eq(vim.fn.filereadable(asked), 0)
  end
end

T['no question when no session is working'] = function()
  start()
  open_chat()
  quit(':qa<CR>')
  wait_for(function() return not responds() end, 'Neovim to exit')
  eq(vim.fn.filereadable(asked), 0)
end

T['closing a window that is not the last asks nothing; the last one asks, also for ZZ and waiting sessions'] = function()
  local ask = { type = 'control_request', request_id = 'p1', request = { subtype = 'can_use_tool', tool_name = 'Write',
    display_name = 'Write', input = { file_path = '/x/a.txt', content = 'hi' }, tool_use_id = 't' } }
  start(flat({ expect = 'Work' }, raw(INIT), { emit = ask }, { ignore_stdin = true }))
  open_chat()
  send('Work')
  wait_for(function() return state() == 'waiting' end, 'waiting')
  child.lua('vim.cmd.wincmd("j")') -- the prompt window
  eq(child.lua_get('#vim.api.nvim_tabpage_list_wins(0) > 1'), true)
  quit(':q<CR>')
  vim.uv.sleep(200)
  eq(child.lua_get('#_G.confirms'), 0)
  eq(responds(), true)

  child.lua('vim.cmd.only()')
  quit('ZZ')
  wait_for(function() return #child.lua_get('_G.confirms') == 1 end, 'question')
  eq(child.lua_get('_G.confirms[1].msg'), 'Agent-IDE: 1 session(s) still working. Quit anyway?')
  dismiss_hit_enter()
  eq(responds(), true)
  eq(state(), 'waiting')
end

T['forced quit commands are recognised'] = function()
  start()
  local forced = function(cmd) return child.lua_get('require("agent-ide.ui.quit_guard")._forced(...)', { cmd }) end
  for _, cmd in ipairs({ 'qa!', 'q!', 'quit!', 'wq!', 'x!', 'xa!', 'wqa!', 'exit!', 'split | q!', '1q!' }) do
    eq({ cmd, forced(cmd) }, { cmd, true })
  end
  for _, cmd in ipairs({ 'qa', 'q', 'wq', 'x', 'w!', 'echo "q!"', 'edit! x', 'q | e!' }) do
    eq({ cmd, forced(cmd) }, { cmd, false })
  end
end

-- History equals live --------------------------------------------------------------------------

-- One turn: the stream objects the fake emits and the records Claude writes to its transcript.
local TURN = {
  prompt = 'List the files',
  blocks = {
    { tool = { id = 't1', name = 'Bash', input = { command = 'ls' }, result = 'main.lua\nREADME.md' } },
    { text = 'Two files.\n\nDone.' },
  },
}

local function turn_steps(t)
  local steps = { { expect = t.prompt }, raw(INIT) }
  for _, b in ipairs(t.blocks) do
    if b.tool then
      steps[#steps + 1] = { emit = { type = 'assistant', message = { id = 'm', type = 'message', role = 'assistant',
        content = { { type = 'tool_use', id = b.tool.id, name = b.tool.name, input = b.tool.input } } } } }
      steps[#steps + 1] = { emit = { type = 'user', message = { role = 'user',
        content = { { type = 'tool_result', tool_use_id = b.tool.id, content = b.tool.result } } } } }
    else
      steps[#steps + 1] = { emit = { type = 'assistant', message = { id = 'm', type = 'message', role = 'assistant',
        content = { { type = 'text', text = b.text } } } } }
    end
  end
  steps[#steps + 1] = raw(RESULT)
  return steps
end

local function turn_records(t)
  local recs = { { type = 'user', uuid = 'u0', message = { role = 'user', content = t.prompt } } }
  for i, b in ipairs(t.blocks) do
    if b.tool then
      recs[#recs + 1] = { type = 'assistant', uuid = 'a' .. i, message = { role = 'assistant', content = {
        { type = 'tool_use', id = b.tool.id, name = b.tool.name, input = b.tool.input } } } }
      recs[#recs + 1] = { type = 'user', uuid = 'r' .. i, message = { role = 'user', content = {
        { type = 'tool_result', tool_use_id = b.tool.id, content = b.tool.result } } } }
    else
      recs[#recs + 1] = { type = 'assistant', uuid = 'a' .. i, message = { role = 'assistant', content = {
        { type = 'text', text = b.text } } } }
    end
  end
  return recs
end

---Write the records as Claude's transcript file and compare, in the child, the chat buffer and
---`render(events)` with `render(parse(file))`, ignoring the events only the live session has.
local function compare_with_file(records)
  local path = tmp .. '/history.jsonl'
  local out = {}
  for i, r in ipairs(records) do out[i] = vim.json.encode(r) end
  vim.fn.writefile(out, path)
  return child.lua([[
    local path = ...
    local render = require('agent-ide.transcript.render')
    local parse = require('agent-ide.transcript.parse')
    local chat = require('agent-ide.ui.chat')
    local tbuf = chat.buffers(_G.S)
    local buffer = vim.api.nvim_buf_get_lines(tbuf, 0, -1, false)
    local live, kept = _G.S.events, {}
    for _, ev in ipairs(live) do
      if not ev.live_only then kept[#kept + 1] = ev end
    end
    local f = assert(io.open(path, 'rb'))
    local from_file = parse.parse_text(f:read('*a'))
    f:close()
    return {
      buffer = buffer,
      live_all = render.render(live).lines,
      live_kept = render.render(kept).lines,
      file = render.render(from_file).lines,
      live_only = #live - #kept,
    }
  ]], { path })
end

T['after a turn the transcript equals the rendered events parsed back from what Claude wrote'] = function()
  start(turn_steps(TURN))
  open_chat()
  send(TURN.prompt)
  wait_for(function() return state() == 'idle' end, 'turn end')
  local r = compare_with_file(turn_records(TURN))
  eq(r.live_only, 0)
  eq(r.buffer, r.file)
  eq(r.live_kept, r.file)
  eq(has_line(r.buffer, '▸ Bash: ls') ~= nil, true)
end

T['events only the live session has are ignored by the history comparison'] = function()
  local steps = turn_steps(TURN)
  table.insert(steps, 3, raw('not json at all'))
  start(steps)
  open_chat()
  send(TURN.prompt)
  wait_for(function() return state() == 'idle' end, 'turn end')
  local r = compare_with_file(turn_records(TURN))
  eq(r.live_only, 1)
  eq(r.buffer, r.live_all) -- the buffer shows the garbage fold
  eq(has_line(r.buffer, '▸ unknown: not JSON') ~= nil, true)
  eq(r.live_kept, r.file) -- and without it, history and live agree
  eq(r.buffer == r.file, false)
end

return T

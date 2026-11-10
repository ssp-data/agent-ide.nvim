-- Chat view integration tests: each case drives a fresh child Neovim with the fake Claude.
local fake = dofile(vim.fn.getcwd() .. '/tests/fake.lua')
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()

local FIXTURE_ID = '11111111-1111-4111-8111-111111111111'
local FIXTURE = vim.fn.getcwd() .. '/tests/fixtures/projects/-home-u-git-alpha/' .. FIXTURE_ID .. '.jsonl'
local ICONS = { open = 'v', closed = '>', project = 'P', waiting = 'W', busy = 'B', idle = 'I', parked = '.',
  done = 'D', failed = 'F', new = '+' }

local tmp, repo, projects, log

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    tmp = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    tmp = vim.uv.fs_realpath(tmp)
    repo = tmp .. '/repo'
    projects = tmp .. '/projects'
    vim.fn.mkdir(repo, 'p')
    vim.fn.system({ 'git', 'init', '-q', repo })
    -- the fixture session, moved into the temporary repo so the fake can run in its folder
    local dir = projects .. '/-repo'
    vim.fn.mkdir(dir, 'p')
    local lines = {}
    for i, l in ipairs(vim.fn.readfile(FIXTURE)) do lines[i] = l:gsub('/home/u/git/alpha', repo) end
    vim.fn.writefile(lines, dir .. '/' .. FIXTURE_ID .. '.jsonl')
  end,
  post_case = function()
    child.stop()
    vim.uv.os_unsetenv('FAKE_CLAUDE_LOG')
    vim.fn.delete(tmp, 'rf')
  end,
  post_once = function() child.stop() end,
} })

-- Scenario steps (see tests/fake_claude.lua) --------------------------------------------

local function init()
  return { emit = { type = 'system', subtype = 'init', session_id = 'x', model = 'claude-haiku-5-5-20261001',
    permissionMode = 'default', slash_commands = { 'compact' }, claude_code_version = '2.1.306' } }
end
local function status() return { emit = { type = 'system', subtype = 'status', status = 'requesting' } } end
local function block_start()
  return { emit = { type = 'stream_event', event = { type = 'content_block_start', index = 0,
    content_block = { type = 'text', text = '' } } } }
end
local function delta(t)
  return { emit = { type = 'stream_event', event = { type = 'content_block_delta', index = 0,
    delta = { type = 'text_delta', text = t } } } }
end
local function say(t)
  return { emit = { type = 'assistant', message = { id = 'm', type = 'message', role = 'assistant',
    content = { { type = 'text', text = t } } } } }
end
local function result(t, is_error)
  return { emit = { type = 'result', subtype = 'success', is_error = is_error or false, result = t } }
end
local function turn(prompt, answer, extra)
  local steps = { { expect = prompt }, init(), status(), block_start(), delta(answer:sub(1, 3)) }
  vim.list_extend(steps, extra or {})
  vim.list_extend(steps, { delta(answer:sub(4)), say(answer), result(answer) })
  return steps
end
local function flat(...)
  local out = {}
  for _, part in ipairs({ ... }) do vim.list_extend(out, part) end
  return out
end

-- Child helpers ---------------------------------------------------------------------------

local function start(steps, live_json)
  local cmd
  cmd, log = fake.cmd(steps or {})
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[
    local log, opts = ...
    vim.env.TMUX = nil
    vim.uv.os_setenv('FAKE_CLAUDE_LOG', log)
    _G.notes = {}
    vim.notify = function(msg) table.insert(_G.notes, msg) end
    require('agent-ide').setup(opts)
  ]], { log, {
    projects_dir = projects,
    helper = { enabled = false },
    live = { interval_ms = 50, cmd = { 'echo', live_json or '[]' } },
    icons_style = 'plain', icons = ICONS,
    claude = { cmd = cmd },
  } })
end

local function wait_for(cond, what, ms)
  local ok = vim.wait(ms or 5000, cond, 20)
  if not ok then error('timed out waiting for ' .. what, 2) end
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

local function drawer_cursor_to(text)
  wait_for(function() return has_line(drawer_lines(), text) ~= nil end, 'drawer line ' .. text)
  local row = has_line(drawer_lines(), text)
  child.lua('local s = require("agent-ide.ui.drawer").state(); vim.api.nvim_set_current_win(s.win); vim.api.nvim_win_set_cursor(s.win, { ..., 0 })', { row })
end

local function wins() return child.lua_get('require("agent-ide.ui.chat")._windows()') end

local function transcript()
  return child.lua_get('vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(require("agent-ide.ui.chat")._windows().transcript), 0, -1, false)')
end

local function prompt_lines()
  return child.lua_get('vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(require("agent-ide.ui.chat")._windows().prompt), 0, -1, false)')
end

local function winbar() return child.lua_get('vim.wo[require("agent-ide.ui.chat")._windows().transcript].winbar') end

local function current()
  return child.lua_get('(function() local s = require("agent-ide.ui.chat").current(); return s and { id = s.id, state = s.state, owned = s.owned, queue = #s.queue } end)()')
end

local function mode() return child.lua_get('vim.api.nvim_get_mode().mode') end

-- Show the drawer (when hidden) and expand `project` (when collapsed).
local function expand(project)
  if child.lua_get('require("agent-ide.ui.drawer").state().win') == vim.NIL then
    child.lua('require("agent-ide").toggle()')
  end
  wait_for(function() return has_line(drawer_lines(), ' P ' .. project .. ' ') ~= nil end, 'project row')
  if has_line(drawer_lines(), '> P ' .. project .. ' ') then
    drawer_cursor_to('> P ' .. project .. ' ')
    child.type_keys('<CR>')
  end
end

-- Open a new session in the `repo` project from the drawer.
local function open_new()
  expand('repo')
  drawer_cursor_to('    + New session')
  child.type_keys('<CR>')
  wait_for(function() return current() ~= vim.NIL end, 'chat open')
end

local function open_fixture()
  expand('repo')
  drawer_cursor_to('Alpha basics')
  child.type_keys('<CR>')
  wait_for(function() return has_line(transcript(), '## You') ~= nil end, 'history loaded')
end

local function fake_ins()
  local out = {}
  for _, l in ipairs(fake.log(log)) do
    if l['in'] then out[#out + 1] = vim.json.decode(l['in']) end
  end
  return out
end

local function type_prompt(text)
  child.type_keys('i', text)
end

-- Tests -------------------------------------------------------------------------------------

T['new session row opens a chat: transcript above, prompt below (8 lines), left of the drawer'] = function()
  start()
  open_new()
  local w = wins()
  local layout = child.lua_get([[(function(w)
    local d = require('agent-ide.ui.drawer').state().win
    local tp = vim.api.nvim_win_get_position(w.transcript)
    local pp = vim.api.nvim_win_get_position(w.prompt)
    local dp = vim.api.nvim_win_get_position(d)
    local tb, pb = vim.api.nvim_win_get_buf(w.transcript), vim.api.nvim_win_get_buf(w.prompt)
    return {
      above = tp[1] < pp[1], same_col = tp[2] == pp[2], left = tp[2] < dp[2],
      height = vim.api.nvim_win_get_height(w.prompt), fix = vim.wo[w.prompt].winfixheight,
      current = vim.api.nvim_get_current_win() == w.prompt,
      tname = vim.api.nvim_buf_get_name(tb), pname = vim.api.nvim_buf_get_name(pb),
      tbt = vim.bo[tb].buftype, tft = vim.bo[tb].filetype, tmod = vim.bo[tb].modifiable,
      pbt = vim.bo[pb].buftype, pft = vim.bo[pb].filetype, pmod = vim.bo[pb].modifiable,
    }
  end)(...)]], { w })
  local id = current().id
  eq(layout, { above = true, same_col = true, left = true, height = 8, fix = true, current = true,
    tname = 'agent-ide://chat/' .. id, pname = 'agent-ide://prompt/' .. id,
    tbt = 'nofile', tft = 'markdown', tmod = false, pbt = 'acwrite', pft = 'markdown', pmod = true })
  eq(winbar(), 'repo · new session · model ? · mode:? · idle')
end

T['<C-CR> in insert mode sends; the answer streams into the transcript; prompt is emptied'] = function()
  start(turn('Hello there', 'Hi, how can I help?', { { sleep_ms = 300 } }))
  open_new()
  type_prompt('Hello there')
  child.type_keys('<C-CR>')
  eq(mode(), 'i')
  eq(prompt_lines(), { '' })
  eq(child.lua_get('vim.bo[vim.api.nvim_win_get_buf(require("agent-ide.ui.chat")._windows().prompt)].modified'), false)
  -- streamed part shows before the turn ends
  wait_for(function() return has_line(transcript(), 'Hi,') ~= nil end, 'streamed text')
  wait_for(function() return current().state == 'idle' end, 'turn end')
  local lines = transcript()
  eq(vim.list_slice(lines, 1, 7), { '', '## You', '', 'Hello there', '', '## Claude', '' })
  eq(has_line(lines, 'Hi, how can I help?') ~= nil, true)
  local bar = winbar()
  eq(bar, 'repo · new session · haiku-5-5 · mode:manual · idle')
  local ins = fake_ins()
  eq(ins[1], { type = 'user', message = { role = 'user', content = 'Hello there' } })
end

T['<leader><CR> in normal mode sends'] = function()
  start(turn('Normal send', 'Done here'))
  open_new()
  type_prompt('Normal send')
  child.type_keys('<Esc>', '\\<CR>')
  wait_for(function() return has_line(transcript(), 'Done here') ~= nil end, 'answer')
  eq(prompt_lines(), { '' })
end

T['empty prompt sends nothing; trailing blank lines are dropped'] = function()
  start(turn('two\\nlines', 'ok'))
  open_new()
  child.type_keys('<C-CR>')
  vim.wait(200)
  eq(fake.log(log), {})
  eq(child.lua_get('require("agent-ide.ui.prompt").text_to_send({ "two", "lines", "", "  ", "" })'), 'two\nlines')
  eq(child.lua_get('require("agent-ide.ui.prompt").text_to_send({ "", " x ", "", "y", "" })'), '\n x \n\ny')
  child.lua('vim.api.nvim_buf_set_lines(0, 0, -1, false, { "two", "lines", "", "" })')
  child.type_keys('<C-CR>')
  wait_for(function() return has_line(transcript(), 'ok') ~= nil end, 'answer')
  eq(fake_ins()[1].message.content, 'two\nlines')
end

T['ZZ hides the prompt, the session stays alive; i in the transcript brings it back in insert mode'] = function()
  start(turn('first', 'answer one'))
  open_new()
  type_prompt('first')
  child.type_keys('<C-CR>', '<Esc>')
  wait_for(function() return current().state == 'idle' and has_line(transcript(), 'answer one') ~= nil end, 'turn end')
  local before = wins()
  child.type_keys('ZZ')
  eq(child.lua_get('vim.api.nvim_win_is_valid(...)', { before.prompt }), false)
  local c = child.lua_get('(function() local s = require("agent-ide.session").all()[1]; return { s.state, s.owned } end)()')
  eq(c, { 'idle', true })
  child.lua('vim.api.nvim_set_current_win(...)', { before.transcript })
  child.type_keys('i')
  local w = wins()
  eq(child.lua_get('vim.api.nvim_get_current_win()'), w.prompt)
  eq(child.lua_get('vim.api.nvim_win_get_height(0)'), 8)
  eq(child.lua_get('vim.api.nvim_buf_get_name(0)'):match('^agent%-ide://prompt/') ~= nil, true)
  eq(mode(), 'i')
  -- <leader>ap from the transcript also recreates it (normal mode)
  child.type_keys('<Esc>')
  child.cmd('quit')
  child.lua('vim.api.nvim_set_current_win(...)', { before.transcript })
  child.type_keys('\\ap')
  eq(child.lua_get('vim.api.nvim_buf_get_name(0)'):match('^agent%-ide://prompt/') ~= nil, true)
  eq(mode(), 'n')
end

T['the prompt is never modified: a draft never blocks :w, :q, ZZ, :wq; the draft survives'] = function()
  start()
  open_new()
  type_prompt('draft')
  eq(child.lua_get('vim.bo.modified'), false) -- also while typing
  child.type_keys('<Esc>')
  eq(child.lua_get('vim.bo.modified'), false)
  child.cmd('write')
  eq(child.lua_get('vim.bo.modified'), false)
  eq(prompt_lines(), { 'draft' })
  local t = wins().transcript
  for _, cmd in ipairs({ 'quit', 'ZZ', 'wq' }) do
    if cmd == 'ZZ' then child.type_keys('ZZ') else child.cmd(cmd) end
    eq(wins().prompt, nil)
    child.lua('vim.api.nvim_set_current_win(...)', { t })
    child.type_keys('i', '<Esc>')
    eq(prompt_lines(), { 'draft' })
  end
end

T[':qa with a draft in the prompt quits Neovim'] = function()
  start()
  open_new()
  type_prompt('draft')
  child.type_keys('<Esc>')
  pcall(child.type_keys, ':qa<CR>') -- the child may exit before type_keys returns
  -- the RPC channel closes once the child has exited
  wait_for(function() return not pcall(child.lua_get, '1') end, 'Neovim to exit', 3000)
end

T[':q! in the prompt discards the draft; i brings an empty prompt back'] = function()
  start()
  open_new()
  local t = wins().transcript
  type_prompt('draft')
  child.type_keys('<Esc>')
  child.cmd('quit!')
  vim.wait(50)
  child.lua('vim.api.nvim_set_current_win(...)', { t })
  child.type_keys('i', '<Esc>')
  eq(prompt_lines(), { '' })
  eq(child.lua_get('{ vim.bo.buftype, vim.bo.filetype, vim.fn.maparg("<C-CR>", "i") ~= "" }'), { 'acwrite', 'markdown', true })
  eq(child.lua_get('vim.api.nvim_buf_get_name(0)'), 'agent-ide://prompt/' .. current().id)
end

-- Transcript of the current chat equals a full render of its session's events.
local function equals_render()
  return child.lua_get([[(function()
    local s = require('agent-ide.ui.chat').current()
    local w = require('agent-ide.ui.chat')._windows().transcript
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
    return vim.deep_equal(lines, require('agent-ide.transcript.render').render(s.events).lines)
  end)()]])
end

local function transcript_props()
  return child.lua_get([[(function()
    local w = require('agent-ide.ui.chat')._windows().transcript
    local b = vim.api.nvim_win_get_buf(w)
    local maps = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(b, 'n')) do maps[m.lhs] = true end
    return { name = vim.api.nvim_buf_get_name(b), bt = vim.bo[b].buftype, ft = vim.bo[b].filetype,
      mod = vim.bo[b].modifiable, i = maps.i == true, fm = vim.wo[w].foldmethod }
  end)()]])
end

T[':bd on the transcript, then reopen: a fresh buffer equal to a full render; live turns still render'] = function()
  start(turn('After bd', 'Still rendering'))
  open_fixture()
  local id = current().id
  child.lua('vim.api.nvim_set_current_win(...)', { wins().transcript })
  child.cmd('bdelete')
  vim.wait(50)
  expand('repo')
  drawer_cursor_to('Alpha basics')
  child.type_keys('<CR>')
  wait_for(function() return has_line(transcript(), '## You') ~= nil end, 'history again')
  eq(transcript_props(), { name = 'agent-ide://chat/' .. id, bt = 'nofile', ft = 'markdown', mod = false, i = true, fm = 'expr' })
  eq(equals_render(), true)
  type_prompt('After bd')
  child.type_keys('<C-CR>')
  wait_for(function() return current().state == 'idle' and has_line(transcript(), 'Still rendering') ~= nil end, 'turn')
  eq(equals_render(), true)
  eq(#child.lua_get('_G.notes'), 0)
end

T[':bd on the prompt, then reopen: a fresh prompt buffer with its keys'] = function()
  start(turn('New prompt buf', 'Fine'))
  open_new()
  type_prompt('lost draft')
  child.type_keys('<Esc>')
  child.cmd('bdelete')
  vim.wait(50)
  child.lua('vim.api.nvim_set_current_win(...)', { wins().transcript })
  child.type_keys('i')
  eq(prompt_lines(), { '' })
  eq(child.lua_get('{ vim.bo.buftype, vim.bo.filetype, vim.fn.maparg("<C-CR>", "i") ~= "" }'), { 'acwrite', 'markdown', true })
  child.type_keys('New prompt buf', '<C-CR>')
  wait_for(function() return has_line(transcript(), 'Fine') ~= nil end, 'answer')
  eq(prompt_lines(), { '' })
end

T[':bd on the transcript while a turn streams does not raise; the session goes on'] = function()
  start(turn('Streaming', 'Long answer', { { sleep_ms = 400 } }))
  open_new()
  type_prompt('Streaming')
  child.type_keys('<C-CR>', '<Esc>')
  wait_for(function() return has_line(transcript(), 'Lon') ~= nil end, 'streaming')
  child.lua('vim.api.nvim_set_current_win(...)', { wins().transcript })
  child.cmd('bdelete')
  wait_for(function() return child.lua_get('require("agent-ide.session").all()[1].state') ~= 'busy' end, 'turn end')
  eq(child.lua_get('require("agent-ide.session").all()[1].owned'), true)
  eq(child.lua_get('vim.v.errmsg'), '')
  eq(#child.lua_get('_G.notes'), 0)
  -- reopening shows the whole turn
  expand('repo')
  drawer_cursor_to('Streaming')
  child.type_keys('<CR>')
  wait_for(function() return has_line(transcript(), 'Long answer') ~= nil end, 'reopened')
  eq(equals_render(), true)
end

T['<C-c> cancels a send held for a load; the text stays'] = function()
  start(turn('Held', 'never'))
  child.lua([[
    local index = require('agent-ide.index')
    local history = index.history
    index.history = function(path, cb) _G.release = function() history(path, cb) end end
  ]])
  expand('repo')
  drawer_cursor_to('Alpha basics')
  child.type_keys('<CR>')
  wait_for(function() return child.lua_get('_G.release ~= nil') end, 'load started')
  type_prompt('Held')
  child.type_keys('<C-CR>', '<Esc>', '<C-c>')
  child.lua('_G.release()')
  wait_for(function() return has_line(transcript(), '## You') ~= nil end, 'history')
  vim.wait(200)
  eq(fake.log(log), {})
  eq(prompt_lines(), { 'Held' })
end

T['winbar of a session running elsewhere follows live polls'] = function()
  local live_file = tmp .. '/live.json'
  local function live(status)
    vim.fn.writefile({ '[{"sessionId":"' .. FIXTURE_ID .. '","status":"' .. status .. '","pid":1,"cwd":"/x"}]' }, live_file)
  end
  live('busy')
  start()
  child.lua('require("agent-ide").setup(vim.tbl_deep_extend("force", require("agent-ide.config").get(), { live = { cmd = { "cat", ... } } }))', { live_file })
  expand('repo')
  drawer_cursor_to('B Alpha basics')
  child.type_keys('<CR>')
  wait_for(function() return has_line(transcript(), '## You') ~= nil end, 'history loaded')
  eq(winbar(), 'repo · Alpha basics · model ? · mode:? · busy')
  live('waiting')
  wait_for(function() return winbar() == 'repo · Alpha basics · model ? · mode:? · waiting' end, 'winbar after poll')
end

T['+ New session on a project without a folder key is refused'] = function()
  vim.fn.mkdir(projects .. '/-nocwd', 'p')
  vim.fn.writefile({ vim.json.encode({ type = 'user', uuid = 'q', message = { role = 'user', content = 'No cwd here' } }) },
    projects .. '/-nocwd/44444444-4444-4444-8444-444444444444.jsonl')
  start()
  expand('-nocwd')
  drawer_cursor_to('    + New session')
  child.type_keys('<CR>')
  local notes = child.lua_get('_G.notes')
  eq(notes[#notes], 'Agent-IDE: project folder not found: -nocwd')
  eq(child.lua_get('#require("agent-ide.session").all()'), 0)
end

T['at most one prompt window per tab, also after the transcript is shown elsewhere'] = function()
  start()
  open_new()
  local agents = child.lua_get('vim.api.nvim_get_current_tabpage()')
  local function prompt_wins()
    return child.lua_get([[#vim.tbl_filter(function(w)
      return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):find('agent-ide://prompt/', 1, true) ~= nil
    end, vim.api.nvim_tabpage_list_wins(0))]])
  end
  -- a split of the transcript in the same tab
  child.lua('vim.api.nvim_set_current_win(...)', { wins().transcript })
  child.cmd('split')
  child.type_keys('i', '<Esc>')
  eq(prompt_wins(), 1)
  -- the transcript in another tab gets its own prompt there
  child.cmd('tab sbuffer ' .. child.lua_get('vim.api.nvim_win_get_buf(require("agent-ide.ui.chat")._windows().transcript)'))
  child.type_keys('i', '<Esc>')
  eq(prompt_wins(), 1)
  child.lua('vim.api.nvim_set_current_tabpage(...)', { agents })
  -- a stray second prompt window in the Agents tab is closed on the next focus
  child.cmd('split')
  eq(prompt_wins(), 2)
  child.lua('vim.api.nvim_set_current_win(...)', { wins().transcript })
  child.type_keys('i', '<Esc>')
  eq(prompt_wins(), 1)
  eq(child.lua_get('vim.api.nvim_buf_get_name(0)'):find('agent-ide://prompt/', 1, true) ~= nil, true)
end

T['a second send while busy shows queued:1; <C-c> interrupts and returns the queue'] = function()
  start({ { expect = 'first' }, init(), status(), { expect = 'interrupt' }, result('stopped', true) })
  open_new()
  type_prompt('first')
  child.type_keys('<C-CR>')
  wait_for(function() return winbar():find('haiku-5-5 · mode:manual · busy', 1, true) ~= nil end, 'busy with init')
  child.type_keys('second', '<C-CR>')
  wait_for(function() return winbar():find('queued:1', 1, true) ~= nil end, 'queued in winbar')
  eq(winbar(), 'repo · new session · haiku-5-5 · mode:manual · busy · queued:1')
  child.type_keys('<Esc>', 'idraft<Esc>')
  child.type_keys('<C-c>')
  wait_for(function()
    for _, o in ipairs(fake_ins()) do
      if o.type == 'control_request' and o.request.subtype == 'interrupt' then return true end
    end
  end, 'interrupt request')
  eq(prompt_lines(), { 'second', '', 'draft' })
  local notes = child.lua_get('_G.notes')
  eq(notes[#notes], 'Agent-IDE: interrupted; 1 queued prompt(s) returned to the prompt buffer')
  wait_for(function() return current().state == 'idle' end, 'idle after interrupt')
  eq(winbar():find('queued', 1, true), nil)
end

T['<C-c> in the transcript interrupts too'] = function()
  start({ { expect = 'first' }, init(), status(), { expect = 'interrupt' }, result('stopped', true) })
  open_new()
  type_prompt('first')
  child.type_keys('<C-CR>', '<Esc>')
  wait_for(function() return current().state == 'busy' end, 'busy')
  child.lua('vim.api.nvim_set_current_win(...)', { wins().transcript })
  child.type_keys('<C-c>')
  wait_for(function() return current().state == 'idle' end, 'idle after interrupt')
  local n = 0
  for _, o in ipairs(fake_ins()) do
    if o.type == 'control_request' and o.request.subtype == 'interrupt' then n = n + 1 end
  end
  eq(n, 1)
end

T['opening the fixture shows its history; a send resumes it'] = function()
  start(turn('Next question', 'Next answer'))
  open_fixture()
  local lines = transcript()
  local bash = has_line(lines, '▸ Bash:')
  eq(bash ~= nil, true)
  eq(child.lua_get('vim.api.nvim_win_call(require("agent-ide.ui.chat")._windows().transcript, function() return vim.fn.foldclosed(' .. bash .. ') end)'), bash)
  eq(winbar(), 'repo · Alpha basics · model ? · mode:? · parked')
  type_prompt('Next question')
  child.type_keys('<C-CR>')
  wait_for(function() return has_line(transcript(), 'Next answer') ~= nil end, 'answer')
  local argv = fake.log(log)[1].argv
  eq(vim.list_slice(argv, #argv - 1), { '--resume', FIXTURE_ID })
  eq(fake.log(log)[1].cwd, repo)
  -- history first, then the new turn
  lines = transcript()
  eq(has_line(lines, 'Please add a greeting to main.') < has_line(lines, 'Next question'), true)
end

T['a send while the history loads waits for the load'] = function()
  start(turn('Early bird', 'Worm'))
  child.lua([[
    local index = require('agent-ide.index')
    local history = index.history
    index.history = function(path, cb)
      _G.release = function() history(path, cb) end
    end
  ]])
  expand('repo')
  drawer_cursor_to('Alpha basics')
  child.type_keys('<CR>')
  eq(transcript(), { 'Loading…' })
  wait_for(function() return child.lua_get('_G.release ~= nil') end, 'load started')
  type_prompt('Early bird')
  child.type_keys('<C-CR>')
  vim.wait(200)
  eq(fake.log(log), {})
  eq(transcript(), { 'Loading…' })
  child.lua('_G.release()')
  wait_for(function() return has_line(transcript(), 'Worm') ~= nil end, 'answer')
  local lines = transcript()
  eq({ lines[1], lines[2] }, { '', '## You' })
  eq(has_line(lines, 'Please add a greeting to main.') < has_line(lines, 'Early bird'), true)
  eq(prompt_lines(), { '' })
end

T['a session running elsewhere refuses to send and keeps the text'] = function()
  start({}, '[{"sessionId":"' .. FIXTURE_ID .. '","status":"busy","pid":1,"cwd":"/x"}]')
  expand('repo')
  drawer_cursor_to('B Alpha basics')
  child.type_keys('<CR>')
  wait_for(function() return has_line(transcript(), '## You') ~= nil end, 'history loaded')
  eq(winbar(), 'repo · Alpha basics · model ? · mode:? · busy')
  type_prompt('Hijack')
  child.type_keys('<C-CR>')
  local notes = child.lua_get('_G.notes')
  eq(notes[#notes], 'Agent-IDE: session is running in another Claude; use gp in the drawer to jump to it')
  eq(prompt_lines(), { 'Hijack' })
  vim.wait(100)
  eq(fake.log(log), {})
end

T['? opens the chat help'] = function()
  start()
  open_new()
  child.type_keys('?')
  wait_for(function() return child.lua_get('vim.api.nvim_win_get_config(0).relative') ~= '' end, 'help float')
  local text = table.concat(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, -1, false)'), '\n')
  for _, key in ipairs({ '<C-CR>', '<leader><CR>', '<C-c>', '<leader>ap', '?', 'za', ':w', 'i / a / o' }) do
    eq(text:find(key, 1, true) ~= nil, true)
  end
end

T['chat keys come from config; false disables one'] = function()
  start()
  child.lua('require("agent-ide").setup(vim.tbl_deep_extend("force", require("agent-ide.config").get(), { keys = { chat = { send_alt = false, interrupt = "<C-x>" } } }))')
  open_new()
  eq(child.lua_get('vim.fn.maparg("<leader><CR>", "n")'), '')
  eq(child.lua_get('vim.fn.maparg("<C-x>", "n") ~= ""'), true)
  eq(child.lua_get('vim.fn.maparg("<C-c>", "n")'), '')
  eq(child.lua_get('vim.fn.maparg("<C-CR>", "i") ~= ""'), true)
end

T['drawer: busy while Claude works, done when the turn ends in another tab, idle once seen'] = function()
  start(turn('Slow one', 'Finally', { { sleep_ms = 1500 } }))
  open_new()
  type_prompt('Slow one')
  child.type_keys('<C-CR>', '<Esc>')
  -- the new session is listed (once) in its project while it is busy
  wait_for(function() return has_line(drawer_lines(), 'B Slow one') ~= nil end, 'busy icon')
  eq(drawer_lines()[3]:match('^v P repo .* B %S+$') ~= nil, true) -- line 1: the header, 2: the Prompts node
  local focus = child.lua_get('{ vim.api.nvim_get_current_win(), vim.api.nvim_win_get_cursor(0) }')
  child.cmd('tabprevious')
  eq(child.lua_get('require("agent-ide.session").all()[1].visible'), false)
  wait_for(function() return child.lua_get('require("agent-ide.session").all()[1].state') == 'done' end, 'done')
  eq(has_line(drawer_lines(), 'D Slow one') ~= nil, true)
  eq(drawer_lines()[3]:match('^v P repo .* D review %(1%) %S+$') ~= nil, true)
  child.cmd('tabnext')
  eq(child.lua_get('{ vim.api.nvim_get_current_win(), vim.api.nvim_win_get_cursor(0) }'), focus)
  eq(child.lua_get('require("agent-ide.session").all()[1].visible'), true)
  eq(child.lua_get('require("agent-ide.session").all()[1].state'), 'idle')
  wait_for(function() return has_line(drawer_lines(), 'I Slow one') ~= nil end, 'idle icon')
end

T['visible follows the transcript window and the focused tab'] = function()
  start()
  open_new()
  local function vis() return child.lua_get('require("agent-ide.session").all()[1].visible') end
  eq(vis(), true)
  child.cmd('tabnew')
  eq(vis(), false)
  child.cmd('tabclose')
  eq(vis(), true)
  -- the transcript window shows another buffer
  child.lua('vim.api.nvim_win_set_buf(require("agent-ide.ui.chat")._windows().transcript, vim.api.nvim_create_buf(false, true))')
  eq(vis(), false)
  open_new() -- a second new session reuses the same two windows
  eq(child.lua_get('#require("agent-ide.session").all()'), 2)
  eq(child.lua_get('{ require("agent-ide.session").all()[1].visible, require("agent-ide.session").all()[2].visible }'), { false, true })
  eq(child.lua_get('#vim.api.nvim_tabpage_list_wins(0)'), 3)
  -- closing the transcript window
  child.lua('vim.api.nvim_win_close(require("agent-ide.ui.chat")._windows().transcript, true)')
  eq(child.lua_get('require("agent-ide.session").all()[2].visible'), false)
end

T['a new session listed by the next rescan shows once and opens the same Session'] = function()
  start(turn('Fresh start', 'Welcome'))
  open_new()
  type_prompt('Fresh start')
  child.type_keys('<C-CR>', '<Esc>')
  wait_for(function() return current().state == 'idle' and has_line(transcript(), 'Welcome') ~= nil end, 'turn end')
  local id = current().id
  wait_for(function() return has_line(drawer_lines(), 'Fresh start') ~= nil end, 'listed before the rescan')
  -- Claude wrote the transcript: the rescan finds it
  local rec = vim.json.encode({ type = 'user', uuid = 'n1', cwd = repo, message = { role = 'user', content = 'Fresh start' } })
  vim.fn.writefile({ rec }, projects .. '/-repo/' .. id .. '.jsonl')
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.drawer").state().win)')
  child.type_keys('R')
  wait_for(function() return has_line(drawer_lines(), 'Sessions (2)') ~= nil end, 'rescan')
  local count = 0
  for _, l in ipairs(drawer_lines()) do
    if l:find('Fresh start', 1, true) then count = count + 1 end
  end
  eq(count, 1)
  drawer_cursor_to('Fresh start')
  child.type_keys('<CR>')
  eq(current().id, id)
  eq(child.lua_get('#require("agent-ide.session").all()'), 1)
  eq(has_line(transcript(), 'Welcome') ~= nil, true)
end

T['new session in a missing project folder is refused'] = function()
  start()
  vim.fn.delete(repo, 'rf')
  expand('repo')
  drawer_cursor_to('    + New session')
  child.type_keys('<CR>')
  local notes = child.lua_get('_G.notes')
  eq(notes[#notes], 'Agent-IDE: project folder not found: ' .. repo)
  eq(child.lua_get('#require("agent-ide.session").all()'), 0)
end

T['events of a session never move focus or the cursor'] = function()
  start(turn('Background', 'Quiet answer', { { sleep_ms = 500 } }))
  open_new()
  type_prompt('Background')
  child.type_keys('<C-CR>', '<Esc>')
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.drawer").state().win)')
  local before = child.lua_get('{ vim.api.nvim_get_current_win(), vim.api.nvim_win_get_cursor(0), vim.api.nvim_get_mode().mode, #vim.api.nvim_list_wins() }')
  wait_for(function() return child.lua_get('require("agent-ide.session").all()[1].state') == 'idle' end, 'turn end')
  eq(child.lua_get('{ vim.api.nvim_get_current_win(), vim.api.nvim_win_get_cursor(0), vim.api.nvim_get_mode().mode, #vim.api.nvim_list_wins() }'), before)
end

T['chat.current and session_of find the session of a chat buffer'] = function()
  start()
  open_new()
  local id = current().id
  eq(child.lua_get('require("agent-ide.ui.chat").session_of(vim.api.nvim_get_current_buf()).id'), id)
  eq(child.lua_get('require("agent-ide.ui.chat").session_of(vim.api.nvim_win_get_buf(require("agent-ide.ui.chat")._windows().transcript)).id'), id)
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.drawer").state().win)')
  eq(current().id, id)
  child.cmd('tabnew')
  eq(current(), vim.NIL)
end

return T

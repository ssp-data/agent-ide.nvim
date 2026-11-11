-- The chat, drawer and status with a session of another agent (the fake ACP agent): controls
-- follow the agent's capabilities, the permission flow is the one Claude sessions use, the
-- drawer labels the session and can start one with any configured agent. Child Neovims.
local acp = dofile(vim.fn.getcwd() .. '/tests/acp.lua')
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()

local ICONS = { open = 'v', closed = '>', project = 'P', waiting = 'W', busy = 'B', idle = 'I', parked = '.',
  done = 'D', failed = 'F', new = '+' }

local tmp, repo, projects, log

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    tmp = vim.uv.fs_realpath(tmp)
    repo = tmp .. '/repo'
    projects = tmp .. '/projects'
    vim.fn.mkdir(repo, 'p')
    vim.fn.mkdir(projects, 'p')
    vim.fn.system({ 'git', 'init', '-q', repo })
  end,
  post_case = function()
    child.stop()
    vim.uv.os_unsetenv('FAKE_ACP_LOG')
    vim.fn.delete(tmp, 'rf')
  end,
  post_once = function() child.stop() end,
} })

-- Child helpers ---------------------------------------------------------------------------

local function start(steps, opts)
  local cmd
  cmd, log = acp.cmd(steps or {})
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[
    local log, opts = ...
    vim.env.TMUX = nil
    vim.uv.os_setenv('FAKE_ACP_LOG', log)
    _G.notes = {}
    vim.notify = function(msg) table.insert(_G.notes, msg) end
    _G.selects = {}
    vim.ui.select = function(items, o, on_choice)
      local labels = {}
      for i, it in ipairs(items) do labels[i] = o.format_item and o.format_item(it) or tostring(it) end
      table.insert(_G.selects, { labels = labels, prompt = o.prompt, mode = vim.api.nvim_get_mode().mode })
      _G.open_select = { items = items, labels = labels, cb = on_choice }
    end
    _G.pick = function(label)
      local p = assert(_G.open_select, 'no select open')
      _G.open_select = nil
      for i, l in ipairs(p.labels) do
        if l == label then return p.cb(p.items[i], i) end
      end
      error('no item ' .. label)
    end
    require('agent-ide').setup(opts)
  ]], { log, vim.tbl_deep_extend('force', {
    projects_dir = projects,
    helper = { enabled = false },
    live = { interval_ms = 50, cmd = { 'echo', '[]' } },
    icons_style = 'plain', icons = ICONS,
    sound = { waiting = false },
    agents = { fake = { kind = 'acp', cmd = cmd, label = 'Fake' }, gemini = false, opencode = false },
  }, opts or {}) })
end

local function wait_for(cond, what, ms)
  local done = vim.wait(ms or 5000, cond, 20)
  if not done then error('timed out waiting for ' .. what, 2) end
end

local function has_line(lines, text)
  for i, l in ipairs(lines) do
    if l:find(text, 1, true) then return i end
  end
end

local function current()
  return child.lua_get('(function() local s = require("agent-ide.ui.chat").current(); return s and { id = s.id, state = s.state } end)()')
end

---Open a chat of a new `fake` session in the repo (the Agents tab opens first).
local function open_fake()
  child.lua('require("agent-ide").toggle()')
  child.lua([[
    local repo = ...
    local s = require('agent-ide.session').open({ cwd = repo, agent = 'fake' })
    require('agent-ide.ui.chat').open(s, { key = repo, name = 'repo', root = repo, sessions = {} })
  ]], { repo })
  wait_for(function() return current() ~= vim.NIL end, 'chat open')
  return current().id
end

local function transcript()
  return child.lua_get('vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(require("agent-ide.ui.chat")._windows().transcript), 0, -1, false)')
end

local function winbar()
  local bar = child.lua_get('vim.wo[require("agent-ide.ui.chat")._windows().transcript].winbar')
  return (bar:gsub('%%#[^#]*#', ''):gsub('%%%*', ''):gsub('%%=', '  '):gsub('%%%%', '%%'))
end
local function selects() return child.lua_get('_G.selects') end
local function pick(label) child.lua('_G.pick(...)', { label }) end
local function notes() return child.lua_get('_G.notes') end
local function send_normal(text) child.type_keys('i', text, '<Esc>', '\\<CR>') end
local function state() return child.lua_get('require("agent-ide.ui.chat").current().state') end

-- A turn answered with `answer`.
local function turn(answer)
  return acp.flat({ expect = '"session/prompt"' }, acp.chunk(answer), acp.end_turn())
end

-- Tests -------------------------------------------------------------------------------------

T['an ACP chat: the answer renders, the winbar names the agent, no quota in the footer'] = function()
  start(acp.flat(acp.handshake({ modes = false }), acp.commands({ 'init', 'review' }), turn('Hello from the fake')))
  open_fake()
  send_normal('hi there')
  wait_for(function() return has_line(transcript(), 'Hello from the fake') ~= nil end, 'answer')
  wait_for(function() return state() == 'idle' end, 'idle')
  local bar = winbar()
  eq(vim.startswith(bar, 'Fake · '), true)
  eq(bar:find('repo', 1, true) ~= nil, true)
  eq(bar:find('mode:', 1, true), nil) -- no mode, no model: nothing on the right
  eq(bar:find('default', 1, true), nil)
  -- the footer counts the session; Claude's quota windows are not shown while it has the focus
  child.lua('require("agent-ide.session")._set_quota({ five_hour = { utilization = 0.5 } }); require("agent-ide.status").refresh()')
  local text = child.lua_get('require("agent-ide.status").statusline()')
  eq(text:find('5h', 1, true), nil)
  eq(text:sub(1, 9), 'agents ok')
  -- the status file row names the agent
  local rows = child.lua_get('require("agent-ide.status").snapshot().sessions')
  eq(#rows, 1)
  eq({ rows[1].agent, rows[1].state }, { 'fake', 'idle' })
end

T['controls follow the capabilities: a mode cycles through the agent\'s modes, models and the hand-over say no'] = function()
  start(acp.flat(acp.handshake({ modes = false }), turn('ok'),
    { expect = '"session/set_mode"' }, { respond = vim.empty_dict() }))
  open_fake()
  -- before the start nothing is known: the keys say so instead of doing nothing
  child.type_keys('<Esc>')
  child.type_keys('<S-Tab>')
  eq(notes()[#notes()], 'Agent-IDE: Fake does not offer permission modes through ACP')
  child.type_keys('\\aM')
  eq(notes()[#notes()], 'Agent-IDE: Fake does not offer a choice of models through ACP')
  child.type_keys('\\aT')
  eq(notes()[#notes()], 'Agent-IDE: Fake does not offer a native screen in a tmux pane through ACP')
  eq(#selects(), 0)
  -- the help names them
  local rows = child.lua_get('require("agent-ide.ui.chat_keys").unsupported_rows(require("agent-ide.ui.chat").current())')
  eq(vim.tbl_map(function(r) return r.desc end, rows), {
    'Fake does not offer permission modes through ACP', 'Fake does not offer a choice of models through ACP',
    'Fake does not offer a native screen in a tmux pane through ACP',
    'Fake announced no commands; the menu has the plugin\'s own' })
  -- the / menu: the plugin's /copy, no /model, no Claude commands or skills
  local items = child.lua_get('vim.tbl_map(function(i) return i.word end, require("agent-ide.ui.prompt").matches(require("agent-ide.ui.chat").current(), "/"))')
  eq(items, { '/copy' })
end

T['an agent with modes and models: <S-Tab> asks for the next mode; the picker lists its models'] = function()
  start(acp.flat(acp.handshake(), acp.commands({ 'memory' }), turn('ok'),
    { expect = '"session/set_mode"' }, { respond = vim.empty_dict() }))
  open_fake()
  send_normal('hi')
  wait_for(function() return state() == 'idle' end, 'idle')
  eq(winbar():find('[default]', 1, true) ~= nil, true)
  eq(winbar():find('m small', 1, true) ~= nil, true) -- the agent's name for it, lowercased as Claude's
  child.type_keys('<S-Tab>')
  wait_for(function() return winbar():find('[plan]', 1, true) ~= nil end, 'plan mode')
  eq(acp.sent(log, 'session/set_mode')[1].params.modeId, 'plan')
  child.type_keys('\\aM')
  eq(#selects(), 1)
  eq(selects()[1].labels, { '● M small', '  M big — Bigger' })
  local items = child.lua_get('vim.tbl_map(function(i) return i.word end, require("agent-ide.ui.prompt").matches(require("agent-ide.ui.chat").current(), "/"))')
  eq(items, { '/copy', '/model', '/memory' }) -- the plugin's own first, then the agent's
end

T['an ask while typing never pops up; the answer key opens it with the agent\'s own choices'] = function()
  start(acp.flat(acp.handshake(),
    { expect = '"session/prompt"' }, acp.tool_call('t1', 'echo hi', 'execute'), acp.permission('t1', 'echo hi'),
    acp.tool_update('t1', 'completed', { content = { acp.text_content('hi') } }), acp.chunk('done'), acp.end_turn()))
  open_fake()
  child.type_keys('i', 'run it', '<Esc>')
  child.type_keys('\\<CR>')
  child.type_keys('i', 'still typing') -- insert mode in the prompt: no popup, a one-line hint
  wait_for(function() return state() == 'waiting' end, 'ask')
  vim.wait(300)
  eq(#selects(), 0)
  wait_for(function() return child.lua_get('vim.fn.execute("messages")'):find('Fake asks: execute: echo hi', 1, true) ~= nil end, 'hint')
  eq(has_line(transcript(), 'Permission needed: execute: echo hi') ~= nil, true)
  child.type_keys('<Esc>')
  wait_for(function() return #selects() == 1 end, 'select')
  eq(selects()[1].labels, { 'Allow', 'Deny', 'Allow for this session' })
  eq(selects()[1].prompt:sub(1, 29), 'Fake wants to use execute: ec')
  pick('Allow for this session')
  wait_for(function() return state() == 'idle' end, 'turn done')
  local answers = vim.tbl_filter(function(m) return m.result and m.result.outcome end, acp.ins(log))
  eq(answers[1].result.outcome, { outcome = 'selected', optionId = 'proceed_always' })
  eq(has_line(transcript(), 'done') ~= nil, true)
end

-- Drawer: choosing an agent, labelling sessions ---------------------------------------------

local function drawer_lines()
  return child.lua_get([[(function()
    local s = require('agent-ide.ui.drawer').state()
    return s.buf and vim.api.nvim_buf_get_lines(s.buf, 0, -1, false) or {}
  end)()]])
end

local function drawer_cursor_to(text)
  local last
  local found = vim.wait(5000, function()
    local ok, lines = pcall(drawer_lines) -- the child may be busy for a moment
    last = { ok, lines }
    return ok and has_line(lines, text) ~= nil
  end, 20)
  if not found then error('timed out waiting for drawer line ' .. text .. ': ' .. vim.inspect(last), 2) end
  local row = has_line(drawer_lines(), text)
  child.lua('local s = require("agent-ide.ui.drawer").state(); vim.api.nvim_set_current_win(s.win); vim.api.nvim_win_set_cursor(s.win, { ..., 0 })', { row })
end

-- A Claude transcript in the repo, so the project shows in the drawer.
local function claude_session(id, title)
  local dir = projects .. '/-repo'
  vim.fn.mkdir(dir, 'p')
  vim.fn.writefile({
    vim.json.encode({ type = 'user', uuid = 'u1', sessionId = id, cwd = repo, timestamp = '2026-11-01T10:00:00Z',
      message = { role = 'user', content = title } }),
  }, dir .. '/' .. id .. '.jsonl')
end

T['A on a project row picks an agent: unavailable ones cannot be picked; the new chat runs that agent; rows are labelled'] = function()
  claude_session('22222222-2222-4222-8222-222222222222', 'A Claude session')
  local fake_claude = dofile(vim.fn.getcwd() .. '/tests/fake.lua')
  local ccmd, clog = fake_claude.cmd({ { expect = 'To Claude' },
    { emit = { type = 'system', subtype = 'init', session_id = 'x', model = 'claude-haiku-5-5-20261001', permissionMode = 'default', slash_commands = {} } },
    { emit = { type = 'assistant', message = { id = 'm', role = 'assistant', content = { { type = 'text', text = 'Claude here' } } } } },
    { emit = { type = 'result', subtype = 'success', is_error = false, result = 'x' } } })
  start(acp.flat(acp.handshake({ modes = false }), turn('Fake here')),
    { claude = { cmd = ccmd }, keeper = { enabled = false },
      agents = { gone = { kind = 'acp', cmd = { 'no-such-agent-binary-xyz', 'acp' } } } })
  child.lua('vim.uv.os_setenv("FAKE_CLAUDE_LOG", ...)', { clog })
  child.lua('require("agent-ide").toggle()')
  drawer_cursor_to('> repo')
  child.type_keys('<CR>')
  drawer_cursor_to('A Claude session')
  -- A anywhere under the project: the picker, the default marked, the missing one unavailable
  child.type_keys('A')
  wait_for(function() return #selects() == 1 end, 'agent picker')
  eq(selects()[1].prompt, 'New session with')
  eq(selects()[1].labels, { 'claude (default)', 'fake', 'gone: unavailable (no-such-agent-binary-xyz not found)' })
  pick('gone: unavailable (no-such-agent-binary-xyz not found)')
  eq(notes()[#notes()], 'Agent-IDE: gone is not available here')
  eq(current(), vim.NIL)
  child.type_keys('A')
  wait_for(function() return #selects() == 2 end, 'agent picker again')
  pick('fake')
  wait_for(function() return current() ~= vim.NIL end, 'fake chat')
  local fid = current().id
  eq(child.lua_get('require("agent-ide.ui.chat").current().agent'), 'fake')
  send_normal('To the fake')
  wait_for(function() return has_line(transcript(), 'Fake here') ~= nil and state() == 'idle' end, 'fake answered')
  -- the row of the fake session names its agent; Claude's row reads as before
  wait_for(function() return has_line(drawer_lines(), 'fake · To the fake') ~= nil end, 'labelled row')
  local l = drawer_lines()
  eq(has_line(l, 'claude · ') == nil, true)
  eq(l[has_line(l, 'A Claude session')]:match('^%s+%S+ A Claude session') ~= nil, true)
  -- the Claude session beside it: its own process, its own chat (Review Focus 4)
  drawer_cursor_to('A Claude session')
  child.type_keys('<CR>')
  wait_for(function() return current().id == '22222222-2222-4222-8222-222222222222' end, 'claude chat')
  eq(child.lua_get('require("agent-ide.ui.chat").current().agent'), 'claude')
  send_normal('To Claude')
  wait_for(function() return has_line(transcript(), 'Claude here') ~= nil end, 'claude answered')
  -- each prompt went to its own process only
  local prompts = acp.sent(log, 'session/prompt')
  eq(#prompts, 1)
  eq(prompts[1].params.prompt[1].text, 'To the fake')
  local cl = vim.tbl_filter(function(x) return x['in'] and x['in']:find('To ', 1, true) end, fake_claude.log(clog))
  eq(#cl, 1)
  eq(cl[1]['in']:find('To Claude', 1, true) ~= nil, true)
  -- the status file lists both; the other agent's row names it (a Claude row has no `agent`, as before)
  local rows = child.lua_get('require("agent-ide.status").snapshot().sessions')
  local by = {}
  for _, r in ipairs(rows) do by[r.id] = r.agent or 'claude' end
  eq({ by[fid], by['22222222-2222-4222-8222-222222222222'] }, { 'fake', 'claude' })
end

T[':AgentsNew <agent> starts a session in the current project; without a name it picks; an unknown agent says so'] = function()
  start(acp.flat(acp.handshake({ modes = false }), turn('ok')))
  child.lua('vim.cmd.cd(...)', { repo })
  child.cmd('AgentsNew fake')
  wait_for(function() return current() ~= vim.NIL end, 'chat')
  eq(child.lua_get('{ require("agent-ide.ui.chat").current().agent, require("agent-ide.ui.chat").current().cwd }'), { 'fake', repo })
  eq(child.fn.getcompletion('AgentsNew ', 'cmdline'), { 'claude', 'fake' })
  child.cmd('AgentsNew nope')
  eq(notes()[#notes()], 'Agent-IDE: unknown agent "nope" (not in config.agents)')
  child.cmd('AgentsNew')
  wait_for(function() return #selects() == 1 end, 'picker')
  eq(selects()[1].labels[2], 'fake')
end

return T

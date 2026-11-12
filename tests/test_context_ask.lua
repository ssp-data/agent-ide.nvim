-- The size of a session's conversation in the chat: the winbar's `~123k`, the question before a
-- send that resumes a session from disk (Send / Compact first / Cancel), the /compact key and
-- the offer to compact before parking. Each case drives a child Neovim with the fake Claude.
local fake = dofile(vim.fn.getcwd() .. '/tests/fake.lua')
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()

local FIXTURE_ID = '11111111-1111-4111-8111-111111111111'
local FIXTURE = vim.fn.getcwd() .. '/tests/fixtures/projects/-home-u-git-alpha/' .. FIXTURE_ID .. '.jsonl'
local ICONS = { open = 'v', closed = '>', project = 'P', waiting = 'W', busy = 'B', idle = 'I', parked = '.',
  done = 'D', failed = 'F', new = '+' }
local BIG = { input_tokens = 10, cache_read_input_tokens = 120000, cache_creation_input_tokens = 3000, output_tokens = 5 }

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
    local dir = projects .. '/-repo'
    vim.fn.mkdir(dir, 'p')
    local lines = {}
    for i, l in ipairs(vim.fn.readfile(FIXTURE)) do lines[i] = l:gsub('/home/u/git/alpha', repo) end
    -- the fixture's messages carry no usage: one more answer says how large the conversation is
    lines[#lines + 1] = vim.json.encode({ type = 'assistant', uuid = 'r99', parentUuid = 'r20', cwd = repo,
      gitBranch = 'feat/x', isSidechain = false, message = { role = 'assistant', model = 'claude-haiku-5-5',
        content = { { type = 'text', text = 'Noted.' } }, usage = BIG } })
    vim.fn.writefile(lines, dir .. '/' .. FIXTURE_ID .. '.jsonl')
  end,
  post_case = function()
    child.stop()
    vim.uv.os_unsetenv('FAKE_CLAUDE_LOG')
    vim.fn.delete(tmp, 'rf')
  end,
  post_once = function() child.stop() end,
} })

local function init()
  return { emit = { type = 'system', subtype = 'init', session_id = 'x', model = 'claude-haiku-5-5-20261001',
    permissionMode = 'default', slash_commands = { 'compact', 'context' }, claude_code_version = '2.1.306' } }
end
local function say(t, usage)
  return { emit = { type = 'assistant', message = { id = 'm', type = 'message', role = 'assistant',
    model = 'claude-haiku-5-5', content = { { type = 'text', text = t } }, usage = usage } } }
end
local function compacted()
  return { emit = { type = 'system', subtype = 'compact_boundary', session_id = 'x', uuid = 'c1',
    compact_metadata = { trigger = 'manual', pre_tokens = 123010 } } }
end
local function result(t) return { emit = { type = 'result', subtype = 'success', is_error = false, result = t } } end
local function flat(...)
  local out = {}
  for _, part in ipairs({ ... }) do vim.list_extend(out, part) end
  return out
end

local function start(steps, context)
  local cmd
  cmd, log = fake.cmd(steps or {})
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[
    local log, setup = ...
    vim.env.TMUX = nil
    vim.uv.os_setenv('FAKE_CLAUDE_LOG', log)
    _G.notes, _G.confirms, _G.answer = {}, {}, 1
    vim.notify = function(msg) table.insert(_G.notes, msg) end
    vim.fn.confirm = function(msg, choices, default)
      table.insert(_G.confirms, { msg = msg, choices = choices, default = default })
      return _G.answer
    end
    require('agent-ide').setup(setup)
  ]], { log, {
    projects_dir = projects,
    helper = { enabled = false },
    live = { interval_ms = 50, cmd = { 'echo', '[]' } },
    icons_style = 'plain', icons = ICONS,
    claude = { cmd = cmd },
    context = context or { threshold = 100000 },
  } })
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

local function drawer_cursor_to(text)
  wait_for(function() return has_line(drawer_lines(), text) ~= nil end, 'drawer line ' .. text)
  local row = has_line(drawer_lines(), text)
  child.lua('local s = require("agent-ide.ui.drawer").state(); vim.api.nvim_set_current_win(s.win); vim.api.nvim_win_set_cursor(s.win, { ..., 0 })', { row })
end

local function transcript()
  return child.lua_get('vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(require("agent-ide.ui.chat")._windows().transcript), 0, -1, false)')
end
local function winbar()
  local bar = child.lua_get('vim.wo[require("agent-ide.ui.chat")._windows().transcript].winbar')
  return (bar:gsub('%%#[^#]*#', ''):gsub('%%%*', ''):gsub('%%=', '  '):gsub('%%%%', '%%'))
end
local function sess()
  return child.lua_get([[(function(id)
    local s = require('agent-ide.session').get(id)
    return { state = s.state, owned = s.owned, queue = #s.queue, tokens = s.context_tokens }
  end)(...)]], { FIXTURE_ID })
end
local function confirms() return child.lua_get('_G.confirms') end
local function notes() return child.lua_get('_G.notes') end
local function prompt_lines()
  return child.lua_get('vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(require("agent-ide.ui.chat")._windows().prompt), 0, -1, false)')
end
-- the prompts the fake received, in order
local function sent()
  local out = {}
  for _, l in ipairs(fake.ins(log)) do
    if type(l) == 'table' and l.type == 'user' and type(l.message) == 'table' then out[#out + 1] = l.message.content end
  end
  return out
end
local function argvs()
  local out = {}
  for _, l in ipairs(fake.log(log)) do
    if l.argv then out[#out + 1] = l.argv end
  end
  return out
end

local function open_fixture()
  child.lua('require("agent-ide").toggle()')
  wait_for(function() return has_line(drawer_lines(), ' repo  ') ~= nil end, 'project row')
  if has_line(drawer_lines(), '> repo  ') then
    drawer_cursor_to('> repo  ')
    child.type_keys('<CR>')
  end
  drawer_cursor_to('Alpha basics')
  child.type_keys('<CR>')
  wait_for(function() return has_line(transcript(), '## You') ~= nil end, 'history loaded')
end

local function send(text)
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.chat")._windows().prompt)')
  child.type_keys('i', text, '<Esc>', '\\<CR>')
end

-- Tests -------------------------------------------------------------------------------------

T['a parked session shows its size in the winbar, read from the transcript'] = function()
  start({})
  open_fixture()
  wait_for(function() return sess().tokens == 123010 end, 'context read')
  wait_for(function() return winbar():find('~123k', 1, true) ~= nil end, 'winbar size')
  eq(vim.startswith(winbar(), '. parked'), true)
end

T['resume above the threshold asks; Send sends it (resumed), the size follows the stream'] = function()
  start(flat({ { expect = 'Hi' }, init(), say('Hello.', { input_tokens = 20, cache_read_input_tokens = 123000 }), result('Hello.') }))
  open_fixture()
  send('Hi')
  wait_for(function() return has_line(transcript(), 'Hello.') ~= nil and sess().state == 'idle' end, 'turn end')
  local c = confirms()
  eq(#c, 1)
  eq(c[1].msg:find('~123k tokens', 1, true) ~= nil, true)
  eq(c[1].choices, '&Send\n&Compact first\nCa&ncel')
  eq(c[1].default, 1)
  eq(sent(), { 'Hi' })
  eq(vim.tbl_contains(argvs()[1], '--resume'), true)
  eq(sess().tokens, 123020)
  -- a second send in the same process: no question
  eq(#confirms(), 1)
end

T['Compact first: /compact goes first, the prompt after it; the fold and the new size show'] = function()
  start(flat({ { expect = '/compact' }, init(), compacted(), result(''),
    { expect = 'Hi' }, init(), say('Hello.', { input_tokens = 10, cache_read_input_tokens = 4990 }), result('Hello.') }))
  child.lua('_G.answer = 2')
  open_fixture()
  send('Hi')
  wait_for(function() return has_line(transcript(), 'Hello.') ~= nil and sess().state == 'idle' end, 'turn end')
  eq(sent(), { '/compact', 'Hi' })
  eq(#argvs(), 1) -- one process: the compaction resumed it, the prompt was queued behind
  eq(has_line(transcript(), 'system: compact_boundary') ~= nil, true)
  eq(sess().tokens, 5000)
  wait_for(function() return winbar():find('~5k', 1, true) ~= nil end, 'winbar size after')
  eq(prompt_lines(), { '' })
end

T['Cancel sends nothing; the prompt keeps its text'] = function()
  start({})
  child.lua('_G.answer = 3')
  open_fixture()
  send('Hi')
  wait_for(function() return #confirms() == 1 end, 'question')
  vim.wait(300)
  eq(sent(), {})
  eq(#argvs(), 0)
  eq(prompt_lines(), { 'Hi' })
  eq(sess().state, 'parked')
end

T['below the threshold, or with confirm_resume off, no question'] = function()
  start(flat({ { expect = 'Hi' }, init(), say('Hello.'), result('Hello.') }), { threshold = 200000 })
  open_fixture()
  send('Hi')
  wait_for(function() return has_line(transcript(), 'Hello.') ~= nil end, 'answer')
  eq(#confirms(), 0)
  start(flat({ { expect = 'Hi' }, init(), say('Hello.'), result('Hello.') }), { threshold = 1000, confirm_resume = false })
  open_fixture()
  send('Hi')
  wait_for(function() return has_line(transcript(), 'Hello.') ~= nil end, 'answer')
  eq(#confirms(), 0)
end

T['<leader>aC sends /compact; while a turn runs it is queued'] = function()
  start(flat({ { expect = 'Hi' }, init(), say('Hello.', { input_tokens = 50 }), result('Hello.'),
    { expect = '/compact' }, init(), compacted(), result('') }), { threshold = 200000 })
  open_fixture()
  send('Hi')
  wait_for(function() return sess().state == 'idle' end, 'turn end')
  child.type_keys('\\aC')
  wait_for(function() return has_line(transcript(), 'system: compact_boundary') ~= nil and sess().state == 'idle' end, 'compacted')
  eq(sent(), { 'Hi', '/compact' })
  eq(has_line(notes(), 'compacting the conversation') ~= nil, true)
  eq(#confirms(), 0)
end

T['parking a large idle session offers to compact: Park now, Compact then park, Cancel'] = function()
  local function scenario()
    return flat({ { expect = 'Hi' }, init(), say('Hello.', BIG), result('Hello.'),
      { expect = '/compact' }, init(), compacted(), result('') })
  end
  local only_park = { threshold = 100000, confirm_resume = false } -- the resume question is tested above
  -- Park now
  start(scenario(), only_park)
  open_fixture()
  send('Hi')
  wait_for(function() return sess().state == 'idle' and sess().tokens == 123010 end, 'turn end')
  child.type_keys('\\ax')
  wait_for(function() return sess().state == 'parked' end, 'parked')
  local c = confirms()
  eq(#c, 1)
  eq(c[1].msg:find('~123k tokens', 1, true) ~= nil, true)
  eq(c[1].choices, '&Park now\n&Compact, then park\nCa&ncel')
  eq(sent(), { 'Hi' })
  -- Compact, then park
  start(scenario(), only_park)
  child.lua('_G.answer = 2')
  open_fixture()
  send('Hi')
  wait_for(function() return sess().state == 'idle' and sess().tokens == 123010 end, 'turn end')
  child.type_keys('\\ax')
  wait_for(function() return sess().state == 'parked' end, 'compacted and parked')
  eq(sent(), { 'Hi', '/compact' })
  eq(has_line(transcript(), 'system: compact_boundary') ~= nil, true)
  eq(sess().owned, false)
  eq(#confirms(), 1) -- parking after the compaction asks nothing more
  -- Cancel
  start(scenario(), only_park)
  child.lua('_G.answer = 3')
  open_fixture()
  send('Hi')
  wait_for(function() return sess().state == 'idle' and sess().tokens == 123010 end, 'turn end')
  child.type_keys('\\ax')
  vim.wait(300)
  eq(sess().state, 'idle')
  eq(sess().owned, true)
  eq(sent(), { 'Hi' })
end

T['no offer with compact_before_park off, below the threshold, or while working (that question stays)'] = function()
  start(flat({ { expect = 'Hi' }, init(), say('Hello.', BIG), result('Hello.') }), { threshold = 100000, compact_before_park = false, confirm_resume = false })
  open_fixture()
  send('Hi')
  wait_for(function() return sess().state == 'idle' and sess().tokens == 123010 end, 'turn end')
  child.type_keys('\\ax')
  wait_for(function() return sess().state == 'parked' end, 'parked')
  eq(#confirms(), 0)
  start(flat({ { expect = 'Hi' }, init(), { sleep_ms = 3000 }, say('x', BIG), result('x') }), { threshold = 100000, confirm_resume = false })
  open_fixture()
  send('Hi')
  wait_for(function() return sess().state == 'busy' end, 'busy')
  child.type_keys('\\ax')
  wait_for(function() return sess().state == 'parked' end, 'parked')
  local c = confirms()
  eq(#c, 1)
  eq(c[1].choices, '&Stop\n&Cancel')
end

return T

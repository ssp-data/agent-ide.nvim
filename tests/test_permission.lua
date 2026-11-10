-- Permission asks, user questions, plan approval, mode and model switching: each case drives a
-- fresh child Neovim with the fake Claude. `vim.ui.select` is stubbed: it records each call and
-- keeps the callback, which the test calls through `_G.pick(label)` / `_G.cancel()`.
local fake = dofile(vim.fn.getcwd() .. '/tests/fake.lua')
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()

local FIXTURE_ID = '11111111-1111-4111-8111-111111111111'
local FIXTURE = vim.fn.getcwd() .. '/tests/fixtures/projects/-home-u-git-alpha/' .. FIXTURE_ID .. '.jsonl'
local ICONS = { open = 'v', closed = '>', project = 'P', waiting = 'W', busy = 'B', idle = 'I', parked = '.',
  done = 'D', failed = 'F', new = '+' }
local WRITE = { file_path = '/x/a.txt', content = 'hello\nworld' }
local WRITE_B = { file_path = '/x/b.txt', content = 'bee' }
local SET_MODE = { type = 'setMode', mode = 'acceptEdits', destination = 'session' }
local ADD_RULES = { type = 'addRules', rules = { { toolName = 'Bash', ruleContent = 'npm test:*' } },
  behavior = 'allow', destination = 'localSettings' }
local ADD_DIRS = { type = 'addDirectories', directories = { '/x' }, destination = 'session' }

local tmp, repo, projects, log

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    tmp = vim.uv.fs_realpath(tmp)
    repo = tmp .. '/repo'
    projects = tmp .. '/projects'
    vim.fn.mkdir(repo, 'p')
    vim.fn.system({ 'git', 'init', '-q', repo })
    -- the fixture session, moved into the temporary repo, so the drawer lists the `repo` project
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

local function init(mode)
  return { emit = { type = 'system', subtype = 'init', session_id = 'x', model = 'claude-haiku-5-5-20261001',
    permissionMode = mode or 'default', slash_commands = { 'compact' }, claude_code_version = '2.1.306' } }
end
local function status(mode)
  if mode then return { emit = { type = 'system', subtype = 'status', status = vim.NIL, permissionMode = mode } } end
  return { emit = { type = 'system', subtype = 'status', status = 'requesting' } }
end
local function say(t)
  return { emit = { type = 'assistant', message = { id = 'm', type = 'message', role = 'assistant',
    content = { { type = 'text', text = t } } } } }
end
local function tool_use(id, name, input)
  return { emit = { type = 'assistant', message = { id = 'm', type = 'message', role = 'assistant',
    content = { { type = 'tool_use', id = id, name = name, input = input } } } } }
end
local function tool_result(id, text, is_error)
  return { emit = { type = 'user', message = { role = 'user',
    content = { { type = 'tool_result', tool_use_id = id, content = text, is_error = is_error } } } } }
end
local function ask(rid, name, input, extra)
  local req = { subtype = 'can_use_tool', tool_name = name, display_name = name, input = input, tool_use_id = 't' }
  for k, v in pairs(extra or {}) do req[k] = v end
  return { emit = { type = 'control_request', request_id = rid, request = req } }
end
local function result(t)
  return { emit = { type = 'result', subtype = 'success', is_error = false, result = t } }
end
local function ok(rid, response)
  return { emit = { type = 'control_response', response = { subtype = 'success', request_id = rid, response = response } } }
end
local function flat(...)
  local out = {}
  for _, part in ipairs({ ... }) do
    if part[1] then vim.list_extend(out, part) else out[#out + 1] = part end
  end
  return out
end
-- A Write that needs a permission: tool call, ask `rid`, then (after our answer) its result.
local function write_turn(prompt, rid, extra)
  return flat({ expect = prompt }, init(), status(), tool_use('t1', 'Write', WRITE), ask(rid, 'Write', WRITE, extra),
    { expect = '"' .. rid .. '"' }, tool_result('t1', 'written'), say('Written.'), result('Written.'))
end

-- Child helpers ---------------------------------------------------------------------------

local function start(steps, opts)
  local cmd
  cmd, log = fake.cmd(steps or {})
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[
    local log, opts = ...
    vim.env.TMUX = nil
    vim.uv.os_setenv('FAKE_CLAUDE_LOG', log)
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
    _G.cancel = function()
      local p = assert(_G.open_select, 'no select open')
      _G.open_select = nil
      p.cb(nil, nil)
    end
    require('agent-ide').setup(opts)
  ]], { log, vim.tbl_deep_extend('force', {
    projects_dir = projects,
    helper = { enabled = false },
    live = { interval_ms = 50, cmd = { 'echo', '[]' } },
    icons = ICONS,
    claude = { cmd = cmd },
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

local function current()
  return child.lua_get('(function() local s = require("agent-ide.ui.chat").current(); return s and { id = s.id, state = s.state } end)()')
end

local function open_new()
  if child.lua_get('require("agent-ide.ui.drawer").state().win') == vim.NIL then
    child.lua('require("agent-ide").toggle()')
  end
  wait_for(function() return has_line(drawer_lines(), ' P repo  ') ~= nil end, 'project row')
  if has_line(drawer_lines(), '> P repo  ') then
    drawer_cursor_to('> P repo  ')
    child.type_keys('<CR>')
  end
  drawer_cursor_to('    + New session')
  child.type_keys('<CR>')
  wait_for(function() return current() ~= vim.NIL end, 'chat open')
  return current().id
end

local function transcript()
  return child.lua_get('vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(require("agent-ide.ui.chat")._windows().transcript), 0, -1, false)')
end

local function winbar() return child.lua_get('vim.wo[require("agent-ide.ui.chat")._windows().transcript].winbar') end
local function mode() return child.lua_get('vim.api.nvim_get_mode().mode') end
local function selects() return child.lua_get('_G.selects') end
local function pick(label) child.lua('_G.pick(...)', { label }) end

local function fake_ins()
  local out = {}
  for _, l in ipairs(fake.log(log)) do
    if l['in'] then out[#out + 1] = vim.json.decode(l['in']) end
  end
  return out
end

-- Our answers to Claude's asks, in order.
local function answers()
  local out = {}
  for _, o in ipairs(fake_ins()) do
    if o.type == 'control_response' then out[#out + 1] = o.response end
  end
  return out
end

local function controls()
  local out = {}
  for _, o in ipairs(fake_ins()) do
    if o.type == 'control_request' then out[#out + 1] = o.request end
  end
  return out
end

-- Send a prompt from normal mode (so the session's own ask may open the select at once).
local function send_normal(text)
  child.type_keys('i', text, '<Esc>', '\\<CR>')
end

-- Buffer split into the part above the pending-ask block and the block itself; `above` must
-- equal the render of the session's events.
local function view_parts()
  return child.lua_get([[(function()
    local chat = require('agent-ide.ui.chat')
    local s = chat.current()
    local buf = vim.api.nvim_win_get_buf(chat._windows().transcript)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local tail = require('agent-ide.transcript.ask').lines(s)
    local rendered = require('agent-ide.transcript.render').render(s.events).lines
    local levels = require('agent-ide.ui.history')._levels(buf)
    return { above = vim.list_slice(lines, 1, #lines - #tail), block = vim.list_slice(lines, #lines - #tail + 1),
      tail = tail, rendered = rendered, tail_levels = vim.list_slice(levels, #lines - #tail + 1) }
  end)()]])
end

local function float_count()
  return child.lua_get([[#vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative ~= '' end, vim.api.nvim_list_wins())]])
end

-- Tests -------------------------------------------------------------------------------------

T['visible session: the select opens; Allow sends allow, the result renders, the block goes'] = function()
  start(write_turn('Write it', 'p1', { description = 'a.txt' }))
  open_new()
  send_normal('Write it')
  wait_for(function() return #selects() == 1 end, 'select')
  local sel = selects()[1]
  eq(sel.labels, { 'Allow', 'Deny' })
  eq(sel.mode, 'n')
  local parts = view_parts()
  eq(parts.above, parts.rendered)
  eq(parts.block, parts.tail)
  eq(parts.block[1], '▸ Permission needed: Write: /x/a.txt')
  eq(vim.list_slice(parts.block, 2, 3), { '│ hello', '│ world' })
  for _, l in ipairs(parts.tail_levels) do eq(l, '0') end -- never folded
  -- the drawer names what the session waits for
  eq(has_line(drawer_lines(), 'W Write it — Write') ~= nil, true)
  pick('Allow')
  wait_for(function() return has_line(transcript(), 'Written.') ~= nil end, 'answer')
  eq(answers()[1], { subtype = 'success', request_id = 'p1', response = { behavior = 'allow', updatedInput = WRITE } })
  parts = view_parts()
  eq(parts.tail, {})
  eq(transcript(), parts.rendered)
  eq(has_line(transcript(), 'Permission needed'), nil)
  eq(has_line(transcript(), '│ written') ~= nil, true)
  eq(#selects(), 1)
end

T['Deny sends deny with the default message; the error result renders'] = function()
  start(flat({ expect = 'Write it' }, init(), status(), tool_use('t1', 'Write', WRITE), ask('p1', 'Write', WRITE),
    { expect = '"p1"' }, tool_result('t1', 'Denied by user in Neovim', true), say('Fine.'), result('Fine.')))
  open_new()
  send_normal('Write it')
  wait_for(function() return #selects() == 1 end, 'select')
  pick('Deny')
  wait_for(function() return has_line(transcript(), 'Fine.') ~= nil end, 'answer')
  eq(answers()[1], { subtype = 'success', request_id = 'p1',
    response = { behavior = 'deny', message = 'Denied by user in Neovim' } })
  eq(has_line(transcript(), '│ ERROR Denied by user in Neovim') ~= nil, true)
  eq(transcript(), view_parts().rendered)
end

T['session B asks while the user types in session A: nothing interrupts; next_waiting opens B once'] = function()
  start(flat({ expect = 'hello B' }, init(), status(), say('ready'), { expect = '"go"' },
    tool_use('t1', 'Write', WRITE), ask('p1', 'Write', WRITE), { expect = '"p1"' },
    tool_result('t1', 'written'), say('Written.'), result('Written.')))
  local b = open_new()
  child.type_keys('i', 'hello B', '<C-CR>', '<Esc>')
  wait_for(function() return has_line(transcript(), 'ready') ~= nil end, 'B ready')
  local a = open_new()
  eq(a ~= b, true)
  child.type_keys('i', 'draft text')
  eq(mode(), 'i')
  local before = child.lua_get('{ win = vim.api.nvim_get_current_win(), cursor = vim.api.nvim_win_get_cursor(0), buf = vim.api.nvim_get_current_buf() }')
  local floats = float_count()
  child.lua('require("agent-ide.session").get(...):_write({ type = "go" })', { b })
  wait_for(function() return child.lua_get('require("agent-ide.session").get(...).state', { b }) == 'waiting' end, 'B waiting')
  vim.wait(400) -- scheduled work in the child runs meanwhile
  eq(#selects(), 0)
  eq(child.lua_get('_G.notes'), {})
  eq(float_count(), floats)
  eq(mode(), 'i')
  eq(child.lua_get('{ win = vim.api.nvim_get_current_win(), cursor = vim.api.nvim_win_get_cursor(0), buf = vim.api.nvim_get_current_buf() }'), before)
  eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, -1, false)'), { 'draft text' })
  eq(child.lua_get('vim.fn.execute("messages")'):find('Claude asks', 1, true), nil)
  wait_for(function() return has_line(drawer_lines(), 'W hello B — Write') ~= nil end, 'drawer waiting row')
  -- typing goes on undisturbed
  child.type_keys(' more')
  eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, -1, false)'), { 'draft text more' })
  child.type_keys('<Esc>')
  vim.wait(200)
  eq(#selects(), 0)
  child.lua('require("agent-ide").next_waiting()')
  wait_for(function() return #selects() == 1 end, 'select for B')
  vim.wait(300)
  eq(#selects(), 1)
  eq(current().id, b)
  eq(selects()[1].labels, { 'Allow', 'Deny' })
  pick('Allow')
  wait_for(function() return has_line(transcript(), 'Written.') ~= nil end, 'B answer')
  eq(answers()[1].response.behavior, 'allow')
  -- A's draft is still there
  eq(child.lua_get('vim.api.nvim_buf_get_lines(vim.fn.bufnr("agent-ide://prompt/" .. ...), 0, -1, false)', { a }), { 'draft text more' })
end

T['ask while typing in the same session prompt: echo only; the select opens on <Esc>'] = function()
  start(flat({ expect = 'Write it' }, init(), status(), say('ready'), { expect = '"go"' },
    tool_use('t1', 'Write', WRITE), ask('p1', 'Write', WRITE), { expect = '"p1"' },
    tool_result('t1', 'written'), say('Written.'), result('Written.')))
  local id = open_new()
  child.type_keys('i', 'Write it', '<C-CR>')
  wait_for(function() return has_line(transcript(), 'ready') ~= nil end, 'ready')
  child.type_keys('next')
  child.lua('require("agent-ide.session").get(...):_write({ type = "go" })', { id })
  wait_for(function() return has_line(transcript(), 'Permission needed') ~= nil end, 'block')
  vim.wait(300)
  eq(#selects(), 0)
  eq(mode(), 'i')
  eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, -1, false)'), { 'next' })
  eq(child.lua_get('vim.fn.execute("messages")'):find('Claude asks: Write: /x/a.txt  (<leader>ay to answer)', 1, true) ~= nil, true)
  eq(child.lua_get('_G.notes'), {})
  child.type_keys('<Esc>')
  wait_for(function() return #selects() == 1 end, 'select after <Esc>')
  vim.wait(200)
  eq(#selects(), 1)
  pick('Allow')
  wait_for(function() return has_line(transcript(), 'Written.') ~= nil end, 'answer')
end

T['AskUserQuestion: one select per question; the answers go back in updatedInput'] = function()
  local input = { questions = {
    { question = 'Pick a color?', header = 'Color', multiSelect = false,
      options = { { label = 'Red', description = 'warm' }, { label = 'Blue', description = 'cool' } } },
    { question = 'Size?', header = 'Size', multiSelect = false, options = { { label = 'S' }, { label = 'L' } } },
  } }
  start(flat({ expect = 'Ask me' }, init(), status(), tool_use('t1', 'AskUserQuestion', input),
    ask('q1', 'AskUserQuestion', input, { requires_user_interaction = true }), { expect = '"q1"' },
    tool_result('t1', 'Your questions have been answered'), say('Thanks.'), result('Thanks.')))
  open_new()
  send_normal('Ask me')
  wait_for(function() return #selects() == 1 end, 'first question')
  eq(selects()[1].prompt, 'Pick a color?')
  eq(selects()[1].labels, { 'Red — warm', 'Blue — cool' })
  local parts = view_parts()
  eq(parts.above, parts.rendered)
  eq(parts.block[1], '▸ Question from Claude')
  eq(has_line(parts.block, 'Pick a color?') ~= nil, true)
  pick('Blue — cool')
  wait_for(function() return #selects() == 2 end, 'second question')
  eq(selects()[2].prompt, 'Size?')
  eq(selects()[2].labels, { 'S', 'L' })
  pick('L')
  wait_for(function() return has_line(transcript(), 'Thanks.') ~= nil end, 'answer')
  local expected = vim.deepcopy(input)
  expected.answers = { ['Pick a color?'] = 'Blue', ['Size?'] = 'L' }
  eq(answers()[1], { subtype = 'success', request_id = 'q1', response = { behavior = 'allow', updatedInput = expected } })
end

T['AskUserQuestion: cancelling a question denies it'] = function()
  local input = { questions = { { question = 'Pick?', header = 'P', multiSelect = true,
    options = { { label = 'A' }, { label = 'B' } } } } }
  start(flat({ expect = 'Ask me' }, init(), status(), tool_use('t1', 'AskUserQuestion', input),
    ask('q1', 'AskUserQuestion', input), { expect = '"q1"' },
    tool_result('t1', 'User cancelled the question in Neovim', true), say('Ok.'), result('Ok.')))
  open_new()
  send_normal('Ask me')
  wait_for(function() return #selects() == 1 end, 'question')
  eq(selects()[1].prompt, 'Pick? (several: one per round, then Done choosing)')
  child.lua('_G.cancel()')
  wait_for(function() return has_line(transcript(), 'Ok.') ~= nil end, 'answer')
  eq(answers()[1], { subtype = 'success', request_id = 'q1',
    response = { behavior = 'deny', message = 'User cancelled the question in Neovim' } })
  eq(#selects(), 1)
end

T['AskUserQuestion: multiSelect picks one option per round until Done choosing; labels go back joined by ", "'] = function()
  local input = { questions = {
    { question = 'Fruits?', header = 'F', multiSelect = true,
      options = { { label = 'Apple' }, { label = 'Banana' }, { label = 'Cherry' } } },
    { question = 'All?', header = 'A', multiSelect = true, options = { { label = 'X' }, { label = 'Y' } } },
  } }
  start(flat({ expect = 'Ask me' }, init(), status(), tool_use('t1', 'AskUserQuestion', input),
    ask('q1', 'AskUserQuestion', input, { requires_user_interaction = true }), { expect = '"q1"' },
    tool_result('t1', 'Your questions have been answered'), say('Thanks.'), result('Thanks.')))
  open_new()
  send_normal('Ask me')
  wait_for(function() return #selects() == 1 end, 'round 1')
  eq(selects()[1].labels, { 'Apple', 'Banana', 'Cherry' }) -- nothing to finish before a first choice
  pick('Cherry')
  wait_for(function() return #selects() == 2 end, 'round 2')
  eq(selects()[2].prompt, 'Fruits? (several: one per round, then Done choosing) — chosen: Cherry')
  eq(selects()[2].labels, { 'Done choosing', 'Apple', 'Banana' })
  pick('Apple')
  wait_for(function() return #selects() == 3 end, 'round 3')
  eq(selects()[3].labels, { 'Done choosing', 'Banana' })
  pick('Done choosing')
  -- second question: choosing every option ends it without a last round
  wait_for(function() return #selects() == 4 end, 'second question')
  pick('Y')
  wait_for(function() return #selects() == 5 end, 'second question round 2')
  pick('X')
  wait_for(function() return has_line(transcript(), 'Thanks.') ~= nil end, 'answer')
  eq(#selects(), 5)
  local expected = vim.deepcopy(input)
  expected.answers = { ['Fruits?'] = 'Apple, Cherry', ['All?'] = 'X, Y' }
  eq(answers()[1], { subtype = 'success', request_id = 'q1', response = { behavior = 'allow', updatedInput = expected } })
end

T['ExitPlanMode: the plan shows as markdown; keep planning denies, approve allows'] = function()
  local plan = { plan = '# Plan\n- step one\n- step two', planFilePath = '/x/plan.md' }
  start(flat({ expect = 'Plan it' }, init('plan'), status(), tool_use('t1', 'ExitPlanMode', plan),
    ask('x1', 'ExitPlanMode', plan, { requires_user_interaction = true }), { expect = '"x1"' },
    tool_result('t1', 'User wants to keep planning', true),
    tool_use('t2', 'ExitPlanMode', plan), ask('x2', 'ExitPlanMode', plan), { expect = '"x2"' },
    status('default'), tool_result('t2', 'User has approved your plan.'), say('Going.'), result('Going.')))
  open_new()
  send_normal('Plan it')
  wait_for(function() return #selects() == 1 end, 'plan select')
  eq(selects()[1].labels, { 'Approve plan', 'Approve plan and accept edits for this session', 'Keep planning' })
  local parts = view_parts()
  eq(parts.above, parts.rendered)
  eq(vim.list_slice(parts.block, 1, 4), { '▸ Plan to approve', '# Plan', '- step one', '- step two' })
  for _, l in ipairs(parts.tail_levels) do eq(l, '0') end
  pick('Keep planning')
  wait_for(function() return #selects() == 2 end, 'second plan select')
  eq(answers()[1], { subtype = 'success', request_id = 'x1',
    response = { behavior = 'deny', message = 'User wants to keep planning' } })
  pick('Approve plan')
  wait_for(function() return has_line(transcript(), 'Going.') ~= nil end, 'answer')
  eq(answers()[2], { subtype = 'success', request_id = 'x2', response = { behavior = 'allow', updatedInput = plan } })
  eq(transcript(), view_parts().rendered)
end

T['ExitPlanMode: approve and accept edits sends the next mode with the approval'] = function()
  local plan = { plan = '# Plan', planFilePath = '/x/plan.md' }
  start(flat({ expect = 'Plan it' }, init('plan'), status(), tool_use('t1', 'ExitPlanMode', plan),
    ask('x1', 'ExitPlanMode', plan, { requires_user_interaction = true }), { expect = '"x1"' },
    status('acceptEdits'), tool_result('t1', 'User has approved your plan.'), say('Going.'), result('Going.')))
  open_new()
  send_normal('Plan it')
  wait_for(function() return #selects() == 1 end, 'plan select')
  pick('Approve plan and accept edits for this session')
  wait_for(function() return has_line(transcript(), 'Going.') ~= nil end, 'answer')
  eq(answers()[1], { subtype = 'success', request_id = 'x1', response = { behavior = 'allow', updatedInput = plan,
    updatedPermissions = { { type = 'setMode', mode = 'acceptEdits', destination = 'session' } } } })
  wait_for(function() return winbar():find('mode:acceptEdits ·', 1, true) ~= nil end, 'mode confirmed')
  eq(controls(), {})
end

local ALWAYS_LOCAL = "Allow and always allow Bash(npm test:*) (saved in this project's local settings)"

T['suggestions: setMode and addRules are offered (addDirectories is not); setMode goes back with the answer'] = function()
  -- the mode change travels in the answer (updatedPermissions); Claude then reports the mode
  start(write_turn('Write it', 'p1', { permission_suggestions = { SET_MODE, ADD_RULES, ADD_DIRS } }))
  child.lua([[require('agent-ide.session').on_change(function(s, what)
    if what == 'permission' and #s.pending_permissions == 0 then _G.mode_at_answer = s.mode_requested or false end
  end)]])
  open_new()
  send_normal('Write it')
  wait_for(function() return #selects() == 1 end, 'select')
  eq(selects()[1].labels, { 'Allow', 'Deny', 'Allow and switch to acceptEdits for this session', ALWAYS_LOCAL })
  pick('Allow and switch to acceptEdits for this session')
  wait_for(function() return has_line(transcript(), 'Written.') ~= nil end, 'answer')
  eq(answers()[1], { subtype = 'success', request_id = 'p1',
    response = { behavior = 'allow', updatedInput = WRITE, updatedPermissions = { SET_MODE } } })
  eq(controls(), {}) -- no separate set_permission_mode request
  eq(child.lua_get('_G.mode_at_answer'), 'acceptEdits') -- pending in the winbar until Claude reports it
end

T['suggestions: the mode Claude reports after a setMode answer reaches the winbar'] = function()
  start(flat({ expect = 'Write it' }, init(), status(), tool_use('t1', 'Write', WRITE),
    ask('p1', 'Write', WRITE, { permission_suggestions = { SET_MODE } }), { expect = '"p1"' },
    status('acceptEdits'), tool_result('t1', 'written'), say('Written.'), result('Written.')))
  open_new()
  send_normal('Write it')
  wait_for(function() return #selects() == 1 end, 'select')
  pick('Allow and switch to acceptEdits for this session')
  wait_for(function() return winbar():find('mode:acceptEdits ·', 1, true) ~= nil end, 'mode confirmed')
end

T['suggestions: always allow only for verified destinations; the rule goes back in updatedPermissions'] = function()
  local function rules(dest, behavior)
    return { type = 'addRules', rules = { { toolName = 'Bash', ruleContent = 'npm test:*' }, { toolName = 'Read' } },
      behavior = behavior or 'allow', destination = dest }
  end
  local sugg = { rules('session'), ADD_RULES, rules('localSettings'), rules('projectSettings'), rules('userSettings'),
    rules('somewhereElse'), rules('localSettings', 'deny') }
  start(write_turn('Write it', 'p1', { permission_suggestions = sugg }))
  open_new()
  send_normal('Write it')
  wait_for(function() return #selects() == 1 end, 'select')
  -- session, projectSettings, userSettings (not verified), an unknown destination and a deny
  -- rule are left out
  eq(selects()[1].labels, { 'Allow', 'Deny', ALWAYS_LOCAL,
    "Allow and always allow Bash(npm test:*), Read (saved in this project's local settings)" })
  pick(ALWAYS_LOCAL)
  wait_for(function() return has_line(transcript(), 'Written.') ~= nil end, 'answer')
  eq(answers()[1], { subtype = 'success', request_id = 'p1',
    response = { behavior = 'allow', updatedInput = WRITE, updatedPermissions = { ADD_RULES } } })
end

T['cancel leaves the ask open; entering the window again does not reopen; <leader>ay does'] = function()
  start(write_turn('Write it', 'p1'))
  open_new()
  send_normal('Write it')
  wait_for(function() return #selects() == 1 end, 'select')
  child.lua('_G.cancel()')
  child.type_keys('<C-w>k')
  child.type_keys('<C-w>j')
  vim.wait(300)
  eq(#selects(), 1)
  eq(has_line(transcript(), 'Permission needed') ~= nil, true)
  child.type_keys('\\ay')
  wait_for(function() return #selects() == 2 end, 'reopened select')
  pick('Allow')
  wait_for(function() return has_line(transcript(), 'Written.') ~= nil end, 'answer')
  eq(#answers(), 1)
end

T['two pending asks are answered oldest first'] = function()
  start(flat({ expect = 'Two' }, init(), status(), tool_use('t1', 'Write', WRITE), tool_use('t2', 'Write', WRITE_B),
    ask('p1', 'Write', WRITE), ask('p2', 'Write', WRITE_B), { expect = '"p1"' }, { expect = '"p2"' },
    tool_result('t1', 'one'), tool_result('t2', 'two'), say('Both.'), result('Both.')))
  open_new()
  send_normal('Two')
  wait_for(function() return #selects() == 1 end, 'first select')
  wait_for(function() return has_line(transcript(), '/x/b.txt') ~= nil and #view_parts().tail > 0 end, 'both blocks')
  eq(selects()[1].prompt:find('/x/a.txt', 1, true) ~= nil, true)
  pick('Allow')
  wait_for(function() return #selects() == 2 end, 'second select')
  eq(selects()[2].prompt:find('/x/b.txt', 1, true) ~= nil, true)
  pick('Deny')
  wait_for(function() return has_line(transcript(), 'Both.') ~= nil end, 'answer')
  local a = answers()
  eq({ a[1].request_id, a[1].response.behavior, a[2].request_id, a[2].response.behavior }, { 'p1', 'allow', 'p2', 'deny' })
end

T['<S-Tab> cycles the mode; the winbar follows what Claude confirms; a control error keeps it'] = function()
  start(flat({ expect = 'hi' }, init(), status(), say('hey'), result('hey'),
    { expect = '"acceptEdits"' }, { expect = '"go"' }, status('acceptEdits'), ok('r1', { mode = 'acceptEdits' }),
    { expect = '"plan"' },
    { emit = { type = 'control_response', response = { subtype = 'error', request_id = 'r2', error = 'bad mode',
      error_code = 'invalid_mode' } } }))
  local id = open_new()
  send_normal('hi')
  wait_for(function() return winbar():find('mode:manual ·', 1, true) ~= nil and current().state == 'idle' end, 'first turn')
  child.type_keys('<S-Tab>')
  wait_for(function() return #controls() == 1 end, 'first set_permission_mode')
  eq(controls()[1], { subtype = 'set_permission_mode', mode = 'acceptEdits' })
  eq(winbar():find('mode:manual→acceptEdits ·', 1, true) ~= nil, true)
  child.lua('require("agent-ide.session").get(...):_write({ type = "go" })', { id })
  wait_for(function() return winbar():find('mode:acceptEdits ·', 1, true) ~= nil end, 'confirmed')
  child.type_keys('<S-Tab>')
  wait_for(function() return #controls() == 2 end, 'second set_permission_mode')
  eq(controls()[2], { subtype = 'set_permission_mode', mode = 'plan' })
  wait_for(function() return winbar():find('mode:acceptEdits ·', 1, true) ~= nil end, 'error keeps the mode')
  local notes = child.lua_get('_G.notes')
  eq(notes[#notes], 'Agent-IDE: cannot switch mode to plan: bad mode')
  -- the cycle and the names sent to Claude
  eq(child.lua_get([[(function()
    local m = require('agent-ide.ui.mode')
    return { m.next_mode('manual'), m.next_mode('acceptEdits'), m.next_mode('plan'), m.next_mode('auto'), m.next_mode(nil),
      m.claude_name('manual'), m.claude_name('plan') }
  end)()]]), { 'acceptEdits', 'plan', 'auto', 'manual', 'acceptEdits', 'default', 'plan' })
end

T['the mode list comes from config; manual is sent as default'] = function()
  start({}, { claude = { modes = { 'manual', 'plan' }, default_mode = 'plan' } })
  open_new()
  eq(child.lua_get('require("agent-ide.ui.mode").next_mode("plan")'), 'manual')
  child.type_keys('<S-Tab>')
  -- default_mode plan: the first press asks for manual
  eq(winbar():find('mode:?→manual ·', 1, true) ~= nil, true)
  eq(child.lua_get('require("agent-ide.ui.chat").current().deferred'),
    { { subtype = 'set_permission_mode', mode = 'default' } })
end

T['<S-Tab> before the first turn: pending in the winbar, sent right after start'] = function()
  start(flat({ expect = 'set_permission_mode' }, ok('r1', { mode = 'acceptEdits' }),
    { expect = 'hi' }, init('acceptEdits'), status(), say('hey'), result('hey')))
  open_new()
  child.type_keys('<S-Tab>')
  eq(winbar():find('mode:?→acceptEdits ·', 1, true) ~= nil, true)
  vim.wait(200)
  eq(fake.log(log), {}) -- no process started
  send_normal('hi')
  wait_for(function() return has_line(transcript(), 'hey') ~= nil end, 'answer')
  local ins = fake_ins()
  eq(ins[1], { type = 'control_request', request_id = 'r1', request = { subtype = 'set_permission_mode', mode = 'acceptEdits' } })
  eq(ins[2].type, 'user')
  eq(winbar():find('mode:acceptEdits ·', 1, true) ~= nil, true)
end

T['<leader>aM picks a model; the winbar shows it pending until Claude confirms'] = function()
  start(flat({ expect = 'hi' }, init(), status(), say('hey'), result('hey'),
    { expect = 'set_model' }, { expect = '"go"' }, ok('r1')))
  local id = open_new()
  send_normal('hi')
  wait_for(function() return winbar():find('haiku-5-5 ·', 1, true) ~= nil and current().state == 'idle' end, 'first turn')
  child.type_keys('\\aM')
  wait_for(function() return #selects() == 1 end, 'model select')
  eq(selects()[1].labels, { 'fable', 'opus', 'sonnet', 'haiku' })
  pick('sonnet')
  wait_for(function() return #controls() == 1 end, 'set_model')
  eq(controls()[1], { subtype = 'set_model', model = 'sonnet' })
  eq(winbar():find('haiku-5-5→sonnet ·', 1, true) ~= nil, true)
  child.lua('require("agent-ide.session").get(...):_write({ type = "go" })', { id })
  wait_for(function() return winbar():find(' · sonnet · ', 1, true) ~= nil end, 'model confirmed')
end

T['next_waiting: nothing needs you; done sessions are opened; global key mapped'] = function()
  start(flat({ expect = 'hi' }, init(), status(), { sleep_ms = 800 }, say('hey'), result('hey')))
  child.lua('require("agent-ide").next_waiting()')
  eq(child.lua_get('_G.notes'), { 'Agent-IDE: nothing needs you' })
  eq(child.lua_get('vim.fn.maparg("<leader>an", "n") ~= ""'), true)
  local b = open_new()
  child.type_keys('i', 'hi', '<C-CR>', '<Esc>')
  open_new() -- B is no longer on screen when its turn ends
  wait_for(function() return child.lua_get('require("agent-ide.session").get(...).state', { b }) == 'done' end, 'B done')
  child.lua('require("agent-ide").next_waiting()')
  wait_for(function() return current().id == b end, 'B opened')
  eq(child.lua_get('require("agent-ide.session").get(...).state', { b }), 'idle')
end

-- An ask of the session on screen arrives while the user is not in plain normal mode.
local function ask_later(keys_before, check_mode, keys_after)
  start(flat({ expect = 'Write it' }, init(), status(), say('ready'), { expect = '"go"' },
    tool_use('t1', 'Write', WRITE), ask('p1', 'Write', WRITE), { expect = '"p1"' },
    tool_result('t1', 'written'), say('Written.'), result('Written.')))
  local id = open_new()
  send_normal('Write it')
  wait_for(function() return has_line(transcript(), 'ready') ~= nil end, 'ready')
  child.type_keys(unpack(keys_before))
  eq(mode(), check_mode)
  child.lua('require("agent-ide.session").get(...):_write({ type = "go" })', { id })
  wait_for(function() return has_line(transcript(), 'Permission needed') ~= nil end, 'block')
  vim.wait(300)
  eq(#selects(), 0)
  eq(mode(), check_mode)
  eq(child.lua_get('vim.fn.execute("messages")'):find('Claude asks', 1, true), nil) -- echo is for typing only
  child.type_keys(unpack(keys_after))
  wait_for(function() return #selects() == 1 end, 'select back in normal mode')
  vim.wait(200)
  eq(#selects(), 1)
  eq(selects()[1].mode, 'n')
end

T['ask while a command line is being typed: no select until back in normal mode'] = function()
  ask_later({ ':echo' }, 'c', { '<Esc>' })
  eq(child.lua_get('vim.fn.getcmdline()'), '')
end

T['ask while in visual mode: no select until back in normal mode'] = function()
  ask_later({ 'i', 'abc', '<Esc>', 'v' }, 'v', { '<Esc>' })
end

T['ask while an operator is pending: no select until it is done'] = function()
  ask_later({ 'i', 'abc', '<Esc>', 'd' }, 'no', { 'l' })
end

-- A select stays open while the ask goes away; choosing then says so and sends nothing.
local function stale_case(gone)
  start(flat({ expect = 'Write it' }, init(), status(), tool_use('t1', 'Write', WRITE), ask('p1', 'Write', WRITE),
    { expect = '"go"' }, gone))
  local id = open_new()
  send_normal('Write it')
  wait_for(function() return #selects() == 1 end, 'select')
  child.lua('require("agent-ide.session").get(...):_write({ type = "go" })', { id })
  wait_for(function() return has_line(transcript(), 'Permission needed') == nil end, 'ask gone')
  pick('Allow')
  vim.wait(100)
  local notes = child.lua_get('_G.notes')
  eq(notes[#notes], 'Agent-IDE: that ask is no longer open')
  eq(answers(), {})
end

T['ask gone with the process while its select is open: choosing says so'] = function()
  stale_case({ exit = 0 })
end

T['ask gone with the turn result while its select is open: choosing says so'] = function()
  stale_case(result('Gave up.'))
end

T['answer key while the select is open opens no second one; leaving the chat frees a select that never returns'] = function()
  start(write_turn('Write it', 'p1'))
  open_new()
  send_normal('Write it')
  wait_for(function() return #selects() == 1 end, 'select')
  child.type_keys('\\ay')
  vim.wait(300)
  eq(#selects(), 1)
  -- the stub never calls back: go to the drawer (not the chat) and back
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.drawer").state().win)')
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.chat")._windows().prompt)')
  wait_for(function() return #selects() == 2 end, 'select again')
  pick('Allow')
  wait_for(function() return has_line(transcript(), 'Written.') ~= nil end, 'answer')
  eq(#answers(), 1)
end

T['echo while typing fits one line: first lines only, cut to the message space'] = function()
  local input = { file_path = '/x/' .. string.rep('long-name-', 12) .. 'a.txt\nsecond', content = 'c' }
  start(flat({ expect = 'Write it' }, init(), status(), say('ready'), { expect = '"go"' },
    tool_use('t1', 'Write\nX', input), ask('p1', 'Write\nX', input)))
  local id = open_new()
  child.type_keys('i', 'Write it', '<C-CR>')
  wait_for(function() return has_line(transcript(), 'ready') ~= nil end, 'ready')
  child.lua('vim.o.columns = 50')
  child.lua('require("agent-ide.session").get(...):_write({ type = "go" })', { id })
  wait_for(function() return child.lua_get('vim.fn.execute("messages")'):find('Claude asks', 1, true) ~= nil end, 'echo')
  local all = vim.split(child.lua_get('vim.fn.execute("messages")'), '\n')
  local msg = all[#all]
  eq(msg:find('Claude asks: Write: /x/long', 1, true), 1)
  eq(vim.endswith(msg, '…'), true)
  eq(msg:find('second', 1, true), nil)
  eq(child.lua_get('vim.fn.strdisplaywidth(...) <= vim.v.echospace', { msg }), true)
  eq(mode(), 'i')
  eq(#selects(), 0)
end

T['help lists the new keys'] = function()
  start()
  open_new()
  child.type_keys('?')
  wait_for(function() return child.lua_get('vim.api.nvim_win_get_config(0).relative') ~= '' end, 'help float')
  local text = table.concat(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, -1, false)'), '\n')
  for _, key in ipairs({ '<S-Tab>', '<leader>aM', '<leader>ay', '<leader>an' }) do
    eq(text:find(key, 1, true) ~= nil, true)
  end
end

return T

-- The models Claude Code offers: the `initialize` request at every process start, the session's
-- and the latest list (models.json), the picker's rows, the on-demand fetch, the model's name in
-- the winbar and the footer. Only the fake Claude runs (tests/fake_claude.lua).
local config = require('agent-ide.config')
local session = require('agent-ide.session')
local models = require('agent-ide.claude.models')
local fetch = require('agent-ide.claude.models_fetch')
local mode = require('agent-ide.ui.mode')
local status = require('agent-ide.status')
local fake = dofile(vim.fn.getcwd() .. '/tests/fake.lua')
local eq = MiniTest.expect.equality

local dir, orig_stdpath, orig_select, orig_notify, orig_current, picked, notes
local orig_wait, orig_timeout, orig_kill = mode._wait_ms, fetch._timeout_ms, fetch._kill_ms

local function wait(pred, ms) return vim.wait(ms or 5000, pred, 10) end

local function children()
  vim.fn.system({ 'pgrep', '-P', tostring(vim.fn.getpid()), '-f', 'fake_claude' })
  return vim.v.shell_error == 0
end

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    session._reset()
    dir = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    -- never the real `claude`: cases that need Claude configure the fake
    config.setup({ claude = { cmd = { dir .. '/no-claude' } } })
    orig_stdpath = vim.fn.stdpath
    vim.fn.stdpath = function(w) if w == 'state' then return dir .. '/state' end return orig_stdpath(w) end
    picked, notes = {}, {}
    orig_select, orig_notify, orig_current = vim.ui.select, vim.notify, status._src.current
    -- a picker that records what it was shown and chooses nothing (tests choose through `picked`)
    vim.ui.select = function(items, opts, on_choice)
      local rows = {}
      for i, it in ipairs(items) do rows[i] = opts.format_item(it) end
      picked[#picked + 1] = { items = items, rows = rows, on_choice = on_choice }
    end
    vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
  end,
  post_case = function()
    session._reset()
    vim.ui.select, vim.notify, status._src.current = orig_select, orig_notify, orig_current
    mode._wait_ms, fetch._timeout_ms, fetch._kill_ms = orig_wait, orig_timeout, orig_kill
    -- a fetch child of this case is gone before the next one starts
    assert(wait(function() return not fetch.busy() and not children() end, 8000), 'a fake Claude is still running')
    vim.wait(50, function() return false end, 10) -- scheduled writes land before the folder goes
    vim.fn.stdpath = orig_stdpath
    vim.uv.os_unsetenv('FAKE_CLAUDE_LOG')
    config.setup({})
    vim.fn.delete(dir, 'rf')
  end,
} })

local ANSWER = fake.init_answer()
local LIST = models.normalize(ANSWER.models)

local function init_event()
  return { emit = { type = 'system', subtype = 'init', session_id = 'x', model = 'claude-alpha-2',
    permissionMode = 'default', slash_commands = { 'compact', 'context' }, claude_code_version = '2.1.306' } }
end
local function turn(prompt, answer)
  return {
    { expect = prompt }, init_event(),
    { emit = { type = 'user', message = { role = 'user', content = prompt }, isReplay = true } },
    { emit = { type = 'assistant', message = { id = 'm', type = 'message', role = 'assistant',
      content = { { type = 'text', text = answer } } } } },
    { emit = { type = 'result', subtype = 'success', is_error = false, result = answer } },
  }
end
local function script(steps, extra)
  local cmd, log = fake.cmd(steps)
  config.setup({ claude = vim.tbl_extend('force', { cmd = cmd }, extra or {}) })
  return log
end
local function inputs(log)
  local out = {}
  for _, l in ipairs(fake.log(log)) do
    if l['in'] then out[#out + 1] = vim.json.decode(l['in']) end
  end
  return out
end
local function new() return session.open({ cwd = dir }) end
local function file() return dir .. '/state/agent-ide/models.json' end

local ROWS = {
  '● Default (recommended) — Alpha 2',
  '  Alpha 2 — For hard problems (claude-alpha-2)',
  '  Alpha 3 — Newest and largest (claude-alpha-3)',
  '  Beta 1 — Fast answers (claude-beta-1)',
  '  Gamma 1 — Older (claude-gamma-1-20250101)',
}

-- The initialize request ---------------------------------------------------------------------

T['initialize is the first line of a new process; the prompt sent in the same tick still works'] = function()
  local log = script(vim.list_extend({ { initialize = ANSWER } }, turn('hi', 'yo')))
  local s = new()
  eq(s:send('hi'), true)
  assert(wait(function() return s.state == 'done' end))
  local ins = inputs(log)
  eq(#ins, 2)
  eq(ins[1], { type = 'control_request', request_id = 'i1', request = { subtype = 'initialize' } })
  eq(ins[2], { type = 'user', message = { role = 'user', content = 'hi' } })
  eq(s.models, LIST)
  eq(s.models[1], { value = 'default', name = 'Default (recommended)', description = 'Alpha 2 for most work', resolved = 'claude-alpha-2' })
  eq(models.latest(), LIST)
  eq(s.events, { { kind = 'prompt', text = 'hi' }, { kind = 'text', text = 'yo' } })
  -- the turn's init brings the full command list
  eq(s.slash_commands, { 'compact', 'context' })
end

T['a deferred mode request goes after initialize; ids of settings still start at r1'] = function()
  local log = script(vim.list_extend({ { initialize = ANSWER } }, turn('hi', 'yo')))
  local s = new()
  s:set_mode('plan')
  s:send('hi')
  assert(wait(function() return s.state == 'done' end))
  local ins = inputs(log)
  eq({ ins[1].request.subtype, ins[2].request_id, ins[2].request.subtype, ins[3].type },
    { 'initialize', 'r1', 'set_permission_mode', 'user' })
end

T['commands of the answer fill the / menu before the first init'] = function()
  script({ { initialize = ANSWER }, { expect = 'never' } })
  local s = new()
  s:send('hi')
  assert(wait(function() return s.models ~= nil end))
  eq(s.slash_commands, { 'compact', 'review' })
end

T['an initialize error changes nothing; the raw view keeps it'] = function()
  script(vim.list_extend({ { initialize_error = 'not supported' } }, turn('hi', 'yo')))
  local s = new()
  s:send('hi')
  assert(wait(function() return s.state == 'done' end))
  eq(s.models, nil)
  eq(models.latest(), nil)
  eq(s.events, { { kind = 'prompt', text = 'hi' }, { kind = 'text', text = 'yo' } })
  local found = false
  for _, r in ipairs(s.raw) do
    if r.dir == 'in' and r.line:find('not supported', 1, true) then found = true end
  end
  eq(found, true)
  -- no list known: the picker asks a one-off Claude (this one has no answer either) and falls back
  mode._wait_ms, fetch._timeout_ms, fetch._kill_ms = 100, 300, 100
  mode.pick_model(s)
  assert(wait(function() return #picked == 1 end))
  eq(#picked[1].rows, 4) -- the aliases
end

-- models.json ----------------------------------------------------------------------------------

T['the latest list is persisted: four fields per model, nothing from account, 0600 in 0700'] = function()
  script(vim.list_extend({ { initialize = ANSWER } }, turn('hi', 'yo')))
  local s = new()
  s:send('hi')
  assert(wait(function() return s.state == 'done' and vim.uv.fs_stat(file()) ~= nil end))
  local text = table.concat(vim.fn.readfile(file()), '\n')
  eq(text:find('account', 1, true), nil)
  eq(text:find('example.invalid', 1, true), nil)
  eq(text:find('supportsEffort', 1, true), nil)
  local data = vim.json.decode(text)
  eq({ data.version, data.claude_version, type(data.at) }, { 1, '2.1.306', 'number' })
  eq(data.models[2], { value = 'alpha', name = 'Alpha 2', description = 'For hard problems', resolved = 'claude-alpha-2' })
  eq(#data.models, 5)
  eq(vim.uv.fs_stat(file()).mode % 512, 384)
  eq(vim.uv.fs_stat(dir .. '/state/agent-ide').mode % 512, 448)
  -- the same list again: the file is not rewritten
  local before = require('agent-ide.util.jsonfile').stamp(file())
  models.record(LIST, '2.1.306')
  vim.wait(100, function() return false end, 10)
  eq(require('agent-ide.util.jsonfile').stamp(file()), before)
  -- a changed list is
  local changed = vim.deepcopy(LIST)
  table.remove(changed)
  models.record(changed, '2.1.306')
  assert(wait(function() return #vim.json.decode(table.concat(vim.fn.readfile(file()), '\n')).models == 4 end))
end

T['models.json is read at setup; corrupt or missing reads as none'] = function()
  vim.fn.mkdir(dir .. '/state/agent-ide', 'p')
  vim.fn.writefile({ '{ not json' }, file())
  local done = false
  models.load(function() done = true end)
  assert(wait(function() return done end))
  eq(models.latest(), nil)
  vim.fn.writefile({ vim.json.encode({ version = 1, at = os.time(), claude_version = '2.1.306',
    models = { { value = 'alpha', name = 'Alpha 2' }, { name = 'no value' } } }) }, file())
  done = false
  models.load(function() done = true end)
  assert(wait(function() return done end))
  eq(models.latest(), { { value = 'alpha', name = 'Alpha 2' } })
end

-- Picker rows --------------------------------------------------------------------------------

T['rows: Claude order, names, descriptions, resolved ids; the current model marked'] = function()
  local s = new()
  s.models = vim.deepcopy(LIST)
  s.model = 'claude-alpha-2'
  eq(mode.rows(s), ROWS)
  local function marked()
    for _, r in ipairs(mode.rows(s)) do if r:sub(1, 3) == '●' then return r end end
  end
  -- the value the user chose wins among models resolving alike
  s.model_chosen = 'alpha'
  eq(marked(), '● Alpha 2 — For hard problems (claude-alpha-2)')
  s.model_chosen = nil
  s.model = 'beta' -- alias, as confirmed by set_model
  eq(marked(), '● Beta 1 — Fast answers (claude-beta-1)')
  s.model = 'claude-beta-1-20261001' -- dated full id
  eq(marked(), '● Beta 1 — Fast answers (claude-beta-1)')
  s.model = 'claude-alpha-3[1m]'
  eq(marked(), '● Alpha 3 — Newest and largest (claude-alpha-3)')
  s.model = 'claude-gamma-1-20250101'
  eq(marked(), '● Gamma 1 — Older (claude-gamma-1-20250101)')
  s.model = 'claude-zeta-9'
  eq(marked(), nil)
  -- no process yet: the model it will start with (Claude's default)
  s.model = nil
  eq(marked(), ROWS[1])
  config.setup({ claude = { cmd = { dir .. '/no-claude' }, model = 'beta' } })
  eq(marked(), '● Beta 1 — Fast answers (claude-beta-1)')
end

T['choosing sends the value exactly as Claude gave it'] = function()
  local s = new()
  s.models = vim.deepcopy(LIST)
  local got
  mode.pick_model(s, function(v) got = v end)
  eq(#picked, 1)
  eq(picked[1].rows, ROWS)
  picked[1].on_choice(picked[1].items[5])
  eq(got, 'claude-gamma-1-20250101')
  eq(s.model_requested, 'claude-gamma-1-20250101')
  eq(s.deferred, { { subtype = 'set_model', model = 'claude-gamma-1-20250101' } })
end

T['config.claude.models is used as given; known entries get their names'] = function()
  config.setup({ claude = { cmd = { dir .. '/no-claude' }, models = { 'x', 'alpha', 'claude-alpha-2' } } })
  local s = new()
  s.models = vim.deepcopy(LIST)
  s.model = 'alpha'
  eq(mode.rows(s), {
    '  x',
    '● Alpha 2 — For hard problems (claude-alpha-2)',
    '  Alpha 2 — For hard problems (claude-alpha-2)',
  })
  local got
  mode.pick_model(s, function(v) got = v end)
  picked[1].on_choice(picked[1].items[3])
  eq(got, 'claude-alpha-2')
end

T['a configured list opens at once; nothing is fetched for it'] = function()
  local log = script({ { initialize = ANSWER } }, { models = { 'x', 'alpha' } })
  mode.pick_model(new())
  eq(picked[1].rows, { '  x', '  alpha' })
  vim.wait(200, function() return false end, 10)
  eq(#fake.log(log), 0)
end

T['fallback: the session list, the latest list, the configured list, the aliases'] = function()
  local s = new()
  s.model = 'claude-alpha-2'
  eq(mode.rows(s), { '  fable', '  opus', '  sonnet', '  haiku' })
  config.setup({ claude = { cmd = { dir .. '/no-claude' }, models = { 'x', 'y' } } })
  eq(mode.rows(s), { '  x', '  y' })
  config.setup({ claude = { cmd = { dir .. '/no-claude' } } })
  models.record({ { value = 'beta', name = 'Beta 1', resolved = 'claude-beta-1' } }, '2.1.306')
  eq(mode.rows(s), { '  Beta 1 (claude-beta-1)' })
  s.models = vim.deepcopy(LIST)
  eq(mode.rows(s), ROWS)
end

-- On-demand fetch ----------------------------------------------------------------------------

T['no list known: the picker fetches it from a one-off Claude, then opens'] = function()
  local log = script({ { initialize = ANSWER } })
  local s = new()
  mode.pick_model(s)
  eq(#picked, 0) -- not synchronously
  assert(wait(function() return #picked == 1 end))
  eq(picked[1].rows, ROWS)
  eq(models.latest(), LIST)
  assert(wait(function() return not children() end))
  local l = fake.log(log)
  local argv = l[1].argv
  eq(vim.list_slice(argv, 2), { '-p', '--verbose', '--input-format', 'stream-json', '--output-format', 'stream-json',
    '--no-session-persistence' })
  eq(l[1].api_key_set, false)
  eq(l[1].cwd ~= dir and l[1].cwd ~= vim.fn.getcwd(), true) -- a temp folder of its own
  eq(#l, 2) -- only the initialize line went in
  eq(vim.json.decode(l[2]['in']), { type = 'control_request', request_id = 'models1', request = { subtype = 'initialize' } })
  assert(wait(function() return vim.uv.fs_stat(l[1].cwd) == nil end)) -- removed after
  eq(s:needs_start(), true) -- the session itself started nothing
end

T['a slow fetch: the picker opens after the wait with what is known; once'] = function()
  mode._wait_ms = 150
  script({ { sleep_ms = 800 }, { initialize = ANSWER } })
  local s = new()
  mode.pick_model(s)
  assert(wait(function() return #picked == 1 end, 600))
  eq(picked[1].rows, { '  fable', '  opus', '  sonnet', '  haiku' })
  assert(wait(function() return models.latest() ~= nil end))
  vim.wait(200, function() return false end, 10)
  eq(#picked, 1)
end

T['the picker does not pop up when the user typed meanwhile'] = function()
  mode._wait_ms = 100
  script({ { sleep_ms = 300 }, { initialize = ANSWER } })
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  mode.pick_model(new())
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'typed' })
  assert(wait(function() return models.latest() ~= nil end))
  eq(#picked, 0)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T['fetch timeout: nothing recorded, the child that never answers is ended'] = function()
  mode._wait_ms, fetch._timeout_ms, fetch._kill_ms = 100, 300, 200
  script({ { ignore_stdin = true } })
  mode.pick_model(new())
  assert(wait(function() return #picked == 1 end))
  eq(fetch.busy(), true)
  assert(wait(function() return not fetch.busy() end))
  assert(wait(function() return not children() end))
  eq(models.latest(), nil)
end

T['a stale latest list is refreshed in the background, once per Neovim'] = function()
  local log = script({ { initialize = ANSWER } })
  vim.fn.mkdir(dir .. '/state/agent-ide', 'p')
  vim.fn.writefile({ vim.json.encode({ version = 1, at = os.time() - 8 * 86400, claude_version = '2.1.306',
    models = { { value = 'beta', name = 'Beta 1' } } }) }, file())
  local done = false
  models.load(function() done = true end)
  assert(wait(function() return done end))
  local s = new()
  mode.pick_model(s)
  eq(#picked, 1) -- at once, with the stale list
  eq(picked[1].rows, { '  Beta 1' })
  assert(wait(function() return models.latest() and #models.latest() == 5 end))
  assert(wait(function() return #vim.json.decode(table.concat(vim.fn.readfile(file()), '\n')).models == 5 end))
  assert(wait(function() return not children() end))
  -- made stale again: no second refresh in this Neovim
  models.record({ { value = 'beta', name = 'Beta 1' } }, '1.0.0')
  vim.fn.writefile({}, log)
  mode.pick_model(s)
  vim.wait(300, function() return false end, 10)
  eq(#fake.log(log), 0)
end

-- Display ------------------------------------------------------------------------------------

T['the winbar shows the model by name; a pending change keeps old→new'] = function()
  local s = new()
  s.models = vim.deepcopy(LIST)
  s.model = 'claude-alpha-2'
  eq((mode.labels(s)), 'alpha 2')
  s.model_requested = 'beta'
  eq((mode.labels(s)), 'alpha 2→beta 1')
  s.model_requested = nil
  s.model = 'claude-zeta-9-20260101' -- not in the list: today's short form
  eq((mode.labels(s)), 'zeta-9')
  s.model = 'claude-alpha-3'
  local bar = require('agent-ide.ui.chat')._winbar(s, { key = dir, name = 'proj', sessions = {} }, 100)
  eq(bar:find('alpha 3', 1, true) ~= nil, true)
end

return T

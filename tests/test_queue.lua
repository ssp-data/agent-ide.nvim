-- The queue panel (ui/queue.lua): Q in the chat, the timeline of sent, running and queued
-- prompts, x takes a queued one back, it follows the chat.
local fake = dofile(vim.fn.getcwd() .. '/tests/fake.lua')
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()
local queue = require('agent-ide.ui.queue')

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

T['layout: header with the count, sent prompts dim, the running one, queued ones numbered; cut to the width'] = function()
  local s = { state = 'busy', turn_start = 4, queue = { 'third prompt\nmore', 'fourth' }, events = {
    { kind = 'prompt', text = 'first prompt' }, { kind = 'text', text = 'a' },
    { kind = 'prompt', text = 'sub', sidechain = true },
    { kind = 'prompt', text = 'second prompt that is rather long for the panel' }, { kind = 'text', text = 'b' },
  } }
  local l = queue.layout(s, 30, { busy = 'B', waiting = 'W' })
  eq(l.lines, { 'Queue · 2 waiting', '✓ first prompt', 'B second prompt that is rath…', '1. third prompt', '2. fourth' })
  eq(vim.tbl_map(function(r) return r and (r.kind .. ':' .. (r.event or r.n)) or 'none' end, { l.rows[1] or false, l.rows[2], l.rows[3], l.rows[4], l.rows[5] }),
    { 'none', 'sent:1', 'running:4', 'queued:1', 'queued:2' })
  for _, w in ipairs(l.lines) do eq(vim.fn.strdisplaywidth(w) <= 30, true) end
  local groups = vim.tbl_map(function(h) return h.group end, l.hl)
  eq(groups, { 'AgentIdeSection', 'AgentIdeAge', 'AgentIdeAge', 'AgentIdeBusy', 'AgentIdeSection', 'AgentIdeSection' })
  -- waiting: the waiting mark and colour; idle: no running row; more than five sent: a count
  s.state = 'waiting'
  eq(queue.layout(s, 30, { busy = 'B', waiting = 'W' }).lines[3], 'W second prompt that is rath…')
  s.state, s.queue = 'idle', {}
  eq(queue.layout(s, 30, {}).lines, { 'Queue · 0 waiting', '✓ first prompt', '✓ second prompt that is rath…' })
  local many = { state = 'idle', turn_start = 1, queue = {}, events = {} }
  for i = 1, 8 do many.events[i] = { kind = 'prompt', text = 'p' .. i } end
  local lines = queue.layout(many, 30, {}).lines
  eq(lines[2], '… 3 earlier')
  eq({ lines[3], lines[#lines] }, { '✓ p4', '✓ p8' })
  eq(queue.layout({ state = 'idle', turn_start = 1, queue = {}, events = {} }, 30, {}).lines, { 'Queue · 0 waiting', 'nothing sent yet' })
end

-- Child helpers -----------------------------------------------------------------------------

local function init()
  return { emit = { type = 'system', subtype = 'init', session_id = 'x', model = 'claude-haiku-5-5-20261001',
    permissionMode = 'default', slash_commands = {}, claude_code_version = '2.1.306' } }
end
local function say(t)
  return { emit = { type = 'assistant', message = { id = 'm', type = 'message', role = 'assistant',
    content = { { type = 'text', text = t } } } } }
end
local function result(t) return { emit = { type = 'result', subtype = 'success', is_error = false, result = t } } end

local function start(steps)
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
    projects_dir = projects, helper = { enabled = false },
    live = { interval_ms = 50, cmd = { 'echo', '[]' } }, icons_style = 'plain', icons = ICONS, claude = { cmd = cmd },
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

local function current()
  return child.lua_get('(function() local s = require("agent-ide.ui.chat").current(); return s and { id = s.id, state = s.state, queue = #s.queue, events = #s.events } end)()')
end

local function expand()
  child.lua('local d = require("agent-ide.ui.drawer"); if not d.state().win then require("agent-ide").toggle() end')
  if has_line(drawer_lines(), '> repo') then
    drawer_cursor_to('> repo')
    child.type_keys('<CR>')
  end
end

local function open_new()
  expand()
  drawer_cursor_to('    + New session')
  child.type_keys('<CR>')
  wait_for(function() return current() ~= vim.NIL end, 'chat open')
end

local function panel() return child.lua_get('require("agent-ide.ui.queue")._state()') end
local function panel_lines()
  local p = panel()
  return p.win and child.lua_get('vim.api.nvim_buf_get_lines(..., 0, -1, false)', { p.buf }) or nil
end
local function prompt_lines()
  return child.lua_get('vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(require("agent-ide.ui.chat")._windows().prompt), 0, -1, false)')
end

T['Q opens the panel left of the transcript; it shows the running and queued prompts; x takes one back'] = function()
  start({ { expect = 'first' }, init(), { expect = 'interrupt' }, result('stopped') })
  open_new()
  child.type_keys('Q')
  local p = panel()
  eq(p.win ~= nil, true)
  local twin = child.lua_get('require("agent-ide.ui.chat")._windows().transcript')
  eq(child.lua_get('vim.fn.win_screenpos(...)[2] < vim.fn.win_screenpos(' .. twin .. ')[2]', { p.win }), true)
  eq(child.lua_get('vim.api.nvim_win_get_width(...)', { p.win }), 36)
  eq(child.lua_get('vim.api.nvim_get_current_win() ~= ...', { p.win }), true) -- never takes the focus
  eq(panel_lines(), { 'Queue · 0 waiting', 'nothing sent yet' })
  eq(child.lua_get('vim.api.nvim_buf_get_name(...)', { p.buf }), 'agents://repo/new session · queue')
  -- a prompt runs, two more are queued
  child.type_keys('i', 'first', '<Esc>', '\\<CR>')
  wait_for(function() return current().state == 'busy' end, 'busy')
  child.type_keys('i', 'second one', '<Esc>', '\\<CR>')
  child.type_keys('i', 'third one', '<Esc>', '\\<CR>')
  wait_for(function() return current().queue == 2 end, 'queued')
  wait_for(function() return vim.deep_equal(panel_lines(), { 'Queue · 2 waiting', 'B first', '1. second one', '2. third one' }) end, 'panel rows')
  -- x on a queued row: back into the prompt buffer
  child.lua('vim.api.nvim_set_current_win(...)', { p.win })
  child.lua('vim.api.nvim_win_set_cursor(0, { 3, 0 })')
  child.type_keys('x')
  wait_for(function() return current().queue == 1 end, 'dequeued')
  eq(panel_lines(), { 'Queue · 1 waiting', 'B first', '1. third one' })
  eq(prompt_lines(), { 'second one' })
  -- Q again closes; Q reopens
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.chat")._windows().transcript)')
  child.type_keys('Q')
  eq(panel().win, nil)
  child.type_keys('Q')
  eq(panel().win ~= nil, true)
  eq(panel_lines(), { 'Queue · 1 waiting', 'B first', '1. third one' })
  -- interrupt: the queue comes back to the prompt, the panel follows
  child.type_keys('<C-c>')
  wait_for(function() return current().state == 'idle' end, 'idle')
  wait_for(function() return vim.deep_equal(panel_lines(), { 'Queue · 0 waiting', '✓ first' }) end, 'after interrupt')
  -- <CR> on the sent row: the transcript cursor on its prompt
  child.lua('vim.api.nvim_set_current_win(...)', { panel().win })
  child.lua('vim.api.nvim_win_set_cursor(0, { 2, 0 })')
  child.type_keys('<CR>')
  eq(child.lua_get('vim.api.nvim_get_current_win()'), twin)
  eq(child.lua_get('vim.api.nvim_get_current_line()'), 'first')
  -- the panel follows the chat to another session
  drawer_cursor_to('Alpha basics')
  child.type_keys('<CR>')
  wait_for(function() return current().id == FIXTURE_ID end, 'fixture open')
  wait_for(function() return panel().sid == FIXTURE_ID end, 'panel follows')
  eq(child.lua_get('vim.api.nvim_buf_get_name(...)', { panel().buf }), 'agents://repo/Alpha basics · queue')
  -- q in the panel closes it; g? lists its keys
  child.lua('vim.api.nvim_set_current_win(...)', { panel().win })
  child.lua('_G.rows = nil; require("agent-ide.ui.help").open = function(_, rows) _G.rows = rows end')
  child.type_keys('g?')
  eq(vim.tbl_map(function(r) return r.key end, child.lua_get('_G.rows')), { '<CR>', 'x', 'q' })
  child.type_keys('q')
  eq(panel().win, nil)
end

return T

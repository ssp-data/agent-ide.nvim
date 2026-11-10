-- `+ New session` pressed again: an unsent new session of the project (no prompt sent, no
-- process) is shown again with its draft; a count makes a separate one; once the first prompt is
-- sent, the next press makes a new one. Each case drives a child Neovim with the fake Claude.
local fake = dofile(vim.fn.getcwd() .. '/tests/fake.lua')
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()

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
    -- one synthetic session, so the project is listed
    local dir = projects .. '/-repo'
    vim.fn.mkdir(dir, 'p')
    local rec = vim.json.encode({ type = 'user', uuid = 'z1', cwd = repo, message = { role = 'user', content = 'Old one' } })
    vim.fn.writefile({ rec }, dir .. '/22222222-2222-4222-8222-222222222222.jsonl')
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
    projects_dir = projects,
    helper = { enabled = false },
    live = { interval_ms = 50, cmd = { 'echo', '[]' } },
    icons_style = 'plain', icons = ICONS,
    claude = { cmd = cmd },
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

local function current()
  return child.lua_get('(function() local s = require("agent-ide.ui.chat").current(); return s and s.id end)()')
end

local function prompt_lines()
  return child.lua_get('vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(require("agent-ide.ui.chat")._windows().prompt), 0, -1, false)')
end

-- Press `+ New session` (with `keys`, default `<CR>`); returns the session id the chat shows.
local function press_new(keys)
  if child.lua_get('require("agent-ide.ui.drawer").state().win') == vim.NIL then
    child.lua('require("agent-ide").toggle()')
  end
  wait_for(function() return has_line(drawer_lines(), ' repo  ') ~= nil end, 'project row')
  if has_line(drawer_lines(), '> repo  ') then
    drawer_cursor_to('> repo  ')
    child.type_keys('<CR>')
  end
  drawer_cursor_to('    + New session')
  child.type_keys(keys or '<CR>')
  wait_for(function()
    return child.lua_get('vim.api.nvim_get_current_win() == require("agent-ide.ui.chat")._windows().prompt')
  end, 'chat open')
  return current()
end

local function sessions() return child.lua_get('#require("agent-ide.session").all()') end

T['pressed again: the unsent new session comes back with its draft'] = function()
  start()
  local a = press_new()
  child.type_keys('i', 'half a thought', '<Esc>')
  local b = press_new()
  eq(b, a)
  eq(prompt_lines(), { 'half a thought' })
  eq(sessions(), 1)
end

T['pressed again with an empty draft: the same session too'] = function()
  start()
  local a = press_new()
  local b = press_new()
  eq(b, a)
  eq(sessions(), 1)
end

T['a count makes a separate new session; the plain press then shows the newest'] = function()
  start()
  local a = press_new()
  child.type_keys('i', 'first draft', '<Esc>')
  local b = press_new('2<CR>')
  eq(b ~= a, true)
  eq(prompt_lines(), { '' })
  child.type_keys('i', 'second draft', '<Esc>')
  eq(press_new(), b)
  eq(prompt_lines(), { 'second draft' })
  eq(sessions(), 2)
end

T['once the first prompt is sent, the next press starts a new session'] = function()
  start({ { expect = 'Hi' }, init(), say('Hello.'), result('Hello.') })
  local a = press_new()
  child.type_keys('i', 'Hi', '<C-CR>', '<Esc>')
  wait_for(function() return child.lua_get('require("agent-ide.session").get(...).state', { a }) == 'idle' end, 'turn end')
  local b = press_new()
  eq(b ~= a, true)
  eq(prompt_lines(), { '' })
end

return T

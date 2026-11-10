-- Drafts kept on disk (ui/drafts.lua): written as you type, back when the prompt opens, gone
-- with a send or `:q!`, taken over by `+ New session`.
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
    require('agent-ide.ui.drafts').DELAY_MS = 60
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

local function prompt_lines()
  return child.lua_get('vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(require("agent-ide.ui.chat")._windows().prompt), 0, -1, false)')
end

local function current()
  return child.lua_get('(function() local s = require("agent-ide.ui.chat").current(); return s and { id = s.id, state = s.state, events = #s.events } end)()')
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

local function open_fixture()
  expand()
  drawer_cursor_to('Alpha basics')
  child.type_keys('<CR>')
  wait_for(function() return current() ~= vim.NIL and current().id == FIXTURE_ID end, 'fixture open')
end

local function draft_file(id) return child.lua_get('require("agent-ide.ui.drafts").path(...)', { id }) end
local function exists(p) return vim.uv.fs_stat(p) ~= nil end
local function notes() return child.lua_get('_G.notes') end

local function write_draft(id, cwd, text)
  local dir = child.lua_get('require("agent-ide.ui.drafts")._dir()')
  vim.fn.mkdir(dir, 'p')
  vim.fn.writefile(vim.split('---\nagent-ide: draft\nsession: ' .. id .. '\ncwd: ' .. cwd .. '\nsaved: 2026-11-10T10:00:00\n---\n' .. text, '\n', { plain = true }), dir .. '/' .. id .. '.md')
end

-- Tests -------------------------------------------------------------------------------------

T['typing writes the draft file (0600, frontmatter, text as typed); an emptied prompt removes it'] = function()
  start()
  open_new()
  local id = current().id
  local file = draft_file(id)
  child.type_keys('i', 'first line', '<CR>', '  second, 100% kept')
  wait_for(function() return exists(file) end, 'draft file')
  local st = vim.uv.fs_stat(file)
  eq(bit.band(st.mode, 511), 384)
  eq(bit.band(vim.uv.fs_stat(vim.fs.dirname(file)).mode, 511), 448)
  wait_for(function() return (vim.fn.readfile(file)[7] or '') == 'first line' and vim.fn.readfile(file)[8] == '  second, 100% kept' end, 'text written')
  local lines = vim.fn.readfile(file)
  eq(vim.list_slice(lines, 1, 4), { '---', 'agent-ide: draft', 'session: ' .. id, 'cwd: ' .. repo })
  eq(lines[5]:match('^saved: %d%d%d%d%-%d%d%-%d%dT') ~= nil, true)
  eq(lines[6], '---')
  eq(#lines, 8)
  local d = child.lua_get('require("agent-ide.ui.drafts").read(...)', { file })
  eq({ d.session, d.cwd, d.text }, { id, repo, 'first line\n  second, 100% kept' })
  -- leaving insert mode flushes at once
  child.type_keys('<Esc>', 'ddgg0', 'i', 'x', '<Esc>')
  eq(vim.fn.readfile(file)[7], 'xfirst line')
  -- an empty prompt: no file
  child.type_keys('ggdG')
  wait_for(function() return not exists(file) end, 'file removed')
end

T['a successful send removes the draft; :q! removes it; a hidden prompt (:q) keeps it'] = function()
  start({ { expect = 'Hi there' }, init(), say('Hello.'), result('Hello.') })
  open_new()
  local id = current().id
  local file = draft_file(id)
  child.type_keys('i', 'Hi there', '<Esc>')
  eq(exists(file), true)
  -- :q hides the prompt: the draft stays on disk and comes back with the window
  child.cmd('quit')
  eq(exists(file), true)
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.chat")._windows().transcript)')
  child.type_keys('i', '<Esc>')
  eq(prompt_lines(), { 'Hi there' })
  child.type_keys('\\<CR>')
  wait_for(function() local c = current(); return c.events >= 2 and c.state == 'idle' end, 'turn end')
  eq(exists(file), false)
  eq(prompt_lines(), { '' })
  -- :q! discards: the draft on disk goes too
  child.type_keys('i', 'thrown away', '<Esc>')
  eq(exists(file), true)
  child.cmd('quit!')
  wait_for(function() return not exists(file) end, 'removed with :q!')
end

T['a draft on disk comes back when the session opens, with a notice; a deleted session takes its draft along'] = function()
  start()
  write_draft(FIXTURE_ID, repo, 'left over\nfrom last time')
  open_fixture()
  eq(prompt_lines(), { 'left over', 'from last time' })
  eq(has_line(notes(), 'Agent-IDE: draft restored (2 lines)') ~= nil, true)
  -- unchanged text is not written again (the file keeps its time stamp)
  local file = draft_file(FIXTURE_ID)
  local before = vim.uv.fs_stat(file).mtime
  vim.wait(200)
  eq(vim.uv.fs_stat(file).mtime, before)
  -- the prompt buffer unloaded on purpose (:bdelete): the draft goes
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.chat")._windows().prompt)')
  child.cmd('bdelete!')
  wait_for(function() return not exists(file) end, 'removed with :bdelete')
end

T['+ New session takes over the newest orphan draft of its project; listed and open sessions are left alone'] = function()
  start()
  write_draft('orphan-old', repo, 'older orphan')
  write_draft('orphan-new', repo, 'newer orphan')
  write_draft('other-project', tmp .. '/elsewhere', 'not mine')
  write_draft(FIXTURE_ID, repo, 'belongs to the fixture')
  local dir = child.lua_get('require("agent-ide.ui.drafts")._dir()')
  -- newest by its saved time
  local f = io.open(dir .. '/orphan-new.md', 'r'); local t = f:read('a'); f:close()
  f = io.open(dir .. '/orphan-new.md', 'w'); f:write((t:gsub('saved: [^\n]+', 'saved: 2026-11-10T11:00:00'))); f:close()
  open_new()
  local id = current().id
  eq(prompt_lines(), { 'newer orphan' })
  eq(exists(dir .. '/orphan-new.md'), false)
  eq(exists(draft_file(id)), true)
  eq(child.lua_get('require("agent-ide.ui.drafts").read(...)', { draft_file(id) }).session, id)
  for _, keep in ipairs({ 'orphan-old', 'other-project', FIXTURE_ID }) do eq({ keep, exists(dir .. '/' .. keep .. '.md') }, { keep, true }) end
  -- the same new session again (unsent): no second take-over; a count starts another, which takes the older orphan
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.drawer").state().win)')
  drawer_cursor_to('    + New session')
  child.type_keys('<CR>')
  eq(current().id, id)
  eq(prompt_lines(), { 'newer orphan' })
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.drawer").state().win)')
  drawer_cursor_to('    + New session')
  child.type_keys('2<CR>')
  wait_for(function() return current().id ~= id end, 'second new session')
  eq(prompt_lines(), { 'older orphan' })
  eq(exists(dir .. '/orphan-old.md'), false)
end

T['quitting Neovim flushes the draft and keeps it'] = function()
  start()
  open_new()
  local id = current().id
  child.lua('require("agent-ide.ui.drafts").DELAY_MS = 60000') -- no timer write: only the exit flush can keep it
  child.type_keys('i', 'typed and gone')
  pcall(child.type_keys, '<Esc>:qa<CR>')
  wait_for(function() return not pcall(child.lua_get, '1') end, 'Neovim to exit', 3000)
  local file = vim.fn.stdpath('state') .. '/agent-ide/drafts/' .. id .. '.md'
  eq(exists(file), true)
  eq(vim.fn.readfile(file)[7], 'typed and gone')
end

return T

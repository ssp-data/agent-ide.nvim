-- UI integration tests: each case drives a fresh child Neovim.
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()

local FIXTURES = vim.fn.fnamemodify('tests/fixtures/projects', ':p'):gsub('/$', '')
local ALPHA = FIXTURES .. '/-home-u-git-alpha/11111111-1111-4111-8111-111111111111.jsonl'
local ALPHA_ID = '11111111-1111-4111-8111-111111111111'
local ICONS = { open = 'v', closed = '>', project = 'P', waiting = 'W', busy = 'B', idle = 'I', parked = '.' }
local LIVE_JSON = '[{"sessionId":"' .. ALPHA_ID .. '","status":"waiting","pid":1,"cwd":"/home/u/git/alpha"}]'

local T = MiniTest.new_set({ hooks = {
  post_case = function() child.stop() end,
  post_once = function() child.stop() end,
} })

-- Start a child with the plugin set up against `projects_dir` (fixtures by default).
local function start(projects_dir)
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[
    vim.env.TMUX = nil
    _G.notes = {}
    vim.notify = function(msg) table.insert(_G.notes, msg) end
    require('agent-ide').setup(...)
  ]], { {
    projects_dir = projects_dir or FIXTURES,
    helper = { enabled = false },
    live = { interval_ms = 50, cmd = { 'echo', LIVE_JSON } },
    icons = ICONS,
  } })
end

local function wait_for(cond, what)
  local ok = vim.wait(2000, cond, 20)
  if not ok then error('timed out waiting for ' .. what, 2) end
end

local function drawer_lines()
  return child.lua_get([[(function()
    local s = require('agent-ide.ui.drawer').state()
    return s.buf and vim.api.nvim_buf_get_lines(s.buf, 0, -1, false) or {}
  end)()]])
end

local function has_line(lines, pattern, plain)
  for i, l in ipairs(lines) do
    if l:find(pattern, 1, plain) then return i end
  end
end

local function wait_drawer_line(pattern, plain)
  wait_for(function() return has_line(drawer_lines(), pattern, plain) ~= nil end, 'drawer line ' .. pattern)
end

-- Focus the drawer and put the cursor on the first line containing `text`.
local function drawer_cursor_to(text)
  wait_drawer_line(text, true)
  local row = has_line(drawer_lines(), text, true)
  child.lua('local s = require("agent-ide.ui.drawer").state(); vim.api.nvim_set_current_win(s.win); vim.api.nvim_win_set_cursor(s.win, { ..., 0 })', { row })
end

-- Lines of the chat transcript (the chat view focuses its prompt buffer).
local function buf_lines()
  return child.lua_get([[(function()
    local w = require('agent-ide.ui.chat')._windows().transcript
    return w and vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false) or {}
  end)()]])
end

-- Evaluate `expr` with the chat transcript window current.
local function in_transcript(expr)
  return child.lua_get('vim.api.nvim_win_call(require("agent-ide.ui.chat")._windows().transcript, function() return ' .. expr .. ' end)')
end

-- Toggle, expand `project`, open the session titled `title`; waits for the history to load.
local function open_session(project, title)
  child.lua('require("agent-ide").toggle()')
  drawer_cursor_to('> P ' .. project .. '  ')
  child.type_keys('<CR>')
  drawer_cursor_to(title)
  child.type_keys('<CR>')
  wait_for(function() return has_line(buf_lines(), '## You', true) ~= nil end, 'history loaded')
end

local function write_session(dir, cwd, id, prompt)
  vim.fn.mkdir(dir, 'p')
  local rec = vim.json.encode({ type = 'user', uuid = 'z1', cwd = cwd, message = { role = 'user', content = prompt } })
  vim.fn.writefile({ rec }, dir .. '/' .. id .. '.jsonl')
end

T['toggle creates Agents tab with drawer on the right at width 44'] = function()
  start()
  child.lua('require("agent-ide").toggle()')
  eq(child.lua_get('vim.fn.tabpagenr("$")'), 2)
  local s = child.lua_get([[(function()
    local s = require('agent-ide.ui.drawer').state()
    return { nr = vim.fn.win_id2win(s.win), last = vim.fn.winnr('$'), width = vim.api.nvim_win_get_width(s.win),
      ft = vim.bo[s.buf].filetype, fix = vim.wo[s.win].winfixwidth, number = vim.wo[s.win].number,
      bt = vim.bo[s.buf].buftype, modifiable = vim.bo[s.buf].modifiable }
  end)()]])
  eq(s, { nr = 2, last = 2, width = 44, ft = 'agent-ide', fix = true, number = false, bt = 'nofile', modifiable = false })
end

T['drawer window has list off even when listchars is set'] = function()
  start()
  child.lua('vim.o.list = true; vim.o.listchars = "eol:$"')
  child.lua('require("agent-ide").toggle()')
  eq(child.lua_get('vim.wo[require("agent-ide.ui.drawer").state().win].list'), false)
end

T['? opens the shortcut help, q closes it, / is not mapped'] = function()
  start()
  child.lua('require("agent-ide").toggle()')
  local drawer_win = child.lua_get('require("agent-ide.ui.drawer").state().win')
  eq(child.lua_get('vim.fn.maparg("/", "n")'), '')
  child.type_keys('?')
  wait_for(function() return child.lua_get('vim.api.nvim_win_get_config(0).relative') ~= '' end, 'help float')
  local text = table.concat(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, -1, false)'), '\n')
  for _, key in ipairs({ '<CR>', 'za', 'R', 'gp', 'q', '?' }) do
    eq(text:find(key, 1, true) ~= nil, true)
  end
  eq(child.lua_get('vim.bo.modifiable'), false)
  child.type_keys('?') -- opening again from the float's own key closes; no stacking
  wait_for(function() return child.lua_get('vim.api.nvim_win_get_config(0).relative') == '' end, 'help closed by ?')
  child.type_keys('?')
  wait_for(function() return child.lua_get('vim.api.nvim_win_get_config(0).relative') ~= '' end, 'help float again')
  child.type_keys('q')
  wait_for(function() return child.lua_get('vim.api.nvim_get_current_win()') == drawer_win end, 'help closed by q')
  child.type_keys('?')
  wait_for(function() return child.lua_get('vim.api.nvim_win_get_config(0).relative') ~= '' end, 'help float 3')
  child.type_keys('<Esc>')
  wait_for(function() return child.lua_get('vim.api.nvim_get_current_win()') == drawer_win end, 'help closed by Esc')
  eq(child.lua_get('#vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative ~= "" end, vim.api.nvim_list_wins())'), 0)
end

T['help.open twice does not stack floats'] = function()
  start()
  child.lua([[local h = require('agent-ide.ui.help'); h.open('t', { { key = 'a', desc = 'b' } }); h.open('t', { { key = 'a', desc = 'b' } })]])
  eq(child.lua_get('#vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative ~= "" end, vim.api.nvim_list_wins())'), 1)
end

T['drawer on the left when configured'] = function()
  start()
  child.lua('require("agent-ide").setup({ drawer = { side = "left", width = 30 } })')
  child.lua('require("agent-ide").toggle()')
  local s = child.lua_get([[(function()
    local s = require('agent-ide.ui.drawer').state()
    return { nr = vim.fn.win_id2win(s.win), width = vim.api.nvim_win_get_width(s.win) }
  end)()]])
  eq(s, { nr = 1, width = 30 })
end

T['drawer lists fixture projects with live state'] = function()
  start()
  child.lua('require("agent-ide").toggle()')
  wait_drawer_line('^> P alpha  W ')
  local lines = drawer_lines()
  eq(has_line(lines, '-nocwd', true) ~= nil, true)
  eq(lines[has_line(lines, '-nocwd', true)]:find('(gone)', 1, true) ~= nil, true)
end

T['enter on project expands; enter on session opens its history in the chat view'] = function()
  start()
  child.lua('require("agent-ide").toggle()')
  drawer_cursor_to('> P alpha  ')
  child.type_keys('<CR>')
  wait_drawer_line('Sessions (', true)
  drawer_cursor_to('Alpha basics')
  child.type_keys('<CR>')
  wait_for(function() return has_line(buf_lines(), '## You', true) ~= nil end, 'history loaded')
  eq(in_transcript('vim.api.nvim_buf_get_name(0)'), 'agent-ide://chat/' .. ALPHA_ID)
  local lines = buf_lines()
  local bash = has_line(lines, '▸ Bash:', true)
  eq(bash ~= nil, true)
  eq(in_transcript('vim.fn.foldclosed(' .. bash .. ')'), bash)
  eq(in_transcript('vim.bo.modifiable'), false)
  eq(in_transcript('vim.bo.filetype'), 'markdown')
  eq(in_transcript('vim.fn.line(".") == vim.fn.line("$")'), true)
  -- running in another Claude (live: waiting): the history shows, the winbar says so
  eq(in_transcript('vim.wo.winbar'), 'alpha · Alpha basics · model ? · mode:? · waiting')
end

T['history of a session with unknown records shows an unknown fold'] = function()
  start()
  open_session('alpha', 'Alpha basics')
  eq(has_line(buf_lines(), '▸ unknown: future-thing', true) ~= nil, true)
end

T['global cwd unchanged, tab cwd set only when project folder exists'] = function()
  local tmp = vim.fn.tempname()
  local repo = tmp .. '/repo'
  vim.fn.mkdir(repo, 'p')
  vim.fn.system({ 'git', 'init', '-q', repo })
  write_session(tmp .. '/projects/-repo', repo, '55555555-5555-4555-8555-555555555555', 'Hello repo')
  start(tmp .. '/projects')
  local before = child.lua_get('vim.fn.getcwd(-1, -1)')
  open_session('repo', 'Hello repo')
  eq(child.lua_get('vim.fn.getcwd(-1, -1)'), before)
  eq(child.lua_get('vim.fn.getcwd(-1, 0)'), repo)
  -- a project whose folder is gone leaves the tab cwd alone
  start()
  local tab_before = child.lua_get('vim.fn.getcwd(-1, -1)')
  open_session('alpha', 'Alpha basics')
  eq(child.lua_get('vim.fn.getcwd(-1, 0)'), tab_before)
  eq(child.lua_get('vim.fn.getcwd(-1, -1)'), tab_before)
  vim.fn.delete(tmp, 'rf')
end

T['toggle twice closes and reopens drawer; from another tab jumps back'] = function()
  start()
  child.lua('require("agent-ide").toggle()')
  local tab = child.lua_get('require("agent-ide.ui.drawer").state().tab')
  child.lua('require("agent-ide").toggle()')
  eq(child.lua_get('require("agent-ide.ui.drawer").state().win'), vim.NIL)
  eq(child.lua_get('vim.fn.tabpagenr("$")'), 2)
  child.lua('require("agent-ide").toggle()')
  eq(child.lua_get('vim.api.nvim_win_is_valid(require("agent-ide.ui.drawer").state().win)'), true)
  child.cmd('tabprevious')
  eq(child.lua_get('vim.api.nvim_get_current_tabpage()') ~= tab, true)
  child.cmd('Agents')
  eq(child.lua_get('vim.api.nvim_get_current_tabpage()'), tab)
  eq(child.lua_get('vim.fn.tabpagenr("$")'), 2)
end

T['closing the Agents tab resets state; next toggle makes a fresh tab'] = function()
  start()
  child.lua('require("agent-ide").toggle()')
  local tab = child.lua_get('require("agent-ide.ui.drawer").state().tab')
  child.cmd('tabclose')
  eq(child.lua_get('vim.fn.tabpagenr("$")'), 1)
  eq(child.lua_get('require("agent-ide.ui.drawer").state().tab'), vim.NIL)
  child.lua('require("agent-ide").toggle()')
  eq(child.lua_get('vim.fn.tabpagenr("$")'), 2)
  local s = child.lua_get('require("agent-ide.ui.drawer").state()')
  eq(s.tab ~= tab, true)
  eq(child.lua_get('vim.api.nvim_win_is_valid(...)', { s.win }), true)
end

T['history reloads after the transcript file changes'] = function()
  local tmp = vim.fn.tempname()
  local dir = tmp .. '/-home-u-git-alpha'
  vim.fn.mkdir(dir, 'p')
  local copy = dir .. '/' .. ALPHA_ID .. '.jsonl'
  vim.fn.writefile(vim.fn.readfile(ALPHA), copy)
  start(tmp)
  open_session('alpha', 'Alpha basics')
  eq(has_line(buf_lines(), 'Brand new question', true), nil)
  local rec = vim.json.encode({ type = 'user', uuid = 'z9', cwd = '/home/u/git/alpha', message = { role = 'user', content = 'Brand new question' } })
  vim.fn.writefile({ rec }, copy, 'a')
  drawer_cursor_to('Alpha basics')
  child.type_keys('<CR>')
  wait_for(function() return has_line(buf_lines(), 'Brand new question', true) ~= nil end, 'reloaded history')
  vim.fn.delete(tmp, 'rf')
end

T['history of a vanished transcript says so'] = function()
  local tmp = vim.fn.tempname()
  local dir = tmp .. '/-home-u-git-alpha'
  vim.fn.mkdir(dir, 'p')
  local copy = dir .. '/' .. ALPHA_ID .. '.jsonl'
  vim.fn.writefile(vim.fn.readfile(ALPHA), copy)
  start(tmp)
  child.lua('require("agent-ide").toggle()')
  drawer_cursor_to('> P alpha  ')
  child.type_keys('<CR>')
  drawer_cursor_to('Alpha basics')
  vim.fn.delete(copy)
  child.type_keys('<CR>')
  wait_for(function() return buf_lines()[1] == 'Transcript not found: ' .. copy end, 'notice')
  eq(buf_lines(), { 'Transcript not found: ' .. copy })
  vim.fn.delete(tmp, 'rf')
end

T['gp outside tmux reports a reason'] = function()
  start()
  child.lua('require("agent-ide").toggle()')
  drawer_cursor_to('> P alpha  W ')
  child.type_keys('<CR>')
  drawer_cursor_to('Alpha basics')
  child.type_keys('gp')
  wait_for(function() return #child.lua_get('_G.notes') > 0 end, 'notification')
  local notes = child.lua_get('_G.notes')
  eq(notes[#notes], 'Agent-IDE: cannot jump (not in tmux)')
end

T['gp on a session without live state says it is not running'] = function()
  start()
  child.lua('require("agent-ide").toggle()')
  drawer_cursor_to('> P notes  ')
  child.type_keys('<CR>')
  drawer_cursor_to('Meeting notes summary')
  child.type_keys('gp')
  local notes = child.lua_get('_G.notes')
  eq(notes[#notes], 'Agent-IDE: session is not running')
end

T['q closes the drawer window, tab stays'] = function()
  start()
  child.lua('require("agent-ide").toggle()')
  local s = child.lua_get('require("agent-ide.ui.drawer").state()')
  child.type_keys('q')
  eq(child.lua_get('vim.api.nvim_win_is_valid(...)', { s.win }), false)
  eq(child.lua_get('vim.api.nvim_tabpage_is_valid(...)', { s.tab }), true)
  eq(child.lua_get('vim.fn.tabpagenr("$")'), 2)
end

T['index change rescans without moving focus or the main cursor'] = function()
  start()
  child.lua([[
    local index = require('agent-ide.index')
    local orig = index.on_change
    index.on_change = function(fn) _G.index_changed = fn; orig(fn) end
    local lua_scan = require('agent-ide.index.lua_scan')
    local scan = lua_scan.scan
    _G.scans = 0
    lua_scan.scan = function(...) _G.scans = _G.scans + 1; return scan(...) end
  ]])
  open_session('alpha', 'Alpha basics')
  local before = child.lua_get('{ vim.api.nvim_get_current_win(), vim.api.nvim_win_get_cursor(0) }')
  local scans = child.lua_get('_G.scans')
  child.lua('_G.index_changed(); _G.index_changed(); _G.index_changed()')
  wait_for(function() return child.lua_get('_G.scans') > scans end, 'debounced rescan')
  vim.wait(300)
  eq(child.lua_get('_G.scans'), scans + 1)
  eq(child.lua_get('{ vim.api.nvim_get_current_win(), vim.api.nvim_win_get_cursor(0) }'), before)
end

T['foldexpr tolerates unknown buffers'] = function()
  start()
  eq(child.lua_get('require("agent-ide.ui.history").foldexpr(1)'), '0')
end

T['setup maps the toggle key; false disables it'] = function()
  start()
  eq(child.lua_get('vim.fn.maparg("<leader>aa", "n") ~= ""'), true)
  child.lua('require("agent-ide").setup({ keys = { toggle = false } })')
  eq(child.lua_get('vim.fn.maparg("<leader>aa", "n")'), '')
end


T['ages are re-rendered on every live poll'] = function()
  start()
  child.lua('require("agent-ide").toggle()')
  wait_drawer_line('^> P alpha  W ')
  -- jump the clock 500 days; the live map does not change, the age must still update
  child.lua([[
    _G.fake_now = os.time() + 500 * 86400
    os.time = function() return _G.fake_now end
  ]])
  local want = child.lua_get([[(function()
    for _, p in ipairs(require('agent-ide.ui.drawer').state().projects) do
      if p.name == 'alpha' then return require('agent-ide.ui.tree').ago(p.activity, _G.fake_now) end
    end
  end)()]])
  wait_drawer_line('> P alpha  W ' .. want, true)
end

T['missing projects dir: no warning, helper stays, hint shown'] = function()
  if not require('agent-ide.index.helper').available() then return MiniTest.skip('helper not built') end
  local missing = vim.fn.tempname() .. '/no-such-projects'
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[
    _G.notes = {}
    vim.notify = function(msg, level) table.insert(_G.notes, { msg, level }) end
    require('agent-ide').setup(...)
    require('agent-ide').toggle()
  ]], { { projects_dir = missing, live = { interval_ms = 50, cmd = { 'echo', '[]' } }, icons = ICONS } })
  wait_drawer_line('No Claude sessions found in ' .. missing, true)
  vim.wait(300)
  eq(child.lua_get('_G.notes'), {})
  eq(child.lua_get('require("agent-ide.index").backend()'), 'helper')
end

-- Record what the drawer tells the live poller and the index about visibility.
local function track_visibility()
  child.lua([[
    local index = require('agent-ide.index')
    local set_visible = index.set_visible
    _G.vis = nil
    index.set_visible = function(v) _G.vis = v; return set_visible(v) end
  ]])
end
local function shown_state() return child.lua_get('{ require("agent-ide.live").active(), _G.vis }') end

T['live polling and the change timer run only while the drawer is on screen'] = function()
  start()
  track_visibility()
  child.lua('require("agent-ide").toggle()')
  eq(shown_state(), { true, true })
  -- :q in the drawer window
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.drawer").state().win)')
  child.cmd('quit')
  eq(child.lua_get('vim.fn.tabpagenr("$")'), 2)
  eq(shown_state(), { false, false })
  child.lua('require("agent-ide").toggle()')
  eq(shown_state(), { true, true })
  -- another tab
  child.cmd('tabprevious')
  eq(shown_state(), { false, false })
  child.cmd('tabnext')
  eq(shown_state(), { true, true })
  child.cmd('tabclose')
  eq(shown_state(), { false, false })
end

T['highlight groups survive a colorscheme change; waiting is violet'] = function()
  start()
  child.cmd('colorscheme default')
  eq(child.lua_get('vim.api.nvim_get_hl(0, { name = "AgentIdeWaiting", link = false }).fg'), 0xa277ff)
  eq(child.lua_get('vim.api.nvim_get_hl(0, { name = "AgentIdeBusy" }).link'), 'AgentIdeLevel2')
end

T['a relative project key never changes the tab cwd'] = function()
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp .. '/-nocwd', 'p')
  start()
  child.cmd('cd ' .. vim.fn.fnameescape(tmp))
  child.lua('require("agent-ide").toggle()')
  local before = child.lua_get('vim.fn.getcwd(-1, 0)')
  child.lua([[require('agent-ide.ui.chat').open(require('agent-ide.session').open(
    { id = '44444444-4444-4444-8444-444444444444', cwd = '-nocwd', path = ..., title = '(untitled)' }),
    { key = '-nocwd', name = '-nocwd' })]], { FIXTURES .. '/-nocwd/44444444-4444-4444-8444-444444444444.jsonl' })
  eq(child.lua_get('vim.fn.getcwd(-1, 0)'), before)
  vim.fn.delete(tmp, 'rf')
end

return T

-- The legend of the state marks at the bottom of the drawer (ui/drawer_legend.lua): the pure
-- layout, then child Neovims for the float itself.
local eq = MiniTest.expect.equality
local legend = require('agent-ide.ui.drawer_legend')
local icons = require('agent-ide.ui.icons')
local child = MiniTest.new_child_neovim()

local ICONS = { open = 'v', closed = '>', project = 'P', waiting = 'W', busy = 'B', idle = 'I', parked = '.',
  done = 'D', failed = 'F' }

local tmp

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
  end,
  post_case = function()
    child.stop()
    vim.fn.delete(tmp, 'rf')
  end,
  post_once = function() child.stop() end,
} })

-- Layout -------------------------------------------------------------------------------------

T['layout: two lines at the default width, right-aligned, marks in their state colour'] = function()
  local l = legend.layout(icons.plain, 44)
  eq(l.lines, {
    '                  ● input  ◐ running  ● idle',
    '                  ○ parked  ✓ done  ✗ failed',
  })
  for _, line in ipairs(l.lines) do eq(vim.fn.strdisplaywidth(line), 44) end
  local groups = {}
  for _, h in ipairs(l.hl) do
    groups[#groups + 1] = h.group .. ':' .. l.lines[h.line]:sub(h.col_start + 1, h.col_end)
  end
  eq(groups, {
    'AgentIdeWaiting:●', 'AgentIdeAge:input', 'AgentIdeBusy:◐', 'AgentIdeAge:running',
    'AgentIdeIdle:●', 'AgentIdeAge:idle', 'AgentIdeParked:○', 'AgentIdeAge:parked',
    'AgentIdeDone:✓', 'AgentIdeAge:done', 'AgentIdeFailed:✗', 'AgentIdeAge:failed',
  })
end

T['layout: one space apart when two do not fit; one line when wide; nil when too narrow'] = function()
  eq(legend.layout(icons.plain, 24).lines, { '● input ◐ running ● idle', '○ parked ✓ done ✗ failed' })
  eq(legend.layout(icons.plain, 23), nil)
  eq(#legend.layout(icons.plain, 80).lines, 1)
  -- the configured marks; an empty one leaves the word in the state colour
  local l = legend.layout(vim.tbl_extend('force', icons.plain, { busy = '*', idle = '' }), 60)
  eq(l.lines, { '        ● input  * running  idle  ○ parked  ✓ done  ✗ failed' })
end

-- In the drawer -----------------------------------------------------------------------------

local function write_sessions(n)
  local projects = tmp .. '/projects'
  local dir = projects .. '/-x-many'
  vim.fn.mkdir(dir, 'p')
  for i = 1, n do
    local rec = vim.json.encode({ type = 'user', uuid = 'u' .. i, cwd = '/x/many', message = { role = 'user', content = 'Session ' .. i } })
    vim.fn.writefile({ rec }, ('%s/%08d-0000-4000-8000-000000000000.jsonl'):format(dir, i))
  end
  return projects
end

local function start(opts)
  opts = opts or {}
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[
    vim.env.TMUX = nil
    _G.notes = {}
    vim.notify = function(msg) table.insert(_G.notes, msg) end
    require('agent-ide').setup(...)
  ]], { {
    projects_dir = opts.projects or write_sessions(opts.sessions or 3),
    helper = { enabled = false },
    live = { interval_ms = 50, cmd = { 'echo', '[]' } },
    icons_style = 'plain', icons = ICONS,
    drawer = { legend = opts.legend },
  } })
  child.lua('require("agent-ide").toggle()')
end

local function wait_for(cond, what)
  if not vim.wait(3000, cond, 20) then error('timed out waiting for ' .. what, 2) end
end

-- The legend float: its lines, config and where it sits in the drawer.
local function float()
  return child.lua_get([[(function()
    local st = require('agent-ide.ui.drawer_legend')._state()
    local w = st.win
    if not w or not vim.api.nvim_win_is_valid(w) then return vim.NIL end
    local c = vim.api.nvim_win_get_config(w)
    local d = require('agent-ide.ui.drawer').state().win
    local b = vim.api.nvim_win_get_buf(w)
    local hl = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, -1, 0, -1, { details = true })) do hl[#hl + 1] = m[4].hl_group end
    return { lines = vim.api.nvim_buf_get_lines(b, 0, -1, false), relative = c.relative, win = c.win == d,
      focusable = c.focusable, row = c.row, height = c.height, width = c.width,
      drawer_h = vim.api.nvim_win_get_height(d), drawer_w = vim.api.nvim_win_get_width(d), hl = hl }
  end)()]])
end

local function floats()
  return child.lua_get([[#vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative ~= '' end,
    vim.api.nvim_list_wins())]])
end

local function drawer_win() return child.lua_get('require("agent-ide.ui.drawer").state().win') end

T['shown by default at the bottom of the drawer, with the marks of the icon set'] = function()
  start()
  wait_for(function() return float() ~= vim.NIL end, 'legend')
  local f = float()
  eq(f.lines, {
    '                  W input  B running  I idle',
    '                  . parked  D done  F failed',
  })
  eq({ f.relative, f.win, f.focusable, f.height, f.width, f.row }, { 'win', true, false, 2, f.drawer_w, f.drawer_h - 2 })
  eq(f.hl, { 'AgentIdeWaiting', 'AgentIdeAge', 'AgentIdeBusy', 'AgentIdeAge', 'AgentIdeIdle', 'AgentIdeAge',
    'AgentIdeParked', 'AgentIdeAge', 'AgentIdeDone', 'AgentIdeAge', 'AgentIdeFailed', 'AgentIdeAge' })
end

T['gL toggles it; drawer.legend = false starts hidden; listed in the help'] = function()
  start()
  wait_for(function() return float() ~= vim.NIL end, 'legend')
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.drawer").state().win)')
  child.type_keys('gL')
  eq(float(), vim.NIL)
  child.lua('require("agent-ide.ui.drawer").refresh()') -- a re-render keeps it off
  eq(float(), vim.NIL)
  child.type_keys('gL')
  eq(float() ~= vim.NIL, true)
  start({ legend = false })
  vim.wait(200)
  eq(float(), vim.NIL)
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.drawer").state().win)')
  child.type_keys('gL')
  eq(float() ~= vim.NIL, true)
  child.lua('_G.rows = {}; require("agent-ide.ui.help").open = function(_, rows) _G.rows = rows end')
  child.type_keys('?')
  local found
  for _, r in ipairs(child.lua_get('_G.rows')) do if r.key == 'gL' then found = r.desc end end
  eq(found, 'show or hide the legend of the state marks')
end

T['hidden while the drawer is too small, back when it grows'] = function()
  start()
  wait_for(function() return float() ~= vim.NIL end, 'legend')
  local d = drawer_win()
  -- shorter than 12 lines: a split below the drawer takes the rest
  child.lua('vim.api.nvim_win_call(..., function() vim.cmd("belowright new") end); vim.api.nvim_win_set_height(..., 11)', { d })
  wait_for(function() return float() == vim.NIL end, 'hidden when short')
  child.lua('vim.api.nvim_win_set_height(..., 12)', { d })
  wait_for(function() return float() ~= vim.NIL end, 'back at 12 lines')
  eq(float().row, 10)
  child.lua('vim.api.nvim_win_close(..., true)', { d })
  wait_for(function() return float() == vim.NIL end, 'gone with the drawer')
  start()
  wait_for(function() return float() ~= vim.NIL end, 'legend')
  d = drawer_win()
  child.lua('vim.api.nvim_win_set_width(..., 23)', { d })
  wait_for(function() return float() == vim.NIL end, 'hidden when narrow')
  child.lua('vim.api.nvim_win_set_width(..., 24)', { d })
  wait_for(function() return float() ~= vim.NIL end, 'back at 24 columns')
  eq(float().lines, { 'W input B running I idle', '. parked D done F failed' })
end

T['closed with the drawer, on tab leave and with the tab; back when the drawer is'] = function()
  start()
  wait_for(function() return float() ~= vim.NIL end, 'legend')
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.drawer").state().win)')
  child.type_keys('q')
  eq(float(), vim.NIL)
  eq(floats(), 0)
  child.lua('require("agent-ide").toggle()')
  wait_for(function() return float() ~= vim.NIL end, 'back with the drawer')
  child.cmd('tabnew')
  eq(floats(), 0)
  child.cmd('tabprevious')
  wait_for(function() return float() ~= vim.NIL end, 'back on tab enter')
  child.cmd('tabclose')
  eq(floats(), 0)
  -- :close in the drawer
  child.lua('require("agent-ide").toggle()')
  wait_for(function() return float() ~= vim.NIL end, 'legend in a new tab')
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.drawer").state().win)')
  child.cmd('close')
  eq(floats(), 0)
end

T['never focusable: <C-w>w and <C-w>p skip it, works with laststatus 2 and 3'] = function()
  for _, ls in ipairs({ 2, 3 }) do
    start()
    child.o.laststatus = ls
    wait_for(function() return float() ~= vim.NIL end, 'legend')
    local leg = child.lua_get('require("agent-ide.ui.drawer_legend")._state().win')
    local seen = {}
    for _ = 1, 6 do
      child.type_keys('<C-w>w')
      seen[#seen + 1] = child.lua_get('vim.api.nvim_get_current_win()')
    end
    eq(vim.tbl_contains(seen, leg), false)
    for _ = 1, 3 do
      child.type_keys('<C-w>p')
      eq(child.lua_get('vim.api.nvim_get_current_win()') ~= leg, true)
    end
    for _, k in ipairs({ '<C-w>j', '<C-w>l', '<C-w>b' }) do
      child.type_keys(k)
      eq(child.lua_get('vim.api.nvim_get_current_win()') ~= leg, true)
    end
    local f = float()
    eq(f.row, f.drawer_h - 2)
  end
end

T['the cursor row is never under the legend: moving down, jumping to the end, scrolling back'] = function()
  start({ sessions = 30 })
  wait_for(function() return float() ~= vim.NIL end, 'legend')
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.drawer").state().win)')
  -- expand the project: more rows than the drawer has lines
  child.lua([[(function()
    local s = require('agent-ide.ui.drawer').state()
    for i, l in ipairs(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)) do
      if l:find('^> many') then vim.api.nvim_win_set_cursor(s.win, { i, 0 }) end
    end
  end)()]])
  child.type_keys('<CR>')
  wait_for(function() return child.lua_get('vim.api.nvim_buf_line_count(0)') > 30 end, 'expanded')
  local function row()
    return child.lua_get('(function() local v = vim.fn.winsaveview(); return v.lnum - v.topline + 1 end)()')
  end
  local room = float().drawer_h - 2
  for _ = 1, 40 do
    child.type_keys('j')
    eq(row() <= room, true)
  end
  child.type_keys('gg')
  child.type_keys('G')
  eq(row() <= room, true)
  eq(child.lua_get('vim.fn.line(".")'), child.lua_get('vim.fn.line("$")'))
  for _ = 1, 10 do
    child.type_keys('<C-y>')
    eq(row() <= room, true)
  end
  -- a re-render (a live poll) with the cursor at the end
  child.type_keys('G')
  child.lua('require("agent-ide.ui.drawer").refresh()')
  eq(row() <= room, true)
  -- the drawer not focused: a re-render keeps the row clear as well
  child.cmd('wincmd p')
  child.lua('local w = require("agent-ide.ui.drawer").state().win; vim.api.nvim_win_set_cursor(w, { vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(w)), 0 })')
  child.lua('require("agent-ide.ui.drawer").refresh()')
  eq(child.lua_get([[vim.api.nvim_win_call(require("agent-ide.ui.drawer").state().win, function()
    local v = vim.fn.winsaveview(); return v.lnum - v.topline + 1 end)]]) <= room, true)
end

return T

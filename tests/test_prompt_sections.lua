-- The drawer's Prompts node and per-project Saved prompts: rows built in this Neovim from the
-- synthetic fixtures, then the real drawer in a child Neovim.
local eq = MiniTest.expect.equality
local tree = require('agent-ide.ui.tree')
local sections = require('agent-ide.ui.sections')
local cache = require('agent-ide.prompts.cache')
local ps = require('agent-ide.ui.prompt_sections')
local config = require('agent-ide.config')

local FIX = vim.fn.fnamemodify('tests/fixtures/prompts', ':p'):gsub('/$', '')
local ICONS = { open = 'v', closed = '>', project = 'P', waiting = 'W', busy = 'B', idle = 'I', parked = '.',
  done = 'D', failed = 'F', new = '+', prompts = '*' }
local projects = {
  { key = '/r/alpha', name = 'alpha', is_git = false, activity = 1000, sessions = { { id = 's1', title = 'Fix', activity = 1000 } } },
  { key = '/r/beta', name = 'beta', is_git = false, activity = 900, sessions = { { id = 's2', title = 'B', activity = 900 } } },
}
local function parked() return 'parked' end

local tmp
local child = MiniTest.new_child_neovim()

local function setup(prompts)
  config.setup({ prompts = prompts, icons_style = 'plain', icons = ICONS })
  cache._reset()
  sections._reset()
  ps.register()
end

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    tmp = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    tmp = vim.uv.fs_realpath(tmp)
    setup({ command_dirs = { FIX .. '/commands' }, skill_dirs = { FIX .. '/skills' }, library_dir = FIX .. '/library',
      saved_dir = tmp .. '/saved' })
  end,
  post_case = function()
    child.stop()
    vim.fn.delete(tmp, 'rf')
    cache._reset()
    sections._reset()
    config.setup()
  end,
  post_once = function() child.stop() end,
} })

-- Without a width the rows are not aligned (as the plain builds they are compared with).
local function build(expanded, width)
  return tree.build(projects, parked, expanded or {}, 1000, ICONS, nil, nil, sections.collect,
    { top = sections.collect_top, width = width })
end

local function loaded()
  if not vim.wait(5000, function() return cache.global() ~= nil end, 5) then error('scan never finished') end
end

T['every test Neovim has a temporary data folder (tests/run.lua)'] = function()
  child.restart({ '-u', 'tests/minimal_init.lua' })
  local data = child.lua_get('vim.fn.stdpath("data")')
  eq(vim.startswith(data, vim.env.XDG_DATA_HOME or '?'), true)
  eq(vim.startswith(data, vim.fn.expand('~/.local')), false)
end

T['collapsed: one Prompts row above the unchanged project lines; nothing is scanned'] = function()
  local plain = tree.build(projects, parked, {}, 1000, ICONS)
  local t = build()
  eq(t.lines[1], '> * Prompts')
  eq(vim.list_slice(t.lines, 2), plain.lines)
  -- an expanded project without saved prompts is unchanged too
  local e = { ['/r/alpha'] = true }
  plain = tree.build(projects, parked, e, 1000, ICONS)
  cache.saved(projects[1])
  vim.wait(200)
  eq(vim.list_slice(build(e).lines, 2), plain.lines)
end

T['expanded: loading, then sections; groups open and close independently; nodes carry the entry'] = function()
  local e = { prompts = true }
  eq(build(e).lines, { 'v * Prompts', '    loading…', '> alpha  . now', '> beta  . 1m' })
  loaded()
  local t = build(e)
  eq(vim.list_slice(t.lines, 1, 6), { 'v * Prompts', '  > Skills & commands (3)', '  v Library (3)',
    '      Invoice text  Short invoice text for a client', '    > writing/ (2)', '> alpha  . now' })
  eq(t.nodes[4].entry.title, 'Invoice text')
  eq(t.nodes[4].type, 'prompt')
  eq(t.nodes[5].fold.key, 'prompts/group/writing')
  e['prompts/skills'] = true
  e['prompts/group/writing'] = true
  t = build(e)
  eq(vim.list_slice(t.lines, 1, 11), { 'v * Prompts', '  v Skills & commands (3)',
    '      /dataviz-pro  Make clean charts from compact specs.',
    '      /fix-grammar  Fix grammar and spelling in the given text',
    '      /git:sync', '  v Library (3)',
    '      Invoice text  Short invoice text for a client', '    v writing/ (2)', '        LinkedIn post',
    '      > social/ (1)', '> alpha  . now' })
  e['prompts/group/writing/social'] = true
  t = build(e)
  eq(vim.list_slice(t.lines, 10, 11), { '      v social/ (1)', '          tweet' })
  -- closing the parent hides the open sub-group
  e['prompts/group/writing'] = false
  t = build(e)
  eq(vim.list_slice(t.lines, 8, 9), { '    > writing/ (2)', '> alpha  . now' })
  e['prompts/library'] = false
  eq(build(e).lines[6], '  > Library (3)')
end

T['descriptions are dimmed and cut to the drawer width'] = function()
  loaded()
  local e = { prompts = true }
  local t = build(e, 30)
  eq(t.lines[4], '      Invoice text  Short inv…')
  eq(vim.fn.strdisplaywidth(t.lines[4]), 30)
  local dim
  for _, h in ipairs(t.hl) do
    if h.line == 4 and h.group == 'AgentIdeAge' then dim = t.lines[4]:sub(h.col_start + 1, h.col_end) end
  end
  eq(dim, '  Short inv…')
  -- no room for a useful part of it: the description goes
  t = build(e, 22)
  eq(t.lines[4], '      Invoice text')
end

T['no entries at all: a one-line hint'] = function()
  setup({ command_dirs = {}, skill_dirs = {}, library_dir = tmp .. '/none', saved_dir = tmp .. '/none2' })
  local e = { prompts = true }
  build(e)
  loaded()
  eq(vim.list_slice(build(e).lines, 1, 2), { 'v * Prompts', '    no prompts yet — <leader>W in a prompt buffer saves one' })
end

T['Saved prompts: shown after Sessions only when the project has some'] = function()
  local folder = cache.folder(projects[1])
  eq(folder:match('^alpha%-%x%x%x%x%x%x%x%x$') ~= nil, true)
  eq(cache.folder({ key = '/other/alpha' }) ~= folder, true)
  vim.fn.mkdir(tmp .. '/saved/' .. folder, 'p')
  vim.fn.writefile({ 'Add idle support' }, tmp .. '/saved/' .. folder .. '/add-idle-support.md')
  local e = { ['/r/alpha'] = true, ['/r/beta'] = true }
  build(e)
  vim.wait(2000, function() return cache.saved(projects[1]) ~= nil and cache.saved(projects[2]) ~= nil end, 5)
  local t = build(e)
  eq(t.lines, { '> * Prompts', 'v alpha  . now', '    + New session', '  v Sessions (1)', '      . Fix  now',
    '  > Saved prompts (1)', 'v beta  . 1m', '    + New session', '  v Sessions (1)', '      . B  1m' })
  e['/r/alpha/saved'] = true
  t = build(e)
  eq(t.lines[7], '      add idle support')
  eq({ t.nodes[7].type, t.nodes[7].entry.kind, t.nodes[7].project.key }, { 'prompt', 'saved', '/r/alpha' })
end

T['drawer focus: nothing while collapsed; open, only changed files are read again'] = function()
  vim.fn.system({ 'cp', '-r', FIX .. '/library', tmp .. '/lib' })
  setup({ command_dirs = {}, skill_dirs = {}, library_dir = tmp .. '/lib', saved_dir = tmp .. '/saved' })
  local sources = require('agent-ide.prompts.sources')
  local orig, scans = sources.scan, 0
  sources.scan = function(...) scans = scans + 1; return orig(...) end
  local ok, err = pcall(function()
    build({ prompts = true })
    loaded()
    eq(scans, 1)
    build({}) -- Prompts collapsed again
    cache.focus()
    vim.wait(500)
    eq(scans, 1)
    build({ prompts = true })
    sources._reads = 0
    vim.uv.sleep(20)
    vim.fn.writefile({ '# Tweet now' }, tmp .. '/lib/writing/social/tweet.md')
    cache.focus()
    vim.wait(2000, function() return scans == 2 and not cache._loading() end, 10)
    eq(sources._reads, 1)
    local titles = vim.tbl_map(function(e) return e.title end, cache.global())
    eq(vim.tbl_contains(titles, 'Tweet now'), true)
  end)
  sources.scan = orig
  if not ok then error(err, 0) end
end

T['row keys: a key, a list of keys or false'] = function()
  config.setup({ keys = { prompts = { edit = { 'e', 'E' }, yank = false, rename = 'r', delete = 'd', to_library = 'L' } } })
  eq(vim.tbl_map(function(k) return k.lhs end, ps.keys()), { 'e', 'E', 'r', 'd', 'L' }) -- as configured
  config.setup({ keys = false })
  eq(ps.keys(), {})
end

T['300 library entries: re-render under 5 ms collapsed and 20 ms expanded'] = function()
  for i = 1, 300 do
    vim.fn.mkdir(tmp .. '/lib/g' .. (i % 10), 'p')
    vim.fn.writefile({ '---', 'description: synthetic prompt number ' .. i .. ' with a longer description', '---', 'x' },
      tmp .. '/lib/g' .. (i % 10) .. '/p' .. i .. '.md')
  end
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[
    local tmp = ...
    require('agent-ide').setup({ projects_dir = tmp .. '/none', helper = { enabled = false },
      live = { interval_ms = 100000, cmd = { 'true' } },
      prompts = { command_dirs = {}, skill_dirs = {}, library_dir = tmp .. '/lib', saved_dir = tmp .. '/saved' } })
    require('agent-ide').toggle()
    _G.best = function()
      collectgarbage('collect')
      local best = math.huge
      for _ = 1, 5 do
        local t0 = vim.uv.hrtime()
        require('agent-ide.ui.drawer').refresh()
        best = math.min(best, (vim.uv.hrtime() - t0) / 1e6)
      end
      return best
    end
  ]], { tmp })
  child.lua([[
    local d = require('agent-ide.ui.drawer')
    local s = d.state()
    vim.api.nvim_set_current_win(s.win)
    vim.api.nvim_win_set_cursor(s.win, { 1, 0 }) -- line 1: the Prompts node
    vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
    assert(vim.wait(5000, function() return #d.state().nodes > 5 end, 5))
    for i = 0, 9 do
      for row, node in ipairs(d.state().nodes) do
        if node.id == 'prompts#group:g' .. i then
          vim.api.nvim_win_set_cursor(s.win, { row, 0 })
          vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
          break
        end
      end
    end
  ]])
  -- Prompts, Skills & commands (0), Library, groups, entries, no sessions
  local want = 1 + 1 + 1 + 10 + 300 + 1
  vim.wait(5000, function()
    return child.lua_get('#vim.api.nvim_buf_get_lines(require("agent-ide.ui.drawer").state().buf, 0, -1, false)') == want
  end, 10)
  eq(child.lua_get('#vim.api.nvim_buf_get_lines(require("agent-ide.ui.drawer").state().buf, 0, -1, false)'), want)
  local expanded = child.lua_get('_G.best()')
  -- the entries stay loaded; the Prompts node collapsed again
  child.lua([[
    local s = require('agent-ide.ui.drawer').state()
    vim.api.nvim_win_set_cursor(s.win, { 1, 0 })
    vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  ]])
  eq(child.lua_get('#vim.api.nvim_buf_get_lines(require("agent-ide.ui.drawer").state().buf, 0, -1, false)'), 2)
  eq(#child.lua_get('require("agent-ide.prompts.cache").global()'), 300)
  local collapsed = child.lua_get('_G.best()')
  if collapsed >= 5 then error(('collapsed re-render %.2f ms, budget < 5 ms'):format(collapsed)) end
  if expanded >= 20 then error(('expanded re-render %.2f ms, budget < 20 ms'):format(expanded)) end
  MiniTest.add_note(('300 library entries: collapsed %.2f ms, expanded %.2f ms'):format(collapsed, expanded))
end

T['the drawer on the session fixtures: Prompts on top, every other line as before'] = function()
  -- a copy with fixed mtimes: the project order never depends on the checkout
  local fx = dofile(vim.fn.getcwd() .. '/tests/fixture_copy.lua')
  local fixtures = fx.make()
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[
    local fixtures, tmp = ...
    vim.env.TMUX = nil
    require('agent-ide').setup({ projects_dir = fixtures, helper = { enabled = false },
      live = { interval_ms = 100000, cmd = { 'echo', '[]' } },
      icons_style = 'plain', icons = { open = 'v', closed = '>', project = 'P', waiting = 'W', busy = 'B', idle = 'I', parked = '.' },
      prompts = { command_dirs = {}, skill_dirs = {}, library_dir = tmp .. '/lib', saved_dir = tmp .. '/saved' } })
    require('agent-ide').toggle()
  ]], { fixtures, tmp })
  local function lines() return child.lua_get('vim.api.nvim_buf_get_lines(require("agent-ide.ui.drawer").state().buf, 0, -1, false)') end
  vim.wait(3000, function() return #lines() > 3 end, 10)
  local l = lines()
  eq(l[1], '> Prompts')
  -- newest first, as the fixed mtimes say; the ages depend on today
  local rest = vim.tbl_map(function(x) return x:match('^> (%S+) %(folder missing%) +%. %S+$') or x end, vim.list_slice(l, 2))
  eq(rest, { 'alpha', 'docs', 'notes', '-nocwd' })
  for _, x in ipairs(vim.list_slice(l, 2)) do eq(vim.fn.strdisplaywidth(x), 44) end
  -- exactly what the drawer builds without any provider (below the Prompts node)
  local plain = child.lua_get([[(function()
    local d, cfg = require('agent-ide.ui.drawer'), require('agent-ide.config').get()
    local m = require('agent-ide.ui.drawer_model')
    return require('agent-ide.ui.tree').build(d.state().projects, m.state_of, {}, os.time(), cfg.icons, cfg.projects_dir,
      nil, nil, { width = 44 }).lines
  end)()]])
  eq(vim.list_slice(lines(), 2), plain)
  vim.fn.delete(fixtures, 'rf')
end

return T

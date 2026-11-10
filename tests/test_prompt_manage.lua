-- Managing prompts from the drawer: r rename, d delete, y yank, L copy a saved prompt into the
-- library; Claude's commands and skills are read-only. A child Neovim, synthetic copies.
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()

local FIX = vim.fn.fnamemodify('tests/fixtures/prompts', ':p'):gsub('/$', '')
local tmp, repo, lib

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    tmp = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    tmp = vim.uv.fs_realpath(tmp)
    repo, lib = tmp .. '/repo', tmp .. '/library'
    vim.fn.mkdir(repo, 'p')
    local dir = tmp .. '/projects/-repo'
    vim.fn.mkdir(dir, 'p')
    vim.fn.writefile({ vim.json.encode({ type = 'user', uuid = 'z1', cwd = repo, message = { role = 'user', content = 'hello' } }) },
      dir .. '/22222222-2222-4222-8222-222222222222.jsonl')
    for _, d in ipairs({ 'commands', 'library' }) do vim.fn.system({ 'cp', '-r', FIX .. '/' .. d, tmp .. '/' .. d }) end
  end,
  post_case = function()
    child.stop()
    vim.fn.delete(tmp, 'rf')
  end,
  post_once = function() child.stop() end,
} })

local function wait_for(cond, what, ms)
  if not vim.wait(ms or 5000, cond, 20) then error('timed out waiting for ' .. what, 2) end
end

local function start(keys)
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[
    local tmp, keys = ...
    vim.env.TMUX = nil
    _G.notes = {}
    vim.notify = function(msg) table.insert(_G.notes, msg) end
    _G.inputs, _G.typed, _G.confirms, _G.confirm_answer = {}, {}, {}, 2
    vim.ui.input = function(opts, cb)
      table.insert(_G.inputs, { prompt = opts.prompt, default = opts.default })
      cb(table.remove(_G.typed, 1))
    end
    vim.fn.confirm = function(msg, choices, default)
      table.insert(_G.confirms, { msg = msg, choices = choices, default = default })
      return _G.confirm_answer
    end
    vim.g.clipboard = { name = 'test', copy = { ['+'] = function(lines) _G.clip = lines end, ['*'] = function() end },
      paste = { ['+'] = function() return _G.clip or {} end, ['*'] = function() return {} end } }
    require('agent-ide').setup({ projects_dir = tmp .. '/projects', helper = { enabled = false },
      live = { interval_ms = 100000, cmd = { 'echo', '[]' } }, claude = { cmd = { 'false' } },
      icons_style = 'plain', icons = { open = 'v', closed = '>', project = 'P' },
      prompts = { command_dirs = { tmp .. '/commands' }, skill_dirs = {}, library_dir = tmp .. '/library', saved_dir = tmp .. '/saved' },
      keys = keys })
    require('agent-ide').toggle()
  ]], { tmp, keys or {} })
end

local function drawer_lines()
  return child.lua_get('vim.api.nvim_buf_get_lines(require("agent-ide.ui.drawer").state().buf, 0, -1, false)')
end

local function has_line(lines, text)
  for i, l in ipairs(lines) do
    if l:find(text, 1, true) then return i end
  end
end

local function drawer_cursor_to(text)
  wait_for(function() return has_line(drawer_lines(), text) ~= nil end, 'drawer line ' .. text)
  child.lua('local s = require("agent-ide.ui.drawer").state(); vim.api.nvim_set_current_win(s.win); vim.api.nvim_win_set_cursor(s.win, { ..., 0 })',
    { has_line(drawer_lines(), text) })
end

local function open(text)
  local l = drawer_lines()
  local i = has_line(l, text)
  if i and l[i]:find('> ' .. text, 1, true) then
    drawer_cursor_to(text)
    child.type_keys('<CR>')
  end
end

local function on_row(text, folds)
  drawer_cursor_to('Prompts')
  open('Prompts')
  for _, f in ipairs(folds or {}) do
    drawer_cursor_to(f)
    open(f)
  end
  drawer_cursor_to(text)
end

local function last_note() local n = child.lua_get('_G.notes'); return n[#n] end
local function exists(p) return vim.uv.fs_stat(p) ~= nil end

local function saved_folder()
  return tmp .. '/saved/' .. child.lua_get('require("agent-ide.prompts.cache").folder({ key = ... })', { repo })
end

T['r renames a template; group/name moves it; a taken name is refused'] = function()
  start()
  on_row('LinkedIn post', { 'writing' })
  child.lua('_G.typed = { "social media/linkedin" }')
  child.type_keys('r')
  eq(child.lua_get('_G.inputs')[1], { prompt = 'Rename to: ', default = 'writing/linkedin-post' })
  eq(exists(lib .. '/writing/linkedin-post.md'), false)
  eq(exists(lib .. '/social-media/linkedin.md'), true)
  eq(last_note(), 'Agent-IDE: renamed → Library/social-media/linkedin')
  wait_for(function() return has_line(drawer_lines(), 'social-media/ (1)') ~= nil end, 'moved in the drawer')
  -- taken
  on_row('Invoice text')
  child.lua('_G.typed = { "social-media/linkedin" }')
  child.type_keys('r')
  eq(last_note(), 'Agent-IDE: cannot rename: Library/social-media/linkedin already exists')
  eq(exists(lib .. '/invoice.md'), true)
  -- bad name, cancel
  child.lua('_G.typed = { "../up" }')
  child.type_keys('r')
  eq(last_note(), 'Agent-IDE: cannot rename: name not allowed: ".." is not allowed')
  child.lua('_G.typed = { nil }')
  child.type_keys('r')
  eq(exists(lib .. '/invoice.md'), true)
end

T['d deletes after a question naming the file (default No)'] = function()
  start()
  on_row('Invoice text')
  child.type_keys('d')
  local c = child.lua_get('_G.confirms')
  eq(c[1], { msg = 'Delete Library/invoice?', choices = '&Yes\n&No', default = 2 })
  eq(exists(lib .. '/invoice.md'), true)
  child.lua('_G.confirm_answer = 1')
  child.type_keys('d')
  eq(exists(lib .. '/invoice.md'), false)
  eq(last_note(), 'Agent-IDE: deleted Library/invoice')
  wait_for(function() return has_line(drawer_lines(), 'Invoice text') == nil end, 'gone from the drawer')
end

T['y yanks the text to the unnamed and + registers'] = function()
  start()
  on_row('Invoice text')
  child.type_keys('y')
  eq(child.lua_get('vim.fn.getreg(\'"\')'), '---\nname: Invoice text\ndescription: Short invoice text for a client\n---\nPlease write an invoice text for [client].\n')
  eq(child.lua_get('_G.clip'), { '---', 'name: Invoice text', 'description: Short invoice text for a client', '---', 'Please write an invoice text for [client].', '' })
  eq(last_note(), 'Agent-IDE: yanked Invoice text')
end

T['L copies a saved prompt into the library; r renames a saved prompt'] = function()
  start()
  local folder = saved_folder()
  vim.fn.mkdir(folder, 'p')
  vim.fn.writefile({ 'Add idle support' }, folder .. '/add-idle-support.md')
  drawer_cursor_to('> repo  ')
  child.type_keys('<CR>')
  drawer_cursor_to('Saved prompts (1)')
  child.type_keys('<CR>')
  drawer_cursor_to('add idle support')
  child.lua('_G.typed = { "ideas/idle" }')
  child.type_keys('L')
  eq(child.lua_get('_G.inputs')[1], { prompt = 'Save to library as: ', default = 'add-idle-support' })
  eq(vim.fn.readfile(lib .. '/ideas/idle.md'), { 'Add idle support' })
  eq(exists(folder .. '/add-idle-support.md'), true)
  eq(last_note(), 'Agent-IDE: saved → Library/ideas/idle')
  -- rename stays in the project's folder; no folders there
  drawer_cursor_to('add idle support')
  child.lua('_G.typed = { "x/y", "idle work" }')
  child.type_keys('r')
  eq(last_note(), 'Agent-IDE: cannot rename: name not allowed: no folders here (no /)')
  child.type_keys('r')
  eq(exists(folder .. '/idle-work.md'), true)
  -- L on a template says it is there already
  on_row('Invoice text')
  child.type_keys('L')
  eq(last_note(), 'Agent-IDE: this prompt is in the library already')
end

T["on commands and skills these keys only say the file is Claude's"] = function()
  start()
  on_row('/fix-grammar', { 'Skills & commands' })
  for _, k in ipairs({ 'r', 'd', 'y', 'L' }) do
    child.lua('_G.notes = {}')
    child.type_keys(k)
    eq(last_note(), "Agent-IDE: /fix-grammar belongs to Claude's folders; it is read-only here")
  end
  eq(exists(tmp .. '/commands/fix-grammar.md'), true)
  eq(#child.lua_get('_G.confirms'), 0)
  eq(#child.lua_get('_G.inputs'), 0)
end

T['the row keys keep their meaning elsewhere in the drawer'] = function()
  start()
  drawer_cursor_to('> repo  ')
  local row = drawer_lines()[has_line(drawer_lines(), '> repo  ')]
  eq(row:match('^> repo +○ now$') ~= nil, true)
  child.lua('vim.fn.setreg(\'"\', "before")')
  child.type_keys('yy')
  eq(child.lua_get('vim.fn.getreg(\'"\')'), row .. '\n')
  -- typed in one chunk: the motion stays after the operator; a register prefix is kept
  drawer_cursor_to('Prompts')
  child.type_keys('yj')
  eq(child.lua_get('vim.fn.getreg(\'"\')'), '> Prompts\n' .. row .. '\n')
  drawer_cursor_to('> repo  ')
  child.type_keys('"ayy')
  eq(child.lua_get('vim.fn.getreg("a")'), row .. '\n')
end

T["the drawer's own keys win a clash with a row key, also in the help"] = function()
  start({ prompts = { edit = 'R', yank = 's' } })
  on_row('Invoice text')
  child.type_keys('R')
  eq(child.lua_get('vim.api.nvim_buf_get_name(0)'), 'agent-ide://drawer')
  child.type_keys('?')
  local text = table.concat(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, -1, false)'), '\n')
  eq(text:find('prompt row: edit', 1, true), nil)
  eq(text:find('prompt row: yank', 1, true), nil)
  eq(text:find('prompt row: rename', 1, true) ~= nil, true)
end

return T

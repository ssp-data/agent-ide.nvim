-- Using a prompt: Enter on drawer rows, the picker, `e`; a child Neovim with a chat on a fresh
-- session (no Claude process is started). Prompt folders are copies of the synthetic fixtures.
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()

local FIX = vim.fn.fnamemodify('tests/fixtures/prompts', ':p'):gsub('/$', '')
local tmp, repo

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    tmp = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    tmp = vim.uv.fs_realpath(tmp)
    repo = tmp .. '/repo'
    vim.fn.mkdir(repo, 'p')
    local dir = tmp .. '/projects/-repo'
    vim.fn.mkdir(dir, 'p')
    vim.fn.writefile({ vim.json.encode({ type = 'user', uuid = 'z1', cwd = repo, message = { role = 'user', content = 'hello' } }) },
      dir .. '/22222222-2222-4222-8222-222222222222.jsonl')
    for _, d in ipairs({ 'commands', 'skills', 'library' }) do vim.fn.system({ 'cp', '-r', FIX .. '/' .. d, tmp .. '/' .. d }) end
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

---Child with the plugin set up; `chat`: open a chat on a fresh session in `repo`.
local function start(chat, extra)
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[
    local tmp, repo, chat, extra = ...
    vim.env.TMUX = nil
    _G.notes = {}
    vim.notify = function(msg) table.insert(_G.notes, msg) end
    _G.answers, _G.asked = {}, {}
    vim.ui.select = function(items, opts, cb)
      table.insert(_G.asked, { items = items, prompt = opts.prompt,
        labels = vim.tbl_map(opts.format_item or tostring, items) })
      local a = table.remove(_G.answers, 1)
      if type(a) == 'function' then a = a(items, opts) end
      cb(a and items[a] or nil, a)
    end
    local opts = vim.tbl_deep_extend('force', { projects_dir = tmp .. '/projects', helper = { enabled = false },
      live = { interval_ms = 100000, cmd = { 'echo', '[]' } }, claude = { cmd = { 'false' } },
      icons_style = 'plain', icons = { open = 'v', closed = '>', project = 'P' },
      prompts = { command_dirs = { tmp .. '/commands' }, skill_dirs = { tmp .. '/skills' },
        library_dir = tmp .. '/library', saved_dir = tmp .. '/saved' } }, extra or {})
    require('agent-ide').setup(opts)
    require('agent-ide').toggle()
    if chat then
      local s = require('agent-ide.session').open({ cwd = repo })
      require('agent-ide.ui.chat').open(s, { key = repo, name = 'repo', root = repo, is_git = false,
        missing = false, sessions = {} })
    end
  ]], { tmp, repo, chat ~= false, extra or {} })
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

-- Open the Prompts node and the given sub-folds, then put the cursor on `text`.
local function on_row(text, folds)
  drawer_cursor_to('Prompts')
  if has_line(drawer_lines(), '> Prompts') then child.type_keys('<CR>') end
  for _, f in ipairs(folds or {}) do
    drawer_cursor_to(f)
    if drawer_lines()[has_line(drawer_lines(), f)]:find('> ' .. f, 1, true) then child.type_keys('<CR>') end
  end
  drawer_cursor_to(text)
end

local function prompt_buf() return child.lua_get('vim.api.nvim_win_get_buf(require("agent-ide.ui.chat")._windows().prompt)') end
local function prompt_lines() return child.lua_get('vim.api.nvim_buf_get_lines(..., 0, -1, false)', { prompt_buf() }) end
local function set_prompt(lines) child.lua('vim.api.nvim_buf_set_lines(..., 0, -1, false, select(2, ...))', { prompt_buf(), lines }) end
local function origin() return child.lua_get('vim.b[...].agent_ide_origin', { prompt_buf() }) end
local function mode() return child.lua_get('vim.api.nvim_get_mode().mode') end
local function cur_win() return child.lua_get('vim.api.nvim_get_current_win()') end
local function notes() return child.lua_get('_G.notes') end

T['Enter on a command inserts /name as its own first line, insert mode at its end; nothing is sent'] = function()
  start()
  set_prompt({ 'my draft' })
  on_row('/fix-grammar', { 'Skills & commands' })
  child.type_keys('<CR>')
  eq(prompt_lines(), { '/fix-grammar ', 'my draft' })
  eq(cur_win(), child.lua_get('require("agent-ide.ui.chat")._windows().prompt'))
  eq(mode(), 'i')
  eq(child.lua_get('vim.api.nvim_win_get_cursor(0)'), { 1, 13 })
  eq(child.lua_get('#require("agent-ide.session").all()[1].events'), 0)
  -- an empty prompt gets it on its only line
  child.type_keys('<Esc>')
  set_prompt({ '' })
  on_row('/dataviz-pro')
  child.type_keys('<CR>')
  eq(prompt_lines(), { '/dataviz-pro ' })
end

T['Enter on a template loads it byte for byte and remembers where it came from'] = function()
  start()
  on_row('LinkedIn post', { 'writing' })
  child.type_keys('<CR>')
  eq(prompt_lines(), { '# LinkedIn post', '', 'Write a LinkedIn post about:', '\t- topic', 'with trailing spaces   ' })
  eq(origin().kind, 'template')
  eq(origin().path, tmp .. '/library/writing/linkedin-post.md')
  eq(cur_win(), child.lua_get('require("agent-ide.ui.chat")._windows().prompt'))
  eq({ mode(), child.lua_get('vim.api.nvim_win_get_cursor(0)') }, { 'n', { 1, 0 } })
  eq(child.lua_get('vim.bo.modified'), false)
  -- no final newline in the file; the frontmatter is not part of the text
  on_row('tweet', { 'social' })
  child.type_keys('<CR>')
  eq(#child.lua_get('_G.asked'), 1) -- the template above is now a draft
  child.lua('_G.answers = { 1 }')
  on_row('tweet')
  child.type_keys('<CR>')
  eq(prompt_lines(), { 'Write a tweet about [topic].' })
  child.lua('_G.answers = { 1 }')
  on_row('Invoice text')
  child.type_keys('<CR>')
  eq(prompt_lines(), { '---', 'name: Invoice text', 'description: Short invoice text for a client', '---', 'Please write an invoice text for [client].' })
  local sent = child.lua_get('require("agent-ide.ui.prompt").text_to_send(vim.api.nvim_buf_get_lines(..., 0, -1, false))', { prompt_buf() })
  eq(sent, '---\nname: Invoice text\ndescription: Short invoice text for a client\n---\nPlease write an invoice text for [client].')
end

T['a draft is never thrown away without asking: replace, insert above, cancel'] = function()
  start()
  local function pick(answer)
    set_prompt({ 'my draft', '  kept  ' })
    child.lua('vim.b[...].agent_ide_origin = nil', { prompt_buf() })
    child.lua('_G.answers = { ... }; _G.asked = {}', { answer })
    on_row('Invoice text')
    child.type_keys('<CR>')
    local a = child.lua_get('_G.asked')
    eq(#a, 1)
    eq(a[1].prompt, 'Replace the draft, insert above it, or cancel?')
    eq(a[1].items, { 'Replace the draft', 'Insert above it', 'Cancel' })
    return prompt_lines()
  end
  eq(pick(3), { 'my draft', '  kept  ' })
  eq(origin(), vim.NIL)
  eq(pick(false), { 'my draft', '  kept  ' }) -- <Esc> in the menu
  eq(pick(2), { '---', 'name: Invoice text', 'description: Short invoice text for a client', '---', 'Please write an invoice text for [client].', '', 'my draft', '  kept  ' })
  eq(origin(), vim.NIL) -- the mix is not that template: :w saves it as a new prompt
  eq(pick(1), { '---', 'name: Invoice text', 'description: Short invoice text for a client', '---', 'Please write an invoice text for [client].' })
  eq(origin().kind, 'template')
  -- a blank-only buffer is no draft
  set_prompt({ '', '   ', '' })
  child.lua('_G.asked = {}')
  on_row('Invoice text')
  child.type_keys('<CR>')
  eq(#child.lua_get('_G.asked'), 0)
end

T['no chat open: the top-level node says so; a saved prompt row opens a session for its project'] = function()
  start(false)
  on_row('Invoice text')
  child.type_keys('<CR>')
  eq(notes()[#notes()], 'Agent-IDE: open or start a session first, then pick a prompt')
  eq(child.lua_get('#require("agent-ide.session").all()'), 0)
  child.lua('_G.notes = {}')
  child.lua('require("agent-ide").prompts()')
  eq(notes(), { 'Agent-IDE: open or start a session first, then pick a prompt' })
  eq(#child.lua_get('_G.asked'), 0)
  -- a saved prompt of a project: a new session for that project, then the text
  local folder = child.lua_get('require("agent-ide.prompts.cache").folder({ key = ... })', { repo })
  vim.fn.mkdir(tmp .. '/saved/' .. folder, 'p')
  vim.fn.writefile({ 'Saved text' }, tmp .. '/saved/' .. folder .. '/saved-text.md')
  drawer_cursor_to('> repo  ')
  child.type_keys('<CR>')
  drawer_cursor_to('Saved prompts (1)')
  child.type_keys('<CR>')
  drawer_cursor_to('saved text')
  child.type_keys('<CR>')
  wait_for(function() return child.lua_get('require("agent-ide.ui.chat").current() ~= nil') end, 'chat')
  eq(child.lua_get('require("agent-ide.ui.chat").current().cwd'), repo)
  eq(prompt_lines(), { 'Saved text' })
  eq(origin().kind, 'saved')
end

T['e opens a template for editing; a command read-only with a notice'] = function()
  start()
  on_row('Invoice text')
  child.type_keys('e')
  local main = child.lua_get('require("agent-ide.ui.drawer").main_win()')
  eq(cur_win(), main)
  eq(child.lua_get('vim.api.nvim_buf_get_name(0)'), tmp .. '/library/invoice.md')
  eq(child.lua_get('{ vim.bo.buftype, vim.bo.modifiable, vim.bo.readonly }'), { '', true, false })
  on_row('/fix-grammar', { 'Skills & commands' })
  child.type_keys('e')
  eq(child.lua_get('vim.api.nvim_buf_get_name(0)'), tmp .. '/commands/fix-grammar.md')
  eq(child.lua_get('{ vim.bo.modifiable, vim.bo.readonly }'), { false, true })
  eq(notes()[#notes()], "Agent-IDE: this file belongs to Claude's folders; opened read-only")
  -- e elsewhere in the drawer is the usual motion
  drawer_cursor_to('Prompts')
  child.lua('vim.api.nvim_win_set_cursor(0, { vim.api.nvim_win_get_cursor(0)[1], 0 })')
  child.type_keys('e')
  eq(child.lua_get('vim.api.nvim_win_get_cursor(0)[2]'), 8) -- '> Prompts': end of the word
end

local function choose(field, value)
  child.lua('local f, v = ...; _G.answers = { function(items) for i, e in ipairs(items) do if e[f] == v then return i end end end }',
    { field, value })
end

T['picker: every entry, labelled; same behaviour as Enter; <leader>al in the chat'] = function()
  start()
  choose('title', 'LinkedIn post')
  child.lua('require("agent-ide").prompts()')
  wait_for(function() return #child.lua_get('_G.asked') == 1 end, 'picker')
  local a = child.lua_get('_G.asked')[1]
  eq(a.prompt, 'Prompt')
  eq(vim.tbl_contains(a.labels, 'template · writing/LinkedIn post'), true)
  eq(vim.tbl_contains(a.labels, 'template · Invoice text — Short invoice text for a client'), true)
  eq(vim.tbl_contains(a.labels, 'command · /fix-grammar — Fix grammar and spelling in the given text'), true)
  eq(vim.tbl_contains(a.labels, 'skill · /dataviz-pro — Make clean charts from compact specs.'), true)
  eq(prompt_lines()[1], '# LinkedIn post')
  -- the chat key, from the prompt buffer
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.chat")._windows().prompt)')
  set_prompt({ '' })
  choose('insert', '/fix-grammar')
  child.type_keys('\\al')
  wait_for(function() return #child.lua_get('_G.asked') == 2 end, 'picker from the chat')
  eq(prompt_lines(), { '/fix-grammar ' })
  eq(mode(), 'i')
  -- <leader>al is not an insert-mode key (it would fire while typing); a key like <M-p> is
  child.type_keys('<Esc>')
  eq(child.lua_get([[vim.fn.maparg('<leader>al', 'i')]]), '')
  eq(child.lua_get([[vim.fn.maparg('<leader>al', 'n') ~= '']]), true)
end

T['picker in insert mode with a non-printing key returns to insert mode'] = function()
  start(true, { keys = { chat = { prompts = '<M-p>' } } })
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.chat")._windows().prompt)')
  set_prompt({ 'draft' })
  choose('insert', '/fix-grammar')
  child.type_keys('A', '<M-p>')
  wait_for(function() return #child.lua_get('_G.asked') == 1 end, 'picker')
  eq(prompt_lines(), { '/fix-grammar ', 'draft' })
  eq(mode(), 'i')
  -- cancelled: back in insert mode where it was
  child.type_keys('<Esc>')
  child.lua('vim.api.nvim_win_set_cursor(0, { 2, 2 })')
  child.lua('_G.answers = { false }')
  child.type_keys('a', '<M-p>')
  wait_for(function() return #child.lua_get('_G.asked') == 2 end, 'picker again')
  eq(mode(), 'i')
  eq(child.lua_get('vim.api.nvim_win_get_cursor(0)'), { 2, 3 })
end

T['a library file deleted while listed: a notice, the list is scanned again'] = function()
  start()
  on_row('Invoice text')
  vim.fn.delete(tmp .. '/library/invoice.md')
  child.type_keys('<CR>')
  eq(notes()[#notes()], 'Agent-IDE: cannot load Invoice text: file not found')
  eq(prompt_lines(), { '' })
  wait_for(function() return has_line(drawer_lines(), 'Invoice text') == nil end, 'rescan')
end

T['help floats list the prompt keys'] = function()
  start()
  drawer_cursor_to('Prompts')
  child.type_keys('?')
  local text = table.concat(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, -1, false)'), '\n')
  for _, k in ipairs({ 'prompt row: edit', 'prompt row: rename', 'prompt row: delete', 'prompt row: yank', 'copy it into the library' }) do
    eq(text:find(k, 1, true) ~= nil, true)
  end
  child.type_keys('q')
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.chat")._windows().prompt)')
  child.type_keys('?')
  text = table.concat(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, -1, false)'), '\n')
  eq(text:find('<leader>al', 1, true) ~= nil, true)
  eq(text:find('<leader>W', 1, true) ~= nil, true)
end

return T

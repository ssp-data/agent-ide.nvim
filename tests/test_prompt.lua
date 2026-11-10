-- Prompt buffer features and the answer text object: pure functions run here, the rest in a
-- child Neovim with a chat opened on a session (no Claude process is started).
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()
local P = require('agent-ide.ui.prompt')

local tmp, repo

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    tmp = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    tmp = vim.uv.fs_realpath(tmp)
    repo = tmp .. '/repo'
    vim.fn.mkdir(repo .. '/sub', 'p')
    vim.fn.mkdir(repo .. '/node_modules/x', 'p')
    vim.fn.writefile({ 'a' }, repo .. '/a.lua')
    vim.fn.writefile({ 'b' }, repo .. '/sub/b.lua')
    vim.fn.writefile({ 'n' }, repo .. '/node_modules/x/n.js')
    -- command lists another case left in the runner's temporary state folder
    vim.fn.delete(vim.fn.stdpath('state') .. '/agent-ide/commands.json')
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

-- Child helpers -----------------------------------------------------------------------------

---Child Neovim with the plugin set up and a chat open on a fresh session in `repo`.
local function start(opts)
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[
    local repo, opts = ...
    vim.env.TMUX = nil
    _G.notes = {}
    vim.notify = function(msg) table.insert(_G.notes, msg) end
    opts = vim.tbl_deep_extend('force', { projects_dir = repo .. '/none', helper = { enabled = false },
      live = { interval_ms = 50, cmd = { 'echo', '[]' } }, claude = { cmd = { 'false' } },
      prompts = { command_dirs = {}, skill_dirs = {}, project_dirs = false } }, opts)
    require('agent-ide').setup(opts)
    require('agent-ide').toggle()
    local s = require('agent-ide.session').open({ cwd = repo })
    require('agent-ide.ui.chat').open(s, { key = repo, name = 'repo', root = repo, is_git = true,
      missing = false, mtime = 0, sessions = {} })
  ]], { repo, opts or {} })
end

local function lines_of(which)
  return child.lua_get('vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(require("agent-ide.ui.chat")._windows()[...]), 0, -1, false)', { which })
end

local function set_events(events)
  child.lua([[
    local s = require('agent-ide.session').all()[1]
    s.events = ...
    s:_emit('events')
  ]], { events })
end

local function git_init()
  vim.fn.system({ 'git', 'init', '-q', repo })
end

-- text_to_send ---------------------------------------------------------------------------------

T['attach lines convert outside fences only'] = function()
  eq(P.text_to_send({ '[attach] src/a.lua', 'look', '```', '[attach] not/this', '```', '  [attach] nor/this', '', '' }),
    '@src/a.lua\nlook\n```\n[attach] not/this\n```\n  [attach] nor/this')
end

T['tabs, CRLF remnants, quotes and unicode are untouched'] = function()
  eq(P.text_to_send({ '\ta "b" \r', 'ümlaut ✓' }), '\ta "b" \r\nümlaut ✓')
end

T['attach path is trimmed; tilde fences, longer fences and unclosed fences'] = function()
  eq(P.text_to_send({ '[attach] ab.lua \t\r' }), '@ab.lua')
  eq(P.text_to_send({ '[attach]nospace', '[attach]   ' }), '[attach]nospace\n[attach]   ')
  eq(P.text_to_send({ '~~~', '[attach] x', '~~~', '[attach] y' }), '~~~\n[attach] x\n~~~\n@y')
  -- a shorter or different fence does not close
  eq(P.text_to_send({ '````', '```', '[attach] x', '````', '[attach] y' }), '````\n```\n[attach] x\n````\n@y')
  eq(P.text_to_send({ '~~~', '```', '[attach] x', '```' }), '~~~\n```\n[attach] x\n```')
  -- an unclosed fence runs to the end
  eq(P.text_to_send({ '```lua', '[attach] x' }), '```lua\n[attach] x')
  -- fences open and close at column 0 only
  eq(P.text_to_send({ '  ```lua', '[attach] x' }), '  ```lua\n@x')
  eq(P.text_to_send({ '```', '  ```', '[attach] x', '```', '[attach] y' }), '```\n  ```\n[attach] x\n```\n@y')
  eq(P.text_to_send({ '~~~', '  ~~~', '[attach] x' }), '~~~\n  ~~~\n[attach] x')
  eq(P.text_to_send({ '[attach] a', '[attach] b' }), '@a\n@b')
end

-- Claude Code reads `@my notes.txt` as `@my`; only the quoted form attaches the file.
T['attach path with whitespace is quoted'] = function()
  eq(P.text_to_send({ '[attach] my notes.txt \t' }), '@"my notes.txt"')
  eq(P.text_to_send({ '[attach] dir/a\tb.lua' }), '@"dir/a\tb.lua"')
  eq(P.text_to_send({ '[attach] plain/path.lua' }), '@plain/path.lua')
end

-- slash completion ---------------------------------------------------------------------------

local WORDS = "vim.tbl_map(function(i) return i.word end, require('agent-ide.ui.prompt').complete(0, ...).words)"

T['completion: plugin entries first, then the session commands; fuzzy, prefix matches first'] = function()
  start()
  child.lua("require('agent-ide.session').all()[1].slash_commands = { 'context', 'help', 'compact', 'memory' }")
  child.type_keys('i', '/co')
  eq(child.lua_get("require('agent-ide.ui.prompt').complete(1, '')"), 0)
  eq(child.lua_get(WORDS, { '/' }), { '/copy', '/model', '/compact', '/context', '/help', '/memory' })
  -- prefix matches first (the plugin's before Claude's), then by the position of the first letter
  eq(child.lua_get(WORDS, { '/co' }), { '/copy', '/compact', '/context' })
  eq(child.lua_get(WORDS, { '/mo' }), { '/model', '/memory' })
  eq(child.lua_get(WORDS, { '/ct' }), { '/context', '/compact' })
  eq(child.lua_get(WORDS, { '/zq' }), {})
  local items = child.lua_get("require('agent-ide.ui.prompt').complete(0, '/')")
  eq(items.refresh, 'always') -- asked again on every typed character
  eq({ items.words[1].kind, items.words[2].kind, items.words[3].kind }, { 'plugin', 'plugin', '' })
  -- not at a command position: no completion
  child.type_keys('<Esc>', 'cc', 'say /co')
  eq(child.lua_get("require('agent-ide.ui.prompt').complete(1, '')") < 0, true)
end

T['no commands yet: the plugin entries, a one-time hint; a new session offers the folder\'s last list'] = function()
  start()
  child.type_keys('i', '/')
  eq(child.lua_get('vim.fn.pumvisible()'), 1)
  eq(child.lua_get(WORDS, { '/' }), { '/copy', '/model' })
  eq(child.lua_get(WORDS, { '/' }), { '/copy', '/model' })
  eq(child.lua_get('_G.notes'), { 'Agent-IDE: commands are known after the first answer in a session' })
  -- a session in the same folder reported its commands: offered here too
  child.type_keys('<Esc>')
  child.lua([[require('agent-ide.session.commands').record(require('agent-ide.session').all()[1].cwd, { 'compact' })]])
  child.type_keys('S', '/')
  eq(child.lua_get(WORDS, { '/' }), { '/copy', '/model', '/compact' })
end

-- The `/` menu before a session's first turn (session/commands.lua) -------------------------------

local function state_file() return child.lua_get("vim.fn.stdpath('state') .. '/agent-ide/commands.json'") end

-- Write commands.json in the child: `lists` maps a folder to { at, commands }.
local function write_lists(lists)
  child.lua([[
    local c = require('agent-ide.session.commands')
    local projects = {}
    for cwd, e in pairs(...) do projects[c.key_of(cwd)] = e end
    require('agent-ide.util.jsonfile').write(vim.fn.stdpath('state') .. '/agent-ide/commands.json', { version = 1, projects = projects })
  ]], { lists })
end

local function read_json(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local t = f:read('a')
  f:close()
  local ok, v = pcall(vim.json.decode, t)
  return ok and v or nil
end

local function menu_of(cwd)
  return child.lua_get([[vim.tbl_map(function(i) return i.word end,
    require('agent-ide.ui.prompt').matches(require('agent-ide.session').open({ cwd = ... }), '/'))]], { cwd })
end

local function wait_words(want)
  wait_for(function() return vim.deep_equal(child.lua_get(WORDS, { '/' }), want) end,
    'menu ' .. table.concat(want, ' '))
end

T['menu before the first turn: the persisted list of the project, else the newest of any project'] = function()
  local other, third = tmp .. '/other', tmp .. '/third'
  vim.fn.mkdir(other, 'p')
  vim.fn.mkdir(third, 'p')
  vim.fn.delete(vim.fn.stdpath('state') .. '/agent-ide/commands.json')
  start()
  write_lists({ [repo] = { at = 100, commands = { 'compact', 'context' } }, [other] = { at = 200, commands = { 'review' } } })
  start() -- read at setup, after a restart
  child.type_keys('i')
  wait_words({ '/copy', '/model', '/compact', '/context' })
  eq(child.lua_get('_G.notes'), {})
  -- no list for this project: the most recent one of any project
  eq(menu_of(third), { '/copy', '/model', '/review' })
  -- the session's own list replaces the fallback
  child.lua("require('agent-ide.session').all()[1].slash_commands = { 'memory' }")
  eq(child.lua_get(WORDS, { '/' }), { '/copy', '/model', '/memory' })
end

T['menu: commands and skills found on disk join, de-duplicated; plugin entries first'] = function()
  vim.fn.delete(vim.fn.stdpath('state') .. '/agent-ide/commands.json')
  local cmds, skills = tmp .. '/cmds', tmp .. '/skills'
  vim.fn.mkdir(cmds .. '/git', 'p')
  vim.fn.mkdir(skills .. '/deploy', 'p')
  vim.fn.writefile({ '# Review' }, cmds .. '/review.md')
  vim.fn.writefile({ 'commit it' }, cmds .. '/git/commit.md')
  vim.fn.writefile({ '---', 'name: deploy', 'description: ship it', '---', 'x' }, skills .. '/deploy/SKILL.md')
  start({ prompts = { command_dirs = { cmds }, skill_dirs = { skills } } })
  child.type_keys('i')
  -- no list from Claude anywhere: the plugin's entries and what was found
  wait_words({ '/copy', '/model', '/deploy', '/git:commit', '/review' })
  local items = child.lua_get("require('agent-ide.ui.prompt').complete(0, '/').words")
  eq(items[3].kind, '')
  -- Claude's list and the found ones: each name once
  child.lua("require('agent-ide.session').all()[1].slash_commands = { 'review', 'compact' }")
  eq(child.lua_get(WORDS, { '/' }), { '/copy', '/model', '/compact', '/deploy', '/git:commit', '/review' })
end

T['commands.json: written on a changed list only, 0600 in 0700, at most 50 projects, a corrupt file is ignored'] = function()
  vim.fn.delete(vim.fn.stdpath('state') .. '/agent-ide/commands.json')
  start()
  local file = state_file()
  -- through Claude's init event
  child.lua([[
    local s = require('agent-ide.session').all()[1]
    require('agent-ide.session.actions').handle(s, { type = 'init', model = 'm', mode = 'default', slash_commands = { 'compact', 'context' } })
  ]])
  wait_for(function() return vim.uv.fs_stat(file) ~= nil end, 'file written')
  local key = child.lua_get("require('agent-ide.session.commands').key_of(...)", { repo })
  eq(#key, 16)
  eq(key:find('/', 1, true), nil) -- not a path
  eq(read_json(file).projects[key].commands, { 'compact', 'context' })
  eq(vim.uv.fs_stat(file).mode % 512, 384)
  eq(vim.uv.fs_stat(vim.fs.dirname(file)).mode % 512, 448)
  local st = vim.uv.fs_stat(file)
  -- the same list again: not rewritten
  child.lua([[
    local s = require('agent-ide.session').all()[1]
    require('agent-ide.session.actions').handle(s, { type = 'init', model = 'm', mode = 'default', slash_commands = { 'compact', 'context' } })
  ]])
  child.lua('vim.wait(50)')
  local st2 = vim.uv.fs_stat(file)
  eq({ st2.ino, st2.mtime.sec, st2.mtime.nsec }, { st.ino, st.mtime.sec, st.mtime.nsec })

  -- 50 projects: a new one drops the oldest
  local lists = {}
  for i = 1, 50 do lists[tmp .. '/p' .. i] = { at = 1000 + i, commands = { 'c' .. i } } end
  write_lists(lists)
  child.lua("require('agent-ide.session.commands')._reset(); require('agent-ide.session.commands').load(function() _G.loaded = true end)")
  wait_for(function() return child.lua_get('_G.loaded == true') end, 'loaded')
  child.lua("require('agent-ide.session.commands').record(..., { 'newest' })", { tmp .. '/p51' })
  wait_for(function()
    local t = read_json(file)
    return t and t.projects[child.lua_get("require('agent-ide.session.commands').key_of(...)", { tmp .. '/p51' })] ~= nil
  end, 'newest written')
  local t = read_json(file)
  eq(vim.tbl_count(t.projects), 50)
  eq(t.projects[child.lua_get("require('agent-ide.session.commands').key_of(...)", { tmp .. '/p1' })], nil)
  eq(t.projects[child.lua_get("require('agent-ide.session.commands').key_of(...)", { tmp .. '/p2' })].commands, { 'c2' })

  -- corrupt: nothing known, no error, replaced on the next list
  local f = io.open(file, 'w')
  f:write('{"version":1,"projects":')
  f:close()
  start()
  child.type_keys('i')
  child.lua('vim.wait(100)')
  eq(child.lua_get(WORDS, { '/' }), { '/copy', '/model' })
  child.lua("require('agent-ide.session.commands').record(..., { 'compact' })", { repo })
  wait_for(function() local x = read_json(file); return x ~= nil and x.version == 1 end, 'rewritten')
end

T['menu entries for 1000 commands build within 5 ms'] = function()
  start()
  child.lua([[
    local list = {}
    for i = 1, 1000 do list[i] = ('command-%04d'):format(i) end
    require('agent-ide.session').all()[1].slash_commands = list
  ]])
  child.type_keys('i')
  local ms = child.lua_get([[(function()
    local P, s = require('agent-ide.ui.prompt'), require('agent-ide.session').all()[1]
    P.matches(s, '/') -- warm
    collectgarbage('collect')
    local best = math.huge
    for _ = 1, 5 do
      local t0 = vim.uv.hrtime()
      P.matches(s, '/')
      P.matches(s, '/cmd5')
      best = math.min(best, (vim.uv.hrtime() - t0) / 1e6 / 2)
    end
    return best
  end)()]])
  eq(ms < 5, true)
end

T['the / menu leaves the global completeopt alone, also with a local value'] = function()
  start()
  child.lua("vim.go.completeopt = 'menu,preview'")
  child.lua("require('agent-ide.session').all()[1].slash_commands = { 'compact' }")
  child.lua("_G.sets = 0; vim.api.nvim_create_autocmd('OptionSet', { pattern = 'completeopt', callback = function() if vim.v.option_type == 'global' then _G.sets = _G.sets + 1 end end })")
  child.type_keys('i', '/')
  eq(child.lua_get('vim.fn.pumvisible()'), 1)
  child.type_keys('<Esc>')
  eq(child.lua_get('vim.go.completeopt'), 'menu,preview')
  child.lua("vim.bo.completeopt = 'menuone'")
  child.type_keys('cc', '/')
  eq(child.lua_get('vim.fn.pumvisible()'), 1)
  child.type_keys('<Esc>')
  eq(child.lua_get('vim.go.completeopt'), 'menu,preview')
  eq(child.lua_get('vim.bo.completeopt'), 'menuone')
  eq(child.lua_get('_G.sets'), 0)
end

T['/copy and /model: chosen from the menu or sent alone, the plugin acts and nothing is sent'] = function()
  start()
  set_events({ { kind = 'prompt', text = 'q' }, { kind = 'text', text = 'first part' },
    { kind = 'text', text = 'second\npart' } })
  child.lua([[
    _G.selects = {}
    vim.ui.select = function(items, opts, cb) table.insert(_G.selects, { items = items, prompt = opts.prompt }) end
    local s = require('agent-ide.session').all()[1]
    _G.sent = {}
    s.send = function(_, text) table.insert(_G.sent, text); return true end
  ]])
  -- chosen from the menu
  child.type_keys('i', '/', 'cop')
  wait_for(function() return child.lua_get('vim.fn.pumvisible()') == 1 end, 'menu')
  child.type_keys('<C-n>', '<C-y>')
  wait_for(function() return child.lua_get('vim.fn.getreg(\'"\')') == 'first part\n\nsecond\npart' end, 'copied')
  eq(child.lua_get('vim.api.nvim_get_current_line()'), '')
  local notes = child.lua_get('_G.notes')
  eq(vim.startswith(notes[#notes], 'Agent-IDE: copied the last answer (4 lines)'), true)
  child.type_keys('/', 'mod')
  wait_for(function() return child.lua_get('vim.fn.pumvisible()') == 1 end, 'menu')
  child.type_keys('<C-n>', '<C-y>')
  wait_for(function() return #child.lua_get('_G.selects') == 1 end, 'model picker')
  eq(child.lua_get('_G.selects[1].prompt'), 'Model')
  -- sent alone
  child.type_keys('<Esc>')
  child.lua("vim.fn.setreg('\"', '')")
  child.lua('vim.api.nvim_buf_set_lines(0, 0, -1, false, { "/copy" })')
  child.type_keys('<C-CR>')
  wait_for(function() return child.lua_get('vim.fn.getreg(\'"\')') ~= '' end, 'copied on send')
  eq(lines_of('prompt'), { '' })
  child.lua('vim.api.nvim_buf_set_lines(0, 0, -1, false, { "/model" })')
  child.type_keys('<C-CR>')
  wait_for(function() return #child.lua_get('_G.selects') == 2 end, 'model picker on send')
  eq(child.lua_get('_G.sent'), {})
end

T['typing / opens the menu with nothing inserted; typing narrows it; completeopt is put back'] = function()
  start()
  child.lua("vim.o.completeopt = 'menu'") -- a user setting that inserts the first match at once
  child.lua("require('agent-ide.session').all()[1].slash_commands = { 'compact', 'context', 'memory' }")
  child.type_keys('i', '/')
  eq(child.lua_get('vim.fn.pumvisible()'), 1)
  eq(child.lua_get('vim.api.nvim_get_current_line()'), '/') -- nothing inserted before a choice
  eq(child.lua_get('vim.fn.complete_info({ "selected" }).selected'), -1)
  eq(vim.startswith(child.lua_get('vim.bo.completeopt'), 'menuone,noinsert,noselect'), true)
  child.type_keys('m', 'o')
  eq(child.lua_get('vim.api.nvim_get_current_line()'), '/mo')
  wait_for(function() return child.lua_get('vim.fn.pumvisible()') == 1 end, 'menu after typing')
  local shown = child.lua_get('vim.tbl_map(function(i) return i.word end, vim.fn.complete_info({ "items" }).items)')
  eq(shown[1], '/model')
  eq(vim.tbl_contains(shown, '/compact'), false)
  child.type_keys('<Esc>')
  eq(child.lua_get('vim.bo.completeopt'), '')
  eq(child.lua_get('vim.o.completeopt'), 'menu')
  -- a loaded nvim-cmp without its menu is closed before ours opens
  child.type_keys('cc')
  child.lua("_G.closed = 0; package.loaded.cmp = { visible = function() return false end, close = function() _G.closed = _G.closed + 1 end }")
  child.type_keys('/')
  eq(child.lua_get('_G.closed'), 1)
  eq(child.lua_get('vim.fn.pumvisible()'), 1)
  child.lua('package.loaded.cmp = nil')
  child.type_keys('<Esc>', 'cc', 'x/')
  eq(child.lua_get('vim.fn.pumvisible()'), 0)
  eq(child.lua_get('vim.api.nvim_get_current_line()'), 'x/')

  -- only on an otherwise empty line
  child.type_keys('<Esc>', 'cc', ' /')
  eq(child.lua_get('vim.fn.pumvisible()'), 0)
  -- not while a completion plugin shows its menu
  child.type_keys('<Esc>', 'dd', 'i')
  child.lua("package.loaded.cmp = { visible = function() return true end }")
  child.type_keys('/')
  eq(child.lua_get('vim.fn.pumvisible()'), 0)
  eq(child.lua_get('vim.api.nvim_get_current_line()'), '/')

  start({ chat = { auto_slash = false } })
  child.lua("require('agent-ide.session').all()[1].slash_commands = { 'compact' }")
  child.type_keys('i', '/')
  eq(child.lua_get('vim.fn.pumvisible()'), 0)
end

-- history ---------------------------------------------------------------------------------------

local function history_events()
  return { { kind = 'prompt', text = 'one' }, { kind = 'text', text = 'a' }, { kind = 'prompt', text = 'two\nlines' },
    { kind = 'text', text = 'b' }, { kind = 'prompt', text = 'two\nlines' }, { kind = 'prompt', text = '@f.lua x' } }
end

T['history steps back and forward, keeps the draft'] = function()
  start()
  set_events(history_events())
  child.lua("require('agent-ide.session').all()[1].queue = { 'queued' }")
  child.type_keys('i', 'draft', '<Esc>')
  child.type_keys('<C-p>')
  eq(lines_of('prompt'), { 'queued' })
  child.type_keys('<C-p>')
  eq(lines_of('prompt'), { '@f.lua x' })
  child.type_keys('<Up>')
  eq(lines_of('prompt'), { 'two', 'lines' }) -- consecutive duplicates collapsed
  child.type_keys('<C-p>') -- cursor is on the first line
  eq(lines_of('prompt'), { 'one' })
  child.type_keys('<C-p>')
  eq(lines_of('prompt'), { 'one' }) -- oldest stays
  child.type_keys('<C-n>')
  eq(lines_of('prompt'), { 'two', 'lines' })
  child.type_keys('<Down>') -- stepping forward leaves the cursor on the last line
  eq(lines_of('prompt'), { '@f.lua x' })
  child.type_keys('<Down>')
  eq(lines_of('prompt'), { 'queued' })
  child.type_keys('<C-n>')
  eq(lines_of('prompt'), { 'draft' })
  child.type_keys('<C-n>')
  eq(lines_of('prompt'), { 'draft' })
end

T['history in insert mode only when the menu is closed and at the first/last line'] = function()
  start()
  -- keyword completion looks in this buffer only (not in every buffer of the child)
  child.lua("vim.o.complete = '.'")
  set_events({ { kind = 'prompt', text = 'old' } })
  local function mode() return child.lua_get('vim.api.nvim_get_mode().mode') end
  local function pum() return child.lua_get('vim.fn.pumvisible()') end
  child.type_keys('i', 'a', '<CR>', 'b')
  wait_for(function() return mode() == 'i' and pum() == 0 end, 'insert mode, no menu')
  child.type_keys('<C-p>') -- insert-mode <C-p> on line 2: normal behaviour (completion)
  wait_for(function() return pum() == 0 end, 'keyword completion done')
  eq(lines_of('prompt'), { 'a', 'b' })
  child.type_keys('<Esc>')
  wait_for(function() return mode() == 'n' end, 'normal mode')
  child.type_keys('gg', 'A')
  wait_for(function() return mode() == 'i' and pum() == 0 end, 'insert mode on the first line, no menu')
  child.type_keys('<C-p>')
  wait_for(function() return vim.deep_equal(lines_of('prompt'), { 'old' }) end, 'history step back')
  eq(mode(), 'i')
  wait_for(function() return pum() == 0 end, 'no menu after the step')
  child.type_keys('<C-n>')
  wait_for(function() return vim.deep_equal(lines_of('prompt'), { 'a', 'b' }) end, 'history step forward')
end

T['insert-mode history keys keep their native action when no step is possible or a plugin menu is open'] = function()
  start()
  -- no history: <C-p> is native (completion), the buffer is untouched
  child.type_keys('i', 'abc', '<C-p>')
  eq(lines_of('prompt'), { 'abc' })
  child.type_keys('<Esc>', 'A')
  set_events({ { kind = 'prompt', text = 'old' } })
  -- a visible nvim-cmp menu: the key goes through
  child.lua("package.loaded.cmp = { visible = function() return true end }")
  child.type_keys('<C-p>', '<Esc>', 'A')
  eq(lines_of('prompt'), { 'abc' })
  child.lua("package.loaded.cmp = nil")
  child.lua("package.loaded['blink.cmp'] = { is_menu_visible = function() return true end }")
  child.type_keys('<C-p>', '<Esc>', 'A')
  eq(lines_of('prompt'), { 'abc' })
  child.lua("package.loaded['blink.cmp'] = nil")
  child.type_keys('<C-p>')
  eq(lines_of('prompt'), { 'old' })
  -- oldest: native again (the buffer does not change)
  child.type_keys('<C-p>')
  eq(lines_of('prompt'), { 'old' })
  -- at the newest end <C-n> steps forward to the draft, then is native
  child.type_keys('<C-n>')
  eq(lines_of('prompt'), { 'abc' })
end

T['history keys can be disabled'] = function()
  start({ keys = { chat = { history_prev = false } } })
  set_events({ { kind = 'prompt', text = 'old' } })
  child.type_keys('<C-p>', '<Up>')
  eq(lines_of('prompt'), { '' })
  eq(child.lua_get("vim.fn.maparg('<C-n>', 'n', false, true).buffer"), 1)
end

-- @ picker ----------------------------------------------------------------------------------------

local function stub_select(choice_index)
  child.lua([[
    local idx = ...
    _G.offered = nil
    vim.ui.select = function(items, _, on_choice)
      _G.offered = items
      on_choice(idx and items[idx] or nil, idx)
    end
  ]], { choice_index or vim.NIL })
end

-- vim.ui.select that picks the item `name` (nil: cancels), at once.
local function stub_pick(name)
  child.lua([[
    local name = ...
    _G.offered = nil
    vim.ui.select = function(items, _, on_choice)
      _G.offered = items
      on_choice(name ~= vim.NIL and name or nil)
    end
  ]], { name or vim.NIL })
end

-- vim.ui.select that answers later: `_G.answer(name|nil)` chooses on a later tick. With
-- `normal`, it leaves insert mode first, as a picker in its own window does.
local function stub_async(normal)
  child.lua([[
    local normal = ...
    _G.offered, _G.answer = nil, nil
    vim.ui.select = function(items, _, on_choice)
      _G.offered = items
      if normal then vim.cmd('stopinsert') end
      _G.answer = function(name) vim.schedule(function() on_choice(name) end) end
    end
  ]], { normal or false })
end

local function cursor() return child.lua_get('vim.api.nvim_win_get_cursor(0)') end
local function mode() return child.lua_get('vim.api.nvim_get_mode().mode') end
local function sent() return child.lua_get('require("agent-ide.ui.prompt").text_to_send(vim.api.nvim_buf_get_lines(0, 0, -1, false))') end
local function pick_marks()
  return child.lua_get([[#vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_get_namespaces()['agent-ide.prompt.pick'], 0, -1, {})]])
end

-- Prompt text `lines`, then insert mode with the cursor before byte `col` (0-based) of `row`.
local function edit_at(lines, row, col)
  child.type_keys('<Esc>')
  child.lua([[
    local lines, row, col = ...
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(0, { row, col })
  ]], { lines, row, col })
  -- normal mode cannot stand past the last byte: append there instead
  child.type_keys((col > 0 and col >= #lines[row]) and 'A' or 'i')
end

local function article()
  local l = {}
  for i = 1, 30 do l[i] = ('Line %d of a long article, with a few words.'):format(i) end
  l[17] = 'Here we look at the parser and its tests.'
  l[10], l[20] = '', ''
  return l
end

T['@ mid-sentence inserts the reference inline at that byte, cursor after it in insert mode'] = function()
  start()
  stub_pick('a.lua')
  local text = article()
  local col = #'Here we look at '
  edit_at(text, 17, col)
  child.type_keys('@')
  local want = vim.deepcopy(text)
  want[17] = 'Here we look at @a.lua the parser and its tests.'
  wait_for(function() return vim.deep_equal(lines_of('prompt'), want) end, 'inline reference')
  eq(cursor(), { 17, col + #'@a.lua ' })
  eq(mode(), 'i')
  eq(pick_marks(), 0)
  child.type_keys('x')
  want[17] = 'Here we look at @a.lua xthe parser and its tests.'
  eq(lines_of('prompt'), want)
  -- sent in place, every other line byte for byte
  eq(sent(), table.concat(want, '\n'))
end

T['@ at the end of a line, at column 0 of text, after multi-byte text'] = function()
  start()
  stub_pick('sub/b.lua')
  edit_at({ 'look ' }, 1, 5)
  child.type_keys('@')
  wait_for(function() return lines_of('prompt')[1] == 'look @sub/b.lua ' end, 'reference at the end')
  eq(cursor(), { 1, #'look @sub/b.lua ' })
  child.type_keys('rest')
  eq(lines_of('prompt'), { 'look @sub/b.lua rest' })

  -- column 0 of a line with text: inline; a space already after the spot is not doubled
  edit_at({ 'first', 'tail' }, 2, 0)
  child.type_keys('@')
  wait_for(function() return lines_of('prompt')[2] == '@sub/b.lua tail' end, 'reference at column 0')
  eq(cursor(), { 2, #'@sub/b.lua ' })
  edit_at({ 'a  b' }, 1, 2)
  child.type_keys('@')
  wait_for(function() return lines_of('prompt')[1] == 'a @sub/b.lua b' end, 'no double space')
  eq(cursor(), { 1, #'a @sub/b.lua ' })

  -- umlauts and an emoji before the cursor: byte columns
  local before = 'Grüße 🎉 und ä '
  edit_at({ before .. 'Ende' }, 1, #before)
  child.type_keys('@')
  wait_for(function() return lines_of('prompt')[1] == before .. '@sub/b.lua Ende' end, 'after multi-byte text')
  eq(cursor(), { 1, #before + #'@sub/b.lua ' })
  child.type_keys('ö')
  eq(lines_of('prompt'), { before .. '@sub/b.lua öEnde' })
end

T['@ on an empty line between paragraphs adds an [attach] line there'] = function()
  start()
  stub_pick('a.lua')
  edit_at({ 'para one', '', 'para two' }, 2, 0)
  child.type_keys('@')
  wait_for(function() return #lines_of('prompt') == 4 end, 'attach line')
  eq(lines_of('prompt'), { 'para one', '[attach] a.lua', '', 'para two' })
  eq(cursor(), { 3, 0 })
  eq(mode(), 'i')
  eq(sent(), 'para one\n@a.lua\n\npara two')
end

T['three attachments keep their places and order when sent'] = function()
  vim.fn.writefile({ '' }, repo .. '/my notes.md')
  start()
  local text = article()
  edit_at(text, 10, 0) -- the empty line 10
  stub_pick('sub/b.lua')
  child.type_keys('@')
  wait_for(function() return #lines_of('prompt') == 31 end, 'first')
  child.type_keys('<Esc>')
  -- line 17 is now 18
  edit_at(lines_of('prompt'), 18, #'Here we look at ')
  stub_pick('my notes.md')
  child.type_keys('@')
  wait_for(function() return lines_of('prompt')[18]:find('notes') ~= nil end, 'second')
  child.type_keys('<Esc>')
  local l3 = lines_of('prompt')[3]
  edit_at(lines_of('prompt'), 3, #l3)
  stub_pick('a.lua')
  child.type_keys(' ', '@')
  wait_for(function() return lines_of('prompt')[3]:find('a.lua') ~= nil end, 'third')
  local want = vim.deepcopy(text)
  table.insert(want, 10, '[attach] sub/b.lua')
  want[18] = 'Here we look at @"my notes.md" the parser and its tests.'
  want[3] = text[3] .. ' @a.lua '
  eq(lines_of('prompt'), want)
  local out = vim.deepcopy(want)
  out[10] = '@sub/b.lua'
  eq(sent(), table.concat(out, '\n'))
end

T['a late picker answer lands at the original spot after the cursor moved and text was typed'] = function()
  start()
  stub_async(false)
  edit_at({ 'one', 'see the file', 'three' }, 2, 4)
  child.type_keys('@')
  wait_for(function() return child.lua_get('_G.answer ~= nil') end, 'picker open')
  -- meanwhile: typing at the spot, on another line, and a new line above
  child.type_keys('new ', '<Esc>', 'gg', 'A', ' more', '<Esc>', 'O', 'top')
  eq(lines_of('prompt'), { 'top', 'one more', 'see new the file', 'three' })
  child.lua('_G.answer("a.lua")')
  wait_for(function() return lines_of('prompt')[3] == 'see @a.lua new the file' end, 'reference at the spot')
  eq(lines_of('prompt'), { 'top', 'one more', 'see @a.lua new the file', 'three' })
  -- the user is typing elsewhere: cursor and mode stay
  eq(cursor(), { 1, 3 })
  eq(mode(), 'i')
  eq(pick_marks(), 0)

  -- same on an empty line: the [attach] line goes above it, the typed text stays below
  edit_at({ 'one', '' }, 2, 0)
  child.type_keys('@')
  wait_for(function() return child.lua_get('_G.answer ~= nil') end, 'picker open')
  child.type_keys('typed', '<Esc>', 'gg', 'A', '!')
  child.lua('_G.answer("a.lua")')
  wait_for(function() return #lines_of('prompt') == 3 end, 'attach line')
  eq(lines_of('prompt'), { 'one!', '[attach] a.lua', 'typed' })
  eq(cursor(), { 1, 4 })
end

T['a picker that leaves insert mode: the reference lands and insert mode resumes after it'] = function()
  start()
  stub_async(true)
  edit_at({ 'see the file' }, 1, 4)
  child.type_keys('@')
  wait_for(function() return child.lua_get('_G.answer ~= nil') and mode() == 'n' end, 'picker in normal mode')
  child.lua('_G.answer("a.lua")')
  wait_for(function() return lines_of('prompt')[1] == 'see @a.lua the file' and mode() == 'i' end, 'insert again')
  eq(cursor(), { 1, #'see @a.lua ' })
  child.type_keys('x')
  eq(lines_of('prompt'), { 'see @a.lua xthe file' })

  -- at the end of the line
  child.type_keys('<Esc>')
  edit_at({ 'look ' }, 1, 5)
  child.type_keys('@')
  wait_for(function() return child.lua_get('_G.answer ~= nil') and mode() == 'n' end, 'picker in normal mode')
  child.lua('_G.answer("a.lua")')
  wait_for(function() return lines_of('prompt')[1] == 'look @a.lua ' and mode() == 'i' end, 'insert at the end')
  child.type_keys('x')
  eq(lines_of('prompt'), { 'look @a.lua x' })

  -- cancelled: a literal @ at the spot, insert mode right after it
  child.type_keys('<Esc>')
  edit_at({ 'see the file' }, 1, 4)
  child.type_keys('@')
  wait_for(function() return child.lua_get('_G.answer ~= nil') and mode() == 'n' end, 'picker in normal mode')
  child.lua('_G.answer(nil)')
  wait_for(function() return lines_of('prompt')[1] == 'see @the file' and mode() == 'i' end, 'literal @')
  eq(cursor(), { 1, 5 })
  eq(pick_marks(), 0)
  child.type_keys('x')
  eq(lines_of('prompt'), { 'see @xthe file' })
end

T['cancel mid-line leaves the text as typed with a literal @; paths with spaces, unicode and %'] = function()
  vim.fn.mkdir(repo .. '/dir ü', 'p')
  vim.fn.writefile({ '' }, repo .. '/dir ü/naïve 🎉.md')
  vim.fn.writefile({ '' }, repo .. '/100%.txt')
  vim.fn.writefile({ '' }, repo .. '/größe.md')
  start()
  stub_pick(nil)
  edit_at({ 'see the file' }, 1, 4)
  child.type_keys('@')
  wait_for(function() return lines_of('prompt')[1] == 'see @the file' end, 'literal @')
  eq(cursor(), { 1, 5 })
  eq(mode(), 'i')
  eq(pick_marks(), 0)

  local function inline(name)
    stub_pick(name)
    child.type_keys('<Esc>')
    edit_at({ 'a ' }, 1, 2)
    child.type_keys('@')
    wait_for(function() return lines_of('prompt')[1] ~= 'a ' end, 'reference ' .. name)
    return lines_of('prompt')[1]
  end
  eq(inline('dir ü/naïve 🎉.md'), 'a @"dir ü/naïve 🎉.md" ')
  eq(inline('100%.txt'), 'a @100%.txt ')
  eq(inline('größe.md'), 'a @größe.md ')
  -- as [attach] lines, sent the same way
  eq(P.text_to_send({ '[attach] dir ü/naïve 🎉.md', '[attach] 100%.txt', '[attach] größe.md' }),
    '@"dir ü/naïve 🎉.md"\n@100%.txt\n@größe.md')
end

T['text_to_send converts [attach] lines in place: nothing moved, blank lines kept'] = function()
  local lines = { 'intro', '', '[attach] a.lua', 'middle @b.lua text', '', '', '```', '[attach] in/fence', '```',
    'end', '[attach] my file.md', '', '' }
  eq(P.text_to_send(lines), 'intro\n\n@a.lua\nmiddle @b.lua text\n\n\n```\n[attach] in/fence\n```\nend\n@"my file.md"')
end

T['@ after whitespace in a git work tree offers the tracked and untracked files'] = function()
  git_init()
  start()
  stub_select(1)
  child.type_keys('i', 'look ', '@')
  wait_for(function() return lines_of('prompt')[1] == 'look @a.lua ' end, 'reference')
  eq(child.lua_get('_G.offered'), { 'a.lua', 'node_modules/x/n.js', 'sub/b.lua' })
end

T['@ in the middle of a word inserts normally; cancel inserts a literal @'] = function()
  start()
  stub_select(nil)
  child.type_keys('i', 'me', '@', 'x')
  eq(lines_of('prompt'), { 'me@x' })
  eq(child.lua_get('_G.offered'), vim.NIL)
  child.type_keys('<Esc>', 'cc', '@')
  wait_for(function() return lines_of('prompt')[1] == '@' end, 'literal @')
  eq(child.lua_get('vim.api.nvim_win_get_cursor(0)'), { 1, 1 })
  child.type_keys('y')
  eq(lines_of('prompt'), { '@y' })
end

T['chat.at_picker = false: @ is plain'] = function()
  start({ chat = { at_picker = false } })
  stub_select(1)
  child.type_keys('i', '@')
  eq(lines_of('prompt'), { '@' })
  eq(child.lua_get('_G.offered'), vim.NIL)
end

T['a second @ while the list loads is a plain @; a picker for a prompt that is no longer current is dropped'] = function()
  start()
  stub_select(1)
  child.type_keys('i', '@', '@')
  wait_for(function() return #lines_of('prompt') == 2 end, 'attach line')
  eq(lines_of('prompt'), { '[attach] a.lua', '@' })
  -- leave the prompt before the list arrives: nothing is offered, a literal @ is inserted
  stub_select(1)
  child.type_keys('<Esc>', 'ccx ')
  child.lua([[
    local prompt = require('agent-ide.ui.prompt')
    local orig = prompt.list_files
    prompt.list_files = function(cwd, cb)
      orig(cwd, function(...)
        local args = { ... }
        vim.api.nvim_set_current_win(require('agent-ide.ui.chat')._windows().transcript)
        cb(unpack(args))
      end)
    end
  ]])
  child.type_keys('@')
  wait_for(function() return lines_of('prompt')[2] == 'x @' end, 'literal @')
  eq(child.lua_get('_G.offered'), vim.NIL)
end

T['the file list is capped (also from git) and says so; a missing session cwd uses the tab cwd'] = function()
  git_init()
  for i = 1, 12 do vim.fn.writefile({ '' }, repo .. '/g' .. i .. '.txt') end
  start()
  child.lua([[
    require('agent-ide.ui.prompt').MAX_WALK = 5
    _G.prompts = {}
    vim.ui.select = function(items, o, on_choice) _G.offered, _G.prompts[1] = items, o.prompt; on_choice(nil) end
  ]])
  child.type_keys('i', '@')
  wait_for(function() return child.lua_get('_G.offered') ~= vim.NIL end, 'picker')
  eq(#child.lua_get('_G.offered'), 5)
  eq(child.lua_get('_G.prompts[1]'), 'Attach file (first 5 files)')
  wait_for(function() return lines_of('prompt')[1] == '@' end, 'literal @ after cancel')

  child.lua([[
    require('agent-ide.session').all()[1].cwd = nil
    vim.cmd('tcd ' .. vim.fn.fnameescape(...))
    _G.offered = nil
  ]], { repo })
  child.type_keys('<Esc>', 'cc', '@')
  wait_for(function() return child.lua_get('_G.offered') ~= vim.NIL end, 'picker from the tab cwd')
end

T['a picker that never answers is given up after the timeout or when the prompt is left'] = function()
  start()
  child.lua([[
    _G.calls = 0
    local prompt = require('agent-ide.ui.prompt')
    prompt.PICK_TIMEOUT_MS = 100
    prompt.list_files = function() _G.calls = _G.calls + 1 end
  ]])
  child.type_keys('i', '@')
  eq(child.lua_get('_G.calls'), 1)
  child.type_keys('@') -- loading: plain @
  eq(lines_of('prompt'), { '@' })
  eq(child.lua_get('_G.calls'), 1)
  vim.wait(300)
  child.type_keys(' ', '@') -- the timeout reset it
  wait_for(function() return child.lua_get('_G.calls') == 2 end, 'second picker')
  -- leaving the prompt resets as well
  vim.wait(300)
  child.lua('require("agent-ide.ui.prompt").PICK_TIMEOUT_MS = 60000')
  child.type_keys('<Esc>', 'o', ' ', '@')
  eq(child.lua_get('_G.calls'), 3)
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.chat")._windows().transcript)')
  child.lua('vim.api.nvim_set_current_win(require("agent-ide.ui.chat")._windows().prompt)')
  child.type_keys('A', ' ', '@')
  eq(child.lua_get('_G.calls'), 4)
end

T['truncated only when more files exist than the cap'] = function()
  start()
  local function run(max)
    return child.lua_get([[(function(dir, max)
      local out
      local prompt = require('agent-ide.ui.prompt')
      prompt.MAX_WALK = max
      prompt.list_files(dir, function(files, truncated) out = { #files, truncated } end)
      vim.wait(5000, function() return out ~= nil end, 20)
      return out
    end)(...)]], { tmp .. '/plain', max })
  end
  vim.fn.mkdir(tmp .. '/plain/d', 'p')
  for _, f in ipairs({ 'a', 'b', 'd/c' }) do vim.fn.writefile({ '' }, tmp .. '/plain/' .. f) end
  eq(run(3), { 3, false })
  eq(run(2), { 2, true })
  eq(run(10), { 3, false })
end

T['<leader>af attaches from normal mode; cancel changes nothing'] = function()
  start()
  stub_select(2)
  child.type_keys('i', 'text', '<Esc>', '\\af')
  wait_for(function() return #lines_of('prompt') == 2 end, 'attach line')
  eq(lines_of('prompt'), { '[attach] sub/b.lua', 'text' })
  eq(child.lua_get('vim.api.nvim_win_get_cursor(0)'), { 2, 3 })
  stub_select(nil)
  child.type_keys('\\af')
  wait_for(function() return child.lua_get('_G.offered') ~= vim.NIL end, 'picker')
  vim.wait(100)
  eq(lines_of('prompt'), { '[attach] sub/b.lua', 'text' })
end

T['file list: git ls-files in a work tree (untracked included), a bounded walk elsewhere'] = function()
  git_init()
  vim.fn.writefile({ 'i' }, repo .. '/.gitignore')
  vim.fn.writefile({ 'x' }, repo .. '/ignored.txt')
  vim.fn.writefile({ 'ignored.txt' }, repo .. '/.gitignore')
  start()
  local got = child.lua_get([[(function(repo)
    local out
    require('agent-ide.ui.prompt').list_files(repo, function(files) out = files end)
    vim.wait(5000, function() return out ~= nil end, 20)
    return out
  end)(...)]], { repo })
  eq(got, { '.gitignore', 'a.lua', 'node_modules/x/n.js', 'sub/b.lua' })

  local plain = tmp .. '/plain'
  vim.fn.mkdir(plain .. '/.git', 'p')
  vim.fn.mkdir(plain .. '/d/e', 'p')
  vim.fn.mkdir(plain .. '/node_modules', 'p')
  vim.fn.writefile({ '' }, plain .. '/.git/config')
  vim.fn.writefile({ '' }, plain .. '/node_modules/m.js')
  vim.fn.writefile({ '' }, plain .. '/top.txt')
  vim.fn.writefile({ '' }, plain .. '/d/e/deep.txt')
  got = child.lua_get([[(function(dir)
    local out
    require('agent-ide.ui.prompt').list_files(dir, function(files) out = files end)
    vim.wait(5000, function() return out ~= nil end, 20)
    return out
  end)(...)]], { plain })
  eq(got, { 'd/e/deep.txt', 'top.txt' })
  -- bounded
  for i = 1, 30 do vim.fn.writefile({ '' }, plain .. '/f' .. i .. '.txt') end
  got = child.lua_get([[(function(dir)
    local out
    require('agent-ide.ui.prompt').MAX_WALK = 10
    require('agent-ide.ui.prompt').list_files(dir, function(files) out = files end)
    vim.wait(5000, function() return out ~= nil end, 20)
    return #out
  end)(...)]], { plain })
  eq(got, 10)
end

-- text object ----------------------------------------------------------------------------------------

local function answer_events()
  return {
    { kind = 'prompt', text = 'q1' },
    { kind = 'text', text = 'first answer\n\nsecond para' },
    { kind = 'tool_call', id = 't1', name = 'Bash', input = { command = 'ls' } },
    { kind = 'tool_result', id = 't1', text = 'file', is_error = false },
    { kind = 'text', text = 'after tool' },
    { kind = 'prompt', text = 'q2\n## Claude\nnot an answer' },
    { kind = 'text', text = 'answer two' },
  }
end

local function reg() return child.lua_get('vim.fn.getreg(\'"\', 1, true)') end

local function to_transcript(row)
  child.lua([[
    local win = require('agent-ide.ui.chat')._windows().transcript
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { ..., 0 })
  ]], { row })
end

T['yir yanks exactly the last answer; y2ir the first; yar adds header and one blank'] = function()
  start()
  set_events(answer_events())
  local lines = lines_of('transcript')
  eq(lines, { '', '## You', '', 'q1', '', '## Claude', '', 'first answer', '', 'second para', '', '▸ Bash: ls',
    '│ $ ls', '│ file', 'after tool', '', '', '## You', '', 'q2', '## Claude', 'not an answer', '',
    '## Claude', '', 'answer two', '' })
  -- cursor in the last answer: count ignored, that answer
  to_transcript(26)
  child.type_keys('yir')
  eq(reg(), { 'answer two' })
  to_transcript(26)
  child.type_keys('y5ir')
  eq(reg(), { 'answer two' })
  to_transcript(26)
  child.type_keys('yar')
  eq(reg(), { '## Claude', '', 'answer two', '' })
  -- cursor outside any answer: count goes back from the last
  to_transcript(1)
  child.type_keys('yir')
  eq(reg(), { 'answer two' })
  to_transcript(1)
  child.type_keys('y2ir')
  eq(reg(), { 'first answer', '', 'second para', '', '▸ Bash: ls', '│ $ ls', '│ file', 'after tool' })
  to_transcript(1)
  child.type_keys('y2ar')
  eq(reg(), { '## Claude', '', 'first answer', '', 'second para', '', '▸ Bash: ls', '│ $ ls', '│ file',
    'after tool', '' })
  -- no such answer: nothing yanked, notice
  child.lua("vim.fn.setreg('\"', 'keep')")
  to_transcript(1)
  child.type_keys('y3ir')
  eq(reg(), { 'keep' })
  eq(child.lua_get('_G.notes[#_G.notes]'), 'Agent-IDE: no Claude answer here')
  eq(child.lua_get('vim.api.nvim_get_mode().mode'), 'n')
end

T['the answer holds a closed fold: the whole fold is yanked, cursor in the fold counts as inside'] = function()
  start()
  set_events(answer_events())
  to_transcript(12)
  eq(child.lua_get('vim.fn.foldclosed(12)'), 12)
  child.type_keys('yir')
  eq(reg(), { 'first answer', '', 'second para', '', '▸ Bash: ls', '│ $ ls', '│ file', 'after tool' })
end

T['visual ir/ar select the answer linewise; d is not possible in the transcript (read-only)'] = function()
  start()
  set_events(answer_events())
  to_transcript(10)
  child.type_keys('vir', 'y')
  eq(reg(), { 'first answer', '', 'second para', '', '▸ Bash: ls', '│ $ ls', '│ file', 'after tool' })
  eq(child.lua_get('vim.fn.getregtype(\'"\')'), 'V')
  child.type_keys('var', 'y')
  eq(reg()[1], '## Claude')
end

T['answer keys can be disabled or remapped; an answer without text has no inner part'] = function()
  start({ keys = { chat = { answer_inner = 'iq', answer_outer = false } } })
  set_events({ { kind = 'prompt', text = 'q' }, { kind = 'text', text = 'only' } })
  eq(lines_of('transcript'), { '', '## You', '', 'q', '', '## Claude', '', 'only', '' })
  to_transcript(8)
  child.type_keys('yiq')
  eq(reg(), { 'only' })
  eq(child.lua_get("vim.fn.maparg('ar', 'o', false, true).buffer"), vim.NIL)
end

T['text object boundaries: turn 0 content, an answer ending in a fold, streaming after events, extra lines'] = function()
  start()
  set_events({ { kind = 'text', text = 'orphan' }, { kind = 'prompt', text = 'q' }, { kind = 'text', text = 'ans' } })
  eq(lines_of('transcript'), { 'orphan', '', '', '## You', '', 'q', '', '## Claude', '', 'ans', '' })
  to_transcript(1)
  child.type_keys('yir')
  eq(reg(), { 'ans' })
  to_transcript(1)
  child.lua("vim.fn.setreg('\"', 'keep')")
  child.type_keys('y2ir')
  eq(reg(), { 'keep' }) -- turn 0 is not an answer

  -- an answer that ends in a tool fold: no trailing blank, ar stops at the fold
  start()
  set_events({ { kind = 'prompt', text = 'q' }, { kind = 'text', text = 'ans' },
    { kind = 'tool_call', id = 't', name = 'Bash', input = { command = 'ls' } },
    { kind = 'tool_result', id = 't', text = 'out', is_error = false },
    { kind = 'prompt', text = 'q2' }, { kind = 'text', text = 'last' } })
  to_transcript(1)
  child.type_keys('y2ir')
  eq(reg(), { 'ans', '', '▸ Bash: ls', '│ $ ls', '│ out' })
  to_transcript(1)
  child.type_keys('y2ar')
  eq(reg(), { '## Claude', '', 'ans', '', '▸ Bash: ls', '│ $ ls', '│ out' })

  -- streaming text below events of the same turn is part of the answer
  start()
  set_events({ { kind = 'prompt', text = 'q' }, { kind = 'text', text = 'done part' } })
  child.lua([[
    local s = require('agent-ide.session').all()[1]
    s.streaming = 'more'
    s:_emit('delta')
  ]])
  eq(lines_of('transcript'), { '', '## You', '', 'q', '', '## Claude', '', 'done part', '', 'more' })
  to_transcript(1)
  child.type_keys('yir')
  eq(reg(), { 'done part', '', 'more' })

  -- lines the view shows after the events (e.g. a permission block) are not part of the answer
  start()
  set_events({ { kind = 'prompt', text = 'q' }, { kind = 'text', text = 'ans' } })
  child.lua([[
    local buf = require('agent-ide.ui.chat')._windows().transcript
    buf = vim.api.nvim_win_get_buf(buf)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { '⏸ permission?', 'Allow  Deny' })
    vim.bo[buf].modifiable = false
  ]])
  to_transcript(1)
  child.type_keys('yir')
  eq(reg(), { 'ans' })
  to_transcript(1)
  child.type_keys('yar')
  eq(reg(), { '## Claude', '', 'ans', '' })
end

T['a streaming answer after a tool call, a thinking event or the prompt ends on its last streamed line'] = function()
  local cases = {
    { 'tool', { { kind = 'prompt', text = 'q' }, { kind = 'tool_call', id = 't', name = 'Bash', input = { command = 'ls' } },
      { kind = 'tool_result', id = 't', text = 'out', is_error = false } } },
    { 'thinking', { { kind = 'prompt', text = 'q' }, { kind = 'thinking', text = 'hmm' } } },
    { 'prompt only', { { kind = 'prompt', text = 'q' } } },
  }
  for _, case in ipairs(cases) do
    start()
    set_events(case[2])
    child.lua([[
      local s = require('agent-ide.session').all()[1]
      s.streaming = 'live one\nlive two'
      s:_emit('delta')
    ]])
    local lines = lines_of('transcript')
    eq({ case[1], lines[#lines] }, { case[1], 'live two' })
    to_transcript(1)
    child.type_keys('yir')
    local got = reg()
    eq({ case[1], got[#got - 1], got[#got] }, { case[1], 'live one', 'live two' })
    to_transcript(1)
    child.type_keys('yar')
    got = reg()
    eq({ case[1], got[1], got[#got] }, { case[1], '## Claude', 'live two' })
  end
end

T['a streaming answer is selectable before its text event exists'] = function()
  start()
  set_events({ { kind = 'prompt', text = 'q' } })
  child.lua([[
    local s = require('agent-ide.session').all()[1]
    s.streaming = 'partial'
    s:_emit('delta')
  ]])
  eq(lines_of('transcript'), { '', '## You', '', 'q', '', '## Claude', '', 'partial' })
  to_transcript(1)
  child.type_keys('yir')
  eq(reg(), { 'partial' })
end

return T

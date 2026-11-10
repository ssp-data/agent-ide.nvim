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
      live = { interval_ms = 50, cmd = { 'echo', '[]' } }, claude = { cmd = { 'false' } } }, opts)
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
  eq(P.text_to_send({ '[attach] a b.lua \t\r' }), '@a b.lua')
  eq(P.text_to_send({ '[attach]nospace', '[attach]   ' }), '[attach]nospace\n[attach]   ')
  eq(P.text_to_send({ '~~~', '[attach] x', '~~~', '[attach] y' }), '~~~\n[attach] x\n~~~\n@y')
  -- a shorter or different fence does not close
  eq(P.text_to_send({ '````', '```', '[attach] x', '````', '[attach] y' }), '````\n```\n[attach] x\n````\n@y')
  eq(P.text_to_send({ '~~~', '```', '[attach] x', '```' }), '~~~\n```\n[attach] x\n```')
  -- an unclosed fence runs to the end
  eq(P.text_to_send({ '  ```lua', '[attach] x' }), '  ```lua\n[attach] x')
  eq(P.text_to_send({ '[attach] a', '[attach] b' }), '@a\n@b')
end

-- slash completion ---------------------------------------------------------------------------

T['completion lists the session commands with a prefix, sorted'] = function()
  start()
  child.lua("require('agent-ide.session').all()[1].slash_commands = { 'context', 'help', 'compact' }")
  child.type_keys('i', '/co')
  eq(child.lua_get("require('agent-ide.ui.prompt').complete(1, '')"), 0)
  eq(child.lua_get("require('agent-ide.ui.prompt').complete(0, '/co')"), { '/compact', '/context' })
  eq(child.lua_get("require('agent-ide.ui.prompt').complete(0, '/')"), { '/compact', '/context', '/help' })
  eq(child.lua_get("require('agent-ide.ui.prompt').complete(0, '/x')"), {})
  -- not at a command position: no completion
  child.type_keys('<Esc>', 'cc', 'say /co')
  eq(child.lua_get("require('agent-ide.ui.prompt').complete(1, '')") < 0, true)
end

T['no commands yet: no matches and a one-time hint'] = function()
  start()
  child.type_keys('i', '/')
  eq(child.lua_get('vim.fn.pumvisible()'), 0)
  eq(child.lua_get("require('agent-ide.ui.prompt').complete(0, '/')"), {})
  eq(child.lua_get("require('agent-ide.ui.prompt').complete(0, '/')"), {})
  eq(child.lua_get('_G.notes'), { 'Agent-IDE: commands are known after the first answer in a session' })
end

T['typing / at the line start opens the completion menu; auto_slash = false turns it off'] = function()
  start()
  child.lua("require('agent-ide.session').all()[1].slash_commands = { 'compact', 'context' }")
  child.type_keys('i', '/')
  eq(child.lua_get('vim.fn.pumvisible()'), 1)
  eq(child.lua_get('vim.api.nvim_get_current_line()'), '/')
  child.type_keys('<Esc>', 'cc', 'x/')
  eq(child.lua_get('vim.fn.pumvisible()'), 0)
  eq(child.lua_get('vim.api.nvim_get_current_line()'), 'x/')

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
  set_events({ { kind = 'prompt', text = 'old' } })
  child.type_keys('i', 'a', '<CR>', 'b')
  child.type_keys('<C-p>') -- insert-mode <C-p> on line 2: normal behaviour (completion)
  eq(lines_of('prompt')[1], 'a')
  child.type_keys('<Esc>', 'gg', 'A')
  child.type_keys('<C-p>')
  eq(lines_of('prompt'), { 'old' })
  eq(child.lua_get('vim.api.nvim_get_mode().mode'), 'i')
  child.type_keys('<C-n>')
  eq(lines_of('prompt'), { 'a', 'b' })
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

T['@ after whitespace inserts an [attach] line above and leaves the cursor in place'] = function()
  git_init()
  start()
  stub_select(1)
  child.type_keys('i', 'look ', '@')
  wait_for(function() return lines_of('prompt')[1] == '[attach] a.lua' end, 'attach line')
  eq(lines_of('prompt'), { '[attach] a.lua', 'look ' })
  eq(child.lua_get('vim.api.nvim_win_get_cursor(0)'), { 2, 5 })
  eq(child.lua_get('_G.offered'), { 'a.lua', 'node_modules/x/n.js', 'sub/b.lua' })
  child.type_keys('rest')
  eq(lines_of('prompt'), { '[attach] a.lua', 'look rest' })
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

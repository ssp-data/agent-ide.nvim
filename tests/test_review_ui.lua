-- Review comments end to end: a child Neovim on a temporary repository, the full diff open,
-- comments typed in the editor, shown as virtual lines, kept across reloads, sent on.
local R = dofile(vim.fn.getcwd() .. '/tests/git_repo.lua')
local fake = dofile(vim.fn.getcwd() .. '/tests/fake.lua')
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()

local ICONS = { open = 'v', closed = '>', project = 'P', waiting = 'W', busy = 'B', idle = 'I', parked = '.',
  done = 'D', failed = 'F', new = '+' }
local ID = '44444444-4444-4444-8444-444444444444'

local tmp, repo, projects

-- main: a.txt; feat: "feat one" (a.txt + rename), "feat two" (img.png); then an uncommitted edit
-- of a.txt and untracked new.txt (the fixture of test_fulldiff_ui).
local function make_repo()
  repo = R.init(tmp .. '/r')
  R.write(repo, 'a.txt', { 'a' })
  R.write(repo, 'sp ace "q".txt', { '1', '2', '3', '4' })
  R.commit(repo, 'init')
  R.git(repo, { 'checkout', '-q', '-b', 'feat' })
  R.write(repo, 'a.txt', { 'a', 'aa' })
  vim.fn.mkdir(repo .. '/dir', 'p')
  R.git(repo, { 'mv', 'sp ace "q".txt', 'dir/sp ace "q".txt' })
  R.write(repo, 'dir/sp ace "q".txt', { '1', '2', '3', '5' })
  R.commit(repo, 'feat one')
  R.write(repo, 'img.png', '\137PNG\0\0')
  R.commit(repo, 'feat two')
  R.write(repo, 'a.txt', { 'a', 'aa', 'aaa' })
  R.write(repo, 'new.txt', { 'n1', 'n2' })
end

local function write_session()
  local dir = projects .. '/-r'
  vim.fn.mkdir(dir, 'p')
  vim.fn.writefile({ vim.json.encode({ type = 'user', uuid = 'z1', cwd = repo, message = { role = 'user', content = 'Work on it' } }) },
    dir .. '/' .. ID .. '.jsonl')
end

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    tmp = R.tmp()
    projects = tmp .. '/projects'
    make_repo()
    write_session()
    vim.fn.delete(vim.fn.stdpath('state') .. '/agent-ide/reviews', 'rf')
  end,
  post_case = function()
    child.stop()
    vim.fn.delete(tmp, 'rf')
  end,
  post_once = function() child.stop() end,
} })

-- `vim.ui.select` answers with `_G.pick` (an index, default 1) and records every question in
-- `_G.asks`; `vim.fn.confirm` answers `_G.confirm` (default 1).
local log -- the fake Claude's log (start with `fake` steps)

local function start(opts)
  opts = opts or {}
  local cmd
  if opts.fake then
    cmd, log = fake.cmd(opts.fake)
    opts.fake = nil
    opts.claude = { cmd = cmd }
  end
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[
    local env, opts, log = ...
    for k, v in pairs(env) do vim.uv.os_setenv(k, v) end
    if log then vim.uv.os_setenv('FAKE_CLAUDE_LOG', log) end
    vim.env.TMUX = nil
    vim.o.columns, vim.o.lines = 200, 50
    _G.notes, _G.asks, _G.pick, _G.confirm = {}, {}, 1, 1
    vim.notify = function(msg) table.insert(_G.notes, msg) end
    vim.ui.select = function(items, o, cb)
      local labels = {}
      for i, it in ipairs(items) do labels[i] = o.format_item and o.format_item(it) or tostring(it) end
      table.insert(_G.asks, { prompt = o.prompt, items = labels })
      local i = _G.pick
      vim.schedule(function() cb(i and items[i] or nil, i) end)
    end
    vim.fn.confirm = function() return _G.confirm end
    require('agent-ide').setup(opts)
  ]], { R.ENV, vim.tbl_deep_extend('force', {
    projects_dir = projects,
    helper = { enabled = false },
    live = { interval_ms = 50, cmd = { 'echo', '[]' } },
    icons_style = 'plain', icons = ICONS, git = { delta = false },
    chat = { ask_picker = 'select' },
  }, opts), log })
end

local function wait_for(cond, what, ms)
  if not vim.wait(ms or 5000, cond, 20) then error('timed out waiting for ' .. what, 2) end
end

local function has_line(lines, text)
  for i, l in ipairs(lines) do
    if l:find(text, 1, true) then return i end
  end
end

-- The view as seen: nil when closed.
local function view()
  return child.lua_get([[(function()
    local v = require('agent-ide.ui.fulldiff').state()
    if not v or not vim.api.nvim_buf_is_valid(v.buf) then return vim.NIL end
    local w = vim.fn.win_findbuf(v.buf)[1]
    local out = { root = v.root, kind = v.scope.kind, loading = v.loading, lines = vim.api.nvim_buf_get_lines(v.buf, 0, -1, false),
      shown = w ~= nil, focused = w ~= nil and vim.api.nvim_get_current_win() == w }
    if w then
      out.cursor = vim.api.nvim_win_get_cursor(w)[1]
      out.winbar = vim.wo[w].winbar
    end
    return out
  end)()]])
end

local function view_line(text)
  local v = view()
  return v ~= vim.NIL and has_line(v.lines, text) or nil
end

local function cursor_on(text)
  wait_for(function() return view_line(text) ~= nil end, 'full diff line ' .. text)
  child.lua([[local v = require('agent-ide.ui.fulldiff').state()
    local w = vim.fn.win_findbuf(v.buf)[1]
    vim.api.nvim_set_current_win(w)
    vim.api.nvim_win_set_cursor(w, { ..., 0 })]], { view_line(text) })
end

local function open(scope, extra)
  child.lua('if not require("agent-ide.ui.drawer").state().tab then require("agent-ide").toggle() end')
  child.lua('require("agent-ide.ui.fulldiff").open(vim.tbl_extend("force", { root = ..., scope = select(2, ...) }, select(3, ...) or {}))',
    { repo, scope, extra or {} })
  wait_for(function() local v = view(); return v ~= vim.NIL and v.kind == scope.kind and v.loading == false end, 'full diff')
end

-- The virtual lines of the review namespace, by buffer line: a list of their texts (chunks joined).
local function virt_lines()
  return child.lua_get([[(function()
    local v = require('agent-ide.ui.fulldiff').state()
    local ns = vim.api.nvim_create_namespace('agent-ide.review')
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(v.buf, ns, 0, -1, { details = true })) do
      local texts = {}
      for _, vl in ipairs(m[4].virt_lines or {}) do
        local s = ''
        for _, chunk in ipairs(vl) do s = s .. chunk[1] end
        texts[#texts + 1] = s
      end
      out[tostring(m[2] + 1)] = texts
    end
    return out
  end)()]])
end

local function virt_at(text)
  local list = virt_lines()[tostring(view_line(text))]
  return list and table.concat(list, '\n') or nil
end

local function editor_open()
  return child.lua_get('require("agent-ide.ui.review_edit").state() ~= nil')
end

local function review_file()
  local path = child.lua_get('require("agent-ide.review").file(...)', { repo })
  if vim.fn.filereadable(path) == 0 then return nil end
  return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
end

local function count() return child.lua_get('require("agent-ide.review").count(...)', { repo }) end

-- Type a comment on the line `text` of the open view: `c`, the text, <Esc>, <CR>.
local function comment_on(text, typed)
  cursor_on(text)
  child.type_keys('c')
  wait_for(editor_open, 'the comment editor')
  child.type_keys(typed, '<Esc>', '<CR>')
  wait_for(function() return not editor_open() end, 'the editor to close')
end

-- Comments in the full diff -----------------------------------------------------------------------

T['c on a + line, text, <CR>: a virtual line under it, the file written, the winbar counts'] = function()
  start()
  open({ kind = 'head' })
  comment_on('+aaa', 'BUG: swallows it')
  wait_for(function() return virt_at('+aaa') ~= nil end, 'the virtual line')
  eq(virt_at('+aaa'), '  ┃ BUG  swallows it')
  eq(view().winbar:find('· 1 comment', 1, true) ~= nil, true)
  local data = review_file()
  local c = data.comments[1]
  eq({ c.kind, c.text, c.path, c.side, c.line, c.code, c.scope.kind, #c.scope.hash }, { 'BUG', 'swallows it', 'a.txt', 'new', 3, 'aaa', 'head', 7 })
  eq(view().focused, true) -- the cursor is back in the diff
end

T['c on a - line anchors the old side; on a header the file; on a commented line it edits'] = function()
  R.write(repo, 'a.txt', { 'a', 'aaa' })
  start()
  open({ kind = 'head' })
  comment_on('-aa', 'ISSUE: why drop it')
  wait_for(function() return virt_at('-aa') ~= nil end, 'the virtual line')
  local c = review_file().comments[1]
  eq({ c.side, c.line, c.code }, { 'old', 2, 'aa' })
  comment_on('v M a.txt', 'DESIGN: the whole file')
  wait_for(function() return virt_at('v M a.txt') ~= nil end, 'the file-level line')
  c = review_file().comments[2]
  eq({ c.side, c.line, c.code, c.path }, { nil, nil, nil, 'a.txt' })
  eq(virt_at('v M a.txt'), '  ┃ DESIGN  the whole file')
  -- editing: the editor opens with `ISSUE: why drop it`; the text is replaced, not added
  cursor_on('-aa')
  child.type_keys('c')
  wait_for(editor_open, 'the editor')
  eq(child.lua_get('vim.api.nvim_buf_get_lines(require("agent-ide.ui.review_edit").state().buf, 0, -1, false)'), { 'ISSUE: why drop it' })
  child.type_keys('<Esc>', 'A', ' now', '<Esc>', '<CR>')
  wait_for(function() return virt_at('-aa') == '  ┃ ISSUE  why drop it now' end, 'the edited line')
  eq(count(), 2)
  eq(view().winbar:find('· 2 comments', 1, true) ~= nil, true)
end

T['a reload keeps the comment; when its line is gone it sits under the header with a note'] = function()
  start()
  open({ kind = 'head' })
  comment_on('+n2', 'NOTE: second line')
  wait_for(function() return virt_at('+n2') ~= nil end, 'the virtual line')
  R.write(repo, 'zz.txt', { 'z' })
  child.lua('require("agent-ide.git_cache").invalidate(...)', { repo })
  wait_for(function() return view_line('v ? zz.txt') ~= nil end, 'reload')
  eq(virt_at('+n2'), '  ┃ NOTE  second line')
  R.write(repo, 'new.txt', { 'n1' })
  child.lua('require("agent-ide.git_cache").invalidate(...)', { repo })
  wait_for(function() return view_line('+n2') == nil end, 'the line to go')
  wait_for(function() return virt_at('v ? new.txt') ~= nil end, 'the note under the header')
  eq(virt_at('v ? new.txt'), '  ┃ NOTE  (line 2 not in this diff)  second line')
  eq(count(), 1)
end

T['dd removes the comment into the unnamed register; ]r / [r step commented lines'] = function()
  start()
  open({ kind = 'head' })
  comment_on('+aaa', 'one')
  comment_on('+n2', 'BUG: two')
  wait_for(function() return virt_at('+n2') ~= nil end, 'both placed')
  cursor_on('v M a.txt')
  child.type_keys(']r')
  eq(view().lines[view().cursor], '+aaa')
  child.type_keys(']r')
  eq(view().lines[view().cursor], '+n2')
  child.type_keys(']r')
  eq(view().lines[view().cursor], '+n2') -- the last one: stays
  child.type_keys('[r')
  eq(view().lines[view().cursor], '+aaa')
  child.type_keys('dd')
  wait_for(function() return virt_at('+aaa') == nil end, 'the comment to go')
  eq(child.fn.getreg('"'), 'one')
  eq(count(), 1)
  eq(view().winbar:find('· 1 comment', 1, true) ~= nil, true)
  cursor_on('v M a.txt')
  child.type_keys('dd') -- nothing there: nothing happens
  eq(count(), 1)
  eq(view().lines[view().cursor]:sub(1, 9), 'v M a.txt')
end

T['q in the editor with changed text asks; an empty save writes nothing; the kinds are in the winbar'] = function()
  start()
  open({ kind = 'head' })
  cursor_on('+aaa')
  child.type_keys('c')
  wait_for(editor_open, 'the editor')
  local wb = child.lua_get('vim.wo[require("agent-ide.ui.review_edit").state().win].winbar')
  eq(wb:find('NOTE · ISSUE · BUG · DESIGN · SUGGESTION · QUESTION', 1, true) ~= nil, true)
  child.type_keys('typed', '<Esc>')
  child.lua('_G.confirm = 2') -- keep editing
  child.type_keys('q')
  eq(editor_open(), true)
  child.lua('_G.confirm = 1') -- discard
  child.type_keys('q')
  wait_for(function() return not editor_open() end, 'closed')
  eq(review_file(), nil)
  child.type_keys('c')
  wait_for(editor_open, 'the editor again')
  child.type_keys('<Esc>', '<CR>') -- empty: nothing saved
  wait_for(function() return not editor_open() end, 'closed again')
  eq(review_file(), nil)
  eq(view().focused, true)
end

T['a comment on an uncommitted line shows in the branch scope too'] = function()
  start()
  open({ kind = 'head' })
  comment_on('+aaa', 'SUGGESTION: both scopes')
  wait_for(function() return virt_at('+aaa') ~= nil end, 'placed')
  child.type_keys('q')
  open({ kind = 'branch' })
  wait_for(function() return virt_at('+aaa') ~= nil end, 'placed in the branch scope')
  eq(virt_at('+aaa'), '  ┃ SUGGESTION  both scopes')
  eq(view().winbar:find('· 1 comment', 1, true) ~= nil, true)
end

-- Which session, the done step --------------------------------------------------------------------

local function asks() return child.lua_get('_G.asks') end
local function session_of_review() return child.lua_get('require("agent-ide.review").session(...)', { repo }) end

-- The prompt buffer of the fixture session (created without a window) and its lines.
local function prompt_lines()
  return child.lua_get([[(function(id, repo)
    local s = require('agent-ide.session').open({ id = id, cwd = repo })
    local _, pbuf = require('agent-ide.ui.chat').buffers(s)
    return pbuf and vim.api.nvim_buf_get_lines(pbuf, 0, -1, false) or vim.NIL
  end)(...)]], { ID, repo })
end

local function set_draft(lines)
  child.lua([[local id, repo, lines = ...
    local s = require('agent-ide.session').open({ id = id, cwd = repo })
    local _, pbuf = require('agent-ide.ui.chat').ensure(s, { key = repo, root = repo, name = 'r', is_git = true, sessions = {} })
    vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, lines)]], { ID, repo, lines })
end

local function wait_drawer_sessions()
  wait_for(function()
    for _, p in ipairs(child.lua_get('require("agent-ide.ui.drawer").state().projects or {}')) do
      if #(p.sessions or {}) > 0 then return true end
    end
    return false
  end, 'the drawer to list the session')
end

T['the first save asks for the session: the project\'s most recent is the default; the answer sticks'] = function()
  start()
  open({ kind = 'head' })
  wait_drawer_sessions()
  comment_on('+aaa', 'BUG: one')
  wait_for(function() return virt_at('+aaa') ~= nil end, 'placed')
  local a = asks()
  eq(#a, 1)
  eq(a[1].prompt, 'Review of r: send the comments to which session?')
  eq(a[1].items[1]:sub(1, 10), 'Work on it')
  eq({ a[1].items[2], a[1].items[3] }, { '+ new session', 'another session…' })
  eq(session_of_review(), ID)
  comment_on('+n2', 'two')
  wait_for(function() return virt_at('+n2') ~= nil end, 'placed')
  eq(#asks(), 1)
end

T['+ new session creates one without opening it; the full diff stays; another session… lists them'] = function()
  start()
  open({ kind = 'head' })
  wait_drawer_sessions()
  child.lua('_G.pick = 2')
  comment_on('+aaa', 'one')
  wait_for(function() return virt_at('+aaa') ~= nil end, 'placed')
  local id = session_of_review()
  eq(id ~= nil and id ~= ID, true)
  eq(child.lua_get('require("agent-ide.session").get(...).cwd', { id }), repo)
  eq(view().shown, true)
  eq(view().focused, true)
  -- the second choice path: another session… then the list of the project's sessions
  child.lua('require("agent-ide.review").set_session(..., nil)', { repo })
  child.lua('_G.pick = 3')
  cursor_on('+n2')
  child.type_keys('c')
  wait_for(editor_open, 'the editor')
  child.lua('_G.asks = {}')
  child.type_keys('two', '<Esc>')
  child.lua('_G.pick = 1') -- the list's first entry
  -- the first ask (which session) answers 3 through the stub's pick at call time: set it per ask
  child.lua([[local n = 0
    local orig = vim.ui.select
    vim.ui.select = function(items, o, cb)
      n = n + 1
      _G.pick = n == 1 and 3 or 1
      return orig(items, o, cb)
    end]])
  child.type_keys('<CR>')
  wait_for(function() return virt_at('+n2') ~= nil end, 'placed')
  local a = asks()
  eq(#a, 2)
  eq(a[2].prompt, 'Review of r: which session?')
  eq(a[2].items[1]:sub(1, 10), 'Work on it')
  eq(session_of_review(), ID)
end

T['gs: the text lands above the draft, the prompt opens below the diff, the review is cleared'] = function()
  start()
  open({ kind = 'head' })
  wait_drawer_sessions()
  comment_on('+aaa', 'BUG: swallows it')
  wait_for(function() return virt_at('+aaa') ~= nil end, 'placed')
  set_draft({ 'my draft' })
  child.type_keys('gs')
  wait_for(function() return #asks() == 2 end, 'the done dialog')
  local a = asks()[2]
  eq(a.prompt, 'Review of r: 1 comment, to "Work on it"')
  eq(a.items, { 'Insert above the draft', 'Replace the draft', 'Copy to clipboard', 'Another session…', 'Cancel' })
  wait_for(function() return count() == 0 end, 'the review cleared')
  local lines = prompt_lines()
  eq(lines[1], 'I reviewed your changes and have the following comments. Please address them.')
  eq(has_line(lines, '## uncommitted changes (working tree against HEAD ') ~= nil, true)
  eq(has_line(lines, '1. **[BUG]** `a.txt:3` — `aaa`') ~= nil, true)
  eq(lines[#lines - 1], '')
  eq(lines[#lines], 'my draft')
  eq(view() ~= vim.NIL and view().shown, true)
  eq(child.lua_get('vim.b[vim.api.nvim_get_current_buf()].agent_ide_kind'), 'prompt')
  eq(virt_at('+aaa'), nil)
  eq(view().winbar:find('comment', 1, true), nil)
  eq(child.lua_get('_G.notes[#_G.notes]'), 'Agent-IDE: review of r: 1 comment in the prompt of "Work on it"')
end

T['gs with an empty prompt offers one put choice; Copy to clipboard fills the register and clears'] = function()
  start()
  open({ kind = 'head' })
  wait_drawer_sessions()
  comment_on('+aaa', 'one')
  wait_for(function() return virt_at('+aaa') ~= nil end, 'placed')
  child.lua('_G.pick = 2')
  child.type_keys('gs')
  wait_for(function() return #asks() == 2 end, 'the done dialog')
  eq(asks()[2].items, { 'Put in the prompt', 'Copy to clipboard', 'Another session…', 'Cancel' })
  wait_for(function() return count() == 0 end, 'cleared')
  eq(child.fn.getreg('"'):sub(1, 10), 'I reviewed')
  eq(view().focused, true)
end

T['gs then Cancel: the prompt and the comments stay; nothing pending notifies'] = function()
  start()
  open({ kind = 'head' })
  wait_drawer_sessions()
  comment_on('+aaa', 'one')
  wait_for(function() return virt_at('+aaa') ~= nil end, 'placed')
  set_draft({ 'my draft' })
  child.lua('_G.pick = 5')
  child.type_keys('gs')
  wait_for(function() return #asks() == 2 end, 'the done dialog')
  vim.wait(100)
  eq(count(), 1)
  eq(prompt_lines(), { 'my draft' })
  eq(view().focused, true)
  child.lua('require("agent-ide.review").clear(..., { 1 })', { repo })
  child.type_keys('gs')
  wait_for(function() return child.lua_get('_G.notes[#_G.notes]') == 'Agent-IDE: no review comments for r' end, 'the notice')
  eq(#asks(), 2)
end

T['a stored session that is gone is dropped and asked again'] = function()
  start()
  open({ kind = 'head' })
  wait_drawer_sessions()
  child.lua('require("agent-ide.review").set_session(..., "dead-id")', { repo })
  comment_on('+aaa', 'one')
  wait_for(function() return virt_at('+aaa') ~= nil end, 'placed')
  eq(asks()[1].prompt, 'Review of r: send the comments to which session?')
  eq(session_of_review(), ID)
  child.lua('require("agent-ide.review").set_session(..., "dead-id")', { repo })
  child.type_keys('gs')
  wait_for(function() return #asks() == 3 end, 'both dialogs')
  eq(asks()[2].prompt, 'Review of r: send the comments to which session?')
  eq(asks()[3].prompt:sub(1, 13), 'Review of r: ')
end

T['the drawer shows review (n) · gs in Commits while comments are pending; <CR> on it is the done step'] = function()
  start()
  open({ kind = 'head' })
  wait_drawer_sessions()
  comment_on('+aaa', 'one')
  wait_for(function() return virt_at('+aaa') ~= nil end, 'placed')
  local function drawer_lines()
    return child.lua_get('vim.api.nvim_buf_get_lines(require("agent-ide.ui.drawer").state().buf, 0, -1, false)')
  end
  local function press(text)
    wait_for(function() return has_line(drawer_lines(), text) ~= nil end, 'drawer row ' .. text)
    child.lua([[local d = require('agent-ide.ui.drawer').state()
      vim.api.nvim_set_current_win(d.win)
      vim.api.nvim_win_set_cursor(d.win, { ..., 0 })]], { has_line(drawer_lines(), text) })
    child.type_keys('<CR>')
  end
  press('> r ')
  press('Commits')
  wait_for(function() return has_line(drawer_lines(), 'review (1) · gs') ~= nil end, 'the review row')
  local l = drawer_lines()
  eq(has_line(l, 'review (1) · gs') + 1, has_line(l, 'full diff · gd'))
  press('review (1) · gs')
  wait_for(function() return #asks() == 2 end, 'the done dialog')
  eq(asks()[2].prompt, 'Review of r: 1 comment, to "Work on it"')
  wait_for(function() return count() == 0 end, 'cleared')
  wait_for(function() return has_line(drawer_lines(), 'review (') == nil end, 'the row gone')
end

T[':AgentsReview from the chat of the repository runs the done step'] = function()
  start()
  open({ kind = 'head' })
  wait_drawer_sessions()
  comment_on('+aaa', 'one')
  wait_for(function() return virt_at('+aaa') ~= nil end, 'placed')
  child.type_keys('q')
  child.lua([[local id, repo = ...
    local s = require('agent-ide.session').open({ id = id, cwd = repo })
    require('agent-ide.ui.chat').open(s, { key = repo, root = repo, name = 'r', is_git = true, sessions = {} })]], { ID, repo })
  child.cmd('AgentsReview')
  wait_for(function() return #asks() == 2 end, 'the done dialog')
  eq(asks()[2].prompt, 'Review of r: 1 comment, to "Work on it"')
  wait_for(function() return count() == 0 end, 'cleared')
  eq(prompt_lines()[1], 'I reviewed your changes and have the following comments. Please address them.')
end

-- The direct send ---------------------------------------------------------------------------------

local function init_step()
  return { emit = { type = 'system', subtype = 'init', session_id = 'x', model = 'claude-haiku-5-5-20261001',
    permissionMode = 'default', slash_commands = {}, claude_code_version = '2.1.306' } }
end
local function result_step(t)
  return { emit = { type = 'result', subtype = 'success', is_error = false, result = t } }
end

-- The prompts the fake received (the `initialize` request left out).
local function fake_prompts()
  local out = {}
  for _, l in ipairs(fake.log(log)) do
    if l['in'] and not fake.is_init(l['in']) then out[#out + 1] = vim.json.decode(l['in']).message.content end
  end
  return out
end

local function session_state()
  return child.lua_get('(function(id) local s = require("agent-ide.session").get(id); return s and { state = s.state, queue = s.queue } or vim.NIL end)(...)', { ID })
end

T['<C-CR> in the editor sends that one comment: the fake sees the review text; the comment leaves the review'] = function()
  start({ fake = { { expect = 'I reviewed your changes' }, init_step(), result_step('ok') } })
  open({ kind = 'head' })
  wait_drawer_sessions()
  cursor_on('+aaa')
  child.type_keys('c')
  wait_for(editor_open, 'the editor')
  child.type_keys('BUG: swallows it', '<C-CR>')
  wait_for(function() return #fake_prompts() == 1 end, 'the fake to receive the prompt', 10000)
  local text = fake_prompts()[1]
  eq(text:sub(1, 76), 'I reviewed your changes and have the following comments. Please address them')
  eq(text:find('Comment kinds: BUG (wrong behaviour)', 1, true) ~= nil, true)
  eq(text:find('## uncommitted changes (working tree against HEAD ', 1, true) ~= nil, true)
  eq(text:find('1. **[BUG]** `a.txt:3` — `aaa`\n   swallows it', 1, true) ~= nil, true)
  wait_for(function() return count() == 0 end, 'the comment gone')
  eq(virt_at('+aaa'), nil)
  eq(view() ~= vim.NIL and view().shown, true)
  eq(editor_open(), false)
  eq(child.lua_get('_G.notes[#_G.notes]'), 'Agent-IDE: sent to "Work on it": [BUG] `a.txt:3`')
  eq(prompt_lines(), { '' }) -- the prompt buffer was not used
  wait_for(function() local st = session_state().state; return st == 'idle' or st == 'done' end, 'the turn to end')
end

T['<C-CR> while a turn runs queues the comment; it leaves the review once queued'] = function()
  start({ fake = { { expect = 'first' }, init_step(), { emit = { type = 'system', subtype = 'status', status = 'requesting' } },
    { sleep_ms = 2500 }, result_step('ok') } })
  open({ kind = 'head' })
  wait_drawer_sessions()
  cursor_on('+aaa')
  child.type_keys('c')
  wait_for(editor_open, 'the editor')
  child.type_keys('first', '<C-CR>')
  wait_for(function() return session_state() ~= vim.NIL and session_state().state == 'busy' end, 'a running turn', 10000)
  cursor_on('+n2')
  child.type_keys('c')
  wait_for(editor_open, 'the editor again')
  child.type_keys('ISSUE: second', '<C-CR>')
  wait_for(function() return session_state() ~= vim.NIL and #session_state().queue == 1 end, 'queued')
  eq(session_state().queue[1]:find('ISSUE (a problem to fix)', 1, true) ~= nil, true)
  wait_for(function() return count() == 0 end, 'both gone')
  eq(child.lua_get('_G.notes[#_G.notes]'), 'Agent-IDE: sent to "Work on it": [ISSUE] `new.txt:2`')
end

T['<C-CR> on a session running elsewhere is refused; the comment stays'] = function()
  start({ fake = { { expect = 'never' }, init_step(), result_step('no') },
    live = { interval_ms = 50, cmd = { 'echo', '[{"sessionId":"' .. ID .. '","status":"idle","pid":1,"cwd":"/x"}]' } } })
  open({ kind = 'head' })
  wait_drawer_sessions()
  cursor_on('+aaa')
  child.type_keys('c')
  wait_for(editor_open, 'the editor')
  child.type_keys('never', '<C-CR>')
  wait_for(function()
    local notes = child.lua_get('_G.notes')
    return notes[#notes] == 'Agent-IDE: session is running in another Claude; use gT in the drawer to jump to it'
  end, 'the refusal')
  vim.wait(200)
  eq(count(), 1)
  eq(fake.log(log), {})
  eq(virt_at('+aaa'), '  ┃ NOTE  never')
end

-- The final review's findings ---------------------------------------------------------------------

T['gs with a draft kept on disk by an earlier Neovim offers Insert above / Replace and keeps it'] = function()
  start()
  open({ kind = 'head' })
  wait_drawer_sessions()
  comment_on('+aaa', 'one')
  wait_for(function() return virt_at('+aaa') ~= nil end, 'placed')
  -- the draft file of the session, as drafts.lua writes it; no prompt buffer exists here yet
  local path = child.lua_get('require("agent-ide.ui.drafts").path(...)', { ID })
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile({ '---', 'agent-ide: draft', 'session: ' .. ID, 'cwd: ' .. repo, 'saved: 2026-01-01T00:00:00', '---',
    'my old draft' }, path)
  eq(prompt_lines(), vim.NIL)
  child.type_keys('gs')
  wait_for(function() return #asks() == 2 end, 'the done dialog')
  eq(asks()[2].items[1], 'Insert above the draft')
  wait_for(function() return count() == 0 end, 'cleared')
  local lines = prompt_lines()
  eq(lines[#lines], 'my old draft')
end

T['<C-CR> to a session never opened here loads its history first: its chat shows the earlier conversation'] = function()
  start({ fake = { { expect = 'I reviewed your changes' }, init_step(), result_step('ok') } })
  open({ kind = 'head' })
  wait_drawer_sessions()
  cursor_on('+aaa')
  child.type_keys('c')
  wait_for(editor_open, 'the editor')
  child.type_keys('BUG: swallows it', '<C-CR>')
  wait_for(function() return #fake_prompts() == 1 end, 'the fake to receive the prompt', 10000)
  wait_for(function() local st = session_state().state; return st == 'idle' or st == 'done' end, 'the turn to end')
  child.lua([[local id, repo = ...
    local s = require('agent-ide.session').open({ id = id, cwd = repo })
    require('agent-ide.ui.chat').open(s, { key = repo, root = repo, name = 'r', is_git = true, sessions = {} })]], { ID, repo })
  local function transcript()
    return child.lua_get([[(function(id)
      local s = require('agent-ide.session').get(id)
      local tbuf = require('agent-ide.ui.chat').buffers(s)
      return vim.api.nvim_buf_get_lines(tbuf, 0, -1, false)
    end)(...)]], { ID })
  end
  wait_for(function() return has_line(transcript(), 'I reviewed your changes') ~= nil end, 'the review in the transcript')
  eq(has_line(transcript(), 'Work on it') ~= nil, true) -- the earlier prompt of the session, from its transcript
  eq(has_line(transcript(), 'Work on it') < has_line(transcript(), 'I reviewed your changes'), true)
end

T['before the drawer has scanned, a stored session is kept: the winbar lookup never drops it'] = function()
  start()
  local project = { key = repo, root = repo, name = 'r', is_git = true, sessions = {} }
  child.lua('require("agent-ide.review").set_session(..., select(2, ...))', { repo, ID })
  eq(child.lua_get('require("agent-ide.ui.review_send").target_name(..., select(2, ...))', { repo, project }), vim.NIL)
  eq(session_of_review(), ID)
  open({ kind = 'head' }) -- opens the Agents tab: the scan runs
  wait_drawer_sessions()
  eq(child.lua_get('require("agent-ide.ui.review_send").target_name(..., select(2, ...))', { repo, project }), 'Work on it')
  eq(session_of_review(), ID)
end

return T

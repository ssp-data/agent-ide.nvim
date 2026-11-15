-- Review comments end to end: a child Neovim on a temporary repository, the full diff open,
-- comments typed in the editor, shown as virtual lines, kept across reloads, sent on.
local R = dofile(vim.fn.getcwd() .. '/tests/git_repo.lua')
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
local function start(opts)
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[
    local env, opts = ...
    for k, v in pairs(env) do vim.uv.os_setenv(k, v) end
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
  }, opts or {}) })
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

return T

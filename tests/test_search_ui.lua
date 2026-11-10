-- Search picker integration tests: each case drives a fresh child Neovim. Synthetic data only;
-- the helper (when used) runs with its own cache directory.
local S = dofile(vim.fn.getcwd() .. '/tests/search_synth.lua')
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()

local ICONS = { open = 'v', closed = '>', project = 'P', waiting = 'W', busy = 'B', idle = 'I', parked = '.',
  done = 'D', failed = 'F', new = '+' }
local real_helper = vim.fn.getcwd() .. '/helper/target/release/agent-ide-helper'
local tmp, projects

local function write_data()
  projects = tmp .. '/projects'
  S.write(projects, '-w-alpha', 'a1', {
    S.title('Alpha parser work'),
    S.user('fix the umlaut bug in Übersetzung', 1, '/w/alpha'),
    S.answer('Fixed the umlaut handling.\nSecond line of the answer.', 2),
    S.tool('Bash', 'cargo test umlaut', 't1'),
    S.result('t1', 'ok'),
    S.user('now write the release notes', 3, '/w/alpha'),
    S.answer('Release notes written.', 4),
  })
  S.write(projects, '-w-alpha', 'a2', { S.user('alpha second session prompt', 5, '/w/alpha') })
  S.write(projects, '-w-beta', 'b1', { S.title('Beta work'), S.user('beta prompt about release', 6, '/w/beta'),
    S.answer(string.rep('long answer text ', 400), 7) })
end

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    write_data()
  end,
  post_case = function()
    child.stop()
    vim.fn.delete(tmp, 'rf')
  end,
  post_once = function() child.stop() end,
} })

local function start(backend)
  child.restart({ '-u', 'tests/minimal_init.lua' })
  local hpath
  if backend == 'helper' then
    hpath = tmp .. '/helper.sh'
    vim.fn.writefile({ '#!/bin/sh', ('exec %q --cache-dir %q'):format(real_helper, tmp .. '/cache') }, hpath)
    vim.uv.fs_chmod(hpath, tonumber('755', 8))
  end
  child.lua([[
    local opts = ...
    vim.env.TMUX = nil
    _G.notes = {}
    vim.notify = function(msg) table.insert(_G.notes, msg) end
    vim.g.mapleader = ' '
    require('agent-ide').setup(opts)
    vim.cmd('runtime plugin/agent-ide.lua')
  ]], { {
    projects_dir = projects,
    helper = { enabled = backend == 'helper', path = hpath },
    live = { interval_ms = 600000, cmd = { 'echo', '[]' } },
    icons_style = 'plain', icons = ICONS, tcd = false,
  } })
end

local function need_helper()
  if not vim.uv.fs_stat(real_helper) then MiniTest.skip('helper not built') end
end

local function wait_for(cond, what, ms)
  if not vim.wait(ms or 8000, cond, 20) then error('timed out waiting for ' .. what, 2) end
end

local function state() return child.lua_get('require("agent-ide.ui.search")._state()') end

local function list_lines()
  local s = state()
  return s ~= vim.NIL and child.lua_get('vim.api.nvim_buf_get_lines(...,0,-1,false)', { s.bufs.list }) or {}
end

local function preview_lines()
  return child.lua_get('vim.api.nvim_buf_get_lines(...,0,-1,false)', { state().bufs.preview })
end

local function title()
  local t = child.lua_get('vim.api.nvim_win_get_config(...).title', { state().wins.input })
  return table.concat(vim.tbl_map(function(c) return c[1] end, t))
end

-- Type `q` and wait until the picker shows results for it.
local function type_query(q)
  child.type_keys(q)
  local want = child.lua_get('vim.api.nvim_buf_get_lines(require("agent-ide.ui.search")._state().bufs.input,0,1,false)[1]')
  wait_for(function()
    local s = state()
    return s ~= vim.NIL and s.query == want
  end, 'results for ' .. want)
end

local function open_picker(lua)
  child.lua(lua or 'require("agent-ide").search()')
  wait_for(function() local s = state(); return s ~= vim.NIL and s.backend ~= nil end, 'first results')
end

T['picker: live results, highlights, moving, preview, close keys (Lua fallback)'] = function()
  start('lua')
  open_picker()
  eq(child.lua_get('vim.api.nvim_get_mode().mode'), 'i')
  eq(child.lua_get('vim.api.nvim_get_current_win()'), state().wins.input)
  wait_for(function() return title():find('limited', 1, true) ~= nil end, 'limited label')
  eq(title():find('all sessions', 1, true) ~= nil, true)
  type_query('release')
  wait_for(function() return #state().hits == 2 end, 'two prompt hits')
  local lines = list_lines()
  eq(lines[1]:sub(1, 7), 'you    ')
  eq(lines[1]:find('release', 1, true) ~= nil, true)
  local marks = child.lua_get([[#vim.api.nvim_buf_get_extmarks(..., -1, 0, -1, { details = true })]], { state().bufs.list })
  eq(marks > 2, true)
  -- the preview shows the hit's turn with the prompt line
  wait_for(function() return vim.tbl_contains(preview_lines(), state().hits[1].snippet) end, 'preview of hit 1')
  child.type_keys('<C-n>')
  eq(state().sel, 2)
  wait_for(function() return vim.tbl_contains(preview_lines(), state().hits[2].snippet) end, 'preview of hit 2')
  child.type_keys('<C-p>')
  eq(state().sel, 1)
  child.type_keys('<Down>')
  eq(state().sel, 2)
  child.type_keys('<Up>')
  eq(state().sel, 1)
  child.type_keys('<Esc>')
  eq(state() ~= vim.NIL, true, 'Esc in insert mode only leaves insert mode')
  child.type_keys('q')
  eq(state(), vim.NIL)
  eq(child.lua_get('#vim.tbl_filter(function(w) local c = vim.api.nvim_win_get_config(w); return c.relative ~= "" and c.focusable end, vim.api.nvim_list_wins())'), 0)
end

T['picker with the helper: fuzzy, answers, kinds cycle, Enter opens the chat on the hit line'] = function()
  need_helper()
  start('helper')
  open_picker()
  wait_for(function() return title():find('helper', 1, true) ~= nil end, 'helper label')
  type_query('umlatu')
  local hits = state().hits
  eq(hits[1].match, 'fuzzy')
  -- <C-f> cycles kinds: prompts only, then answers only
  child.type_keys('<C-f>')
  wait_for(function() return vim.deep_equal(state().kinds, { 'prompt' }) end, 'kinds prompt')
  child.type_keys('<C-f>')
  wait_for(function() return vim.deep_equal(state().kinds, { 'answer' }) and #state().hits > 0 and state().hits[1].kind == 'answer' end, 'answers')
  eq(state().hits[1].snippet, 'Fixed the umlaut handling.')
  child.type_keys('<CR>')
  wait_for(function()
    return vim.startswith(child.lua_get('(vim.b[0].agent_ide_kind or "") .. "/" .. (vim.b[0].agent_ide_session or "")'), 'chat/a1')
      and child.lua_get('vim.api.nvim_get_current_line()') == 'Fixed the umlaut handling.'
  end, 'chat on the answer line')
  eq(state(), vim.NIL)
end

T['Enter on a tool call opens its fold; a deleted session is reported'] = function()
  need_helper()
  start('helper')
  open_picker('require("agent-ide").search({ kinds = { "title", "prompt", "answer", "tool" } })')
  type_query('cargo')
  eq(state().hits[1].kind, 'tool')
  child.type_keys('<CR>')
  wait_for(function() return child.lua_get('vim.api.nvim_get_current_line()') == '▸ Bash: cargo test umlaut' end, 'tool line')
  eq(child.lua_get('vim.fn.foldclosed(".")'), -1)
  -- a session deleted after it was indexed
  open_picker()
  type_query('beta prompt')
  vim.fn.delete(projects .. '/-w-beta/b1.jsonl')
  child.type_keys('<CR>')
  wait_for(function() return #child.lua_get('_G.notes') > 0 end, 'notice')
  eq(child.lua_get('_G.notes[#_G.notes]'):find('no longer exists', 1, true) ~= nil, true)
end

T['a transcript rewritten after indexing still opens on the hit (found by its text)'] = function()
  need_helper()
  start('helper')
  open_picker()
  type_query('release notes written')
  eq(state().hits[1].kind, 'answer')
  -- two events inserted before the hit: its index now points elsewhere
  local path = projects .. '/-w-alpha/a1.jsonl'
  local lines = vim.fn.readfile(path)
  table.insert(lines, 2, S.user('an inserted prompt', 0, '/w/alpha'))
  table.insert(lines, 3, S.answer('an inserted answer', 0))
  vim.fn.writefile(lines, path)
  child.type_keys('<CR>')
  wait_for(function() return child.lua_get('vim.api.nvim_get_current_line()') == 'Release notes written.' end, 'hit line')
end

T['<C-y> copies the full text, <C-e> puts a prompt into the chat prompt'] = function()
  start('lua')
  open_picker()
  type_query('release notes')
  child.type_keys('<C-y>')
  wait_for(function() return child.lua_get('vim.fn.getreg(\'"\')') == 'now write the release notes' end, 'copied')
  child.type_keys('<C-e>')
  eq(child.lua_get('_G.notes[#_G.notes]'):find('no chat prompt', 1, true) ~= nil, true)
  child.type_keys('<Esc>q')
  -- open a chat (its prompt below), then reuse a prompt from the picker
  open_picker()
  type_query('alpha second')
  child.type_keys('<CR>')
  wait_for(function() return child.lua_get('vim.api.nvim_get_current_line()') == 'alpha second session prompt' end, 'chat')
  open_picker()
  type_query('umlaut bug')
  child.type_keys('<C-e>')
  wait_for(function() return state() == vim.NIL end, 'picker closed')
  local pbuf = child.lua_get('vim.api.nvim_win_get_buf(require("agent-ide.ui.chat")._windows().prompt)')
  eq(child.lua_get('vim.api.nvim_buf_get_lines(..., 0, -1, false)', { pbuf }), { 'fix the umlaut bug in Übersetzung' })
  eq(child.lua_get('vim.api.nvim_get_current_buf()'), pbuf)
end

T['scope: drawer s searches the project, <Tab> cycles to all; / stays built-in; help lists s'] = function()
  start('lua')
  child.lua('require("agent-ide").toggle()')
  local drawer_buf = child.lua_get('require("agent-ide.ui.drawer").state().buf')
  wait_for(function()
    return vim.iter(child.lua_get('vim.api.nvim_buf_get_lines(...,0,-1,false)', { drawer_buf })):any(function(l) return l:find(' beta ', 1, true) ~= nil end)
  end, 'drawer rows')
  eq(child.lua_get('vim.fn.maparg("/", "n", false, true).buffer'), vim.NIL)
  local rows = child.lua_get('vim.api.nvim_buf_get_lines(...,0,-1,false)', { drawer_buf })
  local row
  for i, l in ipairs(rows) do if l:find(' beta ', 1, true) then row = i end end
  child.lua('local s = require("agent-ide.ui.drawer").state(); vim.api.nvim_set_current_win(s.win); vim.api.nvim_win_set_cursor(s.win, { ..., 0 })', { row })
  child.type_keys('Z')
  wait_for(function() local s = state(); return s ~= vim.NIL and s.backend ~= nil end, 'picker')
  eq(state().scope, 'project')
  eq(title():find('project beta', 1, true) ~= nil, true)
  type_query('release')
  eq(#state().hits, 1)
  eq(state().hits[1].session, 'b1')
  child.type_keys('<Tab>')
  wait_for(function() return state().scope == 'all' and #state().hits == 2 end, 'all scope')
  child.type_keys('<Esc>q')
  child.lua('local s = require("agent-ide.ui.drawer").state(); vim.api.nvim_set_current_win(s.win)')
  child.type_keys('?')
  local help = child.lua_get("vim.api.nvim_buf_get_lines(require('agent-ide.ui.help')._state().lbuf, 0, -1, false)")
  eq(vim.iter(help):any(function(l) return l:match('^Z / <leader>ff / <leader>Z%s+search') ~= nil end), true)
end

T['entry points: keys, :AgentsSearch, prompt history newest first; stale results are dropped'] = function()
  start('lua')
  eq(child.lua_get('vim.fn.maparg(" as", "n") ~= ""'), true)
  eq(child.lua_get('vim.fn.maparg(" aP", "n") ~= ""'), true)
  child.type_keys(' aP')
  wait_for(function() local s = state(); return s ~= vim.NIL and #s.hits == 4 end, 'prompt history')
  eq(title():find('Prompt history', 1, true) ~= nil, true)
  eq(vim.tbl_map(function(h) return h.snippet end, state().hits),
    { 'beta prompt about release', 'alpha second session prompt', 'now write the release notes', 'fix the umlaut bug in Übersetzung' })
  child.type_keys('<Esc>q')
  child.lua('vim.cmd("AgentsSearch beta")')
  wait_for(function() local s = state(); return s ~= vim.NIL and s.query == 'beta' end, ':AgentsSearch query')
  child.type_keys('<Esc>q')
  -- a slow first answer is dropped when a newer query was typed meanwhile
  child.lua([[
    local search = require('agent-ide.index.search')
    local orig = search.search
    local n = 0
    search.search = function(p, cb)
      n = n + 1
      if n == 2 then return vim.defer_fn(function() orig(p, cb) end, 300) end
      orig(p, cb)
    end
  ]])
  open_picker()
  child.type_keys('z')
  vim.wait(50)
  child.type_keys('<BS>beta')
  wait_for(function() return state().query == 'beta' end, 'latest query')
  vim.wait(400)
  eq(state().query, 'beta')
  eq(state().hits[1].session, 'b1')
end

T['an index pointing at another answer of the same kind still opens on the hit text'] = function()
  need_helper()
  start('helper')
  open_picker('require("agent-ide").search({ kinds = { "answer" } })')
  type_query('umlaut handling')
  eq(state().hits[1].event, 2)
  -- another answer now sits at index 2: same kind, other text
  local path = projects .. '/-w-alpha/a1.jsonl'
  local lines = vim.fn.readfile(path)
  table.insert(lines, 3, S.answer('a different answer here', 1))
  vim.fn.writefile(lines, path)
  child.type_keys('<CR>')
  wait_for(function() return child.lua_get('vim.api.nvim_get_current_line()') == 'Fixed the umlaut handling.' end, 'hit line')
end

T['copy refuses when the full text cannot be read, never copies a snippet'] = function()
  start('lua')
  open_picker()
  type_query('release notes')
  child.lua('vim.fn.setreg(\'"\', "before")')
  vim.fn.delete(projects .. '/-w-alpha/a1.jsonl')
  child.type_keys('<C-y>')
  wait_for(function()
    return vim.iter(child.lua_get('_G.notes')):any(function(n) return n:find('could not read the full text', 1, true) ~= nil end)
  end, 'notice')
  eq(child.lua_get('vim.fn.getreg(\'"\')'), 'before')
end

T['a resize keeps query, scope, kinds and selection'] = function()
  start('lua')
  open_picker()
  type_query('release')
  child.type_keys('<C-f>') -- prompts only
  wait_for(function() return vim.deep_equal(state().kinds, { 'prompt' }) and #state().hits == 2 end, 'prompts')
  child.type_keys('<C-n>')
  eq(state().sel, 2)
  child.lua('vim.api.nvim_exec_autocmds("VimResized", {})')
  wait_for(function() local s = state(); return s ~= vim.NIL and s.query == 'release' and #s.hits == 2 end, 'reopened')
  eq(state().kinds, { 'prompt' })
  eq(state().scope, 'all')
  eq(state().sel, 2)
end

T['the preview folds like the chat, the hit fold open'] = function()
  need_helper()
  start('helper')
  open_picker('require("agent-ide").search({ kinds = { "title", "prompt", "answer", "tool" } })')
  type_query('umlaut handling')
  eq(state().hits[1].kind, 'answer')
  local win = state().wins.preview
  wait_for(function() return vim.tbl_contains(preview_lines(), 'Fixed the umlaut handling.') end, 'preview')
  eq(child.lua_get('vim.wo[...].foldmethod', { win }), 'expr')
  local row
  for i, l in ipairs(preview_lines()) do if l:find('▸ Bash', 1, true) then row = i end end
  eq(child.lua_get('vim.api.nvim_win_call(..., function() return vim.fn.foldclosed(' .. row .. ') end)', { win }), row)
  child.type_keys('<C-u>')
  type_query('cargo test umlaut')
  eq(state().hits[1].kind, 'tool')
  wait_for(function()
    local cur = child.lua_get('vim.api.nvim_win_get_cursor(...)[1]', { win })
    return preview_lines()[cur] == '▸ Bash: cargo test umlaut'
      and child.lua_get('vim.api.nvim_win_call(..., function() return vim.fn.foldclosed(".") end)', { win }) == -1
  end, 'tool fold open')
end

T['the helper cache directory is 0700 and its files 0600'] = function()
  need_helper()
  local xdg = tmp .. '/xdg'
  vim.fn.mkdir(xdg .. '/nvim/agent-ide', 'p', tonumber('755', 8))
  local saved_cache = vim.uv.os_getenv('XDG_CACHE_HOME')
  vim.uv.os_setenv('XDG_CACHE_HOME', xdg)
  local ok, err = pcall(function()
    child.restart({ '-u', 'tests/minimal_init.lua' })
    child.lua([[require('agent-ide').setup({ projects_dir = ..., live = { interval_ms = 600000, cmd = { 'echo', '[]' } } })]],
      { projects })
    eq(child.lua_get('vim.fn.stdpath("cache")'), xdg .. '/nvim')
    open_picker()
    type_query('release')
  end)
  if saved_cache then vim.uv.os_setenv('XDG_CACHE_HOME', saved_cache) else vim.uv.os_unsetenv('XDG_CACHE_HOME') end
  if not ok then error(err, 0) end
  local dir = xdg .. '/nvim/agent-ide'
  local mode = function(p) return bit.band(vim.uv.fs_stat(p).mode, tonumber('777', 8)) end
  eq(mode(dir), tonumber('700', 8))
  wait_for(function() return vim.uv.fs_stat(dir .. '/search-v1.json') ~= nil end, 'search index written')
  eq(mode(dir .. '/search-v1.json'), tonumber('600', 8))
end

T['picker keys come from config; <C-r> and <C-k> keep their Vim meaning'] = function()
  start('lua')
  child.lua('require("agent-ide").setup(vim.tbl_deep_extend("force", require("agent-ide.config").get(), { keys = { search_picker = { kinds = "<C-g>", reuse = false } } }))')
  open_picker()
  local buf = state().bufs.input
  local mapped = function(lhs, mode)
    return child.lua('local b, l, m = ...; return vim.api.nvim_buf_call(b, function() return vim.fn.maparg(l, m) end)', { buf, lhs, mode })
  end
  eq(mapped('<C-r>', 'i'), '')
  eq(mapped('<C-k>', 'i'), '')
  eq(mapped('<C-e>', 'i'), '')
  eq(mapped('<C-f>', 'i'), '')
  eq(mapped('<C-g>', 'i') ~= '', true)
  eq(mapped('<Esc>', 'i'), '')
  eq(mapped('<Esc>', 'n') ~= '', true)
  child.type_keys('<C-g>')
  wait_for(function() return vim.deep_equal(state().kinds, { 'prompt' }) end, 'kinds by <C-g>')
end

T['prompt history: repeated prompts are one row with a count; how many of how many'] = function()
  local lines = {}
  for i = 1, 520 do lines[#lines + 1] = S.user('distinct prompt ' .. i, i, '/w/many') end
  for i = 1, 3 do lines[#lines + 1] = S.user('the same prompt', 600 + i, '/w/many') end
  S.write(projects, '-w-many', 'm1', lines)
  start('lua')
  child.type_keys(' aP')
  wait_for(function() local s = state(); return s ~= vim.NIL and #s.hits > 0 and s.hits[1].snippet == 'the same prompt' end, 'history')
  eq(state().hits[1].count, 3)
  eq(state().hits[2].snippet, 'distinct prompt 520')
  local list = list_lines()
  eq(list[1]:find('the same prompt', 1, true) ~= nil, true)
  local marks = child.lua_get([[vim.tbl_map(function(m) return m[4].virt_text and m[4].virt_text[1][1] or '' end,
    vim.api.nvim_buf_get_extmarks(..., -1, { 0, 0 }, { 0, -1 }, { details = true }))]], { state().bufs.list })
  eq(vim.iter(marks):any(function(t) return t:find('×3', 1, true) ~= nil end), true)
  local footer = child.lua_get('vim.api.nvim_win_get_config(...).footer[1][1]', { state().wins.list })
  eq(footer:find('newest 500 of 527', 1, true) ~= nil, true)
end

-- Matches in the preview and in the opened transcript -----------------------------------------

-- A session whose title holds one query word and whose prompt holds both, the second far below
-- the first; one whose title holds every word of its query and its text none.
local FILLER = 40
local function write_mailer()
  local body = { 'configure the Mailer for the team' }
  for i = 1, FILLER do body[#body + 1] = 'filler line ' .. i .. ' without the words' end
  body[#body + 1] = 'then add a signature block at the end'
  body[#body + 1] = 'and test the signature twice'
  S.write(projects, '-w-mailer', 'm1', { S.title('Mailer settings'), S.user(table.concat(body, '\n'), 10, '/w/mailer'),
    S.answer('Done: the mailer has a signature now.', 11) })
  S.write(projects, '-w-gamma', 'g1', { S.title('Gamma refactor plan'), S.user('something unrelated entirely', 12, '/w/gamma') })
end

local function marks()
  local s = state()
  return s ~= vim.NIL and s.marks ~= vim.NIL and s.marks or nil
end

-- Text of every match extmark of `group` in the preview: { line, text }.
local function preview_marked(group)
  return child.lua_get([[(function(buf, group)
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
      if m[4].hl_group == group then
        local line = vim.api.nvim_buf_get_lines(buf, m[2], m[2] + 1, false)[1]
        out[#out + 1] = { m[2] + 1, line:sub(m[3] + 1, m[4].end_col) }
      end
    end
    table.sort(out, function(a, b) return a[1] < b[1] end)
    return out
  end)(...)]], { state().bufs.preview, group })
end

local function preview_footer()
  local f = child.lua_get('vim.api.nvim_win_get_config(...).footer', { state().wins.preview })
  return table.concat(vim.tbl_map(function(c) return c[1] end, f))
end

-- The cursor of the preview: line, its text, column, and the lines on screen.
local function preview_cursor()
  return child.lua_get([[vim.api.nvim_win_call(..., function()
    local l = vim.fn.line('.')
    return { line = l, text = vim.fn.getline(l), col = vim.fn.col('.') - 1, top = vim.fn.line('w0'), bot = vim.fn.line('w$') }
  end)]], { state().wins.preview })
end

-- The preview's marks once they are those of the selected hit for the query shown.
local function wait_marks()
  wait_for(function()
    local s = state()
    local m, h = marks(), s.hits[s.sel]
    return m ~= nil and h ~= nil and m.query == s.query and m.session == h.session
  end, 'preview marks')
  return marks()
end

local function hl_count() return #child.lua_get('require("agent-ide.ui.search_hl")._state()') end

for _, backend in ipairs({ 'lua', 'helper' }) do
  T['preview (' .. backend .. '): a word only in the title, one in the body: the body word on screen, every word marked, ]n / [n step'] = function()
    if backend == 'helper' then need_helper() end
    write_mailer()
    start(backend)
    open_picker('require("agent-ide").search({ kinds = { "prompt" } })')
    type_query('mailer signature')
    wait_for(function() local h = state().hits[1]; return h ~= nil and h.session == 'm1' end, 'the prompt hit')
    local m = wait_marks()
    -- the prompt: Mailer, signature twice; the answer: mailer, signature. The first signature
    -- is current, on screen
    eq(#m.occ, 5)
    eq(m.cur, 2)
    local cur = preview_cursor()
    eq(cur.text, 'then add a signature block at the end')
    eq(cur.text:sub(cur.col + 1, cur.col + 9), 'signature')
    eq(cur.line >= cur.top and cur.line <= cur.bot, true)
    eq(vim.tbl_map(function(x) return x[2] end, preview_marked('AgentIdeSearchMatch')),
      { 'Mailer', 'signature', 'signature', 'mailer', 'signature' })
    eq(vim.tbl_map(function(x) return x[2] end, preview_marked('AgentIdeSearchMatchCurrent')), { 'signature' })
    eq(preview_footer():find('match 2/5', 1, true) ~= nil, true)
    eq(preview_footer():find(']n/[n match', 1, true) ~= nil, true)
    -- <M-n> in insert mode, ]n / [n in normal mode; wrapping
    eq(child.lua_get('vim.api.nvim_get_mode().mode'), 'i')
    child.type_keys('<M-n>')
    eq(marks().cur, 3)
    eq(preview_footer():find('match 3/5', 1, true) ~= nil, true)
    child.type_keys('<Esc>')
    child.type_keys(']n', ']n', ']n')
    eq(marks().cur, 1)
    eq(preview_footer():find('match 1/5', 1, true) ~= nil, true)
    cur = preview_cursor()
    eq(cur.text, 'configure the Mailer for the team')
    eq(cur.line >= cur.top and cur.line <= cur.bot, true)
    child.type_keys('[n')
    eq(marks().cur, 5)
    eq(preview_cursor().text, 'Done: the mailer has a signature now.')
    child.type_keys('<M-p>')
    eq(marks().cur, 4)
    -- ] and [ are typed text in insert mode
    child.type_keys('A', ' ]n')
    eq(child.lua_get('vim.api.nvim_buf_get_lines(...,0,1,false)[1]', { state().bufs.input }), 'mailer signature ]n')
  end

  T['preview (' .. backend .. '): every word only in the title or project: the top, said in the footer'] = function()
    if backend == 'helper' then need_helper() end
    write_mailer()
    start(backend)
    open_picker()
    type_query('gamma refactor')
    wait_for(function() local h = state().hits[1]; return h ~= nil and h.session == 'g1' end, 'the title hit')
    local m = wait_marks()
    eq(#m.occ, 0)
    eq(m.top, true)
    eq(preview_footer():find('matched in title/project', 1, true) ~= nil, true)
    eq(preview_cursor().line, 1)
  end

  T['preview (' .. backend .. '): umlauts and case fold as the search does'] = function()
    if backend == 'helper' then need_helper() end
    start(backend)
    open_picker()
    type_query('über')
    wait_for(function() local h = state().hits[1]; return h ~= nil and h.kind == 'prompt' end, 'the prompt hit')
    wait_marks()
    eq(vim.tbl_map(function(x) return x[2] end, preview_marked('AgentIdeSearchMatch')), { 'Über' })
    eq(preview_marked('AgentIdeSearchMatchCurrent')[1][2], 'Über')
  end

  T['open (' .. backend .. '): the cursor on the first match in the event, ]n steps through the transcript, <Esc> clears'] = function()
    if backend == 'helper' then need_helper() end
    write_mailer()
    start(backend)
    open_picker('require("agent-ide").search({ kinds = { "prompt" } })')
    type_query('mailer signature')
    wait_for(function() local h = state().hits[1]; return h ~= nil and h.session == 'm1' end, 'the prompt hit')
    wait_marks()
    child.lua('vim.fn.setreg("/", "untouched")')
    child.type_keys('<CR>')
    wait_for(function() return child.lua_get('vim.api.nvim_get_current_line()') == 'then add a signature block at the end' end,
      'chat on the signature line')
    eq(child.lua_get('vim.fn.col(".")'), #'then add a ' + 1)
    local win = child.lua_get('vim.api.nvim_get_current_win()')
    local groups = function()
      return child.lua_get('vim.tbl_map(function(m) return m.group end, vim.fn.getmatches(...))', { win })
    end
    eq(vim.tbl_contains(groups(), 'AgentIdeSearchMatch'), true)
    eq(vim.tbl_contains(groups(), 'AgentIdeSearchMatchCurrent'), true)
    child.type_keys(']n')
    eq(child.lua_get('vim.api.nvim_get_current_line()'), 'and test the signature twice')
    child.type_keys(']n') -- the answer
    eq(child.lua_get('vim.api.nvim_get_current_line()'), 'Done: the mailer has a signature now.')
    eq(child.lua_get('vim.fn.col(".")'), #'Done: the ' + 1)
    child.type_keys('[n', '[n')
    eq(child.lua_get('vim.api.nvim_get_current_line()'), 'then add a signature block at the end')
    -- the search register and 'hlsearch' are the user's
    eq(child.lua_get('vim.fn.getreg("/")'), 'untouched')
    eq(child.lua_get('vim.o.hlsearch'), true)
    child.type_keys('<Esc>')
    eq(groups(), {})
    eq(hl_count(), 0)
    eq(child.lua_get('vim.fn.maparg("]n", "n")'), '')
    eq(child.lua_get('vim.fn.maparg("<Esc>", "n")'), '')
  end

  T['open (' .. backend .. '): the highlights go with the window; the next search clears them'] = function()
    if backend == 'helper' then need_helper() end
    write_mailer()
    start(backend)
    open_picker('require("agent-ide").search({ kinds = { "prompt" } })')
    type_query('mailer signature')
    wait_for(function() local h = state().hits[1]; return h ~= nil and h.session == 'm1' end, 'the prompt hit')
    child.type_keys('<CR>')
    wait_for(function() return hl_count() == 1 end, 'highlights')
    local win = child.lua_get('vim.api.nvim_get_current_win()')
    local buf = child.lua_get('vim.api.nvim_get_current_buf()')
    -- the transcript in a second window: no highlights there
    child.lua('vim.cmd("split")')
    eq(child.lua_get('#vim.fn.getmatches()'), 0)
    child.lua('vim.api.nvim_win_close(..., true)', { win })
    eq(hl_count(), 0)
    eq(child.lua_get('vim.api.nvim_buf_call(..., function() return vim.fn.maparg("]n", "n") end)', { buf }), '')
    -- open again, then a new search clears them
    open_picker('require("agent-ide").search({ kinds = { "prompt" } })')
    type_query('mailer signature')
    wait_for(function() local h = state().hits[1]; return h ~= nil and h.session == 'm1' end, 'the prompt hit again')
    child.type_keys('<CR>')
    wait_for(function() return hl_count() == 1 end, 'highlights again')
    open_picker()
    eq(hl_count(), 0)
  end
end

T['preview with the helper: a fuzzy word marks what the search matched'] = function()
  need_helper()
  start('helper')
  open_picker()
  type_query('umlatu')
  wait_for(function() local h = state().hits[1]; return h ~= nil and h.match == 'fuzzy' end, 'fuzzy hit')
  local m = wait_marks()
  eq(#m.occ > 0, true)
  local marked = preview_marked('AgentIdeSearchMatchCurrent')
  eq(#marked, 1)
  eq(marked[1][2]:lower():find('uml', 1, true) ~= nil, true)
  local cur = preview_cursor()
  eq(cur.line >= cur.top and cur.line <= cur.bot, true)
end

T['search_hl: fuzzy without a span marks the longest part of the word; budget: 2000 lines under 5 ms'] = function()
  child.restart({ '-u', 'tests/minimal_init.lua' })
  local terms = child.lua_get([[vim.tbl_map(function(t) return t.raw end,
    require('agent-ide.ui.search_hl').terms('signatrue', { match = 'fuzzy', title = 'x', project = 'y', snippet = 'z', positions = {} },
      { 'a signature here' }))]])
  eq(terms, { 'signatrue', 'signat' })
  local r = child.lua_get([[(function()
    local hl = require('agent-ide.ui.search_hl')
    local view = require('agent-ide.ui.search_view')
    -- prose with umlauts; the query's words in about one line of five
    local words = { 'release', 'notes', 'window', 'buffer', 'the', 'and', 'über', 'fold', 'Übersicht', 'render', 'query',
      'result', 'with', 'for', 'when', 'Brücke', 'test', 'cargo', 'build', 'Neovim', 'plugin', 'should', 'because' }
    local lines = {}
    for i = 1, 2000 do
      local l = {}
      for k = 1, 14 do l[k] = words[(i * 7 + k * 3) % #words + 1] end
      if i % 7 == 0 then l[5] = 'parser' end
      if i % 13 == 0 then l[9] = 'Größe' end
      lines[i] = table.concat(l, ' ')
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local hit = { title = 'Release work', project = 'proj', match = 'prefix', snippet = 'x', positions = {} }
    local best, n = math.huge, 0
    for _ = 1, 7 do
      vim.api.nvim_buf_clear_namespace(buf, -1, 0, -1)
      local t0 = vim.uv.hrtime()
      local terms = hl.terms('parser größe', hit, lines)
      local occ = hl.occurrences(lines, terms)
      hl.pick(occ, 1000)
      view.mark(buf, occ)
      best = math.min(best, (vim.uv.hrtime() - t0) / 1e6)
      n = #occ
    end
    return { ms = best, n = n }
  end)()]])
  MiniTest.add_note(('2000-line preview highlighted: %.2f ms, %d occurrences (budget 5 ms)'):format(r.ms, r.n))
  eq(r.n, 285 + 153)
  if r.ms >= 5 then error(('highlighting took %.2f ms, budget < 5 ms'):format(r.ms), 0) end
end

return T

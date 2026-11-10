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
    icons = ICONS, tcd = false,
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
  eq(child.lua_get('#vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative ~= "" end, vim.api.nvim_list_wins())'), 0)
end

T['picker with the helper: fuzzy, answers, kinds cycle, Enter opens the chat on the hit line'] = function()
  need_helper()
  start('helper')
  open_picker()
  wait_for(function() return title():find('helper', 1, true) ~= nil end, 'helper label')
  type_query('umlatu')
  local hits = state().hits
  eq(hits[1].match, 'fuzzy')
  -- <C-k> cycles kinds: prompts only, then answers only
  child.type_keys('<C-k>')
  wait_for(function() return vim.deep_equal(state().kinds, { 'prompt' }) end, 'kinds prompt')
  child.type_keys('<C-k>')
  wait_for(function() return vim.deep_equal(state().kinds, { 'answer' }) and #state().hits > 0 and state().hits[1].kind == 'answer' end, 'answers')
  eq(state().hits[1].snippet, 'Fixed the umlaut handling.')
  child.type_keys('<CR>')
  wait_for(function()
    return child.lua_get('vim.api.nvim_buf_get_name(0)'):find('agent-ide://chat/a1', 1, true) ~= nil
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

T['<C-y> copies the full text, <C-r> puts a prompt into the chat prompt'] = function()
  start('lua')
  open_picker()
  type_query('release notes')
  child.type_keys('<C-y>')
  wait_for(function() return child.lua_get('vim.fn.getreg(\'"\')') == 'now write the release notes' end, 'copied')
  child.type_keys('<C-r>')
  eq(child.lua_get('_G.notes[#_G.notes]'):find('no chat prompt', 1, true) ~= nil, true)
  child.type_keys('<Esc>q')
  -- open a chat (its prompt below), then reuse a prompt from the picker
  open_picker()
  type_query('alpha second')
  child.type_keys('<CR>')
  wait_for(function() return child.lua_get('vim.api.nvim_get_current_line()') == 'alpha second session prompt' end, 'chat')
  open_picker()
  type_query('umlaut bug')
  child.type_keys('<C-r>')
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
    return vim.iter(child.lua_get('vim.api.nvim_buf_get_lines(...,0,-1,false)', { drawer_buf })):any(function(l) return l:find('P beta', 1, true) ~= nil end)
  end, 'drawer rows')
  eq(child.lua_get('vim.fn.maparg("/", "n", false, true).buffer'), vim.NIL)
  local rows = child.lua_get('vim.api.nvim_buf_get_lines(...,0,-1,false)', { drawer_buf })
  local row
  for i, l in ipairs(rows) do if l:find('P beta', 1, true) then row = i end end
  child.lua('local s = require("agent-ide.ui.drawer").state(); vim.api.nvim_set_current_win(s.win); vim.api.nvim_win_set_cursor(s.win, { ..., 0 })', { row })
  child.type_keys('s')
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
  local help = child.lua_get('vim.api.nvim_buf_get_lines(0, 0, -1, false)')
  eq(vim.iter(help):any(function(l) return l:match('^s%s+search') ~= nil end), true)
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

return T

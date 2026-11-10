-- Buffer names (ui/bufname.lua): every plugin buffer is named `agents://…`, uniquely, renamed
-- with the session's title, without ghost buffers, autocommands or a changed filetype.
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()
local B = require('agent-ide.ui.bufname')

local tmp, repo

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    tmp = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    tmp = vim.uv.fs_realpath(tmp)
    repo = tmp .. '/repo'
    vim.fn.mkdir(repo, 'p')
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

local function start()
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[
    local repo = ...
    vim.env.TMUX = nil
    _G.notes = {}
    vim.notify = function(msg) table.insert(_G.notes, msg) end
    -- user autocommands that expect real files must not see our names
    _G.filev = 0
    vim.api.nvim_create_autocmd({ 'BufFilePre', 'BufFilePost', 'BufNew', 'BufAdd', 'BufReadCmd', 'FileType' }, {
      pattern = 'agents://*', callback = function() _G.filev = _G.filev + 1 end })
    require('agent-ide').setup({ projects_dir = repo .. '/none', helper = { enabled = false },
      live = { interval_ms = 50, cmd = { 'echo', '[]' } }, claude = { cmd = { 'false' } },
      prompts = { command_dirs = {}, skill_dirs = {}, project_dirs = false } })
    require('agent-ide').toggle()
    _G.project = { key = repo, name = 'repo', root = repo, is_git = false, missing = false, mtime = 0, sessions = {} }
    _G.open = function()
      local s = require('agent-ide.session').open({ cwd = repo })
      require('agent-ide.ui.chat').open(s, _G.project)
      return s
    end
  ]], { repo })
end

local function names()
  return child.lua_get([[(function()
    local out = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do out[#out + 1] = vim.api.nvim_buf_get_name(b) end
    return out
  end)()]])
end

-- Buffers of the current (Agents) tab's windows, and listed buffers other than the first tab's
-- initial one, that have no name.
local function unnamed()
  return child.lua_get([[(function()
    local out = {}
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.api.nvim_buf_get_name(b) == '' then out[#out + 1] = 'shown ' .. b end
    end
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if b ~= 1 and vim.bo[b].buflisted and vim.api.nvim_buf_get_name(b) == '' then out[#out + 1] = 'listed ' .. b end
    end
    return out
  end)()]])
end

local function chat_bufs(i)
  return child.lua_get([[(function(i)
    local s = require('agent-ide.session').all()[i]
    local t, p = require('agent-ide.ui.chat').buffers(s)
    local function info(b)
      return { name = vim.api.nvim_buf_get_name(b), ft = vim.bo[b].filetype, bt = vim.bo[b].buftype, listed = vim.bo[b].buflisted }
    end
    return { t = info(t), p = info(p) }
  end)(...)]], { i })
end

-- Pure -------------------------------------------------------------------------------------------

T['clean: awkward characters become one space, cut to 60 cells with …, a fallback when empty'] = function()
  eq(B.clean('  Fix  the\nparser |now| "x" *?<>\\ \t ', 'new session'), 'Fix the parser now x')
  eq(B.clean('100% of a/b', 'x'), '100% of a/b')
  eq(B.clean('\n \r ', 'new session'), 'new session')
  eq(B.clean(nil, 'new session'), 'new session')
  local long = B.clean(string.rep('ab', 150), 'x')
  eq(vim.fn.strdisplaywidth(long), 60)
  eq(vim.endswith(long, '…'), true)
  -- wide characters are counted by cells, never split
  local wide = B.clean(string.rep('日', 40), 'x')
  eq(vim.fn.strdisplaywidth(wide) <= 60, true)
  eq(wide, string.rep('日', 29) .. '…')
  eq(B.clean('ship it 🚀', 'x'), 'ship it 🚀')
  eq(B.session_name('repo', nil, ' · prompt'), 'agents://repo/new session · prompt')
end

-- Chat buffers ------------------------------------------------------------------------------------

T['transcript and prompt are named after project and title; filetype, buftype and listing as before'] = function()
  start()
  child.lua('_G.open()')
  eq(chat_bufs(1), {
    t = { name = 'agents://repo/new session', ft = 'markdown', bt = 'nofile', listed = false },
    p = { name = 'agents://repo/new session · prompt', ft = 'markdown', bt = 'acwrite', listed = false },
  })
  eq(child.lua_get('_G.filev'), 0)
  -- the winbar is unchanged
  eq(child.lua_get([[require('agent-ide.ui.chat')._winbar(require('agent-ide.session').all()[1], _G.project, 80)]]):find('new session', 1, true) ~= nil, true)
  -- the drawer
  eq(vim.tbl_contains(names(), 'agents://drawer'), true)
  -- a second new session in the same project: a numbered name
  child.lua('_G.open()')
  eq(chat_bufs(2).t.name, 'agents://repo/new session (2)')
  eq(chat_bufs(2).p.name, 'agents://repo/new session · prompt (2)')
  eq(unnamed(), {})
end

T['no buffer shown in the Agents tab or listed by it is unnamed, from the drawer on'] = function()
  start()
  -- the drawer alone: its main window shows the tab's placeholder, named and unlisted
  eq(unnamed(), {})
  eq(child.lua_get('#vim.tbl_filter(function(b) return vim.bo[b].buflisted end, vim.api.nvim_list_bufs())'), 1) -- the first tab's
  child.lua('_G.open()')
  eq(unnamed(), {})
  -- the placeholder went with its window's buffer change
  eq(vim.tbl_contains(names(), 'agents://empty'), false)
  child.lua('require("agent-ide.ui.help").open("Help", { { key = "a", desc = "b" } })')
  eq(unnamed(), {})
end

T['a title change renames the buffers; 20 renames leave no ghost buffers; awkward titles'] = function()
  start()
  child.lua('_G.open()')
  child.lua([[_G.retitle = function(t)
    local s = require('agent-ide.session').all()[1]
    s.title = t
    s:_emit('meta')
  end]])
  child.lua('_G.retitle("Fix the parser")')
  eq(chat_bufs(1).t.name, 'agents://repo/Fix the parser')
  eq(chat_bufs(1).p.name, 'agents://repo/Fix the parser · prompt')
  local n = child.lua_get('#vim.api.nvim_list_bufs()')
  for i = 1, 20 do child.lua('_G.retitle(...)', { 'Title ' .. i }) end
  eq(child.lua_get('#vim.api.nvim_list_bufs()'), n)
  eq(chat_bufs(1).t.name, 'agents://repo/Title 20')
  eq(vim.tbl_filter(function(x) return x:find('Title 1$') or x:find('Fix the parser') end, names()), {})
  -- %, /, |, a newline, an emoji and 300 characters
  child.lua('_G.retitle(...)', { '50% done: a/b | c\nnext 🚀 ' .. string.rep('x', 300) })
  local t = chat_bufs(1)
  eq(vim.startswith(t.t.name, 'agents://repo/50% done: a/b c next 🚀 xxx'), true)
  eq(vim.endswith(t.t.name, '…'), true)
  eq(vim.fn.strdisplaywidth(t.t.name:sub(#'agents://repo/' + 1)), 60)
  eq(t.p.name, t.t.name .. ' · prompt')
  eq({ t.t.ft, t.p.ft, t.p.bt }, { 'markdown', 'markdown', 'acwrite' })
  eq(child.lua_get('_G.filev'), 0)
  -- the window's alternate file is not clobbered by a rename
  eq(child.lua_get('vim.fn.bufnr("#") == -1 or vim.api.nvim_buf_is_loaded(vim.fn.bufnr("#"))'), true)
end

T[':w and ZZ in the prompt buffer save the prompt as before and write no file named agents:'] = function()
  start()
  child.lua('_G.open()')
  child.lua('vim.api.nvim_buf_set_lines(0, 0, -1, false, { "keep this" })')
  child.cmd('w')
  wait_for(function() return #child.lua_get('_G.notes') > 0 end, 'a notice after :w')
  eq(child.lua_get('_G.notes[#_G.notes]'):find('saved', 1, true) ~= nil, true)
  child.type_keys('ZZ')
  for _, d in ipairs({ repo, child.lua_get('vim.fn.getcwd()'), vim.fn.getcwd() }) do
    eq(vim.fn.glob(d .. '/agents*', true, true), {})
  end
  eq(child.lua_get('_G.filev'), 0)
  -- a user :file on the prompt keeps the plugin's name
  child.lua([[
    local _, p = require('agent-ide.ui.chat').buffers(require('agent-ide.session').all()[1])
    vim.api.nvim_buf_call(p, function() vim.cmd('file other.md') end)
  ]])
  eq(chat_bufs(1).p.name, 'agents://repo/new session · prompt')
end

T['raw view, help float: named; the raw view follows the title'] = function()
  start()
  child.lua('_G.open()')
  child.lua('require("agent-ide.ui.raw").open(require("agent-ide.session").all()[1])')
  wait_for(function() return child.lua_get('vim.api.nvim_buf_get_name(0)') == 'agents://repo/new session · raw' end, 'raw name')
  child.lua('local s = require("agent-ide.session").all()[1]; s.title = "Later"; s:_emit("meta")')
  eq(vim.tbl_contains(names(), 'agents://repo/Later · raw'), true)
  child.lua('require("agent-ide.ui.help").open("Help", { { key = "a", desc = "b" } })')
  eq(child.lua_get('vim.api.nvim_buf_get_name(0)'), 'agents://help/query')
  eq(vim.tbl_contains(names(), 'agents://help'), true)
end

return T

-- Every key option accepts a key, a list of keys, or false: a child Neovim per case sets all
-- default key options to two-key lists (or to false) and opens every place that maps them.
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()

local tmp

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp .. '/projects', 'p')
    vim.fn.mkdir(tmp .. '/repo', 'p')
  end,
  post_case = function()
    child.stop()
    vim.fn.delete(tmp, 'rf')
  end,
  post_once = function() child.stop() end,
} })

-- Default key options, as { path = { 'chat', 'send' }, value = '<C-CR>' } (lists kept as lists).
local function default_leaves()
  child.restart({ '-u', 'tests/minimal_init.lua' })
  local keys = child.lua_get('require("agent-ide.config").setup({}).keys')
  local out = {}
  local function walk(t, path)
    for k, v in pairs(t) do
      local p = vim.list_extend(vim.deepcopy(path), { k })
      if type(v) == 'table' and not vim.islist(v) then walk(v, p) else out[#out + 1] = { path = p, value = v } end
    end
  end
  walk(keys, {})
  table.sort(out, function(a, b) return table.concat(a.path, '.') < table.concat(b.path, '.') end)
  return out
end

local function set_path(t, path, v)
  for i = 1, #path - 1 do
    t[path[i]] = t[path[i]] or {}
    t = t[path[i]]
  end
  t[path[#path]] = v
end

-- Set up with `keys`, open the Agents tab, a chat, its raw view (then back), the search picker;
-- map the diff keys on a scratch and a real buffer. Returns the child's errors (none expected).
local function exercise(keys)
  child.restart({ '-u', 'tests/minimal_init.lua' })
  return child.lua_get([[(function(dir, repo, keys)
    local errs = {}
    local function try(what, fn)
      local ok, e = pcall(fn)
      if not ok then errs[#errs + 1] = what .. ': ' .. tostring(e) end
    end
    vim.env.TMUX = nil
    vim.notify = function() end
    try('setup', function()
      require('agent-ide').setup({ projects_dir = dir, helper = { enabled = false },
        live = { interval_ms = 600000, cmd = { 'echo', '[]' } }, icons_style = 'plain', keys = keys })
    end)
    try('toggle', function()
      require('agent-ide').toggle()
      _G.dbuf = require('agent-ide.ui.drawer').state().buf
    end)
    try('chat', function()
      _G.s = require('agent-ide.session').open({ cwd = repo })
      require('agent-ide.ui.chat').open(_G.s, { key = repo, name = 'repo', root = repo, sessions = {} })
      _G.tbuf, _G.pbuf = require('agent-ide.ui.chat').buffers(_G.s)
    end)
    try('raw', function()
      vim.api.nvim_set_current_win(require('agent-ide.ui.chat')._windows().transcript)
      require('agent-ide.ui.raw').open(_G.s)
      _G.rawbuf = vim.api.nvim_get_current_buf()
    end)
    try('diff keys', function()
      local diff_buf = require('agent-ide.ui.diff_buf')
      _G.lbuf = diff_buf.get('main', 'x.lua', { 'a' })
      _G.rbuf = vim.fn.bufadd(repo .. '/x.lua')
      vim.fn.bufload(_G.rbuf)
      local view = { step = function() end, close = function() end, refresh = function() end, state = function() end }
      require('agent-ide.ui.diff_keys').map(_G.lbuf, view)
      require('agent-ide.ui.diff_keys').map(_G.rbuf, view)
    end)
    try('graph keys', function()
      _G.gbuf = vim.api.nvim_create_buf(false, true)
      require('agent-ide.ui.graph_keys').map(_G.gbuf, {})
    end)
    try('search', function()
      require('agent-ide').search()
      _G.qbuf = vim.api.nvim_get_current_buf()
    end)
    return errs
  end)(...)]], { tmp .. '/projects', tmp .. '/repo', keys })
end

-- Is `lhs` mapped by the plugin in `mode`, buffer-locally in `buf` (or globally when buf is nil)?
local function mapped(buf, mode, lhs)
  return child.lua_get([[(function(buf, mode, lhs)
    local function check()
      local m = vim.fn.maparg(lhs, mode, false, true)
      if type(m) ~= 'table' or not m.desc or not vim.startswith(m.desc, 'Agent-IDE') then return false end
      return (buf == vim.NIL) == (m.buffer == 0)
    end
    if buf == vim.NIL then return check() end
    return vim.api.nvim_buf_call(buf, check)
  end)(...)]], { buf or vim.NIL, mode, lhs })
end

-- Where each option's keys are mapped: { buffer global name|nil, mode }.
local function places(path)
  local group, name = path[1], path[2]
  if #path == 1 then return { { nil, 'n' } } end
  if group == 'search_picker' then return { { '_G.qbuf', 'n' } } end
  if group == 'diff' then return { { '_G.lbuf', 'n' }, { '_G.rbuf', 'n' } } end
  if group == 'graph' then return { { '_G.gbuf', 'n' } } end
  if group == 'drawer' then return { { '_G.dbuf', 'n' } } end
  if group == 'prompts' then return {} end -- drawer row keys: checked through prompt_sections.keys()
  local t, p = { '_G.tbuf', 'n' }, { '_G.pbuf', 'n' }
  local only = {
    raw = { t, { '_G.rawbuf', 'n' } }, raw_event = { t }, diff = { t }, answer_inner = { { '_G.tbuf', 'o' } },
    answer_outer = { { '_G.tbuf', 'o' } }, history_prev = { p }, history_next = { p }, attach = { p }, save_library = { p },
  }
  return only[name] or { t, p }
end

T['every default key option as a two-key list: no error, both keys mapped and working'] = function()
  local leaves = default_leaves()
  local keys = {}
  for i, l in ipairs(leaves) do
    local first = type(l.value) == 'table' and l.value[1] or l.value
    l.keys = { first, '<leader>Z' .. i }
    set_path(keys, l.path, l.keys)
  end
  eq(exercise(keys), {})
  local bufs = child.lua_get('{ _G.tbuf, _G.pbuf, _G.rawbuf, _G.lbuf, _G.rbuf, _G.qbuf, _G.dbuf }')
  eq(#bufs, 7)
  local row_keys = {}
  for _, k in ipairs(child.lua_get('require("agent-ide.ui.prompt_sections").keys()')) do row_keys[k.lhs] = true end
  for _, l in ipairs(leaves) do
    local name = table.concat(l.path, '.')
    for _, lhs in ipairs(l.keys) do
      if l.path[1] == 'prompts' then
        eq({ name, lhs, row_keys[lhs] == true }, { name, lhs, true })
      end
      for _, pl in ipairs(places(l.path)) do
        local buf = pl[1] and child.lua_get(pl[1]) or nil
        -- one-character diff keys stay off the user's own file; a typed native key off the prompt
        local expect = not (pl[1] == '_G.rbuf' and #lhs == 1) and not (pl[1] == '_G.pbuf' and name == 'chat.native' and lhs:sub(1, 1) ~= '<')
        eq({ name, lhs, pl[1] or 'global', mapped(buf, pl[2], lhs) }, { name, lhs, pl[1] or 'global', expect })
      end
    end
  end
  -- both keys of a list act: the chat help by its first and its second key
  local help_keys
  for _, l in ipairs(leaves) do
    if table.concat(l.path, '.') == 'chat.help' then help_keys = l.keys end
  end
  -- leave the picker and the raw view: back to the chat
  child.type_keys('<Esc>')
  child.lua([[
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= '' then pcall(vim.api.nvim_win_close, w, true) end
    end
    require('agent-ide.ui.chat').open(_G.s, { key = 'r', name = 'repo', sessions = {} })
  ]])
  for _, lhs in ipairs(help_keys) do
    child.lua('vim.cmd("stopinsert"); vim.api.nvim_set_current_win(require("agent-ide.ui.chat")._windows().prompt)')
    child.type_keys('<Esc>', (lhs:gsub('<leader>', '\\')))
    eq({ lhs, child.lua_get('vim.api.nvim_win_get_config(0).relative ~= ""') }, { lhs, true })
    child.type_keys('<Esc>', 'q') -- the help opens in its query line (insert mode)
  end
  -- and the global toggle by its second key closes and reopens the drawer
  local toggle
  for _, l in ipairs(leaves) do
    if table.concat(l.path, '.') == 'toggle' then toggle = l.keys[2] end
  end
  child.lua('vim.api.nvim_set_current_tabpage(require("agent-ide.ui.drawer").state().tab)')
  toggle = toggle:gsub('<leader>', '\\')
  child.type_keys(toggle)
  eq(child.lua_get('require("agent-ide.ui.drawer").state().win'), vim.NIL)
  child.type_keys(toggle)
  eq(child.lua_get('require("agent-ide.ui.drawer").state().win') ~= vim.NIL, true)
end

T['every default key option false: no error, none of the default keys is mapped by the plugin'] = function()
  local leaves = default_leaves()
  local keys = {}
  for _, l in ipairs(leaves) do set_path(keys, l.path, false) end
  eq(exercise(keys), {})
  eq(child.lua_get('require("agent-ide.ui.prompt_sections").keys()'), {})
  for _, l in ipairs(leaves) do
    for _, lhs in ipairs(type(l.value) == 'table' and l.value or { l.value }) do
      for _, pl in ipairs(places(l.path)) do
        local buf = pl[1] and child.lua_get(pl[1]) or nil
        -- the raw view's own q stays (a fixed key)
        if not (pl[1] == '_G.rawbuf' and lhs == 'q') then
          eq({ table.concat(l.path, '.'), lhs, mapped(buf, pl[2], lhs) }, { table.concat(l.path, '.'), lhs, false })
        end
      end
    end
  end
end

T['defaults: ? is Vim\'s backward search in the transcript and the prompt; g? opens the help'] = function()
  eq(exercise(nil), {})
  for _, b in ipairs({ '_G.tbuf', '_G.pbuf' }) do
    local buf = child.lua_get(b)
    eq({ b, mapped(buf, 'n', '?') }, { b, false })
    eq({ b, child.lua_get('vim.api.nvim_buf_call(..., function() return vim.fn.maparg("?", "n") end)', { buf }) }, { b, '' })
    eq({ b, mapped(buf, 'n', 'g?') }, { b, true })
  end
end

T['keys = false: no error'] = function()
  eq(exercise(false), {})
  eq(child.lua_get('vim.fn.maparg("<leader>aa", "n")'), '')
end

return T

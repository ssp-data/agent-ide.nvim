-- The Agents tab: a drawer window listing projects and sessions beside a main window.
local api = vim.api
local config = require('agent-ide.config')
local index = require('agent-ide.index')
local live = require('agent-ide.live')
local project = require('agent-ide.project')
local session = require('agent-ide.session')
local tmux = require('agent-ide.tmux')
local model = require('agent-ide.ui.drawer_model')
local sections = require('agent-ide.ui.sections')
local tree = require('agent-ide.ui.tree')

local M = {}

local ns = api.nvim_create_namespace('agent-ide.drawer')
local augroup = api.nvim_create_augroup('agent-ide.drawer', { clear = true })

local S = { tab = nil, win = nil, buf = nil, projects = {}, nodes = {}, expanded = {} }
local debounce -- uv timer for index.on_change
local shown = false -- the drawer window is on screen: live polling and the change timer run

local function valid_win(w) return w ~= nil and api.nvim_win_is_valid(w) end

local function sync()
  if S.tab and not api.nvim_tabpage_is_valid(S.tab) then S.tab = nil end
  if S.buf and not api.nvim_buf_is_valid(S.buf) then S.buf = nil end
  if not S.tab or not valid_win(S.win) or api.nvim_win_get_tabpage(S.win) ~= S.tab
    or api.nvim_win_get_buf(S.win) ~= S.buf then
    S.win = nil
  end
end

local function node_key(node)
  if not node then return nil end
  if node.id then return 'e:' .. node.id end -- rows of ui/sections.lua providers
  if node.type == 'project' then return 'p:' .. node.project.key end
  if node.type == 'section' then return 's:' .. node.key end
  if node.type == 'session' then return 'x:' .. node.session.id end
  if node.type == 'new' then return 'n:' .. node.project.key end
  if node.type == 'header' then return 'h:' end
end

---State shown for a session (see `drawer_model.state_of`).
M.state_of = model.state_of

local function set_opt(win, name, value) api.nvim_set_option_value(name, value, { scope = 'local', win = win }) end

-- Text columns of the drawer window (without a fold or sign column the user's options may add).
local function text_width(cfg)
  if not S.win then return cfg.drawer.width end
  local info = vim.fn.getwininfo(S.win)[1]
  return api.nvim_win_get_width(S.win) - (info and info.textoff or 0)
end

---Re-render the drawer buffer; keeps the drawer cursor on the same node (or on `focus`).
---@param focus? string node key to place the cursor on
local function render(focus)
  sync()
  if not S.buf then return end
  local cfg = config.get()
  local t = tree.build(model.with_unsaved(S.projects), model.state_of, S.expanded, os.time(), cfg.icons, cfg.projects_dir,
    model.note_of, sections.collect,
    { top = sections.collect_top, width = text_width(cfg),
      header = { title = 'Agents', hints = M.hints() } })
  local row = S.win and api.nvim_win_get_cursor(S.win)[1]
  focus = focus or (row and node_key(S.nodes[row]))
  vim.bo[S.buf].modifiable = true
  api.nvim_buf_set_lines(S.buf, 0, -1, false, t.lines)
  vim.bo[S.buf].modifiable = false
  S.nodes = t.nodes
  api.nvim_buf_clear_namespace(S.buf, ns, 0, -1)
  for _, h in ipairs(t.hl) do
    api.nvim_buf_set_extmark(S.buf, ns, h.line - 1, h.col_start, { end_col = h.col_end, hl_group = h.group })
  end
  if S.win and focus then
    for i, node in ipairs(S.nodes) do
      if node_key(node) == focus then
        if i ~= row then api.nvim_win_set_cursor(S.win, { i, 0 }) end
        break
      end
    end
  end
end

local function rescan()
  index.scan(function(sessions)
    S.projects = project.group(sessions)
    render()
  end)
end

local live_policy

-- Every finished poll re-renders (about 0.4 ms), so ages stay current with any backend.
-- `slow`: the drawer is hidden; poll 4x less often (the footer and `send` still use the map).
local function start_live(slow)
  local cfg = config.get()
  live.start({ interval_ms = cfg.live.interval_ms * (slow and 4 or 1), cmd = cfg.live.cmd, defer = slow, on_poll = function()
    if not shown then live_policy() end
    require('agent-ide.status').refresh()
    tmux.refresh_labels(model.elsewhere_pids(), function() render() end)
    render()
    local chat = package.loaded['agent-ide.ui.chat']
    if chat then chat.refresh_winbars() end
  end })
end

-- While the drawer is hidden: slow polling as long as an Agents tab exists or a session is alive
-- here, else none.
live_policy = function()
  if shown then return end
  sync()
  local alive = S.tab ~= nil
  for _, s in ipairs(session.all()) do
    if alive then break end
    alive = s:_alive()
  end
  if not alive then
    live.stop()
  elseif live.interval() ~= config.get().live.interval_ms * 4 then
    start_live(true)
  end
end

local function set_shown(v)
  if v == shown then return end
  shown = v
  if v then
    start_live()
    index.set_visible(true)
    render()
  else
    live_policy()
    index.set_visible(false)
  end
end

-- Shown means: the drawer window exists and the Agents tab is the current tab.
local function refresh_shown()
  sync()
  set_shown(S.win ~= nil and api.nvim_get_current_tabpage() == S.tab)
end

local function on_index_change()
  if not debounce then debounce = vim.uv.new_timer() end
  debounce:stop()
  debounce:start(200, 0, vim.schedule_wrap(function() if S.tab then rescan() end end))
end

local resize_timer
local function on_resize()
  if not resize_timer then resize_timer = vim.uv.new_timer() end
  resize_timer:stop()
  resize_timer:start(30, 0, vim.schedule_wrap(function() render() end))
end

local function notify(msg) vim.notify('Agent-IDE: ' .. msg, vim.log.levels.INFO) end

local function current_node()
  sync()
  if not S.win then return nil end
  return S.nodes[api.nvim_win_get_cursor(S.win)[1]]
end

local function toggle_key(key, default_open)
  local open = S.expanded[key]
  if open == nil then open = default_open end
  S.expanded[key] = not open
end

local function toggle_node(node)
  if node.type == 'project' then
    toggle_key(node.project.key, false)
    render('p:' .. node.project.key)
  elseif node.type == 'section' then
    toggle_key(node.key, true)
    render('s:' .. node.key)
  elseif node.type == 'session' then
    local key = node.project.key .. '/sessions'
    toggle_key(key, true)
    render('s:' .. key)
  elseif node.fold then
    toggle_key(node.fold.key, node.fold.default == true)
    render(node.fold.focus and ('e:' .. node.fold.focus) or node_key(node))
  end
end

local actions = {}

function actions.open()
  local node = current_node()
  if not node then return end
  if node.type == 'session' then
    local m, p = node.session, node.project
    local s = session.open({ id = m.id, cwd = m.cwd or p.root or p.key, path = m.path, title = m.title })
    require('agent-ide.ui.chat').open(s, p)
  elseif node.type == 'new' then
    local p = node.project
    local dir = p.root or p.key
    -- only an absolute key is a folder: a project without cwd is keyed by a bare directory name
    if dir:sub(1, 1) ~= '/' or vim.fn.isdirectory(dir) ~= 1 then return notify('project folder not found: ' .. dir) end
    local s = session.open({ cwd = dir })
    model.add_unsaved(s.id, p.key)
    require('agent-ide.ui.chat').open(s, p)
  elseif node.open then
    local ok, err = pcall(node.open, node)
    if not ok then vim.notify('Agent-IDE: ' .. tostring(err), vim.log.levels.ERROR) end
  else
    toggle_node(node)
  end
end

function actions.fold()
  local node = current_node()
  if node then toggle_node(node) end
end

function actions.refresh()
  sections.refresh()
  rescan()
  if shown then start_live() end
end

function actions.jump()
  local node = current_node()
  if not node or node.type ~= 'session' then return notify('no session under cursor') end
  local entry = live.get()[node.session.id]
  if not entry or not entry.pid then return notify('session is not running') end
  tmux.jump_to_pid(entry.pid, function(ok, reason)
    if not ok then notify('cannot jump (' .. tostring(reason) .. ')') end
  end)
end

function actions.park()
  local node = current_node()
  if not node or node.type ~= 'session' then return notify('no session under cursor') end
  local s = session.get(node.session.id)
  if not s then return notify('nothing to park; it is not running in this Neovim') end
  require('agent-ide.ui.chat').park(s)
end

function actions.close() M.close() end

-- The drawer's own keys (lhs, action name, header hint); a provider row key with the same lhs
-- is neither mapped nor listed. The header line shows the hints in this order.
local KEYS = {
  { '<CR>', 'open' }, { 'o', 'open' }, { 'za', 'fold' }, { 'R', 'refresh', 'refresh' }, { 'gp', 'jump' },
  { 'x', 'park' }, { 'glg', 'lazygit', 'lazygit' }, { 'q', 'close' }, { 's', 'search' }, { '?', 'help', 'help' },
}
local OWN = {}
for _, k in ipairs(KEYS) do OWN[vim.keycode(k[1])] = true end

---Key hints of the header line, from the drawer's own keys: `R refresh`, `glg lazygit`, `? help`.
---@return string[]
function M.hints()
  local out = {}
  for _, k in ipairs(KEYS) do
    if k[3] then out[#out + 1] = k[1] .. ' ' .. k[3] end
  end
  return out
end

local function provider_keys()
  return vim.tbl_filter(function(k) return not OWN[vim.keycode(k.lhs)] end, sections.keys())
end

-- The register a plain operator uses ('clipboard' may make it + or *).
local function default_register()
  local cb = vim.o.clipboard
  if cb:find('unnamedplus', 1, true) then return '+' end
  if cb:find('unnamed', 1, true) then return '*' end
  return '"'
end

-- A provider's row key (ui/sections.lua `keys`): the row's handler, else the key's own meaning:
-- fed back with its count and register, ahead of what was typed after it (`yj` stays `yj`).
function actions.row_key(lhs)
  local node = current_node()
  local fn = node and node.keys and node.keys[lhs]
  if not fn then
    local count = vim.v.count > 0 and tostring(vim.v.count) or ''
    local reg = vim.v.register ~= default_register() and ('"' .. vim.v.register) or ''
    return api.nvim_feedkeys(reg .. count .. vim.keycode(lhs), 'in', false)
  end
  local ok, err = pcall(fn, node)
  if not ok then vim.notify('Agent-IDE: ' .. tostring(err), vim.log.levels.ERROR) end
end

function actions.search()
  local node = current_node()
  local p = node and node.project
  require('agent-ide').search(p and { scope = 'project', project = p } or nil)
end

function actions.lazygit()
  local node = current_node()
  local p = node and node.project
  if not (p and p.is_git and p.root) then return notify('not a git project') end
  -- the row's own work tree: a git row's, a session's (a linked worktree), else the project's
  local root = node.root or (node.session and require('agent-ide.ui.git_sections').tree_of(node.session.cwd)) or p.root
  require('agent-ide.ui.lazygit').open(root)
end

function actions.help()
  local rows = {
    { key = '<CR> / o', desc = 'open session, start a new one, use a prompt, or toggle' },
    { key = 'za', desc = 'toggle fold' },
    { key = 'R', desc = 'refresh' },
    { key = 'gp', desc = 'jump to tmux pane' },
    { key = 's', desc = 'search this project (<Tab> in the picker: all sessions)' },
    { key = 'x', desc = 'park the session: stop its Claude process here' },
    { key = 'glg', desc = 'lazygit for the project (or the row\'s worktree)' },
    { key = 'q', desc = 'close drawer' },
    { key = '?', desc = 'this help' },
    { key = '/', desc = 'search (built-in)' },
  }
  for _, k in ipairs(provider_keys()) do rows[#rows + 1] = { key = k.lhs, desc = k.desc } end
  require('agent-ide.ui.help').open('Agent-IDE drawer', rows)
end

local function ensure_buf()
  sync()
  if S.buf then return S.buf end
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(buf, 'agent-ide://drawer')
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].filetype = 'agent-ide'
  vim.bo[buf].modifiable = false
  local function map(lhs, fn) vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, silent = true }) end
  -- provider row keys (the drawer's own keys below win a clash)
  for _, k in ipairs(provider_keys()) do map(k.lhs, function() actions.row_key(k.lhs) end) end
  for _, k in ipairs(KEYS) do map(k[1], actions[k[2]]) end
  api.nvim_create_autocmd('BufEnter', { buffer = buf, callback = function() sections.focus() end })
  S.buf = buf
  return buf
end

local function open_drawer()
  local cfg = config.get()
  local buf = ensure_buf()
  local side = cfg.drawer.side == 'left' and 'left' or 'right'
  S.win = api.nvim_open_win(buf, true, { split = side, win = -1, width = cfg.drawer.width })
  for name, value in pairs({ winfixwidth = true, number = false, relativenumber = false, signcolumn = 'no',
    wrap = false, list = false, cursorline = true, foldenable = false }) do
    set_opt(S.win, name, value)
  end
  render()
  -- a cursor on the header line (a new window) starts below it
  if api.nvim_win_get_cursor(S.win)[1] == 1 and S.nodes[1] and S.nodes[1].type == 'header' and #S.nodes > 1 then
    api.nvim_win_set_cursor(S.win, { 2, 0 })
  end
  refresh_shown()
end

local function teardown()
  set_shown(false)
  index.on_change(nil)
  if debounce then debounce:stop() end
  if resize_timer then resize_timer:stop() end
  S.tab, S.win = nil, nil
  live_policy()
end

local function create_tab()
  vim.cmd('tabnew')
  S.tab = api.nvim_get_current_tabpage()
  api.nvim_clear_autocmds({ group = augroup })
  api.nvim_create_autocmd('TabClosed', { group = augroup, callback = function()
    if S.tab and not api.nvim_tabpage_is_valid(S.tab) then
      teardown()
      api.nvim_clear_autocmds({ group = augroup })
    end
  end })
  -- `:q`, `<C-w>c` and friends in the drawer: the window is still valid while this runs
  api.nvim_create_autocmd('WinClosed', { group = augroup, callback = function(ev)
    if S.win and tonumber(ev.match) == S.win then
      S.win = nil
      set_shown(false)
    end
  end })
  api.nvim_create_autocmd('TabEnter', { group = augroup, callback = refresh_shown })
  -- the right-aligned columns follow the drawer's width
  api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, { group = augroup, callback = function(ev)
    if not S.win then return end
    if ev.event == 'WinResized' and not vim.tbl_contains(vim.v.event.windows or {}, S.win) then return end
    on_resize()
  end })
  open_drawer()
  sections.setup()
  index.on_change(on_index_change)
  rescan()
end

---The main (non-drawer, non-floating) window of the Agents tab; created beside the drawer if missing.
---@return integer|nil win, nil when there is no Agents tab
function M.main_win()
  sync()
  if not S.tab then return nil end
  for _, w in ipairs(api.nvim_tabpage_list_wins(S.tab)) do
    if w ~= S.win and api.nvim_win_get_config(w).relative == '' then return w end
  end
  local cfg = config.get()
  local side = cfg.drawer.side == 'left' and 'right' or 'left'
  local scratch = api.nvim_create_buf(false, true)
  vim.bo[scratch].bufhidden = 'wipe'
  local w = api.nvim_win_call(S.win, function()
    return api.nvim_open_win(scratch, false, { split = side, win = -1 })
  end)
  api.nvim_win_set_width(S.win, cfg.drawer.width)
  return w
end

---Close the drawer window; the tab stays (a main window is created first if needed).
function M.close()
  sync()
  if not S.win then return end
  local main = M.main_win()
  local win = S.win
  if api.nvim_get_current_win() == win and main then api.nvim_set_current_win(main) end
  api.nvim_win_close(win, false)
  S.win = nil
  set_shown(false)
end

function M.toggle()
  sync()
  if not S.tab then
    create_tab()
  elseif api.nvim_get_current_tabpage() ~= S.tab then
    api.nvim_set_current_tabpage(S.tab)
  elseif S.win then
    M.close()
  else
    open_drawer()
  end
end

---Re-render the drawer (e.g. after a session changed state); keeps focus and other cursors.
function M.refresh() render() end

---Re-decide live polling while the drawer is hidden (e.g. a session started or ended here).
function M.live_policy() live_policy() end

---@return { tab: integer|nil, win: integer|nil, buf: integer|nil, projects: table[], nodes: table[] }
function M.state()
  sync()
  return { tab = S.tab, win = S.win, buf = S.buf, projects = S.projects, nodes = S.nodes }
end

return M

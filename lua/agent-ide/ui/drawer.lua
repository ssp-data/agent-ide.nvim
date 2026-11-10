-- The Agents tab: a drawer window listing projects and sessions beside a main window.
local api = vim.api
local config = require('agent-ide.config')
local index = require('agent-ide.index')
local live = require('agent-ide.live')
local project = require('agent-ide.project')
local tmux = require('agent-ide.tmux')
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
  if node.type == 'project' then return 'p:' .. node.project.key end
  if node.type == 'section' then return 's:' .. node.key end
  if node.type == 'session' then return 'x:' .. node.session.id end
end

local function set_opt(win, name, value) api.nvim_set_option_value(name, value, { scope = 'local', win = win }) end

---Re-render the drawer buffer; keeps the drawer cursor on the same node (or on `focus`).
---@param focus? string node key to place the cursor on
local function render(focus)
  sync()
  if not S.buf then return end
  local cfg = config.get()
  local t = tree.build(S.projects, live.get(), S.expanded, os.time(), cfg.icons, cfg.projects_dir)
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

-- Every finished poll re-renders (about 0.4 ms), so ages stay current with any backend.
local function start_live()
  local cfg = config.get()
  live.start({ interval_ms = cfg.live.interval_ms, cmd = cfg.live.cmd, on_poll = function() render() end })
end

local function set_shown(v)
  if v == shown then return end
  shown = v
  if v then
    start_live()
    index.set_visible(true)
    render()
  else
    live.stop()
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
  end
end

local actions = {}

function actions.open()
  local node = current_node()
  if not node then return end
  if node.type == 'session' then
    require('agent-ide.ui.history').open(node.session, node.project)
  else
    toggle_node(node)
  end
end

function actions.fold()
  local node = current_node()
  if node then toggle_node(node) end
end

function actions.refresh()
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

function actions.close() M.close() end

local function ensure_buf()
  sync()
  if S.buf then return S.buf end
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(buf, 'agent-ide://drawer')
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].filetype = 'agent-ide'
  vim.bo[buf].modifiable = false
  local function map(lhs, fn) vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, silent = true }) end
  map('<CR>', actions.open)
  map('o', actions.open)
  map('za', actions.fold)
  map('R', actions.refresh)
  map('gp', actions.jump)
  map('q', actions.close)
  S.buf = buf
  return buf
end

local function open_drawer()
  local cfg = config.get()
  local buf = ensure_buf()
  local side = cfg.drawer.side == 'left' and 'left' or 'right'
  S.win = api.nvim_open_win(buf, true, { split = side, win = -1, width = cfg.drawer.width })
  for name, value in pairs({ winfixwidth = true, number = false, relativenumber = false, signcolumn = 'no',
    wrap = false, cursorline = true, foldenable = false }) do
    set_opt(S.win, name, value)
  end
  render()
  refresh_shown()
end

local function teardown()
  set_shown(false)
  index.on_change(nil)
  if debounce then debounce:stop() end
  S.tab, S.win = nil, nil
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
  open_drawer()
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

---@return { tab: integer|nil, win: integer|nil, buf: integer|nil, projects: table[], nodes: table[] }
function M.state()
  sync()
  return { tab = S.tab, win = S.win, buf = S.buf, projects = S.projects, nodes = S.nodes }
end

return M

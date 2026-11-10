-- The chat view: a session's transcript in the Agents tab's main window and its prompt buffer
-- in a split below. Both buffers belong to the session and are reused; the two windows are
-- reused for whichever session is opened. Session events only update buffers, the winbar and
-- the drawer: they never move focus or open a window.
local api = vim.api
local chat_keys = require('agent-ide.ui.chat_keys')
local history = require('agent-ide.ui.history')
local live_render = require('agent-ide.transcript.live')
local prompt = require('agent-ide.ui.prompt')
local windows = require('agent-ide.ui.chat_win')
local session = require('agent-ide.session')

local M = {}

local ELSEWHERE = 'Agent-IDE: session is running in another Claude; use gp in the drawer to jump to it'

---@class agent_ide.Chat
---@field s table Session
---@field project table Project (for the winbar)
---@field tbuf integer|nil transcript buffer
---@field pbuf integer|nil prompt buffer
---@field view table|nil live renderer of `tbuf`
---@field loading boolean a load runs: renderer updates wait for it
---@field dirty boolean events changed while loading (or the buffer is new): reset after the load
---@field send_after_load boolean the user sent while loading
---@field stale table<string, integer> unloaded buffers ('tbuf'/'pbuf') whose wipe is pending
local chats = {} -- session id -> Chat; never removed (buffers are recreated when wiped)
local by_buf = {} -- buffer -> Chat
local augroup = api.nvim_create_augroup('agent-ide.chat', { clear = true })
local subscribed = false

local function drawer() return require('agent-ide.ui.drawer') end

local function valid_buf(b) return b ~= nil and api.nvim_buf_is_valid(b) and api.nvim_buf_is_loaded(b) end

-- Winbar ----------------------------------------------------------------------------------

local function winbar_text(c)
  local s = c.s
  local model, mode = require('agent-ide.ui.mode').labels(s)
  local parts = {
    c.project and c.project.name or '?',
    s.title and (s.title:gsub('[\r\n]+', ' ')) or 'new session',
    model,
    mode,
    require('agent-ide.ui.handoff').away(s) and 'in native Claude (tmux pane)' or drawer().state_of(s.id),
  }
  if #s.queue > 0 then parts[#parts + 1] = 'queued:' .. #s.queue end
  return (table.concat(parts, ' · '):gsub('%%', '%%%%'))
end

local function update_winbar(c)
  if valid_buf(c.tbuf) then history.set_winbar(c.tbuf, winbar_text(c)) end
end

-- Visibility -------------------------------------------------------------------------------

---`s.visible` is true exactly while the transcript is shown in a window of the current tab.
---@param gone_win? integer a window that is closing
---@param gone_buf? integer a buffer leaving its last window
local function update_visible(gone_win, gone_buf)
  local shown = {}
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if w ~= gone_win and api.nvim_win_is_valid(w) then shown[api.nvim_win_get_buf(w)] = true end
  end
  for _, c in pairs(chats) do
    local v = c.tbuf ~= nil and c.tbuf ~= gone_buf and shown[c.tbuf] == true
    if v ~= c.s.visible then
      c.s.visible = v
      if v then c.s:mark_seen() end
    end
  end
end

local function setup_autocmds()
  local function later() vim.schedule(function() update_visible() end) end
  api.nvim_create_autocmd({ 'BufWinEnter', 'TabEnter' }, { group = augroup, callback = function()
    update_visible()
    later()
  end })
  api.nvim_create_autocmd('BufWinLeave', { group = augroup, callback = function(ev)
    if by_buf[ev.buf] then update_visible(nil, ev.buf) end
    later()
  end })
  api.nvim_create_autocmd('WinClosed', { group = augroup, callback = function(ev)
    update_visible(tonumber(ev.match))
    later()
  end })
  api.nvim_create_autocmd('TabLeave', { group = augroup, callback = later })
end

-- Session changes ----------------------------------------------------------------------------

local function permission() return require('agent-ide.ui.permission') end

local function on_change(s, what)
  local c = chats[s.id]
  if c and (what == 'events' or what == 'delta' or what == 'permission') then
    if c.loading then
      c.dirty = true
    elseif c.view then
      c.view:sync(what)
    end
  end
  if what == 'permission' then
    drawer().refresh()
    permission().on_permission(s)
  elseif what == 'control_error' then
    require('agent-ide.ui.mode').control_error(s)
  elseif what == 'state' or what == 'meta' then
    if c then update_winbar(c) end
    drawer().refresh()
  end
end

local function subscribe()
  if subscribed then return end
  subscribed = true
  session.on_change(on_change)
  setup_autocmds()
  permission().setup()
end

-- Actions ----------------------------------------------------------------------------------

local function notify(msg, level) vim.notify(msg, level or vim.log.levels.INFO) end

---Send the prompt buffer's text. Held while the history loads, so the prompt lands below it.
local function send(c)
  if not valid_buf(c.pbuf) then return end
  local text = prompt.text_to_send(api.nvim_buf_get_lines(c.pbuf, 0, -1, false))
  if not text:find('%S') then return end
  if require('agent-ide.ui.handoff').away(c.s) then
    return notify('Agent-IDE: this session is open in native Claude (tmux pane); quit it there to continue here',
      vim.log.levels.WARN)
  end
  if c.loading then
    c.send_after_load = true
    return
  end
  local ok, reason = c.s:send(text)
  if ok then
    prompt.clear(c.pbuf)
  elseif reason == 'running elsewhere' then
    notify(ELSEWHERE, vim.log.levels.WARN)
  elseif reason ~= 'empty' then
    notify('Agent-IDE: ' .. tostring(reason), vim.log.levels.WARN)
  end
end

local function interrupt(c)
  c.send_after_load = false -- a send held for a load is cancelled; its text stays in the prompt
  local dropped = c.s:interrupt()
  if #dropped == 0 then return end
  if valid_buf(c.pbuf) then prompt.restore(c.pbuf, dropped) end
  notify(('Agent-IDE: interrupted; %d queued prompt(s) returned to the prompt buffer'):format(#dropped))
end

local get_chat

---Focus the prompt of `c` (reopening its window), optionally in insert mode.
local function focus_prompt(c, insert)
  get_chat(c.s) -- recreates a wiped prompt buffer
  local cur = api.nvim_get_current_win()
  if api.nvim_win_get_buf(cur) ~= c.pbuf then
    local twin = api.nvim_win_get_buf(cur) ~= c.tbuf and windows.showing(c.tbuf) or cur
    api.nvim_set_current_win(windows.show_prompt(c.pbuf, twin))
  end
  if insert then vim.cmd('startinsert') end
end

local ACT = { send = send, interrupt = interrupt, focus_prompt = focus_prompt }

local function map_keys(c, buf, is_transcript) chat_keys.map(c, buf, is_transcript, ACT) end

-- Buffers ----------------------------------------------------------------------------------

local function wipe(buf)
  if api.nvim_buf_is_valid(buf) then pcall(api.nvim_buf_delete, buf, { force = true }) end
end

-- `:bdelete`, `:bunload`, `:q!` (prompt) or `:bwipeout` on a chat buffer: an unloaded buffer
-- has lost its options, maps and lines, so it is forgotten and wiped (it holds the name the
-- next buffer needs) and a fresh one is made on the next open.
local function forget_on_unload(c, buf, field)
  api.nvim_create_autocmd('BufUnload', { group = augroup, buffer = buf, once = true, callback = function()
    by_buf[buf] = nil
    if c[field] == buf then
      c[field] = nil
      c.stale[field] = buf
    end
    if field == 'tbuf' and c.view then
      c.view:detach()
      c.view = nil
    end
    vim.schedule(function() wipe(buf) end)
  end })
end

-- Wipe a forgotten buffer now if its scheduled wipe has not run yet (it holds the name).
local function drop_stale(c, field)
  local old = c.stale[field]
  c.stale[field] = nil
  if old then wipe(old) end
end

---The chat of `s`, with both buffers; `fresh` when the transcript buffer was just created.
function get_chat(s, project)
  local c = chats[s.id]
  if not c then
    c = { s = s, loading = false, dirty = false, send_after_load = false, stale = {} }
    chats[s.id] = c
  end
  c.project = project or c.project
  local fresh = false
  if not valid_buf(c.tbuf) then
    drop_stale(c, 'tbuf')
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(buf, 'agent-ide://chat/' .. s.id)
    c.tbuf, c.view, fresh = buf, live_render.attach(buf, s), true
    by_buf[buf] = c
    map_keys(c, buf, true)
    forget_on_unload(c, buf, 'tbuf')
  end
  if not valid_buf(c.pbuf) then
    drop_stale(c, 'pbuf')
    local buf = prompt.create(s)
    c.pbuf = buf
    by_buf[buf] = c
    map_keys(c, buf, false)
    forget_on_unload(c, buf, 'pbuf')
  end
  return c, fresh
end

-- Opening ------------------------------------------------------------------------------------

---Load the history (reloads only when the file changed and no process runs), then bring the
---transcript up to date and send what the user sent meanwhile.
local function load(c, fresh)
  c.loading = true
  if fresh then
    c.dirty = true
    history.set_lines(c.tbuf, { 'Loading…' })
  end
  c.load_n = (c.load_n or 0) + 1
  local n = c.load_n
  c.s:load(function()
    if c.load_n ~= n then return end -- a newer open loads again
    c.loading = false
    if c.dirty and c.view then c.view:sync('reset') end
    c.dirty = false
    local path = c.s.path
    if #c.s.events == 0 and path and valid_buf(c.tbuf) and not vim.uv.fs_stat(path) then
      history.set_lines(c.tbuf, { 'Transcript not found: ' .. path })
    end
    if c.send_after_load then
      c.send_after_load = false
      send(c)
    end
  end)
end

---Continue the session in native Claude in a tmux pane; when that Claude exits, reload it from
---disk and show it (in place when it is on screen; opened when the user is in the Agents tab in
---normal mode; else a notice).
function ACT.native(c)
  require('agent-ide.ui.handoff').start(c.s, {
    away = function()
      update_winbar(c)
      drawer().refresh()
    end,
    back = function(s)
      if valid_buf(c.tbuf) and s.visible then
        load(c, false)
      elseif api.nvim_get_mode().mode == 'n' and api.nvim_get_current_tabpage() == drawer().state().tab then
        M.open(s, c.project)
      else
        notify('Agent-IDE: native Claude ended; the session is parked and can be opened from the drawer')
      end
      update_winbar(c)
      drawer().refresh()
    end,
  })
end

-- Public -------------------------------------------------------------------------------------

---Open the chat of session `s` in the Agents tab: transcript in the main window, prompt below
---(focused), then load the history.
---@param s table Session
---@param project table Project
function M.open(s, project)
  subscribe()
  local c, fresh = get_chat(s, project)
  local twin = windows.transcript()
  if api.nvim_win_get_buf(twin) ~= c.tbuf then api.nvim_win_set_buf(twin, c.tbuf) end
  update_winbar(c)
  history.apply_win(twin, c.tbuf)
  local pwin = windows.show_prompt(c.pbuf, twin)
  api.nvim_set_current_win(pwin)
  windows.tcd(twin, c.project)
  load(c, fresh)
  update_visible()
end

---Session of the chat view in the focused tab: the current window's chat, else the first
---transcript shown in this tab.
---@return table|nil Session
function M.current()
  local c = by_buf[api.nvim_get_current_buf()]
  if c then return c.s end
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    local b = api.nvim_win_get_buf(w)
    c = by_buf[b]
    if c and c.tbuf == b then return c.s end
  end
end

---Refresh the winbar of every chat shown in the current tab (e.g. after a live poll: the
---state of a session running elsewhere comes from the live map).
function M.refresh_winbars()
  for _, c in pairs(chats) do
    if c.s.visible then update_winbar(c) end
  end
end

---Session owning a chat buffer (transcript or prompt).
---@param buf integer
---@return table|nil Session
function M.session_of(buf)
  local c = by_buf[buf]
  return c and c.s
end

---Transcript and prompt buffers of the chat of `s` (nil when it has none).
---@param s table Session
---@return integer|nil tbuf, integer|nil pbuf
function M.buffers(s)
  local c = chats[s.id]
  if not c then return nil, nil end
  return valid_buf(c.tbuf) and c.tbuf or nil, valid_buf(c.pbuf) and c.pbuf or nil
end

---Project the chat of `s` was opened with, else the drawer's project listing it, else one made
---from its folder.
---@param s table Session
---@return table Project
function M.project_of(s)
  local c = chats[s.id]
  if c and c.project then return c.project end
  for _, p in ipairs(drawer().state().projects or {}) do
    for _, m in ipairs(p.sessions or {}) do
      if m.id == s.id then return p end
    end
  end
  return { key = s.cwd, name = vim.fn.fnamemodify(s.cwd or '?', ':t'), root = s.cwd, sessions = {} }
end

---Chat windows (tests): { transcript = win|nil, prompt = win|nil }, only those still valid.
function M._windows()
  return windows.get()
end

return M

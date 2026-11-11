-- The chat view: a session's transcript in the Agents tab's main window and its prompt buffer
-- in a split below. Both buffers belong to the session and are reused; the two windows are
-- reused for whichever session is opened. Session events only update buffers, the winbar and
-- the drawer: they never move focus or open a window.
local api = vim.api
local chat_keys = require('agent-ide.ui.chat_keys')
local bufname = require('agent-ide.ui.bufname')
local history = require('agent-ide.ui.history')
local live_render = require('agent-ide.transcript.live')
local prompt = require('agent-ide.ui.prompt')
local windows = require('agent-ide.ui.chat_win')
local session = require('agent-ide.session')

local M = {}

local function elsewhere_msg()
  return 'Agent-IDE: session is running in another Claude; use '
    .. require('agent-ide.util.keys').first('drawer', 'tmux') .. ' in the drawer to jump to it'
end

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

-- `<mark> <state word>` in the drawer's colours (its marks, groups and words), `· project`
-- (bold) `· title` (cut with … to fit), then right-aligned the model (italic) and the
-- permission mode as a badge (a mode other than the default one stands out). Every `%` of the
-- text is escaped; widths are display widths, and the whole fits the window: what matters
-- least gives way first.
local SEP = ' · '

local function esc(t) return (t:gsub('%%', '%%%%')) end

local function seg(group, text) return '%#' .. group .. '#' .. esc(text) .. '%*' end

local function one_line(t) return (tostring(t or ''):gsub('[\r\n\t]+', ' ')) end

-- Mark, word and their groups, as the drawer's session row shows them (`tree.lua`).
local function state_parts(s)
  local model = require('agent-ide.ui.drawer_model')
  local state = model.state_of(s.id)
  local group = require('agent-ide.ui.tree').STATE_GROUP[state] or 'AgentIdeAge'
  local icons = require('agent-ide.config').get().icons or {}
  local note = model.note_of(s.id, state)
  local word, word_group = state, group
  if note and note[1] and note[1] ~= '' then word, word_group = one_line(note[1]), note[2] or group end
  return { mark = icons[state] or '', group = group, word = word, word_group = word_group }
end

-- The default mode (`manual`, or `claude.default_mode` when set) or none: no badge colour.
local function quiet_mode(m)
  if m == nil or m == 'manual' then return true end
  local c = require('agent-ide.config').get().claude
  return type(c) == 'table' and m == c.default_mode
end

---The winbar of the chat of `s` (statusline syntax) for a window `width` columns wide.
---@param s table Session
---@param project table|nil
---@param width integer
---@return string
local function winbar_text(s, project, width)
  local st = state_parts(s)
  local model_label, mode_label = require('agent-ide.ui.mode').labels(s)
  -- the model it runs with, else the one it would start with here; none for a session another
  -- Claude runs (elsewhere, native: nothing starts here)
  local away = not s.model and (s:_elsewhere() or require('agent-ide.ui.handoff').away(s))
  local model = not away and one_line(model_label) or nil
  local mode = (s.mode or s.mode_requested) and ('[' .. mode_label:gsub('^mode:', '') .. ']') or nil
  local hot = mode and not (quiet_mode(s.mode) and quiet_mode(s.mode_requested))
  local queued = #s.queue > 0 and ('queued:' .. #s.queue) or nil
  local name = one_line(project and project.name or '?')
  local title = one_line(s.title or 'new session')
  local W = vim.fn.strdisplaywidth
  local truncate = require('agent-ide.ui.layout').truncate
  local function lw()
    local n = (st.mark ~= '' and W(st.mark) + 1 or 0) + W(st.word) + (queued and W(SEP) + #queued or 0)
    if name ~= '' then n = n + W(SEP) + W(name) end
    return n
  end
  local function rw()
    if not model and not mode then return 0 end
    return 1 + (model and W(model) or 0) + (model and mode and 1 or 0) + (mode and W(mode) or 0)
  end
  -- the title takes what is left; without room for it the model, the queue count, the badge
  -- and last the state word give way, and the project gets what remains
  local room = width - lw() - rw() - W(SEP)
  title = room >= 2 and truncate(title, room) or nil
  if not title and lw() + rw() > width then
    local full = name
    name = ''
    if lw() + rw() > width then model = nil end
    if lw() + rw() > width then queued = nil end
    if lw() + rw() > width then mode = nil end
    if lw() + rw() > width then
      local keep = width - (st.mark ~= '' and W(st.mark) + 1 or 0)
      st.word = truncate(st.word, math.max(0, keep))
    end
    local spare = width - lw() - rw() - W(SEP)
    if full ~= '' and spare >= 2 then name = truncate(full, spare) end
  end
  local out = {}
  if st.mark ~= '' then out[#out + 1] = seg(st.group, st.mark) .. ' ' end
  out[#out + 1] = seg(st.word_group, st.word)
  if queued then out[#out + 1] = SEP .. esc(queued) end
  if name ~= '' then out[#out + 1] = SEP .. seg('AgentIdeProject', name) end
  if title then out[#out + 1] = SEP .. esc(title) end
  if model or mode then
    out[#out + 1] = '%='
    if model then out[#out + 1] = seg('AgentIdeModel', model) end
    if mode then out[#out + 1] = (model and ' ' or '') .. seg(hot and 'AgentIdeModeHot' or 'AgentIdeMode', mode) end
  end
  return table.concat(out)
end

-- Every window showing the transcript gets the winbar for its width.
local function update_winbar(c)
  bufname.refresh(c.s) -- the buffer names follow the title as the winbar does
  if not valid_buf(c.tbuf) then return end
  local wins = vim.fn.win_findbuf(c.tbuf)
  local first = wins[1] and api.nvim_win_get_width(wins[1]) or vim.o.columns
  history.set_winbar(c.tbuf, winbar_text(c.s, c.project, first))
  for i = 2, #wins do
    api.nvim_set_option_value('winbar', winbar_text(c.s, c.project, api.nvim_win_get_width(wins[i])),
      { scope = 'local', win = wins[i] })
  end
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
  -- the winbar fits its window: computed again for a transcript window that changed size
  api.nvim_create_autocmd('WinResized', { group = augroup, callback = function()
    local seen = {}
    for _, w in ipairs(vim.v.event.windows or {}) do
      local c = api.nvim_win_is_valid(w) and by_buf[api.nvim_win_get_buf(w)]
      if c and c.tbuf == api.nvim_win_get_buf(w) and not seen[c] then
        seen[c] = true
        update_winbar(c)
      end
    end
  end })
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
    if what == 'state' then drawer().live_policy() end
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

---End the pre-send live check of `c` (its answer, a timeout, a cancel): the timer is stopped and
---closed, a late answer finds `check_n` changed and does nothing.
local function end_check(c)
  c.check_n = (c.check_n or 0) + 1
  c.checking = false
  local t = c.check_timer
  c.check_timer = nil
  if t then
    t:stop()
    if not t:is_closing() then t:close() end
  end
end

---Cancel a running check; the prompt text stays, `why` says so when the chat is still open.
local function cancel_check(c, why)
  if not c.checking then return end
  end_check(c)
  if why and valid_buf(c.pbuf) then notify(why, vim.log.levels.WARN) end
end

---Send the prompt buffer's text. Held while the history loads, so the prompt lands below it.
local function send(c)
  if not valid_buf(c.pbuf) then return end
  local text = prompt.text_to_send(api.nvim_buf_get_lines(c.pbuf, 0, -1, false))
  if not text:find('%S') then return end
  -- `/model`, `/copy` alone: the plugin's own commands, nothing is sent to Claude
  local own = prompt.plugin_command(text)
  if own then
    prompt.clear(c.pbuf)
    return own(c.s)
  end
  if require('agent-ide.ui.handoff').away(c.s) then
    return notify('Agent-IDE: this session is open in native Claude (tmux pane); quit it there to continue here',
      vim.log.levels.WARN)
  end
  if c.loading then
    c.send_after_load = true
    return
  end
  -- A send that starts Claude for a session not alive here first asks `claude agents` afresh
  -- (the cached map may be old): two Claudes must never drive one session. The text stays in
  -- the prompt meanwhile (typing goes on); what the prompt holds when the answer comes is sent.
  -- (A session the polled map lists as elsewhere is refused at once, below.)
  if not c.live_checked and c.s:needs_start() and not c.s:_elsewhere() then
    if c.checking then return end -- one question at a time; the answer sends the prompt
    c.checking = true
    local tick = api.nvim_buf_get_changedtick(c.pbuf)
    local pbuf = c.pbuf
    c.check_n = (c.check_n or 0) + 1
    local n = c.check_n
    local cfg = require('agent-ide.config').get()
    -- One timer: after 300 ms a check still running says so; then it waits out the live command
    -- (killed after max(interval, 2 s)) plus 2 s, so a callback that never comes cannot leave the
    -- chat stuck.
    local limit = math.max(cfg.live.interval_ms, 2000) + 2000
    local guard = vim.uv.new_timer()
    c.check_timer = guard
    guard:start(300, 0, vim.schedule_wrap(function()
      if c.check_n ~= n then return end
      notify('Agent-IDE: checking where this session runs…')
      guard:start(limit - 300, 0, vim.schedule_wrap(function()
        if c.check_n ~= n then return end
        cancel_check(c, 'Agent-IDE: could not tell where this session runs (no answer); send again')
      end))
    end))
    require('agent-ide.live').query({ cmd = cfg.live.cmd, interval_ms = cfg.live.interval_ms }, function()
      if c.check_n ~= n then return end -- cancelled or timed out meanwhile
      local unchanged = c.pbuf == pbuf and valid_buf(pbuf) and api.nvim_buf_get_changedtick(pbuf) == tick
      end_check(c)
      -- the prompt moved on while the question ran: what it holds now was never meant to go
      if not unchanged then
        if not valid_buf(c.pbuf) then return end
        if c.s:_elsewhere() then return notify(elsewhere_msg(), vim.log.levels.WARN) end
        notify('Agent-IDE: not sent: the prompt changed while checking; send again', vim.log.levels.WARN)
        return
      end
      -- a failed question leaves the cached map to decide, as without the drawer
      c.live_checked = true
      local ok, err = pcall(send, c)
      c.live_checked = false
      if not ok then error(err, 0) end
    end)
    return
  end
  local ok, reason = c.s:send(text)
  if ok then
    prompt.clear(c.pbuf)
  elseif reason == 'running elsewhere' then
    notify(elsewhere_msg(), vim.log.levels.WARN)
  elseif reason ~= 'empty' then
    notify('Agent-IDE: ' .. tostring(reason), vim.log.levels.WARN)
  end
end

local function interrupt(c)
  c.send_after_load = false -- a send held for a load is cancelled; its text stays in the prompt
  cancel_check(c, 'Agent-IDE: not sent: interrupted while checking; send again')
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
    end_check(c) -- a pending live check (and its timer) goes with the chat
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
    vim.b[buf].agent_ide_kind, vim.b[buf].agent_ide_session = 'chat', s.id
    bufname.track(buf, s, '', function() return M.project_of(s) end)
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

---Continue the session in native Claude in a tmux pane (again while it is away: take it back).
---When it is back, reload it from disk in the background: never a focus or mode change; a chat
---on screen is refreshed in place, otherwise a notice says it is back.
function ACT.native(c)
  require('agent-ide.ui.handoff').start(c.s, {
    away = function()
      update_winbar(c)
      drawer().refresh()
    end,
    back = function(s)
      if valid_buf(c.tbuf) then load(c, false) else s:load() end
      if not s.visible then
        notify(('Agent-IDE: %s is back from native Claude'):format(s.title and (s.title:gsub('[\r\n]+', ' ')) or 'the session'))
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
  local queue = package.loaded['agent-ide.ui.queue']
  if queue then queue.follow(s) end -- an open queue panel shows this session now
end

---Focus the prompt of the chat of `s` (its window reopened when hidden), optionally in insert
---mode. Does nothing when `s` has no chat yet.
---@param s table Session
---@param insert boolean
function M.focus_prompt(s, insert)
  if chats[s.id] then focus_prompt(chats[s.id], insert) end
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

---Interrupt the running turn of `s` as its chat's interrupt key does (queued prompts go back to
---its prompt buffer).
---@param s table Session
function M.interrupt(s)
  if chats[s.id] then return interrupt(chats[s.id]) end
  s:interrupt()
end

---Continue `s` in native Claude in a tmux pane as its chat's key does (again: take it back),
---without showing its chat.
---@param s table Session
---@param project table Project
function M.native(s, project)
  subscribe()
  ACT.native((get_chat(s, project)))
end

---Park `s`: stop the Claude process this Neovim runs for it (asking first when it works). Queued
---prompts it drops go back to its prompt buffer, as after an interrupt. The transcript stays;
---the next send resumes the session. A session without a process here gets a notice.
---@param s table Session
function M.park(s)
  if not s.owned then
    local why = s:_elsewhere() and 'it runs in another Claude' or 'it is not running in this Neovim'
    return notify('Agent-IDE: nothing to park; ' .. why)
  end
  local pc = chats[s.id]
  if pc then cancel_check(pc, 'Agent-IDE: not sent: the session was parked while checking; send again') end
  s:park(function(parked, dropped)
    if not parked then return end
    local c = chats[s.id]
    if dropped and #dropped > 0 and c and valid_buf(c.pbuf) then
      prompt.restore(c.pbuf, dropped)
      notify(('Agent-IDE: parked; %d queued prompt(s) returned to the prompt buffer'):format(#dropped))
    end
    if c then update_winbar(c) end
    drawer().refresh()
  end)
end

---Open the next (`offset` 1) or previous (-1) session of the project of `s`, in the drawer's
---order, skipping hidden sessions and wrapping around. Focus stays in the window the key was
---pressed in (transcript or prompt), so the next press steps again; the drawer's cursor follows.
---@param s table Session
---@param offset integer
function M.cycle(s, offset)
  local in_prompt = chats[s.id] ~= nil and api.nvim_get_current_buf() == chats[s.id].pbuf
  local p = M.project_of(s)
  for _, dp in ipairs(drawer().state().projects or {}) do
    if dp.key == p.key then p = dp break end -- the drawer's latest scan: its order
  end
  local m = require('agent-ide.ui.drawer_model').neighbor(p.sessions or {}, s.id, offset, require('agent-ide.hidden').is)
  if not m then return notify('Agent-IDE: no other session in ' .. (p.name or '?')) end
  M.open(session.open({ id = m.id, cwd = m.cwd or p.root or p.key, path = m.path, title = m.title }), p)
  -- open() leaves the prompt focused
  if not in_prompt then api.nvim_set_current_win(windows.transcript()) end
  drawer().reveal(m.id, p.key)
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

---Chats by session id (tests).
function M._chats() return chats end

---The winbar of session `s` in `project` for a window `width` columns wide (tests).
function M._winbar(s, project, width) return winbar_text(s, project, width) end

---Chat windows (tests): { transcript = win|nil, prompt = win|nil }, only those still valid.
function M._windows()
  return windows.get()
end

return M

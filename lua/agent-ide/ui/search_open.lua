-- What the search picker does with a hit: open the session's chat on the hit's line (the query
-- highlighted there, see `ui/search_hl.lua`), copy the hit's text, put a prompt back into the
-- chat prompt. Also the project grouping the picker shows and scopes by (the drawer's, else one
-- made from a scan).
local api = vim.api
local locate = require('agent-ide.transcript.locate')

local M = {}

M._wait_ms = 10000 -- how long opening waits for the history to load

local EVENT_KIND = { prompt = 'prompt', answer = 'text', tool = 'tool_call' }

local function notify(msg, level) vim.notify('Agent-IDE: ' .. msg, level or vim.log.levels.INFO) end

local function maps(projects)
  local by_cwd, by_id = {}, {}
  for _, p in ipairs(projects) do
    for _, s in ipairs(p.sessions or {}) do
      by_id[s.id] = p
      if s.cwd then by_cwd[s.cwd] = p.name end
    end
  end
  return { projects = projects, by_cwd = by_cwd, by_id = by_id }
end

---Project grouping: the drawer's when it has one, else grouped from a scan (asynchronous).
---@param cb fun(m: { projects: table[], by_cwd: table<string, string>, by_id: table<string, table> })
function M.projects(cb)
  local shown = require('agent-ide.ui.drawer').state().projects or {}
  if #shown > 0 then return cb(maps(shown)) end
  require('agent-ide.index').scan(function(sessions)
    cb(maps(require('agent-ide.project').group(sessions)))
  end)
end

-- What a snippet shows of a text: control characters (newlines, tabs) as spaces.
local function flat(t) return (t:gsub('%c', ' ')) end

local function holds(ev, want, probe)
  if ev.kind ~= want or ev.sidechain then return false end
  if want == 'tool_call' then return vim.startswith(probe, tostring(ev.name) .. ':') end
  return type(ev.text) == 'string' and flat(ev.text):find(probe, 1, true) ~= nil
end

---Index in `events` (which start at event number `first`, default 1) of the event of `hit`:
---the indexed one when its kind fits and its text holds the snippet; else (the transcript
---changed since it was indexed) the first event of that kind whose text holds it; else nil.
function M.event_index(events, hit, first)
  first = first or 1
  local want = EVENT_KIND[hit.kind]
  if not hit.event or not want then return nil end
  local probe = (hit.snippet or ''):gsub('^…', ''):gsub('…$', '')
  if probe == '' then return nil end
  local i = hit.event - first + 1
  if events[i] and holds(events[i], want, probe) then return i end
  for k, ev in ipairs(events) do
    if holds(ev, want, probe) then return k end
  end
end

-- The query's highlights in the transcript window `twin` (see `search_hl.attach`); returns the
-- occurrence to put the cursor on: the first one in the hit's event (lines `from`..`to`) of a
-- word the hit's row does not show, else of any word, else nil.
local function highlight(twin, tbuf, hit, query, from, to)
  local hl = require('agent-ide.ui.search_hl')
  if not query or not query:find('%S') then return hl.clear(twin) end
  local lines = api.nvim_buf_get_lines(tbuf, 0, -1, false)
  local terms = hl.terms(query, hit, lines)
  local occ = hl.occurrences(lines, terms, from, to)
  local i = hl.pick(occ, from)
  local o = i and occ[i]
  local k = require('agent-ide.ui.search_keys').keys()
  hl.attach(twin, terms, o, { next = k.next_match, prev = k.prev_match })
  return o
end

-- `focus`: the window focused right after opening; focus moves to the transcript only while it
-- is still focused (the user may have gone on meanwhile).
local function place(s, tbuf, hit, focus, query)
  local twin = require('agent-ide.ui.chat_win').showing(tbuf)
  if not twin then return end
  local i = M.event_index(s.events, hit)
  if hit.kind == 'title' then
    -- a title stands for the session: its first prompt
    for k, ev in ipairs(s.events) do
      if require('agent-ide.transcript.render').starts_turn(ev) then i = k; break end
    end
  end
  if hit.event and not i then notify('the transcript changed since it was indexed; showing the session', vim.log.levels.WARN) end
  local line = i and locate.line(s.events, i) or 1
  local n = api.nvim_buf_line_count(tbuf)
  line = math.max(1, math.min(line, n))
  -- the event ends where the next one starts
  local last = n
  if i and i < #s.events then last = math.max(line, math.min(n, (locate.line(s.events, i + 1) or n + 1) - 1)) end
  local o = highlight(twin, tbuf, hit, query, line, last)
  if api.nvim_get_current_win() == focus then api.nvim_set_current_win(twin) end
  api.nvim_win_set_cursor(twin, o and { o.line, o.s } or { line, 0 })
  api.nvim_win_call(twin, function() vim.cmd('normal! zvzz') end)
end

---Open the chat of the hit's session in the Agents tab, the cursor on the hit's event (its fold
---opened). The line comes from the renderer (`transcript.locate`), once the history is loaded.
---@param hit table
---@param m? table `projects()` result
---@param query? string the search: its words are highlighted in the transcript window
function M.open(hit, m, query)
  if not vim.uv.fs_stat(hit.path) then
    return notify('this session no longer exists: ' .. vim.fn.fnamemodify(hit.path, ':t'), vim.log.levels.WARN)
  end
  local drawer = require('agent-ide.ui.drawer')
  local chat = require('agent-ide.ui.chat')
  local st = drawer.state()
  if not st.tab then
    require('agent-ide').toggle()
  elseif api.nvim_get_current_tabpage() ~= st.tab then
    api.nvim_set_current_tabpage(st.tab)
  end
  local session = require('agent-ide.session')
  local p = m and m.by_id[hit.session]
  local s = session.open({ id = hit.session, cwd = hit.cwd or (p and (p.root or p.key)), path = hit.path, title = hit.title })
  chat.open(s, p or chat.project_of(s))
  local tbuf = chat.buffers(s)
  local focus = api.nvim_get_current_win()
  local deadline = vim.uv.now() + M._wait_ms
  local timer = vim.uv.new_timer()
  timer:start(0, 20, vim.schedule_wrap(function()
    if timer:is_closing() then return end
    local ready = (s.loaded_key ~= nil or s:_alive()) and tbuf and api.nvim_buf_is_valid(tbuf)
      and api.nvim_buf_get_lines(tbuf, 0, 1, false)[1] ~= 'Loading…'
    if ready or vim.uv.now() > deadline then
      timer:stop()
      timer:close()
      if ready then place(s, tbuf, hit, focus, query) end
    end
  end))
end

---The prompt buffer of the chat view in the Agents tab, when it is shown.
---@return integer|nil buf, integer|nil win
function M.prompt_target()
  local w = require('agent-ide.ui.chat_win').get().prompt
  local tab = require('agent-ide.ui.drawer').state().tab
  if w and tab and api.nvim_win_get_tabpage(w) == tab then return api.nvim_win_get_buf(w), w end
end

---Put `text` into the chat prompt (below what is there, after a blank line) and focus it.
---@return boolean done
function M.reuse(text)
  local buf, win = M.prompt_target()
  if not buf then return false end
  local lines = require('agent-ide.ui.prompt').put(buf, vim.split(text, '\n', { plain = true }), 'below')
  if api.nvim_get_current_tabpage() ~= api.nvim_win_get_tabpage(win) then
    api.nvim_set_current_tabpage(api.nvim_win_get_tabpage(win))
  end
  api.nvim_set_current_win(win)
  api.nvim_win_set_cursor(win, { #lines, #lines[#lines] })
  return true
end

---Copy `text` to the clipboard register (`+` when Neovim has a clipboard) and to `"`.
function M.copy(text)
  vim.fn.setreg('"', text)
  if vim.fn.has('clipboard') == 1 then pcall(vim.fn.setreg, '+', text) end
  notify(('copied %d characters'):format(vim.fn.strchars(text)))
end

return M

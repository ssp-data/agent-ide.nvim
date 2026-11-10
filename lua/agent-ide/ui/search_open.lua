-- What the search picker does with a hit: open the session's chat on the hit's line, copy the
-- hit's text, put a prompt back into the chat prompt. Also the project grouping the picker
-- shows and scopes by (the drawer's, else one made from a scan).
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

---The event of `hit` in `events`: its index when the kind still fits, else (the transcript
---changed since it was indexed) the first event of that kind whose text holds the snippet, else nil.
function M.event_index(events, hit)
  local i, want = hit.event, EVENT_KIND[hit.kind]
  if not i or not want then return nil end
  if events[i] and events[i].kind == want then return i end
  local probe = (hit.snippet or ''):gsub('^…', ''):gsub('…$', '')
  if probe == '' or want == 'tool_call' then return nil end
  for k, ev in ipairs(events) do
    if ev.kind == want and not ev.sidechain and type(ev.text) == 'string' and ev.text:find(probe, 1, true) then
      return k
    end
  end
end

-- `focus`: the window focused right after opening; focus moves to the transcript only while it
-- is still focused (the user may have gone on meanwhile).
local function place(s, tbuf, hit, focus)
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
  line = math.max(1, math.min(line, api.nvim_buf_line_count(tbuf)))
  if api.nvim_get_current_win() == focus then api.nvim_set_current_win(twin) end
  api.nvim_win_set_cursor(twin, { line, 0 })
  api.nvim_win_call(twin, function() vim.cmd('normal! zvzz') end)
end

---Open the chat of the hit's session in the Agents tab, the cursor on the hit's event (its fold
---opened). The line comes from the renderer (`transcript.locate`), once the history is loaded.
---@param hit table
---@param m? table `projects()` result
function M.open(hit, m)
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
      if ready then place(s, tbuf, hit, focus) end
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
  local new = vim.split(text, '\n', { plain = true })
  local cur = api.nvim_buf_get_lines(buf, 0, -1, false)
  local lines = (#cur == 1 and cur[1] == '') and new or vim.list_extend(vim.list_extend(cur, { '' }), new)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
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

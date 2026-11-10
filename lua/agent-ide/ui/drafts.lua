-- Drafts of prompt buffers, kept on disk so nothing typed is lost when a prompt is closed by
-- accident or Neovim dies: stdpath('state')/agent-ide/drafts/<session id>.md, 0600 in a 0700
-- folder, written atomically half a second after the text changed and when the buffer, insert
-- mode or Neovim is left. The file goes with a successful send, with `:q!` (the explicit
-- discard: the buffer is unloaded) and with a deleted session. A draft comes back when the
-- session's prompt is created; `+ New session` takes over the newest draft of an unsent new
-- session of its project that an earlier Neovim left behind (`adopt`).
--
-- The file is readable by hand: a small frontmatter, then the text as typed:
--   ---
--   agent-ide: draft
--   session: <id>
--   cwd: <project folder>
--   saved: <time>
--   ---
--   <text>
local api = vim.api
local jsonfile = require('agent-ide.util.jsonfile')

local M = {}

M.DELAY_MS = 500
local FILE_MODE, DIR_MODE = 384, 448 -- 0600, 0700

local bufs = {} -- prompt buffer -> { s = Session, timer = uv_timer|nil }
local quitting = false

local function dir() return vim.fn.stdpath('state') .. '/agent-ide/drafts' end

---The draft file of session `id`.
---@param id string
---@return string
function M.path(id) return dir() .. '/' .. id .. '.md' end

local function notify(msg) vim.notify('Agent-IDE: ' .. msg, vim.log.levels.INFO) end

---The text of draft file `path` with its header, or nil when there is none or it is not a draft.
---@param path string
---@return { session: string|nil, cwd: string|nil, saved: string|nil, text: string }|nil
function M.read(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local raw = f:read('a')
  f:close()
  if not raw or not vim.startswith(raw, '---\nagent-ide: draft\n') then return nil end
  local close = raw:find('\n---\n', 4, true)
  if not close then return nil end
  local out = { text = raw:sub(close + 5):gsub('\n$', '') }
  for line in raw:sub(1, close):gmatch('[^\n]+') do
    local k, v = line:match('^(%w+): (.*)$')
    if k == 'session' or k == 'cwd' or k == 'saved' then out[k] = v end
  end
  return out
end

local function serialize(s, text)
  return table.concat({ '---', 'agent-ide: draft', 'session: ' .. s.id, 'cwd: ' .. tostring(s.cwd or ''),
    'saved: ' .. os.date('%Y-%m-%dT%H:%M:%S'), '---', text }, '\n') .. '\n'
end

local function remove(id)
  local p = M.path(id)
  if vim.uv.fs_stat(p) then vim.uv.fs_unlink(p) end
end

---Write the draft of `buf` now: its text when it holds any, else the file goes. Nothing while
---the buffer shows a prompt from the history (the draft is kept by ui/prompt.lua meanwhile).
---@param buf integer
function M.flush(buf)
  local st = bufs[buf]
  if not st or not api.nvim_buf_is_valid(buf) then return end
  if st.timer then st.timer:stop() end
  if require('agent-ide.ui.prompt').browsing(buf) then return end
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = table.concat(lines, '\n')
  if not text:find('%S') then return remove(st.s.id) end
  if text == st.written then return end
  local d = dir()
  if vim.fn.isdirectory(d) ~= 1 then pcall(vim.fn.mkdir, d, 'p', DIR_MODE) end
  local ok, err = jsonfile.write_atomic(M.path(st.s.id), serialize(st.s, text), FILE_MODE)
  if ok then
    st.written = text
  elseif not st.warned then
    st.warned = true
    vim.notify('Agent-IDE: cannot keep the draft on disk: ' .. tostring(err), vim.log.levels.WARN)
  end
end

local function schedule(buf)
  local st = bufs[buf]
  if not st then return end
  if not st.timer then st.timer = vim.uv.new_timer() end
  st.timer:stop()
  st.timer:start(M.DELAY_MS, 0, vim.schedule_wrap(function() M.flush(buf) end))
end

---Forget the draft of `buf` (a successful send): the file goes.
---@param buf integer
function M.clear(buf)
  local st = bufs[buf]
  if not st then return end
  if st.timer then st.timer:stop() end
  st.written = nil
  remove(st.s.id)
end

---Keep the draft of prompt buffer `buf` of session `s` on disk, and bring a kept one back now
---(the buffer is new and empty).
---@param buf integer
---@param s table Session
function M.attach(buf, s)
  bufs[buf] = { s = s }
  local group = api.nvim_create_augroup('agent-ide.drafts.' .. buf, { clear = true })
  api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'TextChangedP' }, { group = group, buffer = buf,
    callback = function() schedule(buf) end })
  api.nvim_create_autocmd({ 'InsertLeave', 'BufLeave', 'WinLeave' }, { group = group, buffer = buf,
    callback = function() M.flush(buf) end })
  -- unloaded on purpose (`:q!`, `:bdelete`, a deleted session): the draft goes with it; at exit
  -- every buffer is unloaded, then it stays
  api.nvim_create_autocmd('BufUnload', { group = group, buffer = buf, once = true, callback = function()
    if not quitting then M.clear(buf) end
    local st = bufs[buf]
    if st and st.timer then st.timer:stop() end
    bufs[buf] = nil
    pcall(api.nvim_del_augroup_by_id, group)
  end })
  local kept = M.read(M.path(s.id))
  if kept and kept.text:find('%S') then
    local lines = vim.split(kept.text, '\n', { plain = true })
    require('agent-ide.ui.prompt').put(buf, lines, 'replace')
    bufs[buf].written = kept.text
    notify(('draft restored (%d line%s)'):format(#lines, #lines == 1 and '' or 's'))
  end
end

---`+ New session`: the newest draft of an unsent new session of project folder `cwd` that no
---longer belongs to anything (`known(id)` is false: not listed, not open here) is moved to the
---new session `s`, so its prompt starts with it. Returns true when one was taken over.
---@param s table the new Session
---@param cwd string
---@param known fun(id: string): boolean
---@return boolean
function M.adopt(s, cwd, known)
  local best, best_at
  if vim.fn.isdirectory(dir()) ~= 1 then return false end
  for name, kind in vim.fs.dir(dir()) do
    local id = kind == 'file' and name:match('^(.+)%.md$')
    if id and id ~= s.id and not known(id) then
      local d = M.read(M.path(id))
      if d and d.cwd == cwd and d.text:find('%S') and (not best_at or (d.saved or '') > best_at) then
        best, best_at = id, d.saved or ''
      end
    end
  end
  if not best then return false end
  local d = M.read(M.path(best))
  local ok = jsonfile.write_atomic(M.path(s.id), serialize(s, d.text), FILE_MODE)
  if not ok then return false end
  remove(best)
  return true
end

-- At exit the buffers are unloaded before VimLeavePre: ExitPre is where the drafts are written.
api.nvim_create_autocmd({ 'ExitPre', 'VimLeavePre' }, { group = api.nvim_create_augroup('agent-ide.drafts', { clear = true }),
  callback = function()
    quitting = true
    for buf in pairs(bufs) do M.flush(buf) end
  end })

---Test only.
function M._state(buf) return bufs[buf] and { written = bufs[buf].written } or nil end
M._dir = dir

return M

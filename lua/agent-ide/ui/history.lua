-- Read-only markdown view of one session transcript, with folds from the renderer.
local api = vim.api
local config = require('agent-ide.config')
local index = require('agent-ide.index')
local live = require('agent-ide.live')
local render = require('agent-ide.transcript.render')

local M = {}

local augroup = api.nvim_create_augroup('agent-ide.history', { clear = true })

-- Per history buffer: { levels = string[], mtime, size, token, winbar }
local bufs = {}

---Fold level of line `lnum` in the current buffer; '0' for buffers this module does not know.
---@param lnum integer
---@return string
function M.foldexpr(lnum)
  local b = bufs[api.nvim_get_current_buf()]
  return b and b.levels and b.levels[lnum] or '0'
end

local WIN_OPTS = {
  wrap = true,
  linebreak = true,
  foldmethod = 'expr',
  foldexpr = "v:lua.require'agent-ide.ui.history'.foldexpr(v:lnum)",
  foldlevel = 0,
  foldtext = '',
  foldenable = true,
}

local function apply_win(win, buf)
  for name, value in pairs(WIN_OPTS) do
    api.nvim_set_option_value(name, value, { scope = 'local', win = win })
  end
  local b = bufs[buf]
  api.nvim_set_option_value('winbar', b and b.winbar or '', { scope = 'local', win = win })
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

---Apply window options and put the cursor on the last line in every window showing `buf`;
---`reset_folds` re-applies 'foldlevel' (closes all folds) after new content.
local function refresh_windows(buf, reset_folds)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    apply_win(win, buf)
    if reset_folds then api.nvim_win_call(win, function() vim.cmd('silent! normal! zX') end) end
    api.nvim_win_set_cursor(win, { api.nvim_buf_line_count(buf), 0 })
  end
end

---Make `buf` a read-only transcript buffer whose windows fold with the levels from `set_folds`.
---Idempotent.
---@param buf integer
function M.setup_buf(buf)
  if bufs[buf] then return end
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].undolevels = -1
  vim.bo[buf].modifiable = false
  bufs[buf] = { levels = {} }
  -- set after the filetype so a markdown ftplugin cannot override the fold options
  vim.bo[buf].filetype = 'markdown'
  api.nvim_create_autocmd('BufWinEnter', { group = augroup, buffer = buf,
    callback = function(ev) apply_win(api.nvim_get_current_win(), ev.buf) end })
  api.nvim_create_autocmd('BufWipeout', { group = augroup, buffer = buf,
    callback = function(ev) bufs[ev.buf] = nil end })
end

---Store the per-line fold levels (as from `render.fold_levels`) read by `foldexpr` for `buf`.
---The table is kept by reference: a caller may update it in place before changing lines.
---@param buf integer
---@param levels string[]
function M.set_folds(buf, levels)
  M.setup_buf(buf)
  bufs[buf].levels = levels
end

---Stored fold levels of `buf` (tests).
function M._levels(buf)
  return bufs[buf] and bufs[buf].levels
end

local function get_buf(session)
  local name = 'agent-ide://history/' .. session.id
  local buf = vim.fn.bufnr(name)
  if buf > 0 and bufs[buf] then return buf end
  if buf <= 0 then
    buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(buf, name)
  end
  M.setup_buf(buf)
  return buf
end

local function load(buf, path, st)
  local b = bufs[buf]
  b.mtime, b.size = { st.mtime.sec, st.mtime.nsec }, st.size
  b.token = (b.token or 0) + 1
  local token = b.token
  b.levels = {}
  set_lines(buf, { 'Loading…' })
  index.history(path, function(events)
    if not api.nvim_buf_is_valid(buf) or bufs[buf] ~= b or b.token ~= token then return end
    local out = render.render(events)
    b.levels = render.fold_levels(out.folds, #out.lines)
    set_lines(buf, out.lines)
    refresh_windows(buf, true)
  end)
end

local function winbar(session, project)
  local state = live.state_of(live.get(), session.id)
  local text = table.concat({ project.name or '?', (session.title or ''):gsub('[\r\n]', ' '), state, 'history (read-only)' }, ' · ')
  return (text:gsub('%%', '%%%%'))
end

---Show the history of `session` in the main window of the Agents tab.
---@param session table SessionMeta
---@param project table Project
function M.open(session, project)
  local win = require('agent-ide.ui.drawer').main_win() or api.nvim_get_current_win()
  local buf = get_buf(session)
  local b = bufs[buf]
  b.winbar = winbar(session, project)
  local st = vim.uv.fs_stat(session.path)
  if not st then
    b.mtime, b.size, b.levels = nil, nil, {}
    b.token = (b.token or 0) + 1
    set_lines(buf, { 'Transcript not found: ' .. session.path })
  elseif not (b.mtime and b.mtime[1] == st.mtime.sec and b.mtime[2] == st.mtime.nsec and b.size == st.size) then
    load(buf, session.path, st)
  end
  api.nvim_win_set_buf(win, buf)
  api.nvim_set_current_win(win)
  refresh_windows(buf)
  -- only an absolute key is a folder: a project without cwd is keyed by a bare directory name
  if config.get().tcd and project.key and project.key:sub(1, 1) == '/' and vim.fn.isdirectory(project.key) == 1 then
    api.nvim_win_call(win, function() vim.cmd.tcd(vim.fn.fnameescape(project.key)) end)
  end
end

return M

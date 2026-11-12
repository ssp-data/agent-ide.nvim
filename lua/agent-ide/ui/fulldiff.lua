-- The full diff view: every change of a scope (the branch against the working tree, its
-- commits, one commit, or the uncommitted changes) in one read-only buffer in the Agents tab's
-- main window, a header and a fold per file, three lines of context around each change.
-- `<CR>` opens the side-by-side diff view of the file under the cursor and its close comes back
-- here. The view reloads when the git cache of its repository is invalidated (a turn ended,
-- `R`), keeping the cursor on its file and hunk and the user's folds as they were.
local api = vim.api
local cache = require('agent-ide.git_cache')
local config = require('agent-ide.config')
local cursor = require('agent-ide.ui.fulldiff_cursor')
local git = require('agent-ide.git')
local git_patch = require('agent-ide.git_patch')
local keys_mod = require('agent-ide.ui.fulldiff_keys')
local render = require('agent-ide.ui.fulldiff_render')

local M = {}

local ns = api.nvim_create_namespace('agent-ide.fulldiff')
local augroup = api.nvim_create_augroup('agent-ide.fulldiff', { clear = true })

local FOLD_OVER = 500 -- a file with a longer block starts folded

---@class agent_ide.FullDiffView
---@field buf integer
---@field root string
---@field project table
---@field scope { kind: 'branch'|'commits'|'commit'|'head', commit?: table }
---@field res table|nil the last load (git_patch.load)
---@field t table|nil the last render (fulldiff_render.build)
---@field loading boolean
---@field seq integer
---@field prev { buf: integer|nil, chat: table|nil } what the main window showed before
---@field restore { path?: string, hunk?: string, offset?: integer, row?: integer }|nil where the cursor goes on the next draw
---@field closed table<string, boolean>|nil the user's fold state by path
local V -- the view, or nil

local function notify(msg) vim.notify('Agent-IDE: ' .. msg, vim.log.levels.INFO) end
local function valid_win(w) return w ~= nil and api.nvim_win_is_valid(w) end
local function drawer() return require('agent-ide.ui.drawer') end
local function wins() return V and api.nvim_buf_is_valid(V.buf) and vim.fn.win_findbuf(V.buf) or {} end

local function text_width(win)
  local info = vim.fn.getwininfo(win)[1]
  return api.nvim_win_get_width(win) - (info and info.textoff or 0)
end

-- Winbar and window -----------------------------------------------------------------------------

local function totals(files)
  local a, d = 0, 0
  for _, f in ipairs(files) do
    a, d = a + (f.added or 0), d + (f.removed or 0)
  end
  return a, d
end

local function winbar()
  local parts = { V.project.name or vim.fs.basename(V.root), 'full diff' }
  if V.res then
    parts[#parts + 1] = V.res.label
    local n = #V.res.files
    local a, d = totals(V.res.files)
    local s = n .. (n == 1 and ' file' or ' files')
    if a > 0 then s = s .. ' +' .. a end
    if d > 0 then s = s .. ' −' .. d end
    parts[#parts + 1] = s
  elseif V.loading then
    parts[#parts + 1] = 'loading…'
  end
  return (table.concat(parts, ' · '):gsub('%%', '%%%%'))
end

local WIN_OPTS = { wrap = false, cursorline = true, list = false, number = false, relativenumber = false, spell = false,
  foldenable = true, foldmethod = 'manual', foldlevel = 1, foldtext = "v:lua.require'agent-ide.ui.fulldiff'.foldtext()" }

local function apply_win(w)
  for name, value in pairs(WIN_OPTS) do api.nvim_set_option_value(name, value, { scope = 'local', win = w }) end
  api.nvim_win_call(w, function() vim.opt_local.fillchars:append({ fold = ' ' }) end)
  api.nvim_set_option_value('winbar', winbar(), { scope = 'local', win = w })
end

---The text of a closed file: its header line with the closed icon.
function M.foldtext()
  local line = vim.fn.getline(vim.v.foldstart)
  local icons = config.get().icons
  return (line:gsub('^' .. vim.pesc(icons.open or '▾'), icons.closed or '▸', 1))
end

-- Drawing -------------------------------------------------------------------------------------

local function empty_text()
  local k = V.scope.kind
  if V.res and V.res.error then return 'error: ' .. V.res.error end
  if k == 'branch' then return 'nothing changed ' .. V.res.label end
  if k == 'commits' then return 'no commits on the branch' end
  if k == 'head' then return 'nothing to commit' end
  return 'nothing changed'
end

---Re-render into the buffer; every window showing it keeps its cursor on the same file and
---hunk (or goes where `V.restore` says). Never changes the current window.
local function draw()
  if not (V and api.nvim_buf_is_valid(V.buf)) then return end
  local ws = wins()
  local keep = {}
  for _, w in ipairs(ws) do keep[w] = V.restore or cursor.key(w, V.t) end
  V.restore = nil
  local lines, t, note_hl
  if V.res then
    V.closed = cursor.read_closed(ws[1], V.t) or V.closed
    t = render.build(V.res.files, V.res.blocks, { icons = config.get().icons, width = ws[1] and text_width(ws[1]) or 80,
      closed = V.closed, fold_over = FOLD_OVER })
    lines = t.lines
    if #lines == 0 then
      lines, note_hl = { empty_text() }, true
    end
  else
    lines, note_hl = { 'loading…' }, true
  end
  vim.bo[V.buf].modifiable = true
  api.nvim_buf_set_lines(V.buf, 0, -1, false, lines)
  vim.bo[V.buf].modifiable = false
  vim.bo[V.buf].modified = false
  api.nvim_buf_clear_namespace(V.buf, ns, 0, -1)
  if note_hl then
    api.nvim_buf_set_extmark(V.buf, ns, 0, 0, { end_col = #lines[1], hl_group = 'AgentIdeDiffNote' })
  end
  for _, h in ipairs(t and t.hl or {}) do
    api.nvim_buf_set_extmark(V.buf, ns, h.line - 1, h.col_start,
      { end_row = (h.end_line or h.line) - 1, end_col = h.col_end, hl_group = h.group })
  end
  V.t = t
  for _, w in ipairs(ws) do
    api.nvim_set_option_value('winbar', winbar(), { scope = 'local', win = w })
    cursor.apply_folds(w, t or { folds = {} })
    local key = keep[w]
    local target = t and cursor.find(t, key) or nil
    target = math.min(target or key.row or 1, #lines)
    pcall(api.nvim_win_set_cursor, w, { math.max(target, 1), 0 })
  end
end

local function load()
  V.seq = V.seq + 1
  local v, seq = V, V.seq
  v.loading = true
  git_patch.load(v.root, v.scope, function(res)
    if V ~= v or v.seq ~= seq then return end
    v.loading, v.res = false, res
    draw()
  end)
end

local function on_update(root, kind)
  if not V or root ~= V.root then return end
  if kind == 'invalidate' then
    if V.scope.kind ~= 'commit' and not V.self_invalidate then load() end
  elseif (kind == 'changes' and V.scope.kind == 'branch') or (kind == 'uncommitted' and V.scope.kind == 'head') then
    -- the untracked line counts were filled into the same tables: headers and the winbar again
    if V.res and not V.loading then draw() end
  end
end

-- Actions ----------------------------------------------------------------------------------------

local function current()
  local w = api.nvim_get_current_win()
  if not V or api.nvim_win_get_buf(w) ~= V.buf or not V.t then return nil end
  local row = api.nvim_win_get_cursor(w)[1]
  return V.t.nodes[row], w, row
end

local A = {}

function A.open()
  local node, w = current()
  if not node then return end
  V.restore = cursor.key(w, V.t)
  vim.bo[V.buf].bufhidden = 'hide' -- kept while the diff view shows: closing it shows this again
  require('agent-ide.ui.fulldiff_open').side_by_side(V, V.t.files[node.file].path, node.new_line)
end

local function jump_file(delta)
  local _, w, row = current()
  if not w then return end
  local files = V.t.files
  for _ = 1, vim.v.count1 do
    local target
    if delta > 0 then
      for _, f in ipairs(files) do
        if f.line > row then target = f.line break end
      end
    else
      for i = #files, 1, -1 do
        if files[i].line < row then target = files[i].line break end
      end
    end
    if not target then break end
    row = target
  end
  api.nvim_win_set_cursor(w, { row, 0 })
end

-- The next (previous) `@@` line not inside a closed fold.
local function jump_hunk(delta)
  local _, w, row = current()
  if not w then return end
  local lines = V.t.lines
  api.nvim_win_call(w, function()
    for _ = 1, vim.v.count1 do
      local i = row + delta
      while lines[i] and not (lines[i]:sub(1, 2) == '@@' and vim.fn.foldclosed(i) == -1) do i = i + delta end
      if not lines[i] then break end
      row = i
    end
  end)
  api.nvim_win_set_cursor(w, { row, 0 })
end

function A.next_file() jump_file(1) end
function A.prev_file() jump_file(-1) end
function A.next_hunk() jump_hunk(1) end
function A.prev_hunk() jump_hunk(-1) end
function A.fold() vim.cmd('silent! normal! za') end
function A.collapse_all() vim.cmd('silent! normal! zM') end
function A.expand_all() vim.cmd('silent! normal! zR') end

function A.refresh()
  if cache.peek(V.root) then
    V.self_invalidate = true -- the drawer's lists reload too; this view loads once, below
    local ok, err = pcall(cache.invalidate, V.root)
    V.self_invalidate = nil
    if not ok then error(err) end
  end
  load()
end

function A.yank()
  local node = current()
  if not node then return notify('no file under the cursor') end
  local path = V.t.files[node.file].path
  vim.fn.setreg('"', path)
  pcall(vim.fn.setreg, '+', path)
  notify('yanked ' .. path)
end

function A.lazygit() require('agent-ide.ui.lazygit').open(V.root) end

function A.close() M.close() end

-- Buffer -----------------------------------------------------------------------------------------

local resize_timer

local function make_buf(root)
  local buf = api.nvim_create_buf(false, true)
  local bufname = require('agent-ide.ui.bufname')
  bufname.set(buf, 'agents://' .. bufname.clean(V.project.name or vim.fs.basename(root), '?') .. '/full diff')
  for name, value in pairs({ buftype = 'nofile', bufhidden = 'wipe', swapfile = false, modifiable = false,
    filetype = 'agent-ide-fulldiff' }) do
    vim.bo[buf][name] = value
  end
  keys_mod.map(buf, A)
  api.nvim_create_autocmd('BufWinEnter', { group = augroup, buffer = buf, callback = function()
    if not V or V.buf ~= buf then return end
    vim.bo[buf].bufhidden = 'wipe'
    local w = api.nvim_get_current_win()
    if api.nvim_win_get_buf(w) == buf then apply_win(w) end
    draw()
  end })
  api.nvim_create_autocmd('BufWipeout', { group = augroup, buffer = buf, callback = function()
    if V and V.buf == buf then
      V = nil
      cache.off_update(on_update)
    end
  end })
  return buf
end

api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, { group = augroup, callback = function(ev)
  if not V then return end
  if ev.event == 'WinResized' then
    local hit = false
    for _, w in ipairs(vim.v.event.windows or {}) do hit = hit or (valid_win(w) and api.nvim_win_get_buf(w) == V.buf) end
    if not hit then return end
  end
  if not resize_timer then resize_timer = vim.uv.new_timer() end
  resize_timer:stop()
  resize_timer:start(30, 0, vim.schedule_wrap(function() draw() end))
end })

local function project_for(root, project)
  if project then return project end
  return { key = root, root = root, name = vim.fs.basename(root), is_git = true, sessions = {} }
end

local function same_scope(a, b)
  return a.kind == b.kind and (a.kind ~= 'commit' or (a.commit and b.commit and a.commit.hash == b.commit.hash))
end

local function show(opts)
  local root = opts.root
  local tab = drawer().state().tab
  if not tab then
    require('agent-ide').toggle()
    tab = drawer().state().tab
    if not tab then return notify('cannot open the Agents tab') end
  end
  if api.nvim_get_current_tabpage() ~= tab then api.nvim_set_current_tabpage(tab) end
  local diff = package.loaded['agent-ide.ui.diff']
  if diff and diff.state() then diff.close() end
  local chat_win = require('agent-ide.ui.chat_win')
  local win = chat_win.transcript()
  local shown = api.nvim_win_get_buf(win)
  if V and V.buf == shown and V.root == root and same_scope(V.scope, opts.scope) then
    api.nvim_set_current_win(win)
    if opts.focus_path then
      V.restore = { path = opts.focus_path }
      draw()
    end
    return
  end
  local graph = package.loaded['agent-ide.ui.graph']
  local g = graph and graph.state()
  local prev, drop_graph
  if V and V.buf == shown then
    prev = V.prev -- another full diff: back to what was there before that one
  elseif g and g.buf == shown then
    if opts.keep_graph then
      prev = { buf = shown } -- the graph stays underneath: q returns to it
    else
      prev, drop_graph = g.prev, true
    end
  else
    local chat = package.loaded['agent-ide.ui.chat']
    prev = { buf = shown, chat = chat and chat.session_of(shown) or nil }
  end
  local p = chat_win.get().prompt
  if p and p ~= win and api.nvim_win_get_tabpage(p) == tab then pcall(api.nvim_win_close, p, false) end
  local old = V
  V = { root = root, project = project_for(root, opts.project), scope = opts.scope, loading = true, seq = 0, prev = prev,
    restore = opts.focus_path and { path = opts.focus_path } or nil }
  require('agent-ide.ui.git_hl').setup()
  V.buf = make_buf(root)
  cache.on_update(on_update)
  cache.head(root) -- an entry for the repository: its invalidations reach this view
  api.nvim_win_set_buf(win, V.buf)
  -- the view that held the window goes once this one has it
  if old and api.nvim_buf_is_valid(old.buf) then pcall(api.nvim_buf_delete, old.buf, { force = true }) end
  if drop_graph then graph.drop() end
  apply_win(win)
  api.nvim_set_current_win(win)
  if config.get().tcd and vim.fn.isdirectory(root) == 1 then
    api.nvim_win_call(win, function() vim.cmd.tcd(vim.fn.fnameescape(root)) end)
  end
  draw()
  load()
end

---Open the full diff of `opts.scope` in the repository `opts.root` (kept as given, e.g. a drawer
---project's root) or of the work tree holding `opts.dir`. `focus_path` puts the cursor on that
---file; `keep_graph` leaves a showing commit graph underneath (`q` returns to it). Outside a
---repository: a notice, nothing opens.
---@param opts { root?: string, dir?: string, project?: table, scope: table, focus_path?: string, keep_graph?: boolean }
function M.open(opts)
  local dir = opts.root or opts.dir
  if not dir or vim.fn.isdirectory(dir) ~= 1 then return notify('not a git repository: ' .. tostring(dir)) end
  git.toplevel(dir, function(top)
    if not top then return notify('not a git repository: ' .. vim.fn.fnamemodify(dir, ':~')) end
    local ok, err = pcall(show, vim.tbl_extend('force', opts, { root = opts.root or top }))
    if not ok then vim.notify('Agent-IDE: cannot open the full diff: ' .. tostring(err), vim.log.levels.ERROR) end
  end)
end

---Close the view; the main window shows what it showed before (a chat when one was open).
function M.close()
  if not V then return end
  local v = V
  local w = wins()[1]
  if valid_win(w) then
    api.nvim_set_current_win(w)
    local chat = package.loaded['agent-ide.ui.chat']
    local b = v.prev.buf
    if v.prev.chat and chat then
      chat.open(v.prev.chat, chat.project_of(v.prev.chat))
    elseif b and b ~= v.buf and api.nvim_buf_is_valid(b) and api.nvim_buf_is_loaded(b) then
      api.nvim_win_set_buf(w, b)
    else
      api.nvim_win_set_buf(w, require('agent-ide.ui.diff_buf').empty())
    end
  end
  if api.nvim_buf_is_valid(v.buf) then pcall(api.nvim_buf_delete, v.buf, { force = true }) end
  if V == v then
    V = nil
    cache.off_update(on_update)
  end
end

---Forget the view and wipe its buffer without showing anything: another view (the graph) takes
---the window and what was there before.
function M.drop()
  if not V then return end
  local v = V
  V = nil
  cache.off_update(on_update)
  if api.nvim_buf_is_valid(v.buf) then pcall(api.nvim_buf_delete, v.buf, { force = true }) end
end

---The open view (tests and the drawer): nil when closed.
function M.state() return V end

return M

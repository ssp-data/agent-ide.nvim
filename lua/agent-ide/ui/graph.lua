-- The commit graph view: a project's history as git draws it (`git log --graph`), in the Agents
-- tab's main window, read only. `<CR>` on a commit lists its files below it, on a file opens the
-- diff view of that commit; closing the diff comes back here. The view reloads when the git
-- cache of its repository is invalidated (a turn ended, `R`), keeping the cursor on its commit.
local api = vim.api
local cache = require('agent-ide.git_cache')
local config = require('agent-ide.config')
local git = require('agent-ide.git')
local graph_keys = require('agent-ide.ui.graph_keys')
local keys = require('agent-ide.util.keys')
local render = require('agent-ide.ui.graph_render')

local M = {}

local ns = api.nvim_create_namespace('agent-ide.graph')
local augroup = api.nvim_create_augroup('agent-ide.graph', { clear = true })

---@class agent_ide.GraphView
---@field buf integer
---@field root string
---@field project table
---@field all boolean every branch (false: the current branch only)
---@field limit integer
---@field state 'loading'|'ok'|'empty'|'error'
---@field rows table[]|nil
---@field more boolean|nil
---@field open table<string, true> expanded commits
---@field nodes table[]
---@field seq integer
---@field prev { buf: integer|nil, chat: table|nil } what the main window showed before
---@field restore string|nil node key to put the cursor on when the buffer is shown again
local G -- the view, or nil

local function notify(msg) vim.notify('Agent-IDE: ' .. msg, vim.log.levels.INFO) end
local function valid_win(w) return w ~= nil and api.nvim_win_is_valid(w) end
local function drawer() return require('agent-ide.ui.drawer') end

local function step()
  local g = config.get().git
  local n = type(g) == 'table' and tonumber(g.graph_limit) or nil
  return n and n > 0 and math.floor(n) or 300
end

local function node_key(node)
  if not node then return nil end
  if node.type == 'file' then return node.row.hash .. ':' .. node.file.path end
  if node.row then return node.row.hash end
  return node.type
end

local function text_width(win)
  local info = vim.fn.getwininfo(win)[1]
  return api.nvim_win_get_width(win) - (info and info.textoff or 0)
end

local function winbar()
  return ((G.project.name or vim.fs.basename(G.root)):gsub('%%', '%%%%')) .. ' · graph · ' .. (G.all and 'all branches' or 'current branch')
end

local WIN_OPTS = { wrap = false, cursorline = true, list = false, foldenable = false, foldmethod = 'manual', spell = false }

local function apply_win(w)
  for name, value in pairs(WIN_OPTS) do api.nvim_set_option_value(name, value, { scope = 'local', win = w }) end
  api.nvim_set_option_value('winbar', winbar(), { scope = 'local', win = w })
end

local function more_text()
  local k = keys.list(graph_keys.keys().more)[1]
  return k and ('… more (press %s to load %d more)'):format(k, step()) or '… more'
end

---Re-render into the buffer; every window showing it keeps its cursor on the same commit (or
---file line), or goes to `focus` (a node key). Never changes the current window.
local function draw(focus)
  if not (G and api.nvim_buf_is_valid(G.buf)) then return end
  local wins = vim.fn.win_findbuf(G.buf)
  local open = {}
  for hash in pairs(G.open) do open[hash] = cache.commit_files(G.root, hash) or false end
  local t = render.build(G.rows or {}, { width = wins[1] and text_width(wins[1]) or 80, now = os.time(), open = open,
    more = G.more and more_text() or nil, state = G.state ~= 'ok' and G.state or nil, message = G.message })
  local keep = {}
  for _, w in ipairs(wins) do
    local row = api.nvim_win_get_cursor(w)[1]
    local node = G.nodes[row]
    keep[w] = { key = focus or node_key(node), commit = node and node.row and node.row.hash, row = row }
  end
  vim.bo[G.buf].modifiable = true
  api.nvim_buf_set_lines(G.buf, 0, -1, false, t.lines)
  vim.bo[G.buf].modifiable = false
  vim.bo[G.buf].modified = false
  api.nvim_buf_clear_namespace(G.buf, ns, 0, -1)
  for _, h in ipairs(t.hl) do
    api.nvim_buf_set_extmark(G.buf, ns, h.line - 1, h.col_start, { end_col = h.col_end, hl_group = h.group })
  end
  G.nodes = t.nodes
  for w, k in pairs(keep) do
    local target
    for i, n in ipairs(t.nodes) do
      if node_key(n) == k.key then target = i break end
    end
    if not target and k.commit then
      for i, n in ipairs(t.nodes) do
        if n.type == 'commit' and n.row.hash == k.commit then target = i break end
      end
    end
    target = math.min(target or k.row, #t.lines)
    if target ~= k.row then pcall(api.nvim_win_set_cursor, w, { target, 0 }) end
  end
end

local function load()
  G.seq = G.seq + 1
  local g, seq = G, G.seq
  git.graph(g.root, { all = g.all, limit = g.limit }, function(res)
    if G ~= g or g.seq ~= seq then return end
    if res.error then
      g.state, g.message, g.rows, g.more = 'error', res.error, nil, false
    elseif res.empty then
      g.state, g.rows, g.more = 'empty', nil, false
    else
      g.state, g.rows, g.more = 'ok', res.rows, res.more
    end
    draw()
  end)
end

local function on_update(root, kind)
  if not G or root ~= G.root then return end
  if kind == 'invalidate' then
    if not G.self_invalidate then load() end
  elseif kind:sub(1, 6) == 'files:' and G.open[kind:sub(7)] then
    draw()
  end
end

-- Actions ----------------------------------------------------------------------------------------

local function current()
  local w = api.nvim_get_current_win()
  if not G or api.nvim_win_get_buf(w) ~= G.buf then return nil end
  return G.nodes[api.nvim_win_get_cursor(w)[1]], w
end

local A = {}

function A.open()
  local node = current()
  if not node then return end
  if node.type == 'commit' then
    local h = node.row.hash
    G.open[h] = not G.open[h] or nil
    draw(h)
  elseif node.type == 'file' then
    local r = node.row
    G.restore = node_key(node)
    -- kept while the diff view shows: closing the diff shows it again
    vim.bo[G.buf].bufhidden = 'hide'
    require('agent-ide.ui.diff').open({ project = G.project, root = G.root, mode = 'commit', list = node.list,
      index = node.index, commit = { hash = r.hash, short = r.short, subject = r.subject, date = r.time } })
  elseif node.type == 'more' then
    A.more()
  end
end

local function jump(delta)
  local node, w = current()
  if not node then return end
  local row = api.nvim_win_get_cursor(w)[1]
  for _ = 1, vim.v.count1 do
    local i = row + delta
    while G.nodes[i] and G.nodes[i].type ~= 'commit' do i = i + delta end
    if not G.nodes[i] then break end
    row = i
  end
  api.nvim_win_set_cursor(w, { row, 0 })
end

function A.next_commit() jump(1) end
function A.prev_commit() jump(-1) end

function A.all()
  G.all = not G.all
  for _, w in ipairs(vim.fn.win_findbuf(G.buf)) do apply_win(w) end
  load()
end

function A.refresh()
  if cache.peek(G.root) then
    G.self_invalidate = true -- the drawer's lists reload too; this view loads once, below
    local ok, err = pcall(cache.invalidate, G.root)
    G.self_invalidate = nil
    if not ok then error(err) end
  end
  load()
end

function A.more()
  if not G.more then return notify('all commits are shown') end
  G.limit = G.limit + step()
  load()
end

function A.yank()
  local node = current()
  if not (node and node.row) then return notify('no commit under the cursor') end
  local hash = node.row.hash
  vim.fn.setreg('"', hash)
  pcall(vim.fn.setreg, '+', hash)
  notify('yanked ' .. hash)
end

function A.lazygit() require('agent-ide.ui.lazygit').open(G.root) end

function A.close() M.close() end

-- Buffer -----------------------------------------------------------------------------------------

local resize_timer

local function make_buf(root)
  local buf = api.nvim_create_buf(false, true)
  pcall(api.nvim_buf_set_name, buf, 'agent-ide://graph/' .. root)
  for name, value in pairs({ buftype = 'nofile', bufhidden = 'wipe', swapfile = false, modifiable = false,
    filetype = 'agent-ide-graph' }) do
    vim.bo[buf][name] = value
  end
  graph_keys.map(buf, A)
  api.nvim_create_autocmd('BufWinEnter', { group = augroup, buffer = buf, callback = function()
    if not G or G.buf ~= buf then return end
    vim.bo[buf].bufhidden = 'wipe'
    local w = api.nvim_get_current_win()
    if api.nvim_win_get_buf(w) == buf then apply_win(w) end
    local focus = G.restore
    G.restore = nil
    draw(focus)
  end })
  api.nvim_create_autocmd('BufWipeout', { group = augroup, buffer = buf, callback = function()
    if G and G.buf == buf then
      G = nil
      cache.off_update(on_update)
    end
  end })
  return buf
end

api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, { group = augroup, callback = function(ev)
  if not G then return end
  if ev.event == 'WinResized' then
    local hit = false
    for _, w in ipairs(vim.v.event.windows or {}) do hit = hit or (valid_win(w) and api.nvim_win_get_buf(w) == G.buf) end
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

local function show(root, project)
  local tab = drawer().state().tab
  if not tab then
    require('agent-ide').toggle()
    tab = drawer().state().tab
    if not tab then return notify('cannot open the Agents tab') end
  end
  if api.nvim_get_current_tabpage() ~= tab then api.nvim_set_current_tabpage(tab) end
  local diff = package.loaded['agent-ide.ui.diff']
  if diff and diff.state() then diff.close() end
  local wins = require('agent-ide.ui.chat_win')
  local win = wins.transcript()
  local shown = api.nvim_win_get_buf(win)
  if G and G.buf == shown and G.root == root then
    api.nvim_set_current_win(win)
    return
  end
  local prev
  if G and G.buf == shown then
    prev = G.prev -- another project's graph: back to what was there before that one
  else
    local chat = package.loaded['agent-ide.ui.chat']
    prev = { buf = shown, chat = chat and chat.session_of(shown) or nil }
  end
  local p = wins.get().prompt
  if p and p ~= win and api.nvim_win_get_tabpage(p) == tab then pcall(api.nvim_win_close, p, false) end
  local old = G
  G = { root = root, project = project_for(root, project), all = true, limit = step(), state = 'loading', open = {},
    nodes = {}, seq = 0, prev = prev }
  require('agent-ide.ui.git_hl').setup()
  G.buf = make_buf(root)
  cache.on_update(on_update)
  cache.head(root) -- an entry for the repository: its invalidations reach this view
  api.nvim_win_set_buf(win, G.buf)
  -- another project's graph goes once this one has its window
  if old and api.nvim_buf_is_valid(old.buf) then pcall(api.nvim_buf_delete, old.buf, { force = true }) end
  apply_win(win)
  api.nvim_set_current_win(win)
  if config.get().tcd and vim.fn.isdirectory(root) == 1 then
    api.nvim_win_call(win, function() vim.cmd.tcd(vim.fn.fnameescape(root)) end)
  end
  draw()
  load()
end

---Open the commit graph of the repository `opts.root` (kept as given, e.g. a drawer project's
---root) or of the work tree holding `opts.dir`. Outside a repository: a notice, nothing opens.
---@param opts { root?: string, dir?: string, project?: table }
function M.open(opts)
  local dir = opts.root or opts.dir
  if not dir or vim.fn.isdirectory(dir) ~= 1 then return notify('not a git repository: ' .. tostring(dir)) end
  git.toplevel(dir, function(top)
    if not top then return notify('not a git repository: ' .. vim.fn.fnamemodify(dir, ':~')) end
    local ok, err = pcall(show, opts.root or top, opts.project)
    if not ok then vim.notify('Agent-IDE: cannot open the graph: ' .. tostring(err), vim.log.levels.ERROR) end
  end)
end

---Repository of a drawer row (nil outside a git project); see ui/graph_context.lua.
M.node_root = function(node) return require('agent-ide.ui.graph_context').node_root(node) end

---`:AgentsGraph`: the graph of the current context (see ui/graph_context.lua).
function M.open_context() M.open(require('agent-ide.ui.graph_context').target(G)) end

---Close the view; the main window shows what it showed before (a chat when one was open).
function M.close()
  if not G then return end
  local g = G
  local w = vim.fn.win_findbuf(g.buf)[1]
  if valid_win(w) then
    api.nvim_set_current_win(w)
    local chat = package.loaded['agent-ide.ui.chat']
    local b = g.prev.buf
    if g.prev.chat and chat then
      chat.open(g.prev.chat, chat.project_of(g.prev.chat))
    elseif b and b ~= g.buf and api.nvim_buf_is_valid(b) and api.nvim_buf_is_loaded(b) then
      api.nvim_win_set_buf(w, b)
    else
      api.nvim_win_set_buf(w, require('agent-ide.ui.diff_buf').empty())
    end
  end
  if api.nvim_buf_is_valid(g.buf) then pcall(api.nvim_buf_delete, g.buf, { force = true }) end
  if G == g then
    G = nil
    cache.off_update(on_update)
  end
end

---The open view (tests): nil when closed.
function M.state() return G end

return M

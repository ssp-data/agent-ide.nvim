-- The diff view: two windows side by side in the Agents tab's main area, on Neovim's own diff
-- mode. Branch mode: merge-base (scratch) vs the real working-tree file (the user's buffer).
-- Commit mode: `<hash>^` vs `<hash>` (both scratch). Leaving the view turns diff mode off; the
-- user's buffers are never wiped and never keep 'diff' or 'scrollbind'.
local api = vim.api
local cache = require('agent-ide.git_cache')
local git = require('agent-ide.git')
local scratch = require('agent-ide.ui.diff_buf')

local M = {}

local augroup = api.nvim_create_augroup('agent-ide.diff', { clear = true })
local repair_group = api.nvim_create_augroup('agent-ide.diff.repair', { clear = true })

---@class agent_ide.DiffView
---@field tab integer
---@field left integer window
---@field right integer window
---@field root string
---@field project table
---@field mode 'branch'|'commit'
---@field list table[] files
---@field index integer|nil position of `file` in `list`
---@field file table
---@field commit table|nil
---@field base table|nil
---@field lbuf integer|nil
---@field rbuf integer|nil
---@field real integer|nil the user's buffer shown on the right
---@field prev { buf: integer|nil, chat: table|nil }
---@field seq integer
local D -- the open view, or nil
local switching = false -- our own window/buffer changes: autocmds ignore them
local tainted = {} -- real buffers that left a diff window with 'diff' on: repaired on next display

local function drawer() return require('agent-ide.ui.drawer') end
local function valid_win(w) return w ~= nil and api.nvim_win_is_valid(w) end
local function notify(msg) vim.notify('Agent-IDE: ' .. msg, vim.log.levels.INFO) end

local function win_buf(w) return valid_win(w) and api.nvim_win_get_buf(w) or nil end

local function diffoff(w)
  if valid_win(w) then api.nvim_win_call(w, function() vim.cmd('diffoff') end) end
end

local function diffthis(w)
  if valid_win(w) then api.nvim_win_call(w, function() vim.cmd('diffthis') end) end
end

-- Winbars --------------------------------------------------------------------------------------

local function esc(s) return (tostring(s):gsub('%%', '%%%%')) end

local function position()
  if not D.index then return 'file ?/' .. #D.list end
  return ('file %d/%d'):format(D.index, #D.list)
end

---Labels of both sides: { left, right }.
function M.labels(d)
  d = d or D
  local f = d.file
  if d.mode == 'commit' then
    local c = d.commit
    return { c.short .. '^', c.short .. ' ' .. c.subject }
  end
  local b = d.base or {}
  local left = 'base ' .. (b.label or '?')
  if b.rev then left = left .. ' (' .. b.rev:sub(1, 7) .. ')' end
  local right = 'working tree'
  if f.status == 'D' then right = right .. ' (deleted)' end
  return { left, right }
end

local function set_winbars()
  local l = M.labels()
  local pos = position()
  local name = D.file.old_path and (D.file.old_path .. ' → ' .. D.file.path) or D.file.path
  local opts = { scope = 'local' }
  opts.win = D.left
  if valid_win(D.left) then api.nvim_set_option_value('winbar', esc(l[1] .. ' · ' .. name .. ' · ' .. pos), opts) end
  opts.win = D.right
  if valid_win(D.right) then api.nvim_set_option_value('winbar', esc(l[2] .. ' · ' .. pos), opts) end
end

-- Teardown -------------------------------------------------------------------------------------

local function release_real(d, still_shown)
  if not d.real then return end
  scratch.unmap(d.real)
  if still_shown and valid_win(d.right) then
    api.nvim_set_option_value('winbar', d.real_winbar or '', { scope = 'local', win = d.right })
  elseif api.nvim_buf_is_valid(d.real) then
    tainted[d.real] = true -- it left the window with 'diff' on: fixed when shown again
  end
  d.real = nil
end

local on_update

---Close the view. `keep` is a diff window now showing someone else's buffer: it stays; the
---other one closes. Without `keep` the left window closes and the right one stays.
local function teardown(keep)
  local d = D
  if not d then return end
  D = nil
  api.nvim_clear_autocmds({ group = augroup })
  cache.off_update(on_update)
  switching = true
  for _, w in ipairs({ d.left, d.right }) do diffoff(w) end
  release_real(d, win_buf(d.right) == d.real)
  local close = keep == d.left and d.right or d.left
  if valid_win(close) and #vim.tbl_filter(function(w) return api.nvim_win_get_config(w).relative == '' end,
      api.nvim_tabpage_list_wins(api.nvim_win_get_tabpage(close))) > 1 then
    local b = win_buf(close)
    if b == d.lbuf or b == d.rbuf or b == d.real then pcall(api.nvim_win_close, close, true) end
  end
  if keep == d.left and valid_win(d.left) then pcall(api.nvim_set_option_value, 'winbar', '', { scope = 'local', win = d.left }) end
  switching = false
  return d
end

-- Showing a file -------------------------------------------------------------------------------

local function abs(path) return D.root .. '/' .. path end

local function map_keys(buf) require('agent-ide.ui.diff_keys').map(buf, M) end

---Put the sides into the windows and turn diff mode on.
local function apply(left_lines, right, keep_cursor)
  local f = D.file
  local note = f.submodule and 'submodule: not shown (no descent)'
    or (f.binary or left_lines == true or right == true) and 'binary file, not shown' or nil
  switching = true
  diffoff(D.left)
  diffoff(D.right)
  local cursors = keep_cursor and { api.nvim_win_get_cursor(D.left), api.nvim_win_get_cursor(D.right) }
  local l_rev = D.mode == 'commit' and (D.commit.short .. '^') or (D.base and D.base.rev and D.base.rev:sub(1, 7) or 'empty')
  local lbuf = scratch.get(l_rev, f.old_path or f.path, note and { note } or left_lines or {})
  local rbuf, real
  if type(right) == 'number' and not note then
    rbuf, real = right, right
  else
    local r_rev = D.mode == 'commit' and D.commit.short or 'worktree'
    rbuf = scratch.get(r_rev, f.path, note and { note } or (type(right) == 'table' and right) or {})
  end
  if D.real and D.real ~= real then release_real(D, true) end
  if real and D.real ~= real then
    D.real_winbar = api.nvim_get_option_value('winbar', { scope = 'local', win = D.right })
  end
  if win_buf(D.left) ~= lbuf then api.nvim_win_set_buf(D.left, lbuf) end
  if win_buf(D.right) ~= rbuf then api.nvim_win_set_buf(D.right, rbuf) end
  D.lbuf, D.rbuf, D.real, D.shown = lbuf, rbuf, real, f
  tainted[rbuf] = nil
  map_keys(lbuf)
  map_keys(rbuf)
  if not note then
    diffthis(D.left)
    diffthis(D.right)
  end
  set_winbars()
  if cursors then
    pcall(api.nvim_win_set_cursor, D.left, cursors[1])
    pcall(api.nvim_win_set_cursor, D.right, cursors[2])
  elseif not note then
    api.nvim_win_call(D.right, function()
      vim.cmd('normal! gg')
      if vim.fn.diff_hlID(1, 1) == 0 and vim.fn.diff_filler(1) == 0 then pcall(vim.cmd, 'normal! ]c') end
    end)
  end
  switching = false
end

---Load the current file's sides and show them (`keep_cursor` on refresh).
local function show(keep_cursor)
  D.seq = D.seq + 1
  local seq, d, f = D.seq, D, D.file
  local left_rev = d.mode == 'commit' and (d.commit.hash .. '^') or (d.base and d.base.rev)
  local pending, left, right = 2, nil, nil
  local function done()
    pending = pending - 1
    if pending > 0 or D ~= d or d.seq ~= seq then return end
    if not (valid_win(d.left) and valid_win(d.right)) then return teardown() end
    apply(left, right, keep_cursor)
  end
  local function fetch_left()
    if f.status == 'A' or f.status == '?' then return done() end
    git.show(d.root, left_rev, f.old_path or f.path, function(c)
      left = scratch.lines_of(c)
      done()
    end)
  end
  fetch_left()
  if d.mode == 'commit' then
    if f.status == 'D' then return done() end
    git.show(d.root, d.commit.hash, f.path, function(c)
      right = scratch.lines_of(c)
      done()
    end)
  elseif f.status == 'D' or f.submodule or vim.fn.filereadable(abs(f.path)) ~= 1 then
    done()
  else
    right = f.binary or scratch.real(abs(f.path))
    done()
  end
end

-- Opening ----------------------------------------------------------------------------------------

local function autocmds()
  api.nvim_clear_autocmds({ group = augroup })
  api.nvim_create_autocmd('BufWinEnter', { group = augroup, callback = function()
    if switching or not D then return end
    -- the window the buffer entered (not e.g. the autocmd window of a bufload)
    local w = api.nvim_get_current_win()
    if w ~= D.left and w ~= D.right then return end
    local b = win_buf(w)
    if b ~= D.lbuf and b ~= D.rbuf then teardown(w) end
  end })
  api.nvim_create_autocmd('WinClosed', { group = augroup, callback = function(ev)
    if switching or not D then return end
    local w = tonumber(ev.match)
    if w == D.right then
      local d = teardown(D.left)
      -- the left window becomes the main window: it shows what was there before the view
      vim.schedule(function() if d and valid_win(d.left) then M._restore(d, d.left) end end)
    elseif w == D.left then
      teardown(D.right)
    end
  end })
  api.nvim_create_autocmd('TabClosed', { group = augroup, callback = function()
    if D and not api.nvim_tabpage_is_valid(D.tab) then teardown() end
  end })
  cache.on_update(on_update)
end

-- A real buffer that left a diff window with 'diff' still on gets it back from Neovim when shown
-- in that window again: turn it off there unless the window is part of the view.
api.nvim_create_autocmd('BufWinEnter', { group = repair_group, callback = function(ev)
  if not tainted[ev.buf] then return end
  local w = api.nvim_get_current_win()
  if D and (w == D.left or w == D.right) then return end
  if vim.wo[w].diff then vim.cmd('diffoff') end
  tainted[ev.buf] = nil
end })

---Open the diff view on `opts.list[opts.index]`.
---@param opts { project: table, root: string, mode: 'branch'|'commit', list: table[], index: integer, commit?: table }
function M.open(opts)
  local file = opts.list[opts.index]
  if not file then return end
  local tab = drawer().state().tab
  if not tab then return notify('open the Agents tab first') end
  if D and not (valid_win(D.left) and valid_win(D.right) and api.nvim_win_get_tabpage(D.right) == tab) then teardown() end
  if not D then
    if api.nvim_get_current_tabpage() ~= tab then api.nvim_set_current_tabpage(tab) end
    local wins = require('agent-ide.ui.chat_win')
    local right = wins.transcript()
    local prev = { buf = win_buf(right) }
    local chat = package.loaded['agent-ide.ui.chat']
    prev.chat = chat and prev.buf and chat.session_of(prev.buf) or nil
    switching = true
    local p = wins.get().prompt
    if p and p ~= right and api.nvim_win_get_tabpage(p) == tab then pcall(api.nvim_win_close, p, false) end
    local left = api.nvim_open_win(scratch.empty(), false, { split = 'left', win = right })
    local total = api.nvim_win_get_width(left) + api.nvim_win_get_width(right)
    api.nvim_win_set_width(left, math.floor(total / 2))
    switching = false
    D = { tab = tab, left = left, right = right, prev = prev, seq = 0, lbuf = win_buf(left), rbuf = prev.buf }
    autocmds()
  end
  D.root, D.project, D.mode, D.list, D.index, D.file = opts.root, opts.project, opts.mode, opts.list, opts.index, file
  D.commit = opts.commit
  D.base = opts.mode == 'branch' and cache.base(opts.root) or nil
  api.nvim_set_current_win(D.right)
  if D.mode == 'branch' and not D.base then
    local d = D
    return cache.when(opts.root, 'base', function(b)
      if D ~= d then return end
      D.base = b
      show(false)
    end)
  end
  show(false)
end

---Move to the next (`delta` 1) or previous (-1) file of the current list.
function M.step(delta)
  if not D then return end
  local i = (D.index or 0) + delta
  if not D.list[i] then return notify(delta > 0 and 'last file' or 'first file') end
  D.index, D.file = i, D.list[i]
  show(false)
end

---Show in `win` what the main window showed before view `d` (a chat when one was open).
function M._restore(d, win)
  api.nvim_set_current_win(win)
  local chat = package.loaded['agent-ide.ui.chat']
  if d.prev.chat and chat then
    return chat.open(d.prev.chat, chat.project_of(d.prev.chat))
  end
  local b = d.prev.buf
  local shown = win_buf(win)
  if b and api.nvim_buf_is_valid(b) and api.nvim_buf_is_loaded(b) then
    api.nvim_win_set_buf(win, b)
  elseif shown == d.rbuf or shown == d.lbuf then
    api.nvim_win_set_buf(win, scratch.empty())
  end
end

---Close the view and show what the main window showed before (a chat when one was open).
function M.close()
  local d = teardown()
  if d and valid_win(d.right) then M._restore(d, d.right) end
end

function on_update(root, kind)
  if not D or root ~= D.root or D.mode ~= 'branch' then return end
  if kind == 'base' then
    D.base = cache.base(root)
  elseif kind == 'changes' then
    local list = cache.changes(root)
    if not list then return end
    D.list, D.index = list, nil
    for i, f in ipairs(list) do
      if f.path == D.file.path then D.index, D.file = i, f end
    end
  else
    return
  end
  show(true)
end

---The open view (tests and diff_keys): nil when closed.
function M.state() return D end

---Test only: buffers repaired on their next display.
function M._tainted() return tainted end

return M

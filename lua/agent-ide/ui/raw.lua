-- The raw view: exactly what went over the wire for a session, one line each, `>> ` for what
-- the plugin sent and `<< ` for what Claude sent back (byte-exact after the prefix). It opens
-- in the window that shows the chat transcript and updates while open. A session that never
-- ran in this Neovim shows its transcript file instead (read asynchronously, in chunks).
-- `q` (or the raw key again) returns to the chat transcript in the same window.
local api = vim.api
local lines_util = require('agent-ide.util.lines')
local RAW_KEEP = require('agent-ide.session.object').RAW_KEEP

local M = {}

M._chunk = 262144 -- bytes per read of a transcript file

local ns = api.nvim_create_namespace('agent-ide.raw')
local PREFIX = { out = '>> ', ['in'] = '<< ' }
local UNKNOWN, BODY = '▸ unknown: ', '│ ' -- renderer: header of an unknown fold, prefix of fold body lines
local HL = { out = 'AgentIdeRawSent', ['in'] = 'AgentIdeRawRecv' }

---@class agent_ide.RawView
---@field buf integer
---@field mode 'live'|'file'
---@field gen integer bumped whenever the content is rebuilt: stops a file read still running
---@field dropped integer the `raw_dropped` count the buffer shows
---@field n integer entry lines in the buffer (live mode)
local views = {} -- session id -> RawView

local function valid(buf) return buf ~= nil and api.nvim_buf_is_valid(buf) and api.nvim_buf_is_loaded(buf) end

local function define_highlights()
  api.nvim_set_hl(0, 'AgentIdeRawSent', { default = true, link = 'DiagnosticInfo' })
  api.nvim_set_hl(0, 'AgentIdeRawRecv', { default = true, link = 'Comment' })
end

local function header(dropped)
  return ('… %d earlier lines dropped (cap %d)'):format(dropped, RAW_KEEP)
end

local function write(buf, first, last, lines)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, first, last, false, lines)
  vim.bo[buf].modifiable = false
end

local function mark(buf, row, dir)
  api.nvim_buf_set_extmark(buf, ns, row, 0, { end_col = 2, hl_group = HL[dir] })
end

---Windows showing `buf` whose cursor is on its last line.
local function followers(buf)
  local count, out = api.nvim_buf_line_count(buf), {}
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    if api.nvim_win_get_cursor(w)[1] == count then out[#out + 1] = w end
  end
  return out
end

local function follow(buf, wins)
  local last = api.nvim_buf_line_count(buf)
  for _, w in ipairs(wins) do
    if api.nvim_win_is_valid(w) then api.nvim_win_set_cursor(w, { last, 0 }) end
  end
end

-- Content ----------------------------------------------------------------------------------

---True when this Neovim sent or received lines for the session.
local function ran_here(s) return #s.raw > 0 or s.raw_dropped > 0 end

---Every entry of `s.raw`, with the drop notice first when the list was capped.
local function fill_live(v, s)
  v.mode, v.gen = 'live', v.gen + 1
  local lines, shift = {}, s.raw_dropped > 0 and 1 or 0
  if shift == 1 then lines[1] = header(s.raw_dropped) end
  for _, e in ipairs(s.raw) do lines[#lines + 1] = PREFIX[e.dir] .. e.line end
  v.dropped, v.n = s.raw_dropped, #s.raw
  write(v.buf, 0, -1, lines)
  api.nvim_buf_clear_namespace(v.buf, ns, 0, -1)
  for i, e in ipairs(s.raw) do mark(v.buf, i - 1 + shift, e.dir) end
end

---A line arrived while the view is open.
local function append(v, s, dir, line)
  local buf = v.buf
  local wins = followers(buf)
  local count = api.nvim_buf_line_count(buf)
  local text = PREFIX[dir] .. line
  local row = count
  if v.n == 0 and v.dropped == 0 then -- the buffer's only line is the empty placeholder
    row = 0
    write(buf, 0, 1, { text })
  else
    write(buf, count, count, { text })
  end
  mark(buf, row, dir)
  v.n = v.n + 1
  local d = s.raw_dropped - v.dropped
  if d > 0 then -- the session dropped its oldest lines: drop them here too, update the notice
    local shift = v.dropped > 0 and 1 or 0
    write(buf, shift, shift + d, {})
    v.n = v.n - d
    write(buf, 0, shift, { header(s.raw_dropped) })
    v.dropped = s.raw_dropped
  end
  follow(buf, wins)
end

---The transcript file of a session that never ran here, read in chunks off the UI thread.
local function fill_file(v, s)
  v.mode, v.gen = 'file', v.gen + 1
  v.dropped, v.n = 0, 0
  local gen, buf, path = v.gen, v.buf, s.path
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  write(buf, 0, -1, { path and ('-- transcript file: ' .. vim.fn.fnamemodify(path, ':t') .. ' --')
    or '-- no transcript file --' })
  if not path then return end

  local function add(lines)
    if v.gen ~= gen or not valid(buf) or #lines == 0 then return end
    local count = api.nvim_buf_line_count(buf)
    write(buf, count, count, lines)
  end
  local function fail()
    vim.schedule(function() add({ '-- cannot read the file --' }) end)
  end
  local uv = vim.uv
  uv.fs_open(path, 'r', 438, function(err, fd)
    if err or not fd then return fail() end
    local splitter, offset = lines_util.splitter(), 0
    local function step()
      if v.gen ~= gen then return uv.fs_close(fd) end
      uv.fs_read(fd, M._chunk, offset, function(rerr, data)
        if rerr then
          uv.fs_close(fd)
          return fail()
        end
        local out = {}
        if data and #data > 0 then
          offset = offset + #data
          splitter:push(data, function(line) out[#out + 1] = line end)
        else
          uv.fs_close(fd)
          local rest = splitter:take_rest()
          if rest then out[#out + 1] = rest end
        end
        vim.schedule(function() add(out) end)
        if data and #data > 0 then step() end
      end)
    end
    step()
  end)
end

-- Opening and closing ------------------------------------------------------------------------

local function winbar(id)
  return ('raw · %s · >> sent  << received · q: back to the chat'):format(id:sub(1, 8)):gsub('%%', '%%%%')
end

---Return the window that shows the raw view of `s` to the chat transcript.
local function back(s, buf)
  local win = api.nvim_get_current_win()
  if api.nvim_win_get_buf(win) ~= buf then win = vim.fn.win_findbuf(buf)[1] end
  if not win then return end
  local chat = require('agent-ide.ui.chat')
  local tbuf = chat.buffers(s)
  if not tbuf then return chat.open(s, chat.project_of(s)) end -- the transcript buffer is gone
  api.nvim_win_set_buf(win, tbuf)
  require('agent-ide.ui.history').apply_win(win, tbuf)
end

local function get_view(s)
  local v = views[s.id]
  if v and valid(v.buf) then return v end
  if v and api.nvim_buf_is_valid(v.buf) then pcall(api.nvim_buf_delete, v.buf, { force = true }) end
  local name = 'agent-ide://raw/' .. s.id
  local old = vim.fn.bufnr(name)
  if old ~= -1 then pcall(api.nvim_buf_delete, old, { force = true }) end
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(buf, name)
  vim.bo[buf].bufhidden, vim.bo[buf].undolevels, vim.bo[buf].modifiable = 'hide', -1, false
  v = { buf = buf, mode = 'live', gen = 0, dropped = 0, n = 0 }
  views[s.id] = v
  local lhs = { 'q' }
  vim.list_extend(lhs, require('agent-ide.util.keys').list(require('agent-ide.ui.chat_keys').keys().raw))
  for _, key in ipairs(lhs) do
    vim.keymap.set('n', key, function() back(s, buf) end,
      { buffer = buf, nowait = true, silent = true, desc = 'Agent-IDE: back to the chat' })
  end
  return v
end

---Show the raw view of `s` in `opts.win` (default: the current window).
---@param s table Session
---@param opts? { win?: integer, line?: integer } `line`: buffer line for the cursor (default: the last)
function M.open(s, opts)
  opts = opts or {}
  define_highlights()
  local v = get_view(s)
  local win = opts.win or api.nvim_get_current_win()
  -- 'list' of the transcript is remembered (history.apply_win puts it back); read before the
  -- buffer changes, since the raw buffer brings the options it last had in this window
  if api.nvim_win_get_buf(win) ~= v.buf and vim.w[win].agent_ide_list == nil then
    vim.w[win].agent_ide_list = vim.wo[win].list
  end
  api.nvim_win_set_buf(win, v.buf)
  -- the transcript's fold options must not apply to wire lines (`back` restores them)
  api.nvim_set_option_value('foldmethod', 'manual', { scope = 'local', win = win })
  api.nvim_set_option_value('foldenable', false, { scope = 'local', win = win })
  -- raw lines are byte-exact, some of several MB (pasted images): never wrap them
  for name, value in pairs({ wrap = false, linebreak = false, list = false }) do
    api.nvim_set_option_value(name, value, { scope = 'local', win = win })
  end
  if ran_here(s) then fill_live(v, s) else fill_file(v, s) end
  api.nvim_set_option_value('winbar', (winbar(s.id)), { scope = 'local', win = win })
  local last = api.nvim_buf_line_count(v.buf)
  local line = v.mode == 'live' and (opts.line or last) or 1
  api.nvim_win_set_cursor(win, { math.min(line, last), 0 })
  -- follow the wire while the view is shown; a file view turns live when the session runs
  s.on_raw = function(dir, text)
    if not valid(v.buf) or #vim.fn.win_findbuf(v.buf) == 0 then
      s.on_raw = nil
    elseif v.mode == 'file' then
      fill_live(v, s)
      follow(v.buf, vim.fn.win_findbuf(v.buf))
    else
      append(v, s, dir, text)
    end
  end
end

-- From an event -----------------------------------------------------------------------------

---Raw-view line (1-based, as the live view shows it) of the `nth` unknown event among those
---with the same `raw` text, or nil when it is not among the lines still kept.
---@param s table Session
---@param ev table unknown event
---@param nth integer which of the events with that text this is (1-based)
---@return integer|nil
function M.line_of_event(s, ev, nth)
  if type(ev.raw) ~= 'string' then return nil end
  local shift, seen, loose = s.raw_dropped > 0 and 1 or 0, 0, nil
  for i, e in ipairs(s.raw) do
    if e.dir == 'in' then
      if e.line == ev.raw then
        seen = seen + 1
        if seen == nth then return i + shift end
      elseif not loose and e.line:find(ev.raw, 1, true) then
        loose = i + shift -- the text of a block inside a longer line
      end
    end
  end
  return loose
end

---`gR`: open the raw view; when the cursor is on an `unknown` fold of the transcript, put the
---cursor on the raw line it came from.
---@param s table Session
---@param tbuf integer transcript buffer
function M.open_at_cursor(s, tbuf)
  local render = require('agent-ide.transcript.render')
  local win = api.nvim_get_current_win()
  local lines = api.nvim_buf_get_lines(tbuf, 0, -1, false)
  local row = api.nvim_win_get_cursor(win)[1]
  while row > 1 and vim.startswith(lines[row], BODY) do row = row - 1 end
  local line
  if lines[row] and vim.startswith(lines[row], UNKNOWN) and ran_here(s) then
    -- the n-th top-level unknown header is the n-th top-level unknown event
    local n = 0
    for i = 1, row do
      if vim.startswith(lines[i], UNKNOWN) then n = n + 1 end
    end
    local events = {}
    for _, ev in ipairs(s.events) do
      if ev.kind == 'unknown' and not ev.sidechain then events[#events + 1] = ev end
    end
    local target = events[n]
    if target and lines[row] == UNKNOWN .. render.first_line(target.label) then
      local nth = 0
      for i = 1, n do
        if events[i].raw == target.raw then nth = nth + 1 end
      end
      line = M.line_of_event(s, target, nth)
    end
  end
  M.open(s, { win = win, line = line })
end

---Raw view buffer of `s` (tests).
function M.buffer(s)
  local v = views[s.id]
  return v and valid(v.buf) and v.buf or nil
end

return M

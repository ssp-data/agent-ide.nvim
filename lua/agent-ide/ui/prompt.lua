-- The prompt buffer of a chat: a normal markdown buffer whose text is sent to Claude.
local api = vim.api
local config = require('agent-ide.config')

local M = {}

-- Fence rule: a fenced block OPENS only at a line that starts at column 0 with three or more
-- backticks or tildes (an indented fence line is plain text), and CLOSES at the next line that
-- starts at column 0 with the same character at least as many times. Unclosed: runs to the end.
local function open_fence(line)
  local run = line:match('^(```+)') or line:match('^(~~~+)')
  if run then return run:sub(1, 1), #run end
end

local function closes_fence(line, char, len)
  local run = line:match('^(' .. (char == '`' and '`' or '~') .. '+)')
  return run ~= nil and #run >= len
end

---The text a prompt buffer sends: lines joined with '\n', trailing blank lines removed. A
---`[attach] <path>` line outside a fenced code block becomes `@<path>` (`@"<path>"` when the
---path holds whitespace); nothing else changes.
---@param lines string[]
---@return string
function M.text_to_send(lines)
  local last = #lines
  while last > 0 and not lines[last]:find('%S') do last = last - 1 end
  local out, fence_char, fence_len = {}, nil, 0
  for i = 1, last do
    local line = lines[i]
    if fence_char then
      if closes_fence(line, fence_char, fence_len) then fence_char = nil end
    else
      local c, n = open_fence(line)
      if c then
        fence_char, fence_len = c, n
      else
        local path = line:match('^%[attach%]%s+(.+)$')
        path = path and path:gsub('%s+$', '')
        -- Claude Code ends an unquoted mention at whitespace; a quoted one attaches the file
        if path and path ~= '' then line = path:find('%s') and ('@"' .. path .. '"') or ('@' .. path) end
      end
    end
    out[i] = line
  end
  return table.concat(out, '\n')
end

-- Per prompt buffer: { s = Session, idx = history position|nil, hist = string[]|nil, draft = string[]|nil }
local bufs = {}

local MAX_WALK = 5000
M.MAX_WALK = MAX_WALK
M.PICK_TIMEOUT_MS = 5000 -- a file list that has not arrived by then is given up
local HINT = 'Agent-IDE: commands are known after the first answer in a session'
local hinted = false

local function chat_keys()
  local keys = config.get().keys
  return type(keys) == 'table' and type(keys.chat) == 'table' and keys.chat or {}
end

local function chat_opts()
  local c = config.get().chat
  return type(c) == 'table' and c or {}
end

---True while a completion menu is open: the native one or that of a completion plugin that
---is already loaded (nvim-cmp, blink.cmp); never loads one.
local function menu_visible()
  if vim.fn.pumvisible() == 1 then return true end
  local cmp = package.loaded['cmp']
  if type(cmp) == 'table' and type(cmp.visible) == 'function' then
    local ok, v = pcall(cmp.visible)
    if ok and v then return true end
  end
  local blink = package.loaded['blink.cmp']
  if type(blink) == 'table' then
    for _, name in ipairs({ 'is_menu_visible', 'is_visible' }) do
      if type(blink[name]) == 'function' then
        local ok, v = pcall(blink[name])
        if ok and v then return true end
      end
    end
  end
  return false
end

local function reset_history(buf)
  local st = bufs[buf]
  if st then st.idx, st.hist, st.draft = nil, nil, nil end
end

-- Slash completion --------------------------------------------------------------------------------

local SLASH = '^/[%w:_%-]*$'

-- Screen-only commands Claude does not list but the plugin can do; they never reach Claude.
local PLUGIN_COMMANDS = {
  { name = 'model', info = 'pick the model (Agent-IDE)' },
  { name = 'copy', info = 'copy the last answer to the unnamed and + registers (Agent-IDE)' },
}

---The last answer of `s`: Claude's text after the last prompt (subagents left out).
local function last_answer(s)
  local parts = {}
  for _, ev in ipairs(s.events or {}) do
    if not ev.sidechain then
      if ev.kind == 'prompt' then
        parts = {}
      elseif ev.kind == 'text' and type(ev.text) == 'string' and ev.text ~= '' then
        parts[#parts + 1] = ev.text
      end
    end
  end
  return #parts > 0 and table.concat(parts, '\n\n') or nil
end

local ACTIONS = {
  model = function(s) require('agent-ide.ui.mode').pick_model(s) end,
  copy = function(s)
    local text = last_answer(s)
    if not text then return vim.notify('Agent-IDE: no answer to copy yet', vim.log.levels.INFO) end
    vim.fn.setreg('"', text)
    local clip = pcall(vim.fn.setreg, '+', text)
    local n = #vim.split(text, '\n', { plain = true })
    vim.notify(('Agent-IDE: copied the last answer (%d line%s)%s'):format(n, n == 1 and '' or 's',
      clip and '' or '; no clipboard, unnamed register only'), vim.log.levels.INFO)
  end,
}

---The plugin's own action for a prompt that is only `/model` or `/copy` (else nil).
---@param text string
---@return fun(s: table)|nil
function M.plugin_command(text)
  local name = vim.trim(text or ''):match('^/(%a+)$')
  return name and ACTIONS[name] or nil
end

---Fuzzy score of `name` for `query` (subsequence, case-insensitive): nil when it does not
---match; lower is better: prefix matches first (0), then by the position of the first letter,
---then by how close together the letters are.
local function score(name, query)
  if query == '' then return 0, 0 end
  local n, q = name:lower(), query:lower()
  if n:sub(1, #q) == q then return 0, 0 end
  local pos, first = 0, nil
  for i = 1, #q do
    pos = n:find(q:sub(i, i), pos + 1, true)
    if not pos then return nil end
    first = first or pos
  end
  return first, pos - first
end

---Claude's command list for session `s`: its own, else the last one seen for its project, else
---the most recent one of any project (session/commands.lua); nil when none is known.
local function claude_commands(s)
  local own = s and s.slash_commands
  if own and #own > 0 then return own end
  return require('agent-ide.session.commands').fallback(s and s.cwd)
end

-- Names of the commands and skills the Prompts node found (cached per scan result).
local discovered = { entries = nil, names = {} }
local function discovered_names()
  local entries = require('agent-ide.prompts.cache').global()
  if entries ~= discovered.entries then
    local names = {}
    for _, e in ipairs(entries or {}) do
      if (e.kind == 'command' or e.kind == 'skill') and type(e.name) == 'string' then names[#names + 1] = e.name end
    end
    discovered = { entries = entries, names = names }
  end
  return discovered.names
end

---Menu entries for `base` (`/` and what follows): the plugin's own commands first, then
---Claude's (see `claude_commands`) merged with the commands and skills found on disk.
---@param s table|nil Session
---@param base string
---@return table[] complete-items
function M.matches(s, base)
  local query = (base or ''):gsub('^/', '')
  local commands = claude_commands(s)
  local found, seen = {}, {}
  local function add(name, kind, info, rank)
    if seen[name] then return end
    seen[name] = true
    local sc, span = score(name, query)
    if sc then
      found[#found + 1] = { sc = sc, span = span, rank = rank, item = { word = '/' .. name, abbr = '/' .. name, kind = kind,
        info = info or '', icase = 1, user_data = kind == 'plugin' and { agent_ide = name } or nil } }
    end
  end
  for _, c in ipairs(PLUGIN_COMMANDS) do add(c.name, 'plugin', c.info, 0) end
  for _, c in ipairs(commands or {}) do
    if type(c) == 'string' then add(c, '', nil, 1) end
  end
  for _, name in ipairs(discovered_names()) do add(name, '', nil, 1) end
  table.sort(found, function(a, b)
    if a.sc ~= b.sc then return a.sc < b.sc end
    if a.span ~= b.span then return a.span < b.span end
    if a.rank ~= b.rank then return a.rank < b.rank end
    return a.item.word < b.item.word
  end)
  return vim.tbl_map(function(f) return f.item end, found)
end

---`completefunc` of a prompt buffer: `/` commands, matched fuzzily; asked again on every typed
---character (`refresh`), so typing narrows the menu.
---@param findstart integer
---@param base string
function M.complete(findstart, base)
  local line = api.nvim_get_current_line():sub(1, api.nvim_win_get_cursor(0)[2])
  if findstart == 1 then return line:match(SLASH) and 0 or -2 end
  local st = bufs[api.nvim_get_current_buf()]
  local s = st and st.s
  if not claude_commands(s) and not hinted then
    hinted = true
    vim.notify(HINT, vim.log.levels.INFO)
  end
  return { words = M.matches(s, base), refresh = 'always' }
end

-- 'completeopt' while the `/` menu is open: nothing inserted or selected before a choice.
-- `fuzzy` came with Neovim 0.11; decided by version, so no option is written to find out.
local function menu_completeopt()
  return 'menuone,noinsert,noselect' .. (vim.fn.has('nvim-0.11') == 1 and ',fuzzy' or '')
end

---Set the menu's 'completeopt' on prompt `buf` (put back when the menu is done) and close the
---menu of a completion plugin, so it does not pile on top.
local function open_menu(buf)
  local st = bufs[buf]
  if st.saved_cot == nil then
    st.saved_cot = api.nvim_get_option_value('completeopt', { scope = 'local', buf = buf })
  end
  api.nvim_set_option_value('completeopt', menu_completeopt(), { scope = 'local', buf = buf })
  local cmp = package.loaded['cmp']
  if type(cmp) == 'table' then
    if type(cmp.close) == 'function' then pcall(cmp.close) end
    if type(cmp.abort) == 'function' then pcall(cmp.abort) end
  end
end

local function close_menu(buf)
  local st = bufs[buf]
  if not st or st.saved_cot == nil then return end
  if api.nvim_buf_is_valid(buf) then
    api.nvim_set_option_value('completeopt', st.saved_cot, { scope = 'local', buf = buf })
  end
  st.saved_cot = nil
end

---A plugin entry chosen from the menu: take its text out of the line and act.
local function on_complete_done(buf)
  local item = vim.v.completed_item
  local reason = vim.v.event and vim.v.event.reason
  local data = type(item) == 'table' and item.user_data
  if type(data) ~= 'table' or not data.agent_ide or (reason and reason ~= 'accept') then return end
  local st, fn = bufs[buf], ACTIONS[data.agent_ide]
  if not st or not fn then return end
  if api.nvim_get_current_line() == item.word then api.nvim_set_current_line('') end
  vim.schedule(function() fn(st.s) end)
end

M._menu_completeopt = menu_completeopt

-- History -------------------------------------------------------------------------------------------

---Prompts as sent, oldest to newest (queued ones last), consecutive duplicates collapsed.
local function history_of(s)
  local out = {}
  local function add(text)
    if out[#out] ~= text then out[#out + 1] = text end
  end
  for _, ev in ipairs(s.events) do
    if ev.kind == 'prompt' and not ev.sidechain then add(ev.text) end
  end
  for _, q in ipairs(s.queue) do add(q) end
  return out
end

local function show_lines(buf, lines, row)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  local r = row == 'last' and #lines or 1
  pcall(api.nvim_win_set_cursor, 0, { r, #lines[r] })
end

---Step through the prompt history of `buf`: -1 older, +1 newer. The unsent text is kept when
---stepping back first and restored when stepping past the newest prompt.
---@param buf integer
---@param dir integer
function M.step(buf, dir)
  local st = bufs[buf]
  if not st or api.nvim_get_current_buf() ~= buf then return end
  if dir < 0 then
    if not st.idx then
      st.hist = history_of(st.s)
      if #st.hist == 0 then return end
      st.draft = api.nvim_buf_get_lines(buf, 0, -1, false)
      st.idx = #st.hist + 1
    end
    if st.idx > 1 then st.idx = st.idx - 1 end
    show_lines(buf, vim.split(st.hist[st.idx], '\n', { plain = true }), 'first')
  elseif st.idx then
    st.idx = st.idx + 1
    if st.idx > #st.hist then
      local draft = st.draft
      st.idx, st.hist, st.draft = nil, nil, nil
      show_lines(buf, draft, 'last')
    else
      show_lines(buf, vim.split(st.hist[st.idx], '\n', { plain = true }), 'last')
    end
  end
end

-- File picker -----------------------------------------------------------------------------------------

---Files below `root` found by a bounded asynchronous walk (never `.git` or `node_modules`).
local function walk(root, cb)
  local files, pending, finished, truncated = {}, 0, false, false
  local function finish()
    if finished then return end
    finished = true
    table.sort(files)
    cb(files, truncated)
  end
  local function scan(rel)
    pending = pending + 1
    local dir = rel == '' and root or (root .. '/' .. rel)
    local started = vim.uv.fs_scandir(dir, function(err, req)
      if not err and req then
        while true do
          local name, kind = vim.uv.fs_scandir_next(req)
          if not name then break end
          local path = rel == '' and name or (rel .. '/' .. name)
          if kind == 'directory' then
            -- past the cap directories are still read, but only to find out whether more files exist
            if name ~= '.git' and name ~= 'node_modules' and not truncated then scan(path) end
          elseif #files < M.MAX_WALK then
            files[#files + 1] = path
          else
            truncated = true
          end
        end
      end
      pending = pending - 1
      if pending == 0 then finish() end
    end)
    if not started then
      pending = pending - 1
      if pending == 0 then finish() end
    end
  end
  scan('')
end

---Files of the project at `cwd`, relative to it, sorted, at most `MAX_WALK`: `git ls-files`
---(tracked and untracked, not ignored) in a git work tree, else a walk. Asynchronous: `cb(files,
---truncated)` runs on the main loop.
---@param cwd string
---@param cb fun(files: string[], truncated: boolean)
function M.list_files(cwd, cb)
  local function by_walk()
    walk(cwd, function(files, truncated) vim.schedule(function() cb(files, truncated) end) end)
  end
  local ok = pcall(vim.system, { 'git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard' },
    { cwd = cwd, text = true }, function(res)
      if res.code ~= 0 then return by_walk() end
      local files = vim.split(res.stdout or '', '\0', { plain = true, trimempty = true })
      table.sort(files)
      local truncated = #files > M.MAX_WALK
      if truncated then files = vim.list_slice(files, 1, M.MAX_WALK) end
      vim.schedule(function() cb(files, truncated) end)
    end)
  if not ok then by_walk() end
end

local pick_ns = api.nvim_create_namespace('agent-ide.prompt.pick')

---Pick a file and add an `[attach] <path>` line above the line of the cursor. `typed`: an `@`
---was typed to get here, so cancelling leaves a literal `@` where it would have been.
---@param buf integer prompt buffer
---@param typed boolean
function M.pick(buf, typed)
  local st = bufs[buf]
  if not st or st.picking then return end
  local token = {}
  st.picking = token
  local win = api.nvim_get_current_win()
  local row, col = unpack(api.nvim_win_get_cursor(win))
  -- follows edits made while the file list is being read
  local mark = api.nvim_buf_set_extmark(buf, pick_ns, row - 1, col, { right_gravity = false })
  local dead = false
  local timer = vim.defer_fn(function()
    if st.picking ~= token then return end
    dead, st.picking = true, nil
    if api.nvim_buf_is_valid(buf) then pcall(api.nvim_buf_del_extmark, buf, pick_ns, mark) end
  end, M.PICK_TIMEOUT_MS)

  local function place(fn)
    if st.picking == token then st.picking = nil end
    if not api.nvim_buf_is_valid(buf) then return end
    local pos = api.nvim_buf_get_extmark_by_id(buf, pick_ns, mark, {})
    api.nvim_buf_del_extmark(buf, pick_ns, mark)
    if #pos == 0 then return end
    local cur = api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf and api.nvim_win_get_cursor(win)
    fn(pos[1], pos[2], cur)
  end
  local function cancel()
    place(function(r, c, cur)
      if not typed then return end
      api.nvim_buf_set_text(buf, r, c, r, c, { '@' })
      if cur and cur[1] == r + 1 and cur[2] >= c then api.nvim_win_set_cursor(win, { cur[1], cur[2] + 1 }) end
    end)
  end

  local cwd = st.s.cwd or vim.fn.getcwd(-1, 0)
  M.list_files(cwd, function(files, truncated)
    if dead then return end
    if timer:is_active() then timer:stop() end
    -- the list arrived late: only a prompt that is still being used gets the picker
    if not api.nvim_buf_is_valid(buf) or api.nvim_get_current_buf() ~= buf then return cancel() end
    if #files == 0 then
      vim.notify('Agent-IDE: no files found in ' .. cwd, vim.log.levels.INFO)
      return cancel()
    end
    local prompt = truncated and ('Attach file (first %d files)'):format(#files) or 'Attach file'
    vim.ui.select(files, { prompt = prompt }, function(choice)
      if not choice then return cancel() end
      place(function(r, _, cur)
        api.nvim_buf_set_lines(buf, r, r, false, { '[attach] ' .. choice })
        if cur and cur[1] >= r + 1 then api.nvim_win_set_cursor(win, { cur[1] + 1, cur[2] }) end
      end)
    end)
  end)
end

-- Buffer setup --------------------------------------------------------------------------------------------

---True when a history step in `dir` would change the buffer.
local function can_step(st, dir)
  if dir < 0 then
    if st.idx then return st.idx > 1 end
    return #history_of(st.s) > 0
  end
  return st.idx ~= nil
end

local function edge_key(buf, dir, key, insert)
  return function()
    local st = bufs[buf]
    if not st or not can_step(st, dir) then return key end
    local row = api.nvim_win_get_cursor(0)[1]
    local at_edge = (dir < 0 and row == 1) or (dir > 0 and row == api.nvim_buf_line_count(buf))
    if not at_edge or (insert and menu_visible()) then return key end
    return ('<Cmd>lua require("agent-ide.ui.prompt").step(%d, %d)<CR>'):format(buf, dir)
  end
end

---Completion, history and picker for prompt buffer `buf` of session `s`.
---@param buf integer
---@param s table Session
function M.setup_buf(buf, s)
  bufs[buf] = { s = s }
  api.nvim_create_autocmd('BufWipeout', { buffer = buf, once = true, callback = function() bufs[buf] = nil end })
  -- leaving the prompt gives up a picker that never answered
  api.nvim_create_autocmd('BufLeave', { buffer = buf, callback = function()
    if bufs[buf] then bufs[buf].picking = nil end
  end })
  vim.bo[buf].completefunc = "v:lua.require'agent-ide.ui.prompt'.complete"
  local keys, opts = chat_keys(), chat_opts()
  local function map(modes, lhs, fn, desc)
    vim.keymap.set(modes, lhs, fn, { buffer = buf, expr = true, nowait = true, silent = true, desc = 'Agent-IDE: ' .. desc })
  end
  local list = require('agent-ide.util.keys').list

  if opts.auto_slash ~= false then
    -- what the menu needs is ready before the first `/`: the project key and the found commands
    if s and s.cwd then require('agent-ide.session.commands').key_of(s.cwd) end
    require('agent-ide.prompts.cache').global()
    map('i', '/', function()
      local empty_line = api.nvim_get_current_line() == ''
      if empty_line and bufs[buf] and not menu_visible() then
        open_menu(buf)
        return '/<C-x><C-u>'
      end
      return '/'
    end, 'command menu')
    api.nvim_create_autocmd('CompleteDone', { buffer = buf, callback = function()
      on_complete_done(buf)
      close_menu(buf)
    end })
    api.nvim_create_autocmd('InsertLeave', { buffer = buf, callback = function() close_menu(buf) end })
  end

  if opts.at_picker ~= false then
    map('i', '@', function()
      local col = api.nvim_win_get_cursor(0)[2]
      local before = api.nvim_get_current_line():sub(col, col)
      local st = bufs[buf]
      if st and not st.picking and (col == 0 or before:match('%s')) then
        return ('<Cmd>lua require("agent-ide.ui.prompt").pick(%d, true)<CR>'):format(buf)
      end
      return '@'
    end, 'attach file')
  end
  for _, lhs in ipairs(list(keys.attach)) do
    map('n', lhs, function()
      return ('<Cmd>lua require("agent-ide.ui.prompt").pick(%d, false)<CR>'):format(buf)
    end, 'attach file')
  end

  for dir, name in pairs({ [-1] = 'history_prev', [1] = 'history_next' }) do
    local l = list(keys[name])
    local desc = dir < 0 and 'previous prompt' or 'next prompt'
    for _, lhs in ipairs(l) do
      map('n', lhs, edge_key(buf, dir, lhs, false), desc)
      map('i', lhs, edge_key(buf, dir, lhs, true), desc)
    end
    if #l > 0 then
      local arrow = dir < 0 and '<Up>' or '<Down>'
      map('n', arrow, edge_key(buf, dir, arrow, false), desc)
    end
  end
end

---Create the prompt buffer of session `s`: `agent-ide://prompt/<id>`, `acwrite`, markdown.
---The buffer is never 'modified': a draft never blocks `:q`, `:qa`, `ZZ` or `:wq`, and hiding
---the window keeps it. Saving (`:w`, `ZZ`, `:x`) is prompts/save.lua.
---@param s table Session
---@return integer buf
function M.create(s)
  local buf = api.nvim_create_buf(false, false)
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  api.nvim_buf_set_name(buf, 'agent-ide://prompt/' .. s.id)
  vim.bo[buf].filetype = 'markdown'
  api.nvim_create_autocmd({ 'BufWriteCmd', 'TextChanged', 'TextChangedI', 'TextChangedP', 'InsertLeave' }, {
    buffer = buf, callback = function(ev) vim.bo[ev.buf].modified = false end })
  M.setup_buf(buf, s)
  require('agent-ide.prompts.save').attach(buf) -- :w, ZZ, :x and <leader>W save the prompt
  return buf
end

---Window options for a window showing a prompt buffer (it may be split off a transcript window).
---@param win integer
function M.setup_win(win)
  for name, value in pairs({ winfixheight = true, winbar = '', foldenable = false, foldmethod = 'manual' }) do
    api.nvim_set_option_value(name, value, { scope = 'local', win = win })
  end
end

---True while `buf` shows a prompt from the history instead of the draft.
---@param buf integer
---@return boolean
function M.browsing(buf) return bufs[buf] ~= nil and bufs[buf].idx ~= nil end

---Empty the prompt buffer after a send; the text no longer stands for a loaded prompt file.
---@param buf integer
function M.clear(buf)
  reset_history(buf)
  vim.b[buf].agent_ide_origin = nil
  api.nvim_buf_set_lines(buf, 0, -1, false, {})
  vim.bo[buf].modified = false
end

---Stop showing a history entry: the draft it stood in for comes back, the history resets.
---@param buf integer
function M.leave_history(buf)
  local st = bufs[buf]
  if not st or not st.idx then return end
  local draft = st.draft or { '' }
  reset_history(buf)
  api.nvim_buf_set_lines(buf, 0, -1, false, draft)
  vim.bo[buf].modified = false
end

---The one way the plugin writes text into a prompt buffer (loading a prompt, inserting a
---command, queued prompts coming back, a reused search hit). The history is left first, so
---the text lands next to the real draft, and the buffer forgets the file it was loaded from:
---the result is a new prompt (a caller that loads a file sets the origin again).
---  'replace': `lines` are the whole text; 'above' / 'below': next to the current text with a
---  blank line between; 'first': `lines` become the first lines (no blank line).
---An empty buffer just gets `lines`.
---@param buf integer
---@param lines string[]
---@param how 'replace'|'above'|'below'|'first'
---@return string[] lines now in the buffer
function M.put(buf, lines, how)
  M.leave_history(buf)
  vim.b[buf].agent_ide_origin = nil
  local cur = api.nvim_buf_get_lines(buf, 0, -1, false)
  local empty = #cur == 1 and cur[1] == ''
  local out
  if how == 'replace' or empty then
    out = vim.list_extend({}, lines)
  elseif how == 'below' then
    out = vim.list_extend(vim.list_extend(cur, { '' }), lines)
  elseif how == 'first' then
    out = vim.list_extend(vim.list_extend({}, lines), cur)
  else
    out = vim.list_extend(vim.list_extend(vim.list_extend({}, lines), { '' }), cur)
  end
  if #out == 0 then out = { '' } end
  api.nvim_buf_set_lines(buf, 0, -1, false, out)
  vim.bo[buf].modified = false
  return out
end

---Put prompts back (e.g. dropped from the queue) above the text already in the buffer,
---separated by blank lines.
---@param buf integer
---@param texts string[]
function M.restore(buf, texts)
  M.put(buf, vim.split(table.concat(texts, '\n\n'), '\n', { plain = true }), 'above')
end

return M

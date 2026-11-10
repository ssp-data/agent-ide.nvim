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
---`[attach] <path>` line outside a fenced code block becomes `@<path>`; nothing else changes.
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
        if path and path ~= '' then line = '@' .. path end
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

---`completefunc` of a prompt buffer: `/` commands of the session.
---@param findstart integer
---@param base string
function M.complete(findstart, base)
  local line = api.nvim_get_current_line():sub(1, api.nvim_win_get_cursor(0)[2])
  if findstart == 1 then return line:match(SLASH) and 0 or -2 end
  local st = bufs[api.nvim_get_current_buf()]
  local commands = st and st.s.slash_commands or {}
  if #commands == 0 then
    if not hinted then
      hinted = true
      vim.notify(HINT, vim.log.levels.INFO)
    end
    return {}
  end
  local out = {}
  for _, c in ipairs(commands) do
    local item = '/' .. c
    if item:sub(1, #base) == base then out[#out + 1] = item end
  end
  table.sort(out)
  return out
end

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
  local files, pending, finished = {}, 0, false
  local function finish()
    if finished then return end
    finished = true
    table.sort(files)
    cb(files, #files >= M.MAX_WALK)
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
            if name ~= '.git' and name ~= 'node_modules' and #files < M.MAX_WALK then scan(path) end
          elseif #files < M.MAX_WALK then
            files[#files + 1] = path
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
  st.picking = true
  local win = api.nvim_get_current_win()
  local row, col = unpack(api.nvim_win_get_cursor(win))
  -- follows edits made while the file list is being read
  local mark = api.nvim_buf_set_extmark(buf, pick_ns, row - 1, col, { right_gravity = false })

  local function place(fn)
    st.picking = false
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
  vim.bo[buf].completefunc = "v:lua.require'agent-ide.ui.prompt'.complete"
  local keys, opts = chat_keys(), chat_opts()
  local function map(modes, lhs, fn, desc)
    if not lhs then return end
    vim.keymap.set(modes, lhs, fn, { buffer = buf, expr = true, nowait = true, silent = true, desc = 'Agent-IDE: ' .. desc })
  end

  if opts.auto_slash ~= false then
    map('i', '/', function()
      local empty_line = api.nvim_get_current_line() == ''
      local commands = bufs[buf] and bufs[buf].s.slash_commands
      if empty_line and commands and #commands > 0 and not menu_visible() then return '/<C-x><C-u>' end
      return '/'
    end, 'command menu')
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
  if keys.attach then
    map('n', keys.attach, function()
      return ('<Cmd>lua require("agent-ide.ui.prompt").pick(%d, false)<CR>'):format(buf)
    end, 'attach file')
  end

  if keys.history_prev then
    map('n', keys.history_prev, edge_key(buf, -1, keys.history_prev, false), 'previous prompt')
    map('n', '<Up>', edge_key(buf, -1, '<Up>', false), 'previous prompt')
    map('i', keys.history_prev, edge_key(buf, -1, keys.history_prev, true), 'previous prompt')
  end
  if keys.history_next then
    map('n', keys.history_next, edge_key(buf, 1, keys.history_next, false), 'next prompt')
    map('n', '<Down>', edge_key(buf, 1, '<Down>', false), 'next prompt')
    map('i', keys.history_next, edge_key(buf, 1, keys.history_next, true), 'next prompt')
  end
end

---Create the prompt buffer of session `s`: `agent-ide://prompt/<id>`, `acwrite`, markdown.
---Nothing is saved yet (part 3), so the buffer is never 'modified': a draft never blocks `:q`,
---`:qa`, `ZZ` or `:wq`, and hiding the window keeps it.
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
  return buf
end

---Window options for a window showing a prompt buffer (it may be split off a transcript window).
---@param win integer
function M.setup_win(win)
  for name, value in pairs({ winfixheight = true, winbar = '', foldenable = false, foldmethod = 'manual' }) do
    api.nvim_set_option_value(name, value, { scope = 'local', win = win })
  end
end

---Empty the prompt buffer after a send.
---@param buf integer
function M.clear(buf)
  reset_history(buf)
  api.nvim_buf_set_lines(buf, 0, -1, false, {})
  vim.bo[buf].modified = false
end

---Put prompts back (e.g. dropped from the queue) above the text already in the buffer,
---separated by blank lines.
---@param buf integer
---@param texts string[]
function M.restore(buf, texts)
  reset_history(buf)
  local lines = vim.split(table.concat(texts, '\n\n'), '\n', { plain = true })
  local cur = api.nvim_buf_get_lines(buf, 0, -1, false)
  if #cur > 1 or cur[1] ~= '' then
    lines[#lines + 1] = ''
    vim.list_extend(lines, cur)
  end
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
end

return M

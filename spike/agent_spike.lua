-- THROWAWAY SPIKE v2: touchable sketch of all parts (drawer, chat, folds, saved
-- prompts, git changes, quota). Not the plugin. No tests, not robust.
--   :luafile spike/agent_spike.lua   then   :AgentSpike
--
-- Drawer:  <CR>/za open or toggle · R refresh · gl lazygit on project · q close
-- Chat:    <C-CR> or <leader><CR> send · <S-Tab> mode · <leader>aM model
--          <leader>af attach file · <leader>at native Claude in tmux pane
--          <C-c> interrupt · za toggle tool fold · i (in transcript) go to prompt
--          :w in prompt = store as saved prompt · <C-x><C-u> complete /commands

local M = {}
local uv = vim.uv
local api = vim.api
local G = { sessions = {}, live = {}, expanded = {}, nodes = {}, quota = nil, cache = {} }
M.G = G

local MODES = { 'manual', 'acceptEdits', 'plan', 'auto' }
local MODELS = { 'fable', 'opus', 'sonnet', 'haiku' }
local PROJECTS_DIR = vim.fn.expand('~/.claude/projects')
local PROMPTS_DIR = vim.fn.stdpath('data') .. '/agent-spike/prompts'
local ns = api.nvim_create_namespace('agent_spike')
local ICON = { busy = '●', waiting = '◐', idle = '○' }

---------------------------------------------------------------- helpers
local function read(path, max)
  local f = io.open(path, 'rb')
  if not f then return '' end
  local s = f:read(max or 'a') or ''
  f:close()
  return s
end

local function decode(line)
  local ok, o = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  return ok and type(o) == 'table' and o or nil
end

local function ago(sec)
  local d = os.time() - sec
  if d < 90 then return 'now' end
  if d < 3600 then return math.floor(d / 60) .. 'm' end
  if d < 86400 then return math.floor(d / 3600) .. 'h' end
  return math.floor(d / 86400) .. 'd'
end

local function git(cwd, ...)
  local r = vim.system({ 'git', '-C', cwd, ... }, { text = true }):wait()
  if r.code ~= 0 then return nil end
  return vim.split(vim.trim(r.stdout), '\n', { trimempty = true })
end

local function prefixed(text, max)
  local out = {}
  for i, l in ipairs(vim.split(text or '', '\n', { plain = true })) do
    if i > (max or 60) then
      out[#out + 1] = '│ …'
      break
    end
    out[#out + 1] = '│ ' .. l
  end
  return out
end

---------------------------------------------------------------- transcript
local function follow(s)
  local w = vim.fn.bufwinid(s.tbuf)
  if w ~= -1 then api.nvim_win_set_cursor(w, { api.nvim_buf_line_count(s.tbuf), 0 }) end
end

-- streaming append: continues the last line
local function append(s, text)
  local lines = vim.split(text, '\n', { plain = true })
  local last = api.nvim_buf_line_count(s.tbuf)
  lines[1] = (api.nvim_buf_get_lines(s.tbuf, last - 1, last, false)[1] or '') .. lines[1]
  api.nvim_buf_set_lines(s.tbuf, last - 1, last, false, lines)
  follow(s)
end

local function tool_block(s, b)
  local i = b.input or {}
  local arg = i.command or i.file_path or i.skill or i.pattern or i.description or i.prompt or ''
  local lines = { ('▸ %s: %s'):format(b.name, vim.split(arg, '\n')[1]) }
  if b.name == 'Bash' then
    vim.list_extend(lines, prefixed('$ ' .. (i.command or '')))
  elseif b.name == 'Edit' then
    vim.list_extend(lines, prefixed('- ' .. (i.old_string or ''):gsub('\n', '\n- '), 30))
    vim.list_extend(lines, prefixed('+ ' .. (i.new_string or ''):gsub('\n', '\n+ '), 30))
  elseif b.name == 'Write' then
    vim.list_extend(lines, prefixed(i.content or '', 30))
  else
    vim.list_extend(lines, prefixed(vim.inspect(i), 30))
  end
  local last = api.nvim_buf_line_count(s.tbuf)
  local cur = api.nvim_buf_get_lines(s.tbuf, last - 1, last, false)[1]
  local at = cur == '' and last - 1 or last
  api.nvim_buf_set_lines(s.tbuf, at, last, false, lines)
  s.marks[b.id] = api.nvim_buf_set_extmark(s.tbuf, ns, at + #lines - 1, 0, {})
  api.nvim_buf_set_lines(s.tbuf, -1, -1, false, { '' })
  follow(s)
end

local function tool_result(s, b)
  local mark = s.marks[b.tool_use_id]
  if not mark then return end
  local text = b.content
  if type(text) == 'table' then
    local parts = {}
    for _, c in ipairs(text) do parts[#parts + 1] = c.text or ('[' .. (c.type or '?') .. ']') end
    text = table.concat(parts, '\n')
  end
  local lines = prefixed((b.is_error and 'ERROR ' or '') .. (text or ''), 40)
  local row = api.nvim_buf_get_extmark_by_id(s.tbuf, ns, mark, {})[1]
  api.nvim_buf_set_lines(s.tbuf, row + 1, row + 1, false, lines)
  api.nvim_buf_set_extmark(s.tbuf, ns, row + #lines, 0, { id = mark })
end

function _G.AgentSpikeFold(lnum)
  local l = vim.fn.getline(lnum)
  if vim.startswith(l, '▸ ') then return '>1' end
  if vim.startswith(l, '│') then return '1' end
  return '0'
end

-- shared by live events and history replay
local function render_message(s, o, streamed)
  local c = o.message and o.message.content
  if o.type == 'assistant' then
    for _, b in ipairs(type(c) == 'table' and c or {}) do
      if b.type == 'tool_use' then
        tool_block(s, b)
      elseif b.type == 'text' and not streamed then
        append(s, b.text .. '\n')
      end
    end
  elseif o.type == 'user' and type(c) == 'table' then
    for _, b in ipairs(c) do
      if b.type == 'tool_result' then tool_result(s, b) end
    end
  end
end

local function load_history(s)
  local path = s.file
  if not path or not uv.fs_stat(path) then return end
  for line in io.lines(path) do
    if line:find('"type":"user"', 1, true) or line:find('"type":"assistant"', 1, true) then
      local o = decode(line)
      if o and not o.isSidechain and not o.isMeta and (o.type == 'user' or o.type == 'assistant') then
        local c = o.message and o.message.content
        if o.type == 'user' and type(c) == 'string' then
          if not vim.startswith(c, '<') then append(s, '\n## You\n\n' .. c .. '\n\n## Claude\n\n') end
        else
          render_message(s, o, false)
        end
      end
    end
  end
  append(s, '\n---\n')
end

---------------------------------------------------------------- quota + bars
function M.quota()
  local q = G.quota
  if not q or not q.five_hour then return '' end
  local function bar(u)
    local left = math.max(0, 1 - (u or 0))
    local n = math.floor(left * 5 + 0.5)
    return ('▰'):rep(n) .. ('▱'):rep(5 - n) .. (' %d%%%%'):format(math.floor(left * 100 + 0.5))
  end
  local out = '5h ' .. bar(q.five_hour.utilization)
  if q.seven_day then out = out .. '  7d ' .. bar(q.seven_day.utilization) end
  return out
end

local function hook_lualine()
  if G.lualine_done then return end
  local ok, lualine = pcall(require, 'lualine')
  if not ok then return end
  G.lualine_done = true
  local cfg = lualine.get_config()
  table.insert(cfg.sections.lualine_x, 1, M.quota)
  lualine.setup(cfg)
end

local function winbar(s)
  local w = vim.fn.bufwinid(s.tbuf)
  if w == -1 then return end
  vim.wo[w].winbar = (' %s · %s · mode:%s · %s · %s'):format(
    vim.fs.basename(s.cwd), s.model, s.mode, s.state, s.sid:sub(1, 8))
end

---------------------------------------------------------------- claude process
local render_drawer -- forward

local function send(s, obj)
  if s.proc then s.proc:write(vim.json.encode(obj) .. '\n') end
end

local function control(s, req)
  G.req = (G.req or 0) + 1
  send(s, { type = 'control_request', request_id = 'spike-' .. G.req, request = req })
end

local function set_state(s, state)
  s.state = state
  winbar(s)
  render_drawer()
end

local function ask_permission(s, o)
  local r = o.request
  local what = ('%s: %s'):format(r.tool_name, r.description or '')
  set_state(s, 'waiting: ' .. what)
  vim.ui.select({ 'Allow', 'Deny' }, { prompt = 'Claude asks permission — ' .. what }, function(choice)
    local resp = choice == 'Allow' and { behavior = 'allow', updatedInput = r.input or {} }
      or { behavior = 'deny', message = 'Denied by user in Neovim' }
    send(s, { type = 'control_response', response = { subtype = 'success', request_id = o.request_id, response = resp } })
    set_state(s, 'busy')
  end)
end

local function handle(s, o)
  local t = o.type
  if t == 'system' then
    if o.subtype == 'init' then
      s.model, s.mode, s.slash = o.model, o.permissionMode, o.slash_commands or {}
    elseif o.subtype == 'status' and o.permissionMode then
      s.mode = o.permissionMode
    end
  elseif t == 'stream_event' and not o.parent_tool_use_id then
    local e = o.event
    if e.type == 'message_start' then
      s.streamed = false
    elseif e.type == 'content_block_delta' and e.delta.type == 'text_delta' then
      s.streamed = true
      append(s, e.delta.text)
    elseif e.type == 'content_block_stop' and s.streamed then
      append(s, '\n')
    end
  elseif (t == 'assistant' or t == 'user') and not o.parent_tool_use_id then
    if t == 'user' and type(o.message.content) == 'string' then
      append(s, '\n' .. o.message.content:gsub('</?local%-command%-stdout>', '') .. '\n')
    else
      render_message(s, o, s.streamed)
    end
  elseif t == 'rate_limit_event' then
    G.quota = o.rate_limit_info and o.rate_limit_info.unifiedWindows
    hook_lualine()
  elseif t == 'control_request' and o.request.subtype == 'can_use_tool' then
    return ask_permission(s, o)
  elseif t == 'control_response' and o.response.subtype ~= 'success' then
    vim.notify('claude: ' .. vim.inspect(o.response), vim.log.levels.WARN)
  elseif t == 'result' then
    if o.is_error and o.result then append(s, '\n**error:** ' .. o.result) end
    append(s, '\n---\n')
    return set_state(s, 'idle')
  end
  winbar(s)
end

local function spawn(s)
  -- env -u: screenless Claude would otherwise prefer ANTHROPIC_API_KEY over the subscription login
  local cmd = { 'env', '-u', 'ANTHROPIC_API_KEY', 'claude', '-p', '--verbose',
    '--input-format', 'stream-json', '--output-format', 'stream-json', '--include-partial-messages',
    '--permission-prompts', 'host', '--permission-prompt-tool', 'stdio',
    s.resume and '--resume' or '--session-id', s.sid }
  if s.start_model and not s.resume then vim.list_extend(cmd, { '--model', s.start_model }) end
  local pending = ''
  s.proc = vim.system(cmd, {
    cwd = s.cwd,
    stdin = true,
    text = true,
    stdout = function(_, data)
      if not data then return end
      pending = pending .. data
      while true do
        local nl = pending:find('\n', 1, true)
        if not nl then break end
        local o = decode(pending:sub(1, nl - 1))
        pending = pending:sub(nl + 1)
        if o then vim.schedule(function() handle(s, o) end) end
      end
    end,
  }, function()
    s.proc = nil
  end)
  s.resume = true
end

local function stop(s, cb)
  local p = s.proc
  if not p then return cb() end
  p:write(nil) -- close stdin: claude -p exits
  vim.defer_fn(function()
    if s.proc then p:kill('sigterm') end
    cb()
  end, 1500)
end

---------------------------------------------------------------- chat actions
local function open_prompt(s)
  local w = vim.fn.bufwinid(s.pbuf)
  if w == -1 then
    api.nvim_set_current_win(vim.fn.bufwinid(s.tbuf))
    vim.cmd('belowright 8split')
    w = api.nvim_get_current_win()
    api.nvim_win_set_buf(w, s.pbuf)
    vim.wo[w].winfixheight = true
    vim.wo[w].winbar = ' prompt · <C-CR> send · <S-Tab> mode · <leader>aM model · <leader>at native Claude · :w store'
  end
  api.nvim_set_current_win(w)
end

local function send_prompt(s)
  if G.live[s.sid] and not s.proc then
    return vim.notify('Session is running in another Claude (tmux). View only in this spike.', vim.log.levels.WARN)
  end
  local lines = api.nvim_buf_get_lines(s.pbuf, 0, -1, false)
  for i, l in ipairs(lines) do
    lines[i] = l:gsub('^%[attach%]%s+(.+)$', '@%1') -- neomd-style placeholder -> Claude file mention
  end
  local text = vim.trim(table.concat(lines, '\n'))
  if text == '' then return end
  if not s.proc then spawn(s) end
  append(s, '\n## You\n\n' .. text .. '\n\n## Claude\n\n')
  send(s, { type = 'user', message = { role = 'user', content = text } })
  api.nvim_buf_set_lines(s.pbuf, 0, -1, false, { '' })
  vim.bo[s.pbuf].modified = false
  set_state(s, 'busy')
end

local function cycle_mode(s)
  if not s.proc then spawn(s) end
  local cur = s.mode == 'default' and 'manual' or s.mode
  local idx = 1
  for i, m in ipairs(MODES) do
    if m == cur then idx = i % #MODES + 1 end
  end
  control(s, { subtype = 'set_permission_mode', mode = MODES[idx] })
end

local function pick_model(s)
  vim.ui.select(MODELS, { prompt = 'Model' }, function(m)
    if not m then return end
    if not s.proc then spawn(s) end
    control(s, { subtype = 'set_model', model = m })
    s.model = m
    winbar(s)
  end)
end

local function attach(s)
  vim.ui.input({ prompt = 'Attach file: ', completion = 'file' }, function(path)
    if path and path ~= '' then api.nvim_buf_set_lines(s.pbuf, 0, 0, false, { '[attach] ' .. path }) end
  end)
end

-- escape hatch: same session in the real Claude Code screen, tmux pane beside us
local function handoff(s)
  if not vim.env.TMUX then return vim.notify('not inside tmux', vim.log.levels.WARN) end
  local chan = 'agentspike-' .. s.sid
  set_state(s, 'handed off to tmux pane')
  stop(s, function()
    vim.system({ 'tmux', 'split-window', '-h', '-c', s.cwd,
      ('claude --resume %s; tmux wait-for -S %s'):format(s.sid, chan) })
    vim.system({ 'tmux', 'wait-for', chan }, {}, function()
      vim.schedule(function()
        api.nvim_buf_set_lines(s.tbuf, 0, -1, false, { '' })
        s.marks = {}
        load_history(s) -- pick up turns made in the native screen
        set_state(s, 'idle')
      end)
    end)
  end)
end

local function save_prompt(s)
  local lines = api.nvim_buf_get_lines(s.pbuf, 0, -1, false)
  local text = vim.trim(table.concat(lines, ' '))
  if text == '' then return end
  local dir = PROMPTS_DIR .. '/' .. vim.fs.basename(s.cwd)
  vim.fn.mkdir(dir, 'p')
  local name = text:sub(1, 40):gsub('[^%w]+', '-'):gsub('^-+', ''):gsub('-+$', '')
  vim.fn.writefile(lines, dir .. '/' .. name .. '.md')
  vim.bo[s.pbuf].modified = false
  vim.notify('Saved prompt: ' .. name)
  render_drawer()
end

function _G.AgentSpikeComplete(findstart, base)
  local s = G.sessions[vim.b.agent_sid]
  if findstart == 1 then
    local start = vim.fn.getline('.'):sub(1, vim.fn.col('.') - 1):find('/[%w:_-]*$')
    return start and start - 1 or -3
  end
  return vim.tbl_filter(function(c) return vim.startswith(c, base) end,
    vim.tbl_map(function(c) return '/' .. c end, s and s.slash or {}))
end

---------------------------------------------------------------- layout
local function main_win()
  local keep
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if w ~= G.dwin and api.nvim_win_get_config(w).relative == '' then
      if not keep then keep = w else pcall(api.nvim_win_close, w, true) end
    end
  end
  if not keep then
    vim.cmd('leftabove vnew')
    keep = api.nvim_get_current_win()
    if G.dwin and api.nvim_win_is_valid(G.dwin) then api.nvim_win_set_width(G.dwin, 44) end
  end
  api.nvim_set_current_win(keep)
  vim.cmd('diffoff')
  return keep
end

local function get_session(cwd, sid, file)
  if sid and G.sessions[sid] then return G.sessions[sid] end
  local s = { cwd = cwd, sid = sid or vim.trim(vim.fn.system('uuidgen')), resume = sid ~= nil, file = file,
    model = '?', mode = '?', state = 'idle', slash = {}, marks = {} }
  G.sessions[s.sid] = s
  s.tbuf = api.nvim_create_buf(false, true)
  vim.bo[s.tbuf].filetype = 'markdown'
  s.pbuf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(s.pbuf, 'agent-prompt://' .. s.sid:sub(1, 8))
  vim.bo[s.pbuf].buftype, vim.bo[s.pbuf].filetype = 'acwrite', 'markdown'
  vim.bo[s.pbuf].completefunc = 'v:lua.AgentSpikeComplete'
  vim.b[s.pbuf].agent_sid = s.sid
  api.nvim_create_autocmd('BufWriteCmd', { buffer = s.pbuf, callback = function() save_prompt(s) end })
  for _, buf in ipairs({ s.pbuf, s.tbuf }) do
    local map = function(mode, lhs, fn) vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true }) end
    map({ 'n', 'i' }, '<C-CR>', function() send_prompt(s) end)
    map('n', '<leader><CR>', function() send_prompt(s) end)
    map('n', '<S-Tab>', function() cycle_mode(s) end)
    map('n', '<leader>aM', function() pick_model(s) end)
    map('n', '<leader>af', function() attach(s) end)
    map('n', '<leader>at', function() handoff(s) end)
    map('n', '<C-c>', function() control(s, { subtype = 'interrupt' }) end)
  end
  for _, k in ipairs({ 'i', 'a', 'o' }) do
    vim.keymap.set('n', k, function()
      open_prompt(s)
      vim.cmd('startinsert')
    end, { buffer = s.tbuf, nowait = true })
  end
  if s.resume then load_history(s) end
  return s
end

local function show_chat(s)
  local w = main_win()
  api.nvim_win_set_buf(w, s.tbuf)
  vim.wo[w].wrap, vim.wo[w].linebreak = true, true
  vim.wo[w].foldmethod, vim.wo[w].foldexpr = 'expr', 'v:lua.AgentSpikeFold(v:lnum)'
  vim.wo[w].foldlevel, vim.wo[w].foldtext, vim.wo[w].foldenable = 0, '', true
  winbar(s)
  follow(s)
  open_prompt(s)
  return s
end

local function scratch(name, lines, path)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines or {})
  pcall(api.nvim_buf_set_name, buf, name)
  vim.bo[buf].bufhidden, vim.bo[buf].modifiable = 'wipe', false
  vim.bo[buf].filetype = vim.filetype.match({ filename = path }) or ''
  return buf
end

-- left/right: { rev = 'abc' } (git show rev:path) or { file = true } (working tree)
local function show_diff(cwd, path, left, right)
  local function side(x)
    if x.file then
      vim.cmd('edit ' .. vim.fn.fnameescape(cwd .. '/' .. path))
    else
      api.nvim_win_set_buf(0, scratch(('%s:%s'):format(x.rev, path), git(cwd, 'show', x.rev .. ':' .. path), path))
    end
    vim.cmd('diffthis')
  end
  main_win()
  side(right)
  vim.cmd('leftabove vsplit')
  side(left)
  vim.cmd('wincmd l')
  if G.dwin and api.nvim_win_is_valid(G.dwin) then api.nvim_win_set_width(G.dwin, 44) end
end

---------------------------------------------------------------- drawer data
local function session_meta(path, mtime)
  local c = G.cache[path]
  if c and c.mtime == mtime then return c end
  local head = read(path, 256 * 1024)
  local title
  for t in head:gmatch('"aiTitle":"(.-)"[,}]') do title = t end
  if not title then
    local first = head:match('"type":"user".-"content":"(.-)"[,}]') or head:match('"content":"([^<"][^"]*)"')
    title = first and first:gsub('\\n', ' '):sub(1, 60)
  end
  c = { mtime = mtime, title = title or '(untitled)', cwd = head:match('"cwd":"(.-)"'),
    branch = head:match('"gitBranch":"(.-)"') }
  G.cache[path] = c
  return c
end

local function load_projects()
  local projects = {}
  for name, kind in vim.fs.dir(PROJECTS_DIR) do
    if kind == 'directory' then
      local dir = PROJECTS_DIR .. '/' .. name
      local sessions = {}
      for f, k in vim.fs.dir(dir) do
        if k == 'file' and f:sub(-6) == '.jsonl' then
          local st = uv.fs_stat(dir .. '/' .. f)
          if st then sessions[#sessions + 1] = { sid = f:sub(1, -7), path = dir .. '/' .. f, mtime = st.mtime.sec } end
        end
      end
      table.sort(sessions, function(a, b) return a.mtime > b.mtime end)
      if sessions[1] then
        local cwd = session_meta(sessions[1].path, sessions[1].mtime).cwd
        if cwd and not vim.startswith(cwd, '/tmp') then
          projects[#projects + 1] = { name = vim.fs.basename(cwd), cwd = cwd, dir = dir, sessions = sessions,
            mtime = sessions[1].mtime }
        end
      end
    end
  end
  table.sort(projects, function(a, b) return a.mtime > b.mtime end)
  G.projects = projects
end

local function load_git(p)
  if p.git then return p.git end
  local g = { changes = {}, commits = {} }
  if git(p.cwd, 'rev-parse', '--git-dir') then
    local head = git(p.cwd, 'symbolic-ref', '--short', 'refs/remotes/origin/HEAD')
    g.base = head and head[1]
    for _, b in ipairs({ 'main', 'master' }) do
      if not g.base and git(p.cwd, 'rev-parse', '--verify', '-q', b) then g.base = b end
    end
    local mb = g.base and git(p.cwd, 'merge-base', g.base, 'HEAD')
    g.mb = mb and mb[1] or 'HEAD'
    g.changes = git(p.cwd, 'diff', '--name-status', g.mb) or {}
    g.commits = git(p.cwd, 'log', '--format=%h %s', g.mb .. '..HEAD') or {}
    if #g.commits == 0 then
      g.commits = git(p.cwd, 'log', '-10', '--format=%h %s') or {}
      g.recent = true
    end
  end
  p.git = g
  return g
end

local function project_state(p)
  local best
  local rank = { busy = 3, waiting = 2, idle = 1 }
  for _, a in pairs(G.live) do
    if a.cwd == p.cwd and (rank[a.status] or 0) > (rank[best] or 0) then best = a.status end
  end
  for _, s in pairs(G.sessions) do
    if s.cwd == p.cwd and s.state ~= 'idle' then best = s.state:match('^waiting') and 'waiting' or 'busy' end
  end
  return best
end

---------------------------------------------------------------- drawer render
render_drawer = function()
  if not (G.dbuf and api.nvim_buf_is_valid(G.dbuf)) then return end
  local lines, nodes = {}, {}
  local function add(text, node)
    lines[#lines + 1] = text
    nodes[#lines] = node
  end
  local function section(p, key, label, count, fill)
    local k = p.dir .. '/' .. key
    local open = G.expanded[k]
    add(('  %s %s (%d)'):format(open and '▾' or '▸', label, count), { toggle = k })
    if open then fill() end
  end
  for _, p in ipairs(G.projects or {}) do
    local open = G.expanded[p.dir]
    local st = project_state(p)
    add(('%s %s  %s %s'):format(open and '▾' or '▸', p.name, ICON[st] or ' ', ago(p.mtime)), { toggle = p.dir, project = p })
    if open then
      add('    + New session', { new = p, project = p })
      section(p, 'sessions', 'Sessions', #p.sessions, function()
        for i, s in ipairs(p.sessions) do
          if i > 12 then break end
          local m = session_meta(s.path, s.mtime)
          local own = G.sessions[s.sid]
          local state = own and own.state ~= 'idle' and (own.state:match('^waiting') and 'waiting' or 'busy')
            or (G.live[s.sid] and G.live[s.sid].status)
          add(('      %s %s  %s'):format(ICON[state] or ' ', m.title, ago(s.mtime)), { session = s, project = p })
        end
      end)
      local pdir = PROMPTS_DIR .. '/' .. p.name
      local saved = vim.fn.glob(pdir .. '/*.md', false, true)
      section(p, 'prompts', 'Saved prompts', #saved, function()
        for _, f in ipairs(saved) do add('      ' .. vim.fn.fnamemodify(f, ':t:r'), { prompt = f, project = p }) end
      end)
      local g = load_git(p)
      section(p, 'changes', 'Changes vs ' .. (g.base or 'HEAD'), #g.changes, function()
        for _, c in ipairs(g.changes) do
          local status, path = c:match('^(%S+)%s+(.*)$')
          add(('      %s %s'):format(status, path), { change = path, status = status, project = p })
        end
      end)
      section(p, 'commits', g.recent and 'Recent commits' or 'Commits on branch', #g.commits, function()
        for _, c in ipairs(g.commits) do
          local hash = c:match('^(%S+)')
          local k = p.dir .. '/commit/' .. hash
          add(('      %s %s'):format(G.expanded[k] and '▾' or '▸', c), { toggle = k, project = p })
          if G.expanded[k] then
            for _, f in ipairs(git(p.cwd, 'diff-tree', '--root', '--no-commit-id', '--name-status', '-r', hash) or {}) do
              local status, path = f:match('^(%S+)%s+(.*)$')
              add(('          %s %s'):format(status, path), { commit = hash, change = path, status = status, project = p })
            end
          end
        end
      end)
    end
  end
  G.nodes = nodes
  vim.bo[G.dbuf].modifiable = true
  api.nvim_buf_set_lines(G.dbuf, 0, -1, false, lines)
  vim.bo[G.dbuf].modifiable = false
end

local function refresh_live()
  vim.system({ 'claude', 'agents', '--json' }, { text = true }, function(r)
    local list = r.code == 0 and decode(r.stdout) or {}
    vim.schedule(function()
      G.live = {}
      for _, a in ipairs(list) do
        if a.sessionId then G.live[a.sessionId] = a end
      end
      render_drawer()
    end)
  end)
end

local function drawer_enter()
  local n = G.nodes[api.nvim_win_get_cursor(0)[1]]
  if not n then return end
  local p = n.project
  if n.toggle then
    G.expanded[n.toggle] = not G.expanded[n.toggle]
    if n.toggle == (p and p.dir) and G.expanded[p.dir] and G.expanded[p.dir .. '/sessions'] == nil then
      G.expanded[p.dir .. '/sessions'] = true
    end
    render_drawer()
  elseif n.new then
    show_chat(get_session(p.cwd))
  elseif n.session then
    show_chat(get_session(p.cwd, n.session.sid, n.session.path))
  elseif n.prompt then
    local s = G.current and G.current.cwd == p.cwd and G.current or get_session(p.cwd)
    show_chat(s)
    api.nvim_buf_set_lines(s.pbuf, 0, -1, false, vim.fn.readfile(n.prompt))
  elseif n.commit then
    local parent = git(p.cwd, 'rev-parse', '--verify', '-q', n.commit .. '^') and n.commit .. '^' or nil
    show_diff(p.cwd, n.change, { rev = parent or n.commit }, { rev = n.commit })
  elseif n.change then
    show_diff(p.cwd, n.change, { rev = p.git.mb }, n.status == 'D' and { rev = p.git.mb } or { file = true })
  end
end

local function drawer_lazygit()
  local n = G.nodes[api.nvim_win_get_cursor(0)[1]]
  if not (n and n.project) then return end
  if _G.Snacks and Snacks.lazygit then
    Snacks.lazygit({ cwd = n.project.cwd })
  else
    vim.cmd('tabnew | terminal lazygit -p ' .. vim.fn.fnameescape(n.project.cwd))
  end
end

function M.open()
  vim.cmd('tabnew')
  local main = api.nvim_get_current_win()
  vim.cmd('botright 44vnew')
  G.dwin, G.dbuf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  vim.bo[G.dbuf].buftype, vim.bo[G.dbuf].filetype = 'nofile', 'agentspike'
  vim.wo[G.dwin].winfixwidth, vim.wo[G.dwin].number, vim.wo[G.dwin].relativenumber = true, false, false
  vim.wo[G.dwin].wrap, vim.wo[G.dwin].cursorline, vim.wo[G.dwin].signcolumn = false, true, 'no'
  local map = function(lhs, fn) vim.keymap.set('n', lhs, fn, { buffer = G.dbuf, nowait = true }) end
  map('<CR>', drawer_enter)
  map('za', drawer_enter)
  map('o', drawer_enter)
  map('gl', drawer_lazygit)
  map('q', function() vim.cmd('tabclose') end)
  map('R', function()
    load_projects()
    refresh_live()
  end)
  load_projects()
  local cwd = vim.fn.getcwd()
  for _, p in ipairs(G.projects) do
    if p.cwd == cwd then G.expanded[p.dir], G.expanded[p.dir .. '/sessions'] = true, true end
  end
  render_drawer()
  refresh_live()
  hook_lualine()
  if not G.timer then
    G.timer = uv.new_timer()
    G.timer:start(5000, 5000, vim.schedule_wrap(refresh_live))
  end
  api.nvim_create_autocmd('BufEnter', {
    callback = function(a)
      for _, s in pairs(G.sessions) do
        if a.buf == s.tbuf or a.buf == s.pbuf then G.current = s end
      end
    end,
  })
  return main
end

api.nvim_create_user_command('AgentSpike', function() M.open() end, { desc = 'Throwaway spike: agent drawer + chat + git' })

return M

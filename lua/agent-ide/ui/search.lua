-- The search picker: live results per keystroke over every session (or one project or one
-- session), a preview of the hit in its rendered turn, and actions on the hit. No plugin
-- dependency. Requests run one at a time: keys typed while one runs replace the query that
-- goes next, and a result for an outdated query is dropped.
local api = vim.api
local search = require('agent-ide.index.search')
local match = require('agent-ide.search.match')
local render = require('agent-ide.transcript.render')
local locate = require('agent-ide.transcript.locate')
local view = require('agent-ide.ui.search_view')
local act = require('agent-ide.ui.search_open')

local M = {}

M._debounce_ms = 8
local LIMIT = 100
local PREVIEW_MS = 25
local KIND_SETS = {
  { label = 'titles, prompts, answers', kinds = { 'title', 'prompt', 'answer' } },
  { label = 'prompts', kinds = { 'prompt' } },
  { label = 'answers', kinds = { 'answer' } },
  { label = 'titles', kinds = { 'title' } },
  { label = 'all + tool calls', kinds = { 'title', 'prompt', 'answer', 'tool' } },
}

local P -- the open picker

local function query() return P and api.nvim_buf_is_valid(P.v.input_buf) and (api.nvim_buf_get_lines(P.v.input_buf, 0, 1, false)[1] or '') or '' end

local function scope_param()
  if P.scope == 'project' and P.project then
    local ids = {}
    for _, s in ipairs(P.project.sessions or {}) do ids[#ids + 1] = s.id end
    return { project = P.project.key, sessions = ids }
  elseif P.scope == 'session' and P.session_id then
    return { session = P.session_id }
  end
  return 'all'
end

local function scope_label()
  if P.scope == 'project' and P.project then return 'project ' .. P.project.name end
  if P.scope == 'session' then return 'this session' end
  return 'all sessions'
end

local function update_title()
  local parts = { { text = ' ' .. (P.opts.title or 'Search') .. ' ' }, { text = '· ' .. scope_label() .. ' ' },
    { text = '· ' .. KIND_SETS[P.kind_set].label .. ' ' } }
  if P.backend == 'lua' then
    parts[#parts + 1] = { text = '· Lua fallback, limited: titles and prompts, exact words ', hl = 'AgentIdeSearchLimited' }
  elseif P.backend then
    parts[#parts + 1] = { text = '· helper ' }
  end
  view.set_title(P.v, parts)
end

local function selected() return P and P.hits[P.sel] end

-- Preview ------------------------------------------------------------------------------------

local function show_preview()
  local hit = selected()
  if not hit then return view.render_preview(P.v, {}, 1, {}, '', '') end
  local event = hit.event or 1
  local key = hit.path .. ':' .. event
  P.preview_gen = P.preview_gen + 1
  local gen = P.preview_gen
  local function draw(c)
    if not P or gen ~= P.preview_gen or not view.valid(P.v) then return end
    if not c.first then
      return view.render_preview(P.v, { '(this event is no longer in the transcript)' }, 1, {}, hit.title, hit.project)
    end
    local lines = render.render(c.events).lines
    local target = hit.event and locate.line_in_turn(c.events, hit.event - c.first + 1) or 1
    view.render_preview(P.v, lines, target, match.words(P.sent_query or ''), hit.title, hit.project)
  end
  if P.contexts[key] then return draw(P.contexts[key]) end
  search.context(hit.path, event, function(first, events)
    if not P then return end
    P.contexts[key] = { first = first, events = events }
    draw(P.contexts[key])
  end)
end

local function schedule_preview()
  P.preview_timer:stop()
  P.preview_timer:start(PREVIEW_MS, 0, vim.schedule_wrap(function() if P then show_preview() end end))
end

-- Results ------------------------------------------------------------------------------------

local function footer(res)
  local n = #P.hits
  local s = n == 0 and 'no hits' or (P.sel .. '/' .. n)
  if res and res.indexing then s = s .. ' · indexing ' .. (res.sessions or 0) .. ' sessions…' end
  return s
end

local function apply(res, q, t_key)
  -- a refresh of the same query (the index grew) keeps the selection
  local sel = q == P.sent_query and P.sel or 1
  P.hits, P.backend, P.sent_query = res.hits or {}, res.backend, q
  P.sel = math.max(1, math.min(sel, #P.hits))
  P.last = res
  update_title()
  local empty = res.indexing and 'indexing…' or (q:find('%S') and 'no matches' or 'nothing indexed yet')
  view.render_list(P.v, P.hits, P.sel, empty, footer(res))
  if t_key then P.stats = { ms = (vim.uv.hrtime() - t_key) / 1e6, query = q, hits = #P.hits, backend = res.backend } end
  schedule_preview()
end

local run

function run()
  if not P then return end
  if P.inflight then
    P.pending = true
    return
  end
  local q, t_key = query(), P.t_key
  P.inflight, P.pending = true, false
  search.search({ query = q, kinds = KIND_SETS[P.kind_set].kinds, scope = scope_param(), limit = LIMIT,
    projects = P.maps and P.maps.by_cwd or nil }, function(res)
    if not P then return end
    P.inflight = false
    if P.pending or not view.valid(P.v) then return run() end -- outdated: the newer query goes now
    apply(res, q, t_key)
  end)
end

local function changed()
  if not P then return end
  P.t_key = P.t_key or vim.uv.hrtime()
  P.timer:stop()
  P.timer:start(M._debounce_ms, 0, vim.schedule_wrap(function()
    if not P then return end
    run()
    P.t_key = nil
  end))
end

-- Actions ------------------------------------------------------------------------------------

local function move(d)
  if #P.hits == 0 then return end
  P.sel = (P.sel - 1 + d) % #P.hits + 1
  view.select(P.v, P.sel)
  view.set_footer(P.v, footer(P.last))
  schedule_preview()
end

function M.close()
  if not P then return end
  local p = P
  P = nil
  p.timer:stop(); p.timer:close()
  p.preview_timer:stop(); p.preview_timer:close()
  if p.unsub then p.unsub() end
  pcall(api.nvim_del_augroup_by_id, p.augroup)
  view.close(p.v)
  if api.nvim_get_mode().mode:sub(1, 1) == 'i' then vim.cmd('stopinsert') end
  if p.prev_win and api.nvim_win_is_valid(p.prev_win) then pcall(api.nvim_set_current_win, p.prev_win) end
end

-- The full text of the hit's event (the index keeps only the first 4 KiB), from its turn.
local function with_text(hit, cb)
  if hit.kind == 'title' then return cb(hit.title) end
  if hit.kind == 'tool' then return cb(hit.snippet) end
  search.context(hit.path, hit.event, function(first, events)
    local ev = first and events[hit.event - first + 1]
    cb(ev and type(ev.text) == 'string' and ev.text or hit.snippet)
  end)
end

local actions = {}

function actions.open()
  local hit, maps = selected(), P and P.maps
  if not hit then return end
  M.close()
  act.open(hit, maps)
end

function actions.copy()
  local hit = selected()
  if hit then with_text(hit, act.copy) end
end

function actions.reuse()
  local hit = selected()
  if not hit then return end
  if not act.prompt_target() then
    return vim.notify('Agent-IDE: no chat prompt is open in the Agents tab', vim.log.levels.INFO)
  end
  with_text(hit, function(text)
    M.close()
    act.reuse(text)
  end)
end

function actions.scope()
  local modes = { 'all' }
  if P.project then modes[#modes + 1] = 'project' end
  if P.session_id then modes[#modes + 1] = 'session' end
  local i = 1
  for k, m in ipairs(modes) do if m == P.scope then i = k end end
  P.scope = modes[i % #modes + 1]
  update_title()
  run()
end

function actions.kinds()
  P.kind_set = P.kind_set % #KIND_SETS + 1
  update_title()
  run()
end

local function map_keys(buf)
  local function map(modes, lhs, fn)
    vim.keymap.set(modes, lhs, function() if P then fn() end end, { buffer = buf, nowait = true, silent = true })
  end
  local both = { 'i', 'n' }
  for _, lhs in ipairs({ '<C-n>', '<Down>' }) do map(both, lhs, function() move(1) end) end
  for _, lhs in ipairs({ '<C-p>', '<Up>' }) do map(both, lhs, function() move(-1) end) end
  map('n', 'j', function() move(1) end)
  map('n', 'k', function() move(-1) end)
  map(both, '<CR>', actions.open)
  map(both, '<C-y>', actions.copy)
  map(both, '<C-r>', actions.reuse)
  map(both, '<Tab>', actions.scope)
  map(both, '<C-k>', actions.kinds)
  map('n', '<Esc>', M.close)
  map('n', 'q', M.close)
end

---Open the picker.
---@param opts? { query?: string, kinds?: string[], scope?: 'all'|'project'|'session', project?: table, title?: string }
function M.open(opts)
  opts = opts or {}
  M.close()
  require('agent-ide.ui.highlights').setup()
  local chat = require('agent-ide.ui.chat')
  local cur = chat.current()
  local kind_set = 1
  for i, set in ipairs(KIND_SETS) do
    if opts.kinds and vim.deep_equal(set.kinds, opts.kinds) then kind_set = i end
  end
  P = { opts = opts, hits = {}, sel = 1, contexts = {}, preview_gen = 0, kind_set = kind_set,
    scope = opts.scope or (opts.project and 'project') or 'all', project = opts.project,
    session_id = cur and cur.id, prev_win = api.nvim_get_current_win(),
    timer = vim.uv.new_timer(), preview_timer = vim.uv.new_timer() }
  P.v = view.create()
  update_title()
  view.render_list(P.v, {}, 1, 'searching…', '')
  local buf = P.v.input_buf
  map_keys(buf)
  if opts.query and opts.query ~= '' then api.nvim_buf_set_lines(buf, 0, -1, false, { opts.query }) end
  P.augroup = api.nvim_create_augroup('agent-ide.search', { clear = true })
  api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, { group = P.augroup, buffer = buf, callback = changed })
  api.nvim_create_autocmd('WinLeave', { group = P.augroup, buffer = buf, callback = function()
    vim.schedule(function()
      if P and api.nvim_get_current_win() ~= P.v.input_win then M.close() end
    end)
  end })
  api.nvim_create_autocmd('VimResized', { group = P.augroup, callback = function()
    local o = P.opts
    M.close()
    M.open(vim.tbl_extend('force', o, { query = query() }))
  end })
  P.unsub = search.on_ready(function() if P then run() end end)
  local mine = P
  act.projects(function(maps)
    if P ~= mine then return end
    P.maps = maps
    if not P.project then
      local s = cur and maps.by_id[cur.id]
      P.project = s or nil
    end
    if P.scope == 'project' and not P.project then P.scope = 'all' end
    update_title()
    run()
  end)
  vim.cmd('startinsert!')
end

---Test only: the open picker's state.
function M._state()
  if not P then return nil end
  return { hits = P.hits, sel = P.sel, scope = P.scope, kinds = KIND_SETS[P.kind_set].kinds, backend = P.backend,
    stats = P.stats, query = P.sent_query, wins = { input = P.v.input_win, list = P.v.list_win, preview = P.v.preview_win },
    bufs = { input = P.v.input_buf, list = P.v.list_buf, preview = P.v.preview_buf } }
end

return M

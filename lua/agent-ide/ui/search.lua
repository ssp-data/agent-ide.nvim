-- The search picker: live results per keystroke over every session (or one project or one
-- session), a preview of the hit in its rendered turn, and actions on the hit. No plugin
-- dependency. Requests run one at a time: keys typed while one runs replace the query that
-- goes next, and a result for an outdated query is dropped.
local api = vim.api
local search = require('agent-ide.index.search')
local render = require('agent-ide.transcript.render')
local locate = require('agent-ide.transcript.locate')
local view = require('agent-ide.ui.search_view')
local act = require('agent-ide.ui.search_open')
local keys = require('agent-ide.ui.search_keys')
local hl = require('agent-ide.ui.search_hl')

local M = {}

M._debounce_ms = 8
local LIMIT = 200
local HISTORY_LIMIT = 500 -- the helper's maximum: the prompt history shows this many, newest first
local CONTEXTS = 20 -- turns kept for the preview
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

-- Footer of the preview: where in the occurrences of the query it is, then the key hint.
local function preview_footer()
  local m, parts = P.marks, {}
  if m and m.cur then
    parts[1] = ('match %d/%d'):format(m.cur, #m.occ)
  elseif m and m.top then
    parts[1] = 'matched in title/project'
  end
  parts[#parts + 1] = keys.hint()
  return table.concat(parts, ' · ')
end

local function show_preview()
  local hit = selected()
  P.marks = nil
  if not hit then return view.render_preview(P.v, { lines = {}, folds = {} }, 1, nil, '', keys.hint()) end
  local event = hit.event or 1
  local key = hit.path .. ':' .. event
  P.preview_gen = P.preview_gen + 1
  local mine, gen = P, P.preview_gen
  local function draw(c)
    if P ~= mine or gen ~= P.preview_gen or not view.valid(P.v) then return end
    if not c.first then
      return view.render_preview(P.v, { lines = { '(this event is no longer in the transcript)' }, folds = {} }, 1, nil,
        hit.title, keys.hint())
    end
    local out = render.render(c.events)
    local target = hit.event and locate.line_in_turn(c.events, hit.event - c.first + 1) or 1
    local terms = hl.terms(P.sent_query or '', hit, out.lines)
    local occ = hl.occurrences(out.lines, terms)
    local cur = hl.pick(occ, target)
    P.marks = { occ = occ, cur = cur, top = not cur and hl.all_visible(terms), query = P.sent_query, session = hit.session }
    view.render_preview(P.v, out, target, P.marks, hit.title .. ' · ' .. (hit.project or '?'), preview_footer())
  end
  if P.contexts[key] then return draw(P.contexts[key]) end
  search.context(hit.path, event, function(first, events)
    if P ~= mine then return end
    if vim.tbl_count(P.contexts) >= CONTEXTS then P.contexts = {} end
    P.contexts[key] = { first = first, events = events }
    draw(P.contexts[key])
  end)
end

-- The preview's next (`d` = 1) or previous (-1) occurrence of the query, wrapping.
local function step_match(d)
  local m = P.marks
  if not (m and m.cur and view.valid(P.v)) then return end
  m.cur = (m.cur - 1 + d) % #m.occ + 1
  view.show_match(P.v, m.occ[m.cur], preview_footer())
end

local function schedule_preview()
  P.preview_timer:stop()
  P.preview_timer:start(PREVIEW_MS, 0, vim.schedule_wrap(function() if P then show_preview() end end))
end

-- Results ------------------------------------------------------------------------------------

local function prompts_only() return vim.deep_equal(KIND_SETS[P.kind_set].kinds, { 'prompt' }) end

local function footer(res)
  local n = #P.hits
  local s = n == 0 and 'no hits' or (P.sel .. '/' .. n)
  if res and res.total and res.shown and res.total > res.shown then
    s = s .. (' · newest %d of %d, type to narrow'):format(res.shown, res.total)
  end
  if res and res.indexing then s = s .. ' · indexing ' .. (res.sessions or 0) .. ' sessions…' end
  return s
end

-- Prompt history: the same prompt sent several times in a row is one row with a count.
local function collapse(hits)
  local out = {}
  for _, h in ipairs(hits) do
    local last = out[#out]
    if last and last.kind == 'prompt' and h.kind == 'prompt' and last.snippet == h.snippet then
      last.count = (last.count or 1) + 1
    else
      out[#out + 1] = h
    end
  end
  return out
end

local function apply(res, q, t_key)
  -- a refresh of the same query (the index grew) keeps the selection
  local sel = q == P.sent_query and P.sel or 1
  res.shown = #(res.hits or {})
  P.hits, P.backend, P.sent_query = res.hits or {}, res.backend, q
  if prompts_only() then P.hits = collapse(P.hits) end
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
  local q, t_key, mine = query(), P.t_key, P
  P.inflight, P.pending, P.t_key = true, false, nil
  local limit = (prompts_only() and not q:find('%S')) and HISTORY_LIMIT or LIMIT
  search.search({ query = q, kinds = KIND_SETS[P.kind_set].kinds, scope = scope_param(), limit = limit,
    projects = P.maps and P.maps.by_cwd or nil }, function(res)
    if P ~= mine then return end -- closed (or another picker opened) meanwhile
    P.inflight = false
    if P.pending and t_key then P.t_key = t_key end -- measured from the oldest key not yet served
    if P.pending or not view.valid(P.v) then return run() end -- outdated: the newer query goes now
    apply(res, q, t_key)
  end)
end

local function changed()
  if not P then return end
  P.t_key = P.t_key or vim.uv.hrtime()
  P.timer:stop()
  P.timer:start(M._debounce_ms, 0, vim.schedule_wrap(function()
    if P then run() end
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

local NO_TEXT = 'Agent-IDE: could not read the full text of this hit'

-- The full text of the hit's event (the index keeps only the first 4 KiB), read from its turn
-- in the transcript; never a snippet in its place: when it cannot be read, a notice instead.
local function with_text(hit, cb)
  if hit.kind == 'title' or hit.kind == 'project' then return cb(hit.title) end
  if hit.kind ~= 'prompt' and hit.kind ~= 'answer' then
    return vim.notify('Agent-IDE: only prompts, answers and titles can be copied', vim.log.levels.INFO)
  end
  search.context(hit.path, hit.event, function(first, events)
    local ev = first and events and act.event_index(events, hit, first)
    ev = ev and events[ev]
    if not (ev and type(ev.text) == 'string') then return vim.notify(NO_TEXT, vim.log.levels.WARN) end
    cb(ev.text)
  end)
end

local actions = {}

function actions.open()
  local hit, maps, q = selected(), P and P.maps, P and P.sent_query
  if not hit then return end
  M.close()
  act.open(hit, maps, q)
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
  local function guard(fn) return function() if P then fn() end end end
  keys.map(buf, {
    next = guard(function() move(1) end), prev = guard(function() move(-1) end), open = guard(actions.open),
    copy = guard(actions.copy), reuse = guard(actions.reuse), scope = guard(actions.scope),
    kinds = guard(actions.kinds), close = guard(M.close),
    next_match = guard(function() step_match(1) end), prev_match = guard(function() step_match(-1) end),
  })
end

---Open the picker.
---@param opts? { query?: string, kinds?: string[], scope?: 'all'|'project'|'session', project?: table, title?: string, sel?: integer, kind_set?: integer }
function M.open(opts)
  opts = opts or {}
  M.close()
  hl.clear_all() -- the highlights of the search before
  require('agent-ide.ui.highlights').setup()
  local chat = require('agent-ide.ui.chat')
  local cur = chat.current()
  local kind_set = 1
  for i, set in ipairs(KIND_SETS) do
    if opts.kinds and vim.deep_equal(set.kinds, opts.kinds) then kind_set = i end
  end
  -- in project scope (scope.lua) the picker starts on that project; <Tab> still widens to all
  local sp = not opts.scope and not opts.project and require('agent-ide.scope').project() or nil
  P = { opts = opts, hits = {}, sel = opts.sel or 1, sent_query = opts.sel and (opts.query or ''), contexts = {},
    preview_gen = 0, kind_set = opts.kind_set or kind_set,
    scope = opts.scope or ((opts.project or sp) and 'project') or 'all',
    project = opts.project or (sp and require('agent-ide.ui.drawer_model').in_scope({}, sp)[1]),
    session_id = cur and cur.id, prev_win = api.nvim_get_current_win(),
    timer = vim.uv.new_timer(), preview_timer = vim.uv.new_timer() }
  P.v = view.create()
  update_title()
  view.render_list(P.v, {}, 1, 'searching…', '')
  local buf = P.v.input_buf
  -- no completion menu in the query line (blink.cmp reads `b:completion`)
  vim.b[buf].completion = false
  local cmp = package.loaded['cmp']
  if type(cmp) == 'table' and type(cmp.setup) == 'table' and cmp.setup.buffer then pcall(cmp.setup.buffer, { enabled = false }) end
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
    -- reopen at the new size with what was chosen: query, scope, kinds, selection
    local o = vim.tbl_extend('force', P.opts, { query = query(), scope = P.scope, project = P.project,
      kind_set = P.kind_set, sel = P.sel })
    M.close()
    M.open(o)
  end })
  P.unsub = search.on_ready(function() if P then run() end end)
  local mine = P
  act.projects(function(maps)
    if P ~= mine then return end
    P.maps = maps
    if sp then P.project = require('agent-ide.ui.drawer_model').in_scope(maps.projects, sp)[1] end
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
    stats = P.stats, query = P.sent_query, marks = P.marks,
    wins = { input = P.v.input_win, list = P.v.list_win, preview = P.v.preview_win },
    bufs = { input = P.v.input_buf, list = P.v.list_buf, preview = P.v.preview_buf } }
end

return M

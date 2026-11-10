-- Limited search without the helper: session titles and prompts, exact matching only (no
-- fuzzy, no answers or tool calls). Hits have the helper's shape. Prompts are read from each
-- transcript once per change (asynchronous reads, at most a few ms of parsing per event-loop
-- turn) and kept in memory for this Neovim; the session list is rescanned when older than
-- RESCAN_S. Event indexes count the events of complete lines, as the helper does.
local lua_scan = require('agent-ide.index.lua_scan')
local match = require('agent-ide.search.match')
local parse = require('agent-ide.transcript.parse')
local uv = vim.uv

local M = {}

local SLICE_NS = 4e6 -- work per event-loop turn
local RESCAN_S = 5
local DEFAULT_KINDS = { title = true, prompt = true, answer = true }

local S = { dir = nil, metas = nil, scanned = 0, scanning = false, waiting = {}, docs = {}, queue = {}, busy = false,
  listeners = {} }

local function yield(fn) vim.defer_fn(fn, 0) end

local function notify_ready()
  for _, fn in ipairs(S.listeners) do pcall(fn) end
end

local function read_async(path, cb)
  uv.fs_open(path, 'r', 438, function(err, fd)
    if err or not fd then return vim.schedule(function() cb(nil) end) end
    uv.fs_fstat(fd, function(serr, st)
      if serr or not st then
        uv.fs_close(fd)
        return vim.schedule(function() cb(nil) end)
      end
      uv.fs_read(fd, st.size, 0, function(rerr, data)
        uv.fs_close(fd)
        vim.schedule(function() cb(not rerr and data or nil) end)
      end)
    end)
  end)
end

local function timestamp(line)
  local ok, rec = pcall(vim.json.decode, parse.fix_utf8(line), parse.DECODE_OPTS)
  return ok and type(rec) == 'table' and lua_scan.parse_timestamp(rec.timestamp) or nil
end

-- Prompts of the complete lines of `text`, parsed a slice at a time; `done(prompts)`.
local function index_text(text, done)
  local prompts, pos, n = {}, 1, 0
  local last = (text:match('.*()\n')) or 0 -- position of the last newline
  local function step()
    local t0 = uv.hrtime()
    while pos <= last do
      local nl = text:find('\n', pos, true)
      local line = text:sub(pos, nl - 1)
      pos = nl + 1
      if line ~= '' then
        local evs = parse.parse_record(line)
        local ts
        for i, ev in ipairs(evs) do
          if ev.kind == 'prompt' and not ev.sidechain and type(ev.text) == 'string' and ev.text:find('%S') then
            if ts == nil then ts = timestamp(line) or false end
            local t, cut = match.cap(ev.text, match.TEXT_CAP)
            prompts[#prompts + 1] = { event = n + i, ts = ts or nil, text = t, cut = cut, p = match.prepare(t) }
          end
        end
        n = n + #evs
      end
      if uv.hrtime() - t0 > SLICE_NS then return yield(step) end
    end
    done(prompts)
  end
  step()
end

local function pump()
  if S.busy then return end
  local meta = table.remove(S.queue, 1)
  if not meta then return notify_ready() end
  S.busy = true
  read_async(meta.path, function(text)
    local function finish(prompts)
      S.docs[meta.path] = { key = meta.mtime .. ':' .. meta.size, prompts = prompts }
      S.busy = false
      if #S.queue % 8 == 0 then notify_ready() end
      yield(pump)
    end
    if not text then return finish({}) end
    index_text(text, finish)
  end)
end

local function enqueue(metas)
  S.queue = {}
  for _, m in ipairs(metas) do
    local d = S.docs[m.path]
    if not d or d.key ~= m.mtime .. ':' .. m.size then S.queue[#S.queue + 1] = m end
  end
  pump()
end

local function with_sessions(dir, cb)
  local fresh = S.dir == dir and S.metas and os.time() - S.scanned < RESCAN_S
  if S.dir == dir and S.metas then cb(S.metas) end
  if fresh or (S.scanning and S.dir == dir) then
    if not S.metas then S.waiting[#S.waiting + 1] = cb end
    return
  end
  if S.dir ~= dir then S.dir, S.metas, S.docs = dir, nil, {} end
  if not S.metas then S.waiting[#S.waiting + 1] = cb end
  S.scanning = true
  lua_scan.scan(dir, function(metas)
    if S.dir ~= dir then return end
    S.metas, S.scanned, S.scanning = metas, os.time(), false
    enqueue(metas)
    local waiting = S.waiting
    S.waiting = {}
    for _, w in ipairs(waiting) do w(metas) end
  end)
end

local KIND_RANK = { title = 0, prompt = 1, answer = 2, tool = 3, project = 4 }
local QUALITY = { substring = 1, prefix = 2, recent = 3 }

local function order(empty)
  return function(a, b)
    local ta, tb = a.ts or 0, b.ts or 0
    if empty then
      if ta ~= tb then return ta > tb end
      if a.kind ~= b.kind then return KIND_RANK[a.kind] < KIND_RANK[b.kind] end
    else
      if a.kind ~= b.kind then return KIND_RANK[a.kind] < KIND_RANK[b.kind] end
      if a.match ~= b.match then return QUALITY[a.match] > QUALITY[b.match] end
      if ta ~= tb then return ta > tb end
    end
    if a.session ~= b.session then return a.session < b.session end
    return (a.event or 0) < (b.event or 0)
  end
end

local function in_scope(m, scope)
  if type(scope) ~= 'table' then return true end
  if scope.session then return m.id == scope.session end
  if scope.project then return vim.tbl_contains(scope.sessions or {}, m.id) end
  return true
end

local function project_of(m, projects)
  if not m.cwd then return '?' end
  return projects[m.cwd] or m.cwd:match('([^/]*)$')
end

---@param params table as the helper's `search` request
---@param cb fun(result: table)
function M.search(params, cb)
  local dir = params.projects_dir
  with_sessions(dir, function(metas)
    local words = match.words(params.query)
    local empty = #words == 0
    local kinds = {}
    for _, k in ipairs(params.kinds or {}) do kinds[k] = true end
    if next(kinds) == nil then kinds = DEFAULT_KINDS end
    local projects = params.projects or {}
    local found, chunks, i = {}, 0, 1
    local function add(m, kind, item, quality, text)
      found[#found + 1] = { m = m, kind = kind, item = item, match = quality, text = text,
        session = m.id, event = item and item.event, ts = item and item.ts or (not item and m.activity) or nil }
    end
    local function step()
      local t0 = uv.hrtime()
      while i <= #metas do
        local m = metas[i]
        i = i + 1
        local doc = S.docs[m.path]
        if doc then chunks = chunks + #doc.prompts end
        if in_scope(m, params.scope) then
          local project = project_of(m, projects)
          if kinds.title then
            local q, via = 'recent', false
            if not empty then q, via = match.match(match.prepare(m.title), words, project) end
            -- a session found through its project's name ranks after every other hit
            if q then add(m, via and 'project' or 'title', nil, q, m.title) end
          end
          if kinds.prompt and doc then
            for _, pr in ipairs(doc.prompts) do
              local q = empty and 'recent' or match.match(pr.p, words)
              if q then add(m, 'prompt', pr, q, pr.text) end
            end
          end
        end
        if uv.hrtime() - t0 > SLICE_NS then return yield(step) end
      end
      table.sort(found, order(empty))
      local hits = {}
      for k = 1, math.min(#found, math.max(1, math.min(params.limit or 50, 500))) do
        local f = found[k]
        local at = 1
        for _, w in ipairs(words) do
          local s = match.exact(f.item and f.item.p or match.prepare(f.text), w)
          if s then at = s; break end
        end
        if empty then at = f.text:find('%S') or 1 end
        local snippet, positions = match.snippet(f.text, at, words)
        hits[k] = { session = f.m.id, path = f.m.path, cwd = f.m.cwd, project = project_of(f.m, projects),
          title = f.m.title, kind = f.kind, event = f.event, ts = f.ts, snippet = snippet, positions = positions,
          match = f.match, score = 0 }
      end
      cb({ hits = hits, total = #found, indexing = S.busy or #S.queue > 0 or S.scanning, sessions = #metas, chunks = chunks,
        backend = 'lua', limited = true })
    end
    step()
  end)
end

---Call `fn` when more of the index is ready (the picker searches again).
function M.on_ready(fn) S.listeners[#S.listeners + 1] = fn end

---Test only: forget everything.
function M._reset()
  S = { dir = nil, metas = nil, scanned = 0, scanning = false, waiting = {}, docs = {}, queue = {}, busy = false,
    listeners = {} }
end

return M

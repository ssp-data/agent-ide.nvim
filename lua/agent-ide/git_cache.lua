-- Per-repository cache of git data for the drawer and the diff view. Getters return what is
-- known (nil while unknown) and start a load when needed. `invalidate` bumps the generation and
-- reloads what was loaded; the old data stays visible until the new arrives, and results of an
-- older generation are dropped. Commit files never change for a hash, so they survive.
local git = require('agent-ide.git')

local M = {}

local CHECK_AFTER = 5 -- seconds between status checks of one repository

local entries = {} -- root -> entry
local listeners = {}

local function now() return vim.uv.now() / 1000 end

local function entry(root)
  local e = entries[root]
  if not e then
    e = { gen = 0, data = {}, loaded = {}, loading = {}, base_waiters = nil, checked = now() }
    entries[root] = e
  end
  return e
end

local function emit(root, kind)
  for _, fn in ipairs(vim.list_slice(listeners)) do
    local ok, err = pcall(fn, root, kind)
    if not ok then vim.notify('Agent-IDE: git listener failed: ' .. tostring(err), vim.log.levels.WARN) end
  end
end

-- Run `start(done)` once per generation for `kind`; `done(value)` stores and tells listeners.
-- Commit files (`files:<hash>`) never change: their loads ignore generations.
local function load(root, kind, start)
  local e = entry(root)
  local stable = kind:find('^files:') ~= nil
  if e.loading[kind] ~= nil and (stable or e.loading[kind] == e.gen) then return end
  e.loading[kind] = e.gen
  local gen = e.gen
  start(function(value)
    if entries[root] ~= e or (not stable and e.gen ~= gen) then return end
    e.loading[kind] = nil
    e.data[kind], e.loaded[kind] = value, true
    emit(root, kind)
  end, e)
end

-- The base of the current generation, shared by the changes and commits loads.
local function with_base(root, e, cb)
  local gen = e.gen
  if e.base_gen == gen then return cb(e.data.base) end
  if e.base_waiters and e.base_waiters.gen == gen then
    table.insert(e.base_waiters, cb)
    return
  end
  e.base_waiters = { gen = gen, cb }
  git.base(root, function(b)
    if entries[root] ~= e or e.gen ~= gen then return end
    local waiters = e.base_waiters
    e.base_waiters, e.base_gen = nil, gen
    e.data.base, e.loaded.base = b, true
    if b then e.data.head, e.loaded.head = b, true end
    emit(root, 'base')
    for _, w in ipairs(waiters) do w(b) end
  end)
end

local function snapshot(root, e)
  local gen = e.gen
  git.signature(root, function(sig)
    if entries[root] == e and e.gen == gen then e.sig, e.checked = sig, now() end
  end, { background = true })
end

local loaders = {
  head = function(root)
    load(root, 'head', function(done, e)
      git.head(root, function(h)
        done(h)
        snapshot(root, e)
      end, { background = true })
    end)
  end,
  base = function(root)
    local e = entry(root)
    with_base(root, e, function() end)
  end,
  changes = function(root)
    load(root, 'changes', function(done, e)
      with_base(root, e, function(b)
        local gen = e.gen
        git.changes(root, function(files)
          done(files)
          snapshot(root, e)
        end, b, function()
          -- untracked line counts were filled into the same tables: one more re-render
          if entries[root] == e and e.gen == gen then emit(root, 'changes') end
        end)
      end)
    end)
  end,
  commits = function(root)
    load(root, 'commits', function(done, e)
      with_base(root, e, function(b) git.commits(root, done, b) end)
    end)
  end,
  -- the files of the commits scope of the full diff: the branch's commits against their start
  -- (git_patch.start), committed changes only
  committed = function(root)
    load(root, 'committed', function(done, e)
      with_base(root, e, function(b) require('agent-ide.git_patch').committed(root, b, done) end)
    end)
  end,
  -- what is not committed yet: the working tree and the index against HEAD, untracked files
  -- included (the same query as the branch changes, with HEAD for the base)
  uncommitted = function(root)
    load(root, 'uncommitted', function(done, e)
      local gen = e.gen
      git.changes(root, function(files) done(files) end, { rev = 'HEAD', label = 'HEAD' }, function()
        if entries[root] == e and e.gen == gen then emit(root, 'uncommitted') end
      end)
    end)
  end,
}

---@param root string
---@return table|nil head (branch, detached, default_name, ...), loaded in the background
function M.head(root)
  local e = entry(root)
  if e.data.head == nil and not e.loaded.head then loaders.head(root) end
  return e.data.head
end

---@return table|nil base (see git.base)
function M.base(root)
  local e = entry(root)
  if not e.loaded.base then loaders.base(root) end
  return e.data.base
end

---@return table[]|nil files, table|nil base
function M.changes(root)
  local e = entry(root)
  if not e.loaded.changes then loaders.changes(root) end
  return e.data.changes, e.data.base
end

---@return table[]|nil commits, table|nil base
function M.commits(root)
  local e = entry(root)
  if not e.loaded.commits then loaders.commits(root) end
  return e.data.commits, e.data.base
end

---@return table[]|nil files of the branch's commits (merge-base to HEAD; the listed recent commits on the default branch)
function M.committed(root)
  local e = entry(root)
  if not e.loaded.committed then loaders.committed(root) end
  return e.data.committed
end

---@return table[]|nil files changed in the working tree and the index against HEAD (untracked too)
function M.uncommitted(root)
  local e = entry(root)
  if not e.loaded.uncommitted then loaders.uncommitted(root) end
  return e.data.uncommitted
end

---@param root string
---@param hash string
---@return table[]|nil files of that commit
function M.commit_files(root, hash)
  local kind = 'files:' .. hash
  local e = entry(root)
  if not e.loaded[kind] then
    load(root, kind, function(done) git.commit_files(root, hash, done) end)
  end
  return e.data[kind]
end

local getters -- kind -> getter, filled below

---Call `cb(value)` once `kind` ('changes', 'commits', 'committed', 'uncommitted', 'base', 'files:<hash>') of `root` is
---loaded (at once when it already is), starting the load when needed.
---@param root string
---@param kind string
---@param cb fun(value: any)
function M.when(root, kind, cb)
  local function value()
    local hash = kind:match('^files:(.+)$')
    if hash then return M.commit_files(root, hash) end
    return getters[kind](root)
  end
  local v = value()
  if entry(root).loaded[kind] then return cb(v) end
  local function on(r, k)
    if r == root and k == kind and entry(root).loaded[kind] then
      M.off_update(on)
      cb(entry(root).data[kind])
    end
  end
  M.on_update(on)
end

---The entry of `root` without starting anything (nil when unknown).
function M.peek(root) return entries[root] end

---@return string[] roots with an entry
function M.roots() return vim.tbl_keys(entries) end

---Reload what was loaded for `root`, keeping the old data until the new arrives.
---@param root string
function M.invalidate(root)
  local e = entries[root]
  if not e then return end
  e.gen = e.gen + 1
  local kinds, seen = {}, {}
  local function add(kind)
    if not kind:find('^files:') and not seen[kind] then
      seen[kind] = true
      kinds[#kinds + 1] = kind
    end
  end
  -- what was loaded, and what is still loading: its answer is dropped, so it starts again
  for kind in pairs(e.loaded) do add(kind) end
  for kind in pairs(e.loading) do add(kind) end
  if e.base_waiters then add('base') end
  local keep = {}
  for kind, v in pairs(e.loading) do
    if kind:find('^files:') then keep[kind] = v end
  end
  e.loading, e.base_waiters, e.base_gen = keep, nil, nil
  for _, kind in ipairs(kinds) do e.loaded[kind] = nil end
  for _, kind in ipairs(kinds) do
    if kind == 'head' and seen.base then
      -- head comes with the base
    elseif loaders[kind] then
      loaders[kind](root)
    end
  end
  emit(root, 'invalidate')
end

---Cheap status-level check: invalidate when HEAD or the working tree status changed since the
---last load or check. Does nothing within 5 s of the previous one or for unloaded repositories.
---@param root string
function M.check(root)
  local e = entries[root]
  if not e or not (e.loaded.changes or e.loaded.commits or e.loaded.head) or now() - e.checked < CHECK_AFTER then return end
  e.checked = now()
  local gen, before = e.gen, e.sig
  git.signature(root, function(sig)
    if entries[root] ~= e or e.gen ~= gen then return end
    if sig ~= before then
      M.invalidate(root)
    end
  end, { background = true })
end

---@param fn fun(root: string, kind: string)
function M.on_update(fn)
  M.off_update(fn)
  listeners[#listeners + 1] = fn
end

function M.off_update(fn)
  for i, f in ipairs(listeners) do
    if f == fn then return table.remove(listeners, i) end
  end
end

getters = { changes = M.changes, commits = M.commits, base = M.base, head = M.head, uncommitted = M.uncommitted,
  committed = M.committed }

---Test only: store `value` as loaded data of `kind` (bumps the generation: running loads are dropped).
function M._set(root, kind, value)
  local e = entry(root)
  e.gen = e.gen + 1
  e.loading, e.base_waiters = {}, nil
  e.data[kind], e.loaded[kind] = value, true
  if kind == 'base' then e.base_gen = e.gen end
  for k in pairs(e.loaded) do
    if k == 'base' then e.base_gen = e.gen end
  end
end

---Test only: forget everything (listeners stay).
function M._reset() entries = {} end

return M

-- Deleting a session (drawer `D`) moves what Claude Code keeps of it into the plugin's trash,
-- `stdpath('data')/agent-ide/trash/<YYYYMMDD-HHMMSS>-<id>/`, and `:AgentsTrash` restores or
-- purges it. This is the plugin's only write under a `.claude` folder, and only for one
-- confirmed session. What belongs to session <id> in Claude's folder <claude> (the parent of
-- `projects_dir`):
--   projects/<slug>/<id>.jsonl (the transcript), projects/<slug>/<id>/ (subagents, tool
--   results), file-history/<id>/, session-env/<id>/, tasks/<id>/ (each when present), and the
--   lines of history.jsonl whose `sessionId` is <id> (the prompts typed).
-- Moved entries keep their layout below the trash folder; the history lines go to its own
-- `history.jsonl`; `manifest.json` lists what came from where. Every path is checked to be
-- inside <claude> (links resolved) and named after the id; a symbolic link is never moved.
--
-- The order of a delete keeps every byte on disk somewhere at every moment: (1) the trash
-- folder, (2) a manifest with `complete = false` listing what will move, (3) the session's
-- history lines written to the trash, (4) the entries moved, (5) Claude's history.jsonl
-- rewritten without them, (6) the manifest rewritten with `complete = true`. A failure undoes
-- the steps in reverse, checking each; when one cannot be undone the trash folder stays (listed
-- as incomplete, restorable, never purged by age) and the message says what is where.
local uv = vim.uv
local jsonfile = require('agent-ide.util.jsonfile')
local fs = require('agent-ide.trash_fs')
local history = require('agent-ide.trash_history')

local M = {}

local DIR_MODE, FILE_MODE = 448, 384 -- 0700, 0600
local UUID = '^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$'

M.split_history, M.merge_history = history.split, history.merge

-- Test seam: run at the start of each step of a delete ('folder', 'manifest', 'history_copy',
-- 'move', 'history', 'complete'); a string it returns fails that step with it.
M._step = nil

---@param id string
---@return boolean
function M.valid_id(id) return type(id) == 'string' and id:match(UUID) ~= nil end

---Claude's folder: the parent of `projects_dir`, links resolved; nil and why when
---`projects_dir` is not an absolute path or the folder does not exist (a relative one would
---resolve against the current, tab-local, folder).
---@return string|nil dir, string|nil err
function M.claude_dir()
  local pd = require('agent-ide.config').get().projects_dir
  local dir = type(pd) == 'string' and pd ~= '' and vim.fs.normalize(pd) or ''
  if dir:sub(1, 1) ~= '/' then return nil, 'projects_dir is not an absolute path' end
  local real = uv.fs_realpath(vim.fs.dirname(dir))
  if not real then return nil, 'Claude\'s folder not found' end
  return real
end

---The plugin's trash folder.
---@return string
function M.dir() return vim.fn.stdpath('data') .. '/agent-ide/trash' end

local function inside(path, root) return root ~= nil and vim.startswith(path, root .. '/') end

-- Entry `rel` below `claude` for session `id`, or nil and why it may not be moved. `name` must
-- be the id or `<id>.jsonl`; the folder holding it must resolve inside `claude`; nothing in it
-- may be a special file.
local function check(claude, rel, id)
  local abs = claude .. '/' .. rel
  local name = vim.fs.basename(abs)
  if name ~= id and name ~= id .. '.jsonl' then return nil, 'not named after the session: ' .. rel end
  local st = uv.fs_lstat(abs)
  if not st then return false end -- not there: nothing to move
  if st.type == 'link' then return nil, 'a symbolic link: ' .. rel end
  local parent = uv.fs_realpath(vim.fs.dirname(abs))
  if not parent or not (parent == claude or inside(parent, claude)) then return nil, 'outside Claude\'s folder: ' .. rel end
  local _, serr = fs.scan(abs)
  if serr then return nil, serr end
  return { rel = rel, path = parent .. '/' .. name, kind = st.type == 'directory' and 'dir' or 'file' }
end

---What deleting session `id` (transcript at `path`) would move; nil and a reason when it may not.
---@param id string
---@param path string the transcript
---@return table[]|nil entries { rel, path, kind }, string|nil err
function M.plan(id, path)
  if not M.valid_id(id) then return nil, 'not a session id' end
  local claude, cerr = M.claude_dir()
  if not claude then return nil, cerr end
  local real = path and uv.fs_realpath(vim.fs.dirname(path))
  if not real or vim.fs.basename(path) ~= id .. '.jsonl' or not inside(real, claude .. '/projects') then
    return nil, 'the transcript is not in Claude\'s projects folder'
  end
  local slug = real:sub(#claude + #'/projects/' + 1)
  if slug == '' or slug:find('/', 1, true) then return nil, 'unexpected transcript folder' end
  local out = {}
  for _, rel in ipairs({ 'projects/' .. slug .. '/' .. id .. '.jsonl', 'projects/' .. slug .. '/' .. id,
    'file-history/' .. id, 'session-env/' .. id, 'tasks/' .. id }) do
    local e, err = check(claude, rel, id)
    if e == nil then return nil, err end
    if e then out[#out + 1] = e end
  end
  if #out == 0 or out[1].kind ~= 'file' then return nil, 'transcript not found' end
  return out
end

-- history.jsonl --------------------------------------------------------------------------------

local function read(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local t = f:read('a')
  f:close()
  return t
end

local HELD = 'a running Claude has its history file open; close it or try later'

-- Refused while another process keeps Claude's history.jsonl open (Linux; see trash_history).
local function held(claude)
  local pids = history.holders(claude .. '/history.jsonl')
  if pids and #pids > 0 then return HELD .. ' (pid ' .. table.concat(pids, ', ') .. ')' end
end

-- Put `lines` (each ending in a newline) back into Claude's history.jsonl, skipping lines that
-- are there already (an unfinished delete may not have removed them).
local function give_history(claude, lines)
  if lines == '' then return true end
  return history.rewrite(claude .. '/history.jsonl', { create = true, transform = function(text)
    local have = {}
    for line in text:gmatch('[^\n]*\n?') do
      if line ~= '' then have[line:sub(-1) == '\n' and line or (line .. '\n')] = true end
    end
    local missing = {}
    for line in lines:gmatch('[^\n]*\n') do
      if not have[line] then missing[#missing + 1] = line end
    end
    if #missing == 0 then return nil end
    return history.merge(text, table.concat(missing))
  end })
end

-- Delete ---------------------------------------------------------------------------------------

local function manifest_text(fields, entries, complete, n)
  return vim.json.encode({ version = 1, id = fields.id, complete = complete, deleted_at = fields.now,
    title = fields.title, project = fields.project, claude_dir = fields.claude, history_lines = n,
    entries = vim.tbl_map(function(e) return { rel = e.rel, path = e.path, kind = e.kind } end, entries) })
end

---Move session `id` (transcript `path`) into the trash; see the order at the top. On success
---the trash folder, and the paths that could not be removed from Claude's folder after their
---verified copy (a move across file systems), if any.
---@param id string
---@param path string
---@param info { title?: string, project?: string }
---@return string|nil trash folder, string|nil err, string[]|nil left
function M.delete(id, path, info)
  local entries, err = M.plan(id, path)
  if not entries then return nil, err end
  local claude = assert(M.claude_dir())
  local hpath = claude .. '/history.jsonl'
  local busy = held(claude)
  if busy then return nil, busy end
  history.remove_stale_tmp(hpath)
  local root = M.dir()
  if not fs.mkdirs(root, {}) then return nil, 'cannot create the trash folder' end
  pcall(uv.fs_chmod, root, DIR_MODE)
  local now = os.time()
  local dir = ('%s/%s-%s'):format(root, os.date('%Y%m%d-%H%M%S', now), id)
  if uv.fs_lstat(dir) then return nil, 'already in the trash: ' .. dir end
  local fields = { id = id, now = now, title = info and info.title or nil, project = info and info.project or nil, claude = claude }
  local function step(name) return M._step and M._step(name) end

  -- what has been done, for the undo
  local made_dir, wrote_manifest, wrote_history, renamed = false, false, false, false
  local moved, created, left = {}, {}, {}
  local removed, n, pending = '', 0, ''

  local function undo(reason)
    local problems = {}
    -- (5) Claude's history.jsonl was rewritten: its lines go back
    if renamed then
      if pending ~= '' and not jsonfile.write_atomic(dir .. '/history.other.jsonl', pending, FILE_MODE) then
        problems[#problems + 1] = 'lines of other sessions could not be saved'
      end
      local ok, gerr = give_history(claude, removed .. pending)
      if not ok then
        problems[#problems + 1] = ('the session\'s history lines are not back in %s (they are in %s/history.jsonl%s): %s')
          :format(hpath, dir, pending ~= '' and ' and history.other.jsonl' or '', tostring(gerr))
      end
    end
    -- (4) entries back, last first, each checked at its place
    for i = #moved, 1, -1 do
      local e = moved[i]
      local from = dir .. '/' .. e.rel
      if e.left then
        problems[#problems + 1] = ('%s was only partly removed; its full copy is in %s'):format(e.path, from)
      else
        local ok, merr, l = fs.move(from, e.path, {})
        if not ok or not uv.fs_lstat(e.path) then
          problems[#problems + 1] = ('%s could not be put back; it is in %s (%s)'):format(e.path, from, tostring(merr))
        elseif l then
          problems[#problems + 1] = 'put back, but left in the trash: ' .. table.concat(l, ', ')
        end
      end
    end
    -- (3), (2), (1): only when everything is back; what this delete made, nothing recursive
    if #problems == 0 and made_dir then
      if wrote_history then uv.fs_unlink(dir .. '/history.jsonl') end
      if wrote_manifest then uv.fs_unlink(dir .. '/manifest.json') end
      fs.cleanup(dir, created)
    end
    if #problems > 0 then
      return nil, ('%s; %s (the trash folder %s is kept)'):format(reason, table.concat(problems, '; '), dir)
    end
    return nil, reason
  end

  -- (1) the trash folder
  local serr = step('folder')
  if serr or not uv.fs_mkdir(dir, DIR_MODE) then return nil, serr or ('cannot create ' .. dir) end
  made_dir = true
  -- (2) the manifest, not complete yet
  serr = step('manifest')
  local ok, werr
  if not serr then ok, werr = jsonfile.write_atomic(dir .. '/manifest.json', manifest_text(fields, entries, false, nil), FILE_MODE) end
  if serr or not ok then return undo(serr or ('cannot write the manifest: ' .. tostring(werr))) end
  wrote_manifest = true
  -- (3) the session's history lines into the trash, before Claude's file is touched
  local function save_removed(text)
    local wok, e = jsonfile.write_atomic(dir .. '/history.jsonl', text, FILE_MODE)
    if wok then wrote_history = true end
    return wok, e
  end
  serr = step('history_copy')
  if serr then return undo(serr) end
  local hst = uv.fs_lstat(hpath)
  if hst and hst.type ~= 'file' then return undo('history.jsonl is not a plain file') end
  if hst then
    local text = read(hpath)
    if not text then return undo('cannot read ' .. hpath) end
    local _, r, c = history.split(text, id)
    if c > 0 then
      ok, werr = save_removed(r)
      if not ok then return undo('cannot write the trash\'s history.jsonl: ' .. tostring(werr)) end
      removed, n = r, c
    end
  end
  -- (4) the entries
  serr = step('move')
  if serr then return undo(serr) end
  for _, e in ipairs(entries) do
    local mok, merr, l = fs.move(e.path, dir .. '/' .. e.rel, created)
    if not mok then return undo(merr) end
    moved[#moved + 1] = e
    if l then
      e.left = l
      vim.list_extend(left, l)
    end
  end
  -- (5) Claude's history.jsonl without the session's lines
  serr = step('history')
  if serr then return undo(serr) end
  local changed = false
  local hok, herr, hinfo = history.rewrite(hpath, {
    transform = function(text)
      local kept, r, c = history.split(text, id)
      changed = c > 0
      if c == 0 then return nil end
      if r ~= removed then -- more of its lines than at (3): saved first
        local sok, e = save_removed(r)
        if not sok then return nil, 'cannot write the trash\'s history.jsonl: ' .. tostring(e) end
        removed, n = r, c
      end
      return kept
    end,
    on_extra = function(extra)
      local kept, r, c = history.split(extra, id)
      if c > 0 then
        local sok, e = save_removed(removed .. r)
        if not sok then return nil, 'cannot write the trash\'s history.jsonl: ' .. tostring(e) end
        removed, n = removed .. r, n + c
      end
      return kept
    end,
  })
  if not hok then
    if hinfo and hinfo.renamed then renamed, pending = true, hinfo.pending or '' end
    return undo(herr)
  end
  renamed = changed
  -- (6) complete
  serr = step('complete')
  if not serr then ok, werr = jsonfile.write_atomic(dir .. '/manifest.json', manifest_text(fields, entries, true, n), FILE_MODE) end
  if serr or not ok then return undo(serr or ('cannot write the manifest: ' .. tostring(werr))) end
  return dir, nil, #left > 0 and left or nil
end

-- Trash listing, restore, purge ------------------------------------------------------------------

-- The manifest of trash folder `dir`, or nil.
local function manifest_of(dir)
  local m = jsonfile.decode(read(dir .. '/manifest.json'))
  if m and M.valid_id(m.id) then return m end
end

---Trashed sessions, newest first: { dir, manifest, name, incomplete }. `incomplete`: a delete
---that did not finish (its manifest says `complete = false`); restorable, never purged by age.
---@return { dir: string, manifest: table, name: string, incomplete: boolean }[]
function M.list()
  local out = {}
  local h = uv.fs_scandir(M.dir())
  while h do
    local name, typ = uv.fs_scandir_next(h)
    if not name then break end
    if typ == 'directory' then
      local dir = M.dir() .. '/' .. name
      local m = manifest_of(dir)
      if m then out[#out + 1] = { dir = dir, manifest = m, name = name, incomplete = m.complete == false } end
    end
  end
  table.sort(out, function(a, b) return a.name > b.name end)
  return out
end

-- A folder directly in the trash.
local function in_trash(dir)
  local real = uv.fs_realpath(dir)
  local root = uv.fs_realpath(M.dir())
  return real ~= nil and root ~= nil and vim.fs.dirname(real) == root
end

---Delete one trashed session for good.
---@param dir string
---@return boolean ok, string|nil err
function M.purge(dir)
  if not in_trash(dir) then return false, 'not in the trash' end
  -- a read-only folder kept from the session (modes are kept) would stop the removal
  for _, e in ipairs(fs.scan(dir) or {}) do
    if e.type == 'directory' then pcall(uv.fs_chmod, e.rel == '' and dir or (dir .. '/' .. e.rel), DIR_MODE) end
  end
  return vim.fn.delete(dir, 'rf') == 0
end

-- No empty, `.` or `..` component.
local function clean_parts(p)
  for part in (p .. '/'):gmatch('([^/]*)/') do
    if part == '..' or part == '.' then return false end
  end
  return not p:find('//', 1, true)
end

-- The nearest existing folder above `path`, links resolved, is Claude's folder or inside it.
local function anchored(path, claude)
  local d = vim.fs.dirname(path)
  while d and d ~= '/' and not uv.fs_lstat(d) do d = vim.fs.dirname(d) end
  local real = d and uv.fs_realpath(d)
  return real ~= nil and (real == claude or inside(real, claude))
end

local function valid_entry(e, m, claude)
  if type(e) ~= 'table' or type(e.rel) ~= 'string' or type(e.path) ~= 'string' then return false end
  if e.rel == '' or e.rel:sub(1, 1) == '/' or not clean_parts(e.rel) then return false end
  if e.path:sub(1, 1) ~= '/' or not clean_parts(e.path:sub(2)) or not inside(e.path, claude) then return false end
  local name = vim.fs.basename(e.path)
  if name ~= vim.fs.basename(e.rel) or (name ~= m.id and name ~= m.id .. '.jsonl') then return false end
  return anchored(e.path, claude)
end

---Put a trashed session back where it came from; refused when anything is there now. An
---incomplete one puts back whatever is in the trash. On success, what could not be removed
---from the trash folder (if anything) comes as the second result.
---@param item { dir: string, manifest: table }
---@return boolean ok, string|nil err_or_note
function M.restore(item)
  local m, dir = item.manifest, item.dir
  if not in_trash(dir) then return false, 'not in the trash' end
  local claude, cerr = M.claude_dir()
  if not claude then return false, cerr end
  if type(m.entries) ~= 'table' then return false, 'broken manifest' end
  local todo = {}
  for _, e in ipairs(m.entries) do
    if not valid_entry(e, m, claude) then return false, 'unexpected entry in the manifest' end
    if uv.fs_lstat(dir .. '/' .. e.rel) then
      if uv.fs_lstat(e.path) then return false, 'something is there already: ' .. e.path end
      todo[#todo + 1] = e
    elseif m.complete ~= false then
      return false, 'missing in the trash: ' .. e.rel
    end
  end
  local lines = read(dir .. '/history.jsonl') or ''
  local other = read(dir .. '/history.other.jsonl') or ''
  if lines .. other ~= '' then
    local busy = held(claude)
    if busy then return false, busy end
  end
  local back = {}
  local function undo(reason)
    local stuck = {}
    for i = #back, 1, -1 do
      local e = back[i]
      local ok = fs.move(e.path, dir .. '/' .. e.rel, {})
      if not ok or not uv.fs_lstat(dir .. '/' .. e.rel) then stuck[#stuck + 1] = e.path end
    end
    if #stuck > 0 then
      reason = ('%s; these are back in Claude\'s folder already and could not return to the trash: %s'):format(reason, table.concat(stuck, ', '))
    end
    return false, reason
  end
  for _, e in ipairs(todo) do
    local ok, err = fs.move(dir .. '/' .. e.rel, e.path, {})
    if not ok then return undo(err) end
    back[#back + 1] = e
  end
  local ok, err = give_history(claude, lines .. other)
  if not ok then return undo(tostring(err)) end
  -- the trash folder: our files, then folders bottom-up when empty; never recursive
  for _, f in ipairs({ 'history.jsonl', 'history.other.jsonl', 'manifest.json' }) do uv.fs_unlink(dir .. '/' .. f) end
  local list = fs.scan(dir) or {}
  local dirs = {}
  for _, e in ipairs(list) do
    if e.type == 'directory' and e.rel ~= '' then dirs[#dirs + 1] = dir .. '/' .. e.rel end
  end
  local left = fs.cleanup(dir, dirs)
  return true, #left > 0 and ('left in the trash (not empty): ' .. dir) or nil
end

---Purge trashed sessions older than `days`, asynchronously (setup with `trash.keep_days`).
---A folder without a valid manifest, or an incomplete one, is never purged.
---@param days number
---@param cb? fun(n: integer)
function M.purge_older(days, cb)
  local root = M.dir()
  local limit = os.time() - days * 86400
  uv.fs_scandir(root, function(err, h)
    local old = {}
    while not err and h do
      local name = uv.fs_scandir_next(h)
      if not name then break end
      local y, mo, d, hh, mi, ss = name:match('^(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)(%d%d)%-')
      if y then
        local t = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(hh),
          min = tonumber(mi), sec = tonumber(ss) })
        if t < limit then old[#old + 1] = root .. '/' .. name end
      end
    end
    vim.schedule(function()
      local n = 0
      for _, dir in ipairs(old) do
        local m = manifest_of(dir)
        if m and m.complete ~= false and M.purge(dir) then n = n + 1 end
      end
      if cb then cb(n) end
    end)
  end)
end

return M

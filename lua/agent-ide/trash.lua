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
local uv = vim.uv
local jsonfile = require('agent-ide.util.jsonfile')

local M = {}

local DIR_MODE = 448 -- 0700
local UUID = '^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$'
local HISTORY_TRIES = 5

-- Test seams: the rename used for moves, and a hook run between writing the new history.jsonl
-- and checking that the original did not change.
M._rename = function(a, b) return uv.fs_rename(a, b) end
M._before_history_rename = nil

---@param id string
---@return boolean
function M.valid_id(id) return type(id) == 'string' and id:match(UUID) ~= nil end

---Claude's folder: the parent of `projects_dir`, links resolved; nil when it does not exist.
---@return string|nil
function M.claude_dir()
  local dir = vim.fs.normalize(require('agent-ide.config').get().projects_dir)
  return uv.fs_realpath(vim.fs.dirname(dir))
end

---The plugin's trash folder.
---@return string
function M.dir() return vim.fn.stdpath('data') .. '/agent-ide/trash' end

local function inside(path, root) return root ~= nil and vim.startswith(path, root .. '/') end

-- Entry `rel` below `claude` for session `id`, or nil and why it may not be moved. `name` must
-- be the id or `<id>.jsonl`; the folder holding it must resolve inside `claude`.
local function check(claude, rel, id)
  local abs = claude .. '/' .. rel
  local name = vim.fs.basename(abs)
  if name ~= id and name ~= id .. '.jsonl' then return nil, 'not named after the session: ' .. rel end
  local st = uv.fs_lstat(abs)
  if not st then return false end -- not there: nothing to move
  if st.type == 'link' then return nil, 'a symbolic link: ' .. rel end
  local parent = uv.fs_realpath(vim.fs.dirname(abs))
  if not parent or not (parent == claude or inside(parent, claude)) then return nil, 'outside Claude\'s folder: ' .. rel end
  return { rel = rel, path = parent .. '/' .. name, kind = st.type == 'directory' and 'dir' or 'file' }
end

---What deleting session `id` (transcript at `path`) would move; nil and a reason when it may not.
---@param id string
---@param path string the transcript
---@return table[]|nil entries { rel, path, kind }, string|nil err
function M.plan(id, path)
  if not M.valid_id(id) then return nil, 'not a session id' end
  local claude = M.claude_dir()
  if not claude then return nil, 'Claude\'s folder not found' end
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

-- Moving ---------------------------------------------------------------------------------------

local function mkdirs(dir)
  if vim.fn.isdirectory(dir) == 1 then return true end
  return pcall(vim.fn.mkdir, dir, 'p', DIR_MODE) and vim.fn.isdirectory(dir) == 1
end

-- Copy file or folder `src` to `dst` (modes kept); true when every file arrived with its size.
local function copy(src, dst)
  local st = uv.fs_lstat(src)
  if not st then return false end
  if st.type == 'directory' then
    if not pcall(vim.fn.mkdir, dst, 'p', st.mode % 4096) then return false end
    local h = uv.fs_scandir(src)
    while h do
      local name = uv.fs_scandir_next(h)
      if not name then break end
      if not copy(src .. '/' .. name, dst .. '/' .. name) then return false end
    end
    return true
  elseif st.type == 'file' then
    if not uv.fs_copyfile(src, dst, { excl = true }) then return false end
    uv.fs_chmod(dst, st.mode % 4096)
    local d = uv.fs_stat(dst)
    return d ~= nil and d.size == st.size
  end
  return false -- links and others are not copied
end

---Move `src` to `dst` (rename; across file systems copy, check sizes, then delete).
local function move(src, dst)
  if not mkdirs(vim.fs.dirname(dst)) then return false, 'cannot create ' .. vim.fs.dirname(dst) end
  if uv.fs_lstat(dst) then return false, 'already exists: ' .. dst end
  local ok, err = M._rename(src, dst)
  if ok then return true end
  if not (err and tostring(err):find('EXDEV', 1, true)) then return false, tostring(err) end
  if not copy(src, dst) then
    vim.fn.delete(dst, 'rf')
    return false, 'copy failed: ' .. src
  end
  if vim.fn.delete(src, 'rf') ~= 0 then return false, 'cannot remove ' .. src end
  return true
end

-- history.jsonl --------------------------------------------------------------------------------

local function read(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local t = f:read('a')
  f:close()
  return t
end

---Lines of `text` (each with its newline) split into those of session `id` and the rest.
---Byte-exact: lines are only decoded to test their `sessionId`; one that does not decode stays.
---@return string kept, string removed, integer n
function M.split_history(text, id)
  local kept, removed, n = {}, {}, 0
  local pos = 1
  while pos <= #text do
    local nl = text:find('\n', pos, true)
    local line = text:sub(pos, nl or #text)
    pos = (nl or #text) + 1
    local mine = false
    if line:find(id, 1, true) then
      local ok, rec = pcall(vim.json.decode, line)
      mine = ok and type(rec) == 'table' and rec.sessionId == id
    end
    if mine then
      removed[#removed + 1] = line:sub(-1) == '\n' and line or (line .. '\n')
      n = n + 1
    else
      kept[#kept + 1] = line
    end
  end
  return table.concat(kept), table.concat(removed), n
end

---Rewrite `path` as `transform(text)` without losing lines appended meanwhile: the new text
---goes to a temp file (same folder and mode), which replaces the original only when the
---original's size and mtime did not change since it was read; else everything again.
---@param path string
---@param transform fun(text: string): string|nil new text (nil: no change), any extra result
---@param create? boolean a missing file is created (from '')
---@return boolean ok, any extra|string err
local function rewrite(path, transform, create)
  for _ = 1, HISTORY_TRIES do
    local st = uv.fs_stat(path)
    if not st and not create then return true, nil end
    local text = st and read(path) or ''
    if st and not text then return false, 'cannot read ' .. path end
    local new, extra = transform(text)
    if new == nil then return true, extra end
    local tmp = ('%s/.agent-ide-%d-%s.tmp'):format(vim.fs.dirname(path), uv.os_getpid(), uv.hrtime())
    local fd = uv.fs_open(tmp, 'wx', st and st.mode % 4096 or 384)
    if not fd then return false, 'cannot write next to ' .. path end
    local wrote = uv.fs_write(fd, new, 0)
    if st then uv.fs_fchmod(fd, st.mode % 4096) end
    local synced = wrote and uv.fs_fsync(fd)
    uv.fs_close(fd)
    if not synced then
      uv.fs_unlink(tmp)
      return false, 'cannot write next to ' .. path
    end
    if M._before_history_rename then M._before_history_rename(path) end
    local now = uv.fs_stat(path)
    local same = (st == nil and now == nil) or (st and now and now.size == st.size
      and now.mtime.sec == st.mtime.sec and now.mtime.nsec == st.mtime.nsec)
    if same then
      local ok, err = uv.fs_rename(tmp, path)
      if not ok then
        uv.fs_unlink(tmp)
        return false, tostring(err)
      end
      return true, extra
    end
    uv.fs_unlink(tmp) -- Claude wrote meanwhile: read again
  end
  return false, path .. ' kept changing'
end

-- Take the lines of `id` out of history.jsonl; ok, the removed text, their count.
local function take_history(claude, id)
  local path = claude .. '/history.jsonl'
  local st = uv.fs_lstat(path)
  if st and st.type ~= 'file' then return false, 'history.jsonl is not a plain file' end
  local ok, res = rewrite(path, function(text)
    local kept, removed, n = M.split_history(text, id)
    if n == 0 then return nil, { '', 0 } end
    return kept, { removed, n }
  end)
  if not ok then return false, res end
  res = res or { '', 0 }
  return true, res[1], res[2]
end

local function stamp_of(line) return tonumber(line:match('"timestamp"%s*:%s*(%d+)')) end

local function lines_of(text)
  local out = {}
  for line in text:gmatch('[^\n]*\n?') do
    if line ~= '' then out[#out + 1] = line end
  end
  return out
end

---`lines` (each ending in a newline) put back into history `text` in time order: each right
---after the last line with a `timestamp` not later than its own (else at the start; a line
---without a timestamp goes at the end).
---@param text string
---@param lines string
---@return string
function M.merge_history(text, lines)
  local kept, back = lines_of(text), lines_of(lines)
  if #kept > 0 and kept[#kept]:sub(-1) ~= '\n' then kept[#kept] = kept[#kept] .. '\n' end
  local stamps = {}
  for i, k in ipairs(kept) do stamps[i] = stamp_of(k) end
  local out, i = {}, 1 -- kept[i..] not written yet
  for _, r in ipairs(back) do
    local t = stamp_of(r)
    local j = t and i - 1 or #kept
    if t then
      for x = i, #kept do
        if stamps[x] and stamps[x] <= t then j = x elseif stamps[x] and stamps[x] > t then break end
      end
    end
    for x = i, j do out[#out + 1] = kept[x] end
    i = math.max(i, j + 1)
    out[#out + 1] = r
  end
  for x = i, #kept do out[#out + 1] = kept[x] end
  return table.concat(out)
end

-- Put `lines` (each ending in a newline) back into history.jsonl.
local function give_history(claude, lines)
  if lines == '' then return true end
  return rewrite(claude .. '/history.jsonl', function(text) return M.merge_history(text, lines) end, true)
end

-- Delete ---------------------------------------------------------------------------------------

local function write_file(path, text)
  local fd = uv.fs_open(path, 'wx', 384)
  if not fd then return false end
  local ok = uv.fs_write(fd, text, 0)
  uv.fs_close(fd)
  return ok ~= nil
end

---Move session `id` (transcript `path`) into the trash. On any failure everything moved so
---far goes back.
---@param id string
---@param path string
---@param info { title?: string, project?: string }
---@return string|nil trash folder, string|nil err
function M.delete(id, path, info)
  local entries, err = M.plan(id, path)
  if not entries then return nil, err end
  local claude = M.claude_dir()
  local root = M.dir()
  if not mkdirs(root) then return nil, 'cannot create the trash folder' end
  pcall(uv.fs_chmod, root, DIR_MODE)
  local now = os.time()
  local dir = ('%s/%s-%s'):format(root, os.date('%Y%m%d-%H%M%S', now), id)
  if uv.fs_lstat(dir) then return nil, 'already in the trash: ' .. dir end
  if not mkdirs(dir) then return nil, 'cannot create ' .. dir end

  local moved = {}
  local function undo(reason)
    local lost = {}
    for i = #moved, 1, -1 do
      local e = moved[i]
      if not move(dir .. '/' .. e.rel, e.path) then lost[#lost + 1] = e.path end
    end
    if #lost == 0 then vim.fn.delete(dir, 'rf') end
    if #lost > 0 then reason = reason .. '; could not put back ' .. table.concat(lost, ', ') .. ' (left in ' .. dir .. ')' end
    return nil, reason
  end
  for _, e in ipairs(entries) do
    local ok, merr = move(e.path, dir .. '/' .. e.rel)
    if not ok then return undo(merr) end
    local st = uv.fs_lstat(dir .. '/' .. e.rel)
    e.size = st and st.size or 0
    moved[#moved + 1] = e
  end
  local ok, removed, n = take_history(claude, id)
  if not ok then return undo(removed) end
  local manifest = vim.json.encode({ version = 1, id = id, deleted_at = now, title = info and info.title or nil,
    project = info and info.project or nil, claude_dir = claude, history_lines = n,
    entries = vim.tbl_map(function(e) return { rel = e.rel, path = e.path, kind = e.kind, size = e.size } end, entries) })
  if (n > 0 and not write_file(dir .. '/history.jsonl', removed)) or not write_file(dir .. '/manifest.json', manifest) then
    give_history(claude, removed)
    return undo('cannot write the manifest')
  end
  return dir
end

-- Trash listing, restore, purge ------------------------------------------------------------------

---Trashed sessions, newest first: { dir, manifest }.
---@return { dir: string, manifest: table }[]
function M.list()
  local out = {}
  local h = uv.fs_scandir(M.dir())
  while h do
    local name, typ = uv.fs_scandir_next(h)
    if not name then break end
    if typ == 'directory' then
      local dir = M.dir() .. '/' .. name
      local m = jsonfile.decode(read(dir .. '/manifest.json'))
      if m and M.valid_id(m.id) then out[#out + 1] = { dir = dir, manifest = m, name = name } end
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
  return vim.fn.delete(dir, 'rf') == 0
end

---Put a trashed session back where it came from; refused when anything is there now.
---@param item { dir: string, manifest: table }
---@return boolean ok, string|nil err
function M.restore(item)
  local m, dir = item.manifest, item.dir
  if not in_trash(dir) then return false, 'not in the trash' end
  local claude = M.claude_dir()
  if not claude then return false, 'Claude\'s folder not found' end
  if type(m.entries) ~= 'table' then return false, 'broken manifest' end
  for _, e in ipairs(m.entries) do
    if type(e.rel) ~= 'string' or type(e.path) ~= 'string' or e.rel:find('..', 1, true)
      or not inside(e.path, claude) or vim.fs.basename(e.path) ~= vim.fs.basename(e.rel)
      or (vim.fs.basename(e.path) ~= m.id and vim.fs.basename(e.path) ~= m.id .. '.jsonl') then
      return false, 'unexpected entry in the manifest'
    end
    if uv.fs_lstat(e.path) then return false, 'something is there already: ' .. e.path end
    if not uv.fs_lstat(dir .. '/' .. e.rel) then return false, 'missing in the trash: ' .. e.rel end
  end
  local back = {}
  for _, e in ipairs(m.entries) do
    local ok, err = move(dir .. '/' .. e.rel, e.path)
    if not ok then
      for i = #back, 1, -1 do move(back[i].path, dir .. '/' .. back[i].rel) end
      return false, err
    end
    back[#back + 1] = e
  end
  local lines = read(dir .. '/history.jsonl') or ''
  local ok, err = give_history(claude, lines)
  if not ok then
    for i = #back, 1, -1 do move(back[i].path, dir .. '/' .. back[i].rel) end
    return false, err
  end
  vim.fn.delete(dir, 'rf')
  return true
end

---Purge trashed sessions older than `days`, asynchronously (setup with `trash.keep_days`).
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
        if M.purge(dir) then n = n + 1 end
      end
      if cb then cb(n) end
    end)
  end)
end

return M

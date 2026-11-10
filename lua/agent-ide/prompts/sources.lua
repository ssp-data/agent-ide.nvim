-- Prompt sources: folders of markdown files scanned into PromptEntry lists, off the UI thread
-- (a work queue run in short slices on later event-loop turns, like the Lua session scan).
--
-- PromptEntry: { kind = 'command'|'skill'|'template'|'saved', name, title, description|nil, path,
--   group|nil, scope = 'user'|'project'|'library'|'saved', insert|nil, stamp }
-- `insert` is `/name` for commands and skills; templates and saved prompts are read with `read`.
local uv = vim.uv

local M = {}

M.SLICE_MS = 4 -- work per event-loop turn
M.HEAD_BYTES = 8192 -- bytes read per file for frontmatter and the first heading
M.MAX_FILES = 5000 -- per source folder
M.MAX_DEPTH = 12
M.MAX_READ = 1024 * 1024 -- a template or saved prompt larger than this is not loaded
local DESC_MAX = 500

local function yield(fn) vim.defer_fn(fn, 0) end

-- Frontmatter ------------------------------------------------------------------------------

local function unquote(v)
  v = v:gsub('^%s+', ''):gsub('%s+$', '')
  local q = v:sub(1, 1)
  if (q == '"' or q == "'") and #v >= 2 and v:sub(-1) == q then
    v = v:sub(2, -2)
    if q == "'" then v = v:gsub("''", "'") end
  end
  return v
end

local function one_line(v)
  v = v:gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', '')
  if #v > DESC_MAX then v = vim.fn.strcharpart(v, 0, DESC_MAX) end
  return v ~= '' and v or nil
end

-- `name` and `description` of the lines of a frontmatter block (plain, quoted, folded scalars).
local function fields(block)
  local lines = vim.split(block, '\n', { plain = true })
  local out = {}
  local i = 1
  while i <= #lines do
    local line = lines[i]:gsub('\r$', '')
    local key, value = line:match('^([%w_%-]+)%s*:%s*(.-)%s*$')
    if (key == 'name' or key == 'title' or key == 'description') and out[key] == nil then
      if value:match('^[>|][%+%-]?%d*$') then
        local parts = {}
        while i < #lines and (lines[i + 1]:match('^%s') or lines[i + 1]:gsub('\r$', '') == '') do
          i = i + 1
          parts[#parts + 1] = lines[i]
        end
        out[key] = one_line(table.concat(parts, ' '))
      else
        out[key] = one_line(unquote(value))
      end
    end
    i = i + 1
  end
  return out
end

-- A block that reads as YAML: at least one `key:` line, and every other non-blank line a key
-- line, an indented continuation, a `- item` or a `#` comment.
local function yaml_like(block)
  local keys = 0
  for line in (block .. '\n'):gmatch('(.-)\n') do
    line = line:gsub('\r$', '')
    if line:match('^[%w_%-]+%s*:') then
      keys = keys + 1
    elseif line:find('%S') and not (line:match('^%s') or line:match('^#') or line:match('^%-%s') or line == '-') then
      return false
    end
  end
  return keys > 0
end

---Split optional YAML frontmatter (`---` fenced at the very top) from the body. Reads only
---`name` and `description`; never raises. `frontmatter` holds the block's bytes, both fences and
---the newline after the closing one included, so a file can be rewritten with it unchanged.
---`opts.yaml`: a block counts only when it reads as YAML (library files: a prompt may start
---with a pair of markdown rules); Claude's commands and skills take any block.
---@param text string
---@param opts? { yaml?: boolean }
---@return { name: string|nil, description: string|nil, body: string, frontmatter: string|nil }
function M.parse(text, opts)
  local yaml = opts and opts.yaml
  local ok, res = pcall(function()
    local start = text:sub(1, 3) == '\239\187\191' and 4 or 1 -- a UTF-8 byte order mark
    local first = text:match('^%-%-%-[ \t]*\r?\n', start)
    if not first then return { body = text } end
    local from = start + #first
    local pos = from
    while pos <= #text + 1 do
      local nl = text:find('\n', pos, true)
      local line = text:sub(pos, (nl or #text + 1) - 1):gsub('\r$', '')
      if line:match('^%-%-%-[ \t]*$') or line:match('^%.%.%.[ \t]*$') then
        local stop = nl or #text
        if yaml and not yaml_like(text:sub(from, pos - 1)) then return { body = text } end
        local f = fields(text:sub(from, pos - 1))
        return { name = f.name, title = f.title, description = f.description, body = text:sub(stop + 1), frontmatter = text:sub(1, stop) }
      end
      if not nl then break end
      pos = nl + 1
    end
    return { body = text } -- never closed: not frontmatter
  end)
  if ok then return res end
  return { body = text }
end

-- Files ------------------------------------------------------------------------------------

-- The first HEAD_BYTES of a file; up to 64 KiB when a frontmatter block is longer than that.
M._reads = 0 -- file heads read (tests)
local function read_head(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  M._reads = M._reads + 1
  local text = f:read(M.HEAD_BYTES) or ''
  if #text == M.HEAD_BYTES and text:match('^%-%-%-') and not M.parse(text).frontmatter then
    text = text .. (f:read(65536 - M.HEAD_BYTES) or '')
  end
  f:close()
  return text
end

local function first_heading(body)
  for line in body:gmatch('[^\n]+') do
    local h = line:gsub('\r$', ''):match('^#+%s+(.-)%s*#*%s*$')
    if h and h ~= '' then return h end
  end
end

local function pretty(file) return (file:gsub('%.md$', ''):gsub('[-_]+', ' ')) end

local function stamp(st) return st and (st.mtime.sec .. '.' .. st.mtime.nsec .. ':' .. st.size) or '' end

---Text of a template or saved prompt: the whole file, byte for byte. A leading `---` block is
---part of the prompt (it may be a skill-style definition meant for the agent); its `name` and
---`description` are only read for display (see `make`).
---@param entry table PromptEntry
---@param cb fun(text: string|nil, err: string|nil)
function M.read(entry, cb)
  local st = uv.fs_stat(entry.path)
  if not st or st.type ~= 'file' then return cb(nil, 'file not found') end
  if st.size > M.MAX_READ then return cb(nil, 'file too large') end
  local f = io.open(entry.path, 'rb')
  if not f then return cb(nil, 'cannot read the file') end
  local text = f:read('a') or ''
  f:close()
  cb(text)
end

-- Scan -------------------------------------------------------------------------------------

local function expand(dir) return dir and vim.fs.normalize(dir) or nil end

local function is_dir(path, typ)
  if typ == 'directory' then return true end
  if typ == 'link' or typ == nil then
    local st = uv.fs_stat(path)
    return st ~= nil and st.type == 'directory'
  end
  return false
end

local function is_file(path, typ)
  if typ == 'file' then return true end
  if typ == 'link' or typ == nil then
    local st = uv.fs_stat(path)
    return st ~= nil and st.type == 'file'
  end
  return false
end

-- Build the entry of one file; nil when it cannot be read. An entry of `known` (the last scan)
-- whose file has not changed is reused without reading the file.
local function make(src, path, rel, known)
  local st = stamp(uv.fs_stat(path))
  local old = known and known[path]
  if old and old.stamp == st and old.kind == src.kind and old.scope == src.scope then return old end
  local head = read_head(path)
  if not head then return nil end
  -- templates and saved prompts: a YAML-like block only gives the title and description shown
  -- in the drawer and picker; the text itself is never cut (see `read`)
  local p = M.parse(head, { yaml = src.kind == 'template' or src.kind == 'saved' })
  local e = { kind = src.kind, path = path, scope = src.scope, stamp = st, description = p.description }
  if src.kind == 'command' then
    e.name = rel:gsub('%.md$', ''):gsub('/', ':')
    e.title, e.insert = e.name, '/' .. e.name
  elseif src.kind == 'skill' then
    local folder = vim.fs.basename(vim.fs.dirname(path))
    -- Claude's skill names are plain words; anything odd falls back to the folder name
    e.name = (p.name and p.name:match('^[%w][%w_.:%-]*$')) and p.name or folder
    e.title, e.insert = e.name, '/' .. e.name
  else
    local dir = vim.fs.dirname(rel)
    e.group = (dir ~= '.' and dir ~= '') and dir or nil
    e.name = rel:gsub('%.md$', '')
    e.title = p.name or p.title or first_heading(p.body) or pretty(vim.fs.basename(rel))
  end
  return e
end

-- Group then title, case-insensitive; '/' sorts before every other character, so a folder's
-- sub-folders follow its own entries and never interleave with a sibling (`a/b` before `a-c`).
local function sort_key(e) return ((e.group or ''):gsub('/', '\1') .. '\0' .. e.title):lower() end

---Scan every source asynchronously; `cb(entries)` runs on the main loop. Missing folders give
---no entries, unreadable files are skipped, symlinked folders are followed (once each).
---@param opts { command_dirs?: string[], skill_dirs?: string[], library_dir?: string, saved_dir?: string, project_root?: string, project_name?: string, project_dirs?: boolean }
---@param cb fun(entries: table[])
function M.scan(opts, cb)
  local srcs = {}
  local function add(kind, scope, dir, mode)
    dir = expand(dir)
    if dir and dir ~= '' then srcs[#srcs + 1] = { kind = kind, scope = scope, root = dir, mode = mode, n = 0 } end
  end
  if opts.project_root and opts.project_dirs ~= false then
    add('command', 'project', opts.project_root .. '/.claude/commands', 'tree')
    add('skill', 'project', opts.project_root .. '/.claude/skills', 'skills')
  end
  local function list(v) return type(v) == 'string' and { v } or (type(v) == 'table' and v or {}) end
  for _, d in ipairs(list(opts.command_dirs)) do add('command', 'user', d, 'tree') end
  for _, d in ipairs(list(opts.skill_dirs)) do add('skill', 'user', d, 'skills') end
  add('template', 'library', opts.library_dir, 'tree')
  if opts.saved_dir and opts.project_name then add('saved', 'saved', expand(opts.saved_dir) .. '/' .. opts.project_name, 'flat') end

  local queue, head, tail = {}, 1, 0
  local function push(item)
    tail = tail + 1
    queue[tail] = item
  end
  for i, s in ipairs(srcs) do
    s.order = i
    push({ dir = s.root, rel = '', src = s, depth = 0 })
  end
  local seen = {} -- real paths of folders already listed
  local found = {}

  local function list(item)
    local real = uv.fs_realpath(item.dir)
    if not real or seen[real] then return end
    seen[real] = true
    local h = uv.fs_scandir(item.dir)
    if not h then return end
    local src = item.src
    while true do
      local name, typ = uv.fs_scandir_next(h)
      if not name then break end
      if name:sub(1, 1) ~= '.' then
        local path = item.dir .. '/' .. name
        local rel = item.rel == '' and name or (item.rel .. '/' .. name)
        if src.mode == 'skills' then
          if item.depth == 0 and is_dir(path, typ) and is_file(path .. '/SKILL.md') then
            push({ file = path .. '/SKILL.md', rel = rel, src = src })
          end
        elseif name:sub(-3) == '.md' and is_file(path, typ) then
          if src.n < M.MAX_FILES then
            src.n = src.n + 1
            push({ file = path, rel = rel, src = src })
          end
        elseif src.mode == 'tree' and item.depth < M.MAX_DEPTH and is_dir(path, typ) then
          push({ dir = path, rel = rel, src = src, depth = item.depth + 1 })
        end
      end
    end
  end

  local function finish()
    local out, taken = {}, {}
    table.sort(found, function(a, b) -- project sources come first: they win a name clash
      if a.order ~= b.order then return a.order < b.order end
      return a.e.path < b.e.path
    end)
    for _, f in ipairs(found) do
      local e = f.e
      local key = e.insert or (e.kind .. ':' .. e.path)
      if not taken[key] then
        taken[key] = true
        out[#out + 1] = e
      end
    end
    for _, e in ipairs(out) do e._sort = sort_key(e) end
    table.sort(out, function(a, b)
      if a._sort ~= b._sort then return a._sort < b._sort end
      return a.path < b.path
    end)
    for _, e in ipairs(out) do e._sort = nil end
    cb(out)
  end

  local function step()
    local t0 = uv.hrtime()
    while head <= tail do
      local item = queue[head]
      queue[head] = nil
      head = head + 1
      pcall(function()
        if item.dir then
          list(item)
        else
          local e = make(item.src, item.file, item.rel, opts.known)
          if e then found[#found + 1] = { e = e, order = item.src.order } end
        end
      end)
      if (uv.hrtime() - t0) / 1e6 >= M.SLICE_MS then return yield(step) end
    end
    finish()
  end
  yield(step)
end

return M

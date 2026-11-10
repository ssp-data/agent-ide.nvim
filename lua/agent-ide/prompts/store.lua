-- Library and saved-prompt files: origins of prompt buffers, naming rules, atomic writes that
-- never clobber another prompt, rename and delete. Never writes under a `.claude` folder; files
-- it creates are 0600 in folders it creates 0700 (a replaced file keeps its mode).
local uv = vim.uv

local M = {}

local FILE_MODE, DIR_MODE = 384, 448 -- 0600, 0700
local SLUG_MAX = 60
-- bytes per file name part: 255 (Linux NAME_MAX) minus room for `-NNNN.md`
local NAME_BYTES = 240

-- Origins ------------------------------------------------------------------------------------

---Change stamp of a file (mtime and size); nil when it is gone.
---@param path string
---@return string|nil
function M.stamp(path)
  local st = uv.fs_stat(path)
  return st and (st.mtime.sec .. '.' .. st.mtime.nsec .. ':' .. st.size) or nil
end

---Where the text of prompt buffer `buf` came from: nil for a fresh prompt.
---@param buf integer
---@return { kind: string, path: string, stamp: string }|nil
function M.origin(buf)
  local o = vim.b[buf].agent_ide_origin
  return type(o) == 'table' and o or nil
end

---Remember (or forget, `e` nil) the file the text of `buf` came from.
---@param buf integer
---@param e table|nil PromptEntry or { kind, path }
function M.set_origin(buf, e)
  vim.b[buf].agent_ide_origin = e and { kind = e.kind, path = e.path, stamp = M.stamp(e.path) or '' } or nil
end

local function prompt_bufs()
  local out = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.startswith(vim.api.nvim_buf_get_name(b), 'agent-ide://prompt/') then out[#out + 1] = b end
  end
  return out
end

-- Names ----------------------------------------------------------------------------------------

-- Characters of a string (UTF-8 sequences kept whole).
local function chars(s) return vim.fn.split(s, '\\zs') end

-- A letter or digit: ASCII ones, and non-ASCII word characters (umlauts, CJK; not emoji).
local function is_alnum(ch)
  if #ch == 1 then return ch:match('^[%w]$') ~= nil end
  local class = vim.fn.charclass(ch)
  return class == 2 or class >= 0x100
end

---File name (without `.md`) for a prompt: its first non-blank line that is not an `[attach]`
---line, lower case, runs of other characters as `-`, at most 60 characters; empty:
---`prompt-<YYYYMMDD-HHMMSS>`.
---@param lines string[]
---@return string
function M.slug(lines)
  local first = ''
  for _, l in ipairs(lines) do
    if l:find('%S') and not l:match('^%[attach%]') then
      first = l
      break
    end
  end
  local out, dash = {}, false
  for _, ch in ipairs(chars(vim.fn.tolower(first))) do
    if is_alnum(ch) then
      out[#out + 1] = ch
      dash = false
    elseif not dash and #out > 0 then
      out[#out + 1] = '-'
      dash = true
    end
    if #out >= SLUG_MAX or #table.concat(out) + 4 > NAME_BYTES then break end
  end
  while out[#out] == '-' do out[#out] = nil end
  local s = table.concat(out)
  return s ~= '' and s or ('prompt-' .. os.date('%Y%m%d-%H%M%S'))
end

---A library name as typed (`group/name`) made a relative path without `.md`; nil and the
---reason when it is not allowed: no `..`, `.` or empty parts, no leading `/`, a part may not
---start with `.`, only letters, digits, space, `-`, `_` and `.`. Spaces become `-`.
---@param typed string
---@param flat? boolean no `/` allowed (saved prompts)
---@return string|nil rel, string|nil reason
function M.clean_name(typed, flat)
  local name = vim.trim(typed or ''):gsub('%.md$', '')
  if name == '' then return nil, 'the name is empty' end
  if name:sub(1, 1) == '/' or name:sub(1, 1) == '~' then return nil, 'a name cannot start with / or ~' end
  if flat and name:find('/', 1, true) then return nil, 'no folders here (no /)' end
  local parts = {}
  for part in (name .. '/'):gmatch('(.-)/') do
    part = vim.trim(part)
    if part == '..' then return nil, '".." is not allowed' end
    if part == '' or part == '.' then return nil, 'empty or "." folder names are not allowed' end
    if part:sub(1, 1) == '.' then return nil, 'a name cannot start with "."' end
    for _, ch in ipairs(chars(part)) do
      if not (is_alnum(ch) or ch == ' ' or ch == '-' or ch == '_' or ch == '.') then
        return nil, 'only letters, digits, space, - _ and . are allowed'
      end
    end
    if #part > NAME_BYTES then return nil, 'a name part is longer than ' .. NAME_BYTES .. ' bytes' end
    parts[#parts + 1] = (part:gsub('%s+', '-'))
  end
  return table.concat(parts, '/')
end

---`base.md`, else `base-2.md`, `base-3.md`, ... : the first that does not exist in `dir`.
---@param dir string
---@param base string
---@return string rel name without `.md`
function M.free_name(dir, base)
  if not uv.fs_stat(dir .. '/' .. base .. '.md') then return base end
  local n = 2
  while uv.fs_stat(('%s/%s-%d.md'):format(dir, base, n)) do n = n + 1 end
  return ('%s-%d'):format(base, n)
end

-- Writing ----------------------------------------------------------------------------------------

---Error when `path` is under a `.claude` folder (as given or with links resolved).
local function guard(path)
  local function has(p) return p and (('/' .. p .. '/'):find('/.claude/', 1, true) ~= nil) end
  if has(path) then return 'refusing to write under a .claude folder' end
  local dir = vim.fs.dirname(path)
  while dir and dir ~= '/' and not uv.fs_stat(dir) do dir = vim.fs.dirname(dir) end
  if has(dir and uv.fs_realpath(dir)) then return 'refusing to write under a .claude folder' end
end

local function ensure_dir(dir)
  if vim.fn.isdirectory(dir) == 1 then return true end
  local ok, err = pcall(vim.fn.mkdir, dir, 'p', DIR_MODE)
  if not ok or vim.fn.isdirectory(dir) ~= 1 then return nil, 'cannot create ' .. vim.fn.fnamemodify(dir, ':~') .. (ok and '' or (': ' .. tostring(err))) end
  return true
end

-- Write `text` to a new temporary file next to `path`; its path, or nil and an error.
local function write_tmp(path, text, mode)
  local tmp = ('%s/.agent-ide-%s.tmp'):format(vim.fs.dirname(path), vim.fn.sha256(path .. uv.hrtime() .. math.random()):sub(1, 12))
  local fd, err = uv.fs_open(tmp, 'wx', mode or FILE_MODE)
  if not fd then return nil, err end
  local ok, werr = uv.fs_write(fd, text, 0)
  if ok and mode then uv.fs_fchmod(fd, mode) end -- the mode of a replaced file, not the umask's
  local synced = ok and uv.fs_fsync(fd)
  uv.fs_close(fd)
  if not ok or not synced then
    uv.fs_unlink(tmp)
    return nil, werr or 'write failed'
  end
  return tmp
end

---Write a new file atomically; never replaces an existing one (returns nil, 'exists').
---@param path string
---@param text string
---@return true|nil ok, string|nil err
function M.write_new(path, text)
  local bad = guard(path)
  if bad then return nil, bad end
  local ok, err = ensure_dir(vim.fs.dirname(path))
  if not ok then return nil, err end
  if uv.fs_stat(path) then return nil, 'exists' end
  local tmp, terr = write_tmp(path, text)
  if not tmp then return nil, terr end
  -- a hard link fails when the name is taken: two Neovims saving one name both keep theirs
  local linked, lerr = uv.fs_link(tmp, path)
  if linked then
    uv.fs_unlink(tmp)
    return true
  end
  if lerr and lerr:find('EEXIST', 1, true) then
    uv.fs_unlink(tmp)
    return nil, 'exists'
  end
  -- no hard links on this file system: an exclusive create instead
  uv.fs_unlink(tmp)
  local fd, oerr = uv.fs_open(path, 'wx', FILE_MODE)
  if not fd then return nil, (oerr and oerr:find('EEXIST', 1, true)) and 'exists' or oerr end
  local w = uv.fs_write(fd, text, 0)
  uv.fs_close(fd)
  if not w then
    uv.fs_unlink(path)
    return nil, 'write failed'
  end
  return true
end

---Replace the file at `path` atomically (temp file + rename), keeping its mode.
---@param path string
---@param text string
---@return true|nil ok, string|nil err
function M.replace(path, text)
  local bad = guard(path)
  if bad then return nil, bad end
  local ok, err = ensure_dir(vim.fs.dirname(path))
  if not ok then return nil, err end
  local st = uv.fs_stat(path)
  local tmp, terr = write_tmp(path, text, st and (st.mode % 4096) or nil)
  if not tmp then return nil, terr end
  local renamed, rerr = uv.fs_rename(tmp, path)
  if not renamed then
    uv.fs_unlink(tmp)
    return nil, rerr
  end
  return true
end

-- Rename and delete --------------------------------------------------------------------------------

local function claude_owned(e) return e.kind == 'command' or e.kind == 'skill' end

local function base_dir(e)
  if e.kind == 'template' then return require('agent-ide.prompts.cache').dirs().library end
  return vim.fs.dirname(e.path)
end

---Rename a template (`group/name` moves it between groups) or a saved prompt; never replaces
---another file. `cb(new_path)` or `cb(nil, err)`.
---@param e table PromptEntry
---@param new_name string
---@param cb fun(path: string|nil, err: string|nil)
function M.rename(e, new_name, cb)
  if claude_owned(e) then return cb(nil, "this file belongs to Claude's folders") end
  local rel, why = M.clean_name(new_name, e.kind == 'saved')
  if not rel then return cb(nil, 'name not allowed: ' .. why) end
  local dest = base_dir(e) .. '/' .. rel .. '.md'
  if dest == e.path then return cb(dest) end
  local bad = guard(dest)
  if bad then return cb(nil, bad) end
  if uv.fs_stat(dest) then return cb(nil, 'exists') end
  local ok, err = ensure_dir(vim.fs.dirname(dest))
  if not ok then return cb(nil, err) end
  local linked, lerr = uv.fs_link(e.path, dest)
  if linked then
    uv.fs_unlink(e.path)
  elseif lerr and lerr:find('EEXIST', 1, true) then
    return cb(nil, 'exists')
  else
    local renamed, rerr = uv.fs_rename(e.path, dest)
    if not renamed then return cb(nil, rerr) end
  end
  for _, b in ipairs(prompt_bufs()) do
    local o = M.origin(b)
    -- the old stamp moves along: a change made on disk before the rename is still noticed
    if o and o.path == e.path then vim.b[b].agent_ide_origin = { kind = o.kind, path = dest, stamp = o.stamp } end
  end
  cb(dest)
end

---Delete a template or saved prompt; prompt buffers loaded from it become fresh prompts.
---@param e table PromptEntry
---@param cb fun(ok: boolean|nil, err: string|nil)
function M.delete(e, cb)
  if claude_owned(e) then return cb(nil, "this file belongs to Claude's folders") end
  local bad = guard(e.path)
  if bad then return cb(nil, bad) end
  local ok, err = uv.fs_unlink(e.path)
  if not ok then return cb(nil, err) end
  for _, b in ipairs(prompt_bufs()) do
    local o = M.origin(b)
    if o and o.path == e.path then M.set_origin(b, nil) end
  end
  cb(true)
end

return M
